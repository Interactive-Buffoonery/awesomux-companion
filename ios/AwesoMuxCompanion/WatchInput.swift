import os
import AwesoMuxCompanionProtocol
import Foundation
import Observation

struct WatchInputModes: Equatable {
    var bracketedPaste = false
    var applicationCursor = false
}

enum WatchPaste {
    static let tooLarge = "Too large to paste (64 KB). Copy it to a file on the Mac instead."
    static let strip: Set<UInt8> = [0x00, 0x08, 0x05, 0x04, 0x1b, 0x7f, 0x03, 0x1c,
                                   0x15, 0x1a, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0f]
    static func isSafe(_ text: String, bracketed: Bool) -> Bool {
        !text.contains("\u{1b}[201~") && (bracketed || !text.utf8.contains(where: { $0 == 10 || $0 == 13 }))
    }

    // Swift port of Ghostty input/paste.zig's text insertion path.
    static func encode(_ text: String, bracketed: Bool) -> Data {
        let body = text.utf8.map { byte in
            strip.contains(byte) ? UInt8(32) : (!bracketed && byte == 10 ? UInt8(13) : byte)
        }
        return bracketed ? Data("\u{1b}[200~".utf8) + Data(body) + Data("\u{1b}[201~".utf8) : Data(body)
    }
}

struct WatchKeyModifiers {
    enum State: Equatable { case off, once, locked }
    var control = State.off
    var alt = State.off

    static func tapped(_ state: State, doubleTap: Bool) -> State {
        if doubleTap { return .locked }
        return state == .off ? .once : .off
    }

    mutating func encode(_ text: String, control heldControl: Bool = false, alt heldAlt: Bool = false) -> Data {
        let (useControl, useAlt) = consume(control: heldControl, alt: heldAlt)
        var bytes = Data(text.utf8)
        if useControl, bytes.count == 1, let byte = bytes.first {
            switch byte {
            case 64...95, 97...122: bytes = Data([byte & 0x1f])
            case 32: bytes = Data([0])
            case 63: bytes = Data([127])
            default: break
            }
        }
        if useAlt { bytes.insert(0x1b, at: 0) }
        return bytes
    }

    mutating func consume(control heldControl: Bool = false, alt heldAlt: Bool = false) -> (control: Bool, alt: Bool) {
        let useControl = heldControl || control != .off
        let useAlt = heldAlt || alt != .off
        if control == .once { control = .off }
        if alt == .once { alt = .off }
        return (useControl, useAlt)
    }

    static func arrow(_ final: Character, application: Bool) -> String {
        "\u{1b}" + (application ? "O" : "[") + String(final)
    }
}

@MainActor @Observable
final class WatchInput {
    typealias Stream = CompanionTerminalStream
    enum Delivery: String { case sending, sent, notSent = "not sent", mayHaveRun = "may have run" }
    struct Confirmation: Identifiable {
        let id = UUID()
        let text: String
        let encoded: Data
        let generation: UInt32
        let modes: WatchInputModes
        var preview: String { String(decoding: encoded, as: UTF8.self).prefix(1200).description }
    }
    private struct Job {
        /// Nil for an automatic resize, whose frame is decided when it sends.
        let frame: Stream.Frame?
        let sequence: UInt64?
        let paste: Bool
    }

    private(set) var isInteractive = false
    private(set) var isLive = false
    private(set) var keyboardRequested = false
    private(set) var generation: UInt32?
    private(set) var watchMessage: String?
    private(set) var pasteDelivery: Delivery?
    private(set) var pasteError: String?
    private var typedRefusal: String?
    private var typedUncertain = false
    var typedNotice: String? {
        typedRefusal ?? (typedUncertain ? "Typed input may have run. Check the terminal before typing it again." : nil)
    }
    private(set) var confirmation: Confirmation?
    /// Nil until the terminal has measured the grid that fits on screen.
    var preferredGrid: Stream.Grid?
    var leader: String? { didSet { claimPending = false } }
    var ownLeaderID: String?

    @ObservationIgnored private var connection: (any WatchConnection)?
    @ObservationIgnored private var authority: @MainActor () -> Bool = { false }
    @ObservationIgnored private var nextSequence: UInt64 = 0
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var outstanding: [UInt64: TimeInterval] = [:]
    @ObservationIgnored private var pasteSequence: UInt64?
    @ObservationIgnored private var highestTyped: UInt64?
    @ObservationIgnored private var highestAck: UInt64?
    @ObservationIgnored private var lastSentGrid: Stream.Grid?
    @ObservationIgnored private var claimPending = false
    @ObservationIgnored private var maximum = Stream.maximumInputBytes
    @ObservationIgnored private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    var sessionID: UUID { token }
    var canType: Bool { isInteractive && isLive && generation != nil && preferredGrid != nil && authority() }
    var pasteInFlight: Bool { pasteDelivery == .sending }
    var drivingText: String {
        guard let leader else { return "No one has control" }
        if hasControl { return "You have control" }
        return leader == "mac" ? "Mac has control" : "Another terminal has control"
    }

