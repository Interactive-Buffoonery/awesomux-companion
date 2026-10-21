import AwesoMuxCompanionProtocol
import SwiftUI
import UIKit
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class PendingDecisionsRenderingTests: XCTestCase {
    func testInlineRequestsAndOutcomesHaveContextAndDisabledStateRenders() async throws {
        let f = DecisionFixture()
        let secondIdentity = CompanionDecisionIdentity(runtimeID: f.identity.runtimeID, workspaceID: UUID(), paneID: UUID(),
            targetVersion: UUID(), providerSessionID: "second", invocationID: UUID(), revision: 2)
        let second = CompanionPendingDecision(identity: secondIdentity, tool: "Write", summary: "Update project notes",
            remoteExpiresAt: f.pending.remoteExpiresAt, choices: [.allow, .deny])
        f.response = f.list(pending: [f.pending, second])
        await f.model.refresh()
        try await attach(f, name: "inline-claude-pending-context-large-text")
        // These transitions call the model. They do not exercise UI taps or real authentication.
        await f.model.answer(f.identity, choice: .allow)
        XCTAssertEqual(f.model.outcomes.first?.state, .delivered)
        try await attach(f, name: "inline-claude-hook-delivered-context")
        f.response = APIResponse(remoteDecisionsEnabled: false)
        await f.model.refresh()
        XCTAssertEqual(f.model.availability, .disabled)
        XCTAssertTrue(f.model.pending.isEmpty)
        try await attach(f, name: "inline-claude-production-disabled")
    }

    private func attach(_ fixture: DecisionFixture, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let appeared = expectation(description: "\(name) fixture appeared")
        let host = DecisionRenderingHost(rootView: NavigationStack {
            List {
                PendingDecisionsSection(model: fixture.model) { identity in
                    DecisionContext(workspace: identity == fixture.identity ? "Companion" : "Another workspace",
                                    pane: identity == fixture.identity ? "Claude build" : "Claude notes", identity: identity)
                }
            }
            .navigationTitle("Agents")
        }.environment(\.dynamicTypeSize, .accessibility1))
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
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
        XCTAssertGreaterThan(window.bounds.width, 0)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
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
private final class DecisionRenderingHost<Content: View>: UIHostingController<Content> {
    var appeared: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared?()
        appeared = nil
    }
}
