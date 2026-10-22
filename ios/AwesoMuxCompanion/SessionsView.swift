import SwiftUI

struct CompanionTabs: View {
    let store: CompanionStore
    @State private var selection: CompanionDestination = .sessions

    var body: some View {
        TabView(selection: $selection) {
            Tab("Sessions", systemImage: "rectangle.split.2x2", value: CompanionDestination.sessions) {
                SessionsView(store: store)
            }
            Tab("Agents", systemImage: "person.2", value: CompanionDestination.agents) {
                AgentsView(store: store)
            }
        }
        .task(id: store.focusedPaneDestination) {
            if let target = store.focusedPaneDestination { selection = target.destination }
        }
    }
}

struct SessionsView: View {
    let store: CompanionStore
    @Environment(TerminalLockModel.self) private var terminalLock

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let record = store.record {
                        Section {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.macName).font(.subheadline.weight(.semibold)).foregroundStyle(Cat.text)
                                MacStatusLine(store: store)
                            }
                        }
                        .listRowBackground(Cat.card)
                    }
                    roster
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Cat.page)
                .task(id: visibleFocusedPaneID) {
                    guard let paneID = visibleFocusedPaneID else { return }
                    await Task.yield()
                    guard !Task.isCancelled, visibleFocusedPaneID == paneID else { return }
                    withAnimation { proxy.scrollTo(paneID, anchor: .center) }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard !terminalLock.isLocked, store.focusedPaneID == paneID else { return }
                    store.focusedPaneID = nil
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView(store: store) } label: {
                        Image(systemName: "gearshape").accessibilityLabel("Settings")
                    }
                }
            }
            .refreshable { await store.refreshPanes() }
        }
    }

    private var visibleFocusedPaneID: String? {
        guard !terminalLock.isLocked, let id = store.focusedPaneID,
              store.panes.state.workspaces.contains(where: { $0.panes.contains(where: { $0.id == id }) }) else { return nil }
        return id
    }

    @ViewBuilder private var roster: some View {
        switch store.panes.state {
        case .idle, .loading:
            ProgressView("Loading sessions…").listRowBackground(Cat.card)
        case .unsupported:
            ContentUnavailableView("Update awesoMux on your Mac", systemImage: "desktopcomputer",
                                   description: Text("This Mac doesn't support the pane list yet. Your agents are still available in Agents."))
                .listRowBackground(Color.clear)
        case .failed(let message):
            Section {
                Text(message).foregroundStyle(Cat.subtext0)
                Button("Try Again") { Task { await store.refreshPanes() } }
            }
            .listRowBackground(Cat.card)
        case .loaded(let workspaces):
            TerminalPreviewSection(store: store)
            if workspaces.isEmpty {
                ContentUnavailableView("No workspaces", systemImage: "rectangle.split.2x2",
                                       description: Text("Workspaces you open on your Mac appear here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(workspaces) { workspace in
                Section {
                    if workspace.panes.isEmpty {
                        Text("No panes").foregroundStyle(Cat.subtext0)
                    }
                    ForEach(workspace.panes) { pane in
                        Group {
                            if pane.kind == .terminal, pane.availability == "attached",
                               let paneID = UUID(uuidString: pane.id),
                               let version = pane.targetVersion.flatMap(UUID.init(uuidString:)) {
                                NavigationLink {
                                    WatchView(store: store, paneID: paneID, targetVersion: version, title: pane.title, terminalLock: terminalLock)
                                } label: { PaneRow(pane: pane) }
                            } else {
                                PaneRow(pane: pane)
                            }
                        }
                            .id(pane.id)
                            .listRowBackground(store.focusedPaneID == pane.id ? Cat.needs.opacity(0.18) : Cat.card)
                    }
                } header: { Text(workspace.name).foregroundStyle(Cat.subtext0) }
                .listRowBackground(Cat.card)
            }
        }
    }
}

private struct PaneRow: View {
    let pane: ListedPane

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Cat.accent).frame(width: 24)
                .padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title.isEmpty ? String(localized: "Untitled pane") : pane.title)
                    .font(.body.weight(.medium)).foregroundStyle(Cat.text)
                Text(pane.status).font(.subheadline).foregroundStyle(Cat.subtext0)
                if let preview = pane.preview, !preview.isEmpty {
                    Text(verbatim: preview).font(.footnote.monospaced()).foregroundStyle(Cat.subtext0)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch pane.kind {
        case .terminal: "terminal"
        case .documents: "doc.on.doc"
        case .unknown: "questionmark.square"
        }
    }
}

struct TerminalPreviewSection: View {
    let store: CompanionStore
    @State private var confirmingPreview = false

    var body: some View {
        Section {
            switch store.panes.permission {
            case .unknown:
                Text("Checking preview permission…").foregroundStyle(Cat.subtext0)
            case .unsupported:
                Text("Terminal previews aren't available on this Mac.").foregroundStyle(Cat.subtext0)
            case .updating(let allowed):
                ProgressView(allowed ? "Enabling previews…" : "Turning previews off…")
            case .enabled:
                Toggle("Terminal previews", isOn: previewBinding)
            case .disabled:
                Toggle("Terminal previews", isOn: previewBinding)
            case .failed(let message):
                Text(message).foregroundStyle(Cat.subtext0)
                Button("Turn Previews Off") { Task { await store.setTerminalPreview(false) } }
                Button("Enable Previews…") { confirmingPreview = true }
            }
        } header: {
            Text("Terminal previews").foregroundStyle(Cat.subtext0)
        } footer: {
            Text("Share the last nonblank line of each terminal's active screen directly from your Mac. It may include secrets. Previews stay in this app and aren't saved.")
                .foregroundStyle(Cat.subtext0)
        }
        .foregroundStyle(Cat.text)
        .listRowBackground(Cat.card)
        .confirmationDialog("Show terminal previews on this iPhone?", isPresented: $confirmingPreview, titleVisibility: .visible) {
            Button("Enable Previews") { Task { await store.setTerminalPreview(true) } }
        } message: {
            Text("Terminal text can include passwords, tokens and other sensitive content. This changes preview permission for this iPhone on your Mac.")
        }
    }

    private var previewBinding: Binding<Bool> {
        Binding(get: { store.panes.permission.allowsPreview }, set: { allowed in
            if allowed { confirmingPreview = true } else { Task { await store.setTerminalPreview(false) } }
        })
    }
}
