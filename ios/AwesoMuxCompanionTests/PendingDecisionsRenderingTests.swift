import AwesoMuxCompanionProtocol
import SwiftUI
import UIKit
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class PendingDecisionsRenderingTests: XCTestCase {
    func testInlineRequestsAndOutcomesHaveContextAndDisabledStateRenders() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let f = DecisionFixture()
        let secondIdentity = CompanionDecisionIdentity(runtimeID: f.identity.runtimeID, workspaceID: UUID(), paneID: UUID(),
            targetVersion: UUID(), providerSessionID: "second", invocationID: UUID(), revision: 2)
        let second = CompanionPendingDecision(identity: secondIdentity, tool: "Write", summary: "Update project notes",
            remoteExpiresAt: f.pending.remoteExpiresAt, choices: [.allow, .deny])
        f.response = f.list(pending: [f.pending, second])
        await f.model.refresh()
        let host = UIHostingController(rootView: NavigationStack {
            List {
                PendingDecisionsSection(model: f.model) { identity in
                    DecisionContext(workspace: identity == f.identity ? "Companion" : "Another workspace",
                                    pane: identity == f.identity ? "Claude build" : "Claude notes", identity: identity)
                }
            }
            .navigationTitle("Agents")
        }.environment(\.dynamicTypeSize, .accessibility1))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        attach(window, name: "inline-claude-pending-context-large-text")
        await f.model.answer(f.identity, choice: .allow)
        XCTAssertEqual(f.model.outcomes.first?.state, .delivered)
        attach(window, name: "inline-claude-hook-delivered-context")
        f.response = APIResponse(remoteDecisionsEnabled: false)
        await f.model.refresh()
        XCTAssertEqual(f.model.availability, .disabled)
        XCTAssertTrue(f.model.pending.isEmpty)
        attach(window, name: "inline-claude-production-disabled")
    }

    private func attach(_ window: UIWindow, name: String) {
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        window.layoutIfNeeded()
        XCTAssertGreaterThan(window.bounds.width, 0)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
