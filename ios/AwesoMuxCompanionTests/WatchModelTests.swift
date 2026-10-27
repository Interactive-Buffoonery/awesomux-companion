import AwesoMuxCompanionProtocol
import Foundation
import os
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class WatchModelTests: XCTestCase {
    private typealias Stream = CompanionTerminalStream

    func testSnapshotCompletionTakesOverOnlyWithTheInputGrant() async {
        for allowed in [false, true] {
            let f = WatchModelFixture()
            f.inputAllowed = allowed
            let waiting = expectation(description: "snapshot completed")
            let connection = f.connection(waiting: waiting, role: .interactive)
            f.open = { _ in connection }
            let task = f.start()
            await fulfillment(of: [waiting], timeout: 2)
            for _ in 0..<100 { await Task.yield() }
            XCTAssertTrue(connection.sent.isEmpty)
            f.model.updatePhoneGrid(.init(rows: 31, cols: 43))
            for _ in 0..<100 { await Task.yield() }
            if allowed {
                XCTAssertEqual(connection.sent.map(\.frame), [.claim(.init(grid: .init(rows: 31, cols: 43)))])
            } else {
                XCTAssertTrue(connection.sent.isEmpty)
            }
            f.model.stop()
            await task?.value
        }
    }

    func testMissingInputGrantBlocksManualWritesOnInteractiveStream() async {
        let f = WatchModelFixture()
        let waiting = expectation(description: "snapshot completed")
        let connection = f.connection(waiting: waiting, role: .interactive)
        f.open = { _ in connection }
        let task = f.start()
        await fulfillment(of: [waiting], timeout: 2)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(f.model.input.canType)
        f.model.input.takeOver()
        f.model.input.type(Data("a".utf8))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(connection.sent.isEmpty)
        f.model.updatePhoneGrid(.init(rows: 24, cols: 80))
        f.inputAllowed = true
        XCTAssertTrue(f.model.input.canType)
        f.model.stop()
        await task?.value
    }

    func testFreshForegroundGrantAfterSnapshotAppliesOpeningOnlyOnce() async {
        let f = WatchModelFixture()
        let waiting = expectation(description: "snapshot before permission refresh")
        let connection = f.connection(waiting: waiting, role: .interactive)
        f.open = { _ in connection }
        let task = f.start()
        await fulfillment(of: [waiting], timeout: 2)
        f.model.updatePhoneGrid(.init(rows: 24, cols: 80))
        XCTAssertTrue(connection.sent.isEmpty)
        f.inputAllowed = true
        f.model.updateInputPermission()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(connection.sent.count, 1)
        f.model.updateInputPermission()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(connection.sent.count, 1)
        f.model.stop()
        await task?.value
    }

    func testReconnectDoesNotReapplyInputOpening() async {
        let f = WatchModelFixture()
        f.inputAllowed = true
        let firstWait = expectation(description: "first live")
        let nextWait = expectation(description: "fresh live")
        let first = f.connection(waiting: firstWait, role: .interactive)
        let second = f.connection(waiting: nextWait, role: .interactive)
        f.sleep = { _ in }
        f.open = { _ in f.openCount == 1 ? first : second }
        let task = f.start()
        await fulfillment(of: [firstWait], timeout: 2)
        for _ in 0..<100 { await Task.yield() }
        f.model.updatePhoneGrid(.init(rows: 24, cols: 80))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(first.sent.count, 1)
        first.deliver(.init(frame: .output(sequence: 8, bytes: Data([9])), generation: 1))
        await fulfillment(of: [nextWait], timeout: 2)
        for _ in 0..<100 { await Task.yield() }
        f.model.updatePhoneGrid(.init(rows: 24, cols: 80))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(second.sent.isEmpty)
        f.model.stop()
        await task?.value
    }

    func testMacOpeningRefusalLeavesVisibleReasonWithoutRetrying() async {
        for code in ["pane_exited", "pane_disconnected", "terminal_unavailable", "stale_target", "timeout"] {
            let f = WatchModelFixture()
            f.open = { _ in throw MacClientFailure.api(code) }
            let task = f.start()
            await task?.value
            XCTAssertEqual(f.model.status, .failed)
            XCTAssertEqual(f.model.error, WatchModel.message(for: MacClientFailure.api(code)))
            XCTAssertFalse(f.model.error?.isEmpty ?? true)
            XCTAssertEqual(f.openCount, 1)
            f.model.stop()
        }
    }

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

    func testNativeBusyResetReattachesWithFreshSnapshotAndCanStop() async {
        let f = WatchModelFixture()
        let retry = expectation(description: "native busy backoff")
        let live = expectation(description: "fresh snapshot live")
        let first = f.connection(bytes: Data([1, 2]))
        let second = f.connection(waiting: live, bytes: Data([7, 8]))
        var releaseRetry: CheckedContinuation<Void, Error>?
        f.sleep = { delay in
            XCTAssertEqual(delay, .seconds(1))
            try await withCheckedThrowingContinuation { continuation in
                releaseRetry = continuation
                retry.fulfill()
            }
        }
        f.renderer.busyResetsRemaining = 1
        f.open = { _ in f.openCount == 1 ? first : second }
        let task = f.start()
        await fulfillment(of: [retry], timeout: 2)
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(f.openCount, 1)
        XCTAssertEqual(f.renderer.resets, 1)
        XCTAssertTrue(f.renderer.bytes.isEmpty)
        XCTAssertNil(f.model.grid)
        XCTAssertNil(f.model.activeRoute)

        releaseRetry?.resume()
        await fulfillment(of: [live], timeout: 2)
        XCTAssertEqual(f.openCount, 2)
        XCTAssertEqual(f.renderer.resets, 2)
        XCTAssertEqual(f.renderer.bytes, Data([7, 8]))
        XCTAssertEqual(f.model.status, .live)
        XCTAssertNil(f.model.error)
        XCTAssertEqual(f.routes.map(\.transport), [.lan, .lan])
        f.model.stop()
        await task?.value
        XCTAssertTrue(second.cancelled)
        XCTAssertTrue(f.renderer.bytes.isEmpty)
        XCTAssertEqual(f.model.status, .idle)
    }

    func testStopDuringNativeBusyBackoffPreventsAnotherAttach() async {
        let f = WatchModelFixture()
        let retry = expectation(description: "native busy cancellation wait")
        let first = f.connection()
        var releaseRetry: CheckedContinuation<Void, Error>?
        f.sleep = { _ in
            try await withCheckedThrowingContinuation { continuation in
                releaseRetry = continuation
                retry.fulfill()
            }
        }
        f.renderer.busyResetsRemaining = 1
        f.open = { _ in first }
        let task = f.start()
        await fulfillment(of: [retry], timeout: 2)
        f.model.stop()
        // Even a cancellation-ignoring sleeper cannot revive the old epoch.
        releaseRetry?.resume()
        await task?.value
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(f.openCount, 1)
        XCTAssertEqual(f.renderer.resets, 1)
        XCTAssertTrue(f.renderer.bytes.isEmpty)
        XCTAssertNil(f.model.grid)
        XCTAssertEqual(f.model.status, .idle)
    }

    func testTransientRendererThrowsAndCallbacksClearThenAttachFreshSnapshot() async {
        for failure in [WatchTerminalFailure.overflow, .readinessTimeout, .drainTimeout] {
            for mode in 0..<3 {
                let delayed = mode == 2
                let f = WatchModelFixture()
                let firstLive = delayed ? expectation(description: "before renderer callback") : nil
                let freshLive = expectation(description: "fresh renderer snapshot")
                let retry = expectation(description: "renderer failure backoff")
                let first = f.connection(waiting: firstLive)
                let second = f.connection(waiting: freshLive, bytes: Data([7, 8]))
                var releaseRetry: CheckedContinuation<Void, Error>?
                f.sleep = { delay in
                    XCTAssertEqual(delay, .seconds(1))
                    try await withCheckedThrowingContinuation { continuation in
                        releaseRetry = continuation
                        retry.fulfill()
                    }
                }
                if !delayed { f.renderer.feedFailure = failure }
                if mode == 1 {
                    f.renderer.onFailure = { [weak model = f.model] in model?.rendererFailed($0) }
                }
                f.open = { _ in f.openCount == 1 ? first : second }
                let task = f.start()
                if let firstLive {
                    await fulfillment(of: [firstLive], timeout: 2)
                    f.model.rendererFailed(failure)
                    XCTAssertTrue(first.cancelled)
                    XCTAssertTrue(f.renderer.bytes.isEmpty)
                    XCTAssertNil(f.model.grid)
                }
                await fulfillment(of: [retry], timeout: 2)
                let retryTask = f.model.start(record: f.record, paneID: f.paneID, targetVersion: f.targetVersion)
                XCTAssertTrue(first.cancelled)
                XCTAssertTrue(f.renderer.bytes.isEmpty)
                XCTAssertNil(f.model.grid)
                XCTAssertEqual(f.model.status, .failed)
                XCTAssertEqual(f.openCount, 1)
                f.renderer.feedFailure = nil
                releaseRetry?.resume()
                await fulfillment(of: [freshLive], timeout: 2)
                XCTAssertEqual(f.openCount, 2)
                XCTAssertEqual(f.renderer.bytes, Data([7, 8]))
                XCTAssertEqual(f.model.status, .live)
                XCTAssertEqual(f.routes.map(\.transport), [.lan, .lan])
                f.model.stop()
                await task?.value
                await retryTask?.value
                XCTAssertTrue(second.cancelled)
            }
        }
    }

    func testTransientRendererRetryRechecksAuthorityAfterBackoff() async {
        let f = WatchModelFixture()
        let live = expectation(description: "before authority loss")
        let retry = expectation(description: "authority retry wait")
        let connection = f.connection(waiting: live)
        var releaseRetry: CheckedContinuation<Void, Error>?
        f.sleep = { _ in
            try await withCheckedThrowingContinuation { continuation in
                releaseRetry = continuation
                retry.fulfill()
            }
        }
        f.open = { _ in connection }
        let task = f.start()
        await fulfillment(of: [live], timeout: 2)
        f.model.rendererFailed(WatchTerminalFailure.drainTimeout)
        await fulfillment(of: [retry], timeout: 2)
        let retryTask = f.model.start(record: f.record, paneID: f.paneID, targetVersion: f.targetVersion)
        f.authorized = false
        releaseRetry?.resume()
        await task?.value
        await retryTask?.value
        XCTAssertTrue(connection.cancelled)
        XCTAssertEqual(f.openCount, 1)
        XCTAssertTrue(f.renderer.bytes.isEmpty)
        XCTAssertNil(f.model.grid)
        XCTAssertEqual(f.model.status, .idle)
        f.model.stop()
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
    var inputAllowed = false
    var routes: [CompanionRoute] = []
    var openCount = 0
    var open: @MainActor (CompanionRoute) async throws -> any WatchConnection = { _ in throw MacClientFailure.unreachable }
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    let record = PairingRecord(macName: "Mac", host: nil, port: 1234, macFingerprint: "same-pin",
        transport: nil, routes: [.init(transport: .lan, host: "192.168.1.2"), .init(transport: .tailscale, host: "100.64.1.2")],
        connectionID: UUID(), identityTag: "test-identity", identityStorage: .keychain, pairedAt: .now)
    lazy var model = makeModel()

    private func makeModel() -> WatchModel {
        WatchModel(renderer: renderer, canInput: { [unowned self] in inputAllowed }, canWatch: { [unowned self] in authorized },
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
                    bytes: Data = Data([1, 2]), role: CompanionTerminalStream.Role = .watch) -> WatchTestConnection {
        let begin = CompanionTerminalStream.SnapshotBegin(paneID: paneID.uuidString,
            targetVersion: targetVersion.uuidString, grid: .init(rows: 24, cols: 80), leader: nil,
            scrollbackBound: CompanionTerminalStream.maximumSnapshotBytes)
        return WatchTestConnection(packets: [.init(frame: .snapshotBegin(begin), generation: 1),
            .init(frame: .snapshot(sequence: 0, bytes: bytes), generation: 1),
            .init(frame: .snapshotEnd(.init(bytes: bytes.count)), generation: 1)],
            waiting: waiting, ignoreCancellation: ignoreCancellation, role: role)
    }
}

private struct WatchTestClient: WatchClient {
    let open: @MainActor @Sendable (@MainActor @Sendable () -> Bool) async throws -> any WatchConnection

    func openWatch(connectionID: UUID, paneID: UUID, targetVersion: UUID,
                   preferredGrid: CompanionTerminalStream.Grid,
                   canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> any WatchConnection {
        try await open(canSend)
    }
}

@MainActor
private final class WatchTestRenderer: WatchRendering {
    var bytes = Data()
    var resets = 0
    var failOnFeed = false
    var feedFailure: WatchTerminalFailure?
    var onFailure: ((Error) -> Void)?
    var busyResetsRemaining = 0
    func reset(scrollbackBound: Int) throws {
        bytes = Data()
        resets += 1
        if busyResetsRemaining > 0 {
            busyResetsRemaining -= 1
            throw WatchTerminalFailure.nativeBusy
        }
    }
    func feed(_ bytes: Data) throws {
        if let feedFailure {
            onFailure?(feedFailure)
            throw feedFailure
        }
        if failOnFeed { throw WatchFailure.invalidDimensions }
        self.bytes.append(bytes)
    }
    func clear() { bytes = Data() }
}

private final class WatchTestConnection: WatchConnection, @unchecked Sendable {
    let capabilities = CompanionTerminalStream.Capabilities()
    let accepted: CompanionTerminalStream.Accepted
    @MainActor var sent: [WatchPacket] = []
    @MainActor func send(_ frame: CompanionTerminalStream.Frame, generation: UInt32,
                         canSend: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard canSend() else { throw CancellationError() }
        sent.append(.init(frame: frame, generation: generation))
    }
    private struct State {
        var packets: [WatchPacket]
        var waiter: CheckedContinuation<WatchPacket, Error>?
        var cancelled = false
    }
    private let state: OSAllocatedUnfairLock<State>
    private let waiting: XCTestExpectation?
    private let ignoreCancellation: Bool
    var cancelled: Bool { state.withLock { $0.cancelled } }

    init(packets: [WatchPacket], waiting: XCTestExpectation?, ignoreCancellation: Bool,
         role: CompanionTerminalStream.Role = .watch) {
        accepted = .init(role: role)
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
