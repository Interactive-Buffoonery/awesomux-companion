import AwesoMuxCompanionProtocol
import Combine
import Foundation
import GhosttyTerminal
import SwiftUI
import UIKit

@MainActor
final class WatchTerminal: ObservableObject, WatchRendering {
    var onFailure: ((Error) -> Void)?
    var canRender: @MainActor () -> Bool = { true }
    @Published private(set) var isReady = false
    @Published private(set) var failure: WatchTerminalFailure?
    @Published fileprivate var surface: WatchNativeSurface?
    @Published fileprivate var probe: WatchNativeSurface?

    private enum Operation {
        case bytes(Data)
        case grid(CompanionTerminalStream.Grid)
    }

    private var operations: [Operation] = []
    private var queuedBytes = 0
    private var epoch = UUID()
    private var target: CompanionTerminalStream.Grid?
    private var scrollbackBound = 0
    private var sizingAttempts = 0
    private var deadline: Task<Void, Never>?
    private var drainToken: UUID?
    private let drainQueue = DispatchQueue(label: "app.awesomux.watch-renderer-drain")
    private let discardedWrites = WatchDiscardedWrites()
    private static let maximumQueuedBytes = CompanionTerminalStream.maximumSnapshotBytes
    private static let maximumOperations = 256
    // Native logging is independent of TerminalDebugLog. The pinned engine
    // reads this setting once in ghostty_init, before any controller exists.
    private static let nativeLoggingDisabled = setenv("GHOSTTY_LOG", "no-stderr,no-macos", 1) == 0

    init() {
        _ = Self.nativeLoggingDisabled
        TerminalDebugLog.disable()
    }

    var isIdle: Bool { isReady && operations.isEmpty && drainToken == nil && probe == nil }
    var discardedWriteByteCount: Int { discardedWrites.count }
    var grid: CompanionTerminalStream.Grid? { target }
    var reportedGrid: CompanionTerminalStream.Grid? {
        surface?.viewport.map { .init(rows: Int($0.rows), cols: Int($0.columns)) }
    }

    func reset(grid: CompanionTerminalStream.Grid, scrollbackBound: Int) throws {
        clear()
        try requireAuthority()
        guard Self.nativeLoggingDisabled else { throw WatchTerminalFailure.unsafeConfiguration }
        guard drainToken == nil else { throw WatchTerminalFailure.nativeBusy }
        try validate(grid)
        guard scrollbackBound >= 0 else { throw WatchTerminalFailure.invalidRetention }
        self.scrollbackBound = min(scrollbackBound, Self.maximumQueuedBytes)
        target = grid
        let surface = try makeSurface(size: CGSize(width: CGFloat(grid.cols) * 8,
                                                  height: CGFloat(grid.rows) * 16))
        self.surface = surface
        beginSizing()
    }

    func feed(_ bytes: Data) throws {
        try requireAuthority()
        if let failure { throw failure }
        guard surface != nil else { throw WatchTerminalFailure.notAttached }
        guard bytes.count <= CompanionTerminalStream.maximumDataBytes,
              bytes.count <= Self.maximumQueuedBytes - queuedBytes,
              operations.count < Self.maximumOperations else {
            throw invalidate(.overflow)
        }
        guard !bytes.isEmpty else { return }
        operations.append(.bytes(bytes))
        queuedBytes += bytes.count
        pump()
    }

    func resize(_ grid: CompanionTerminalStream.Grid) throws {
        try requireAuthority()
        if let failure { throw failure }
        try validate(grid)
        guard surface != nil else { throw WatchTerminalFailure.notAttached }
        guard operations.count < Self.maximumOperations else { throw invalidate(.overflow) }
        operations.append(.grid(grid))
        pump()
    }

    func clear() {
        epoch = UUID()
        deadline?.cancel()
        deadline = nil
        operations.removeAll(keepingCapacity: false)
        queuedBytes = 0
        target = nil
        isReady = false
        failure = nil
        probe?.detach()
        probe = nil
        surface?.detach()
        surface = nil
        // An uncancellable package drain may still be returning. Keep its token
        // until completion so repeated resets cannot accumulate blocked workers.
    }

    func readViewportText() -> String? {
        guard checkAuthority(), isIdle else { return nil }
        return surface?.session.readViewportText()
    }

    fileprivate func checkAuthority() -> Bool {
        guard canRender() else {
            clear()
            return false
        }
        return true
    }

