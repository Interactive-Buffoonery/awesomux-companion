import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class DecisionOutcomeTests: XCTestCase {
    func testOriginalAlreadyAnsweredReceiptExplainsWinnerWithoutMislabelingFreshStatus() {
        let f = DecisionFixture()
        let original = DecisionOutcomeView(receipt: f.macWinner, isCurrent: false, context: .init(identity: f.identity))
        let current = DecisionOutcomeView(receipt: f.macWinner, isCurrent: true, context: .init(identity: f.identity))
        XCTAssertTrue(original.statusText.contains("Already answered by Mac"))
        XCTAssertTrue(original.statusText.contains("was not used"))
        XCTAssertFalse(current.statusText.contains("was not used"))
        XCTAssertTrue(current.statusText.contains("recorded"))
    }

    func testRefusalsDoNotImplyPendingSuccessOrLostReply() {
        let f = DecisionFixture()
        for result: CompanionDecisionReceipt.Result in [.expired, .retryConflict, .capacityExceeded] {
            let receipt = CompanionDecisionReceipt(identity: f.identity, result: result, state: .pending)
            let view = DecisionOutcomeView(receipt: receipt, isCurrent: false, context: .init(identity: f.identity))
            XCTAssertFalse(view.statusText.contains("Pending"))
            XCTAssertFalse(view.statusText.contains("not confirmed"))
            XCTAssertTrue(view.statusText.contains("Mac"))
        }
    }

    func testAlreadyAnsweredTerminalOutcomeNeverInventsAHumanWinner() {
        let f = DecisionFixture()
        for state: CompanionDecisionState in [.expired, .cancelled, .unknown] {
            let receipt = CompanionDecisionReceipt(identity: f.identity, result: .alreadyAnswered, state: state)
            let view = DecisionOutcomeView(receipt: receipt, isCurrent: false, context: .init(identity: f.identity))
            XCTAssertTrue(view.statusText.contains("was not used"))
            XCTAssertFalse(view.statusText.contains("Already answered by"))
        }
    }
}
