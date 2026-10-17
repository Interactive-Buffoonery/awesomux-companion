import XCTest
@testable import AwesoMuxCompanion

actor FakeAPI: BridgeAPI {
    var current: ThreadSnapshot
    var failFetch = false
    var holdFetch = false
    var holdAnswer = false
    var waitingFetch: CheckedContinuation<ThreadSnapshot, any Error>?
    var waitingAnswer: CheckedContinuation<AnswerReply, any Error>?
    var operations: [AnswerOperation] = []
    var reply = AnswerReply(status: 202, outcome: "submitted", error: nil)
    init(_ snapshot: ThreadSnapshot) { current = snapshot }
    func fetch() async throws -> ThreadSnapshot {
        if holdFetch { return try await withCheckedThrowingContinuation { waitingFetch = $0 } }
        if failFetch { throw URLError(.notConnectedToInternet) }
        return current
    }
    func answer(_ operation: AnswerOperation) async throws -> AnswerReply {
        operations.append(operation)
        if holdAnswer { return try await withCheckedThrowingContinuation { waitingAnswer = $0 } }
        return reply
    }
    func allowNewFetch() { holdFetch = false }
    func deferFetch() { holdFetch = true }
    func deferAnswer() { holdAnswer = true }
    func waitForFetch() async { while waitingFetch == nil { await Task.yield() } }
    func waitForAnswer() async { while waitingAnswer == nil { await Task.yield() } }
    func releaseFetch(_ value: ThreadSnapshot) { holdFetch = false; waitingFetch?.resume(returning: value); waitingFetch = nil }
    func failWaitingFetch() { holdFetch = false; waitingFetch?.resume(throwing: URLError(.notConnectedToInternet)); waitingFetch = nil }
    func releaseAnswer() { holdAnswer = false; waitingAnswer?.resume(returning: reply); waitingAnswer = nil }
    func setFailure() { failFetch = true }
    func setSnapshot(_ snapshot: ThreadSnapshot) { current = snapshot }
    func setReply(_ value: AnswerReply) { reply = value }
}

