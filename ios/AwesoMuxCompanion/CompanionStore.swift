import os
import AwesoMuxCompanionProtocol
import Foundation
import Network
import Observation
import UIKit
import UserNotifications
import WidgetKit

enum PairingStep: Equatable {
    case idle
    /// A link from outside the app (URL or clipboard) waiting for the person to choose Pair.
    case review(PairingLink)
    case connecting(macName: String)
    case confirm(words: [String], macName: String, transport: CompanionTransport)
    case failed(String)
}

protocol CompanionSessionClient: Sendable {
    func call(_ operation: String, connectionID: UUID, limit: Int?, cursor: String?) async throws -> APIResponse
    func call(_ operation: String, connectionID: UUID, limit: Int?, cursor: String?,
              canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse
    func unpair(connectionID: UUID) async throws
    func answerDecision(_ answer: CompanionDecisionAnswer, connectionID: UUID,
                        canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse
    func setTerminalPreview(_ allowed: Bool, connectionID: UUID) async throws -> APIResponse
    func createTerminal(connectionID: UUID, workspaceID: UUID?,
                        canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> CreatedTerminal
}

extension CompanionSessionClient {
    func call(_ operation: String, connectionID: UUID, limit: Int?, cursor: String?,
              canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse {
        guard await canSend() else { throw CancellationError() }
        return try await call(operation, connectionID: connectionID, limit: limit, cursor: cursor)
    }

    func answerDecision(_ answer: CompanionDecisionAnswer, connectionID: UUID,
                        canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse {
        throw MacClientFailure.api("unsupported_operation")
    }

    func createTerminal(connectionID: UUID, workspaceID: UUID?,
                        canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> CreatedTerminal {
        throw MacClientFailure.api("unsupported_operation")
    }

    func setTerminalPreview(_ allowed: Bool, connectionID: UUID) async throws -> APIResponse {
        throw MacClientFailure.api("unsupported_operation")
    }
}

extension MacClient: CompanionSessionClient {}

@MainActor @Observable
final class CompanionStore {
    private(set) var panes = PaneRoster()
    private(set) var decisionPairingID = UUID()
    var decisionPairing: UUID? { record == nil || isUnpairing ? nil : decisionPairingID }
    private(set) var decisionSessionID = UUID()
    private(set) var decisionAccessDenied = false
    var decisionSession: UUID? { record == nil || isUnpairing ? nil : decisionSessionID }

    private(set) var record: PairingRecord?
    private(set) var snapshot: GlanceSnapshot?
    private(set) var isSnapshotCached = false
    /// Whether the latest read reached the Mac.
    private(set) var reachable = false
    private(set) var message: String?
    private(set) var isUnpairing = false
    private(set) var unpairMessage: String? {
        didSet { defaults.set(unpairMessage, forKey: Keys.unpairMessage) }
    }
    private(set) var pairingStep: PairingStep = .idle
    /// The route that answered the latest read; cleared when no route answers.
    private(set) var activeRoute: CompanionRoute?
    /// Pair Again from Settings; the welcome screen also shows whenever no Mac is paired.
    var showingPairing = false
    /// Pane named by a tapped notification; the list scrolls to and highlights it.
    var focusedPaneID: String?
    var isConnected: Bool { reachable && snapshot?.connected == true }
    var liveActivityEnabled: Bool {
        didSet {
            defaults.set(liveActivityEnabled, forKey: Keys.liveActivity)
            if !liveActivityEnabled { Task { await liveActivity?.endAll() } }
        }
    }

    @ObservationIgnored private var clients: [String: any CompanionSessionClient] = [:]
    /// Set when a read falls through to Tailscale; reads stay on Tailscale until the network changes or the app returns to the foreground.
    @ObservationIgnored private var lanFailed = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var routesCheckedAt = Date.distantPast
    /// Bumped whenever the pairing changes so reads that straddle the change are dropped.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var permissionRevision = 0
    @ObservationIgnored private var previewMutationTask: Task<Void, Never>?
    @ObservationIgnored private var previewMutationID: UUID?
    @ObservationIgnored private var previewChoice: PreviewChoice?

    private struct PreviewChoice: Equatable {
        let id = UUID()
        let allowed: Bool
        let pairingRevision: Int
    }
    private struct PreviewSuppression: Codable, Equatable {
        let connectionID: UUID
        let macFingerprint: String
        let identityTag: String

        init(_ record: PairingRecord) {
            connectionID = record.connectionID
            macFingerprint = record.macFingerprint
            identityTag = record.identityTag
        }
    }
    /// A failure confirms connectivity only within one uninterrupted active scene.
    @ObservationIgnored private var foregroundSession: UUID?
    @ObservationIgnored private var panePollID: UUID?
    @ObservationIgnored private var paneReadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var lastSharedWrite = Date.distantPast
    @ObservationIgnored private var tracker: AttentionTracker { didSet { tracker.save(defaults: defaults) } }
    /// Alerts raised since the last roster read; posted once workspace names are known.
    @ObservationIgnored private var pendingAlerts: [APIResponse.Event] = []
    @ObservationIgnored private let liveActivity: LiveActivityController?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cache: SessionSnapshotCache
    @ObservationIgnored private let makeClient: (PairingRecord, CompanionRoute) throws -> any CompanionSessionClient
    @ObservationIgnored private let removePairing: (PairingRecord) throws -> Void
    @ObservationIgnored private let writeShared: (GlanceSnapshot) -> Void
    @ObservationIgnored private let clearShared: () -> Void

    // ponytail: one slot each; stored values name the pairing they belong to. Multi-host keys them by fingerprint.
    private enum Keys {
        static let liveActivity = "liveActivityEnabled"
        static let previewSuppression = "terminalPreviewSuppression"
        static let unpairMessage = "unpairMessage"
        static let revokedConnectionID = "revokedConnectionID"
    }

    init(
        defaults: UserDefaults = .standard,
        loadPairing: () throws -> PairingRecord? = { try PairingStore.system.load() },
        makeClient: @escaping (PairingRecord, CompanionRoute) throws -> any CompanionSessionClient = { record, route in
            try MacClient(host: route.host, port: record.port, macFingerprint: record.macFingerprint,
                          identity: PhoneIdentity.load(tag: record.identityTag, storage: record.identityStorage))
        },
        removePairing: @escaping (PairingRecord) throws -> Void = {
            try PairingStore.system.clearAll(current: $0, deletingIdentity: PhoneIdentity.delete(tag:))
        },
        liveActivity: LiveActivityController? = LiveActivityController(),
        writeShared: @escaping (GlanceSnapshot) -> Void = {
            SharedSnapshot.write($0); WidgetCenter.shared.reloadAllTimelines()
        },
        clearShared: @escaping () -> Void = {
            SharedSnapshot.clear(); WidgetCenter.shared.reloadAllTimelines()
        }
    ) {
        self.defaults = defaults
        cache = SessionSnapshotCache(defaults: defaults)
        self.makeClient = makeClient
        self.removePairing = removePairing
        self.liveActivity = liveActivity
        self.writeShared = writeShared
        self.clearShared = clearShared
        tracker = AttentionTracker.load(defaults: defaults)
        liveActivityEnabled = defaults.object(forKey: Keys.liveActivity) as? Bool ?? true
        unpairMessage = defaults.string(forKey: Keys.unpairMessage)
        do {
            record = try loadPairing()
            if let record, let data = defaults.data(forKey: Keys.previewSuppression),
               let suppression = try? JSONDecoder().decode(PreviewSuppression.self, from: data),
               suppression == PreviewSuppression(record) {
                panes.previewIntent = .keepOff
            }
            snapshot = cache.restore(for: record)
            isSnapshotCached = snapshot != nil
        } catch {
            message = String(localized: "This iPhone's pairing couldn't be read. Pair again to continue.")
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            WatchDiagnostics.routing.notice("path_changed satisfied=\(path.status == .satisfied) expensive=\(path.isExpensive) constrained=\(path.isConstrained)")
            Task { @MainActor in self?.lanFailed = false }
        }
        pathMonitor.start(queue: .main)
    }

    // MARK: Pairing

    func startPairing(_ link: PairingLink) {
        guard !isUnpairing else { return }
        pairingTask?.cancel()
        pairingStep = .connecting(macName: link.macName)
        pairingTask = Task { await pair(link) }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingStep = .idle
    }

    /// Scanned links pair right away; links from a URL or the clipboard wait for the person to choose Pair,
    /// so a tapped link can't make the phone contact a host on its own.
    func openPairingLink(_ text: String, review: Bool) {
        guard !isUnpairing else { return }
        switch pairingStep {
        case .connecting, .confirm: return
        case .idle, .review, .failed: break
        }
        do throws(PairingLink.Failure) {
            let link = try PairingLink(text)
            if review { pairingStep = .review(link) } else { startPairing(link) }
        } catch {
            pairingStep = .failed(error.message)
        }
    }

    private func pair(_ link: PairingLink) async {
        var identity: PhoneIdentity?
        do {
            let created = try PhoneIdentity.create()
            identity = created
            let (session, route) = try await firstAnswering(link.routes) { route in
                try await MacClient(host: route.host, port: link.port, macFingerprint: link.macFingerprint, identity: created)
                    .beginPairing(secret: link.secret, phoneName: String(UIDevice.current.name.prefix(80)))
            }
            try Task.checkCancellation()
            pairingStep = .confirm(words: session.words, macName: link.macName, transport: route.transport)
            let reply = try await withTaskCancellationHandler { try await session.outcome() } onCancel: { session.cancel() }
            try Task.checkCancellation()
            guard let connectionID = reply.connectionID else { throw MacClientFailure.denied }
            let v1 = link.version == 1 ? link.routes.first : nil
            let previous = record
            // Strictly newest even if the clock moved back, since the newest pairing is the one that opens.
            let pairedAt = max(Date.now, previous?.pairedAt.addingTimeInterval(1) ?? .distantPast)
            let next = PairingRecord(
                macName: reply.macName ?? link.macName, host: v1?.host, port: link.port,
                macFingerprint: link.macFingerprint, transport: v1?.transport, routes: v1 == nil ? link.routes : nil,
                connectionID: connectionID, identityTag: created.tag, identityStorage: created.storage, pairedAt: pairedAt)
            let previousGone = try PairingStore.system.replace(previous, with: next)
            replacePairing(with: next)
            if let previous, previous.identityTag != next.identityTag { revoke(previous, deletingIdentity: previousGone) }
            unpairMessage = nil
            defaults.removeObject(forKey: Keys.revokedConnectionID)
            message = nil
            pairingStep = .idle
            showingPairing = false
            requestNotificationPermission()
            await refresh()
        } catch {
            if let identity { try? PhoneIdentity.delete(tag: identity.tag) }
            guard !Task.isCancelled else { return }
            pairingStep = .failed(Self.pairingMessage(for: error))
        }
    }

    func unpair() async {
        guard !isUnpairing, let record else { return }
        isUnpairing = true
        cancelPairing()
        forgetConnection()
        defer { isUnpairing = false }
        var notifiedMac = defaults.string(forKey: Keys.revokedConnectionID) == record.connectionID.uuidString
        if !notifiedMac {
            do {
                _ = try await firstAnswering(record.allRoutes) { route in
                    try await makeClient(record, route).unpair(connectionID: record.connectionID)
                }
                notifiedMac = true
                // Keep the acknowledgement if local deletion needs another attempt.
                defaults.set(record.connectionID.uuidString, forKey: Keys.revokedConnectionID)
            } catch {
                // Local removal must finish even when the Mac cannot acknowledge it.
            }
        }
        unpairMessage = notifiedMac ? nil : String(localized:
            "To finish, also choose Unpair in awesoMux Settings on your Mac.")
        do {
            try removePairing(record)
            defaults.removeObject(forKey: Keys.revokedConnectionID)
            self.record = nil
            discardPreviewSuppression()
            message = nil
        } catch {
            message = String(localized: "This iPhone couldn’t finish unpairing. Choose Unpair This iPhone to try again.")
        }
    }

    /// Best effort, after a new pairing replaces `previous`: if the old Mac can't be reached, its grant stays
    /// until the person unpairs there, the same as an unacknowledged unpair. The old key is deleted only when
    /// `previous` is gone; otherwise unpairing deletes it along with the superseded pairing.
    // This attempt is not persisted; quitting before it finishes can leave the old key in Keychain.
    private func revoke(_ previous: PairingRecord, deletingIdentity: Bool) {
        Task {
            if let identity = try? PhoneIdentity.load(tag: previous.identityTag, storage: previous.identityStorage) {
                _ = try? await firstAnswering(previous.allRoutes) { route in
                    try await MacClient(host: route.host, port: previous.port, macFingerprint: previous.macFingerprint,
                                        identity: identity).unpair(connectionID: previous.connectionID)
                }
            }
            if deletingIdentity { try? PhoneIdentity.delete(tag: previous.identityTag) }
        }
    }

    /// Installs a pairing after its record has been saved successfully.
    func replacePairing(with next: PairingRecord) {
        forgetConnection()
        discardPreviewSuppression()
        record = next
    }

    private func discardPreviewSuppression() {
        defaults.removeObject(forKey: Keys.previewSuppression)
        panes.previewIntent = .followHost
    }

    private func forgetConnection() {
        decisionPairingID = UUID()
        decisionAccessDenied = false
        decisionSessionID = UUID()
        revision += 1
        invalidatePaneRead()
        let previewIntent = panes.previewIntent
        panes.reset()
        panes.previewIntent = previewIntent
        previewChoice = nil
        previewMutationID = nil
        previewMutationTask = nil
        focusedPaneID = nil
        refreshTask?.cancel(); refreshTask = nil
        cache.clear()
        clients = [:]; activeRoute = nil; snapshot = nil; reachable = false; isSnapshotCached = false
        lanFailed = false; routesCheckedAt = .distantPast
        tracker = AttentionTracker()
        pendingAlerts = []
        clearShared()
        Task { await liveActivity?.endAll() }
    }

    // MARK: Reading

    func poll() async {
        lanFailed = false
        let pollID = UUID()
        panePollID = pollID
        resumePanes()
        defer { if panePollID == pollID { suspendPanes() } }
        while !Task.isCancelled {
            await refresh()
            guard !Task.isCancelled else { return }
            await refreshPanes()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    /// One read of alerts and agents; overlapping callers share the read already in flight.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        guard !isUnpairing, let record else { return }
        let started = revision
        let task = Task { await read(record, revision: started) }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    private func read(_ record: PairingRecord, revision started: Int) async {
        guard revision == started else { return }
        let foregroundStarted = foregroundSession
        do {
            let next = try await readFeed(record: record, revision: started)
            guard revision == started else { return }
            cache.save(next, for: record)
            await apply(next)
        } catch {
            guard revision == started, !(error is CancellationError) else { return }
            reachable = false
            activeRoute = nil
            message = Self.readMessage(for: error, macName: record.macName)
            guard isStillForeground(since: foregroundStarted) else { return }
            if let snapshot {
                if snapshot.connected {
                    let offline = snapshot.offline()
                    writeShared(offline)
                    self.snapshot = offline
                }
                if liveActivityEnabled { await liveActivity?.sync(snapshot, connected: false) }
            }
        }
    }

    /// Page alerts from the saved cursor, then read the roster. A recovery
    /// status drops open alerts and queued notifications, and the cursor only advances once the roster
    /// read that recovery requires succeeds.
    private func readFeed(record: PairingRecord, revision started: Int) async throws -> GlanceSnapshot {
        func call(_ operation: String, limit: Int? = nil, cursor: String? = nil) async throws -> APIResponse {
            try await sessionCall(operation, record: record, revision: started, limit: limit, cursor: cursor,
                                  reportOffline: false)
        }
        if record.routes != nil, Date.now.timeIntervalSince(routesCheckedAt) > Self.routesCheckInterval {
            updateRoutes(try await call("get_connection_status").routes, record: record)
            routesCheckedAt = .now
        }
        var workspaceNames: [String: String] = [:]
        func roster() async throws -> GlanceSnapshot {
            let response = try await call("list_agents")
            guard let agents = response.agents else { throw MacClientFailure.invalidResponse }
            workspaceNames = Dictionary(agents.map { ($0.workspaceID, $0.workspaceName) }) { first, _ in first }
            return GlanceSnapshot(macName: record.macName, agents: agents, openAlerts: tracker.openAlerts,
                                  capturedAt: response.capturedAt ?? .now)
        }

        while true {
            guard let page = try await call("get_attention_events", limit: 100, cursor: tracker.cursor).attentionEvents,
                  AttentionTracker.knownStatuses.contains(page.cursorStatus), !page.nextCursor.isEmpty else {
                throw MacClientFailure.invalidResponse
            }
            if page.currentStateRecoveryRequired || AttentionTracker.recoveryStatuses.contains(page.cursorStatus) {
                tracker.openAlerts.removeAll()
                pendingAlerts.removeAll()
                let snapshot = try await roster()
                tracker.cursor = page.nextCursor
                tracker.readingInitialHistory = false
                return snapshot
            }
            var next = tracker
            try next.apply(page.events, cursorStatus: page.cursorStatus, pendingAlerts: &pendingAlerts)
            if page.hasMore && page.nextCursor == tracker.cursor { throw MacClientFailure.invalidResponse }
            next.cursor = page.nextCursor
            if !page.hasMore { next.readingInitialHistory = false }
            tracker = next
            if !page.hasMore { break }
        }
        let snapshot = try await roster()
        postPendingAlerts(workspaceNames: workspaceNames)
        return snapshot
    }

    private func apply(_ next: GlanceSnapshot) async {
        let previous = snapshot
        snapshot = next; reachable = true; message = nil; isSnapshotCached = false
        reconcilePaneFocus()
        if previous?.agents != next.agents || previous?.connected != next.connected || previous?.hostName != next.hostName
            || SharedSnapshot.read()?.connected != next.connected
            // Refresh well inside the widget's freshness window so a quiet, healthy Mac never ages out.
            || Date.now.timeIntervalSince(lastSharedWrite) > SharedSnapshot.freshFor / 3 {
            writeShared(next); lastSharedWrite = .now
        }
        if liveActivityEnabled { await liveActivity?.sync(next, connected: next.connected) }
    }

    // MARK: Foreground pane content

    func resumePanes() {
        if foregroundSession == nil { foregroundSession = UUID() }
        panes.lifecycle = .active
        if previewMutationTask != nil, let previewChoice, previewChoice.pairingRevision == revision {
            panes.permission = .updating(previewChoice.allowed)
        }
    }

    /// A failure confirms the Mac is offline only if the call began and ended in one active scene.
    private func isStillForeground(since started: UUID?) -> Bool {
        started != nil && foregroundSession == started
    }

    func suspendPanes() {
        foregroundSession = nil
        panePollID = nil
        invalidatePaneRead()
        panes.suspend()
    }

    private func invalidatePaneRead() {
        panes.invalidate()
        paneReadTask?.cancel()
        paneReadTask = nil
    }

    private func acceptsPaneRead(_ generation: Int, revision started: Int) -> Bool {
        panes.generation == generation && revision == started && panes.lifecycle == .active
            && !Task.isCancelled
    }

    /// Only active polling calls this; background refresh remains agent-only.
    func refreshPanes() async {
        guard panes.lifecycle == .active, !isUnpairing, let record else { return }
        guard previewMutationTask == nil else { return }
        if let paneReadTask { return await paneReadTask.value }
        let generation = panes.generation
        let started = revision
        let task = Task {
            do {
                // v1 pairings need permission readback too, independently of route discovery.
                let status = try await sessionCall("get_connection_status", record: record, revision: started, paneGeneration: generation)
                guard acceptsPaneRead(generation, revision: started) else { return }
                panes.terminalAccess = TerminalAccess(status)
                if panes.previewIntent == .keepOff, status.terminalPreviewAllowed == true {
                    panes.permission = .failed(String(localized: "Previews stay hidden on this iPhone. Turn them off on your Mac or confirm enabling them again."))
                } else {
                    panes.permission = PaneRoster.permission(status.terminalPreviewAllowed)
                }
                panes.clearPreviews()
                if panes.state == .idle { panes.state = .loading }
                let response = try await sessionCall("list_panes", record: record, revision: started, paneGeneration: generation)
                guard acceptsPaneRead(generation, revision: started) else { return }
                guard let workspaces = response.workspaces else {
                    panes.state = .unsupported
                    panes.permission = .unsupported
                    reconcilePaneFocus()
                    return
                }
                panes.state = .loaded(PaneRoster.project(workspaces, previews: panes.permission.allowsPreview))
                reconcilePaneFocus()
            } catch {
                guard acceptsPaneRead(generation, revision: started) else { return }
                panes.terminalAccess = TerminalAccess()
                if (error as? MacClientFailure) == .api("unsupported_operation") {
                    panes.state = .unsupported
                    panes.permission = .unsupported
                    reconcilePaneFocus()
                } else {
                    panes.state = .failed(String(localized: "Can't load sessions. Check your Mac and try again."))
                    panes.permission = .unknown
                }
            }
        }
        paneReadTask = task
        await task.value
        if panes.generation == generation { paneReadTask = nil }
    }

    func createTerminal(workspaceID: UUID?, canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> CreatedTerminal {
        guard let record, let pairing = decisionPairing else { throw CancellationError() }
        let started = revision
        let generation = panes.generation
        let permitted: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, self.revision == started, self.panes.generation == generation,
                  self.decisionPairing == pairing, self.panes.lifecycle == .active,
                  !self.showingPairing, self.pairingStep == .idle, canSend() else { return false }
            return workspaceID == nil ? self.panes.terminalAccess.createWorkspaceAllowed : self.panes.terminalAccess.createPaneAllowed
        }
        guard permitted(), let route = activeRoute ?? orderedRoutes(record).first else { throw CancellationError() }
        // Creation is a write: a dropped reply must never fall through to another route.
        let created = try await client(for: route, record: record).createTerminal(
            connectionID: record.connectionID, workspaceID: workspaceID, canSend: permitted)
        guard !Task.isCancelled, permitted() else { throw CancellationError() }
        return created
    }

    var focusedPaneDestination: FocusedPaneDestination? {
        guard let focusedPaneID else { return nil }
        if snapshot?.agents.contains(where: { $0.id == focusedPaneID }) == true {
            return FocusedPaneDestination(paneID: focusedPaneID, destination: .agents)
        }
        if panes.state.workspaces.contains(where: { $0.panes.contains(where: { $0.id == focusedPaneID }) }) {
            return FocusedPaneDestination(paneID: focusedPaneID, destination: .sessions)
        }
        return nil
    }

    private func reconcilePaneFocus() {
        switch panes.state {
        case .loaded, .unsupported: break
        default: return
        }
        guard !isSnapshotCached, let snapshot else { return }
        if let focusedPaneID, !snapshot.agents.contains(where: { $0.id == focusedPaneID }),
           !panes.state.workspaces.contains(where: { $0.panes.contains(where: { $0.id == focusedPaneID }) }) {
            self.focusedPaneID = nil
        }
    }

    func setTerminalPreview(_ allowed: Bool) async {
        guard panes.lifecycle == .active, !isUnpairing, let record,
              panes.permission.canChange || previewMutationTask != nil else { return }
        previewChoice = PreviewChoice(allowed: allowed, pairingRevision: revision)
        // Persist suppression before contacting the host, including an enable awaiting confirmation.
        defaults.set(try? JSONEncoder().encode(PreviewSuppression(record)), forKey: Keys.previewSuppression)
        panes.previewIntent = .keepOff
        invalidatePaneRead()
        permissionRevision += 1
        panes.clearPreviews()
        panes.permission = .updating(allowed)

        if let previewMutationTask { return await previewMutationTask.value }
        let owner = UUID()
        previewMutationID = owner
        let task = Task { await drainPreviewChoices(owner: owner) }
        previewMutationTask = task
        await task.value
    }

    private func drainPreviewChoices(owner: UUID) async {
        var confirmed = false
        while previewMutationID == owner, let choice = previewChoice,
              choice.pairingRevision == revision, let record {
            confirmed = await changeTerminalPreview(choice, record: record)
            if previewMutationID != owner { return }
            if previewChoice == choice {
                previewChoice = nil
                break
            }
        }
        guard previewMutationID == owner else { return }
        previewMutationID = nil
        previewMutationTask = nil
        if confirmed { await refreshPanes() }
    }

    private func changeTerminalPreview(_ choice: PreviewChoice, record: PairingRecord) async -> Bool {
        func isCurrent() -> Bool { revision == choice.pairingRevision && previewChoice == choice }
        func publish(_ permission: TerminalPreviewPermission) {
            if panes.lifecycle == .active { panes.permission = permission }
        }
        do {
            let receipt = try await sessionCall("set_terminal_preview", record: record, revision: choice.pairingRevision,
                                                previewAllowed: choice.allowed)
            guard isCurrent() else { return false }
            permissionRevision += 1
            invalidatePaneRead()
            guard receipt.terminalPreviewAllowed == choice.allowed else { throw MacClientFailure.invalidResponse }
            let status = try await sessionCall("get_connection_status", record: record, revision: choice.pairingRevision)
            guard isCurrent() else { return false }
            guard status.terminalPreviewAllowed == choice.allowed else { throw MacClientFailure.invalidResponse }
            // An explicit, confirmed enable is the only way to release this pairing's local suppression.
            if choice.allowed {
                defaults.removeObject(forKey: Keys.previewSuppression)
                panes.previewIntent = .followHost
            }
            publish(PaneRoster.permission(status.terminalPreviewAllowed))
            return true
        } catch {
            guard isCurrent() else { return false }
            panes.clearPreviews()
            if (error as? MacClientFailure) == .api("unsupported_operation") {
                publish(.unsupported)
            } else {
                publish(.failed(String(localized: "Couldn't confirm preview permission. Try again when your Mac is available.")))
            }
            return false
        }
    }

    private func sessionCall(_ operation: String, record: PairingRecord, revision started: Int,
                             limit: Int? = nil, cursor: String? = nil, previewAllowed: Bool? = nil, paneGeneration: Int? = nil,
                             canRead: (@MainActor @Sendable () -> Bool)? = nil, scopedDecision: Bool = false,
                             reportOffline: Bool = true) async throws -> APIResponse {
        let foregroundStarted = foregroundSession
        let permissionStarted = permissionRevision
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard revision == started, permissionRevision == permissionStarted, canRead?() ?? true,
                  paneGeneration.map({ acceptsPaneRead($0, revision: started) }) ?? true else { throw CancellationError() }
        }
        try checkCurrent()
        do {
            let (response, route) = try await firstAnswering(orderedRoutes(record)) { route in
                try checkCurrent()
                let client = try client(for: route, record: record)
                if let previewAllowed {
                    return try await client.setTerminalPreview(previewAllowed, connectionID: record.connectionID)
                }
                if let canRead {
                    return try await client.call(operation, connectionID: record.connectionID, limit: limit, cursor: cursor,
                        canSend: { [weak self] in
                            self?.revision == started && self?.permissionRevision == permissionStarted && canRead()
                        })
                }
                return try await client.call(operation, connectionID: record.connectionID, limit: limit, cursor: cursor)
            }
            try checkCurrent()
            if activeRoute != route {
                WatchDiagnostics.routing.notice("route_selected transport=\(route.transport.rawValue, privacy: .public)")
            }
            activeRoute = route
            if route.transport == .tailscale { lanFailed = true }
            return response
        } catch {
            try checkCurrent()
            if scopedDecision, (error as? MacClientFailure) == .api("permission_denied") {
                handleDecisionDenial()
            } else if error.isCompanionAuthorizationFailure {
                handleAuthorizationFailure(error, reportOffline: reportOffline && isStillForeground(since: foregroundStarted))
            }
            throw error
        }
    }

    private func handleDecisionDenial() {
        decisionAccessDenied = true
        decisionSessionID = UUID()
    }

    private func handleAuthorizationFailure(_ error: Error, reportOffline: Bool) {
        decisionAccessDenied = true
        decisionSessionID = UUID()
        permissionRevision += 1
        invalidatePaneRead()
        panes.state = .failed(Self.readMessage(for: error, macName: record?.macName ?? "Mac"))
        panes.permission = .unknown
        panes.terminalAccess = TerminalAccess()
        reachable = false
        activeRoute = nil
        message = Self.readMessage(for: error, macName: record?.macName ?? "Mac")
        if reportOffline, let snapshot, snapshot.connected {
            let offline = snapshot.offline()
            self.snapshot = offline
            writeShared(offline)
            if liveActivityEnabled { Task { await liveActivity?.sync(offline, connected: false) } }
        }
    }

    func decisionContext(_ identity: CompanionDecisionIdentity) -> DecisionContext {
        let workspaceID = identity.workspaceID.uuidString
        let paneID = identity.paneID.uuidString
        let workspace = panes.state.workspaces.first { $0.id.caseInsensitiveCompare(workspaceID) == .orderedSame }
        let pane = workspace?.panes.first { $0.id.caseInsensitiveCompare(paneID) == .orderedSame }
        return DecisionContext(workspace: workspace?.name, pane: pane?.title, identity: identity)
    }

    // MARK: Foreground decisions

    func readDecisions(session: UUID, canRead: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse {
        guard canRead(), decisionSession == session, let record else { throw CancellationError() }
        let started = revision
        let status = try await sessionCall(CompanionOperation.connectionStatus.rawValue,
                                           record: record, revision: started, canRead: canRead)
        guard canRead(), decisionSession == session else { throw CancellationError() }
        decisionAccessDenied = false
        guard status.remoteDecisionsEnabled == true else { return status }
        let response = try await sessionCall(CompanionOperation.pendingDecisions.rawValue,
                                             record: record, revision: started, canRead: canRead, scopedDecision: true)
        guard canRead(), decisionSession == session else { throw CancellationError() }
        return response
    }

    /// A write uses exactly one route. Lost replies require a fresh read and an
    /// explicit authenticated retry; firstAnswering must never replay this call.
    func submitDecision(_ answer: CompanionDecisionAnswer, session: UUID,
                        canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse {
        let foregroundStarted = foregroundSession
        guard decisionSession == session, let record, canSend(),
              let route = activeRoute ?? orderedRoutes(record).first else { throw CancellationError() }
        let client = try client(for: route, record: record)
        guard decisionSession == session, canSend() else { throw CancellationError() }
        do {
            let response = try await client.answerDecision(answer, connectionID: record.connectionID, canSend: { [weak self] in
                self?.decisionSession == session && canSend()
            })
            guard decisionSession == session else { throw CancellationError() }
            return response
        } catch {
            guard decisionSession == session else { throw CancellationError() }
            if (error as? MacClientFailure) == .api("permission_denied") {
                handleDecisionDenial()
            } else if error.isCompanionAuthorizationFailure {
                handleAuthorizationFailure(error, reportOffline: isStillForeground(since: foregroundStarted))
            }
            throw error
        }
    }

    // MARK: Routes

    private static let routesCheckInterval: TimeInterval = 60

    /// LAN first, unless a read has already fallen through to Tailscale on this network.
    private func orderedRoutes(_ record: PairingRecord) -> [CompanionRoute] {
        let routes = record.allRoutes
        guard lanFailed else { return routes }
        return routes.filter { $0.transport == .tailscale } + routes.filter { $0.transport != .tailscale }
    }

    /// Merges the Mac's current routes into the saved ones; a malformed report changes nothing. Updates the
    /// live record only while it is still the pairing that was read, so a reply that lands after an unpair or
    /// re-pair is dropped. Never applies to v1 pairings.
    private func updateRoutes(_ metadata: CompanionRoutes?, record read: PairingRecord) {
        guard let metadata, metadata.p == read.port, let reported = CompanionRoute.routes(metadata),
              var next = self.record, next.connectionID == read.connectionID, let saved = next.routes
        else { return }
        let routes = CompanionRoute.merged(reported, keeping: saved)
        guard routes != saved else { return }
        next.routes = routes
        // Publish only what was saved, so a failed write is retried by the next identical report.
        guard (try? PairingStore.system.save(next)) != nil else { return }
        self.record = next
    }

    private func client(for route: CompanionRoute, record: PairingRecord) throws -> any CompanionSessionClient {
        if let client = clients[route.host] { return client }
        let client = try makeClient(record, route)
        clients[route.host] = client
        return client
    }

    /// Tries each route in order until one answers. A route that can't connect, closes, or fails the pin falls
    /// through; anything the Mac answers (including an API error) ends the search. A pin failure is reported
    /// only when every route failed it, so a stale address held by another machine still reads as unreachable.
    private func firstAnswering<T: Sendable>(
        _ routes: [CompanionRoute], _ work: (CompanionRoute) async throws -> T
    ) async throws -> (T, CompanionRoute) {
        var failures: [MacClientFailure] = []
        for route in routes {
            do {
                return try (await work(route), route)
            } catch let failure as MacClientFailure where [.unreachable, .closed, .handshakeRejected].contains(failure) {
                try Task.checkCancellation()
                failures.append(failure)
            }
        }
        throw failures.first { $0 != .handshakeRejected } ?? failures.first ?? MacClientFailure.unreachable
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    private func postPendingAlerts(workspaceNames: [String: String]) {
        for event in pendingAlerts {
            let content = UNMutableNotificationContent()
            content.title = Self.alertTitle(provider: event.provider, reason: event.reason)
            content.body = workspaceNames[event.workspaceID] ?? ""
            content.sound = .default
            content.threadIdentifier = event.paneID
            content.userInfo = ["paneID": event.paneID, "attentionID": event.attentionID]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.attentionID, content: content, trigger: nil))
        }
        pendingAlerts.removeAll()
    }

    private static func alertTitle(provider: String, reason: String) -> String {
        switch reason {
        case "permissionPrompt": String(localized: "\(provider) needs permission")
        case "userInputRequired": String(localized: "\(provider) has a question")
        case "waitingForInput": String(localized: "\(provider) is waiting for you")
        case "processError", "agentError": String(localized: "\(provider) hit an error")
        default: String(localized: "\(provider) wants your attention")
        }
    }

    // MARK: Messages

    private static func pairingMessage(for error: Error) -> String {
        switch error {
        case MacClientFailure.denied:
            String(localized: "Your Mac didn't allow this iPhone. The pairing code may have expired; choose Pair iPhone on your Mac to try again.")
        case MacClientFailure.handshakeRejected:
            String(localized: "Your Mac didn't match the pairing code. Choose Pair iPhone on your Mac to make a new one.")
        case MacClientFailure.unreachable, MacClientFailure.closed:
            String(localized: "Can't reach your Mac. Make sure it's awake, awesoMux is open, and both devices are on the network in the code.")
        case is PhoneIdentity.Failure:
            String(localized: "This iPhone couldn't create its pairing key. Try again.")
        default:
            String(localized: "Pairing didn't finish. Choose Pair iPhone on your Mac to try again.")
        }
    }

    private static func readMessage(for error: Error, macName: String) -> String {
        switch error {
        case MacClientFailure.denied, MacClientFailure.handshakeRejected, MacClientFailure.api("permission_denied"),
             MacClientFailure.api("credential_unavailable"), MacClientFailure.api("access_disabled"),
             is PhoneIdentity.Failure:
            String(localized: "\(macName) couldn't authorize this read. Try again, or pair again in Settings if it continues.")
        case MacClientFailure.invalidResponse, MacClientFailure.oversizedFrame:
            String(localized: "\(macName) sent an update this app can't read.")
        case MacClientFailure.api(let code):
            String(localized: "awesoMux isn't answering on \(macName) (\(code)).")
        default:
            String(localized: "Can't reach \(macName). Make sure it's awake and awesoMux is open.")
        }
    }
}

/// Alert cursor state, kept across launches so a background refresh can tell new alerts from history.
struct AttentionTracker: Codable {
    static let recoveryStatuses: Set<String> = ["history_gap", "app_restarted", "access_changed"]
    static let knownStatuses = recoveryStatuses.union(["initial", "current"])
    private static let key = "attentionTracker"

    var cursor: String?
    var openAlerts: [String: APIResponse.Event] = [:]
    var readingInitialHistory = true

    static func load(defaults: UserDefaults = .standard) -> AttentionTracker {
        defaults.data(forKey: key).flatMap { try? CompanionProtocol.decoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try? encoder.encode(self), forKey: Self.key)
    }

    mutating func apply(_ events: [APIResponse.Event], cursorStatus: String,
                        pendingAlerts: inout [APIResponse.Event]) throws {
        for event in events {
            switch event.change {
            case "raised":
                openAlerts[event.attentionID] = event
                if cursorStatus != "initial" && !readingInitialHistory { pendingAlerts.append(event) }
            case "resolved":
                openAlerts.removeValue(forKey: event.attentionID)
                pendingAlerts.removeAll { $0.attentionID == event.attentionID }
            default:
                throw MacClientFailure.invalidResponse
            }
        }
    }
}

extension GlanceSnapshot {
    /// Unavailable agents are hidden; needs-you agents sort oldest first, otherwise roster order holds.
    init(macName: String, agents roster: [APIResponse.Agent], openAlerts: [String: APIResponse.Event], capturedAt: Date) {
        var alertsByPane: [String: APIResponse.Event] = [:]
        for alert in openAlerts.values where alertsByPane[alert.paneID].map({ alert.occurredAt < $0.occurredAt }) ?? true {
            alertsByPane[alert.paneID] = alert
        }
        let agents = roster.filter { $0.availability != "unavailable" }.map { source in
            let alert = alertsByPane[source.paneID]
            let group: GlanceGroup = if alert != nil || source.attentionReason != nil
                || ["waiting", "needsAttention", "error"].contains(source.state) { .needsYou }
                else if ["running", "thinking", "output"].contains(source.state) { .working }
                else { .done }
            return GlanceAgent(id: source.paneID, workspaceName: source.workspaceName,
                               provider: source.provider, group: group, state: source.state,
                               reason: alert?.reason ?? source.attentionReason, since: alert?.occurredAt ?? source.observedAt)
        }
        let order: [GlanceGroup: Int] = [.needsYou: 0, .working: 1, .done: 2]
        let sorted = agents.enumerated().sorted { lhs, rhs in
            let l = lhs.element, r = rhs.element
            if l.group != r.group { return order[l.group]! < order[r.group]! }
            if l.group == .needsYou, l.since != r.since { return (l.since ?? .distantFuture) < (r.since ?? .distantFuture) }
            return lhs.offset < rhs.offset
        }.map(\.element)
        self.init(schemaVersion: 1, hostName: macName, connected: true, error: nil, updatedAt: capturedAt, agents: sorted)
    }
}
