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
    // Optional future decision values must not erase unrelated status/roster
    // data, and a partly understood decision array must never be actionable.
    @Test(arguments: [
        "pendingDecisions.choices", "decisionOutcomes.result", "decisionOutcomes.state",
        "decisionOutcomes.choice", "decisionReceipt.result", "decisionReceipt.state",
        "decisionReceipt.choice",
    ])
    func unknownResponseDecisionValueDropsWholeOptionalField(_ mutation: String) throws {
        let identity = CompanionDecisionIdentity(
            runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(),
            targetVersion: UUID(), providerSessionID: "session", invocationID: UUID(), revision: 1)
        let pending = CompanionPendingDecision(
            identity: identity, tool: "Bash", summary: "echo ready",
            remoteExpiresAt: Date(timeIntervalSince1970: 1000), choices: [.allow, .deny])
        let receipt = CompanionDecisionReceipt(
            identity: identity, result: .recorded, state: .recorded, choice: .allow)
        let response = CompanionAPIResponse(
            connectionStatus: "connected",
            agents: [
                .init(
                    paneID: "agent-pane", workspaceID: "workspace", workspaceName: "Work",
                    provider: "claudeCode",
                    executionLocation: "local", availability: "attached", state: "working")
            ],
            workspaces: [
                .init(
                    workspaceID: "workspace", name: "Work",
                    panes: [
                        .init(
                            paneID: "shell", kind: "terminal", title: "Shell", availability: "attached",
                            lastOutputLine: "ready")
                    ])
            ], pendingDecisions: [pending, pending], decisionOutcomes: [receipt, receipt],
            decisionReceipt: receipt,
            remoteDecisionsEnabled: false)
        let data = try CompanionProtocol.encoder().encode(response)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parts = mutation.split(separator: ".").map(String.init)
        let field = parts[0]
        let key = parts[1]
        if field == "decisionReceipt" {
            var value = try #require(object[field] as? [String: Any])
            value[key] = "future"
            object[field] = value
        } else {
            var values = try #require(object[field] as? [[String: Any]])
            values[1][key] = key == "choices" ? ["allow", "future"] : "future"
            object[field] = values
        }
        let decoded = try CompanionProtocol.decoder().decode(
            CompanionAPIResponse.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.pendingDecisions == (field == "pendingDecisions" ? nil : [pending, pending]))
        #expect(decoded.decisionOutcomes == (field == "decisionOutcomes" ? nil : [receipt, receipt]))
        #expect(decoded.decisionReceipt == (field == "decisionReceipt" ? nil : receipt))
        #expect(decoded.remoteDecisionsEnabled == false)
        #expect(decoded.connectionStatus == "connected")
        #expect(decoded.agents?.first?.paneID == "agent-pane")
        #expect(decoded.agents?.first?.state == "working")
        #expect(decoded.workspaces?.first?.panes.first?.lastOutputLine == "ready")
    }

    @Test func unknownAnswerChoiceRemainsStrict() throws {
        let identity = CompanionDecisionIdentity(
            runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(),
            targetVersion: UUID(), providerSessionID: "session", invocationID: UUID(), revision: 1)
        let answer = CompanionDecisionAnswer(identity: identity, choice: .allow, retryID: UUID())
        var object = try #require(
            JSONSerialization.jsonObject(with: CompanionProtocol.encoder().encode(answer))
                as? [String: Any])
        object["choice"] = "future"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try CompanionProtocol.decoder().decode(CompanionDecisionAnswer.self, from: data)
        }
    }

}
