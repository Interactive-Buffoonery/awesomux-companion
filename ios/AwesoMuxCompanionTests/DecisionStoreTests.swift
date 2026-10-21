import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class DecisionStoreTests: XCTestCase {
    func testInactiveSceneStopsListAfterStatusAndReadAfterTransportPreparation() async {
        for preparingTransport in [false, true] {
            let f = Fixture()
            let gate = RequestGate("foreground-only decision read")
            if preparingTransport { f.lan.prepareReadGate = gate } else { f.lan.readGate = gate }
            let task = Task {
                try await f.store.readDecisions(session: f.store.decisionSessionID, canRead: { f.active })
            }
            await fulfillment(of: [gate.started], timeout: 3)
            f.active = false
            gate.release()
            do { _ = try await task.value; XCTFail("Inactive read must stop") } catch {}
            XCTAssertFalse(f.lan.calls.contains("list_pending_decisions"))
            if preparingTransport { XCTAssertTrue(f.lan.calls.isEmpty) }
            XCTAssertTrue(f.tailscale.calls.isEmpty)
        }
    }

    func testScopedListAndSubmitDenialsPreserveAgentAndPaneReadAuthority() async throws {
        for denyingSubmit in [false, true] {
            let f = Fixture()
            f.store.resumePanes()
            defer { f.store.suspendPanes() }
            await f.store.refresh()
            await f.store.refreshPanes()
            XCTAssertTrue(f.store.reachable)
            let snapshot = f.store.snapshot
            let panes = f.store.panes
            let pairing = f.store.decisionPairing
            let token = f.store.decisionSessionID
            if denyingSubmit { f.lan.writeError = .api("permission_denied") }
            else { f.lan.listError = .api("permission_denied") }
            do {
                if denyingSubmit { _ = try await f.store.submitDecision(f.answer, session: token, canSend: { true }) }
                else { _ = try await f.store.readDecisions(session: token, canRead: { true }) }
                XCTFail("Expected scoped denial")
            } catch { XCTAssertEqual(error as? MacClientFailure, .api("permission_denied")) }
            XCTAssertTrue(f.store.reachable)
            XCTAssertEqual(f.store.snapshot, snapshot)
            XCTAssertEqual(f.store.panes.state, panes.state)
            XCTAssertEqual(f.store.panes.permission, panes.permission)
            XCTAssertEqual(f.store.decisionPairing, pairing)
            XCTAssertNotEqual(f.store.decisionSessionID, token)
            XCTAssertTrue(f.tailscale.calls.isEmpty)
        }
    }

    func testDisabledProductionStatusDoesNotCallDeniedPendingList() async throws {
        let f = Fixture()
        f.lan.enabled = false
        f.lan.readError = .api("permission_denied")
        let response = try await f.store.readDecisions(session: f.store.decisionSessionID, canRead: { true })
        XCTAssertEqual(response.remoteDecisionsEnabled, false)
        XCTAssertEqual(f.lan.calls, ["get_connection_status"])
        XCTAssertTrue(f.tailscale.calls.isEmpty)
    }

    func testReadsFailOverButLostWriteNeverTriesAnotherRoute() async throws {
        let f = Fixture()
        f.lan.readError = .unreachable
        let token = f.store.decisionSessionID
        let response = try await f.store.readDecisions(session: token, canRead: { true })
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
            _ = try await f.store.readDecisions(session: previous, canRead: { true })
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
        var active = true
        let lan = DecisionClientFixture()
        let tailscale = DecisionClientFixture()
        let answer = CompanionDecisionAnswer(identity: .init(runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(),
            targetVersion: UUID(), providerSessionID: "claude", invocationID: UUID(), revision: 1), choice: .allow, retryID: UUID())
        let store: CompanionStore
        init() {
            let defaults = UserDefaults(suiteName: suite)!
            let lan = lan, tailscale = tailscale
            store = CompanionStore(defaults: defaults,
                loadPairing: { panePairing(routes: [.init(transport: .lan, host: "192.168.1.2"),
                                                   .init(transport: .tailscale, host: "100.64.0.2")]) },
                makeClient: { _, route in route.transport == .lan ? lan : tailscale },
                removePairing: { _ in }, liveActivity: nil, writeShared: { _ in }, clearShared: {})
        }
        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
}

@MainActor
final class DecisionClientFixture: CompanionSessionClient {
    var enabled = true
    var readError: MacClientFailure?
    var listError: MacClientFailure?
    var readGate: RequestGate?
    var prepareReadGate: RequestGate?
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
        if let readGate { self.readGate = nil; await readGate.pause() }
        if let readError { throw readError }
        if operation == "list_pending_decisions", let listError { throw listError }
        if operation == "list_agents" {
            return APIResponse(agents: [.init(paneID: "agent", workspaceID: "workspace", workspaceName: "Project",
                provider: "Claude", executionLocation: "local", availability: "attached", state: "running")])
        }
        if operation == "get_attention_events" {
            return APIResponse(attentionEvents: .init(events: [], nextCursor: "cursor", cursorStatus: "initial",
                hasMore: false, currentStateRecoveryRequired: false))
        }
        return APIResponse(workspaces: workspaces, terminalPreviewAllowed: false,
                           pendingDecisions: [], decisionOutcomes: [], remoteDecisionsEnabled: enabled)
    }

    func call(_ operation: String, connectionID: UUID, limit: Int?, cursor: String?,
              canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse {
        if let prepareReadGate { self.prepareReadGate = nil; await prepareReadGate.pause() }
        guard canSend() else { throw CancellationError() }
        return try await call(operation, connectionID: connectionID, limit: limit, cursor: cursor)
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
