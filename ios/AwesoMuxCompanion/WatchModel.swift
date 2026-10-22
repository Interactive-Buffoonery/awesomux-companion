import AwesoMuxCompanionProtocol
import Foundation
import Observation

@MainActor @Observable
final class WatchModel {
    enum Status: Equatable { case idle, connecting, snapshot, live, failed }

    private(set) var status = Status.idle
    private(set) var grid: CompanionTerminalStream.Grid?
    private(set) var historyIncomplete = false
    private(set) var leader: String?
    private(set) var activeRoute: CompanionRoute?
    private(set) var error: String?

    @ObservationIgnored private let renderer: any WatchRendering
    @ObservationIgnored private let canWatch: @MainActor () -> Bool
    @ObservationIgnored private let makeClient: (PairingRecord, CompanionRoute) throws -> any WatchClient
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var connection: (any WatchConnection)?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var allowed = false
    @ObservationIgnored private var lanFailed = false
    @ObservationIgnored private var retrySeconds = 1

    private struct Target: Equatable {
        let record: PairingRecord
        let paneID: UUID
        let targetVersion: UUID
    }

    init(renderer: any WatchRendering, canWatch: @escaping @MainActor () -> Bool = { true },
         makeClient: @escaping (PairingRecord, CompanionRoute) throws -> any WatchClient = { record, route in
             try MacClient(host: route.host, port: record.port, macFingerprint: record.macFingerprint,
                           identity: PhoneIdentity.load(tag: record.identityTag, storage: record.identityStorage))
         },
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.renderer = renderer
        self.canWatch = canWatch
        self.makeClient = makeClient
        self.sleep = sleep
    }

    @discardableResult
    func start(record: PairingRecord, paneID: UUID, targetVersion: UUID) -> Task<Void, Never>? {
        let next = Target(record: record, paneID: paneID, targetVersion: targetVersion)
        guard next != target || task == nil else { return task }
        cancelAndClear()
        target = next
        lanFailed = false
        retrySeconds = 1
        launchIfAllowed()
        return task
    }

    func updateLifecycle(isActive: Bool, isUnlocked: Bool, isVisible: Bool) {
        let next = isActive && isUnlocked && isVisible
        guard allowed != next else { return }
        allowed = next
        if next {
            lanFailed = false
            retrySeconds = 1
            launchIfAllowed()
        } else {
            cancelAndClear()
        }
    }

    func reconnect() {
        cancelAndClear()
        lanFailed = false
        retrySeconds = 1
        launchIfAllowed()
    }

    func stop() {
        target = nil
        cancelAndClear()
    }

    /// Native renderer readiness failures can arrive after a synchronous feed.
    func rendererFailed(_ error: Error) {
        cancelAndClear()
        status = .failed
        if Self.isTransientRendererFailure(error) {
            self.error = Self.message(for: error)
            guard allowed, canWatch(), let target else { return }
            let epoch = epoch
            let delay = retrySeconds
            task = Task { [weak self] in
                guard let self, self.isCurrent(epoch) else { return }
                do { try await self.sleep(.seconds(delay)) } catch { return }
                guard self.isCurrent(epoch) else { return }
                self.retrySeconds = min(delay * 2, 15)
                await self.run(target, epoch: epoch)
            }
            return
        }
        if let failure = error as? WatchTerminalFailure,
           failure == .invalidGrid || failure == .drawableTooLarge {
            self.error = String(localized: "This terminal's dimensions can't be displayed.")
        } else {
            self.error = String(localized: "This terminal couldn't be displayed. Reconnect to try again.")
        }
    }

    private func launchIfAllowed() {
        guard allowed, canWatch(), let target, task == nil else { return }
        let epoch = epoch
        status = .connecting
        error = nil
        task = Task { [weak self] in await self?.run(target, epoch: epoch) }
    }

    private func cancelAndClear() {
        epoch = UUID()
        task?.cancel()
        task = nil
        connection?.cancel()
        connection = nil
        clearTerminal()
        activeRoute = nil
        status = .idle
        error = nil
    }

    private func clearTerminal() {
        renderer.clear()
        grid = nil
        leader = nil
        historyIncomplete = false
    }

    private func isCurrent(_ epoch: UUID) -> Bool {
        guard self.epoch == epoch else { return false }
        guard allowed, canWatch(), !Task.isCancelled else {
            cancelAndClear()
            return false
        }
        return true
    }

