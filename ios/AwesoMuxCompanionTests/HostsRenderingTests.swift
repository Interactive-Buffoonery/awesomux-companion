import SwiftUI
import UIKit
import XCTest
@testable import AwesoMuxCompanion

/// The real Hosts screen over fixture Macs: one connected with work waiting, one offline with a cached roster.
@MainActor
final class HostsRenderingTests: XCTestCase {
    func testHostsScreen() async throws {
        for (name, longNames, size) in [("b2-hosts", false, DynamicTypeSize.large),
                                        ("b2-hosts-long-names", true, .large),
                                        ("b2-hosts-dynamic-type", false, .accessibility3)] {
            try await render(name, longNames: longNames, size: size)
        }
    }

    private func render(_ name: String, longNames: Bool, size: DynamicTypeSize) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let suite = "HostsRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let desk = Data(repeating: 0xA1, count: 32).base64URLEncodedString
        let studio = Data(repeating: 0xB2, count: 32).base64URLEncodedString
        let keychain = KeychainFixture()
        let pairingStore = PairingStore(keychain: keychain)
        let names = longNames ? [desk: "Sarah’s MacBook Pro (Work, 16-inch, upstairs office)",
                                 studio: "Mac Studio in the Recording Room Downstairs"]
                              : [desk: "MacBook Pro", studio: "Mac Studio"]
        for (fingerprint, pairedAt) in [(desk, 100.0), (studio, 200.0)] {
            try pairingStore.save(PairingRecord(
                macName: names[fingerprint]!, host: "fixture.invalid", port: 1234, macFingerprint: fingerprint,
                transport: .lan, routes: nil, connectionID: UUID(), identityTag: "fixture-\(fingerprint.prefix(4))",
                identityStorage: .keychain, pairedAt: Date(timeIntervalSince1970: pairedAt)))
        }
        defaults.set([desk, studio], forKey: HostRegistry.hostsKey)
        defaults.set(desk, forKey: HostRegistry.selectedKey)
        let working = PaneClientFixture()
        working.agentState = "waiting"
        let offline = PaneClientFixture()
        offline.capturedAt = .now.addingTimeInterval(-300)
        let hosts = Hosts(defaults: defaults, pairingStore: pairingStore) { load in
            CompanionStore(defaults: defaults, loadPairing: load,
                           makeClient: { record, _ in record.macFingerprint == desk ? working : offline },
                           removePairing: { _ in }, liveActivity: nil, writeShared: { _ in }, clearShared: {})
        }
        for store in hosts.stores { store.resumePanes(); await store.refresh() }
        await hosts.stores[0].refreshPanes()
        offline.errors["get_attention_events"] = .unreachable
        await hosts.stores[1].refresh()
        XCTAssertTrue(hosts.stores[0].isConnected)
        XCTAssertFalse(hosts.stores[1].isConnected)
        XCTAssertNotNil(hosts.stores[1].snapshot)
        defer { for store in hosts.stores { store.suspendPanes() } }

        let host = UIHostingController(rootView: NavigationStack(path: .constant([String]())) {
            HostsView(hosts: hosts)
        }.environment(\.dynamicTypeSize, size))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        window.rootViewController?.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
