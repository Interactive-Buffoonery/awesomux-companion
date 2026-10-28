import AwesoMuxCompanionProtocol
import Combine
import Foundation
import GhosttyTerminal
import SwiftUI
import UIKit
import os

/// Fills its view, like a tmux client: Ghostty measures the grid that fits and
/// `measuredGrid` publishes it, so whoever drives resizes the Mac pane to match.
@MainActor
final class WatchTerminal: ObservableObject, WatchRendering {
    var onFailure: ((Error) -> Void)?
    var canRender: @MainActor () -> Bool = { true }
    @Published private(set) var isReady = false
    @Published private(set) var failure: WatchTerminalFailure?
    @Published private(set) var measuredGrid: CompanionTerminalStream.Grid?
    @Published fileprivate var surface: WatchNativeSurface?
    private(set) var fontSize: Float = 13

    private var boundary = WatchTerminalBoundary()
    private var modeProbe: UUID?
    private var operations: [Data] = []
    private var queuedBytes = 0
    private var epoch = UUID()
    private var scrollbackBound = 0
    private var deadlineStarted: ContinuousClock.Instant?
    private var deadline: Task<Void, Never>?
    private var drainToken: UUID?
    private let drainQueue = DispatchQueue(label: "app.awesomux.watch-renderer-drain")
    private let discardedWrites = WatchDiscardedWrites()
    private static let maximumQueuedBytes = CompanionTerminalStream.maximumSnapshotBytes
    private static let maximumOperations = 256
    static let fontSizes: ClosedRange<Float> = 8...28
    // Native logging is independent of TerminalDebugLog. The pinned engine
    // reads this setting once in ghostty_init, before any controller exists.
    private static let nativeLoggingDisabled = setenv("GHOSTTY_LOG", "no-stderr,no-macos", 1) == 0

    init() {
        _ = Self.nativeLoggingDisabled
        TerminalDebugLog.disable()
    }

    var isIdle: Bool { isReady && operations.isEmpty && drainToken == nil }
    var discardedWriteByteCount: Int { discardedWrites.count }

    func reset(scrollbackBound: Int) throws {
        clear()
        try requireAuthority()
        guard Self.nativeLoggingDisabled else { throw diagnosticFailure(.unsafeConfiguration) }
        guard drainToken == nil else { throw diagnosticFailure(.nativeBusy) }
        guard scrollbackBound >= 0 else { throw diagnosticFailure(.invalidRetention) }
        self.scrollbackBound = min(scrollbackBound, Self.maximumQueuedBytes)
        TerminalDebugLog.disable()
        let identity = epoch
        surface = try WatchNativeSurface(fontSize: fontSize, scrollbackBound: self.scrollbackBound,
                                         discardedWrites: discardedWrites,
                                         authority: { [weak self] in self?.checkAuthority() ?? false },
                                         resized: { [weak self] id, value in
            guard let self, self.epoch == identity, self.checkAuthority() else { return }
            self.resized(id: id, value: value)
        })
        armDeadline(.readinessTimeout)
    }

    func feed(_ bytes: Data) throws {
        try requireAuthority()
        if let failure { throw failure }
        guard surface != nil else { throw diagnosticFailure(.notAttached) }
        guard bytes.count <= CompanionTerminalStream.maximumDataBytes,
              bytes.count <= Self.maximumQueuedBytes - queuedBytes,
              operations.count < Self.maximumOperations else {
            throw invalidate(.overflow)
        }
        guard !bytes.isEmpty else { return }
        boundary.receive(bytes)
        operations.append(bytes)
        queuedBytes += bytes.count
        pump()
    }

    func clear() {
        epoch = UUID()
        deadline?.cancel()
        deadline = nil
        deadlineStarted = nil
        boundary = WatchTerminalBoundary()
        modeProbe = nil
        operations.removeAll(keepingCapacity: false)
        queuedBytes = 0
        isReady = false
        failure = nil
        measuredGrid = nil
        surface?.detach()
        surface = nil
        // An uncancellable package drain may still be returning. Keep its token
        // until completion so repeated resets cannot accumulate blocked workers.
    }

