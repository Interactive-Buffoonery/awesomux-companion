import AwesoMuxCompanionProtocol
import Foundation
import os

@MainActor
protocol WatchRendering: AnyObject {
    func reset(grid: CompanionTerminalStream.Grid, scrollbackBound: Int) throws
    func feed(_ bytes: Data) throws
    func resize(_ grid: CompanionTerminalStream.Grid) throws
    func clear()
}

struct WatchPacket: Sendable {
    let frame: CompanionTerminalStream.Frame
    let generation: UInt32
}

protocol WatchConnection: Sendable {
    var capabilities: CompanionTerminalStream.Capabilities { get }
    var accepted: CompanionTerminalStream.Accepted { get }
    @MainActor func send(_ frame: CompanionTerminalStream.Frame, generation: UInt32,
                         canSend: @escaping @MainActor @Sendable () -> Bool) async throws
    func receive() async throws -> WatchPacket
    func cancel()
}

protocol WatchClient: Sendable {
    func openWatch(connectionID: UUID, paneID: UUID, targetVersion: UUID, preferredGrid: CompanionTerminalStream.Grid,
                   canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> any WatchConnection
}

extension WatchConnection {
    var accepted: CompanionTerminalStream.Accepted { .init(role: .watch) }
    @MainActor func send(_ frame: CompanionTerminalStream.Frame, generation: UInt32,
                         canSend: @escaping @MainActor @Sendable () -> Bool) async throws {
        throw WatchFailure.invalidStream
    }
}

extension MacClient: WatchClient {}

protocol WatchFrameConnection: Sendable {
    @MainActor func send(_ payload: Data, maximum: Int, canSend: (@MainActor @Sendable () -> Bool)?) async throws
    func receiveFrame(maximum: Int) async throws -> Data
    func cancel()
}

final class MacWatchConnection: WatchConnection, Sendable {
    let capabilities: CompanionTerminalStream.Capabilities
    let accepted: CompanionTerminalStream.Accepted
    private let connection: any WatchFrameConnection
    private let receiving = OSAllocatedUnfairLock(initialState: false)
    private let idleTimeout: Duration

    init(connection: any WatchFrameConnection, capabilities: CompanionTerminalStream.Capabilities,
         idleTimeout: Duration = .seconds(45),
         accepted: CompanionTerminalStream.Accepted = .init(role: .watch)) {
        self.connection = connection
        self.capabilities = capabilities
        self.idleTimeout = idleTimeout
        self.accepted = accepted
    }

    @MainActor func send(_ frame: CompanionTerminalStream.Frame, generation: UInt32,
                         canSend: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard accepted.role == .interactive, let maximum = capabilities.inputFrameMax else {
            throw WatchFailure.invalidStream
        }
        switch frame {
        case .input(_, let bytes):
            guard bytes.count <= maximum else { throw WatchFailure.invalidStream }
        case .grid(let grid): try WatchStream.validate(grid)
        case .claim(let claim): try WatchStream.validate(claim.grid)
        default: throw WatchFailure.invalidStream
        }
        try await connection.send(CompanionTerminalStream.encode(frame, generation: generation),
                                  maximum: CompanionTerminalStream.maximumFrameBytes, canSend: canSend)
    }

    func receive() async throws -> WatchPacket {
        guard receiving.withLock({ value in
            guard !value else { return false }
            value = true
            return true
        }) else { throw WatchFailure.invalidStream }
        defer { receiving.withLock { $0 = false } }
        do {
            try Task.checkCancellation()
            let connection = connection
            let data = try await withTimeout(idleTimeout) {
                try await connection.receiveFrame(maximum: CompanionTerminalStream.maximumFrameBytes)
            }
            try Task.checkCancellation()
            let decoded = try CompanionTerminalStream.decode(data)
            return WatchPacket(frame: decoded.frame, generation: decoded.generation)
        } catch {
            connection.cancel()
            throw error
        }
    }

    func cancel() { connection.cancel() }
    deinit { connection.cancel() }
}

enum WatchFailure: Error, Equatable {
    case invalidStream
    case unsupportedStream
    case invalidDimensions
    case snapshotTooLarge
    case truncatedSnapshot
    case ended(CompanionTerminalStream.EndReason)
}

/// Validates one packet at a time without retaining terminal bytes or a replay queue.
struct WatchStream {
    typealias Stream = CompanionTerminalStream

    enum Event: Equatable {
        case reset(Stream.SnapshotBegin)
        case bytes(Data)
        case ready
        case grid(Stream.Grid)
        case leader(String?)
        case heartbeat
        case ack(UInt64)
    }

