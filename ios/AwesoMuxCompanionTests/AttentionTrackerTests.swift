import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

final class AttentionTrackerTests: XCTestCase {
    func testResolvedAlertIsNotPendingFromSamePage() throws {
        var tracker = AttentionTracker(readingInitialHistory: false)
        var pending: [APIResponse.Event] = []
        let raised = event(id: "event-1", attentionID: "attention-1", change: "raised")
        let resolved = event(id: "event-2", attentionID: "attention-1", change: "resolved")

        try tracker.apply([raised, resolved], cursorStatus: "current", pendingAlerts: &pending)

        XCTAssertTrue(tracker.openAlerts.isEmpty)
        XCTAssertTrue(pending.isEmpty)
    }

    func testResolvedAlertIsNotPendingAcrossPages() throws {
        var tracker = AttentionTracker(readingInitialHistory: false)
        var pending: [APIResponse.Event] = []

        try tracker.apply(
            [event(id: "event-1", attentionID: "attention-1", change: "raised")],
            cursorStatus: "current",
            pendingAlerts: &pending)
        try tracker.apply(
            [event(id: "event-2", attentionID: "attention-1", change: "resolved")],
            cursorStatus: "current",
            pendingAlerts: &pending)

        XCTAssertTrue(tracker.openAlerts.isEmpty)
        XCTAssertTrue(pending.isEmpty)
    }

    func testResolvingOneAlertKeepsOtherAlertPending() throws {
        var tracker = AttentionTracker(readingInitialHistory: false)
        var pending: [APIResponse.Event] = []
        let queuedToResolve = event(id: "event-1", attentionID: "attention-1", change: "raised")
        let stillOpen = event(id: "event-2", attentionID: "attention-2", change: "raised")

        try tracker.apply([queuedToResolve, stillOpen], cursorStatus: "current", pendingAlerts: &pending)
        try tracker.apply(
            [event(id: "event-3", attentionID: "attention-1", change: "resolved")],
            cursorStatus: "current",
            pendingAlerts: &pending)

        XCTAssertEqual(Set(tracker.openAlerts.keys), ["attention-2"])
        XCTAssertEqual(pending.map(\.attentionID), ["attention-2"])
    }

    func testInitialHistoryDoesNotQueueAlerts() throws {
        var tracker = AttentionTracker()
        var pending: [APIResponse.Event] = []

        try tracker.apply(
            [event(id: "event-1", attentionID: "attention-1", change: "raised")],
            cursorStatus: "initial",
            pendingAlerts: &pending)

        XCTAssertEqual(Set(tracker.openAlerts.keys), ["attention-1"])
        XCTAssertTrue(pending.isEmpty)
    }

    private func event(id: String, attentionID: String, change: String) -> APIResponse.Event {
        APIResponse.Event(
            id: id,
            attentionID: attentionID,
            change: change,
            paneID: "pane-1",
            workspaceID: "workspace-1",
            provider: "Codex",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            reason: "userInputRequired")
    }
}