    private func requireAuthority() throws {
        guard checkAuthority() else { throw WatchTerminalFailure.accessDenied }
    }

    private func validate(_ grid: CompanionTerminalStream.Grid) throws {
        guard (1...1000).contains(grid.cols), (1...1000).contains(grid.rows),
              grid.cols * grid.rows <= 250_000 else { throw WatchTerminalFailure.invalidGrid }
    }

    private func makeSurface(size: CGSize) throws -> WatchNativeSurface {
        TerminalDebugLog.disable()
        let identity = epoch
        return try WatchNativeSurface(size: size, scrollbackBound: scrollbackBound,
                                      discardedWrites: discardedWrites,
                                      authority: { [weak self] in self?.checkAuthority() ?? false },
                                      resized: { [weak self] id, value in
            guard let self, self.epoch == identity, self.checkAuthority() else { return }
            self.resized(id: id, value: value)
        })
    }

    private func beginSizing() {
        isReady = false
        sizingAttempts = 0
        armDeadline(.readinessTimeout)
    }

    private func resized(id: UUID, value: InMemoryTerminalViewport) {
        guard let target, let surface else { return }
        let sizingSurface: WatchNativeSurface
        if let probe, probe.id == id {
            sizingSurface = probe
        } else if surface.id == id {
            // A scale/appearance change must not silently reflow the live grid.
            if isReady, (Int(value.columns) != target.cols || Int(value.rows) != target.rows) {
                _ = invalidate(.unexpectedGrid)
                return
            }
            if probe != nil { return }
            sizingSurface = surface
        } else { return }
        sizingSurface.viewport = value
        guard sizingSurface.controller.lastConfigurationIssue == nil else {
            _ = invalidate(.unsafeConfiguration)
            return
        }
        if Int(value.columns) == target.cols, Int(value.rows) == target.rows {
            if sizingSurface === probe {
                // Calibration changes only an empty surface. Retained content
                // sees exactly one resize, at the authoritative dimensions.
                surface.size = sizingSurface.size
                surface.applySize()
                probe?.detach()
                probe = nil
                return
            }
            deadline?.cancel()
            isReady = true
            pump()
            return
        }
        guard value.columns > 0, value.rows > 0, sizingAttempts < 12 else {
            _ = invalidate(.unexpectedGrid)
            return
        }
        sizingAttempts += 1
        let scale = sizingSurface.view.traitCollection.displayScale
        let next: CGSize
        if value.cellWidthPixels > 0, value.cellHeightPixels > 0, scale > 0 {
            let paddingX = max(0, Int(value.widthPixels) - Int(value.columns) * Int(value.cellWidthPixels))
            let paddingY = max(0, Int(value.heightPixels) - Int(value.rows) * Int(value.cellHeightPixels))
            next = CGSize(width: CGFloat(target.cols * Int(value.cellWidthPixels) + paddingX) / scale,
                          height: CGFloat(target.rows * Int(value.cellHeightPixels) + paddingY) / scale)
        } else {
            // The pinned iOS binary reports zero cell metrics. Use observed
            // grid rounding intervals, as the public diagnostics adapter does.
            next = CGSize(width: Int(value.columns) == target.cols ? sizingSurface.size.width
                          : sizingSurface.size.width * (CGFloat(target.cols) + 0.5) / (CGFloat(value.columns) + 0.5),
                          height: Int(value.rows) == target.rows ? sizingSurface.size.height
                          : sizingSurface.size.height * (CGFloat(target.rows) + 0.5) / (CGFloat(value.rows) + 0.5))
        }
        guard next.width.isFinite, next.height.isFinite,
              next.width > 0, next.height > 0, next.width <= 32768, next.height <= 32768 else {
            _ = invalidate(.invalidGrid)
            return
        }
        sizingSurface.size = next
        sizingSurface.applySize()
    }

