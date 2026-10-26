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
        // The app cannot refresh while suspended; show the age without declaring the Mac offline.
        guard let snapshot = SharedSnapshot.read(), snapshot.connected, let updatedAt = snapshot.updatedAt else {
            return completion(Timeline(entries: [GlanceEntry(date: .now, snapshot: SharedSnapshot.read())], policy: .never))
        }
        let showsAge = updatedAt + SharedSnapshot.freshFor
        let entries = showsAge <= .now
            ? [GlanceEntry(date: .now, snapshot: snapshot)]
            : [GlanceEntry(date: .now, snapshot: snapshot), GlanceEntry(date: showsAge, snapshot: snapshot)]
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct GlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GlanceWidget", provider: GlanceTimelineProvider()) { entry in
            GlanceWidgetView(snapshot: entry.snapshot, date: entry.date)
                .containerBackground(Cat.base, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("See which agents need you, are working, or are done.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct GlanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: GlanceSnapshot?
    let date: Date

    var body: some View {
        if let snapshot {
            let status = GlanceStatus(connected: snapshot.connected, updatedAt: snapshot.updatedAt, now: date)
            switch family {
            case .accessoryCircular: circular(snapshot, status)
            case .accessoryRectangular: rectangular(snapshot, status)
            case .systemMedium: medium(snapshot, status).foregroundStyle(Cat.text)
            default: small(snapshot, status).foregroundStyle(Cat.text)
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

    private func small(_ snapshot: GlanceSnapshot, _ status: GlanceStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            counts(snapshot)
            Spacer(minLength: 0)
            if status == .current, let top = snapshot.agents(in: .needsYou).first {
                Text(top.workspaceName).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(top.status).font(.caption2).foregroundStyle(Cat.needs).lineLimit(1)
            } else {
                offlineOrHost(snapshot, status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ snapshot: GlanceSnapshot, _ status: GlanceStatus) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                counts(snapshot)
                Spacer(minLength: 0)
                offlineOrHost(snapshot, status)
            }
            VStack(alignment: .leading, spacing: 8) {
                GroupBar(needsYou: snapshot.count(.needsYou), working: snapshot.count(.working), done: snapshot.count(.done))
                if let top = snapshot.topAgent {
                    HStack(spacing: 8) {
                        ProviderAvatar(provider: top.provider, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(top.workspaceName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(top.status).font(.caption)
                                .foregroundStyle(top.group == .needsYou ? Cat.needs : Cat.subtext0)
                                .lineLimit(1)
                            HStack(spacing: 0) {
                                Text(top.provider)
                                if let since = top.since { Text(" · "); AgeText(date: since) }
                            }
                            .font(.caption2).foregroundStyle(Cat.subtext0).lineLimit(1)
                        }
                    }
                } else {
                    Text("All agents are done").font(.subheadline).foregroundStyle(Cat.subtext0)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rectangular(_ snapshot: GlanceSnapshot, _ status: GlanceStatus) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(snapshot.count(.needsYou)) need you · \(snapshot.count(.working)) working")
                .font(.headline).widgetAccentable()
            if status != .current {
                GlanceStatusLabel(status: status).lineLimit(1)
            } else if let top = snapshot.agents(in: .needsYou).first {
                Text("\(top.workspaceName) · \(top.status)").lineLimit(1)
            } else {
                Text("\(snapshot.count(.done)) done").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circular(_ snapshot: GlanceSnapshot, _ status: GlanceStatus) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                switch status {
                case .current:
                    Image(systemName: snapshot.count(.needsYou) > 0 ? "bell.badge.fill" : "terminal.fill")
                    Text("\(snapshot.count(.needsYou) > 0 ? snapshot.count(.needsYou) : snapshot.count(.working))")
                        .font(.title3.weight(.semibold)).widgetAccentable()
                case .updated(let date):
                    Image(systemName: "clock")
                    AgeText(date: date).font(.caption2)
                case .offline:
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Offline").font(.caption2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(circularAccessibilityLabel(snapshot, status))
    }

    private func circularAccessibilityLabel(_ snapshot: GlanceSnapshot, _ status: GlanceStatus) -> Text {
        switch status {
        case .current:
            Text("\(snapshot.count(.needsYou)) need you, \(snapshot.count(.working)) working")
        case .updated(let date): Text("Updated \(AgeText.text(since: date)) ago")
        case .offline: Text("Offline")
        }
    }

    private func counts(_ snapshot: GlanceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(GlanceGroup.allCases) { group in
                HStack(spacing: 6) {
                    Circle().fill(group.tint).frame(width: 8, height: 8)
                    Text("\(snapshot.count(group))").font(.headline.monospacedDigit())
                    Text(group.title).font(.caption).foregroundStyle(Cat.subtext0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func offlineOrHost(_ snapshot: GlanceSnapshot, _ status: GlanceStatus) -> some View {
        if status == .current {
            Text(snapshot.hostName).font(.caption2).foregroundStyle(Cat.subtext0).lineLimit(1)
        } else {
            GlanceStatusLabel(status: status).font(.caption2).foregroundStyle(Cat.subtext0).lineLimit(1)
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
