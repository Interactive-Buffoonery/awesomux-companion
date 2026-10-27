import AwesoMuxCompanionProtocol
import Combine
import Foundation
import GhosttyTerminal
import SwiftUI
import UIKit
import os

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

    private var boundary = WatchTerminalBoundary()
    private var modeProbe: UUID?
    private var operations: [Operation] = []
    private var queuedBytes = 0
    private var epoch = UUID()
    private var target: CompanionTerminalStream.Grid?
    private var scrollbackBound = 0
    private var sizingAttempts = 0
    private var deadlineStarted: ContinuousClock.Instant?
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
        guard Self.nativeLoggingDisabled else { throw diagnosticFailure(.unsafeConfiguration) }
        guard drainToken == nil else { throw diagnosticFailure(.nativeBusy) }
        try validate(grid)
        guard scrollbackBound >= 0 else { throw diagnosticFailure(.invalidRetention) }
        self.scrollbackBound = min(scrollbackBound, Self.maximumQueuedBytes)
        target = grid
        let fontSize = WatchDrawableBudget.fontSize(for: grid)
        let cell = WatchDrawableBudget.cellSize(fontSize: fontSize)
        let surface = try makeSurface(size: CGSize(width: CGFloat(grid.cols) * cell.width,
                                                  height: CGFloat(grid.rows) * cell.height),
                                      fontSize: fontSize)
        self.surface = surface
        beginSizing()
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
        operations.append(.bytes(bytes))
        queuedBytes += bytes.count
        pump()
    }

    func resize(_ grid: CompanionTerminalStream.Grid) throws {
        try requireAuthority()
        if let failure { throw failure }
        try validate(grid)
        guard surface != nil else { throw diagnosticFailure(.notAttached) }
        guard operations.count < Self.maximumOperations else { throw invalidate(.overflow) }
        operations.append(.grid(grid))
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

    /// Ghostty scrollback actions, such as `scroll_page_up`.
    func scrollHistory(_ action: String) {
        guard checkAuthority(), isReady else { return }
        _ = surface?.view.surface?.performBindingAction(action)
    }

    func phoneGrid(for size: CGSize) -> CompanionTerminalStream.Grid {
        var cell = WatchDrawableBudget.cellSize(fontSize: WatchDrawableBudget.maximumFontSize)
        // Size and viewport only agree once sizing finishes.
        if isReady, let surface, let viewport = surface.viewport, viewport.columns > 0, viewport.rows > 0 {
            let ratio = CGFloat(WatchDrawableBudget.maximumFontSize / surface.fontSize)
            cell = CGSize(width: surface.size.width / CGFloat(viewport.columns) * ratio,
                          height: surface.size.height / CGFloat(viewport.rows) * ratio)
        }
        return .init(rows: max(1, min(1000, Int(size.height / max(1, cell.height)))),
                     cols: max(1, min(1000, Int(size.width / max(1, cell.width)))))
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

    private func validate(_ grid: CompanionTerminalStream.Grid) throws {
        guard (1...1000).contains(grid.cols), (1...1000).contains(grid.rows),
              grid.cols * grid.rows <= 250_000 else { throw diagnosticFailure(.invalidGrid, grid: grid) }
    }

    private func makeSurface(size: CGSize, fontSize: Float, displayScale: CGFloat = 3) throws -> WatchNativeSurface {
        let screenScale = UIApplication.shared.connectedScenes.compactMap {
            ($0 as? UIWindowScene)?.screen.scale
        }.max() ?? 3
        try WatchDrawableBudget.validate(size: size, displayScale: max(screenScale, displayScale))
        TerminalDebugLog.disable()
        let identity = epoch
        return try WatchNativeSurface(size: size, fontSize: fontSize, scrollbackBound: scrollbackBound,
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
                // sees exactly one resize, at the authoritative font and size.
                do {
                    try surface.resize(to: sizingSurface.size, fontSize: sizingSurface.fontSize,
                                       displayScale: sizingSurface.view.traitCollection.displayScale)
                } catch let failure as WatchTerminalFailure {
                    _ = invalidate(failure)
                    return
                } catch {
                    _ = invalidate(.drawableTooLarge)
                    return
                }
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
        let scale = sizingSurface.view.traitCollection.displayScale
        // The engine first reports its default pre-layout size; extrapolating
        // from that overshoots wide grids. Wait for the laid-out report.
        guard abs(CGFloat(value.widthPixels) - sizingSurface.size.width * scale) <= scale,
              abs(CGFloat(value.heightPixels) - sizingSurface.size.height * scale) <= scale else { return }
        sizingAttempts += 1
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
        do {
            try sizingSurface.resize(to: next)
        } catch {
            _ = invalidate(.drawableTooLarge)
        }
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
            // Every grid gets the font reset would pick for it, so a phone
            // claim shrinking a wide Mac grid renders at full size.
            target = grid
            beginSizing()
            do {
                let fontSize = WatchDrawableBudget.fontSize(for: grid)
                let cell = WatchDrawableBudget.cellSize(fontSize: fontSize)
                probe = try makeSurface(size: CGSize(width: CGFloat(grid.cols) * cell.width,
                                                     height: CGFloat(grid.rows) * cell.height),
                                        fontSize: fontSize,
                                        displayScale: surface.view.traitCollection.displayScale)
            } catch let failure as WatchTerminalFailure {
                _ = invalidate(failure)
            } catch {
                _ = invalidate(.unsafeConfiguration)
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

    private func diagnosticFailure(_ error: WatchTerminalFailure, grid: CompanionTerminalStream.Grid? = nil) -> WatchTerminalFailure {
        let diagnosticGrid = grid ?? target
        WatchDiagnostics.renderer.error("renderer_failed reason=\(WatchDiagnostics.reason(error), privacy: .public) rows=\(diagnosticGrid?.rows ?? 0) cols=\(diagnosticGrid?.cols ?? 0) queue_bytes=\(self.queuedBytes) queue_ops=\(self.operations.count) deadline_age_ms=\(self.deadlineStarted.map { WatchDiagnostics.milliseconds(.now - $0) } ?? -1)")
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
    case accessDenied, notAttached, invalidGrid, invalidRetention, overflow, drawableTooLarge
    case readinessTimeout, drainTimeout, unexpectedGrid, unsafeConfiguration, nativeBusy

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Watch is no longer available."
        case .notAttached: "The Watch renderer is not attached."
        case .invalidGrid: "The terminal grid exceeds the Watch renderer limit."
        case .drawableTooLarge: "The terminal dimensions exceed the Watch renderer's display limit."
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

enum WatchDrawableBudget {
    static let maximumFontSize: Float = 13

    /// Measured on iOS 26 at 3x: a 13pt cell is about 10.6x23.1pt and scales
    /// linearly with the font size.
    static func cellSize(fontSize: Float) -> CGSize {
        let ratio = CGFloat(fontSize / maximumFontSize)
        return CGSize(width: 10.6 * ratio, height: 23.1 * ratio)
    }

    /// Largest font, up to 13pt, whose estimated drawable fits the budget, so
    /// wide Mac grids render small instead of failing. 20% headroom per side
    /// covers padding and measurement error.
    static func fontSize(for grid: CompanionTerminalStream.Grid) -> Float {
        let side: CGFloat = 8192 / 3 * 0.8
        let cell = cellSize(fontSize: maximumFontSize)
        let width = CGFloat(grid.cols) * cell.width, height = CGFloat(grid.rows) * cell.height
        let fit = min(1, side / width, side / height, (8_388_608 * 0.64 / 9 / (width * height)).squareRoot())
        return max(1, (maximumFontSize * Float(fit) * 2).rounded(.down) / 2)
    }

    static func validate(size: CGSize, displayScale: CGFloat) throws {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              displayScale.isFinite, displayScale > 0 else { throw WatchTerminalFailure.drawableTooLarge }
        let scale = max(displayScale, 3)
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        // BGRA uses four bytes per pixel: at most 32 MiB per drawable.
        guard width <= 8192, height <= 8192,
              width * height <= 8_388_608 else { throw WatchTerminalFailure.drawableTooLarge }
    }
}

@MainActor
fileprivate final class WatchNativeSurface: ObservableObject, Identifiable,
    TerminalSurfaceOpenURLDelegate, TerminalSurfaceClipboardConfirmationDelegate {
    let id: UUID
    let controller: TerminalController
    let session: InMemoryTerminalSession
    let view: WatchReadOnlyTerminalView
    private(set) var fontSize: Float
    let modeReports = WatchModeReports()
    @Published private(set) var size: CGSize
    var viewport: InMemoryTerminalViewport?

    init(size: CGSize, fontSize: Float, scrollbackBound: Int, discardedWrites: WatchDiscardedWrites,
         authority: @escaping () -> Bool,
         resized: @escaping @MainActor (UUID, InMemoryTerminalViewport) -> Void) throws {
        let identity = UUID()
        id = identity
        self.size = size
        self.fontSize = fontSize
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
        view = WatchReadOnlyTerminalView(frame: CGRect(origin: .zero, size: size))
        view.authority = authority
        view.delegate = self
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: fontSize)
        view.controller = controller
        view.accessibilityLabel = "Read-only Mac terminal"
        view.accessibilityHint = "Select text to copy. Use two fingers or the history controls to scroll."
    }

    func resize(to size: CGSize, fontSize: Float? = nil, displayScale: CGFloat = 3) throws {
        try WatchDrawableBudget.validate(size: size,
            displayScale: max(displayScale, view.traitCollection.displayScale))
        if let fontSize, fontSize != self.fontSize {
            // One native step: setting the font alone would resize the grid at
            // the old pixel size first and drop rows the final grid keeps.
            guard view.setFontSize(fontSize, size: size) else { throw WatchTerminalFailure.notAttached }
            self.fontSize = fontSize
        }
        self.size = size
        applySize()
    }

    func applySize() {
        view.frame = CGRect(origin: .zero, size: size)
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
    var zoom: Double = 1

    var body: some View {
        ZStack {
            if let surface = terminal.surface, terminal.canRender() {
                // Bottom-anchored so the prompt stays in view when the keyboard shortens the pane.
                ScrollView([.horizontal, .vertical]) {
                    WatchNativeCanvas(surface: surface)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: surface.size.width * zoom,
                               height: surface.size.height * zoom, alignment: .topLeading)
                }
                .defaultScrollAnchor(.bottomLeading)
            }
        }
        .overlay(alignment: .topLeading) {
            if let probe = terminal.probe {
                WatchNativeCanvas(surface: probe)
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
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

/// SwiftUI sizes only the container; the terminal view's frame is ours alone, so a
/// keyboard relayout can never leave the two disagreeing about its geometry.
private struct WatchNativeRepresentable: UIViewRepresentable {
    let surface: WatchNativeSurface
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.addSubview(surface.view)
        return container
    }
    func updateUIView(_ container: UIView, context: Context) {
        guard surface.view.superview === container, surface.view.authority() else { return }
        surface.applySize()
    }
    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        for case let view as WatchReadOnlyTerminalView in container.subviews {
            view.setSurfaceVisible(false)
            view.controller = nil
        }
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