    private func pump() {
        guard checkAuthority(), isReady, drainToken == nil, let surface, !operations.isEmpty else { return }
        let operation = operations.removeFirst()
        switch operation {
        case .bytes(let bytes):
            // A package queue silently trims bytes while detached. Never send
            // it output without an attached, correctly sized native surface.
            guard surface.view.surface != nil else { _ = invalidate(.notAttached); return }
            let token = UUID()
            let identity = epoch
            drainToken = token
            surface.session.receive(bytes)
            armDeadline(.drainTimeout)
            let session = surface.session
            drainQueue.async { [weak self] in
                let drained = session.waitForPendingOutput()
                Task { @MainActor [weak self] in
                    guard let self, self.drainToken == token else { return }
                    self.drainToken = nil
                    guard self.epoch == identity, self.checkAuthority() else { return }
                    self.deadline?.cancel()
                    self.queuedBytes -= bytes.count
                    guard drained else { _ = self.invalidate(.notAttached); return }
                    self.pump()
                }
            }
        case .grid(let grid):
            guard grid != target else { pump(); return }
            target = grid
            beginSizing()
            do {
                probe = try makeSurface(size: surface.size)
            } catch {
                _ = invalidate(.unsafeConfiguration)
            }
        }
    }

    private func armDeadline(_ error: WatchTerminalFailure) {
        deadline?.cancel()
        let identity = epoch
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.epoch == identity, self.checkAuthority() else { return }
            _ = self.invalidate(error)
        }
    }

    @discardableResult
    private func invalidate(_ error: WatchTerminalFailure) -> WatchTerminalFailure {
        clear()
        failure = error
        onFailure?(error)
        return error
    }
}

enum WatchTerminalFailure: Error, LocalizedError, Equatable {
    case accessDenied, notAttached, invalidGrid, invalidRetention, overflow
    case readinessTimeout, drainTimeout, unexpectedGrid, unsafeConfiguration, nativeBusy

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Watch is no longer available."
        case .notAttached: "The Watch renderer is not attached."
        case .invalidGrid: "The terminal grid exceeds the Watch renderer limit."
        case .invalidRetention: "The terminal history bound is invalid."
        case .overflow: "Watch output exceeded the renderer buffer. Reconnect to continue."
        case .readinessTimeout: "The Watch renderer did not become ready."
        case .drainTimeout: "The Watch renderer did not finish processing output."
        case .unexpectedGrid: "The Watch renderer could not preserve the Mac terminal grid."
        case .unsafeConfiguration: "The Watch renderer could not disable terminal host effects."
        case .nativeBusy: "The previous Watch renderer is still stopping."
        }
    }
}

@MainActor
fileprivate final class WatchNativeSurface: ObservableObject, Identifiable,
    TerminalSurfaceOpenURLDelegate, TerminalSurfaceClipboardConfirmationDelegate {
    let id: UUID
    let controller: TerminalController
    let session: InMemoryTerminalSession
    let view: WatchReadOnlyTerminalView
    @Published var size: CGSize
    var viewport: InMemoryTerminalViewport?

    init(size: CGSize, scrollbackBound: Int, discardedWrites: WatchDiscardedWrites,
         authority: @escaping () -> Bool,
         resized: @escaping @MainActor (UUID, InMemoryTerminalViewport) -> Void) throws {
        let identity = UUID()
        id = identity
        self.size = size
        let configuration = TerminalConfiguration()
            .fontSize(13).windowPaddingX(0).windowPaddingY(0)
            .custom("clipboard-read", "deny").custom("clipboard-write", "deny")
            .custom("copy-on-select", "none")
            .custom("desktop-notifications", "false")
            .custom("bell-features", "no-system,no-audio,no-attention,no-title,no-border")
            .custom("link-url", "false").custom("link-previews", "false")
            .custom("scrollback-limit-bytes", String(scrollbackBound))
            .custom("keybind", "clear")
        controller = TerminalController(configSource: .none, terminalConfiguration: configuration)
        guard controller.lastConfigurationIssue == nil else { throw WatchTerminalFailure.unsafeConfiguration }
        session = InMemoryTerminalSession(write: { bytes in discardedWrites.discard(bytes) }, resize: { value in
            Task { @MainActor in resized(identity, value) }
        })
        view = WatchReadOnlyTerminalView(frame: CGRect(origin: .zero, size: size))
        view.authority = authority
        view.delegate = self
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: 13)
        view.controller = controller
        view.accessibilityLabel = "Read-only Mac terminal"
        view.accessibilityHint = "Select text to copy. Use two fingers or the history controls to scroll."
    }

    func applySize() {
        view.frame.size = size
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func detach() {
        view.authority = { false }
        view.isHidden = true
        view.accessibilityElementsHidden = true
        view.setSurfaceVisible(false)
        view.controller = nil
        view.removeFromSuperview()
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {}
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        request.respond(allow: false)
    }
}

