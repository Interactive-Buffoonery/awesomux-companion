import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class DecisionStoreTests: XCTestCase {
    func testDisabledProductionStatusDoesNotCallDeniedPendingList() async throws {
        let f = Fixture()
        f.lan.enabled = false
        f.lan.readError = .api("permission_denied")
        let response = try await f.store.readDecisions(session: f.store.decisionSessionID)
        XCTAssertEqual(response.remoteDecisionsEnabled, false)
        XCTAssertEqual(f.lan.calls, ["get_connection_status"])
        XCTAssertTrue(f.tailscale.calls.isEmpty)
    }

    func testReadsFailOverButLostWriteNeverTriesAnotherRoute() async throws {
        let f = Fixture()
        f.lan.readError = .unreachable
        let token = f.store.decisionSessionID
        let response = try await f.store.readDecisions(session: token)
        XCTAssertEqual(response.remoteDecisionsEnabled, true)
        XCTAssertEqual(f.store.activeRoute?.transport, .tailscale)
        f.tailscale.writeError = .closed
        do {
            _ = try await f.store.submitDecision(f.answer, session: token, canSend: { true })
            XCTFail("Expected a lost reply")
        } catch { XCTAssertEqual(error as? MacClientFailure, .closed) }
        XCTAssertEqual(f.tailscale.answers, [f.answer])
        XCTAssertTrue(f.lan.answers.isEmpty)
        XCTAssertEqual(f.tailscale.connectionIDs, [f.store.record!.connectionID])
    }

    func testDeniedReadRotatesDecisionSessionAndDoesNotFailOver() async {
        let f = Fixture()
        f.lan.readError = .api("permission_denied")
        let previous = f.store.decisionSessionID
        do {
            _ = try await f.store.readDecisions(session: previous)
            XCTFail("Expected denied grant")
        } catch { XCTAssertEqual(error as? MacClientFailure, .api("permission_denied")) }
        XCTAssertNotEqual(f.store.decisionSessionID, previous)
        XCTAssertTrue(f.tailscale.calls.isEmpty)
    }

    func testAuthorizationRecheckedAfterConnectionPreparationAndOldPairingRejected() async {
        let f = Fixture()
        let token = f.store.decisionSessionID
        let gate = RequestGate("connection preparation")
        f.lan.beforeSend = gate
        var active = true
        let task = Task { try await f.store.submitDecision(f.answer, session: token, canSend: { active }) }
        await fulfillment(of: [gate.started], timeout: 3)
        active = false
        gate.release()
        do { _ = try await task.value; XCTFail("Inactive send must be blocked") } catch {}
        XCTAssertTrue(f.lan.answers.isEmpty)
        f.store.replacePairing(with: panePairing(connectionID: UUID()))
        do {
            _ = try await f.store.submitDecision(f.answer, session: token, canSend: { true })
            XCTFail("Old pairing must be blocked")
        } catch {}
        XCTAssertTrue(f.lan.answers.isEmpty)
    }

    func testContextJoinsExactWorkspaceAndPaneOrUsesIDs() async {
        let f = Fixture()
        let identity = f.answer.identity
        f.lan.workspaces = [.init(workspaceID: identity.workspaceID.uuidString.lowercased(), name: "Project One", panes: [
            .init(paneID: identity.paneID.uuidString.lowercased(), kind: "terminal", title: "Claude pane", availability: "attached")])]
        f.store.resumePanes()
        defer { f.store.suspendPanes() }
        await f.store.refreshPanes()
        XCTAssertEqual(f.store.decisionContext(identity).workspaceLabel, "Project One")
        XCTAssertEqual(f.store.decisionContext(identity).paneLabel, "Claude pane")
        let other = CompanionDecisionIdentity(runtimeID: identity.runtimeID, workspaceID: UUID(), paneID: identity.paneID,
            targetVersion: identity.targetVersion, providerSessionID: identity.providerSessionID,
            invocationID: UUID(), revision: 2)
        let fallback = f.store.decisionContext(other)
        XCTAssertEqual(fallback.workspaceLabel, other.workspaceID.uuidString)
        XCTAssertEqual(fallback.paneLabel, other.paneID.uuidString)
        XCTAssertNotEqual(fallback.requestLabel, f.store.decisionContext(identity).requestLabel)
    }

    @MainActor
    private final class Fixture {
        let suite = "DecisionStoreTests.\(UUID())"
        let defaults: UserDefaults
        let lan = DecisionClientFixture()
        let tailscale = DecisionClientFixture()
        let answer = CompanionDecisionAnswer(identity: .init(runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(),
            targetVersion: UUID(), providerSessionID: "claude", invocationID: UUID(), revision: 1), choice: .allow, retryID: UUID())
        let store: CompanionStore
        init() {
            defaults = UserDefaults(suiteName: suite)!
            let lan = lan, tailscale = tailscale
            store = CompanionStore(defaults: defaults,
                loadPairing: { panePairing(routes: [.init(transport: .lan, host: "192.168.1.2"),
                                                   .init(transport: .tailscale, host: "100.64.0.2")]) },
                makeClient: { _, route in route.transport == .lan ? lan : tailscale },
                removePairing: { _ in }, liveActivity: nil, writeShared: { _ in }, clearShared: {})
        }
        deinit { defaults.removePersistentDomain(forName: suite) }
    }
}

@MainActor
final class DecisionClientFixture: CompanionSessionClient {
    var enabled = true
    var readError: MacClientFailure?
    var writeError: MacClientFailure?
    var beforeSend: RequestGate?
    var calls: [String] = []
    var answers: [CompanionDecisionAnswer] = []
    var connectionIDs: [UUID] = []
    var workspaces: [APIResponse.Workspace] = []

    func call(_ operation: String, connectionID: UUID, limit: Int?, cursor: String?) async throws -> APIResponse {
        calls.append(operation)
        // Disabled status succeeds, while the production list denies access.
        if operation == "get_connection_status", !enabled { return APIResponse(remoteDecisionsEnabled: false) }
        if let readError { throw readError }
        return APIResponse(workspaces: workspaces, terminalPreviewAllowed: false,
                           pendingDecisions: [], decisionOutcomes: [], remoteDecisionsEnabled: enabled)
    }

    func answerDecision(_ answer: CompanionDecisionAnswer, connectionID: UUID,
                        canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse {
        if let beforeSend { await beforeSend.pause() }
        guard canSend() else { throw CancellationError() }
        answers.append(answer)
        connectionIDs.append(connectionID)
        if let writeError { throw writeError }
        return APIResponse(decisionReceipt: .init(identity: answer.identity, result: .recorded,
            state: .recorded, choice: answer.choice, source: .init(name: "Fixture iPhone")))
    }

    func unpair(connectionID: UUID) async throws {}
}
