import Foundation
import Testing
@testable import AwesoMuxCompanionProtocol

@Test func alertPreferencesRequestRoundTrip() throws {
    let id = UUID()
    let preferences = CompanionAlertPreferences(categories: [.permission, .commandFailed])
    let request = CompanionAPIRequest(operation: CompanionOperation.setAlertPreferences.rawValue,
        connectionID: id, alertPreferences: preferences)
    let data = try CompanionProtocol.encoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["operation"] as? String == "set_alert_preferences")
    let payload = try #require(object["alertPreferences"] as? [String: Any])
    #expect(payload["categories"] as? [String] == ["permission", "commandFailed"])
    let decoded = try CompanionProtocol.decoder().decode(CompanionAPIRequest.self, from: data)
    #expect(decoded.alertPreferences == preferences)
    #expect(decoded.connectionID == id)
}

@Test func defaultAndMutedAlertPreferencesRoundTrip() throws {
    #expect(CompanionAlertPreferences().categories == Set(CompanionAlertCategory.allCases))
    for preferences in [CompanionAlertPreferences(), CompanionAlertPreferences(categories: [])] {
        let response = CompanionAPIResponse(alertPreferences: preferences)
        let data = try CompanionProtocol.encoder().encode(response)
        #expect(try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data).alertPreferences == preferences)
    }
}

@Test func legacyEnvelopesOmitAlertPreferences() throws {
    let request = CompanionAPIRequest(operation: CompanionOperation.getAlertPreferences.rawValue, connectionID: UUID())
    let data = try CompanionProtocol.encoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["operation"] as? String == "get_alert_preferences")
    #expect(object["alertPreferences"] == nil)
    #expect(try CompanionProtocol.decoder().decode(CompanionAPIRequest.self, from: data).alertPreferences == nil)
    let legacyResponse = Data(#"{"schemaVersion":1}"#.utf8)
    #expect(try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: legacyResponse).alertPreferences == nil)
}

@Test(arguments: [
    #"{"categories":["unknown"]}"#,
    #"{"categories":[true]}"#,
    #"{"categories":null}"#,
    #"{}"#,
])
func malformedAlertPreferencesFailClosed(_ json: String) {
    #expect(throws: (any Error).self) {
        try CompanionProtocol.decoder().decode(CompanionAlertPreferences.self, from: Data(json.utf8))
    }
}

@Test func alertPreferencesEncodingIsCanonical() throws {
    let a = CompanionAlertPreferences(categories: [.commandFailed, .waiting, .permission])
    let b = CompanionAlertPreferences(categories: [.permission, .waiting, .commandFailed])
    #expect(try CompanionProtocol.encoder().encode(a) == CompanionProtocol.encoder().encode(b))
}

@Test func malformedEnvelopePreferencesFailClosed() {
    let response = Data(#"{"schemaVersion":1,"alertPreferences":{"categories":["future"]}}"#.utf8)
    #expect(throws: (any Error).self) {
        try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: response)
    }
    let request = Data("""
    {"schemaVersion":1,"requestID":"\(UUID())","connectionID":"\(UUID())",
     "operation":"set_alert_preferences","alertPreferences":{"categories":["future"]}}
    """.utf8)
    #expect(throws: (any Error).self) {
        try CompanionProtocol.decoder().decode(CompanionAPIRequest.self, from: request)
    }
}
