import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class PendingDecisionsModelTests: XCTestCase {
    func testDoubleTapAndOppositeChoiceDuringAuthenticationSendOnlyOnce() async {
        let f = DecisionFixture()
        await f.model.refresh()
        let gate = RequestGate("decision authentication")
        f.auth.gate = gate
        let answer = Task { await f.model.answer(f.identity, choice: .allow) }
        await fulfillment(of: [gate.started], timeout: 3)
        await f.model.answer(f.identity, choice: .deny)
        await f.model.answer(f.identity, choice: .allow)
        XCTAssertEqual(f.auth.calls, 1)
        gate.release()
        await answer.value
        XCTAssertEqual(f.sent.map(\.choice), [.allow])
    }

    func testLockInvalidatesAuthenticationEvenIfUnlockedBeforeLateSuccess() async {
        let f = DecisionFixture()
        await f.model.refresh()
        let gate = RequestGate("late auth after locking")
        f.auth.gate = gate
        let answer = Task { await f.model.answer(f.identity, choice: .allow) }
        await fulfillment(of: [gate.started], timeout: 3)
        f.lockEnabled = true
        f.unlocked = false
        f.model.sceneChanged(active: true)
        f.lockEnabled = false
        f.unlocked = true
        f.model.sceneChanged(active: true)
        gate.release()
        await answer.value
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertFalse(f.model.isAnswering)
    }

    func testBackgroundDropsLateSubmissionResultAndReconcilesOnReturn() async {
        let f = DecisionFixture()
        await f.model.refresh()
        let gate = RequestGate("late submitted answer")
        f.sendGate = gate
        let answer = Task { await f.model.answer(f.identity, choice: .allow) }
        await fulfillment(of: [gate.started], timeout: 3)
        f.active = false
        f.model.sceneChanged(active: false, backgrounded: true)
        gate.release()
        await answer.value
        XCTAssertTrue(f.model.pending.isEmpty)
        XCTAssertTrue(f.model.outcomes.isEmpty)
        XCTAssertTrue(f.model.receipts.isEmpty)
        f.active = true
        f.model.sceneChanged(active: true)
        await f.model.refresh()
        XCTAssertEqual(f.model.outcomes.first?.state, .delivered)
        await f.model.answer(f.identity, choice: .deny)
        XCTAssertEqual(f.sent.count, 1)
    }

    func testOldReadCannotReopenRequestAfterNewerOutcomeRead() async {
        let f = DecisionFixture()
        await f.model.refresh()
        let gate = RequestGate("stale read")
        f.readGate = gate
        let stale = Task { await f.model.refresh() }
        await fulfillment(of: [gate.started], timeout: 3)
        f.response = f.list(outcomes: [f.macWinner])
        await f.model.refresh()
        f.response = f.list(pending: [f.pending])
        gate.release()
        await stale.value
        XCTAssertTrue(f.model.pending.isEmpty)
        XCTAssertEqual(f.model.outcomes.first, f.macWinner)
    }

    func testAllIdentityChangesInvalidateOldCardBeforeSend() async {
        for field in 0..<7 {
            let f = DecisionFixture()
            await f.model.refresh()
            let old = f.identity
            let changed = CompanionDecisionIdentity(runtimeID: field == 0 ? UUID() : old.runtimeID,
                workspaceID: field == 1 ? UUID() : old.workspaceID, paneID: field == 2 ? UUID() : old.paneID,
                targetVersion: field == 3 ? UUID() : old.targetVersion,
                providerSessionID: field == 4 ? "new-session" : old.providerSessionID,
                invocationID: field == 5 ? UUID() : old.invocationID, revision: field == 6 ? 2 : old.revision)
            f.auth.onAuthenticate = {
                f.response = f.list(pending: [.init(identity: changed, tool: "Bash", summary: "New request",
                    remoteExpiresAt: f.pending.remoteExpiresAt, choices: [.allow, .deny])])
            }
            await f.model.answer(old, choice: .allow)
            XCTAssertTrue(f.sent.isEmpty, "Identity field \(field)")
        }
    }

    func testExpiredCancelledAndUnknownMacOutcomesNeverLookPending() async {
        for state: CompanionDecisionState in [.expired, .cancelled, .unknown] {
            let f = DecisionFixture()
            let outcome = CompanionDecisionReceipt(identity: f.identity, result: .alreadyAnswered, state: state)
            f.response = f.list(outcomes: [outcome])
            await f.model.refresh()
            await f.model.answer(f.identity, choice: .allow)
            XCTAssertEqual(f.model.outcomes, [outcome])
            XCTAssertTrue(f.sent.isEmpty)
            XCTAssertEqual(f.auth.calls, 0)
        }
    }

    func testProductionGateAndMissingFieldsNeverOfferAnswers() async {
        let f = DecisionFixture()
        for response in [APIResponse(remoteDecisionsEnabled: false), APIResponse(),
                         APIResponse(pendingDecisions: [f.pending], remoteDecisionsEnabled: true)] {
            f.response = response
            await f.model.refresh()
            XCTAssertTrue(f.model.pending.isEmpty)
            await f.model.answer(f.pending.identity, choice: .allow)
        }
        XCTAssertEqual(f.auth.calls, 0)
        XCTAssertTrue(f.sent.isEmpty)
    }

    func testEveryAnswerAuthenticatesEvenWithAppLockOffAndRereads() async {
        let f = DecisionFixture()
        await f.model.refresh()
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertEqual(f.auth.calls, 1)
        XCTAssertEqual(f.reads, 3) // Initial, after authentication, after submission.
        XCTAssertEqual(f.sent.first?.identity, f.pending.identity)
        XCTAssertEqual(f.sent.first?.choice, .allow)
        XCTAssertEqual(f.model.receipts.first?.state, .recorded)
        XCTAssertEqual(f.model.outcomes.first?.state, .delivered)
    }

    func testMacWinnerDuringAuthenticationPreventsSubmission() async {
        let f = DecisionFixture()
        await f.model.refresh()
        f.auth.onAuthenticate = { f.response = f.list(outcomes: [f.macWinner]) }
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertEqual(f.model.outcomes.first?.source?.name, "Mac")
        XCTAssertEqual(f.model.outcomes.first?.choice, .deny)
    }

    func testLostReplyReconcilesAndExplicitRetryKeepsExactTuple() async {
        let f = DecisionFixture()
        f.dropReply = true
        await f.model.refresh()
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertEqual(f.sent.count, 1)
        XCTAssertTrue(f.model.canRetry(f.pending.identity))
        await f.model.answer(f.pending.identity, choice: .deny)
        XCTAssertEqual(f.sent.count, 1)
        f.dropReply = false
        await f.model.retry(f.pending.identity)
        XCTAssertEqual(f.sent.count, 2)
        XCTAssertEqual(f.sent[0], f.sent[1])
        XCTAssertEqual(f.auth.calls, 2)
    }

    func testLostReplyWithFreshWinnerNeverRetriesOrChangesSource() async {
        let f = DecisionFixture()
        await f.model.refresh()
        f.onSend = { f.response = f.list(outcomes: [f.macWinner]) }
        f.dropReply = true
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertFalse(f.model.canRetry(f.pending.identity))
        await f.model.retry(f.pending.identity)
        XCTAssertEqual(f.sent.count, 1)
        XCTAssertEqual(f.model.outcomes.first, f.macWinner)
    }

    func testAuthenticationCancellationAndLocalExpiryNeverSend() async {
        let f = DecisionFixture()
        await f.model.refresh()
        f.auth.success = false
        await f.model.answer(f.pending.identity, choice: .deny)
        XCTAssertTrue(f.sent.isEmpty)
        f.auth.success = true
        f.auth.onAuthenticate = { f.time += 61 }
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertTrue(f.model.pending.isEmpty)
    }

    func testBackgroundRejectsLateAuthentication() async {
        let f = DecisionFixture()
        await f.model.refresh()
        f.auth.onAuthenticate = {
            f.active = false
            f.model.sceneChanged(active: false, backgrounded: true)
            f.active = true
            f.model.sceneChanged(active: true)
        }
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertTrue(f.model.pending.isEmpty)
    }

    func testInactiveAuthenticationWaitsForActiveAndFreshRead() async {
        let f = DecisionFixture()
        await f.model.refresh()
        f.auth.onAuthenticate = {
            f.active = false
            f.model.sceneChanged(active: false)
        }
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertTrue(f.model.pending.isEmpty)
        f.response = f.list(outcomes: [f.macWinner])
        f.active = true
        f.model.sceneChanged(active: true)
        await f.model.resumeAuthenticatedAnswer()
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertEqual(f.model.outcomes.first, f.macWinner)
    }

    func testLockOrPairingChangeDuringRereadRejectsLateResult() async {
        for changePairing in [false, true] {
            let f = DecisionFixture()
            await f.model.refresh()
            f.onRead = {
                if changePairing { f.session = UUID() } else { f.unlocked = false }
            }
            await f.model.answer(f.pending.identity, choice: .allow)
            XCTAssertTrue(f.sent.isEmpty)
            XCTAssertTrue(f.model.pending.isEmpty)
        }
    }

    func testReadFailureAndInactiveSceneClearSensitiveSummaries() async {
        let f = DecisionFixture()
        await f.model.refresh()
        XCTAssertEqual(f.model.pending.count, 1)
        f.readFails = true
        await f.model.refresh()
        XCTAssertTrue(f.model.pending.isEmpty)
        XCTAssertFalse(f.model.canRetry(f.pending.identity))
        f.readFails = false
        await f.model.refresh()
        f.active = false
        f.model.sceneChanged(active: false)
        XCTAssertTrue(f.model.pending.isEmpty)
    }

    func testMonotonicExpirySurvivesWallClockRollbackAndRepeatedReads() async {
        let f = DecisionFixture()
        await f.model.refresh()
        f.time += 61
        f.wallTime -= 3600
        await f.model.refresh()
        XCTAssertTrue(f.model.pending.isEmpty)
        await f.model.answer(f.pending.identity, choice: .deny)
        XCTAssertTrue(f.sent.isEmpty)
    }

    func testChangedIdentityOrUnsupportedChoiceCannotUseOldCard() async {
        let f = DecisionFixture()
        await f.model.refresh()
        f.auth.onAuthenticate = {
            f.response = f.list(pending: [CompanionPendingDecision(
                identity: f.pending.identity, tool: "Bash", summary: "Changed", remoteExpiresAt: f.pending.remoteExpiresAt,
                choices: [.deny])])
        }
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertTrue(f.sent.isEmpty)
    }

    func testReceiptNeverOverwritesFresherOutcomeOrReopensRequest() async {
        let f = DecisionFixture()
        await f.model.refresh()
        await f.model.answer(f.pending.identity, choice: .allow)
        XCTAssertEqual(f.model.receipts.first?.state, .recorded)
        XCTAssertEqual(f.model.outcomes.first?.state, .delivered)
        f.response = f.list(pending: [f.pending])
        await f.model.refresh()
        await f.model.answer(f.pending.identity, choice: .deny)
        XCTAssertEqual(f.sent.count, 1)
        XCTAssertTrue(f.model.pending.isEmpty)
    }
}

