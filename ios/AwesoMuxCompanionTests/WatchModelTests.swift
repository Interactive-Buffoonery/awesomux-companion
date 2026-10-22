import AwesoMuxCompanionProtocol
import Foundation
import os
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class WatchModelTests: XCTestCase {
    private typealias Stream = CompanionTerminalStream

    func testLifecycleGatesAttachAndClearsImmediatelyOnInactiveLockAndDismissal() async throws {
        for reason in 0..<3 {
            let f = WatchModelFixture()
            let waiting = expectation(description: "live frame wait")
            let connection = f.connection(waiting: waiting, ignoreCancellation: true)
            f.open = { _ in connection }
            let model = f.model
            XCTAssertNil(model.start(record: f.record, paneID: f.paneID, targetVersion: f.targetVersion))
            XCTAssertEqual(f.openCount, 0)
            model.updateLifecycle(isActive: true, isUnlocked: true, isVisible: true)
            let task = model.start(record: f.record, paneID: f.paneID, targetVersion: f.targetVersion)
            await fulfillment(of: [waiting], timeout: 2)
            XCTAssertEqual(model.status, .live)
            XCTAssertTrue(model.historyIncomplete)
            XCTAssertEqual(f.renderer.bytes, Data([1, 2]))

            switch reason {
            case 0: model.updateLifecycle(isActive: false, isUnlocked: true, isVisible: true)
            case 1: model.updateLifecycle(isActive: true, isUnlocked: false, isVisible: true)
            default: model.stop()
            }
            XCTAssertTrue(connection.cancelled)
            XCTAssertTrue(f.renderer.bytes.isEmpty)
            XCTAssertNil(model.grid)
            XCTAssertEqual(model.status, .idle)
            // Deliberately release a cancellation-ignoring receive after the synchronous clear.
            connection.deliver(.init(frame: .output(sequence: 1, bytes: Data([9])), generation: 1))
            await task?.value
            XCTAssertTrue(f.renderer.bytes.isEmpty)
            XCTAssertEqual(model.status, .idle)
            model.stop()
        }
    }

    func testLiveAuthorityFenceDropsBytesBeforeDeferredLifecycleNotification() async {
        let f = WatchModelFixture()
        let waiting = expectation(description: "live authority wait")
        let connection = f.connection(waiting: waiting)
        f.open = { _ in connection }
        let task = f.start()
        await fulfillment(of: [waiting], timeout: 2)
        f.authorized = false
        connection.deliver(.init(frame: .output(sequence: 1, bytes: Data([9])), generation: 1))
        await task?.value
        XCTAssertTrue(connection.cancelled)
        XCTAssertTrue(f.renderer.bytes.isEmpty)
        XCTAssertEqual(f.model.status, .idle)
        f.model.stop()
    }

    func testLateAttachAfterDismissalIsCancelledWithoutRendererReset() async {
        let f = WatchModelFixture()
        let started = expectation(description: "attach pending")
        var finish: CheckedContinuation<any WatchConnection, Error>?
        f.open = { _ in
            try await withCheckedThrowingContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
        }
        let task = f.start()
        await fulfillment(of: [started], timeout: 2)
        f.model.stop()
        let stale = f.connection()
        finish?.resume(returning: stale)
        await task?.value
        XCTAssertTrue(stale.cancelled)
        XCTAssertEqual(f.renderer.resets, 0)
        XCTAssertTrue(f.renderer.bytes.isEmpty)
    }

    func testRoutesFallThroughForConnectionFailureButNotAPIDenial() async {
        let f = WatchModelFixture()
        let waiting = expectation(description: "tailscale live")
        let connection = f.connection(waiting: waiting)
        f.open = { route in
            if route.transport == .lan { throw MacClientFailure.unreachable }
            return connection
        }
        let task = f.start()
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(f.routes.map(\.transport), [.lan, .tailscale])
        XCTAssertEqual(f.model.activeRoute?.transport, .tailscale)
        f.model.stop()
        await task?.value

        let denied = WatchModelFixture()
        denied.open = { _ in throw MacClientFailure.api("denied") }
        await denied.start()?.value
        XCTAssertEqual(denied.routes.map(\.transport), [.lan])
        XCTAssertEqual(denied.model.status, .failed)
        XCTAssertNotNil(denied.model.error)
        XCTAssertTrue(denied.renderer.bytes.isEmpty)
        denied.model.stop()
    }

    func testGapClearsAndReconnectUsesFreshSnapshotWithSequenceZero() async {
        let f = WatchModelFixture()
        let firstWait = expectation(description: "first live")
        let nextWait = expectation(description: "fresh live")
        let retry = expectation(description: "retry delay")
        let first = f.connection(waiting: firstWait)
        let second = f.connection(waiting: nextWait, bytes: Data([7, 8]))
        var releaseRetry: CheckedContinuation<Void, Error>?
        f.sleep = { _ in
            try await withCheckedThrowingContinuation { continuation in
                releaseRetry = continuation
                retry.fulfill()
            }
        }
        f.open = { _ in f.openCount == 1 ? first : second }
        let task = f.start()
        await fulfillment(of: [firstWait], timeout: 2)
        first.deliver(.init(frame: .output(sequence: 8, bytes: Data([9])), generation: 1))
        await fulfillment(of: [retry], timeout: 2)
        XCTAssertTrue(first.cancelled)
        XCTAssertTrue(f.renderer.bytes.isEmpty)
        XCTAssertEqual(f.model.status, .failed)
        XCTAssertNotNil(f.model.error)
        releaseRetry?.resume()
        await fulfillment(of: [nextWait], timeout: 2)
        XCTAssertEqual(f.model.status, .live)
        XCTAssertEqual(f.renderer.bytes, Data([7, 8]))
        XCTAssertEqual(f.renderer.resets, 2)
        XCTAssertTrue(f.model.historyIncomplete)
        XCTAssertEqual(f.routes.map(\.transport), [.lan, .tailscale])
        f.model.stop()
        await task?.value
    }

    func testRendererSyncAndDelayedFailuresCancelClearAndSurfaceSafeError() async {
        for delayed in [false, true] {
            let f = WatchModelFixture()
            let waiting = delayed ? expectation(description: "renderer live") : nil
            let connection = f.connection(waiting: waiting)
            f.open = { _ in connection }
            f.renderer.failOnFeed = !delayed
            let task = f.start()
            if let waiting {
                await fulfillment(of: [waiting], timeout: 2)
                f.model.rendererFailed(WatchFailure.invalidDimensions)
            }
            await task?.value
            XCTAssertTrue(connection.cancelled)
            XCTAssertTrue(f.renderer.bytes.isEmpty)
            XCTAssertNil(f.model.grid)
            XCTAssertEqual(f.model.status, .failed)
            XCTAssertNotNil(f.model.error)
            XCTAssertEqual(f.openCount, 1)
            f.model.stop()
        }
    }

    func testRevocationClearsWithoutRetryAndFreshResumeDoesNotReuseTerminalBytes() async {
        let f = WatchModelFixture()
        let waiting = expectation(description: "before revocation")
        let first = f.connection(waiting: waiting)
        f.open = { _ in first }
        let task = f.start()
        await fulfillment(of: [waiting], timeout: 2)
        first.deliver(.init(frame: .end(.init(reason: .revoked)), generation: 1))
        await task?.value
        XCTAssertTrue(first.cancelled)
        XCTAssertTrue(f.renderer.bytes.isEmpty)
        XCTAssertEqual(f.model.status, .failed)
        XCTAssertEqual(f.openCount, 1)
        f.model.stop()
    }
}

