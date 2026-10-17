import SwiftUI

@main
struct AwesoMuxCompanionApp: App {
    @State private var store = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            InboxView(store: store)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { store.deactivate(); return }
                    store.activate()
                    await store.poll()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { store.deactivate() }
                }
        }
    }
}
