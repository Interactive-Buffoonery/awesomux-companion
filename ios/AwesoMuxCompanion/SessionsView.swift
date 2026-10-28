import SwiftUI

struct SessionsView: View {
    let store: CompanionStore
    @Environment(TerminalLockModel.self) private var terminalLock
    @Environment(PendingDecisionsModel.self) private var decisions
    @Environment(\.scenePhase) private var scenePhase
    @State private var creation = TerminalCreationModel()
    @State private var destination: TerminalDestination?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let message = store.message {
                        Button { Task { await store.refresh() } } label: {
                            SystemLine(text: "[\(message) · tap to retry]")
                        }
                        .terminalRow()
                    }
                    if !decisions.pending.isEmpty || !decisions.outcomes.isEmpty {
                        NavigationLink { DecisionsView(store: store) } label: {
                            TerminalRow(glyph: .agent, title: String(localized: "permission requests"),
                                        tag: decisions.pending.isEmpty ? nil : "\(decisions.pending.count)",
                                        detail: String(localized: "Claude is asking to run a tool"))
                        }
                        .terminalRow()
                    }
                    roster
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Cat.page)
                .environment(\.defaultMinListRowHeight, 0)
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
            .terminalTitle(store.record?.macName ?? String(localized: "Sessions"), subtitle: connectionLine)
            .toolbarBackground(Cat.page, for: .navigationBar)
            .navigationDestination(item: $destination) { target in
                WatchView(store: store, target: target, terminalLock: terminalLock)
            }
            .onChange(of: creation.destination) { _, target in
                if let target { destination = target; creation.destination = nil }
            }
            .alert("Couldn't create terminal", isPresented: Binding(
                get: { creation.error != nil }, set: { if !$0 { creation.error = nil } })) {
                Button("OK", role: .cancel) { creation.error = nil }
            } message: { Text(creation.error ?? "") }
            .toolbar {
                if store.panes.terminalAccess.createWorkspaceAllowed {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { createTerminal(in: nil) } label: {
                            Image(systemName: "plus").accessibilityLabel("New Workspace")
                        }
                        .disabled(creation.isCreating)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView(store: store) } label: {
                        Image(systemName: "gearshape").accessibilityLabel("Settings")
                    }
                }
            }
            .refreshable {
                await store.refresh()
                await store.refreshPanes()
                await decisions.refresh()
            }
        }
    }

    /// "lan · checked 1 min ago" in place of the old Mac card.
    private var connectionLine: String {
        guard let updatedAt = store.snapshot?.updatedAt else {
            return store.message == nil ? String(localized: "connecting…") : String(localized: "offline")
        }
        let age = updatedAt.formatted(.relative(presentation: .named))
        if store.isConnected, let route = store.activeRoute {
            return "\(route.transport.title.lowercased()) · \(age)"
        }
        return String(localized: "offline · \(age)")
    }

    private func createTerminal(in workspaceID: UUID?, named workspaceName: String = "") {
        let pairing = store.decisionPairing
        let current: @MainActor @Sendable () -> Bool = {
            scenePhase == .active && terminalLock.isActive && !terminalLock.isLocked
                && pairing != nil && store.decisionPairing == pairing
                && !store.showingPairing && store.pairingStep == .idle
        }
        let permitted: @MainActor @Sendable () -> Bool = {
            guard current() else { return false }
            return workspaceID == nil ? store.panes.terminalAccess.createWorkspaceAllowed : store.panes.terminalAccess.createPaneAllowed
        }
        Task {
            await creation.create(workspaceID: workspaceID, workspaceName: workspaceName, isCurrent: current, canCreate: permitted, send: { workspaceID in
                try await store.createTerminal(workspaceID: workspaceID, canSend: permitted)
            }, refresh: { await store.refreshPanes() })
        }
    }

    private var visibleFocusedPaneID: String? {
        guard !terminalLock.isLocked, let id = store.focusedPaneID else { return nil }
        let listed = store.panes.state.workspaces.contains { $0.panes.contains { $0.id == id } }
            || unlistedAgents.contains { $0.id == id }
        return listed ? id : nil
    }

    /// Agents the pane list doesn't show: all of them on older Macs, or any missing from a loaded list.
    private var unlistedAgents: [GlanceAgent] {
        let agents = store.snapshot?.agents ?? []
        switch store.panes.state {
        case .unsupported: return agents
        case .loaded(let workspaces):
            return agents.filter { agent in !workspaces.contains { $0.panes.contains { $0.id == agent.id } } }
        default: return []
        }
    }

    private func agentRow(_ agent: GlanceAgent) -> some View {
        TerminalRow(glyph: PaneGlyph(agent: agent), title: agent.workspaceName, tag: agent.provider,
                    since: agent.since, detail: agent.status)
            .id(agent.id)
            .terminalRow(focused: store.focusedPaneID == agent.id)
    }

    private func agent(for pane: ListedPane) -> GlanceAgent? {
        store.snapshot?.agents.first { $0.id == pane.id }
    }

    @ViewBuilder private var roster: some View {
        switch store.panes.state {
        case .idle, .loading:
            SystemLine(text: String(localized: "loading sessions…")).terminalRow()
        case .unsupported:
            // Older Macs have no pane list; agents still come from the glance snapshot.
            SystemLine(text: String(localized: "update awesoMux on your Mac to see every pane")).terminalRow()
            ForEach(unlistedAgents, content: agentRow)
        case .failed(let message):
            Button { Task { await store.refreshPanes() } } label: {
                SystemLine(text: "[\(message) · tap to retry]")
            }
            .terminalRow()
        case .loaded(let workspaces):
            if workspaces.isEmpty {
                SystemLine(text: String(localized: "no workspaces · open one on your Mac")).terminalRow()
            }
            ForEach(workspaces) { workspace in
                Section {
                    if workspace.panes.isEmpty {
                        SystemLine(text: String(localized: "no panes")).terminalRow()
                    }
                    ForEach(sorted(workspace.panes)) { pane in
                        paneRow(pane, in: workspace)
                            .id(pane.id)
                            .terminalRow(focused: store.focusedPaneID == pane.id)
                    }
                    if store.panes.terminalAccess.createPaneAllowed,
                       let workspaceID = UUID(uuidString: workspace.id) {
                        Button { createTerminal(in: workspaceID, named: workspace.name) } label: {
                            SystemLine(text: String(localized: "+ new pane"))
                        }
                        .accessibilityLabel("New Pane")
                        .disabled(creation.isCreating)
                        .terminalRow()
                    }
                } header: {
                    WorkspaceRule(name: workspace.name)
                }
                .listSectionSeparator(.hidden)
            }
            if !unlistedAgents.isEmpty {
                Section {
                    ForEach(unlistedAgents, content: agentRow)
                } header: {
                    WorkspaceRule(name: String(localized: "other agents"))
                }
                .listSectionSeparator(.hidden)
            }
        }
    }

    /// Rows that need you float to the top; everything else keeps the Mac's order.
    private func sorted(_ panes: [ListedPane]) -> [ListedPane] {
        panes.enumerated().sorted { lhs, rhs in
            let left = PaneGlyph(pane: lhs.element, agent: agent(for: lhs.element)).needsYou
            let right = PaneGlyph(pane: rhs.element, agent: agent(for: rhs.element)).needsYou
            return left != right ? left : lhs.offset < rhs.offset
        }.map(\.element)
    }

    @ViewBuilder private func paneRow(_ pane: ListedPane, in workspace: PaneWorkspace) -> some View {
        let agent = agent(for: pane)
        let row = TerminalRow(glyph: PaneGlyph(pane: pane, agent: agent),
                              title: pane.title.isEmpty ? String(localized: "untitled") : pane.title,
                              tag: agent?.provider, since: agent?.since,
                              detail: pane.preview?.isEmpty == false ? pane.preview : agent?.status ?? pane.status,
                              detailIsTerminal: pane.preview?.isEmpty == false)
        if let target = pane.terminalTarget(in: workspace.name) {
            Button { destination = target } label: { row }
        } else {
            row
        }
    }
}