@MainActor
final class DecisionTestAuthenticator: TerminalAuthenticating {
    var calls = 0
    var success = true
    var onAuthenticate: (() -> Void)?
    var gate: RequestGate?
    func authenticate() async -> Bool {
        calls += 1
        onAuthenticate?()
        if let gate { await gate.pause() }
        return success
    }
    func cancel() {}
}

@MainActor
final class DecisionFixture {
    var time: TimeInterval = 0
    var wallTime: TimeInterval = 1_800_000_000
    var active = true
    var unlocked = true
    var session: UUID? = UUID()
    var reads = 0
    var sent: [CompanionDecisionAnswer] = []
    var readFails = false
    var readGate: RequestGate?
    var sendGate: RequestGate?
    var lockEnabled = false
    var dropReply = false
    var onRead: (() -> Void)?
    var onSend: (() -> Void)?
    let auth = DecisionTestAuthenticator()
    let identity = CompanionDecisionIdentity(runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(),
        targetVersion: UUID(), providerSessionID: "claude-session", invocationID: UUID(), revision: 1)
    lazy var pending = CompanionPendingDecision(identity: identity, tool: "Bash", summary: "Run a bounded command",
        remoteExpiresAt: Date(timeIntervalSince1970: wallTime + 60), choices: [.allow, .deny])
    lazy var macWinner = CompanionDecisionReceipt(identity: identity, result: .alreadyAnswered, state: .recorded,
        choice: .deny, source: .init(name: "Mac"))
    lazy var response = list(pending: [pending])
    lazy var model = PendingDecisionsModel(
        session: { [unowned self] in session }, isUnlocked: { [unowned self] in unlocked && active },
        isLocked: { [unowned self] in lockEnabled }, authenticator: auth, now: { [unowned self] in Date(timeIntervalSince1970: wallTime) },
        uptime: { [unowned self] in time },
        read: { [unowned self] _ in
            reads += 1; onRead?()
            if let gate = readGate { readGate = nil; await gate.pause() }
            if readFails { throw MacClientFailure.unreachable }
            return response
        },
        submit: { [unowned self] answer, _, canSend in
            guard canSend() else { throw CancellationError() }
            sent.append(answer); onSend?()
            if let gate = sendGate { sendGate = nil; await gate.pause() }
            if dropReply { throw MacClientFailure.closed }
            let receipt = CompanionDecisionReceipt(identity: answer.identity, result: .recorded, state: .recorded,
                choice: answer.choice, source: .init(name: "Test iPhone"))
            response = list(outcomes: [.init(identity: answer.identity, result: .alreadyAnswered, state: .delivered,
                choice: answer.choice, source: receipt.source)])
            return APIResponse(decisionReceipt: receipt)
        })

    init() { model.sceneChanged(active: true) }

    func list(pending: [CompanionPendingDecision] = [], outcomes: [CompanionDecisionReceipt] = []) -> APIResponse {
        APIResponse(pendingDecisions: pending, decisionOutcomes: outcomes, remoteDecisionsEnabled: true)
    }
}
