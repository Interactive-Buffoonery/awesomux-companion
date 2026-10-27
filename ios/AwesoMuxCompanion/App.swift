import os
import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct GlanceApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        let text = Cat.uiColor(mocha: "#cdd6f4", latte: "#4c4f69", mochaHC: "#ffffff", latteHC: "#0a0a14")
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: text]
    }

    var body: some Scene {
        WindowGroup {
            #if SNAPSHOT_DIAGNOSTICS
            SnapshotDiagnosticsView()
            #else
            ProtectedCompanionRoot(hosts: appDelegate.hosts)
            #endif
        }
    }
}

/// WindowGroup creates one root and one authentication session per scene.
private struct ProtectedCompanionRoot: View {
    @Bindable var hosts: Hosts
    @Environment(\.scenePhase) private var scenePhase
    @State private var terminalLock: TerminalLockModel
    @State private var decisions: PendingDecisionsModel

    /// Restarts polling when the scene, the open Mac, or the list of Macs changes.
    private struct PollScope: Equatable {
        let active: Bool
        let selected: ObjectIdentifier?
        let stores: [ObjectIdentifier]
    }

    init(hosts: Hosts) {
        self.hosts = hosts
        let lock = TerminalLockModel()
        _terminalLock = State(initialValue: lock)
        // Decisions belong to the open Mac; another Mac's grant or session never answers them.
        _decisions = State(initialValue: PendingDecisionsModel(
            session: { [weak hosts] in hosts?.selected?.decisionSession },
            pairing: { [weak hosts] in hosts?.selected?.decisionPairing },
            isUnlocked: { [weak hosts] in
                lock.isActive && !lock.isLocked && hosts != nil && hosts?.pairing == nil
            },
            isLocked: { lock.isLocked },
            read: { [weak hosts] session, canRead in
                guard let store = hosts?.selected else { throw CancellationError() }
                return try await store.readDecisions(session: session, canRead: canRead)
            },
            submit: { [weak hosts] answer, session, canSend in
                guard let store = hosts?.selected else { throw CancellationError() }
                return try await store.submitDecision(answer, session: session, canSend: canSend)
            }))
    }

    private var canReadDecisions: Bool {
        scenePhase == .active && terminalLock.isActive && !terminalLock.isLocked
            && hosts.selected?.decisionSession != nil && hosts.pairing == nil
    }

    private var pollScope: PollScope {
        PollScope(active: scenePhase == .active, selected: hosts.selected.map(ObjectIdentifier.init),
                  stores: hosts.stores.map(ObjectIdentifier.init))
    }

    var body: some View {
        TerminalLockContainer(model: terminalLock, protectsContent: !hosts.stores.isEmpty && hosts.pairing == nil) {
            if let pairing = hosts.pairing {
                PairingView(store: pairing, canCancel: !hosts.stores.isEmpty,
                            reminders: hosts.stores.isEmpty ? hosts.reminderMessages : [])
            } else {
                NavigationStack(path: $hosts.path) {
                    HostsView(hosts: hosts)
                        .navigationDestination(for: String.self) { fingerprint in
                            if let store = hosts.store(for: fingerprint) {
                                SessionsView(store: store).id(fingerprint)
                            }
                        }
                }
            }
        }
        .environment(decisions)
        .tint(Cat.accent)
        .onOpenURL { url in
            hosts.openPairingLink(url.absoluteString)
        }
        .onChange(of: scenePhase) {
            WatchDiagnostics.lifecycle.notice("scene_changed origin=lifecycle source=app active=\(scenePhase == .active) background=\(scenePhase == .background)")
            if scenePhase != .active { hosts.suspend() }
            decisions.sceneChanged(active: scenePhase == .active,
                backgrounded: scenePhase == .background || hosts.pairing != nil)
        }
        .onChange(of: canReadDecisions, initial: true) {
            decisions.sceneChanged(active: scenePhase == .active,
                backgrounded: scenePhase == .background || hosts.pairing != nil)
        }
        .onChange(of: hosts.selected?.decisionSession) {
            decisions.connectionChanged(denied: hosts.selected?.decisionAccessDenied ?? false)
        }
        .task(id: canReadDecisions) {
            if canReadDecisions { await decisions.poll() }
        }
        .task(id: pollScope) {
            if pollScope.active { await hosts.poll() }
        }
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .background { AppDelegate.scheduleRefresh() }
        }
    }
}

/// Owns the hosts so a background refresh can update them even when iOS launches the app in the background.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskID = "com.interactivebuffoonery.awesomux.companion.refresh"
    let hosts = Hosts()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if SNAPSHOT_DIAGNOSTICS
        return true
        #else
        UNUserNotificationCenter.current().delegate = self
        let hosts = hosts
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: .main) { task in
            Self.scheduleRefresh()
            let work = Task { @MainActor in
                task.setTaskCompleted(success: await hosts.refreshAll())
            }
            task.expirationHandler = { work.cancel() }
        }
        return true
        #endif
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = .now + 15 * 60
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let paneID = info["paneID"] as? String
        let macFingerprint = info["macFingerprint"] as? String
        await MainActor.run { hosts.openNotification(paneID: paneID, macFingerprint: macFingerprint) }
    }
}