    /// Ghostty reflows to the new cell size and reports the grid that now fits.
    func setFontSize(_ size: Float) {
        fontSize = min(max(size, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        guard checkAuthority(), let view = surface?.view else { return }
        view.performBindingAction("set_font_size:\(fontSize)")
        view.fitToSize()
    }

    /// Ghostty scrollback actions, such as `scroll_page_up`.
    func scrollHistory(_ action: String) {
        guard checkAuthority(), isReady else { return }
        _ = surface?.view.surface?.performBindingAction(action)
    }

    // Probe only between complete parser sequences, after native output drains.
    // Fresh marker reports fence replies queued by earlier Mac queries.
    func inputModes() async -> WatchInputModes? {
        guard checkAuthority(), let surface else { return nil }
        let identity = epoch
        let probe = UUID()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !isIdle || !boundary.canProbe || modeProbe != nil {
            guard epoch == identity, checkAuthority(), !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
        }
        guard epoch == identity, checkAuthority(), !Task.isCancelled else { return nil }
        modeProbe = probe
        defer { if modeProbe == probe { modeProbe = nil } }
        let markers = (0..<3).map { _ in UInt16.random(in: 32_768...65_535) }
        surface.modeReports.beginProbe(probe, markers: markers)
        let queries = "\u{1b}[?2004$p\u{1b}[?1$p" + markers.map { "\u{1b}[?\($0)$p" }.joined()
        do { try feed(Data(queries.utf8)) } catch { return nil }
        while ContinuousClock.now < deadline {
            guard epoch == identity, checkAuthority(), !Task.isCancelled else { return nil }
            if let modes = surface.modeReports.readProbe(probe) { return modes }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
        }
        return nil
    }

    func readViewportText() -> String? {
        guard checkAuthority(), isIdle else { return nil }
        return surface?.session.readViewportText()
    }

    fileprivate func checkAuthority() -> Bool {
        guard canRender() else {
            WatchDiagnostics.renderer.notice("authority_lost origin=lifecycle phase=renderer")
            clear()
            return false
        }
        return true
    }

    private func requireAuthority() throws {
        guard checkAuthority() else { throw diagnosticFailure(.accessDenied) }
    }

    private func resized(id: UUID, value: InMemoryTerminalViewport) {
        guard let surface, surface.id == id else { return }
        guard surface.controller.lastConfigurationIssue == nil else {
            _ = invalidate(.unsafeConfiguration)
            return
        }
        // The engine first reports its default pre-layout size. Only a report
        // matching the laid-out view is the grid the phone actually shows.
        // Ghostty sizes pixels with the screen's native scale, which differs from displayScale in zoomed modes.
        let bounds = surface.view.bounds.size
        let scale = surface.view.window?.screen.nativeScale ?? surface.view.traitCollection.displayScale
        guard value.columns > 0, value.rows > 0, scale > 0,
              abs(CGFloat(value.widthPixels) - bounds.width * scale) <= scale,
              abs(CGFloat(value.heightPixels) - bounds.height * scale) <= scale else { return }
        // The Mac rejects grids outside 1...1000 and ends the stream.
        let grid = CompanionTerminalStream.Grid(rows: min(Int(value.rows), 1000), cols: min(Int(value.columns), 1000))
        if measuredGrid != grid { measuredGrid = grid }
        guard !isReady else { return }
        deadline?.cancel()
        isReady = true
        pump()
    }

    private func pump() {
        guard checkAuthority(), isReady, drainToken == nil, let surface, !operations.isEmpty else { return }
        let bytes = operations.removeFirst()
        // A package queue silently trims bytes while detached. Never send
        // it output without an attached, laid-out native surface.
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
    }

    private func armDeadline(_ error: WatchTerminalFailure) {
        deadlineStarted = .now
        deadline?.cancel()
        let identity = epoch
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.epoch == identity, self.checkAuthority() else { return }
            _ = self.invalidate(error)
        }
    }

    private func diagnosticFailure(_ error: WatchTerminalFailure) -> WatchTerminalFailure {
        WatchDiagnostics.renderer.error("renderer_failed reason=\(WatchDiagnostics.reason(error), privacy: .public) rows=\(self.measuredGrid?.rows ?? 0) cols=\(self.measuredGrid?.cols ?? 0) queue_bytes=\(self.queuedBytes) queue_ops=\(self.operations.count) deadline_age_ms=\(self.deadlineStarted.map { WatchDiagnostics.milliseconds(.now - $0) } ?? -1)")
        return error
    }

    @discardableResult
    private func invalidate(_ error: WatchTerminalFailure) -> WatchTerminalFailure {
        _ = diagnosticFailure(error)
        clear()
        failure = error
        onFailure?(error)
        return error
    }
}

enum WatchTerminalFailure: Error, LocalizedError, Equatable {
    case accessDenied, notAttached, invalidRetention, overflow
    case readinessTimeout, drainTimeout, unsafeConfiguration, nativeBusy

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Watch is no longer available."
        case .notAttached: "The Watch renderer is not attached."
        case .invalidRetention: "The terminal history bound is invalid."
        case .overflow: "Watch output exceeded the renderer buffer. Reconnect to continue."
        case .readinessTimeout: "The Watch renderer did not become ready."
        case .drainTimeout: "The Watch renderer did not finish processing output."
        case .unsafeConfiguration: "The Watch renderer could not disable terminal host effects."
        case .nativeBusy: "The previous Watch renderer is still stopping."
        }
    }
}

