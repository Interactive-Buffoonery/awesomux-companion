import AwesoMuxCompanionProtocol
import XCTest
import Observation
@testable import AwesoMuxCompanion

@MainActor
final class PaneRosterTests: XCTestCase {
    private lazy var defaults: UserDefaults = {
        let suite = "PaneRosterTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }()

    private func store(_ client: PaneClientFixture, record: PairingRecord = panePairing(),
                       makeClient: ((PairingRecord, CompanionRoute) throws -> any CompanionSessionClient)? = nil,
                       writeShared: @escaping (GlanceSnapshot) -> Void = { _ in }) -> CompanionStore {
        CompanionStore(defaults: defaults, loadPairing: { record }, makeClient: makeClient ?? { _, _ in client },
                       removePairing: { _ in }, liveActivity: nil, writeShared: writeShared, clearShared: {})
    }

    func testProjectionPreservesHostOrderAndRejectsUnknownOrUnavailablePreviews() {
        let projected = PaneRoster.project([
            .init(workspaceID: "b", name: "Second alphabetically", panes: [
                .init(paneID: "shell", kind: "terminal", title: "Shell", availability: "attached", state: "thinking", lastOutputLine: "safe fixture"),
                .init(paneID: "docs", kind: "documentGroup", title: "Notes", availability: "attached", lastOutputLine: "must not show"),
                .init(paneID: "future", kind: "futureKind", title: "Future", availability: "attached", lastOutputLine: "must not show"),
                .init(paneID: "stale", kind: "terminal", title: "Old", availability: "stale", lastOutputLine: "must not show"),
                .init(paneID: "unknown", kind: "terminal", title: "Unknown", availability: "future", lastOutputLine: "must not show")
            ]),
            .init(workspaceID: "a", name: "First alphabetically", panes: []),
            .init(workspaceID: "b", name: "Duplicate", panes: [])
        ], previews: true)
        XCTAssertEqual(projected.map(\.id), ["b", "a"])
        XCTAssertEqual(projected[0].panes.map(\.id), ["shell", "docs", "future", "stale", "unknown"])
        XCTAssertEqual(projected[0].panes.compactMap(\.preview), ["safe fixture"])
        XCTAssertEqual(projected[0].panes.map(\.status), ["Working", "Documents", "Unsupported pane", "Stale", "Status unavailable"])
        XCTAssertEqual(PaneRoster.project(paneWorkspaces(), previews: false).flatMap(\.panes).compactMap(\.preview), [])
    }

    func testForegroundReadsV1PermissionAndRosterWithoutRequiringPermissionEcho() async {
        let client = PaneClientFixture()
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        XCTAssertEqual(client.calls.map(\.operation), ["get_connection_status", "list_panes"])
        XCTAssertEqual(store.panes.permission, .enabled)
        XCTAssertEqual(previews(store), ["Build complete"])
        XCTAssertEqual(store.panes.state.workspaces.map(\.id), ["workspace", "empty"])
    }

    func testBackgroundRefreshNeverRequestsPanesAndNeverPersistsPreviews() async throws {
        let client = PaneClientFixture()
        var shared: [GlanceSnapshot] = []
        let store = store(client, writeShared: { shared.append($0) })
        await store.refresh()
        XCTAssertEqual(client.calls.map(\.operation), ["get_attention_events", "list_agents"])
        XCTAssertTrue(store.reachable)
        XCTAssertEqual(store.panes.state, .idle)
        store.resumePanes()
        await store.refreshPanes()
        XCTAssertEqual(shared.count, 1)
        XCTAssertFalse(String(decoding: try XCTUnwrap(shared.first).encoded(), as: UTF8.self).contains("Build complete"))
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            guard let data = value as? Data else { return false }
            return String(decoding: data, as: UTF8.self).contains("Build complete")
        })
    }

    func testOlderHostMissingPermissionHidesPreviewsAndUnsupportedRosterKeepsAgents() async {
        let client = PaneClientFixture()
        client.allowed = nil
        let store = store(client)
        await store.refresh()
        store.resumePanes()
        await store.refreshPanes()
        XCTAssertEqual(store.panes.permission, .unsupported)
        XCTAssertEqual(previews(store), [])
        client.errors["list_panes"] = .api("unsupported_operation")
        await store.refreshPanes()
        XCTAssertEqual(store.panes.state, .unsupported)
        XCTAssertTrue(store.isConnected)
        XCTAssertNil(store.message)
        XCTAssertEqual(store.snapshot?.agents.map(\.id), ["agent"])
        client.errors = [:]
        client.workspaces = nil
        await store.refreshPanes()
        XCTAssertEqual(store.panes.state, .unsupported)
    }

    func testRosterFailureClearsContentWithoutChangingAgentConnection() async {
        let client = PaneClientFixture()
        let store = store(client)
        await store.refresh()
        store.resumePanes()
        await store.refreshPanes()
        client.errors["list_panes"] = .closed
        await store.refreshPanes()
        guard case .failed = store.panes.state else { return XCTFail("Expected pane-only failure") }
        XCTAssertEqual(previews(store), [])
        XCTAssertTrue(store.isConnected)
        XCTAssertNil(store.message)
    }

    func testOptOutDropsOldInFlightRosterAndReplacesPreviewContent() async {
        let client = PaneClientFixture()
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        let gate = RequestGate("old roster")
        client.holdNext["list_panes"] = gate
        let oldRead = Task { await store.refreshPanes() }
        await fulfillment(of: [gate.started], timeout: 3)
        await store.setTerminalPreview(false)
        XCTAssertEqual(store.panes.permission, .disabled)
        XCTAssertEqual(previews(store), [])
        gate.release()
        await oldRead.value
        XCTAssertEqual(store.panes.permission, .disabled)
        XCTAssertEqual(previews(store), [])
        client.allowed = true
        client.workspaces = [.init(workspaceID: "workspace", name: "Changed", panes: [
            .init(paneID: "shell", kind: "terminal", title: "Shell", availability: "attached")
        ])]
        await store.refreshPanes()
        XCTAssertEqual(previews(store), [], "Missing preview must replace, never merge, earlier output")
    }

    func testInvalidatedPermissionDenialCannotRevokeCurrentPairing() async {
        let client = PaneClientFixture()
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        let gate = RequestGate("stale denial")
        client.holdNext["list_panes"] = gate
        client.errors["list_panes"] = .api("permission_denied")
        let oldRead = Task { await store.refreshPanes() }
        await fulfillment(of: [gate.started], timeout: 3)
        client.errors = [:]
        await store.setTerminalPreview(false)
        gate.release()
        await oldRead.value
        XCTAssertEqual(store.panes.permission, .disabled)
        guard case .loaded = store.panes.state else { return XCTFail("Stale denial revoked current pairing") }
    }

    func testOldAgentAuthorizationReplyCannotRevokeNewPermissionEpoch() async {
        let client = PaneClientFixture()
        let store = store(client)
        await store.refresh()
        store.resumePanes()
        await store.refreshPanes()
        let gate = RequestGate("old agent denial")
        client.holdNext["list_agents"] = gate
        client.errors["list_agents"] = .api("permission_denied")
        let read = Task { await store.refresh() }
        await fulfillment(of: [gate.started], timeout: 3)
        client.errors = [:]
        await store.setTerminalPreview(false)
        gate.release()
        await read.value
        XCTAssertEqual(store.panes.permission, .disabled)
        XCTAssertTrue(store.isConnected)
        XCTAssertNotNil(store.snapshot)
    }

    func testOptInWaitsForReceiptAndStatusReadback() async {
        let client = PaneClientFixture()
        client.allowed = false
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        let gate = RequestGate("readback")
        client.holdNext["get_connection_status"] = gate
        let mutation = Task { await store.setTerminalPreview(true) }
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertEqual(store.panes.permission, .updating(true))
        XCTAssertEqual(previews(store), [])
        XCTAssertEqual(client.calls.last?.operation, "get_connection_status")
        gate.release()
        await mutation.value
        XCTAssertEqual(store.panes.permission, .enabled)
        XCTAssertEqual(previews(store), ["Build complete"])
        XCTAssertEqual(client.calls.filter { $0.operation == "set_terminal_preview" }.map(\.allowed), [true])
    }

    func testFailedOptOutClearsImmediatelyAndLaterPollCannotImplicitlyEnable() async {
        let client = PaneClientFixture()
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        let gate = RequestGate("failed opt-out")
        client.holdNext["set_terminal_preview"] = gate
        client.errors["set_terminal_preview"] = .unreachable
        let mutation = Task { await store.setTerminalPreview(false) }
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertEqual(store.panes.permission, .updating(false))
        XCTAssertEqual(previews(store), [])
        gate.release()
        await mutation.value
        guard case .failed = store.panes.permission else { return XCTFail("Expected failed permission") }
        await store.refreshPanes()
        XCTAssertEqual(previews(store), [])
        guard case .failed = store.panes.permission else { return XCTFail("Must retain deliberate change failure") }
    }

    func testUnresolvedOptOutSurvivesReadFailureAndSuspendRecoveryUntilConfirmedEnable() async {
        for suspend in [false, true] {
            let client = PaneClientFixture()
            let store = store(client)
            store.resumePanes()
            await store.refreshPanes()
            client.errors["set_terminal_preview"] = .unreachable
            await store.setTerminalPreview(false)
            XCTAssertEqual(store.panes.previewIntent, .keepOff)
            if suspend {
                store.suspendPanes()
                store.resumePanes()
            } else {
                client.errors["list_panes"] = .unreachable
                await store.refreshPanes()
                XCTAssertEqual(store.panes.permission, .unknown)
            }
            client.errors = [:]
            await store.refreshPanes()
            XCTAssertEqual(client.allowed, true, "The failed opt-out never reached the host")
            XCTAssertEqual(previews(store), [])
            XCTAssertEqual(store.panes.previewIntent, .keepOff)
            XCTAssertFalse(store.panes.permission.allowsPreview)
            await store.setTerminalPreview(true)
            XCTAssertEqual(store.panes.previewIntent, .followHost)
            XCTAssertEqual(previews(store), ["Build complete"])
        }
    }

    func testPendingEnableOwnsMutationAcrossSuspensionBeforeNewOptOutCanSend() async {
        let client = PaneClientFixture()
        client.allowed = false
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        let oldWrite = RequestGate("enable held before host mutation")
        client.holdNext["set_terminal_preview"] = oldWrite
        let enabling = Task { await store.setTerminalPreview(true) }
        await fulfillment(of: [oldWrite.started], timeout: 3)
        store.suspendPanes()
        store.resumePanes()
        XCTAssertEqual(store.panes.permission, .updating(true))
        let callsBeforeRead = client.calls.count
        await store.refreshPanes()
        XCTAssertEqual(client.calls.count, callsBeforeRead, "Polling must not release mutation ownership")
        let disabling = Task { await store.setTerminalPreview(false) }
        await waitForPermission(.updating(false), store: store)
        XCTAssertEqual(client.calls.filter { $0.operation == "set_terminal_preview" }.map(\.allowed), [true])
        XCTAssertEqual(previews(store), [])
        oldWrite.release()
        await enabling.value
        await disabling.value
        XCTAssertEqual(client.calls.filter { $0.operation == "set_terminal_preview" }.map(\.allowed), [true, false])
        XCTAssertEqual(client.allowed, false)
        XCTAssertEqual(store.panes.permission, .disabled)
        XCTAssertEqual(previews(store), [])
        // Even an ambiguous older server write observed later cannot release local opt-out intent.
        client.allowed = true
        await store.refreshPanes()
        XCTAssertEqual(previews(store), [])
        XCTAssertEqual(store.panes.previewIntent, .keepOff)
    }

    func testQueuedOptOutDrainsWhenSuspendedAfterAcceptance() async {
        await checkQueuedOptOut(suspend: true, cancelWaiter: false)
    }

    func testQueuedOptOutDrainsWhenWaitingCallerIsCancelled() async {
        await checkQueuedOptOut(suspend: false, cancelWaiter: true)
    }

    private func checkQueuedOptOut(suspend: Bool, cancelWaiter: Bool) async {
        let client = PaneClientFixture()
        client.allowed = false
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        let gate = RequestGate("enable held before queued opt-out")
        client.holdNext["set_terminal_preview"] = gate
        let enable = Task { await store.setTerminalPreview(true) }
        await fulfillment(of: [gate.started], timeout: 3)
        let disable = Task { await store.setTerminalPreview(false) }
        await waitForPermission(.updating(false), store: store)
        if suspend { store.suspendPanes() }
        if cancelWaiter { disable.cancel() }
        let latest = RequestGate("queued opt-out held after older write settles")
        client.holdNext["set_terminal_preview"] = latest
        gate.release()
        await fulfillment(of: [latest.started], timeout: 3)
        let beforePoll = client.calls.count
        await store.refreshPanes()
        XCTAssertEqual(client.calls.count, beforePoll, "No polling handoff between queued writes")
        if !suspend { XCTAssertEqual(store.panes.permission, .updating(false)) }
        latest.release()
        await enable.value
        await disable.value
        XCTAssertEqual(client.calls.filter { $0.operation == "set_terminal_preview" }.map(\.allowed), [true, false])
        XCTAssertEqual(client.allowed, false, "Accepted opt-out must reach the host without its caller or scene")
        if suspend {
            XCTAssertEqual(store.panes.permission, .unknown)
            XCTAssertEqual(store.panes.state, .idle)
            store.resumePanes()
        }
        await store.refreshPanes()
        XCTAssertEqual(store.panes.permission, .disabled, "No abandoned updating state")
        XCTAssertEqual(previews(store), [])
    }

    func testOptOutSuppressionSurvivesRecreationUntilConfirmedEnable() async {
        for fails in [true, false] {
            let client = PaneClientFixture()
            var current = store(client)
            current.resumePanes()
            await current.refreshPanes()
            if fails { client.errors["set_terminal_preview"] = .unreachable }
            await current.setTerminalPreview(false)
            current.suspendPanes()
            client.errors = [:]
            client.allowed = true // Mac re-enables, or the failed request never applied.
            current = store(client)
            XCTAssertEqual(current.panes.previewIntent, .keepOff)
            current.resumePanes()
            await current.refreshPanes()
            XCTAssertEqual(previews(current), [])
            XCTAssertFalse(current.panes.permission.allowsPreview)
            await current.setTerminalPreview(true)
            XCTAssertEqual(current.panes.previewIntent, .followHost)
            current.suspendPanes()
            current = store(client)
            current.resumePanes()
            await current.refreshPanes()
            XCTAssertEqual(previews(current), ["Build complete"], "Confirmed enable clears persisted suppression")
        }
    }

    func testSuppressionIsScopedToConnectionAndBothIdentities() async {
        let client = PaneClientFixture()
        let original = store(client)
        original.resumePanes()
        await original.refreshPanes()
        await original.setTerminalPreview(false)
        client.allowed = true
        for record in [panePairing(connectionID: UUID()), panePairing(macFingerprint: "other-mac"),
                       panePairing(identityTag: "other-phone")] {
            let different = store(client, record: record)
            different.resumePanes()
            await different.refreshPanes()
            XCTAssertEqual(different.panes.previewIntent, .followHost)
            XCTAssertEqual(previews(different), ["Build complete"])
        }
        await original.unpair()
        let recreated = store(client)
        XCTAssertEqual(recreated.panes.previewIntent, .followHost, "Unpair clears the preference")
    }

    func testOldPairingMutationCannotBlockOrReleaseReplacementWorker() async {
        let old = PaneClientFixture()
        old.allowed = false
        let next = PaneClientFixture()
        let store = store(old, makeClient: { record, _ in record.identityTag == "fixture-only" ? old : next })
        store.resumePanes()
        await store.refreshPanes()
        let oldGate = RequestGate("old pairing enable held")
        old.holdNext["set_terminal_preview"] = oldGate
        let oldEnable = Task { await store.setTerminalPreview(true) }
        await fulfillment(of: [oldGate.started], timeout: 3)
        await store.unpair()
        store.replacePairing(with: panePairing(connectionID: UUID(), identityTag: "new-phone"))
        await store.refreshPanes()
        XCTAssertEqual(previews(store), ["Build complete"], "New pairing reads must not await the old grant")
        let nextGate = RequestGate("new pairing opt-out held")
        next.holdNext["set_terminal_preview"] = nextGate
        let nextDisable = Task { await store.setTerminalPreview(false) }
        await fulfillment(of: [nextGate.started], timeout: 3)
        oldGate.release()
        await oldEnable.value
        XCTAssertEqual(store.panes.permission, .updating(false))
        let before = next.calls.count
        await store.refreshPanes()
        XCTAssertEqual(next.calls.count, before, "Old completion must not release the new worker")
        nextGate.release()
        await nextDisable.value
        XCTAssertEqual(old.allowed, true)
        XCTAssertEqual(next.allowed, false)
        XCTAssertEqual(store.panes.permission, .disabled)
        XCTAssertEqual(store.panes.previewIntent, .keepOff)
        XCTAssertEqual(previews(store), [])
    }

    func testRepeatedAuthorizationDenialsWriteOfflineSnapshotOnlyOnce() async {
        let client = PaneClientFixture()
        var shared: [GlanceSnapshot] = []
        let store = store(client, writeShared: { shared.append($0) })
        store.liveActivityEnabled = false
        await store.refresh()
        store.resumePanes()
        await store.refreshPanes()
        let before = shared.count
        client.errors["list_panes"] = .api("permission_denied")
        for _ in 0..<3 { await store.refreshPanes() }
        client.errors["list_agents"] = .api("permission_denied")
        await store.refresh()
        client.errors["get_connection_status"] = .api("permission_denied")
        await store.refreshPanes()
        XCTAssertEqual(shared.count, before + 1)
        XCTAssertEqual(shared.last?.connected, false)
        XCTAssertEqual(store.snapshot?.agents.count, 1)
        XCTAssertEqual(previews(store), [])
        client.errors = [:]
        await store.refresh()
        await store.refreshPanes()
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(previews(store), ["Build complete"])
    }

    func testPairingResetClearsLocalIntentButSceneSuspensionDoesNot() async {
        var roster = PaneRoster()
        roster.previewIntent = .keepOff
        roster.suspend()
        XCTAssertEqual(roster.previewIntent, .keepOff)
        roster.reset()
        XCTAssertEqual(roster.previewIntent, .followHost)
        let client = PaneClientFixture()
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        await store.setTerminalPreview(false)
        XCTAssertEqual(store.panes.previewIntent, .keepOff)
        await store.unpair()
        XCTAssertEqual(store.panes.previewIntent, .followHost)
    }

    private func waitForPermission(_ expected: TerminalPreviewPermission, store: CompanionStore) async {
        let ready = expectation(description: "Permission reached \(expected)")
        @Sendable func observe() {
            Task { @MainActor in
                if store.panes.permission == expected { ready.fulfill(); return }
                withObservationTracking { _ = store.panes.permission } onChange: { observe() }
            }
        }
        observe()
        await fulfillment(of: [ready], timeout: 3)
    }

    func testMismatchedAndUnsupportedMutationNeverEnablePreview() async {
        for error in [MacClientFailure.invalidResponse, .api("unsupported_operation")] {
            let client = PaneClientFixture()
            client.allowed = false
            let store = store(client)
            store.resumePanes()
            await store.refreshPanes()
            if error == .invalidResponse { client.receiptOverride = false }
            else { client.errors["set_terminal_preview"] = error }
            await store.setTerminalPreview(true)
            XCTAssertFalse(store.panes.permission.allowsPreview)
            XCTAssertEqual(previews(store), [])
        }
    }

    func testSuccessfulReceiptWithDisagreeingStatusDoesNotEnablePreview() async {
        let client = PaneClientFixture()
        client.allowed = false
        client.mutationStatusOverride = false
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        await store.setTerminalPreview(true)
        guard case .failed = store.panes.permission else { return XCTFail("Status readback must agree") }
        XCTAssertEqual(previews(store), [])
    }

    func testMacPermissionChangeRemovesPreviouslyVisiblePreview() async {
        let client = PaneClientFixture()
        let store = store(client)
        store.resumePanes()
        await store.refreshPanes()
        client.allowed = false
        await store.refreshPanes()
        XCTAssertEqual(store.panes.permission, .disabled)
        XCTAssertEqual(previews(store), [])
    }

    func testBackgroundInvalidatesUnstructuredPaneReadAndLatePermissionReceipt() async {
        for operation in ["list_panes", "set_terminal_preview"] {
            let client = PaneClientFixture()
            let store = store(client)
            store.resumePanes()
            await store.refreshPanes()
            let gate = RequestGate(operation)
            client.holdNext[operation] = gate
            let work = Task {
                if operation == "list_panes" { await store.refreshPanes() }
                else { await store.setTerminalPreview(false) }
            }
            await fulfillment(of: [gate.started], timeout: 3)
            let before = store.panes.generation
            store.suspendPanes()
            XCTAssertGreaterThan(store.panes.generation, before)
            XCTAssertEqual(store.panes.state, .idle)
            gate.release()
            await work.value
            XCTAssertEqual(store.panes.state, .idle)
            XCTAssertEqual(store.panes.permission, .unknown)
            store.resumePanes()
            await store.refreshPanes()
            XCTAssertEqual(store.panes.permission, operation == "list_panes" ? .enabled : .disabled)
        }
    }

    func testUnpairInvalidatesLatePaneRead() async {
        let client = PaneClientFixture()
        let store = store(client)
        store.resumePanes()
        let gate = RequestGate("unpair while reading")
        client.holdNext["list_panes"] = gate
        let read = Task { await store.refreshPanes() }
        await fulfillment(of: [gate.started], timeout: 3)
        await store.unpair()
        XCTAssertNil(store.record)
        gate.release()
        await read.value
        XCTAssertEqual(store.panes.state, .idle)
        XCTAssertEqual(previews(store), [])
    }

    func testAuthorizationFailureClearsPreviewsPreservesOfflineAgentsAndRecovers() async {
        for operation in ["list_agents", "list_panes", "set_terminal_preview"] {
            let client = PaneClientFixture()
            var shared: [GlanceSnapshot] = []
            let store = store(client, writeShared: { shared.append($0) })
            await store.refresh()
            store.resumePanes()
            await store.refreshPanes()
            let original = store.snapshot
            client.errors[operation] = .api("permission_denied")
            if operation == "list_agents" { await store.refresh() }
            else if operation == "list_panes" { await store.refreshPanes() }
            else { await store.setTerminalPreview(false) }
            guard case .failed = store.panes.state else { return XCTFail("Expected recoverable pane error") }
            XCTAssertEqual(previews(store), [])
            XCTAssertEqual(store.snapshot, original?.offline())
            XCTAssertEqual(shared.last, original?.offline())
            XCTAssertFalse(store.reachable)
            XCTAssertEqual(SessionSnapshotCache(defaults: defaults).restore(for: store.record), original?.offline())
            client.errors = [:]
            await store.refresh()
            await store.refreshPanes()
            XCTAssertTrue(store.isConnected)
            guard case .loaded = store.panes.state else { return XCTFail("Next valid response must recover") }
            XCTAssertEqual(previews(store), operation == "set_terminal_preview" ? [] : ["Build complete"])
        }
    }

    func testRepeatedDenialsNeverPublishTerminalContentAndIdentityReadCanRecover() async {
        let client = PaneClientFixture()
        var identityUnavailable = false
        let store = store(client, makeClient: { _, _ in
            if identityUnavailable { throw PhoneIdentity.Failure.keychain(-1) }
            return client
        })
        identityUnavailable = true
        store.resumePanes()
        await store.refreshPanes()
        XCTAssertEqual(previews(store), [])
        identityUnavailable = false
        await store.refresh()
        await store.refreshPanes()
        XCTAssertEqual(previews(store), ["Build complete"])
        client.errors["list_panes"] = .api("permission_denied")
        for _ in 0..<3 {
            await store.refreshPanes()
            XCTAssertEqual(previews(store), [])
            XCTAssertFalse(store.panes.permission.allowsPreview)
        }
        client.errors = [:]
        await store.refreshPanes()
        XCTAssertEqual(previews(store), ["Build complete"])
    }

    func testColdNotificationFocusSurvivesAgentRefreshThenUsesBothRosters() async {
        let client = PaneClientFixture()
        let store = store(client)
        store.focusedPaneID = "shell"
        await store.refresh()
        XCTAssertEqual(store.focusedPaneID, "shell")
        store.resumePanes()
        await store.refreshPanes()
        XCTAssertEqual(store.focusedPaneID, "shell")
        store.focusedPaneID = "agent"
        await store.refreshPanes()
        XCTAssertEqual(store.focusedPaneID, "agent")
        store.focusedPaneID = "exited"
        await store.refreshPanes()
        XCTAssertNil(store.focusedPaneID)
    }

    func testRepeatedPollKeepsEmptyUnsupportedAndFailedRosterStableWhileReading() async {
        for initial in ["empty", "unsupported", "failed"] {
            let client = PaneClientFixture()
            let store = store(client)
            if initial == "empty" { client.workspaces = [] }
            if initial == "unsupported" { client.errors["list_panes"] = .api("unsupported_operation") }
            if initial == "failed" { client.errors["list_panes"] = .unreachable }
            store.resumePanes()
            await store.refreshPanes()
            let previous = store.panes.state
            let gate = RequestGate("stable \(initial)")
            client.holdNext["list_panes"] = gate
            let read = Task { await store.refreshPanes() }
            await fulfillment(of: [gate.started], timeout: 3)
            XCTAssertEqual(store.panes.state, previous)
            gate.release()
            await read.value
            XCTAssertEqual(store.panes.state, previous)
        }
    }

    func testOldHostClearsUnknownNotificationOnlyAfterKnownAgentRoster() async {
        let client = PaneClientFixture()
        client.errors["list_panes"] = .api("unsupported_operation")
        let store = store(client)
        store.focusedPaneID = "exited"
        XCTAssertNil(store.focusedPaneDestination)
        store.resumePanes()
        await store.refreshPanes()
        XCTAssertEqual(store.focusedPaneID, "exited", "Cold target waits for an authoritative agent roster")
        XCTAssertNil(store.focusedPaneDestination)
        await store.refresh()
        XCTAssertNil(store.focusedPaneID)
        store.focusedPaneID = "agent"
        let known = store.focusedPaneDestination
        XCTAssertEqual(known, FocusedPaneDestination(paneID: "agent", destination: .agents))
        client.agentState = "waiting"
        await store.refresh()
        XCTAssertEqual(store.focusedPaneDestination, known, "Unrelated agent updates keep the same navigation task key")
        store.focusedPaneID = "another-exited"
        await store.refreshPanes()
        XCTAssertNil(store.focusedPaneID)
        XCTAssertNil(store.focusedPaneDestination)
    }

    func testFailedRosterNeverRoutesUnknownNotificationToSessions() async {
        let client = PaneClientFixture()
        client.errors["list_panes"] = .unreachable
        let store = store(client)
        store.focusedPaneID = "unknown"
        await store.refresh()
        store.resumePanes()
        await store.refreshPanes()
        XCTAssertEqual(store.focusedPaneID, "unknown")
        XCTAssertNil(store.focusedPaneDestination)
        client.errors = [:]
        await store.refreshPanes()
        XCTAssertNil(store.focusedPaneID)
    }

    func testPaneReadsAndConsentUsePairedDirectRoutesAndStopAtAPIDenial() async {
        let lan = PaneClientFixture()
        lan.errors = ["get_connection_status": .unreachable, "list_panes": .unreachable, "set_terminal_preview": .unreachable]
        let tailscale = PaneClientFixture()
        let record = panePairing(routes: [.init(transport: .lan, host: "lan.invalid"),
                                          .init(transport: .tailscale, host: "100.64.0.1")])
        var hosts: [String] = []
        let store = store(tailscale, record: record, makeClient: { _, route in
            hosts.append(route.host)
            return route.transport == .lan ? lan : tailscale
        })
        store.resumePanes()
        await store.refreshPanes()
        await store.setTerminalPreview(false)
        XCTAssertEqual(hosts, ["lan.invalid", "100.64.0.1"])
        XCTAssertEqual(store.activeRoute?.transport, .tailscale)
        XCTAssertTrue((lan.calls + tailscale.calls).allSatisfy { $0.connectionID == record.connectionID })
        XCTAssertEqual(tailscale.calls.filter { $0.operation == "set_terminal_preview" }.map(\.allowed), [false])
        let denied = PaneClientFixture()
        denied.errors["get_connection_status"] = .api("permission_denied")
        var deniedHosts: [String] = []
        let revoked = self.store(denied, record: record, makeClient: { _, route in
            deniedHosts.append(route.host)
            return denied
        })
        revoked.resumePanes()
        await revoked.refreshPanes()
        XCTAssertEqual(deniedHosts, ["lan.invalid"])
        guard case .failed = revoked.panes.state else { return XCTFail("Expected recoverable denial") }
    }

    private func previews(_ store: CompanionStore) -> [String] {
        store.panes.state.workspaces.flatMap(\.panes).compactMap(\.preview)
    }
}

