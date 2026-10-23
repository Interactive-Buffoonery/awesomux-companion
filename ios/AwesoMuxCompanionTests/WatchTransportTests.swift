import AwesoMuxCompanionProtocol
import Foundation
import os
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class WatchTransportTests: XCTestCase {
    private typealias Stream = CompanionTerminalStream

    func testWatchRequestContainsOnlyAttachFieldsAndNeverInputOrResizeFrames() throws {
        let request = MacClient.watchRequest(connectionID: UUID(), paneID: UUID(), targetVersion: UUID())
        let encoded = try CompanionProtocol.encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "requestID", "operation", "connectionID",
                                         "paneID", "targetVersion", "streamVersion", "grid"])
        XCTAssertEqual(request.operation, "watch_terminal")
        XCTAssertEqual(request.streamVersion, 1)
        XCTAssertEqual(try MacClient.frameRequest(encoded).dropFirst(4), encoded)
    }

    func testAcceptedHandshakeKeepsSameConnectionForBoundedSequentialFrames() async throws {
        let request = MacClient.watchRequest(connectionID: UUID(), paneID: UUID(), targetVersion: UUID())
        let response = APIResponse(requestID: request.requestID, terminalStreamAccepted: .init(role: .watch))
        let frame = try Stream.encode(.heartbeat, generation: 4)
        let wire = WatchTestWire(replies: [try CompanionProtocol.encoder().encode(response), frame])
        let opened = try await MacClient.openWatch(connection: wire, request: request, capabilities: .init())
        let packet = try await opened.receive()
        XCTAssertEqual(packet.frame, .heartbeat)
        XCTAssertEqual(packet.generation, 4)
        XCTAssertEqual(wire.sent.count, 1)
        XCTAssertEqual(wire.maximums, [CompanionProtocol.maximumResponseBytes, Stream.maximumFrameBytes])
        XCTAssertFalse(wire.cancelled)
        opened.cancel()
        XCTAssertTrue(wire.cancelled)
    }

    func testRejectsWrongEnvelopeMissingAcceptanceAndDenial() async throws {
        let request = MacClient.watchRequest(connectionID: UUID(), paneID: UUID(), targetVersion: UUID())
        let responses = [
            APIResponse(schemaVersion: 2, requestID: request.requestID, terminalStream: .init(), terminalStreamAccepted: .init(role: .watch)),
            APIResponse(requestID: UUID(), terminalStream: .init(), terminalStreamAccepted: .init(role: .watch)),
            APIResponse(requestID: request.requestID, terminalStream: .init()),
            APIResponse(requestID: request.requestID, error: "denied")
        ]
        for response in responses {
            let wire = WatchTestWire(replies: [try CompanionProtocol.encoder().encode(response)])
            do {
                _ = try await MacClient.openWatch(connection: wire, request: request, capabilities: .init())
                XCTFail("Invalid Watch acceptance must close the connection")
            } catch {
                XCTAssertTrue(wire.cancelled)
            }
        }
    }

    func testAuthorityIsRecheckedAtActualHandshakeSendAndAfterReply() async throws {
        let request = MacClient.watchRequest(connectionID: UUID(), paneID: UUID(), targetVersion: UUID())
        let response = APIResponse(requestID: request.requestID, terminalStream: .init(),
                                   terminalStreamAccepted: .init(role: .watch))
        for allowedAtSend in [false, true] {
            let wire = WatchTestWire(replies: [try CompanionProtocol.encoder().encode(response)])
            var calls = 0
            do {
                _ = try await MacClient.openWatch(connection: wire, request: request, capabilities: .init(), canSend: {
                    calls += 1
                    return allowedAtSend && calls == 1
                })
                XCTFail("Lost authority must reject the attach")
            } catch is CancellationError {
                XCTAssertTrue(wire.cancelled)
                XCTAssertEqual(wire.sent.count, allowedAtSend ? 1 : 0)
            }
        }
    }

    func testInteractiveHandshakePreservesWatchReasonAndSendsOnlyUserFrames() async throws {
        let request = MacClient.watchRequest(connectionID: UUID(), paneID: UUID(), targetVersion: UUID(),
                                             preferredGrid: .init(rows: 20, cols: 38))
        XCTAssertEqual(request.grid, .init(rows: 20, cols: 38))
        let response = APIResponse(requestID: request.requestID, terminalStreamAccepted: .init(role: .interactive))
        let wire = WatchTestWire(replies: [try CompanionProtocol.encoder().encode(response)])
        let opened = try await MacClient.openWatch(connection: wire, request: request, capabilities: .init())
        XCTAssertEqual(opened.accepted.role, .interactive)
        try await opened.send(.grid(.init(rows: 20, cols: 38)), generation: 8, canSend: { true })
        try await opened.send(.input(sequence: 0, bytes: Data([3])), generation: 8, canSend: { true })
        XCTAssertEqual(try Stream.decode(wire.sent[2]).frame, .input(sequence: 0, bytes: Data([3])))
        XCTAssertEqual(try Stream.decode(wire.sent[2]).generation, 8)
        do {
            try await opened.send(.heartbeat, generation: 8, canSend: { true })
            XCTFail("Only input, grid and claim may be sent")
        } catch {}
        do {
            try await opened.send(.input(sequence: 1, bytes: Data([4])), generation: 8, canSend: { false })
            XCTFail("Authority is checked at the wire send")
        } catch {}
        XCTAssertEqual(wire.sent.count, 3)
        opened.cancel()
    }

    func testWatchWithReasonAcceptsHandshakeButRejectsAllInput() async throws {
        let request = MacClient.watchRequest(connectionID: UUID(), paneID: UUID(), targetVersion: UUID())
        let response = APIResponse(requestID: request.requestID,
                                   terminalStreamAccepted: .init(role: .watch, watchReason: .inputOff))
        let wire = WatchTestWire(replies: [try CompanionProtocol.encoder().encode(response)])
        let opened = try await MacClient.openWatch(connection: wire, request: request, capabilities: .init())
        XCTAssertEqual(opened.accepted.watchReason, .inputOff)
        do {
            try await opened.send(.claim(.init(grid: .init(rows: 20, cols: 38))), generation: 8, canSend: { true })
            XCTFail("Watch must not write interactive frames")
        } catch {}
        XCTAssertEqual(wire.sent.count, 1)
        opened.cancel()
    }

    func testMalformedFrameClosesConnectionAndConcurrentReceiveIsRejected() async throws {
        let malformed = WatchTestWire(replies: [Data([255, 0, 0, 0, 1])])
        let opened = MacWatchConnection(connection: malformed, capabilities: .init())
        do { _ = try await opened.receive(); XCTFail("Unknown frame type must fail") }
        catch { XCTAssertTrue(malformed.cancelled) }

        let started = expectation(description: "first receive")
        let waiting = WatchTestWire(started: started)
        let serial = MacWatchConnection(connection: waiting, capabilities: .init())
        let first = Task { try await serial.receive() }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await serial.receive(); XCTFail("Concurrent receive must fail") }
        catch { XCTAssertEqual(error as? WatchFailure, .invalidStream) }
        serial.cancel()
        _ = await first.result
        XCTAssertTrue(waiting.cancelled)
    }

    func testReceiveDeadlineCancelsPendingReadAndTaskCancellationClosesSocket() async {
        for timeout in [true, false] {
            let started = expectation(description: "pending receive")
            let wire = WatchTestWire(started: started)
            let opened = MacWatchConnection(connection: wire, capabilities: .init(),
                                            idleTimeout: timeout ? .milliseconds(10) : .seconds(45))
            let receive = Task { try await opened.receive() }
            await fulfillment(of: [started], timeout: 2)
            if !timeout { receive.cancel() }
            let result = await receive.result
            if case .success = result { XCTFail("Pending receive must not succeed") }
            XCTAssertTrue(wire.cancelled)
        }
    }
}

private final class WatchTestWire: WatchFrameConnection, Sendable {
    private struct State {
        var replies: [Data]
        var waiter: CheckedContinuation<Data, Error>?
        var cancelled = false
        var sent: [Data] = []
        var maximums: [Int] = []
    }
    private let state: OSAllocatedUnfairLock<State>
    private let started: XCTestExpectation?
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var sent: [Data] { state.withLock { $0.sent } }
    var maximums: [Int] { state.withLock { $0.maximums } }

    init(replies: [Data] = [], started: XCTestExpectation? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(replies: replies))
        self.started = started
    }

    @MainActor func send(_ payload: Data, canSend: (@MainActor @Sendable () -> Bool)?) async throws {
        guard canSend?() ?? true else { throw CancellationError() }
        state.withLock { $0.sent.append(payload) }
    }

    func receiveFrame(maximum: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.withLock { value in
                    value.maximums.append(maximum)
                    if value.cancelled { continuation.resume(throwing: CancellationError()) }
                    else if !value.replies.isEmpty { continuation.resume(returning: value.replies.removeFirst()) }
                    else { value.waiter = continuation }
                }
                started?.fulfill()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        let waiter = state.withLock { value in
            value.cancelled = true
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume(throwing: CancellationError())
    }
}