/// One shape per state so color is never the only signal; VoiceOver reads the word.
enum PaneGlyph {
    case failed, waiting, agent, running, done, idle, unavailable

    init(pane: ListedPane, agent: GlanceAgent?) {
        if let agent { self.init(agent: agent); return }
        guard pane.availability == "attached", pane.kind == .terminal else { self = .unavailable; return }
        switch pane.state {
        case "error": self = .failed
        case "waiting", "needsAttention": self = .waiting
        case "running", "thinking": self = .running
        case "output", "done": self = .done
        default: self = .idle
        }
    }

    init(agent: GlanceAgent) {
        switch agent.group {
        case .needsYou: self = agent.state == "error" ? .failed : .agent
        case .working: self = .running
        case .done: self = .done
        }
    }

    var needsYou: Bool { [.failed, .waiting, .agent].contains(self) }

    var symbol: String {
        switch self {
        case .failed: "✕"
        case .waiting: "?"
        case .agent: "◆"
        case .running: "●"
        case .done: "✓"
        case .idle: "○"
        case .unavailable: "·"
        }
    }

    var color: Color {
        switch self {
        case .failed: Cat.red
        case .waiting: Cat.needs
        case .agent: Cat.mauve
        case .running: Cat.running
        case .done: Cat.done
        case .idle, .unavailable: Cat.subtext0
        }
    }

