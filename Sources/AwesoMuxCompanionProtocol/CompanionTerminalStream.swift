import Foundation

/// The live terminal stream from awesoMux ADR-0040. After an accepted
/// `watch_terminal` reply the same connection carries these frames, each
/// inside the usual four-byte big-endian length prefix (`CompanionFrame`).
///
/// Wire layout of one frame payload:
/// - byte 0: `FrameType`
/// - bytes 1...4: generation ID, big-endian
/// - control frames: UTF-8 JSON
/// - data frames: eight-byte big-endian sequence number, then raw terminal bytes
///
/// The version changes only for an incompatible frame layout. Unknown JSON
/// fields are ignored; an unknown frame type ends the stream.
public enum CompanionTerminalStream {
    public static let version = 1
    public static let maximumPendingBytes = 4 * 1024 * 1024
    public static let maximumDataBytes = 64 * 1024
    public static let maximumSnapshotBytes = 8 * 1024 * 1024
    public static let heartbeatSeconds: TimeInterval = 15
    public static let idleTimeoutSeconds: TimeInterval = 45
    public static let maximumStreamsPerDevice = 2
    public static let maximumStreamsPerMac = 4
    public static let headerBytes = 5
    public static let sequenceBytes = 8
    /// Largest framed payload either side will accept.
    public static let maximumFrameBytes = headerBytes + sequenceBytes + maximumDataBytes

    public enum FrameType: UInt8, Sendable {
        case snapshotBegin = 1
        case snapshot = 2
        case snapshotEnd = 3
        case output = 4
        case grid = 5
        case leader = 6
        case heartbeat = 7
        case end = 8
        case input = 16
        case reply = 17
        case claim = 18
        case ack = 19

        public var isData: Bool {
            switch self {
            case .snapshot, .output, .input, .reply: true
            default: false
            }
        }
    }

    public enum Role: String, Codable, Sendable {
        case watch
        case interactive
    }

    public enum EndReason: String, Codable, Sendable {
        case closed
        case superseded
        case revoked
        case paneUnavailable = "pane_unavailable"
        case sessionEnded = "session_ended"
        case roleChanged = "role_changed"
        case protocolError = "protocol_error"
        case overflow
    }

    public struct Grid: Codable, Equatable, Sendable {
        public let rows: Int
        public let cols: Int

        public init(rows: Int, cols: Int) {
            self.rows = rows
            self.cols = cols
        }
    }

    /// Advertised with the accepted handshake and on connection status.
    public struct Capabilities: Codable, Equatable, Sendable {
        public let version: Int
        public let maximumDataBytes: Int
        public let maximumPendingBytes: Int
        public let maximumSnapshotBytes: Int
        public let heartbeatSeconds: Int
        public let idleTimeoutSeconds: Int
        public let maximumStreamsPerDevice: Int
        public let maximumStreamsPerMac: Int

        public init() {
            version = CompanionTerminalStream.version
            maximumDataBytes = CompanionTerminalStream.maximumDataBytes
            maximumPendingBytes = CompanionTerminalStream.maximumPendingBytes
            maximumSnapshotBytes = CompanionTerminalStream.maximumSnapshotBytes
            heartbeatSeconds = Int(CompanionTerminalStream.heartbeatSeconds)
            idleTimeoutSeconds = Int(CompanionTerminalStream.idleTimeoutSeconds)
            maximumStreamsPerDevice = CompanionTerminalStream.maximumStreamsPerDevice
            maximumStreamsPerMac = CompanionTerminalStream.maximumStreamsPerMac
        }
    }

    /// The `watch_terminal` success reply body.
    public struct Accepted: Codable, Equatable, Sendable {
        public let role: Role
        public let streamVersion: Int

        public init(role: Role, streamVersion: Int = CompanionTerminalStream.version) {
            self.role = role
            self.streamVersion = streamVersion
        }
    }

    public struct SnapshotBegin: Codable, Equatable, Sendable {
        public let paneID: String
        public let targetVersion: String
        public let grid: Grid
        /// Daemon attachment ID of the current leader; nil when nobody leads.
        public let leader: String?
        public let historyIncomplete: Bool
        public let scrollbackBound: Int

        public init(paneID: String, targetVersion: String, grid: Grid, leader: String?, scrollbackBound: Int) {
            self.paneID = paneID
            self.targetVersion = targetVersion
            self.grid = grid
            self.leader = leader
            historyIncomplete = true
            self.scrollbackBound = scrollbackBound
        }