    var hasControl: Bool {
        guard let leader, let ownLeaderID else { return false }
        return leader.caseInsensitiveCompare(ownLeaderID) == .orderedSame
    }

    func attach(_ connection: any WatchConnection, ownLeaderID: String,
                authority: @escaping @MainActor () -> Bool) {
        disconnect()
        self.connection = connection
        self.ownLeaderID = ownLeaderID
        self.authority = authority
        maximum = min(Stream.maximumInputBytes, connection.capabilities.inputFrameMax ?? 0)
        isInteractive = connection.accepted.role == .interactive && maximum > 0
        switch connection.accepted.watchReason {
        case .inputOff: watchMessage = String(localized: "Typing from this iPhone is off. Allow it on the Mac in Settings › Companion.")
        case .remotePane: watchMessage = String(localized: "Typing isn't available for this remote pane.")
        case nil: watchMessage = nil
        }
    }

    func begin(generation: UInt32, leader: String?) {
        endGeneration()
        self.generation = generation
        self.leader = leader
        claimPending = false
        nextSequence = 0
        highestAck = nil
        highestTyped = nil
        pasteSequence = nil
        lastSentGrid = nil
    }

    func ready(opening: TerminalOpening = .watch) {
        isLive = true
        openIfReady(opening)
        sendPhoneGrid()
    }

    func openIfReady(_ opening: TerminalOpening) {
        if opening == .input, preferredGrid != nil, canType, !keyboardRequested {
            takeOver()
            keyboardRequested = true
        }
    }

    func updatePhoneGrid(_ grid: Stream.Grid) {
        preferredGrid = grid
        sendPhoneGrid()
    }

    // A queued resize or claim sends the latest grid, so one pending job covers a burst of layouts.
    private func sendPhoneGrid() {
        guard canType, phoneGridFrame() != nil, !jobs.contains(where: { $0.sequence == nil }), jobs.count < 64 else { return }
        jobs.append(Job(frame: nil, sequence: nil, paste: false))
        runWorker()
    }

    private func phoneGridFrame() -> Stream.Frame? {
        guard keyboardRequested || hasControl, let grid = preferredGrid, grid != lastSentGrid else { return nil }
        // The Mac only caches a bare grid frame; re-claiming applies the keyboard-sized grid now.
        return claimPending || hasControl ? .claim(.init(grid: grid)) : .grid(grid)
    }

    func takeOver() {
        guard canType, let grid = preferredGrid, jobs.count < 64 else { return }
        jobs.append(Job(frame: .claim(.init(grid: grid)), sequence: nil, paste: false))
        claimPending = true
        runWorker()
    }

    // Each call is one key event. In particular a lone Escape always owns a frame.
    func type(_ bytes: Data) { enqueue(bytes, paste: false) }

    func paste(_ text: String, modes: WatchInputModes) {
        guard canType else { return }
        guard !pasteInFlight, confirmation == nil else { refuseQueuedInput(paste: true); return }
        pasteError = nil
        guard !text.isEmpty else { return }
        // Bound allocation before encoding; stripping and CR conversion never shrink UTF-8.
        guard text.utf8.count <= maximum else { refusePaste(WatchPaste.tooLarge); return }
        let bytes = WatchPaste.encode(text, bracketed: modes.bracketedPaste)
        guard bytes.count <= maximum else { refusePaste(WatchPaste.tooLarge); return }
        guard WatchPaste.isSafe(text, bracketed: modes.bracketedPaste) else {
            confirmation = Confirmation(text: text, encoded: bytes, generation: generation!, modes: modes)
            return
        }
        enqueue(bytes, paste: true)
    }

    func confirmPaste(modes: WatchInputModes) {
        guard let confirmation else { return }
        self.confirmation = nil
        guard canType, confirmation.generation == generation else { return }
        // Output may have changed mode while the confirmation was open. Re-encode
        // and ask again if its safety or actual bytes changed.
        guard confirmation.modes == modes else { paste(confirmation.text, modes: modes); return }
        enqueue(confirmation.encoded, paste: true)
    }

    func cancelPaste() { confirmation = nil }
    func dismissTypedNotice() { typedRefusal = nil; typedUncertain = false }
    func refuseModeRead(paste: Bool) {
        if paste {
            guard !pasteInFlight, confirmation == nil else { refuseQueuedInput(paste: true); return }
            refusePaste("The terminal is still receiving a control sequence. Try pasting again when output settles.")
        } else {
            typedRefusal = "Key not sent. Try again when terminal output settles."
        }
    }
    func refuseQueuedInput(paste: Bool) {
        if paste { pasteError = "A paste is already waiting. Try again after it settles." }
        else { typedRefusal = "Key not sent. Input is busy; try again after it settles." }
    }

