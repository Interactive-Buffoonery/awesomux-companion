import SwiftUI
import UIKit
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class PaneRosterRenderingTests: XCTestCase {
    func testActualSessionsListWithConsentChangesAndLock() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let suite = "PaneRosterRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: TerminalLockModel.preferenceKey)
        let lock = TerminalLockModel(defaults: defaults, authenticator: PaneRenderingAuthenticator())
        lock.becomeActive()
        let client = PaneClientFixture()
        client.allowed = false
        let store = CompanionStore(defaults: defaults, loadPairing: { panePairing() },
                                   makeClient: { _, _ in client }, removePairing: { _ in }, liveActivity: nil,
                                   writeShared: { _ in }, clearShared: {})
        store.resumePanes()
        defer { store.suspendPanes() }
        await store.refresh()
        await store.refreshPanes()
        let appeared = expectation(description: "SwiftUI Sessions appeared")
        let host = PaneHostingController(rootView: TerminalLockContainer(model: lock, protectsContent: true) {
            SessionsView(store: store)
                .environment(PendingDecisionsModel(session: { nil }, isUnlocked: { true },
                                                   read: { _, _ in throw CancellationError() },
                                                   submit: { _, _, _ in throw CancellationError() }))
        })
        host.appeared = { appeared.fulfill() }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await fulfillment(of: [appeared], timeout: 5)
        XCTAssertEqual(store.panes.permission, .disabled)
        attach(window, name: "p9-sessions-previews-off")
        await store.setTerminalPreview(true)
        XCTAssertEqual(store.panes.permission, .enabled)
        XCTAssertEqual(store.panes.state.workspaces.first?.panes.first?.preview, "Build complete")
        attach(window, name: "p9-sessions-previews-on")
        await store.setTerminalPreview(false)
        XCTAssertEqual(store.panes.permission, .disabled)
        XCTAssertTrue(store.panes.state.workspaces.flatMap(\.panes).allSatisfy { $0.preview == nil })
        attach(window, name: "p9-sessions-after-opt-out")
        await lock.setEnabled(true)
        XCTAssertTrue(lock.isLocked)
        let anchor = ScenePrivacyAnchor(model: lock, protectsContent: true)
        window.addSubview(anchor)
        defer { anchor.detach() }
        let cover = try XCTUnwrap(anchor.privacyWindow)
        XCTAssertFalse(window.isUserInteractionEnabled)
        XCTAssertTrue(window.accessibilityElementsHidden)
        attach(cover, name: "p9-sessions-locked")
    }

    private func attach(_ window: UIWindow, name: String) {
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class PaneHostingController<Content: View>: UIHostingController<Content> {
    var appeared: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared?()
        appeared = nil
    }
}

@MainActor
private final class PaneRenderingAuthenticator: TerminalAuthenticating {
    func authenticate() async -> Bool { false }
    func cancel() {}
}
