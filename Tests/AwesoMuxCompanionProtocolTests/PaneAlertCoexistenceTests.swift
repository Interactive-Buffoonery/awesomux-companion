import Foundation
import Testing

@testable import AwesoMuxCompanionProtocol

@Suite("Pane and alert preference coexistence")
struct PaneAlertCoexistenceTests {
  @Test func responsePreservesAllAdditiveFields() throws {
    let routes = CompanionRoutes(p: 1234, lan: "10.0.0.2", tailscale: nil)
    let preferences = CompanionAlertPreferences(categories: [.permission, .commandFailed])
    let response = CompanionAPIResponse(
      routes: routes, alertPreferences: preferences,
      workspaces: [
        .init(
          workspaceID: "workspace", name: "Work",
          panes: [
            .init(
              paneID: "shell", kind: "terminal", title: "Shell", availability: "attached",
              lastOutputLine: "ready")
          ])
      ], terminalPreviewAllowed: true)
    let data = try CompanionProtocol.encoder().encode(response)
    let decoded = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data)
    #expect(decoded.routes == routes)
    #expect(decoded.alertPreferences == preferences)
    #expect(decoded.terminalPreviewAllowed == true)
    #expect(decoded.workspaces?.first?.panes.first?.lastOutputLine == "ready")
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["routes"] = ["v": 999]
    let tolerant = try CompanionProtocol.decoder().decode(
      CompanionAPIResponse.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(tolerant.routes == nil)
    #expect(tolerant.alertPreferences == preferences)
    #expect(tolerant.terminalPreviewAllowed == true)
    #expect(tolerant.workspaces?.first?.workspaceID == "workspace")
    object["alertPreferences"] = ["categories": ["future"]]
    #expect(throws: (any Error).self) {
      try CompanionProtocol.decoder().decode(
        CompanionAPIResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  @Test func requestsPreservePreviewAlertsAndAttentionOptions() throws {
    let preferences = CompanionAlertPreferences(categories: [.waiting])
    for request in [
      CompanionAPIRequest(
        operation: CompanionOperation.setTerminalPreview.rawValue, connectionID: UUID(),
        terminalPreviewAllowed: false),
      CompanionAPIRequest(
        operation: CompanionOperation.setAlertPreferences.rawValue, connectionID: UUID(),
        alertPreferences: preferences),
      CompanionAPIRequest(
        operation: CompanionOperation.attentionEvents.rawValue, connectionID: UUID(), limit: 100,
        includeCommandEvents: true),
    ] {
      let data = try CompanionProtocol.encoder().encode(request)
      let decoded = try CompanionProtocol.decoder().decode(CompanionAPIRequest.self, from: data)
      #expect(decoded.operation == request.operation)
      #expect(decoded.terminalPreviewAllowed == request.terminalPreviewAllowed)
      #expect(decoded.alertPreferences == request.alertPreferences)
      #expect(decoded.includeCommandEvents == request.includeCommandEvents)
    }
  }
}
