import SwiftUI

struct AgentsView: View {
    @Bindable var store: CompanionStore
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let snapshot = store.snapshot {
                        agentSections(snapshot)
                    } else {
                        emptyState
                    }
                    hostSection
                }
                .listStyle(.insetGrouped)
                .onChange(of: store.focusedPaneID) { _, paneID in
                    guard let paneID else { return }
                    withAnimation { proxy.scrollTo(paneID, anchor: .center) }
                }
                .task(id: store.focusedPaneID) {
                    guard store.focusedPaneID != nil else { return }
                    try? await Task.sleep(for: .seconds(3))
                    store.focusedPaneID = nil
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                if let snapshot = store.snapshot {
                    ToolbarItem(placement: .topBarTrailing) { ConnectionIndicator(connected: store.isConnected, updatedAt: snapshot.updatedAt) }
                }
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $pairing) { PairHostView(store: store) }
        }
    }

    @ViewBuilder private func agentSections(_ snapshot: GlanceSnapshot) -> some View {
        if let message = store.message {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        if snapshot.agents.isEmpty {
            ContentUnavailableView("No agents running", systemImage: "moon.zzz",
                description: Text("Agents you start in awesoMux on \(snapshot.hostName) show up here."))
                .listRowBackground(Color.clear)
        }
        ForEach(GlanceGroup.allCases) { group in
            let agents = snapshot.agents(in: group)
            if !agents.isEmpty {
                Section(group.title) {
                    ForEach(agents) { agent in
                        AgentRow(agent: agent)
                            .id(agent.id)
                            .listRowBackground(store.focusedPaneID == agent.id ? Color.orange.opacity(0.18) : nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if store.activeHostLabel == nil && store.connectionState != .loadFailed {
            ContentUnavailableView {
                Label("Connect your Mac", systemImage: "desktopcomputer")
            } description: {
                Text("See which agents need you, are working, or are done.")
            } actions: {
                if store.canPair { Button("Connect a host") { pairing = true }.buttonStyle(.borderedProminent) }
            }
            .listRowBackground(Color.clear)
        } else {
            ContentUnavailableView(store.message ?? String(localized: "Connecting…"), systemImage: "antenna.radiowaves.left.and.right")
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder private var hostSection: some View {
        Section {
            if case .quarantined(let priorHost) = store.connectionState {
                Button("Retry \(priorHost ?? String(localized: "saved host"))") { retryConnection() }
            } else if store.connectionState == .loadFailed {
                Button("Retry saved connection") { retryConnection() }
            }
            if store.canPair && store.activeHostLabel != nil { Button("Change host") { pairing = true } }
            if store.activeHostLabel != nil || store.connectionState == .loadFailed {
                Button("Disconnect host", role: .destructive) { try? store.disconnectHost() }
            }
        } footer: {
            if let host = store.activeHostLabel { Text(host).textSelection(.enabled) }
        }
    }

    private func retryConnection() {
        do { try store.retryConnection(); Task { await store.refresh() } } catch { /* The store keeps an actionable message. */ }
    }
}

private struct AgentRow: View {
    let agent: GlanceAgent

    var body: some View {
        HStack(spacing: 12) {
            ProviderAvatar(provider: agent.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.workspaceName).font(.body.weight(.medium))
                Text("\(agent.provider) · \(agent.status)")
                    .font(.subheadline)
                    .foregroundStyle(agent.group == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 8)
            if let since = agent.since {
                AgeText(date: since).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var sentence = String(localized: "\(agent.provider) in \(agent.workspaceName): \(agent.status)")
        if let since = agent.since {
            sentence += ", " + since.formatted(.relative(presentation: .named, unitsStyle: .wide))
        }
        return sentence
    }
}

private struct ConnectionIndicator: View {
    let connected: Bool
    let updatedAt: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill").imageScale(.small)
                .foregroundStyle(connected ? .green : .orange)
            if connected {
                Text("Connected")
            } else {
                Text("Offline · \(AgeText.text(since: updatedAt))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected
            ? String(localized: "Connected to your Mac")
            : String(localized: "Offline, last updated \(updatedAt.formatted(.relative(presentation: .named)))"))
    }
}
