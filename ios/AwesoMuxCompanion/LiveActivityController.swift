@preconcurrency import ActivityKit
import Foundation

/// Drives the single Glance Live Activity from snapshots the app fetches (phase 1 has no push-to-update).
///
/// Starts when any agent needs you or is working, updates on each snapshot, and ends when
/// everything is done or the host has been out of touch for `offlineLimit`.
@MainActor
final class LiveActivityController {
    private typealias GlanceActivity = Activity<GlanceActivityAttributes>

    /// Long enough to ride out a Mac sleeping or a short network drop, short enough
    /// that a stale "3 agents working" doesn't sit on the Lock Screen all evening.
    private let offlineLimit: TimeInterval = 30 * 60
    /// The system dims the activity when no update arrives in this window, e.g. while the app is suspended.
    private let staleAfter: TimeInterval = 15 * 60
    /// Keeps the content's stale date moving forward while nothing else changes.
    private let heartbeat: TimeInterval = 60
    private var lastUpdate: (state: GlanceActivityAttributes.ContentState, at: Date)?

    func sync(_ snapshot: GlanceSnapshot, connected: Bool) async {
        let state = GlanceActivityAttributes.ContentState(snapshot, connected: connected)
        let hasWork = state.needsYou + state.working > 0
        let offlineTooLong = !connected && Date.now.timeIntervalSince(state.updatedAt) > offlineLimit
        let running = GlanceActivity.activities.filter { $0.activityState == .active }

        for activity in running.dropFirst() { await activity.end(nil, dismissalPolicy: .immediate) }
        if let activity = running.first {
            if activity.attributes.hostName != snapshot.hostName || offlineTooLong {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else if !hasWork {
                // Leave the final "all done" card briefly instead of vanishing mid-glance.
                await activity.end(content(state), dismissalPolicy: .after(.now + 5 * 60))
            } else {
                let due = lastUpdate.map { !$0.state.sameContent(as: state) || Date.now.timeIntervalSince($0.at) > heartbeat } ?? true
                if due {
                    await activity.update(content(state))
                    lastUpdate = (state, .now)
                }
                return
            }
            lastUpdate = nil
        }

        guard hasWork, connected, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try GlanceActivity.request(attributes: .init(hostName: snapshot.hostName), content: content(state))
            lastUpdate = (state, .now)
        } catch {
            // Requests fail outside the foreground; the next foreground snapshot retries.
        }
    }

    func endAll() async {
        for activity in GlanceActivity.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        lastUpdate = nil
    }

    private func content(_ state: GlanceActivityAttributes.ContentState) -> ActivityContent<GlanceActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: .now + staleAfter)
    }
}

private extension GlanceActivityAttributes.ContentState {
    func sameContent(as other: Self) -> Bool {
        needsYou == other.needsYou && working == other.working && done == other.done
            && top == other.top && connected == other.connected
    }
}