@MainActor
final class CompanionStoreTests: XCTestCase {
    func fixture(_ name: String) throws -> ThreadSnapshot {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ThreadSnapshot.self, from: Data(contentsOf: url))
    }
    func testActualFixturesDecodeIncludingFractionalTimeAndOperations() throws {
        XCTAssertNil(try fixture("disconnected").generation)
        XCTAssertEqual(try fixture("pending").updatedAt, 1.5)
        XCTAssertEqual(try fixture("pending").pending[0].questions.count, 2)
        XCTAssertEqual(try fixture("submitted").operations.values.first, "submitted")
    }
    func testWholeControlRequiresAllAnswersAndDuplicateDoesNotPost() async throws {
        let api = FakeAPI(try fixture("pending"))
        let store = CompanionStore(api: api)
        store.activate()
        await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        await store.submit(control, context: store.answerContext, answers: ["q": "A"], confirmUncertain: false)
        var sent = await api.operations
        XCTAssertTrue(sent.isEmpty)
        await store.submit(control, context: store.answerContext, answers: ["q": "A", "detail": "details"], confirmUncertain: false)
        await store.submit(control, context: store.answerContext, answers: ["q": "B", "detail": "different"], confirmUncertain: false)
        sent = await api.operations
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].operationID, sent[0].operationID.lowercased())
        XCTAssertFalse(store.canAnswer(control, context: store.answerContext))
    }
    func testFailedPollAndLeaseExpiryDisableControls() async throws {
        let api = FakeAPI(try fixture("pending"))
        var now = 1.0
        let store = CompanionStore(api: api, now: { now })
        store.activate(); await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        XCTAssertTrue(store.canAnswer(control, context: store.answerContext))
        now = 12
        XCTAssertFalse(store.canAnswer(control, context: store.answerContext))
        await store.submit(control, context: store.answerContext, answers: ["q": "A", "detail": "details"], confirmUncertain: false)
        let sent = await api.operations
        XCTAssertTrue(sent.isEmpty)
        now = 13; await store.refresh(); await api.setFailure(); await store.refresh()
        XCTAssertFalse(store.canAnswer(control, context: store.answerContext))
        store.deactivate()
        XCTAssertFalse(store.isFresh)
    }
    func testUncertainRetryUsesIdenticalEncodedOperation() async throws {
        let api = FakeAPI(try fixture("pending"))
        await api.setReply(AnswerReply(status: 503, outcome: "disconnected", error: nil))
        let store = CompanionStore(api: api)
        store.activate(); await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        await store.submit(control, context: store.answerContext, answers: ["q": "A", "detail": "details"], confirmUncertain: false)
        await store.retry(control.id, operationID: store.submissions[control.id]?.operation.operationID ?? "missing", context: store.answerContext)
        let sent = await api.operations
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].body, sent[1].body)
        XCTAssertEqual(sent[0].operationID, sent[1].operationID)
        XCTAssertEqual(store.submissions[control.id]?.status, .uncertain)
    }
    func testUnknownOutcomeAndMismatchedStatusStayUncertain() async throws {
        let api = FakeAPI(try fixture("pending"))
        await api.setReply(AnswerReply(status: 404, outcome: nil, error: "not_found"))
        let store = CompanionStore(api: api)
        store.activate(); await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        await store.submit(control, context: store.answerContext, answers: ["q": "A", "detail": "details"], confirmUncertain: false)
        XCTAssertEqual(store.submissions[control.id]?.status, .uncertain)
    }
    func testLeavingActiveRejectsLateFetch() async throws {
        let snapshot = try fixture("pending")
        let api = FakeAPI(snapshot)
        let store = CompanionStore(api: api)
        store.activate(); await api.deferFetch()
        let fetch = Task { await store.refresh() }
        await api.waitForFetch(); store.deactivate(); await api.releaseFetch(snapshot); await fetch.value
        XCTAssertNil(store.snapshot); XCTAssertFalse(store.isFresh)
    }
    func testGenerationChangeClearsOldSubmissionAndRetainsNotice() async throws {
        var next = try fixture("pending")
        let api = FakeAPI(next)
        await api.setReply(AnswerReply(status: 503, outcome: "disconnected", error: nil))
        let store = CompanionStore(api: api); store.activate(); await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        await store.submit(control, context: store.answerContext, answers: ["q":"A", "detail":"details"], confirmUncertain:false)
        next.generation = "another-generation"; next.pending[0].id = "another-control"
        await api.setSnapshot(next); await store.refresh()
        XCTAssertTrue(store.submissions.isEmpty); XCTAssertTrue(store.earlierOutcomeUnknown)
    }
    func testResolutionWinsLatePost() async throws {
        var next = try fixture("pending")
        let api = FakeAPI(next); await api.deferAnswer()
        let store = CompanionStore(api: api); store.activate(); await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        let post = Task { await store.submit(control, context: store.answerContext, answers:["q":"A","detail":"details"], confirmUncertain:false) }
        await api.waitForAnswer(); next.pending = []
        await api.setSnapshot(next); await store.refresh(); await api.releaseAnswer(); await post.value
        XCTAssertEqual(store.submissions[control.id]?.status, .resolved)
        XCTAssertEqual(store.snapshot?.pending.count, 0)
    }
    func testPrePostFetchCannotResolveOrUnlockReservedControl() async throws {
        var old = try fixture("pending")
        let api = FakeAPI(old)
        let store = CompanionStore(api:api); store.activate(); await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        await api.deferFetch(); let fetch = Task { await store.refresh() }
        await api.waitForFetch()
        await store.submit(control, context: store.answerContext, answers:["q":"A","detail":"details"], confirmUncertain:false)
        old.pending = []; await api.releaseFetch(old); await fetch.value
        XCTAssertEqual(store.submissions[control.id]?.status, .submitted)
        await api.setSnapshot(try fixture("pending")); await store.refresh()
        XCTAssertFalse(store.canAnswer(control, context: store.answerContext))
    }

    func testDisconnectedOrErrorSnapshotDoesNotResolveUncertainAnswer() async throws {
        for bridgeError in [nil, "capacity"] as [String?] {
            var next = try fixture("pending")
            let api = FakeAPI(next)
            await api.setReply(AnswerReply(status: 503, outcome: nil, error: nil))
            let store = CompanionStore(api: api); store.activate(); await store.refresh()
            let control = try XCTUnwrap(store.snapshot?.pending.first)
            await store.submit(control, context: store.answerContext, answers:["q":"A","detail":"details"], confirmUncertain:false)
            let operation = try XCTUnwrap(store.submissions[control.id]?.operation)
            next.connected = bridgeError != nil; next.error = bridgeError; next.pending = []
            next.operations[operation.operationID] = "uncertain"
            await api.setSnapshot(next); await store.refresh()
            XCTAssertEqual(store.submissions[control.id]?.status, .uncertain)
            next.generation = "reconnected"; next.connected = true; next.error = nil
            await api.setSnapshot(next); await store.refresh()
            XCTAssertTrue(store.earlierOutcomeUnknown)
        }
    }
    func testOlderFailedFetchCannotInvalidateNewerSuccess() async throws {
        let api = FakeAPI(try fixture("pending"))
        let store = CompanionStore(api: api); store.activate(); await store.refresh()
        await api.deferFetch()
        let old = Task { await store.refresh() }; await api.waitForFetch()
        // Leave the older continuation pending while permitting a newer request.
        await api.allowNewFetch(); await store.refresh()
        XCTAssertTrue(store.isFresh)
        await api.failWaitingFetch(); await old.value
        XCTAssertTrue(store.isFresh)
        XCTAssertNil(store.message)
    }

}
