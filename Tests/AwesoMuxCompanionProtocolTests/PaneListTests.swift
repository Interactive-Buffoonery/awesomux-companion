import Foundation
import Testing
@testable import AwesoMuxCompanionProtocol

@Suite("Companion pane list encoding")
struct PaneListTests {
    @Test func requestHasNoBearerOrContext() throws {
        let request = CompanionAPIRequest(operation: CompanionOperation.listPanes.rawValue, connectionID: UUID())
        let object = try #require(JSONSerialization.jsonObject(with: CompanionProtocol.encoder().encode(request)) as? [String: Any])
        #expect(object["operation"] as? String == "list_panes")
        #expect(Set(object.keys) == ["schemaVersion", "requestID", "operation", "connectionID"])
    }

    @Test func orderedRosterRoundTripsWithoutDocumentContent() throws {
        let response = CompanionAPIResponse(workspaces: [
            .init(workspaceID: "workspace", name: "Work", panes: [
                .init(paneID: "shell", kind: "terminal", title: "Shell", availability: "attached", state: "idle", lastOutputLine: "hello"),
                .init(paneID: "split", kind: "terminal", title: "Agent", availability: "stale", state: "running"),
                .init(paneID: "document", kind: "documentGroup", title: "Notes", availability: "attached"),
            ]),
            .init(workspaceID: "empty", name: "Empty", panes: []),
        ])
        let data = try CompanionProtocol.encoder().encode(response)
        let decoded = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data)
        #expect(decoded.workspaces?.map(\.workspaceID) == ["workspace", "empty"])
        #expect(decoded.workspaces?.first?.panes.map(\.paneID) == ["shell", "split", "document"])
        #expect(decoded.workspaces?.first?.panes.first?.lastOutputLine == "hello")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaces = try #require(object["workspaces"] as? [[String: Any]])
        let panes = try #require(workspaces.first?["panes"] as? [[String: Any]])
        #expect(Set(panes[2].keys) == ["paneID", "kind", "title", "availability"])
        #expect(panes[1]["lastOutputLine"] == nil)
        #expect(object["agents"] == nil)
    }

    @Test func olderEnvelopeOmitsRoster() throws {
        let data = Data("{\"schemaVersion\":1}".utf8)
        let response = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data)
        #expect(response.workspaces == nil)
        #expect(try CompanionProtocol.encoder().encode(response) == data)
    }
}