    private enum Phase { case awaitingSnapshot, snapshot, live }
    private var phase = Phase.awaitingSnapshot
    private(set) var generation: UInt32?
    private var nextSequence: UInt64 = 0
    private var snapshotBytes = 0
    private let paneID: UUID
    private let targetVersion: UUID
    private let capabilities: Stream.Capabilities
    private let role: Stream.Role

    init(paneID: UUID, targetVersion: UUID, capabilities: Stream.Capabilities, role: Stream.Role = .watch) throws {
        try Self.validate(capabilities)
        self.paneID = paneID
        self.targetVersion = targetVersion
        self.capabilities = capabilities
        self.role = role
    }

    static func validate(_ limits: Stream.Capabilities) throws {
        guard limits.version == Stream.version,
              (1...Stream.maximumDataBytes).contains(limits.maximumDataBytes),
              (1...Stream.maximumSnapshotBytes).contains(limits.maximumSnapshotBytes),
              limits.maximumPendingBytes > 0, limits.maximumStreamsPerDevice > 0,
              limits.maximumStreamsPerMac > 0,
              limits.inputFrameMax.map({ (1...Stream.maximumInputBytes).contains($0) }) ?? true,
              (1...15).contains(limits.heartbeatSeconds), limits.idleTimeoutSeconds == 45 else {
            throw WatchFailure.unsupportedStream
        }
    }

    static func validate(_ grid: Stream.Grid) throws {
        guard (1...Int(UInt16.max)).contains(grid.rows), (1...Int(UInt16.max)).contains(grid.cols),
              grid.rows * grid.cols <= 1_048_576 else { throw WatchFailure.invalidDimensions }
    }

    mutating func consume(_ packet: WatchPacket) throws -> Event {
        if case .snapshotBegin(let begin) = packet.frame {
            guard generation.map({ packet.generation > $0 }) ?? true,
                  UUID(uuidString: begin.paneID) == paneID,
                  UUID(uuidString: begin.targetVersion) == targetVersion,
                  begin.historyIncomplete,
                  (0...capabilities.maximumSnapshotBytes).contains(begin.scrollbackBound) else {
                throw WatchFailure.invalidStream
            }
            try Self.validate(begin.grid)
            generation = packet.generation
            phase = .snapshot
            nextSequence = 0
            snapshotBytes = 0
            return .reset(begin)
        }
        if case .ack = packet.frame, role == .interactive, let generation, packet.generation < generation { return .heartbeat }
        // A final end can precede snapshot_begin after the Mac advances its generation.
        if case .end(let end) = packet.frame {
            guard generation.map({ packet.generation >= $0 }) ?? true else { throw WatchFailure.invalidStream }
            throw WatchFailure.ended(end.reason)
        }
        guard generation == packet.generation, phase != .awaitingSnapshot else {
            throw WatchFailure.invalidStream
        }
        switch packet.frame {
        case .snapshot(_, let bytes):
            guard phase == .snapshot else { throw WatchFailure.invalidStream }
            try consumeBytes(packet.frame, bytes: bytes)
            guard bytes.count <= capabilities.maximumSnapshotBytes - snapshotBytes else {
                throw WatchFailure.snapshotTooLarge
            }
            snapshotBytes += bytes.count
            return .bytes(bytes)
        case .snapshotEnd(let end):
            guard phase == .snapshot else { throw WatchFailure.invalidStream }
            guard end.bytes == snapshotBytes else { throw WatchFailure.truncatedSnapshot }
            phase = .live
            return .ready
        case .output(_, let bytes):
            guard phase == .live else { throw WatchFailure.invalidStream }
            try consumeBytes(packet.frame, bytes: bytes)
            return .bytes(bytes)
        case .grid(let grid):
            try Self.validate(grid)
            return .grid(grid)
        case .leader(let leader): return .leader(leader.leader)
        case .heartbeat: return .heartbeat
        case .end(let end): throw WatchFailure.ended(end.reason)
        case .ack(let ack):
            guard role == .interactive, phase == .live else { throw WatchFailure.invalidStream }
            return .ack(ack.sequence)
        case .input, .claim, .phoneSent, .snapshotBegin: throw WatchFailure.invalidStream
        }
    }

    private mutating func consumeBytes(_ frame: Stream.Frame, bytes: Data) throws {
        let sequence: UInt64
        switch frame {
        case .snapshot(let value, _), .output(let value, _): sequence = value
        default: throw WatchFailure.invalidStream
        }
        guard sequence == nextSequence, sequence < UInt64.max,
              bytes.count <= capabilities.maximumDataBytes else { throw WatchFailure.invalidStream }
        nextSequence += 1
    }
}
