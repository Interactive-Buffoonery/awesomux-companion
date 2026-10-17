import XCTest
@testable import AwesoMuxCompanion

@MainActor private final class FakeCredentials: HostCredentialStorage {
    var item: ConnectionConfiguration?
    var failLoad = false
    var failSave = false
    var failDelete = false
    func load() throws -> ConnectionConfiguration? { if failLoad { throw BridgeFailure.disconnected }; return item }
    func save(_ configuration: ConnectionConfiguration) throws { if failSave { throw BridgeFailure.disconnected }; item = configuration }
    func clear() throws { if failDelete { throw BridgeFailure.disconnected }; item = nil }
}

@MainActor final class PairingStoreTests: XCTestCase {
    private let first = ConnectionConfiguration(endpoint: "https://first.example.ts.net:8443", token: String(repeating: "a", count: 32))
    private let second = ConnectionConfiguration(endpoint: "https://second.example.ts.net:8443", token: String(repeating: "b", count: 32))
    private func snapshot() throws -> ThreadSnapshot {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pending", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ThreadSnapshot.self, from: Data(contentsOf: url))
    }
    func testFailedReplacementAndDeleteRemainQuarantinedAcrossActivation() async throws {
        for deleting in [false, true] {
            let credentials = FakeCredentials(); credentials.item = first
            let api = FakeAPI(try snapshot())
            let store = CompanionStore(credentials: credentials, clientFactory: { _ in api })
            store.activate(); await store.refresh(); XCTAssertTrue(store.isFresh)
            credentials.failSave = !deleting; credentials.failDelete = deleting
            if deleting { XCTAssertThrowsError(try store.disconnectHost()) }
            else { XCTAssertThrowsError(try store.pair(second)) }
            store.deactivate(); store.activate(); await store.refresh()
            XCTAssertNil(store.snapshot); XCTAssertFalse(store.isFresh)
            XCTAssertEqual(credentials.item, first)
            XCTAssertEqual(store.connectionState, .quarantined(first.hostLabel))
            try store.retryConnection()
            XCTAssertFalse(store.isFresh)
            await store.refresh(); XCTAssertTrue(store.isFresh)
            XCTAssertEqual(store.activeHostLabel, first.hostLabel)
        }
    }
    func testLoadFailureDoesNotFallBackOrOfferOverwrite() async throws {
        let credentials = FakeCredentials(); credentials.item = first; credentials.failLoad = true
        let api = FakeAPI(try snapshot())
        let store = CompanionStore(credentials: credentials, clientFactory: { _ in api })
        store.activate(); await store.refresh()
        XCTAssertEqual(store.connectionState, .loadFailed)
        XCTAssertFalse(store.canPair); XCTAssertFalse(store.isFresh)
        store.deactivate(); credentials.failLoad = false; store.activate(); await store.refresh()
        XCTAssertNil(store.snapshot)
        try store.retryConnection(); await store.refresh()
        XCTAssertEqual(store.activeHostLabel, first.hostLabel); XCTAssertTrue(store.isFresh)
    }
    func testOldFetchAndPostCannotApplyAfterSameGenerationRePair() async throws {
        let credentials = FakeCredentials(); credentials.item = first
        let current = try snapshot(); let old = FakeAPI(current); let new = FakeAPI(current)
        let store = CompanionStore(credentials: credentials, clientFactory: { configuration in configuration == self.first ? old : new })
        store.activate(); await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        await old.deferFetch(); await old.deferAnswer()
        let oldGet = Task { await store.refresh() }
        let oldPost = Task { await store.submit(control, context: store.answerContext, answers: ["q":"A", "detail":"old"], confirmUncertain: false) }
        await old.waitForFetch(); await old.waitForAnswer()
        try store.pair(second); XCTAssertNil(store.snapshot); XCTAssertTrue(store.earlierOutcomeUnknown)
        await store.refresh()
        let newControl = try XCTUnwrap(store.snapshot?.pending.first)
        await store.submit(newControl, context: store.answerContext, answers: ["q":"B", "detail":"new"], confirmUncertain: false)
        let newOperation = try XCTUnwrap(store.submissions[control.id]?.operation.operationID)
        await old.setReply(AnswerReply(status: 200, outcome: "resolved", error: nil))
        await old.releaseAnswer(); await old.releaseFetch(current)
        await oldGet.value; await oldPost.value
        XCTAssertEqual(store.submissions[control.id]?.operation.operationID, newOperation)
        XCTAssertEqual(store.submissions[control.id]?.status, .submitted)
        XCTAssertEqual(store.activeHostLabel, second.hostLabel)
    }
    func testActivationReloadsChangedCredentialAndRetainsUnchangedPost() async throws {
        let credentials = FakeCredentials(); credentials.item = first
        let current = try snapshot(); let old = FakeAPI(current); let new = FakeAPI(current)
        let store = CompanionStore(credentials: credentials, clientFactory: { configuration in configuration == self.first ? old : new })
        store.activate(); await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first)
        await old.deferAnswer()
        let post = Task { await store.submit(control, context: store.answerContext, answers: ["q":"A", "detail":"old"], confirmUncertain: false) }
        await old.waitForAnswer();store.deactivate();store.activate();await store.refresh()
        await old.releaseAnswer();await post.value
        XCTAssertEqual(store.submissions[control.id]?.status, .submitted)
        store.deactivate();credentials.item = second;store.activate()
        XCTAssertNil(store.snapshot);XCTAssertFalse(store.isFresh)
        await store.refresh();XCTAssertEqual(store.activeHostLabel, second.hostLabel)
        XCTAssertTrue(store.earlierOutcomeUnknown)
    }

    func testExplicitDisconnectRemainsOfflineAcrossActivation() async throws {
        let credentials = FakeCredentials(); credentials.item = first
        let api = FakeAPI(try snapshot())
        let store = CompanionStore(credentials: credentials, clientFactory: { _ in api })
        store.activate(); await store.refresh();try store.disconnectHost()
        // Simulate a preserved development file or an external credential insertion.
        credentials.item = first
        store.deactivate();store.activate();await store.refresh()
        XCTAssertNil(store.snapshot);XCTAssertFalse(store.isFresh)
        try store.retryConnection();await store.refresh();XCTAssertTrue(store.isFresh)
    }

    func testQueuedDisplayedIntentCannotCrossReplacementOrSameHostRePair() async throws {
        for replacement in [first, second] {
            let credentials = FakeCredentials(); credentials.item = first
            let old = FakeAPI(try snapshot()); let new = FakeAPI(try snapshot())
            let store = CompanionStore(credentials: credentials, clientFactory: { configuration in configuration == self.first ? old : new })
            store.activate();await store.refresh()
            let displayedControl = try XCTUnwrap(store.snapshot?.pending.first)
            let displayedContext = store.answerContext
            try store.pair(replacement);await store.refresh()
            await store.submit(displayedControl, context: displayedContext, answers: ["q":"A", "detail":"queued old answer"], confirmUncertain: false)
            let operations = replacement == first ? await old.operations : await new.operations
            XCTAssertTrue(operations.isEmpty, "A retained pre-pair form must not write to the new connection")
            let currentControl = try XCTUnwrap(store.snapshot?.pending.first)
            await store.submit(currentControl, context: store.answerContext, answers: ["q":"B", "detail":"new form"], confirmUncertain: false)
            let currentOperations = replacement == first ? await old.operations : await new.operations
            XCTAssertEqual(currentOperations.count, 1)
        }
    }

    func testStaleRetryContextOrOperationCannotRetryReplacementAnswer() async throws {
        let credentials = FakeCredentials();credentials.item = first
        let api = FakeAPI(try snapshot());await api.setReply(AnswerReply(status:503,outcome:"disconnected",error:nil))
        let store = CompanionStore(credentials:credentials,clientFactory:{ _ in api })
        store.activate();await store.refresh()
        let control = try XCTUnwrap(store.snapshot?.pending.first);let oldContext=store.answerContext
        await store.submit(control,context:oldContext,answers:["q":"A","detail":"old"],confirmUncertain:false)
        let oldOperation=try XCTUnwrap(store.submissions[control.id]?.operation.operationID)
        try store.pair(first);await store.refresh()
        let current=try XCTUnwrap(store.snapshot?.pending.first);let currentContext=store.answerContext
        await store.submit(current,context:currentContext,answers:["q":"B","detail":"new"],confirmUncertain:false)
        let currentOperation=try XCTUnwrap(store.submissions[current.id]?.operation.operationID)
        await store.retry(current.id,operationID:currentOperation,context:oldContext)
        await store.retry(current.id,operationID:oldOperation,context:currentContext)
        let before=await api.operations;XCTAssertEqual(before.count,2)
        await store.retry(current.id,operationID:currentOperation,context:currentContext)
        let after=await api.operations;XCTAssertEqual(after.count,3)
        XCTAssertEqual(after[1].body,after[2].body)
    }

    func testFailedDeleteOfUnreadCredentialCannotOfferOverwrite() async throws {
        let credentials=FakeCredentials();credentials.item=first
        let api=FakeAPI(try snapshot());let store=CompanionStore(credentials:credentials,clientFactory:{ _ in api })
        store.activate();await store.refresh();credentials.failLoad=true
        store.deactivate();store.activate()
        credentials.failDelete=true
        XCTAssertThrowsError(try store.disconnectHost())
        XCTAssertEqual(store.connectionState,.loadFailed)
        XCTAssertFalse(store.canPair);XCTAssertNil(store.activeHostLabel)
        XCTAssertEqual(credentials.item,first)
    }

}
