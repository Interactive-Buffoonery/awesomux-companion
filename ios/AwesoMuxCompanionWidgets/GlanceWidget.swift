import SwiftUI
import WidgetKit

@main
struct GlanceWidgetsBundle: WidgetBundle {
    var body: some Widget {
        GlanceWidget()
        GlanceLiveActivity()
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let snapshot: GlanceSnapshot?
}

/// Reads the snapshot the app writes to the App Group; the app reloads timelines whenever it changes.
struct GlanceTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry { GlanceEntry(date: .now, snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let snapshot = SharedSnapshot.read()
        completion(GlanceEntry(date: .now, snapshot: snapshot ?? (context.isPreview ? .sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        completion(Timeline(entries: [GlanceEntry(date: .now, snapshot: SharedSnapshot.read())], policy: .never))
    }
}

struct GlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlanceWidget", provider: GlanceTimelineProvider()) { entry in
            GlanceWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("See which agents need you, are working, or are done.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct GlanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: GlanceSnapshot?

    var body: some View {
        if let snapshot {
            switch family {
            case .accessoryCircular: circular(snapshot)
            case .accessoryRectangular: rectangular(snapshot)
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            switch family {
            case .accessoryCircular: Image(systemName: "desktopcomputer")
            default:
                Label("Open awesoMux to connect your Mac", systemImage: "desktopcomputer")
                    .font(.footnote)
            }
        }
    }

    private func small(_ snapshot: GlanceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            counts(snapshot)
            Spacer(minLength: 0)
            if let top = snapshot.agents(in: .needsYou).first {
                Text(top.workspaceName).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(top.status).font(.caption2).foregroundStyle(.orange).lineLimit(1)
            } else {
                offlineOrHost(snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ snapshot: GlanceSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                counts(snapshot)
                Spacer(minLength: 0)
                offlineOrHost(snapshot)
            }
            VStack(alignment: .leading, spacing: 8) {
                GroupBar(needsYou: snapshot.count(.needsYou), working: snapshot.count(.working), done: snapshot.count(.done))
                if let top = snapshot.topAgent {
                    HStack(spacing: 8) {
                        ProviderAvatar(provider: top.provider, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(top.workspaceName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(top.status).font(.caption)
                                .foregroundStyle(top.group == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                            HStack(spacing: 0) {
                                Text(top.provider)
                                if let since = top.since { Text(" · "); AgeText(date: since) }
                            }
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    Text("All agents are done").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rectangular(_ snapshot: GlanceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(snapshot.count(.needsYou)) need you · \(snapshot.count(.working)) working")
                .font(.headline).widgetAccentable()
            if let top = snapshot.agents(in: .needsYou).first {
                Text("\(top.workspaceName) · \(top.status)").lineLimit(1)
            } else {
                Text("\(snapshot.count(.done)) done").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circular(_ snapshot: GlanceSnapshot) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: snapshot.count(.needsYou) > 0 ? "bell.badge.fill" : "terminal.fill")
                Text("\(snapshot.count(.needsYou) > 0 ? snapshot.count(.needsYou) : snapshot.count(.working))")
                    .font(.title3.weight(.semibold)).widgetAccentable()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.count(.needsYou)) need you, \(snapshot.count(.working)) working")
    }

    private func counts(_ snapshot: GlanceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(GlanceGroup.allCases) { group in
                HStack(spacing: 6) {
                    Circle().fill(group.tint).frame(width: 8, height: 8)
                    Text("\(snapshot.count(group))").font(.headline.monospacedDigit())
                    Text(group.title).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func offlineOrHost(_ snapshot: GlanceSnapshot) -> some View {
        if snapshot.connected {
            Text(snapshot.hostName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Label("Offline", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
        }
    }
}

extension GlanceSnapshot {
    static let sample = GlanceSnapshot(
        schemaVersion: 1, hostName: "mac-studio", connected: true, error: nil, updatedAt: .now,
        agents: [
            GlanceAgent(id: "p1", workspaceName: "ssh-health-warning", provider: "Claude Code", group: .needsYou,
                        state: "needsAttention", reason: "permissionPrompt", since: .now - 120),
            GlanceAgent(id: "p2", workspaceName: "local-api-push", provider: "Codex", group: .working,
                        state: "running", reason: nil, since: .now - 30),
            GlanceAgent(id: "p3", workspaceName: "palette-fix", provider: "OpenCode", group: .working,
                        state: "thinking", reason: nil, since: .now - 60),
            GlanceAgent(id: "p4", workspaceName: "markdown-refresh", provider: "Claude Code", group: .done,
                        state: "done", reason: nil, since: .now - 18 * 60),
        ])
}

#Preview("Small", as: .systemSmall) { GlanceWidget() } timeline: { GlanceEntry(date: .now, snapshot: .sample) }
#Preview("Medium", as: .systemMedium) { GlanceWidget() } timeline: { GlanceEntry(date: .now, snapshot: .sample) }
#Preview("Rectangular", as: .accessoryRectangular) { GlanceWidget() } timeline: { GlanceEntry(date: .now, snapshot: .sample) }
