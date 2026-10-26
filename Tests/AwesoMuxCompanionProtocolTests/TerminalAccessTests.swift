import Foundation
import Testing
@testable import AwesoMuxCompanionProtocol

struct TerminalAccessTests {
    @Test func grantsRoundTripWithExactJSONKeys() throws {
        for allowed in [true, false] {
            let response = CompanionAPIResponse(terminalInputAllowed: allowed,
                createWorkspaceAllowed: allowed, createPaneAllowed: allowed)
            let data = try CompanionProtocol.encoder().encode(response)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for key in ["terminalInputAllowed", "createWorkspaceAllowed", "createPaneAllowed"] {
                #expect(json[key] as? Bool == allowed)
            }
            let decoded = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data)
            #expect(decoded.terminalInputAllowed == allowed)
            #expect(decoded.createWorkspaceAllowed == allowed)
            #expect(decoded.createPaneAllowed == allowed)
        }
    }

    @Test func missingAndNullGrantsRemainAbsent() throws {
        for json in [#"{"schemaVersion":1}"#,
                     #"{"schemaVersion":1,"terminalInputAllowed":null,"createWorkspaceAllowed":null,"createPaneAllowed":null}"#] {
            let response = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: Data(json.utf8))
            #expect(response.terminalInputAllowed == nil)
            #expect(response.createWorkspaceAllowed == nil)
            #expect(response.createPaneAllowed == nil)
        }
    }

    @Test func malformedGrantsAreRejected() throws {
        for key in ["terminalInputAllowed", "createWorkspaceAllowed", "createPaneAllowed"] {
            for invalid in ["yes" as Any, 1] {
                let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, key: invalid])
                #expect(throws: (any Error).self) {
                    try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data)
                }
            }
        }
    }
}