fileprivate final class WatchDiscardedWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    func discard(_ data: Data) {
        lock.lock()
        bytes = bytes > Int.max - data.count ? Int.max : bytes + data.count
        lock.unlock()
    }
}

@MainActor
fileprivate final class WatchReadOnlyTerminalView: UITerminalView {
    var authority: () -> Bool = { false }
    override var canBecomeFirstResponder: Bool { false }
    override func toggleSoftwareKeyboard() {}
    override func paste(_ sender: Any?) {}
    override func copy(_ sender: Any?) {
        guard authority() else { return }
        super.copy(sender)
    }
    override func copySelectedTextToPasteboard() -> Bool {
        guard authority() else { return false }
        return super.copySelectedTextToPasteboard()
    }
    override func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
        guard authority() else { return nil }
        return super.selectionMenuPoint(at: point)
    }
    override func selectionContextMenuElements() -> [UIMenuElement] {
        guard authority() else { return [] }
        return super.selectionContextMenuElements()
    }
    override func select(_ sender: Any?) {
        guard authority() else { return }
        super.select(sender)
    }
    override func selectAll(_ sender: Any?) {
        guard authority() else { return }
        super.selectAll(sender)
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard authority(), [#selector(copy(_:)), #selector(select(_:)), #selector(selectAll(_:))].contains(action) else {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard authority(), !(gestureRecognizer is UIPinchGestureRecognizer) else { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    override func layoutSubviews() {
        guard authority() else { return }
        super.layoutSubviews()
    }
    override func didMoveToWindow() {
        guard window == nil || authority() else { return }
        super.didMoveToWindow()
    }
    override func touchMenuItems(for context: TerminalTouchMenuContext) -> [UIMenuElement] {
        guard authority() else { return [] }
        return [
            UIAction(title: "Select", identifier: UIAction.Identifier("terminal.select")) { [weak self] _ in
                self?.select(nil)
            },
            UIAction(title: "Select All", identifier: UIAction.Identifier("terminal.selectAll")) { [weak self] _ in
                self?.selectAll(nil)
            }
        ]
    }
    override func touchSelectionMenuItems(for context: TerminalTouchSelectionMenuContext) -> [UIMenuElement] {
        guard authority() else { return [] }
        return [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.copy(nil)
        }]
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        inputAccessoryItems = []
        for interaction in interactions where interaction is UIDropInteraction { removeInteraction(interaction) }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct WatchTerminalView: View {
    @ObservedObject var terminal: WatchTerminal

    var body: some View {
        VStack(spacing: 4) {
            if let surface = terminal.surface, terminal.canRender() {
                ScrollView([.horizontal, .vertical]) {
                    WatchNativeCanvas(surface: surface)
                }
                HStack {
                    historyButton("Earlier", action: "scroll_page_up")
                    historyButton("Later", action: "scroll_page_down")
                    historyButton("Latest", action: "scroll_to_bottom")
                }
                .font(.caption)
            }
        }
        .overlay(alignment: .topLeading) {
            if let probe = terminal.probe {
                WatchNativeCanvas(surface: probe)
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func historyButton(_ title: String, action: String) -> some View {
        Button(title) {
            guard terminal.checkAuthority(), terminal.isReady else { return }
            _ = terminal.surface?.view.surface?.performBindingAction(action)
        }
        .accessibilityLabel("\(title) terminal history")
        .disabled(!terminal.isReady)
    }
}

private struct WatchNativeCanvas: View {
    @ObservedObject var surface: WatchNativeSurface
    var body: some View {
        WatchNativeRepresentable(surface: surface)
            .id(surface.id)
            .frame(width: surface.size.width, height: surface.size.height)
            .fixedSize()
    }
}

private struct WatchNativeRepresentable: UIViewRepresentable {
    let surface: WatchNativeSurface
    func makeUIView(context: Context) -> WatchReadOnlyTerminalView { surface.view }
    func updateUIView(_ uiView: WatchReadOnlyTerminalView, context: Context) {
        guard uiView.authority() else { return }
        surface.applySize()
    }
    static func dismantleUIView(_ uiView: WatchReadOnlyTerminalView, coordinator: ()) {
        uiView.setSurfaceVisible(false)
        uiView.controller = nil
    }
}
