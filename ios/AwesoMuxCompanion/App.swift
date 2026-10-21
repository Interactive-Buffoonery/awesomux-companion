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
            ProtectedCompanionRoot(store: appDelegate.store)
            #endif
        }
    }
}

/// WindowGroup creates one root and one authentication session per scene.
private struct ProtectedCompanionRoot: View {
    let store: CompanionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var terminalLock: TerminalLockModel
    @State private var decisions: PendingDecisionsModel

    init(store: CompanionStore) {
        self.store = store
        let lock = TerminalLockModel()
        _terminalLock = State(initialValue: lock)
        _decisions = State(initialValue: PendingDecisionsModel(
            session: { [weak store] in store?.decisionSession },
            isUnlocked: { [weak store] in
                lock.isActive && !lock.isLocked && store?.showingPairing == false && store?.pairingStep == .idle
            },
            isLocked: { lock.isLocked },
            read: { [weak store] session in
                guard let store else { throw CancellationError() }
                return try await store.readDecisions(session: session)
            },
            submit: { [weak store] answer, session, canSend in
                guard let store else { throw CancellationError() }
                return try await store.submitDecision(answer, session: session, canSend: canSend)
            }))
    }

    private var canReadDecisions: Bool {
        scenePhase == .active && terminalLock.isActive && !terminalLock.isLocked
            && store.decisionSession != nil && !store.showingPairing && store.pairingStep == .idle
    }

    var body: some View {
        TerminalLockContainer(
            model: terminalLock,
            protectsContent: store.record != nil && !store.showingPairing && store.pairingStep == .idle
        ) {
            if store.record == nil || store.showingPairing || store.pairingStep != .idle {
                PairingView(store: store)
            } else {
                CompanionTabs(store: store)
            }
        }
        .environment(decisions)
        .tint(Cat.accent)
        .onOpenURL { url in
            store.openPairingLink(url.absoluteString, review: true)
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { store.suspendPanes() }
            decisions.sceneChanged(active: scenePhase == .active,
                backgrounded: scenePhase == .background || store.showingPairing || store.pairingStep != .idle)
        }
        .onChange(of: canReadDecisions, initial: true) {
            decisions.sceneChanged(active: scenePhase == .active,
                backgrounded: scenePhase == .background || store.showingPairing || store.pairingStep != .idle)
        }
        .onChange(of: store.decisionSession) {
            decisions.connectionChanged(denied: store.decisionAccessDenied)
        }
        .task(id: canReadDecisions) {
            if canReadDecisions { await decisions.poll() }
        }
        .task(id: scenePhase) {
            switch scenePhase {
            case .active: await store.poll()
            case .background: AppDelegate.scheduleRefresh()
            default: break
            }
        }
    }
}

/// Owns the store so a background refresh can update it even when iOS launches the app in the background.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskID = "com.interactivebuffoonery.awesomux.companion.refresh"
    let store = CompanionStore()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if SNAPSHOT_DIAGNOSTICS
        return true
        #else
        UNUserNotificationCenter.current().delegate = self
        let store = store
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: .main) { task in
            Self.scheduleRefresh()
            let work = Task { @MainActor in
                await store.refresh()
                task.setTaskCompleted(success: store.reachable)
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
        let paneID = response.notification.request.content.userInfo["paneID"] as? String
        await MainActor.run { store.focusedPaneID = paneID }
    }
}