@MainActor
fileprivate final class WatchNativeSurface: Identifiable,
    TerminalSurfaceOpenURLDelegate, TerminalSurfaceClipboardConfirmationDelegate {
    let id: UUID
    let controller: TerminalController
    let session: InMemoryTerminalSession
    let view: WatchReadOnlyTerminalView
    let modeReports = WatchModeReports()

    init(fontSize: Float, scrollbackBound: Int, discardedWrites: WatchDiscardedWrites,
         authority: @escaping () -> Bool,
         resized: @escaping @MainActor (UUID, InMemoryTerminalViewport) -> Void) throws {
        let identity = UUID()
        id = identity
        let configuration = TerminalConfiguration()
            .fontSize(fontSize).windowPaddingX(0).windowPaddingY(0)
            .custom("clipboard-read", "deny").custom("clipboard-write", "deny")
            .custom("copy-on-select", "none")
            .custom("desktop-notifications", "false")
            .custom("bell-features", "no-system,no-audio,no-attention,no-title,no-border")
            .custom("link-url", "false").custom("link-previews", "false")
            .custom("scrollback-limit-bytes", String(scrollbackBound))
            .custom("keybind", "clear")
        controller = TerminalController(configSource: .none, terminalConfiguration: configuration)
        guard controller.lastConfigurationIssue == nil else { throw WatchTerminalFailure.unsafeConfiguration }
        let modeReports = self.modeReports
        session = InMemoryTerminalSession(write: { bytes in
            discardedWrites.discard(bytes)
            modeReports.receive(bytes)
        }, resize: { value in
            Task { @MainActor in resized(identity, value) }
        })
        view = WatchReadOnlyTerminalView(frame: .zero)
        view.authority = authority
        view.delegate = self
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: fontSize)
        view.controller = controller
        view.accessibilityLabel = "Read-only Mac terminal"
        view.accessibilityHint = "Select text to copy. Use two fingers or the history controls to scroll."
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
        if let surface = terminal.surface, terminal.canRender() {
            WatchNativeRepresentable(surface: surface).id(surface.id)
        }
    }
}

/// The terminal view always takes the container's full bounds, so the grid
/// Ghostty measures is the grid the phone shows.
private struct WatchNativeRepresentable: UIViewRepresentable {
    let surface: WatchNativeSurface
    func makeUIView(context: Context) -> WatchNativeContainer {
        let container = WatchNativeContainer()
        container.addSubview(surface.view)
        return container
    }
    func updateUIView(_ container: WatchNativeContainer, context: Context) {}
    static func dismantleUIView(_ container: WatchNativeContainer, coordinator: ()) {
        for case let view as WatchReadOnlyTerminalView in container.subviews {
            view.setSurfaceVisible(false)
            view.controller = nil
        }
    }
}

private final class WatchNativeContainer: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for case let view as WatchReadOnlyTerminalView in subviews where view.authority() { view.frame = bounds }
    }
}

final class WatchModeReports: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var paste = (version: UInt64(0), enabled: false)
    private var cursor = (version: UInt64(0), enabled: false)

    private struct Probe {
        let id: UUID
        let markers: [UInt16]
        let baseline: (UInt64, UInt64)
        var matched = 0
        var result: WatchInputModes?
    }
    private var probe: Probe?

    func beginProbe(_ id: UUID, markers: [UInt16]) {
        lock.lock(); defer { lock.unlock() }
        probe = Probe(id: id, markers: markers, baseline: (paste.version, cursor.version))
    }

    func readProbe(_ id: UUID) -> WatchInputModes? {
        lock.lock(); defer { lock.unlock() }
        guard probe?.id == id else { return nil }
        return probe?.result
    }

    func receive(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        for byte in bytes {
            if byte == 0x1b { buffer = [byte]; continue }
            guard !buffer.isEmpty else { continue }
            buffer.append(byte)
            if byte == 121 {
                let report = String(decoding: buffer, as: UTF8.self)
                if var pending = probe, pending.result == nil, !pending.markers.isEmpty {
                    let marker = pending.markers[pending.matched]
                    if report == "\u{1b}[?\(marker);0$y" {
                        pending.matched += 1
                        if pending.matched == pending.markers.count {
                            if paste.version > pending.baseline.0, cursor.version > pending.baseline.1 {
                                pending.result = WatchInputModes(bracketedPaste: paste.enabled, applicationCursor: cursor.enabled)
                            }
                            pending.matched = 0
                        }
                    } else { pending.matched = 0 }
                    probe = pending
                }
                for mode in ["2004", "1"] {
                    for state in 1...4 where report == "\u{1b}[?\(mode);\(state)$y" {
                        let isSet = state == 1 || state == 3
                        if mode == "2004" { paste = (paste.version &+ 1, isSet) }
                        else { cursor = (cursor.version &+ 1, isSet) }
                    }
                }
                buffer.removeAll(keepingCapacity: true)
            } else if buffer.count >= 32 {
                buffer.removeAll(keepingCapacity: true)
            }
        }
    }
}