@MainActor
private final class WatchModelFixture {
    let paneID = UUID()
    let targetVersion = UUID()
    let renderer = WatchTestRenderer()
    var authorized = true
    var routes: [CompanionRoute] = []
    var openCount = 0
    var open: @MainActor (CompanionRoute) async throws -> any WatchConnection = { _ in throw MacClientFailure.unreachable }
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    let record = PairingRecord(macName: "Mac", host: nil, port: 1234, macFingerprint: "same-pin",
        transport: nil, routes: [.init(transport: .lan, host: "192.168.1.2"), .init(transport: .tailscale, host: "100.64.1.2")],
        connectionID: UUID(), identityTag: "test-identity", identityStorage: .keychain, pairedAt: .now)
    lazy var model = makeModel()

    private func makeModel() -> WatchModel {
        WatchModel(renderer: renderer, canWatch: { [unowned self] in authorized },
            makeClient: { [unowned self] _, route in
                routes.append(route)
                return WatchTestClient { [unowned self] canSend in
                    guard canSend() else { throw CancellationError() }
                    openCount += 1
                    return try await open(route)
                }
            }, sleep: { [unowned self] in try await sleep($0) })
    }

    func start() -> Task<Void, Never>? {
        model.updateLifecycle(isActive: true, isUnlocked: true, isVisible: true)
        return model.start(record: record, paneID: paneID, targetVersion: targetVersion)
    }

