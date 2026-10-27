import os
import AwesoMuxCompanionProtocol
import SwiftUI
import UIKit

struct WatchView: View {
    let store: CompanionStore
    let target: TerminalDestination
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PendingDecisionsModel.self) private var decisions
    let terminalLock: TerminalLockModel
    @StateObject private var terminal: WatchTerminal
    @State private var model: WatchModel
    @State private var isVisible = false
    @State private var keyboardShown = false
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @State private var terminalSize = CGSize.zero
    @State private var securityObserver: UUID?

    init(store: CompanionStore, target: TerminalDestination, terminalLock: TerminalLockModel) {
        self.store = store
        self.target = target
        self.terminalLock = terminalLock
        let renderer = WatchTerminal()
        let pairing = store.decisionPairing
        let canRender: @MainActor () -> Bool = { [weak store] in
            terminalLock.isActive && !terminalLock.isLocked && pairing != nil
                && store?.decisionPairing == pairing && store?.showingPairing == false
                && store?.pairingStep == .idle
        }
        renderer.canRender = canRender
        _terminal = StateObject(wrappedValue: renderer)
        _model = State(initialValue: WatchModel(renderer: renderer, opening: target.opening,
            canInput: { [weak store] in store?.panes.terminalAccess.inputAllowed == true }, canWatch: canRender))
    }

    private var canWatch: Bool {
        scenePhase == .active && terminalLock.isActive && !terminalLock.isLocked
            && store.decisionPairing != nil && !store.showingPairing && store.pairingStep == .idle
    }

    var body: some View {
        WatchTerminalView(terminal: terminal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHint("The Mac snapshot preserves terminal cells, but earlier command history and line wraps are unavailable.")
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                terminalSize = size
                if model.status == .idle { connect() }
            }
            // The Mac pane follows the phone's grid while the phone drives, as tmux does.
            .onChange(of: terminal.measuredGrid) { _, grid in
                if let grid { model.input.updatePhoneGrid(grid) }
            }
            .onChange(of: fontSize, initial: true) { _, size in terminal.setFontSize(Float(size)) }
            .background(WatchKeyboard(input: model.input, terminal: terminal, isShown: $keyboardShown)
                .frame(width: 1, height: 1))
            .overlay(alignment: .top) { notices }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let request = decisions.pending.first(where: { $0.identity.paneID == target.paneID }) {
                        QuestionDock(request: request, decisions: decisions)
                    }
                    if !keyboardShown { bottomBar }
                }
            }
            .foregroundStyle(Cat.text)
            .background(Cat.page)
            .terminalTitle(target.path, subtitle: host, accessibilityLabel: target.accessibilityHeader(host: host))
            .toolbarBackground(Cat.page, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ModeChip(driving: model.input.hasControl) }
                    .sharedBackgroundVisibility(.hidden)
            }
            .onAppear {
                isVisible = true
                if securityObserver == nil {
                    securityObserver = terminalLock.observeSecurityChanges { [weak model, weak terminalLock] in
                        guard let terminalLock, !terminalLock.isActive || terminalLock.isLocked else { return }
                        model?.updateLifecycle(isActive: terminalLock.isActive,
                                               isUnlocked: !terminalLock.isLocked, isVisible: true)
                    }
                }
                terminal.onFailure = { [weak model] error in model?.rendererFailed(error) }
                connect()
            }
            .onDisappear {
                WatchDiagnostics.lifecycle.notice("authority_lost origin=lifecycle source=watch_disappear")
                isVisible = false
                if let securityObserver { terminalLock.removeSecurityObserver(securityObserver) }
                securityObserver = nil
                keyboardShown = false
                model.stop()
            }
            .onChange(of: canWatch) { _, _ in updateLifecycle() }
            .onChange(of: store.panes.terminalAccess.inputAllowed) { _, _ in model.updateInputPermission() }
            .onChange(of: store.decisionPairing) { _, _ in
                WatchDiagnostics.lifecycle.notice("authority_lost origin=lifecycle source=pairing_changed")
                model.stop()
            }
            .onChange(of: inputAnnouncement) { _, message in
                if !message.isEmpty { UIAccessibility.post(notification: .announcement, argument: message) }
            }
            .onChange(of: model.input.keyboardRequested) { _, requested in keyboardShown = requested }
            .onChange(of: model.input.canType) { _, canType in if !canType { keyboardShown = false } }
            .sheet(item: Binding(get: { model.input.confirmation }, set: { _ in model.input.cancelPaste() })) { confirmation in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("This paste contains line endings that may run commands, or a bracketed-paste terminator.")
                        ScrollView { Text(confirmation.preview).font(.caption.monospaced()).textSelection(.enabled) }
                        HStack {
                            Button("Cancel", role: .cancel) { model.input.cancelPaste() }
                            Spacer()
                            Button("Send") {
                                Task { @MainActor in
                                    guard let modes = await terminal.inputModes() else {
                                        if model.input.confirmation?.id == confirmation.id {
                                            model.input.cancelPaste()
                                            model.input.refuseModeRead(paste: true)
                                        }
                                        return
                                    }
                                    guard model.input.confirmation?.id == confirmation.id else { return }
                                    model.input.confirmPaste(modes: modes)
                                }
                            }
                        }
                    }
                    .padding()
                    .navigationTitle("Send paste?")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
    }

    /// The pairing `connect()` uses, so the header names the Mac that receives typing.
    private var host: String { TerminalDestination.hostName(store.record?.macName) }

    private var pasteDeliveryText: String? { model.input.pasteDelivery.map { "Paste: \($0.rawValue)" } }

    private var inputAnnouncement: String {
        [pasteDeliveryText, model.input.pasteError, model.input.typedNotice]
            .compactMap { $0 }.joined(separator: ". ")
    }

    private var statusText: String {
        switch model.status {
        case .idle: String(localized: "disconnected")
        case .connecting: String(localized: "connecting to your Mac…")
        case .snapshot: String(localized: "restoring Mac terminal…")
        case .live: liveText
        case .failed: String(localized: "lost connection")
        }
    }

    private var liveText: String {
        let grid = model.grid.map { " · \($0.cols)×\($0.rows)" } ?? ""
        if let message = model.input.watchMessage { return message }
        return model.input.drivingText.lowercased() + grid
    }

    /// Interactive: paste and keyboard, plus Take over while someone else drives. Dropped: retry.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(verbatim: model.error ?? statusText)
                .font(.caption.monospaced()).foregroundStyle(Cat.subtext0)
                .lineLimit(2)
                .accessibilityAddTraits(.updatesFrequently)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.status == .failed || model.status == .idle {
                Button("Retry") {
                    model.stop()
                    connect()
                }
                .buttonStyle(BarButtonStyle(filled: true))
                .disabled(!canWatch)
                .accessibilityHint("Starts a new snapshot from your Mac.")
            } else if model.input.isInteractive {
                if !model.input.hasControl {
                    Button("Take over") { model.input.takeOver() }
                        .buttonStyle(BarButtonStyle(filled: true))
                        .disabled(!model.input.canType)
                }
                Button("Paste", action: paste)
                    .buttonStyle(BarButtonStyle(filled: false))
                    .disabled(!model.input.canType || model.input.pasteInFlight || model.input.confirmation != nil)
                Button { keyboardShown = true } label: {
                    Image(systemName: "keyboard").accessibilityLabel("Show keyboard")
                }
                .buttonStyle(BarButtonStyle(filled: false))
                .disabled(!model.input.canType)
            }
            if terminal.isReady { optionsMenu }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Cat.crust)
        .overlay(alignment: .top) { Rectangle().fill(Cat.card).frame(height: 1) }
    }

    /// Display size and Mac scrollback, kept out of the way of the terminal.
    private var optionsMenu: some View {
        Menu {
            Section("Text size \(Int(fontSize)) pt") {
                Button("Larger", systemImage: "plus.magnifyingglass") { fontSize += 1 }
                    .disabled(Float(fontSize) >= WatchTerminal.fontSizes.upperBound)
                Button("Smaller", systemImage: "minus.magnifyingglass") { fontSize -= 1 }
                    .disabled(Float(fontSize) <= WatchTerminal.fontSizes.lowerBound)
            }
            Section("History") {
                Button("Earlier", systemImage: "chevron.up") { terminal.scrollHistory("scroll_page_up") }
                Button("Later", systemImage: "chevron.down") { terminal.scrollHistory("scroll_page_down") }
                Button("Latest", systemImage: "arrow.down.to.line") { terminal.scrollHistory("scroll_to_bottom") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(Cat.text)
                .frame(height: 15)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Cat.card, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("Terminal options")
        }
    }

    /// Short-lived lines over the top of the terminal instead of captions under it.
    @ViewBuilder private var notices: some View {
        let lines = [model.status == .snapshot ? String(localized: "┄ earlier history stays on the Mac ┄") : nil,
                     pasteDeliveryText, model.input.pasteError].compactMap { $0 }
        if !lines.isEmpty || model.input.typedNotice != nil {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text(verbatim: $0) }
                if let notice = model.input.typedNotice {
                    HStack {
                        Text(verbatim: notice)
                        Button("Dismiss") { model.input.dismissTypedNotice() }.fontWeight(.semibold)
                    }
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(Cat.subtext0)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Cat.crust.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string else { return }
        let sessionID = model.input.sessionID
        Task { @MainActor in
            guard let modes = await terminal.inputModes() else {
                if model.input.sessionID == sessionID { model.input.refuseModeRead(paste: true) }
                return
            }
            guard model.input.sessionID == sessionID else { return }
            model.input.paste(text, modes: modes)
        }
    }

    private func updateLifecycle() {
        model.updateLifecycle(isActive: canWatch, isUnlocked: !terminalLock.isLocked, isVisible: isVisible)
    }

    private func connect() {
        updateLifecycle()
        guard canWatch, isVisible, terminalSize.width > 0, terminalSize.height > 0,
              let record = store.record else { return }
        model.start(record: record, paneID: target.paneID, targetVersion: target.targetVersion)
    }
}

/// WATCH is outlined; DRIVE is the only filled chip, so it's obvious when keys reach the Mac.
private struct ModeChip: View {
    let driving: Bool

    var body: some View {
        Text(driving ? "DRIVE" : "WATCH")
            .font(.caption2.monospaced().weight(.bold)).tracking(1)
            .foregroundStyle(driving ? Cat.crust : Cat.running)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(driving ? Cat.accent : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay { if !driving { RoundedRectangle(cornerRadius: 4).stroke(Cat.running, lineWidth: 1) } }
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(driving ? "You have control" : "Watching")
    }
}

/// A permission request docked in the pane it came from. Answering never takes over the terminal.
private struct QuestionDock: View {
    let request: CompanionPendingDecision
    let decisions: PendingDecisionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(verbatim: "◆ \(request.tool)").foregroundStyle(Cat.mauve)
                Text("asks permission").foregroundStyle(Cat.subtext0)
            }
            Text(verbatim: request.summary)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Cat.crust, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Request summary from Claude, untrusted: \(request.summary)")
            if let message = decisions.message {
                Text(verbatim: message).foregroundStyle(Cat.subtext0)
            }
            HStack(spacing: 6) {
                if decisions.isAnswering {
                    Text("checking your Mac…").foregroundStyle(Cat.subtext0)
                } else if decisions.hasAttempt(request.identity) {
                    Button("Retry same answer") { Task { await decisions.retry(request.identity) } }
                        .buttonStyle(BarButtonStyle(filled: true))
                        .disabled(!decisions.canRetry(request.identity))
                        .accessibilityHint("An answer may have reached your Mac. This retries only the original choice.")
                } else {
                    ForEach(request.choices, id: \.rawValue) { choice in
                        Button(choice == .allow ? "Allow once" : "Deny once") {
                            Task { await decisions.answer(request.identity, choice: choice) }
                        }
                        .buttonStyle(BarButtonStyle(filled: choice == .allow))
                        .disabled(!decisions.canAnswer(request.identity, choice: choice))
                        .accessibilityHint("Authenticates before answering this Claude permission request.")
                    }
                }
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(Cat.text)
        .padding(10)
        .background(Cat.mauve.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Cat.mauve, lineWidth: 1))
        .padding(.horizontal, 8).padding(.bottom, 8)
    }
}

private struct BarButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(filled ? Cat.crust : Cat.text)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(filled ? Cat.accent : Cat.card, in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