    private func run(_ target: Target, epoch: UUID) async {
        while isCurrent(epoch) {
            do {
                status = .connecting
                let (opened, route) = try await attach(target, epoch: epoch)
                guard isCurrent(epoch) else { opened.cancel(); return }
                connection = opened
                activeRoute = route
                if route.transport == .tailscale { lanFailed = true }
                var stream = try WatchStream(paneID: target.paneID, targetVersion: target.targetVersion,
                                             capabilities: opened.capabilities)
                while isCurrent(epoch) {
                    let packet = try await opened.receive()
                    guard isCurrent(epoch) else { opened.cancel(); return }
                    let event = try stream.consume(packet)
                    do {
                        try render(event)
                    } catch let failure as WatchTerminalFailure where Self.isTransientRendererFailure(failure) {
                        // Drop this stream and request a fresh snapshot after the bounded backoff.
                        throw failure
                    } catch {
                        guard isCurrent(epoch) else { opened.cancel(); return }
                        rendererFailed(error)
                        return
                    }
                    // A renderer may synchronously report a delayed native failure during feed/reset.
                    guard isCurrent(epoch) else { opened.cancel(); return }
                    if status == .live { retrySeconds = 1 }
                }
                return
            } catch {
                guard isCurrent(epoch) else { return }
                connection?.cancel()
                connection = nil
                if activeRoute?.transport == .lan, !Self.isTransientRendererFailure(error) {
                    lanFailed = true
                }
                activeRoute = nil
                clearTerminal()
                self.error = Self.message(for: error)
                status = .failed
                guard Self.canRetry(error) else { task = nil; return }
                do {
                    try await sleep(.seconds(retrySeconds))
                } catch { return }
                guard isCurrent(epoch) else { return }
                retrySeconds = min(retrySeconds * 2, 15)
            }
        }
    }

    private func attach(_ target: Target, epoch: UUID) async throws -> (any WatchConnection, CompanionRoute) {
        let routes = target.record.allRoutes
        let ordered = lanFailed
            ? routes.filter { $0.transport == .tailscale } + routes.filter { $0.transport != .tailscale }
            : routes
        var failures: [MacClientFailure] = []
        for route in ordered {
            try Task.checkCancellation()
            guard isCurrent(epoch) else { throw CancellationError() }
            do {
                let client = try makeClient(target.record, route)
                let opened = try await client.openWatch(connectionID: target.record.connectionID,
                    paneID: target.paneID, targetVersion: target.targetVersion,
                    canSend: { [weak self] in self?.isCurrent(epoch) ?? false })
                return (opened, route)
            } catch let failure as MacClientFailure where [.unreachable, .closed, .handshakeRejected].contains(failure) {
                try Task.checkCancellation()
                failures.append(failure)
            }
        }
        throw failures.first { $0 != .handshakeRejected } ?? failures.first ?? MacClientFailure.unreachable
    }

    private func render(_ event: WatchStream.Event) throws {
        switch event {
        case .reset(let begin):
            // Destroy the previous generation before creating its replacement.
            clearTerminal()
            grid = begin.grid
            leader = begin.leader
            historyIncomplete = true
            status = .snapshot
            error = nil
            try renderer.reset(grid: begin.grid, scrollbackBound: begin.scrollbackBound)
        case .bytes(let bytes): try renderer.feed(bytes)
        case .ready: status = .live; error = nil
        case .grid(let grid):
            try renderer.resize(grid)
            self.grid = grid
        case .leader(let leader): self.leader = leader
        case .heartbeat: break
        }
    }

    private static func isTransientRendererFailure(_ error: Error) -> Bool {
        guard let failure = error as? WatchTerminalFailure else { return false }
        return [.nativeBusy, .overflow, .readinessTimeout, .drainTimeout].contains(failure)
    }

    private static func canRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is WatchTerminalFailure { return isTransientRendererFailure(error) }
        if let failure = error as? MacClientFailure {
            switch failure {
            case .api, .denied: return false
            default: return true
            }
        }
        if let failure = error as? WatchFailure {
            switch failure {
            case .unsupportedStream, .invalidDimensions: return false
            case .ended(let reason): return reason == .overflow || reason == .closed
            default: return true
            }
        }
        return error is CompanionTerminalStream.Failure
    }

    private static func message(for error: Error) -> String {
        if (error as? WatchTerminalFailure) == .nativeBusy {
            return String(localized: "The previous terminal is still stopping. Reconnecting…")
        }
        if isTransientRendererFailure(error) {
            return String(localized: "The terminal display was interrupted. Reconnecting…")
        }
        if let failure = error as? WatchFailure {
            switch failure {
            case .unsupportedStream: return String(localized: "Update awesoMux on your Mac to watch this terminal.")
            case .invalidDimensions: return String(localized: "This terminal's dimensions can't be displayed.")
            case .ended(.revoked): return String(localized: "Watch access was removed on your Mac.")
            case .ended(.paneUnavailable), .ended(.sessionEnded): return String(localized: "This terminal is no longer available.")
            case .ended(.roleChanged): return String(localized: "Terminal permissions changed. Reconnect to continue watching.")
            case .ended(.superseded): return String(localized: "This terminal was opened in another Watch view.")
            default: return String(localized: "The terminal stream was interrupted. Reconnecting…")
            }
        }
        if let failure = error as? MacClientFailure {
            switch failure {
            case .api, .denied: return String(localized: "Your Mac didn't allow this terminal. Check Watch access on your Mac.")
            case .handshakeRejected: return String(localized: "Your Mac didn't match this pairing. Check your connection or pair again.")
            default: break
            }
        }
        return String(localized: "Couldn't connect to this terminal. Check your Mac and network.")
    }
}