    func connection(waiting: XCTestExpectation? = nil, ignoreCancellation: Bool = false,
                    bytes: Data = Data([1, 2])) -> WatchTestConnection {
        let begin = CompanionTerminalStream.SnapshotBegin(paneID: paneID.uuidString,
            targetVersion: targetVersion.uuidString, grid: .init(rows: 24, cols: 80), leader: nil,
            scrollbackBound: CompanionTerminalStream.maximumSnapshotBytes)
        return WatchTestConnection(packets: [.init(frame: .snapshotBegin(begin), generation: 1),
            .init(frame: .snapshot(sequence: 0, bytes: bytes), generation: 1),
            .init(frame: .snapshotEnd(.init(bytes: bytes.count)), generation: 1)],
            waiting: waiting, ignoreCancellation: ignoreCancellation)
    }
}

private struct WatchTestClient: WatchClient {
    let open: @MainActor @Sendable (@MainActor @Sendable () -> Bool) async throws -> any WatchConnection

    func openWatch(connectionID: UUID, paneID: UUID, targetVersion: UUID,
                   canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> any WatchConnection {
        try await open(canSend)
    }
}

@MainActor
private final class WatchTestRenderer: WatchRendering {
    var bytes = Data()
    var resets = 0
    var failOnFeed = false
    func reset(grid: CompanionTerminalStream.Grid, scrollbackBound: Int) throws { bytes = Data(); resets += 1 }
    func feed(_ bytes: Data) throws {
        if failOnFeed { throw WatchFailure.invalidDimensions }
        self.bytes.append(bytes)
    }
    func resize(_ grid: CompanionTerminalStream.Grid) throws {}
    func clear() { bytes = Data() }
}

private final class WatchTestConnection: WatchConnection, Sendable {
    let capabilities = CompanionTerminalStream.Capabilities()
    private struct State {
        var packets: [WatchPacket]
        var waiter: CheckedContinuation<WatchPacket, Error>?
        var cancelled = false
    }
    private let state: OSAllocatedUnfairLock<State>
    private let waiting: XCTestExpectation?
    private let ignoreCancellation: Bool
    var cancelled: Bool { state.withLock { $0.cancelled } }

    init(packets: [WatchPacket], waiting: XCTestExpectation?, ignoreCancellation: Bool) {
        state = OSAllocatedUnfairLock(initialState: State(packets: packets))
        self.waiting = waiting
        self.ignoreCancellation = ignoreCancellation
    }

    func receive() async throws -> WatchPacket {
        try await withCheckedThrowingContinuation { continuation in
            let pending = state.withLock { value in
                if value.cancelled && !ignoreCancellation { continuation.resume(throwing: CancellationError()); return false }
                if !value.packets.isEmpty { continuation.resume(returning: value.packets.removeFirst()); return false }
                value.waiter = continuation
                return true
            }
            if pending { waiting?.fulfill() }
        }
    }

    func deliver(_ packet: WatchPacket) {
        let waiter = state.withLock { value in
            let waiter = value.waiter
            value.waiter = nil
            if waiter == nil { value.packets.append(packet) }
            return waiter
        }
        waiter?.resume(returning: packet)
    }

    func cancel() {
        let waiter = state.withLock { value in
            value.cancelled = true
            guard !ignoreCancellation else { return nil as CheckedContinuation<WatchPacket, Error>? }
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: CancellationError())
    }
}
