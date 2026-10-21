import Foundation
import Testing
@testable import AwesoMuxCompanionProtocol

// Failure modes: dropped replies must preserve the exact identity/retry tuple;
// older peers must decode envelopes with no decision fields.
@Suite struct DecisionTests {
    @Test func answerRoundTripsExactIdentity() throws {
        let identity = CompanionDecisionIdentity(
            runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(),
            targetVersion: UUID(), providerSessionID: "session", invocationID: UUID(), revision: 1)
        let answer = CompanionDecisionAnswer(identity: identity, choice: .deny, retryID: UUID())
        let request = CompanionAPIRequest(
            operation: CompanionOperation.answerDecision.rawValue,
            connectionID: UUID(), decisionAnswer: answer)
        let decoded = try CompanionProtocol.decoder().decode(
            CompanionAPIRequest.self,
            from: CompanionProtocol.encoder().encode(request))
        #expect(decoded.decisionAnswer == answer)
    }
    @Test func responseRoundTripsAndOldEnvelopeSurvives() throws {
        let old = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: Data("{\"schemaVersion\":1}".utf8))
        #expect(old.pendingDecisions == nil)
        #expect(old.decisionReceipt == nil)
        let response = CompanionAPIResponse(pendingDecisions: [], remoteDecisionsEnabled: false)
        let decoded = try CompanionProtocol.decoder().decode(
            CompanionAPIResponse.self,
            from: CompanionProtocol.encoder().encode(response))
        #expect(decoded.pendingDecisions?.isEmpty == true)
        #expect(decoded.remoteDecisionsEnabled == false)
    }
}