func panePairing(routes: [CompanionRoute]? = nil,
                 connectionID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                 macFingerprint: String = "fixture-pin", identityTag: String = "fixture-only") -> PairingRecord {
    PairingRecord(macName: "Fixture Mac", host: routes == nil ? "fixture.invalid" : nil, port: 1234,
                  macFingerprint: macFingerprint, transport: routes == nil ? .lan : nil, routes: routes,
                  connectionID: connectionID, identityTag: identityTag,
                  identityStorage: .keychain, pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

func paneWorkspaces() -> [APIResponse.Workspace] {
    [.init(workspaceID: "workspace", name: "awesoMux", panes: [
        .init(paneID: "shell", kind: "terminal", title: "Build", availability: "attached", state: "running", lastOutputLine: "Build complete"),
        .init(paneID: "notes", kind: "documentGroup", title: "Notes", availability: "attached"),
        .init(paneID: "detached", kind: "terminal", title: "Remote shell", availability: "unavailable")
    ]), .init(workspaceID: "empty", name: "Personal", panes: [])]
}

@MainActor
final class RequestGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ name: String) { started = XCTestExpectation(description: name) }
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class PaneClientFixture: CompanionSessionClient {
    struct Call { let operation: String; let connectionID: UUID; let allowed: Bool? }
    var calls: [Call] = []
    var agentState = "running"
    var capturedAt = Date.now
    var allowed: Bool? = true
    var receiptOverride: Bool?
    var mutationStatusOverride: Bool?
    var workspaces: [APIResponse.Workspace]? = paneWorkspaces()
    var errors: [String: MacClientFailure] = [:]
    var holdNext: [String: RequestGate] = [:]

    func call(_ operation: String, connectionID: UUID, limit: Int?, cursor: String?) async throws -> APIResponse {
        calls.append(Call(operation: operation, connectionID: connectionID, allowed: nil))
        let response: APIResponse
        switch operation {
        case "get_connection_status": response = APIResponse(terminalPreviewAllowed: allowed)
        case "list_panes": response = APIResponse(workspaces: workspaces)
        case "get_attention_events":
            response = APIResponse(attentionEvents: .init(events: [], nextCursor: "cursor", cursorStatus: "initial", hasMore: false, currentStateRecoveryRequired: false))
        default:
            response = APIResponse(capturedAt: capturedAt, agents: [
                .init(paneID: "agent", workspaceID: "workspace", workspaceName: "awesoMux", provider: "Codex",
                      executionLocation: "local", availability: "attached", state: agentState)
            ])
        }
        let error = errors[operation]
        if let gate = holdNext.removeValue(forKey: operation) { await gate.pause() }
        if let error { throw error }
        return response
    }

    func setTerminalPreview(_ allowed: Bool, connectionID: UUID) async throws -> APIResponse {
        calls.append(Call(operation: "set_terminal_preview", connectionID: connectionID, allowed: allowed))
        let error = errors["set_terminal_preview"]
        if let gate = holdNext.removeValue(forKey: "set_terminal_preview") { await gate.pause() }
        if let error { throw error }
        self.allowed = mutationStatusOverride ?? allowed
        return APIResponse(terminalPreviewAllowed: receiptOverride ?? allowed)
    }

    func unpair(connectionID: UUID) async throws {}
}