        /// `leader` is always present so phones can distinguish "nobody leads" from an older Mac.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(targetVersion, forKey: .targetVersion)
            try container.encode(grid, forKey: .grid)
            try container.encode(leader, forKey: .leader)
            try container.encode(historyIncomplete, forKey: .historyIncomplete)
            try container.encode(scrollbackBound, forKey: .scrollbackBound)
        }
    }

    public struct SnapshotEnd: Codable, Equatable, Sendable {
        public let bytes: Int

        public init(bytes: Int) { self.bytes = bytes }
    }

    public struct Leader: Codable, Equatable, Sendable {
        public let leader: String?

        public init(leader: String?) { self.leader = leader }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(leader, forKey: .leader)
        }
    }

    public struct End: Codable, Equatable, Sendable {
        public let reason: EndReason

        public init(reason: EndReason) { self.reason = reason }
    }

    public enum Frame: Equatable, Sendable {
        case snapshotBegin(SnapshotBegin)
        case snapshot(sequence: UInt64, bytes: Data)
        case snapshotEnd(SnapshotEnd)
        case output(sequence: UInt64, bytes: Data)
        case grid(Grid)
        case leader(Leader)
        case heartbeat
        case end(End)
        /// Phone-sent frames. A Watch stream never carries them; the Mac
        /// recognizes the type only to end the stream as a protocol error.
        case phoneSent(FrameType)

        public var type: FrameType {
            switch self {
            case .snapshotBegin: .snapshotBegin
            case .snapshot: .snapshot
            case .snapshotEnd: .snapshotEnd
            case .output: .output
            case .grid: .grid
            case .leader: .leader
            case .heartbeat: .heartbeat
            case .end: .end
            case .phoneSent(let type): type
            }
        }
    }

    public enum Failure: Error, Equatable {
        case tooShort
        case unknownType(UInt8)
        case tooLarge
        case invalidControl
    }

    public static func encode(_ frame: Frame, generation: UInt32) throws -> Data {
        var data = Data([frame.type.rawValue])
        data.append(contentsOf: withUnsafeBytes(of: generation.bigEndian, Array.init))
        func control<T: Encodable>(_ value: T) throws {
            data.append(try CompanionProtocol.encoder().encode(value))
        }
        func payload(_ sequence: UInt64, _ bytes: Data) throws {
            guard bytes.count <= maximumDataBytes else { throw Failure.tooLarge }
            data.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian, Array.init))
            data.append(bytes)
        }
        switch frame {
        case .snapshotBegin(let value): try control(value)
        case .snapshot(let sequence, let bytes): try payload(sequence, bytes)
        case .snapshotEnd(let value): try control(value)
        case .output(let sequence, let bytes): try payload(sequence, bytes)
        case .grid(let value): try control(value)
        case .leader(let value): try control(value)
        case .heartbeat: data.append(contentsOf: Data("{}".utf8))
        case .end(let value): try control(value)
        case .phoneSent: throw Failure.invalidControl
        }
        guard data.count <= maximumFrameBytes else { throw Failure.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> (frame: Frame, generation: UInt32) {
        guard data.count >= headerBytes else { throw Failure.tooShort }
        guard data.count <= maximumFrameBytes else { throw Failure.tooLarge }
        let bytes = [UInt8](data)
        guard let type = FrameType(rawValue: bytes[0]) else { throw Failure.unknownType(bytes[0]) }
        let generation = bytes[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let body = data.dropFirst(headerBytes)
        func control<T: Decodable>(_ kind: T.Type) throws -> T {
            guard let value = try? CompanionProtocol.decoder().decode(kind, from: Data(body)) else { throw Failure.invalidControl }
            return value
        }
        func payload() throws -> (UInt64, Data) {
            guard body.count >= sequenceBytes else { throw Failure.tooShort }
            let sequence = body.prefix(sequenceBytes).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return (sequence, Data(body.dropFirst(sequenceBytes)))
        }
        let frame: Frame
        switch type {
        case .snapshotBegin: frame = .snapshotBegin(try control(SnapshotBegin.self))
        case .snapshot:
            let (sequence, bytes) = try payload()
            frame = .snapshot(sequence: sequence, bytes: bytes)
        case .snapshotEnd: frame = .snapshotEnd(try control(SnapshotEnd.self))
        case .output:
            let (sequence, bytes) = try payload()
            frame = .output(sequence: sequence, bytes: bytes)
        case .grid: frame = .grid(try control(Grid.self))
        case .leader: frame = .leader(try control(Leader.self))
        case .heartbeat: frame = .heartbeat
        case .end: frame = .end(try control(End.self))
        case .input, .reply, .claim, .ack: frame = .phoneSent(type)
        }
        return (frame, generation)
    }
}
