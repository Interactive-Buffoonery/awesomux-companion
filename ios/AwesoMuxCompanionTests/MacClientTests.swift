import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

final class MacClientTests: XCTestCase {
    func testPreviewRequestUsesOnlySelfPermissionAndExistingFrameContract() throws {
        let id = UUID()
        for allowed in [true, false] {
            let request = MacClient.previewRequest(allowed, connectionID: id)
            let data = try CompanionProtocol.encoder().encode(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["schemaVersion", "requestID", "operation", "connectionID", "terminalPreviewAllowed"])
            XCTAssertEqual(object["operation"] as? String, "set_terminal_preview")
            XCTAssertEqual(object["connectionID"] as? String, id.uuidString)
            XCTAssertEqual(object["terminalPreviewAllowed"] as? Bool, allowed)
            XCTAssertEqual(try MacClient.frameRequest(data).dropFirst(4), data)
        }
    }

    func testDecisionRequestContainsOnlyExactAnswerAndPairing() throws {
        let connection = UUID()
        let identity = CompanionDecisionIdentity(runtimeID: UUID(), workspaceID: UUID(), paneID: UUID(),
            targetVersion: UUID(), providerSessionID: "session", invocationID: UUID(), revision: 3)
        let answer = CompanionDecisionAnswer(identity: identity, choice: .deny, retryID: UUID())
        let request = MacClient.decisionRequest(answer, connectionID: connection)
        let data = try CompanionProtocol.encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "requestID", "operation", "connectionID", "decisionAnswer"])
        XCTAssertEqual(object["operation"] as? String, "decide")
        XCTAssertEqual(object["connectionID"] as? String, connection.uuidString)
        XCTAssertEqual(try CompanionProtocol.decoder().decode(CompanionAPIRequest.self, from: data).decisionAnswer, answer)
        XCTAssertEqual(try MacClient.frameRequest(data).dropFirst(4), data)
    }

    func testEmptyRequestUsesClientFailure() {
        XCTAssertThrowsError(try MacClient.frameRequest(Data())) { error in
            XCTAssertEqual(error as? MacClientFailure, .invalidResponse)
        }
    }

    func testOversizedRequestUsesClientFailure() {
        XCTAssertThrowsError(try MacClient.frameRequest(Data(repeating: 0, count: 8193))) { error in
            XCTAssertEqual(error as? MacClientFailure, .oversizedFrame)
        }
    }

    func testMaximumRequestPreservesFrameAndPayload() throws {
        let payload = Data(repeating: 42, count: 8192)
        let frame = try MacClient.frameRequest(payload)

        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 32, 0])
        XCTAssertEqual(frame.dropFirst(4), payload)
    }
}
