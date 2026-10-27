import SwiftUI
import UIKit
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class TerminalLockRenderingTests: XCTestCase {
    func testLockedGateAndSynchronousScenePrivacyCover() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousKeyWindow = scene.windows.first(where: { $0.isKeyWindow })
        let suite = "TerminalLockRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TerminalLockModel(defaults: defaults, authenticator: RenderingAuthenticator())
        model.becomeActive()
        let hosts = Hosts(defaults: defaults, pairingStore: PairingStore(keychain: KeychainFixture())) { load in
            CompanionStore(defaults: defaults, loadPairing: load, liveActivity: nil, writeShared: { _ in }, clearShared: {})
        }
        let host = UIHostingController(rootView: NavigationStack {
            AppSettingsView(hosts: hosts)
        }.environment(model))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        let anchor = ScenePrivacyAnchor(model: model, protectsContent: true)
        window.addSubview(anchor)
        defer {
            anchor.detach()
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.isLocked)
        XCTAssertTrue(anchor.privacyWindow == nil || anchor.privacyWindow?.isHidden == true)
        XCTAssertTrue(window.isUserInteractionEnabled)
        attach(window, name: "Optional Lock App off by default — app-hosted Settings")
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
        model.becomeInactive()
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
        await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
            host.dismiss(animated: false) { completion.resume() }
        }
    }

    private func attach(_ window: UIWindow, name: String) {
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertTrue(hasVisibleContent(image), "\(name) must contain more than an empty background")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func hasVisibleContent(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }
        var pixels = [UInt32](repeating: 0, count: 32 * 64)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 32, height: 64, bitsPerComponent: 8,
                bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 32, height: 64))
            let values = buffer.bindMemory(to: UInt32.self)
            return values.contains { $0 != values[0] }
        }
    }
}

@MainActor
private final class RenderingAuthenticator: TerminalAuthenticating {
    func authenticate() async -> Bool { false }
    func cancel() {}
}
