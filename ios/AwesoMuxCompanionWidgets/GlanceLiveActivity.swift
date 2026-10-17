import ActivityKit
import SwiftUI
import WidgetKit

struct GlanceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlanceActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state, isStale: context.isStale)
                .padding(16)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CountLabel(count: state.needsYou, group: .needsYou)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountLabel(count: state.working, group: .working)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupBar(needsYou: state.needsYou, working: state.working, done: state.done)
                        TopItemLine(state: state, isStale: context.isStale)
                    }
                }
            } compactLeading: {
                Image(systemName: state.needsYou > 0 ? "bell.badge.fill" : "terminal.fill")
                    .foregroundStyle(state.needsYou > 0 ? GlanceGroup.needsYou.tint : GlanceGroup.working.tint)
            } compactTrailing: {
                Text("\(state.needsYou > 0 ? state.needsYou : state.working)")
                    .foregroundStyle(state.needsYou > 0 ? GlanceGroup.needsYou.tint : GlanceGroup.working.tint)
            } minimal: {
                Text("\(state.needsYou > 0 ? state.needsYou : state.working)")
                    .foregroundStyle(state.needsYou > 0 ? GlanceGroup.needsYou.tint : GlanceGroup.working.tint)
            }
        }
    }
}

private struct LockScreenActivityView: View {
    let state: GlanceActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(headline).font(.headline)
                Spacer(minLength: 4)
                if state.needsYou > 0 {
                    Text("\(state.needsYou) waiting")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(GlanceGroup.needsYou.tint, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            GroupBar(needsYou: state.needsYou, working: state.working, done: state.done)
            TopItemLine(state: state, isStale: isStale)
        }
    }

    private var headline: LocalizedStringKey {
        if state.working > 0 { "^[\(state.working) agent](inflect: true) working" }
        else if state.needsYou > 0 { "Waiting on you" }
        else { "All agents done" }
    }
}

private struct TopItemLine: View {
    let state: GlanceActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 4) {
            if !state.connected || isStale {
                Label("Offline", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Text("Updated \(AgeText.text(since: state.updatedAt))")
            } else if let top = state.top {
                // Workspace names truncate first so the reason ("Needs permission") stays readable.
                Text(top.workspaceName).lineLimit(1).truncationMode(.middle)
                Text("· \(top.reason)").lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let since = top.since { AgeText(date: since).multilineTextAlignment(.trailing) }
            } else {
                Text("\(state.done) done")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct CountLabel: View {
    let count: Int
    let group: GlanceGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(count)").font(.title2.weight(.semibold)).foregroundStyle(group.tint)
            Text(group.title).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Lock Screen", as: .content, using: GlanceActivityAttributes(hostName: "mac-studio")) {
    GlanceLiveActivity()
} contentStates: {
    GlanceActivityAttributes.ContentState(GlanceSnapshot.sample, connected: true)
    GlanceActivityAttributes.ContentState(GlanceSnapshot.sample, connected: false)
}
