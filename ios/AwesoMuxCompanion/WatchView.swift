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
            Text("Watch only").font(.headline)
            Text("Earlier history incomplete")
                .font(.callout)
                .accessibilityHint("The Mac snapshot preserves terminal cells, but earlier command history and line wraps are unavailable.")
            if let grid = model.grid {
                Text("Mac grid: \(grid.cols) × \(grid.rows)")
                    .font(.caption.monospaced())
            }
            Text(model.leader == nil ? "No terminal leads; keeping the Mac grid" : "Following the terminal leader")
                .font(.caption)
            Text(statusText).font(.caption).accessibilityAddTraits(.updatesFrequently)
            WatchTerminalView(terminal: terminal)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(Cat.subtext0)
            }
            Button("Connect / Reconnect") {
                model.stop()
                connect()
            }
                .disabled(!canWatch)
                .accessibilityHint("Starts a new snapshot from your Mac. No typing or resizing is sent.")
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
            model.stop()
        }
        .onChange(of: canWatch) { _, _ in updateLifecycle() }
        .onChange(of: store.decisionPairing) { _, _ in model.stop() }
    }

    private var statusText: String {
        switch model.status {
        case .idle: "Disconnected"
        case .connecting: "Connecting to your Mac…"
        case .snapshot: "Restoring Mac terminal…"
        case .live: "Watching live"
        case .failed: "Watch disconnected"
        }
    }

    private func updateLifecycle() {
        model.updateLifecycle(isActive: canWatch, isUnlocked: !terminalLock.isLocked, isVisible: isVisible)
    }

    private func connect() {
        updateLifecycle()
        guard canWatch, isVisible, let record = store.record else { return }
        model.start(record: record, paneID: paneID, targetVersion: targetVersion)
    }
}