    func acknowledge(_ sequence: UInt64, generation: UInt32) {
        guard self.generation == generation, sequence < nextSequence else { return }
        highestAck = max(highestAck ?? sequence, sequence)
        outstanding = outstanding.filter { $0.key > sequence }
        if let pasteSequence, pasteSequence <= sequence { pasteDelivery = .sent }
        if let highestTyped, highestTyped <= sequence { typedUncertain = false }
    }

    func checkDeadlines() {
        let expired = outstanding.filter { now() - $0.value >= 2 }
        if let pasteSequence, expired[pasteSequence] != nil { pasteDelivery = .mayHaveRun }
        if expired.keys.contains(where: { $0 != pasteSequence }) {
            typedUncertain = true
        }
        for sequence in expired.keys { outstanding.removeValue(forKey: sequence) }
    }

    func disconnect() {
        endGeneration()
        generation = nil
        connection = nil
        isInteractive = false
        leader = nil
    }

    private func endGeneration() {
        keyboardRequested = false
        if let highestTyped, highestAck.map({ highestTyped > $0 }) ?? true {
            typedUncertain = true
        }
        if pasteDelivery == .sending {
            pasteDelivery = pasteSequence.map { outstanding[$0] != nil ? .mayHaveRun : .notSent } ?? .notSent
        }
        token = UUID()
        worker = nil
        timer?.cancel()
        timer = nil
        jobs.removeAll()
        outstanding.removeAll()
        confirmation = nil
        isLive = false
    }

    private func refusePaste(_ error: String? = nil) {
        pasteSequence = nil
        pasteDelivery = .notSent
        if let error { pasteError = error }
    }

    private func enqueue(_ bytes: Data, paste: Bool) {
        guard canType, !bytes.isEmpty, bytes.count <= maximum, jobs.count < 64,
              outstanding.count < 512, nextSequence < UInt64.max else {
            if paste { refusePaste() }
            else if canType { refuseQueuedInput(paste: false) }
            return
        }
        guard !paste || !pasteInFlight else { return }
        let sequence = nextSequence
        nextSequence += 1
        if paste { pasteDelivery = .sending; pasteSequence = sequence }
        jobs.append(Job(frame: .input(sequence: sequence, bytes: bytes), sequence: sequence, paste: paste))
        runWorker()
    }

    private func runWorker() {
        guard worker == nil, let connection, let generation else { return }
        let identity = token
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                while self.token == identity, !self.jobs.isEmpty {
                    if self.jobs[0].frame == nil {
                        // ponytail: fixed settle delay bounds Mac resizes to ~10/s; tune if TUIs still thrash.
                        try? await Task.sleep(for: .milliseconds(100))
                        guard self.token == identity else { return }
                    }
                    let job = self.jobs.removeFirst()
                    guard self.canType, let grid = self.preferredGrid else { self.disconnect(); return }
                    let frame: Stream.Frame
                    switch job.frame {
                    case nil:
                        // Leadership is checked now, so a stale layout never undoes a handback to the Mac.
                        guard let resize = self.phoneGridFrame() else { continue }
                        frame = resize
                    case .claim?:
                        frame = .claim(.init(grid: grid))
                    case let other?:
                        frame = other
                    }
                    if job.sequence != nil, self.lastSentGrid != grid {
                        try await connection.send(.grid(grid), generation: generation) { [weak self] in
                            self?.maySend(identity) ?? false
                        }
                        guard self.token == identity else { return }
                        self.lastSentGrid = grid
                    }
                    try await connection.send(frame, generation: generation) { [weak self] in
                        guard let self, self.maySend(identity) else { return false }
                        if let sequence = job.sequence {
                            self.outstanding[sequence] = self.now()
                            if !job.paste { self.highestTyped = sequence }
                            self.startTimer()
                        }
                        return true
                    }
                    guard self.token == identity else { return }
                    if case .claim(let claim) = frame { self.lastSentGrid = claim.grid }
                    if case .grid(let grid) = frame { self.lastSentGrid = grid }
                    // A layout that changed back while this frame was sending still needs to reach the Mac.
                    if self.jobs.isEmpty { self.sendPhoneGrid() }
                }
                guard self.token == identity else { return }
                self.worker = nil
            } catch {
                WatchDiagnostics.input.error("input_worker_failed generation=\(generation) reason=\(WatchDiagnostics.reason(error), privacy: .public) queued_ops=\(self.jobs.count) outstanding=\(self.outstanding.count)")
                guard self.token == identity else { return }
                self.connection?.cancel()
                self.disconnect()
            }
        }
    }

    private func maySend(_ identity: UUID) -> Bool { token == identity && canType && !Task.isCancelled }

    private func startTimer() {
        guard timer == nil else { return }
        let identity = token
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.token == identity else { return }
                self.checkDeadlines()
                if self.outstanding.isEmpty { self.timer = nil; return }
            }
        }
    }
}
