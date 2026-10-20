import SwiftUI
import UIKit
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class TerminalLockRenderingTests: XCTestCase {
    func testLockedGateAndSynchronousScenePrivacyCover() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: { $0.isKeyWindow })
        let suite = "TerminalLockRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: TerminalLockModel.preferenceKey)
        let model = TerminalLockModel(defaults: defaults, authenticator: RenderingAuthenticator())
        model.becomeActive()
        let host = UIHostingController(rootView: Text("Sensitive agent content"))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        let anchor = ScenePrivacyAnchor(model: model, protectsContent: true)
        window.addSubview(anchor)
        defer {
            anchor.detach()
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            previousKeyWindow?.makeKey()
        }
        let sheet = UIViewController()
        sheet.view.backgroundColor = .systemRed
        let field = UITextField(frame: CGRect(x: 24, y: 48, width: 240, height: 44))
        field.text = "Sensitive terminal input"
        sheet.view.addSubview(field)
        await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
            host.present(sheet, animated: false) { completion.resume() }
        }
        XCTAssertTrue(field.becomeFirstResponder())
        XCTAssertTrue(field.isFirstResponder)
        // Enabling must synchronously revoke input before SwiftUI renders.
        await model.setEnabled(true)
        let cover = try XCTUnwrap(anchor.privacyWindow)
        XCTAssertTrue(model.isLocked)
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertFalse(window.isUserInteractionEnabled)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertTrue(cover.isKeyWindow)
        XCTAssertFalse(cover.accessibilityElementsHidden)
        XCTAssertNotNil(sheet.presentingViewController)
        XCTAssertGreaterThan(cover.windowLevel.rawValue, try XCTUnwrap(sheet.view.window).windowLevel.rawValue)
        XCTAssertEqual(cover.windowScene, scene)
        XCTAssertEqual(cover.bounds.size, window.bounds.size)
        cover.layoutIfNeeded()
        attach(cover, name: "Locked gate over presented sheet — unit host")

        // Assert before yielding the main actor. This is cover installation
        // evidence, not an actual operating-system app-switcher snapshot.
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
        XCTAssertFalse(cover.isHidden)
        XCTAssertNotNil(cover.rootViewController)
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(window.isUserInteractionEnabled)
        XCTAssertTrue(window.accessibilityElementsHidden)
        XCTAssertEqual(cover.backgroundColor, .systemBackground)
        XCTAssertGreaterThan(cover.windowLevel.rawValue, UIWindow.Level.alert.rawValue)
        cover.layoutIfNeeded()
        attach(cover, name: "Inactive privacy cover over presented sheet — unit host")

        anchor.detach()
        XCTAssertTrue(window.isUserInteractionEnabled)
        XCTAssertFalse(window.accessibilityElementsHidden)
    }

    private func attach(_ window: UIWindow, name: String) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class RenderingAuthenticator: TerminalAuthenticating {
    func authenticate() async -> Bool { false }
    func cancel() {}
}
