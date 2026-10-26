import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class PhoneTerminalTests: XCTestCase {
    func testEachRefusalHasALocalizedReason() {
        let reasons = [
            "pane_exited": "This pane has exited.",
            "pane_disconnected": "This pane is disconnected. Reconnect it on your Mac.",
            "terminal_unavailable": "This terminal isn't available on your Mac.",
            "remote_workspace_unsupported": "New panes aren't available in this remote workspace.",
            "input_off": "Typing from this iPhone is off. Allow it on the Mac in Settings › Companion.",
            "stale_target": "This pane has changed. Open it again from Sessions.",
            "timeout": "Your Mac took too long to open this terminal. Try again."
        ]
        for (code, message) in reasons {
            XCTAssertEqual(WatchModel.message(for: MacClientFailure.api(code)), message)
        }
    }

    func testCreationAndInputDefaultOffForOlderMacAndRespectIndependentGrants() {
        let old = TerminalAccess(APIResponse())
        XCTAssertFalse(old.inputAllowed)
        XCTAssertFalse(old.createWorkspaceAllowed)
        XCTAssertFalse(old.createPaneAllowed)
        let off = TerminalAccess(APIResponse(terminalInputAllowed: false,
            createWorkspaceAllowed: true, createPaneAllowed: true))
        XCTAssertFalse(off.createWorkspaceAllowed)
        XCTAssertFalse(off.createPaneAllowed)
        let scoped = TerminalAccess(APIResponse(terminalInputAllowed: true,
            createWorkspaceAllowed: false, createPaneAllowed: true))
        XCTAssertTrue(scoped.inputAllowed)
        XCTAssertFalse(scoped.createWorkspaceAllowed)
        XCTAssertTrue(scoped.createPaneAllowed)
    }

    func testCreateSuccessOpensReturnedPaneReadyToType() async throws {
        let created = CreatedTerminal(workspaceID: UUID(), paneID: UUID(), targetVersion: UUID())
        let model = TerminalCreationModel()
        await model.create(workspaceID: nil, isCurrent: { true }, canCreate: { true }, send: { workspace in
            XCTAssertNil(workspace)
            return created
        }, refresh: {})
        XCTAssertEqual(model.destination?.paneID, created.paneID)
        XCTAssertEqual(model.destination?.targetVersion, created.targetVersion)
        XCTAssertEqual(model.destination?.opening, .input)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isCreating)
    }

    func testInputOffDoesNotSendCreateAndLostReplyRefreshesWithoutRetry() async {
        let model = TerminalCreationModel()
        var calls = 0
        var refreshes = 0
        let send: (UUID?) async throws -> CreatedTerminal = { _ in
            calls += 1
            throw MacClientFailure.closed
        }
        await model.create(workspaceID: nil, isCurrent: { true }, canCreate: { false }, send: send, refresh: { refreshes += 1 })
        XCTAssertEqual(calls, 0)
        await model.create(workspaceID: UUID(), isCurrent: { true }, canCreate: { true }, send: send, refresh: { refreshes += 1 })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(refreshes, 1)
        XCTAssertNil(model.destination)
        XCTAssertNotNil(model.error)
    }

    func testGrantLossMidCreateExplainsAndRefreshesWithoutOpening() async {
        let model = TerminalCreationModel()
        var allowed = true
        var refreshes = 0
        await model.create(workspaceID: nil, isCurrent: { true }, canCreate: { allowed }, send: { _ in
            allowed = false
            return CreatedTerminal(workspaceID: UUID(), paneID: UUID(), targetVersion: UUID())
        }, refresh: { refreshes += 1 })
        XCTAssertNil(model.destination)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(refreshes, 1)

        allowed = true
        await model.create(workspaceID: nil, isCurrent: { true }, canCreate: { allowed }, send: { _ in
            allowed = false
            throw MacClientFailure.api("permission_denied")
        }, refresh: { refreshes += 1 })
        XCTAssertNotNil(model.error)
        XCTAssertEqual(refreshes, 2)
    }

    func testCreateCompletionAfterLeavingPairingStaysSilent() async {
        let model = TerminalCreationModel()
        var current = true
        await model.create(workspaceID: nil, isCurrent: { current }, canCreate: { true }, send: { _ in
            current = false
            return CreatedTerminal(workspaceID: UUID(), paneID: UUID(), targetVersion: UUID())
        }, refresh: {})
        XCTAssertNil(model.destination)
        XCTAssertNil(model.error)
    }

    func testCreationRefusalIsShownAndConcurrentTapDoesNotSendTwice() async {
        let model = TerminalCreationModel()
        let gate = RequestGate("create accepted for sending")
        var calls = 0
        let send: (UUID?) async throws -> CreatedTerminal = { _ in
            calls += 1
            await gate.pause()
            throw MacClientFailure.api("remote_workspace_unsupported")
        }
        let first = Task {
            await model.create(workspaceID: UUID(), isCurrent: { true }, canCreate: { true }, send: send, refresh: {})
        }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertTrue(model.isCreating)
        await model.create(workspaceID: UUID(), isCurrent: { true }, canCreate: { true }, send: send, refresh: {})
        XCTAssertEqual(calls, 1)
        gate.release()
        await first.value
        XCTAssertEqual(model.error, "New panes aren't available in this remote workspace.")
        XCTAssertNil(model.destination)
        XCTAssertFalse(model.isCreating)
    }

    func testCreateRequestOmitsWorkspaceInsteadOfNullAndReceiptRequiresMatchingIdentity() throws {
        for workspace in [nil, UUID()] {
            let request = CreateTerminalRequest(connectionID: UUID(), workspaceID: workspace)
            let data = try CompanionProtocol.encoder().encode(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["operation"] as? String, "create_terminal")
            XCTAssertEqual(json["workspaceID"] as? String, workspace?.uuidString)
            XCTAssertEqual(Set(json.keys), Set(["schemaVersion", "requestID", "operation", "connectionID"] + (workspace == nil ? [] : ["workspaceID"])))
            let created = CreatedTerminal(workspaceID: UUID(), paneID: UUID(), targetVersion: UUID())
            let receipt = CreateTerminalResponse(schemaVersion: 1, requestID: request.requestID,
                error: nil, createdTerminal: created)
            let encoded = try CompanionProtocol.encoder().encode(receipt)
            XCTAssertEqual(try MacClient.createdTerminal(from: encoded, requestID: request.requestID), created)
            XCTAssertThrowsError(try MacClient.createdTerminal(from: encoded, requestID: UUID()))
            let denied = CreateTerminalResponse(schemaVersion: 1, requestID: request.requestID,
                error: "remote_workspace_unsupported", createdTerminal: nil)
            XCTAssertThrowsError(try MacClient.createdTerminal(from: CompanionProtocol.encoder().encode(denied), requestID: request.requestID)) {
                XCTAssertEqual($0 as? MacClientFailure, .api("remote_workspace_unsupported"))
            }
        }
    }
}
