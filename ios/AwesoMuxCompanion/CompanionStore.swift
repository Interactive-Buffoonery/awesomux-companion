import Foundation
import Observation
import UserNotifications
import WidgetKit

enum HostConnectionState: Equatable { case unconfigured, configured, quarantined(String?), loadFailed }

@MainActor @Observable
final class CompanionStore {
    private(set) var connectionState: HostConnectionState = .unconfigured
    private(set) var activeHostLabel: String?
    private(set) var snapshot: GlanceSnapshot?
    /// Whether the latest request reached the relay; `snapshot.connected` separately reports relay-to-awesoMux health.
    private(set) var reachable = false
    private(set) var message: String?
    /// Pane named by a tapped notification; the list scrolls to and highlights it.
    var focusedPaneID: String?
    var canPair: Bool { connectionState != .loadFailed }
    var isConnected: Bool { reachable && snapshot?.connected == true }

    @ObservationIgnored private var api: BridgeClient?
    @ObservationIgnored private var configuration: ConnectionConfiguration?
    @ObservationIgnored private var connectionRevision = 0
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var appliedSequence = 0
    @ObservationIgnored private var explicitlyDisconnected = false
    @ObservationIgnored private var requestedNotifications = false
    @ObservationIgnored private var lastSharedWrite = Date.distantPast
    @ObservationIgnored private let credentials: any HostCredentialStorage
    @ObservationIgnored private let liveActivity = LiveActivityController()
    #if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored private var developmentConfiguration: DevelopmentConfiguration?
    #endif

    init() {
        #if DEBUG && targetEnvironment(simulator)
        credentials = InMemoryHostCredentialStore()
        #else
        credentials = HostCredentialStore()
        #endif
    }

    private func invalidateConnection() {
        connectionRevision += 1
        api = nil; snapshot = nil; reachable = false
        #if DEBUG && targetEnvironment(simulator)
        developmentConfiguration = nil
        #endif
    }

    private func loadConnection() throws {
        let next = try credentials.load()
        if let next {
            _ = try next.validatedURL()
            if configuration != next || api == nil {
                invalidateConnection()
                api = try BridgeClient(configuration: next)
            }
            configuration = next; activeHostLabel = next.hostLabel; connectionState = .configured
            message = nil
        } else {
            #if DEBUG && targetEnvironment(simulator)
            if let development = try DevelopmentConfiguration.load() {
                if developmentConfiguration != development || api == nil || configuration != nil {
                    invalidateConnection(); api = try BridgeClient(configuration: development)
                }
                developmentConfiguration = development; configuration = nil
                activeHostLabel = String(localized: "Local Mac"); connectionState = .unconfigured; message = nil
                return
            }
            #endif
            invalidateConnection(); configuration = nil; activeHostLabel = nil; connectionState = .unconfigured
            message = nil
        }
    }

    /// Re-reads saved credentials; safe to call on every foreground and push since an unchanged host keeps its client.
    func activate() {
        guard !explicitlyDisconnected else { return }
        switch connectionState {
        case .quarantined, .loadFailed: return
        default: break
        }
        do { try loadConnection() }
        catch {
            invalidateConnection(); connectionState = .loadFailed; activeHostLabel = nil
            message = String(localized: "Saved host unavailable. Retry or disconnect to continue.")
        }
    }

    func pair(_ next: ConnectionConfiguration) throws {
        guard canPair else { throw BridgeFailure.invalidConfiguration }
        _ = try next.validatedURL()
        let priorHost = activeHostLabel
        invalidateConnection(); connectionState = .quarantined(priorHost)
        clearSharedState()
        do {
            let candidate = try BridgeClient(configuration: next)
            try credentials.save(next)
            api = candidate; configuration = next; activeHostLabel = next.hostLabel
            connectionState = .configured; explicitlyDisconnected = false
            message = String(localized: "Connecting to host…")
        } catch {
            message = String(localized: "Connection could not be saved. The previous host remains unavailable until you retry.")
            throw error
        }
    }

    func disconnectHost() throws {
        let wasLoadFailed = connectionState == .loadFailed
        let priorHost = activeHostLabel
        invalidateConnection(); connectionState = .quarantined(priorHost)
        clearSharedState()
        do {
            try credentials.clear(); configuration = nil; activeHostLabel = nil
            connectionState = .unconfigured; explicitlyDisconnected = true; message = nil
        } catch {
            if wasLoadFailed { connectionState = .loadFailed; activeHostLabel = nil }
            message = String(localized: "Saved connection could not be removed. Retry or disconnect again.")
            throw error
        }
    }

    func retryConnection() throws {
        explicitlyDisconnected = false
        invalidateConnection()
        do { try loadConnection() }
        catch {
            connectionState = .loadFailed; activeHostLabel = nil
            message = String(localized: "Saved host unavailable. Retry or disconnect to continue.")
            throw error
        }
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func refresh() async {
        if api == nil { activate() }
        guard let api else { return }
        let requestRevision = connectionRevision
        sequence += 1; let requestSequence = sequence
        do {
            let next = try await api.fetch()
            guard connectionRevision == requestRevision, requestSequence > appliedSequence else { return }
            appliedSequence = requestSequence
            await apply(next)
        } catch {
            guard connectionRevision == requestRevision, requestSequence > appliedSequence,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            appliedSequence = requestSequence
            reachable = false
            message = switch error {
            case BridgeFailure.credentialsRejected: String(localized: "Your Mac rejected the connection key.")
            case BridgeFailure.invalidResponse: String(localized: "Your Mac sent an update this app can't read.")
            default: String(localized: "Can't reach your Mac.")
            }
            if let snapshot {
                if snapshot.connected {
                    let offline = snapshot.offline()
                    SharedSnapshot.write(offline); WidgetCenter.shared.reloadAllTimelines()
                    self.snapshot = offline
                }
                await liveActivity.sync(snapshot, connected: false)
            }
        }
    }

    private func apply(_ next: GlanceSnapshot) async {
        let previous = snapshot
        snapshot = next; reachable = true
        message = next.connected ? nil : String(localized: "awesoMux isn't answering on your Mac (\(next.error ?? "helper_failed")).")
        if previous?.agents != next.agents || previous?.connected != next.connected || previous?.hostName != next.hostName
            || SharedSnapshot.read()?.connected != next.connected
            // Refresh well inside the widget's freshness window so a quiet, healthy host never ages out.
            || Date.now.timeIntervalSince(lastSharedWrite) > SharedSnapshot.freshFor / 3 {
            SharedSnapshot.write(next); lastSharedWrite = .now
            WidgetCenter.shared.reloadAllTimelines()
        }
        await liveActivity.sync(next, connected: next.connected)
        if !requestedNotifications {
            requestedNotifications = true
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        }
    }

    private func clearSharedState() {
        SharedSnapshot.clear()
        WidgetCenter.shared.reloadAllTimelines()
        Task { await liveActivity.endAll() }
    }
}
