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
    func unpair(connectionID: UUID) async throws
}

extension MacClient: CompanionSessionClient {}

@MainActor @Observable
final class CompanionStore {
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

    private enum Keys {
        static let liveActivity = "liveActivityEnabled"
        static let unpairMessage = "unpairMessage"
        static let revokedConnectionID = "revokedConnectionID"
    }

    init(
        defaults: UserDefaults = .standard,
        loadPairing: () throws -> PairingRecord? = { try PairingStore.load() },
        makeClient: @escaping (PairingRecord, CompanionRoute) throws -> any CompanionSessionClient = { record, route in
            try MacClient(host: route.host, port: record.port, macFingerprint: record.macFingerprint,
                          identity: PhoneIdentity.load(tag: record.identityTag, storage: record.identityStorage))
        },
        removePairing: @escaping (PairingRecord) throws -> Void = { record in
            try PhoneIdentity.delete(tag: record.identityTag)
            try PairingStore.clear()
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
            snapshot = cache.restore(for: record)
            isSnapshotCached = snapshot != nil
        } catch {
            message = String(localized: "This iPhone's pairing couldn't be read. Pair again to continue.")
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
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
            let next = PairingRecord(
                macName: reply.macName ?? link.macName, host: v1?.host, port: link.port,
                macFingerprint: link.macFingerprint, transport: v1?.transport, routes: v1 == nil ? link.routes : nil,
                connectionID: connectionID, identityTag: created.tag, identityStorage: created.storage, pairedAt: .now)
            try PairingStore.save(next)
            let previous = record
            forgetConnection()
            if let previous, previous.identityTag != next.identityTag { revoke(previous) }
            record = next
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
            message = nil
        } catch {
            message = String(localized: "This iPhone couldn’t finish unpairing. Choose Unpair This iPhone to try again.")
        }
    }

    /// Best effort, after a new pairing replaces `previous`: if the old Mac can't be reached, its grant stays
    /// until the person unpairs there, the same as an unacknowledged unpair.
    // This attempt is not persisted; quitting before it finishes can leave the old key in Keychain.
    private func revoke(_ previous: PairingRecord) {
        Task {
            if let identity = try? PhoneIdentity.load(tag: previous.identityTag, storage: previous.identityStorage) {
                _ = try? await firstAnswering(previous.allRoutes) { route in
                    try await MacClient(host: route.host, port: previous.port, macFingerprint: previous.macFingerprint,
                                        identity: identity).unpair(connectionID: previous.connectionID)
                }
            }
            try? PhoneIdentity.delete(tag: previous.identityTag)
        }
    }

    private func forgetConnection() {
        revision += 1
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
        while !Task.isCancelled {
            await refresh()
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
            let (response, route) = try await firstAnswering(orderedRoutes(record)) { route in
                try await client(for: route, record: record)
                    .call(operation, connectionID: record.connectionID, limit: limit, cursor: cursor)
            }
            guard revision == started else { throw CancellationError() }
            activeRoute = route
            if route.transport == .tailscale { lanFailed = true }
            return response
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
        if previous?.agents != next.agents || previous?.connected != next.connected || previous?.hostName != next.hostName
            || SharedSnapshot.read()?.connected != next.connected
            // Refresh well inside the widget's freshness window so a quiet, healthy Mac never ages out.
            || Date.now.timeIntervalSince(lastSharedWrite) > SharedSnapshot.freshFor / 3 {
            writeShared(next); lastSharedWrite = .now
        }
        if liveActivityEnabled { await liveActivity?.sync(next, connected: next.connected) }
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
        guard (try? PairingStore.save(next)) != nil else { return }
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
        case MacClientFailure.handshakeRejected, MacClientFailure.api("permission_denied"),
             MacClientFailure.api("credential_unavailable"), MacClientFailure.api("access_disabled"),
             is PhoneIdentity.Failure:
            String(localized: "\(macName) no longer recognizes this iPhone. Pair again in Settings.")
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
