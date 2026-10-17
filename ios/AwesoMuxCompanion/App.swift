import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct GlanceApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let text = Cat.uiColor(mocha: "#cdd6f4", latte: "#4c4f69", mochaHC: "#ffffff", latteHC: "#0a0a14")
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: text]
    }

    var body: some Scene {
        WindowGroup {
            let store = appDelegate.store
            Group {
                if store.record == nil || store.showingPairing || store.pairingStep != .idle {
                    PairingView(store: store)
                } else {
                    AgentsView(store: store)
                }
            }
            .tint(Cat.accent)
            .onOpenURL { url in
                store.openPairingLink(url.absoluteString, review: true)
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
}

/// Owns the store so a background refresh can update it even when iOS launches the app in the background.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskID = "com.interactivebuffoonery.awesomux.companion.refresh"
    let store = CompanionStore()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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
