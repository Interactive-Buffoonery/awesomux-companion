import SwiftUI

struct AgentsView: View {
    @Bindable var store: CompanionStore

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let record = store.record {
                        Section {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.macName).font(.subheadline.weight(.semibold)).foregroundStyle(Cat.text)
                                MacStatusLine(store: store, transport: record.transport)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .listRowBackground(Cat.card)
                    }
                    if let message = store.message {
                        Section {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(message)
                                    Button("Try Again") { Task { await store.refresh() } }
                                        .buttonStyle(.borderless)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Cat.accent)
                                }
                            }
                            .font(.subheadline).foregroundStyle(Cat.subtext0)
                        }
                        .listRowBackground(Cat.card)
                    }
                    if let snapshot = store.snapshot {
                        agentSections(snapshot)
                    } else if store.message == nil {
                        ContentUnavailableView(String(localized: "Connecting…"), systemImage: "antenna.radiowaves.left.and.right")
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Cat.page)
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
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView(store: store) } label: {
                        Image(systemName: "gearshape").accessibilityLabel("Settings")
                    }
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder private func agentSections(_ snapshot: GlanceSnapshot) -> some View {
        if snapshot.agents.isEmpty {
            ContentUnavailableView {
                Label {
                    Text(snapshot.connected ? "No agents running" : "No agents when last checked")
                } icon: {
                    Image(systemName: "moon.zzz").accessibilityHidden(true)
                }
            } description: {
                if snapshot.connected {
                    Text("Agents you start in awesoMux on \(snapshot.hostName) show up here.")
                } else if let updatedAt = snapshot.updatedAt {
                    Text("Last update from \(snapshot.hostName) at \(lastUpdate(updatedAt)).")
                } else {
                    Text("\(snapshot.hostName) can't be reached right now.")
                }
            }
            .listRowBackground(Color.clear)
        }
        ForEach(GlanceGroup.allCases) { group in
            let agents = snapshot.agents(in: group)
            if !agents.isEmpty {
                Section {
                    ForEach(agents) { agent in
                        AgentRow(agent: agent)
                            .id(agent.id)
                            .listRowBackground(store.focusedPaneID == agent.id ? Cat.needs.opacity(0.18) : Cat.card)
                    }
                } header: {
                    Text(group.title).foregroundStyle(group.tint)
                }
            }
        }
    }

    private func lastUpdate(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AgentRow: View {
    let agent: GlanceAgent

    var body: some View {
        HStack(spacing: 12) {
            ProviderAvatar(provider: agent.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.workspaceName).font(.body.weight(.medium)).foregroundStyle(Cat.text)
                Text("\(agent.provider) · \(agent.status)")
                    .font(.subheadline)
                    .foregroundStyle(agent.group == .needsYou ? Cat.needs : Cat.subtext0)
            }
            Spacer(minLength: 8)
            if let since = agent.since {
                AgeText(date: since).font(.footnote).foregroundStyle(Cat.subtext0).monospacedDigit()
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
