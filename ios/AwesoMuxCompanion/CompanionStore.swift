import Foundation
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

@MainActor @Observable
final class CompanionStore {
    private(set) var record: PairingRecord?
    private(set) var snapshot: GlanceSnapshot?
    /// Whether the latest read reached the Mac.
    private(set) var reachable = false
    private(set) var message: String?
    private(set) var pairingStep: PairingStep = .idle
    /// Pair Again from Settings; the welcome screen also shows whenever no Mac is paired.
    var showingPairing = false
    /// Pane named by a tapped notification; the list scrolls to and highlights it.
    var focusedPaneID: String?
    var isConnected: Bool { reachable && snapshot?.connected == true }
    var liveActivityEnabled: Bool = UserDefaults.standard.object(forKey: Keys.liveActivity) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled, forKey: Keys.liveActivity)
            if !liveActivityEnabled { Task { await liveActivity.endAll() } }
        }
    }

    @ObservationIgnored private var client: MacClient?
    /// Bumped whenever the pairing changes so reads that straddle the change are dropped.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var lastSharedWrite = Date.distantPast
    @ObservationIgnored private var tracker = AttentionTracker.load() { didSet { tracker.save() } }
    /// Alerts raised since the last roster read; posted once workspace names are known.
    @ObservationIgnored private var pendingAlerts: [APIResponse.Event] = []
    @ObservationIgnored private let liveActivity = LiveActivityController()

    private enum Keys { static let liveActivity = "liveActivityEnabled" }

    init() {
        do {
            record = try PairingStore.load()
        } catch {
            message = String(localized: "This iPhone's pairing couldn't be read. Pair again to continue.")
        }
    }

    // MARK: Pairing

    func startPairing(_ link: PairingLink) {
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
            let client = MacClient(host: link.host, port: link.port, macFingerprint: link.macFingerprint, identity: created)
            let session = try await client.beginPairing(secret: link.secret, phoneName: String(UIDevice.current.name.prefix(80)))
            try Task.checkCancellation()
            pairingStep = .confirm(words: session.words, macName: link.macName, transport: link.transport)
            let reply = try await withTaskCancellationHandler { try await session.outcome() } onCancel: { session.cancel() }
            try Task.checkCancellation()
            guard let connectionID = reply.connectionID else { throw MacClientFailure.denied }
            let next = PairingRecord(
                macName: reply.macName ?? link.macName, host: link.host, port: link.port,
                macFingerprint: link.macFingerprint, transport: link.transport, connectionID: connectionID,
                identityTag: created.tag, identityStorage: created.storage, pairedAt: .now)
            try PairingStore.save(next)
            let previous = record
            forgetConnection()
            if let previous, previous.identityTag != next.identityTag { PhoneIdentity.delete(tag: previous.identityTag) }
            record = next
            message = nil
            pairingStep = .idle
            showingPairing = false
            requestNotificationPermission()
            await refresh()
        } catch {
            if let identity { PhoneIdentity.delete(tag: identity.tag) }
            guard !Task.isCancelled else { return }
            pairingStep = .failed(Self.pairingMessage(for: error))
        }
    }

    func unpair() {
        // ponytail: the wire has no unpair operation; the Mac drops this phone when its user unpairs there.
        if let record { PhoneIdentity.delete(tag: record.identityTag) }
        try? PairingStore.clear()
        forgetConnection()
        record = nil
        message = nil
    }

    private func forgetConnection() {
        revision += 1
        refreshTask?.cancel(); refreshTask = nil
        client = nil; snapshot = nil; reachable = false
        tracker = AttentionTracker()
        pendingAlerts = []
        SharedSnapshot.clear()
        WidgetCenter.shared.reloadAllTimelines()
        Task { await liveActivity.endAll() }
    }

    // MARK: Reading

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    /// One read of alerts and agents; overlapping callers share the read already in flight.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        guard let record else { return }
        let task = Task { await read(record) }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    private func read(_ record: PairingRecord) async {
        let started = revision
        do {
            let client = try self.client ?? MacClient(
                host: record.host, port: record.port, macFingerprint: record.macFingerprint,
                identity: PhoneIdentity.load(tag: record.identityTag, storage: record.identityStorage))
            self.client = client
            let next = try await readFeed(client, record: record, revision: started)
            guard revision == started else { return }
            await apply(next)
        } catch {
            guard revision == started, !(error is CancellationError) else { return }
            reachable = false
            message = Self.readMessage(for: error, macName: record.macName)
            if let snapshot {
                if snapshot.connected {
                    let offline = snapshot.offline()
                    SharedSnapshot.write(offline); WidgetCenter.shared.reloadAllTimelines()
                    self.snapshot = offline
                }
                if liveActivityEnabled { await liveActivity.sync(snapshot, connected: false) }
            }
        }
    }

    /// Page alerts from the saved cursor, then read the roster. A recovery
    /// status drops open alerts and queued notifications, and the cursor only advances once the roster
    /// read that recovery requires succeeds.
    private func readFeed(_ client: MacClient, record: PairingRecord, revision started: Int) async throws -> GlanceSnapshot {
        func call(_ operation: String, limit: Int? = nil, cursor: String? = nil) async throws -> APIResponse {
            let response = try await client.call(operation, connectionID: record.connectionID,
                                                 limit: limit, cursor: cursor)
            guard revision == started else { throw CancellationError() }
            return response
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
            for event in page.events {
                switch event.change {
                case "raised":
                    next.openAlerts[event.attentionID] = event
                    if page.cursorStatus != "initial" && !next.readingInitialHistory { pendingAlerts.append(event) }
                case "resolved":
                    next.openAlerts.removeValue(forKey: event.attentionID)
                default:
                    throw MacClientFailure.invalidResponse
                }
            }
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
        snapshot = next; reachable = true; message = nil
        if previous?.agents != next.agents || previous?.connected != next.connected || previous?.hostName != next.hostName
            || SharedSnapshot.read()?.connected != next.connected
            // Refresh well inside the widget's freshness window so a quiet, healthy Mac never ages out.
            || Date.now.timeIntervalSince(lastSharedWrite) > SharedSnapshot.freshFor / 3 {
            SharedSnapshot.write(next); lastSharedWrite = .now
            WidgetCenter.shared.reloadAllTimelines()
        }
        if liveActivityEnabled { await liveActivity.sync(next, connected: next.connected) }
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
        case MacClientFailure.invalidResponse, MacClientFailure.oversizedResponse:
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

    static func load() -> AttentionTracker {
        UserDefaults.standard.data(forKey: key).flatMap { try? APIResponse.decoder.decode(Self.self, from: $0) } ?? Self()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(try? encoder.encode(self), forKey: Self.key)
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