    var label: String {
        switch self {
        case .failed: String(localized: "Failed")
        case .waiting: String(localized: "Waiting for you")
        case .agent: String(localized: "Agent needs you")
        case .running: String(localized: "Running")
        case .done: String(localized: "Finished")
        case .idle: String(localized: "Idle")
        case .unavailable: String(localized: "Unavailable")
        }
    }
}

struct TerminalRow: View {
    let glyph: PaneGlyph
    let title: String
    var tag: String?
    var since: Date?
    var detail: String?
    var detailIsTerminal = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(glyph.symbol).fontWeight(.bold).foregroundStyle(glyph.color).frame(minWidth: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: title).foregroundStyle(Cat.text).lineLimit(1)
                    if let tag { Text(verbatim: tag).font(.caption.monospaced()).foregroundStyle(Cat.subtext0) }
                    Spacer(minLength: 8)
                    if let since { AgeText(date: since).font(.caption.monospaced()).foregroundStyle(Cat.subtext0) }
                }
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(Cat.subtext0)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .font(.subheadline.monospaced())
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, glyph.label, tag, detailIsTerminal ? nil : detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(detailIsTerminal ? detail ?? "" : "")
    }
}

/// Dim text that reads like a line the terminal printed: loading, offline, empty states.
struct SystemLine: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(.caption.monospaced()).foregroundStyle(Cat.subtext0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct WorkspaceRule: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: name.uppercased()).font(.caption2.monospaced()).tracking(1.2).foregroundStyle(Cat.subtext0)
                .lineLimit(1)
            Rectangle().fill(Cat.card).frame(height: 1).accessibilityHidden(true)
        }
        .padding(.top, 10)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// SwiftUI on iOS 26 ignores navigation bar font appearance, so the mono title is drawn here.
    /// `navigationTitle` stays for the back button and VoiceOver.
    /// Middle truncation keeps both ends of long names, such as a workspace and its pane.
    func terminalTitle(_ title: String, subtitle: String? = nil, accessibilityLabel: String? = nil) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title).font(.headline.monospaced()).foregroundStyle(Cat.text)
                        if let subtitle {
                            Text(subtitle).font(.caption.monospaced()).foregroundStyle(Cat.subtext0)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(verbatim: accessibilityLabel ?? [title, subtitle].compactMap { $0 }.joined(separator: ", ")))
                    .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

private extension View {
    func terminalRow(focused: Bool = false) -> some View {
        buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(focused ? Cat.card : Color.clear)
    }
}

/// Claude permission requests, moved out of the old Agents tab.
struct DecisionsView: View {
    let store: CompanionStore
    @Environment(PendingDecisionsModel.self) private var decisions

    var body: some View {
        List { PendingDecisionsSection(model: decisions, context: store.decisionContext) }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Cat.page)
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await decisions.refresh() }
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
