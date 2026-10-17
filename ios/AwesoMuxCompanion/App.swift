import SwiftUI
import UserNotifications

@main
struct GlanceApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            AgentsView(store: appDelegate.store)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    appDelegate.store.activate()
                    await appDelegate.store.poll()
                }
        }
    }
}

/// Owns the store so a push can refresh it even when iOS launches the app in the background.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = CompanionStore()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // ponytail: phase 1 delivers with `simctl push`, which needs no device token; phase 2 uploads it for APNs.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await store.refresh()
        return store.reachable ? .newData : .failed
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let paneID = response.notification.request.content.userInfo["paneID"] as? String
        await MainActor.run { store.focusedPaneID = paneID }
    }
}
