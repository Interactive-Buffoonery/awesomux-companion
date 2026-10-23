import AwesoMuxCompanionProtocol
import SwiftUI

struct WatchView: View {
    let store: CompanionStore
    let paneID: UUID
    let targetVersion: UUID
    let title: String
    @Environment(\.scenePhase) private var scenePhase
    let terminalLock: TerminalLockModel
    @StateObject private var terminal: WatchTerminal
    @State private var model: WatchModel
    @State private var isVisible = false
    @State private var keyboardShown = false
    @State private var terminalSize = CGSize.zero
    @State private var securityObserver: UUID?

    init(store: CompanionStore, paneID: UUID, targetVersion: UUID, title: String, terminalLock: TerminalLockModel) {
        self.store = store
        self.paneID = paneID
        self.targetVersion = targetVersion
        self.title = title
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
        _model = State(initialValue: WatchModel(renderer: renderer, canWatch: canRender))
    }

    private var canWatch: Bool {
        scenePhase == .active && terminalLock.isActive && !terminalLock.isLocked
            && store.decisionPairing != nil && !store.showingPairing && store.pairingStep == .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.input.isInteractive ? "Terminal" : "Watch only").font(.headline)
            Text("Earlier history incomplete")
                .font(.callout)
                .accessibilityHint("The Mac snapshot preserves terminal cells, but earlier command history and line wraps are unavailable.")
            if let grid = model.grid {
                Text("Mac grid: \(grid.cols) × \(grid.rows)")
                    .font(.caption.monospaced())
            }
            Text(model.input.drivingText)
                .font(.caption)
            Text(statusText).font(.caption).accessibilityAddTraits(.updatesFrequently)
            if let message = model.input.watchMessage { Text(message).font(.callout) }
            if model.input.isInteractive {
                HStack {
                    Button("Take over") { model.input.takeOver() }
                        .disabled(!model.input.canType)
                    Spacer()
                    Button(keyboardShown ? "Hide keyboard" : "Show keyboard",
                           systemImage: "keyboard") { keyboardShown.toggle() }
                        .disabled(!model.input.canType)
                }
                .font(.callout)
            }
            WatchTerminalView(terminal: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    terminalSize = size
                    model.input.preferredGrid = terminal.phoneGrid(for: size)
                    if model.status == .idle { connect() }
                }
                .onChange(of: terminal.isReady) { _, ready in
                    if ready { model.input.preferredGrid = terminal.phoneGrid(for: terminalSize) }
                }
                .background(WatchKeyboard(input: model.input, terminal: terminal, isShown: $keyboardShown)
                    .frame(width: 1, height: 1))
            if let delivery = model.input.pasteDelivery {
                Text("Paste: \(delivery.rawValue)").font(.caption)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let error = model.input.pasteError { Text(error).font(.caption) }
            if let notice = model.input.typedNotice {
                HStack {
                    Text(notice).font(.caption)
                    Button("Dismiss") { model.input.dismissTypedNotice() }.font(.caption)
                }
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(Cat.subtext0)
            }
            Button("Connect / Reconnect") {
                model.stop()
                connect()
            }
                .disabled(!canWatch)
                .accessibilityHint("Starts a new snapshot from your Mac as a follower.")
        }
        .padding()
        .foregroundStyle(Cat.text)
        .background(Cat.page)
        .navigationTitle(title.isEmpty ? "Watch" : title)
        .navigationBarTitleDisplayMode(.inline)
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
            isVisible = false
            if let securityObserver { terminalLock.removeSecurityObserver(securityObserver) }
            securityObserver = nil
            keyboardShown = false
            model.stop()
        }
        .onChange(of: canWatch) { _, _ in updateLifecycle() }
        .onChange(of: store.decisionPairing) { _, _ in model.stop() }
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
                                guard let modes = await terminal.inputModes(),
                                      model.input.confirmation?.id == confirmation.id else { return }
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

    private var statusText: String {
        switch model.status {
        case .idle: "Disconnected"
        case .connecting: "Connecting to your Mac…"
        case .snapshot: "Restoring Mac terminal…"
        case .live: model.input.isInteractive ? "Connected" : "Watching live"
        case .failed: "Watch disconnected"
        }
    }

    private func updateLifecycle() {
        model.updateLifecycle(isActive: canWatch, isUnlocked: !terminalLock.isLocked, isVisible: isVisible)
    }

    private func connect() {
        updateLifecycle()
        guard canWatch, isVisible, terminalSize.width > 0, terminalSize.height > 0,
              let record = store.record else { return }
        model.start(record: record, paneID: paneID, targetVersion: targetVersion)
    }
}
