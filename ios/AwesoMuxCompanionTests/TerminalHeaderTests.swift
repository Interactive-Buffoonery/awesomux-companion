import SwiftUI
import UIKit
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class TerminalHeaderTests: XCTestCase {
    func testHeaderAlwaysNamesHostWithWorkspaceAndPane() {
        var target = TerminalDestination(paneID: UUID(), targetVersion: UUID(), title: "build", workspace: "api-server")
        XCTAssertEqual(target.path, "api-server/build")
        XCTAssertEqual(target.accessibilityHeader(host: "sarahs-mbp"), "build in api-server on sarahs-mbp")
        target.workspace = ""
        target.title = ""
        XCTAssertEqual(target.path, "Terminal")
        XCTAssertEqual(target.accessibilityHeader(host: "sarahs-mbp"), "Terminal on sarahs-mbp")
        XCTAssertEqual(TerminalDestination.hostName("sarahs-mbp"), "sarahs-mbp")
        XCTAssertEqual(TerminalDestination.hostName(""), "Mac")
        XCTAssertEqual(TerminalDestination.hostName(nil), "Mac")
    }

    func testSessionsAndCreationCarryWorkspaceWithoutChangingTargetOrOpening() async throws {
        let paneID = UUID()
        let version = UUID()
        let pane = ListedPane(id: paneID.uuidString, title: "build", kind: .terminal,
                              availability: "attached", state: nil, targetVersion: version.uuidString)
        let listed = try XCTUnwrap(pane.terminalTarget(in: "api-server"))
        XCTAssertEqual(listed, TerminalDestination(paneID: paneID, targetVersion: version,
                                                   title: "build", workspace: "api-server", opening: .input))

        let created = CreatedTerminal(workspaceID: UUID(), paneID: UUID(), targetVersion: UUID())
        let model = TerminalCreationModel()
        await model.create(workspaceID: created.workspaceID, workspaceName: "api-server", isCurrent: { true },
                           canCreate: { true }, send: { _ in created }, refresh: {})
        XCTAssertEqual(model.destination, TerminalDestination(paneID: created.paneID, targetVersion: created.targetVersion,
                                                              title: "Terminal", workspace: "api-server", opening: .input))
    }

    /// Real `WatchView` header at iPhone SE width with long names. Inactive lock keeps it offline.
    func testLongNamesAtCompactWidthAndLargeType() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let suite = "TerminalHeader.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = PairingRecord(macName: "Sarah’s MacBook Pro 16-inch (Studio)", host: "fixture.invalid", port: 1234,
                                   macFingerprint: "fixture-pin", transport: .lan, routes: nil,
                                   connectionID: UUID(), identityTag: "fixture-only", identityStorage: .keychain,
                                   pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let store = CompanionStore(defaults: defaults, loadPairing: { record }, makeClient: { _, _ in PaneClientFixture() },
                                   removePairing: { _ in }, liveActivity: nil, writeShared: { _ in }, clearShared: {})
        let lock = TerminalLockModel(defaults: defaults, authenticator: HeaderAuthenticator())
        let target = TerminalDestination(paneID: UUID(), targetVersion: UUID(),
                                         title: "codex-review-long-running-build-watcher",
                                         workspace: "awesomux-companion-redesign-workspace")
        let root = NavigationStack(path: .constant([target])) {
            Color.clear
                .terminalTitle(record.macName)
                .navigationDestination(for: TerminalDestination.self) { target in
                    WatchView(store: store, target: target, terminalLock: lock)
                }
        }
        .environment(PendingDecisionsModel(session: { nil }, isUnlocked: { true },
                                           read: { _, _ in throw CancellationError() },
                                           submit: { _, _, _ in throw CancellationError() }))
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        for size in [UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityLarge] {
            host.traitOverrides.preferredContentSizeCategory = size
            try await Task.sleep(for: .milliseconds(500))
            attach(window, name: "a2-header-375-\(size.rawValue)")
        }
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
private final class HeaderAuthenticator: TerminalAuthenticating {
    func authenticate() async -> Bool { false }
    func cancel() {}
}
