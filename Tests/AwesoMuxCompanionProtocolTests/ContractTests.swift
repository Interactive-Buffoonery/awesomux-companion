import CryptoKit
import Foundation
import Testing
@testable import AwesoMuxCompanionProtocol

private let requestID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!

private func fixture(_ number: Int) throws -> Data {
    let name = String(format: "vector-%02d", number)
    return try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
}

private func object(_ data: Data) throws -> NSDictionary {
    try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

@Test func pairingRequestVector() throws {
    let request = CompanionPairingRequest(secret: String(repeating: "A", count: 43), phoneName: "iPhone")
    #expect(try object(CompanionProtocol.encoder().encode(request)) == object(fixture(0)))
}

@Test(arguments: [1, 2, 3]) func pairingReplyVectors(_ number: Int) throws {
    let data = try fixture(number)
    let reply = try CompanionProtocol.decoder().decode(CompanionPairingReply.self, from: data)
    #expect(reply.v == 1)
    #expect(try object(CompanionProtocol.encoder().encode(reply)) == object(data))
}

@Test(arguments: [4, 9]) func apiRequestVectors(_ number: Int) throws {
    let data = try fixture(number)
    let request = try CompanionProtocol.decoder().decode(CompanionAPIRequest.self, from: data)
    #expect(request.requestID == requestID)
    #expect(request.connectionID == requestID)
    let encoded = try object(CompanionProtocol.encoder().encode(request))
    #expect(encoded["profile"] == nil)
    #expect(encoded["credential"] == nil)
    #expect((encoded["operation"] as? String) == (try object(data)["operation"] as? String))
}

@Test(arguments: [5, 6, 7, 10]) func apiResponseVectors(_ number: Int) throws {
    let data = try fixture(number)
    let response = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data)
    #expect(response.requestID == requestID)
    let encoded = try object(CompanionProtocol.encoder().encode(response))
    let original = try object(data)
    #expect(encoded.allKeys.count == original.allKeys.count)
    #expect(encoded["error"] as? String == original["error"] as? String)
    #expect(encoded["profile"] as? String == original["profile"] as? String)
}

@Test func agentAndAttentionVectors() throws {
    let agent = try CompanionProtocol.decoder().decode(CompanionAPIResponse.Agent.self, from: fixture(11))
    #expect(agent.paneID == requestID.uuidString.lowercased())
    #expect(agent.provider == "Codex")
    #expect(agent.targetVersion == requestID.uuidString.lowercased())
    #expect(try object(CompanionProtocol.encoder().encode(agent)) == object(fixture(11)))
    let page = try CompanionProtocol.decoder().decode(CompanionAPIResponse.AttentionPage.self, from: fixture(12))
    #expect(page.events.first?.change == "raised")
    #expect(page.events.first?.resolvedAt == nil)
    #expect(try object(CompanionProtocol.encoder().encode(page)) == object(fixture(12)))
}

@Test func tolerantPhoneDecoding() throws {
    let data = Data("""
    {"schemaVersion":1,"requestID":"01234567-89AB-CDEF-0123-456789ABCDEF",
     "error":"future_error","connectionStatus":"future_status","capturedAt":"2026-10-17T18:20:00.125Z",
     "agents":[{"paneID":"opaque-pane","workspaceID":"opaque-workspace","workspaceName":"Project",
       "provider":"Future Provider","executionLocation":"ssh:example","availability":"future",
       "state":"future_state","futureField":true}],"futureEnvelope":{}}
    """.utf8)
    let response = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data)
    #expect(response.requestID == requestID)
    #expect(response.error == "future_error")
    #expect(response.connectionStatus == "future_status")
    #expect(response.agents?.first?.paneID == "opaque-pane")
    #expect(response.agents?.first?.attentionReason == nil)
    #expect(response.agents?.first?.unreadCount == nil)
    #expect(response.capturedAt?.timeIntervalSince1970 == 1_792_261_200.125)
}

@Test(arguments: ["2026-10-17T18:20:00Z", "2026-10-17T18:20:00.000Z"])
func isoDates(_ value: String) throws {
    let response = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self,
        from: Data("{\"schemaVersion\":1,\"capturedAt\":\"\(value)\"}".utf8))
    #expect(response.capturedAt != nil)
}

@Test func pairingUUIDCase() throws {
    let data = Data("{\"v\":1,\"status\":\"paired\",\"connectionID\":\"01234567-89AB-CDEF-0123-456789ABCDEF\"}".utf8)
    let reply = try CompanionProtocol.decoder().decode(CompanionPairingReply.self, from: data)
    #expect(reply.connectionID == requestID)
    #expect(try object(CompanionProtocol.encoder().encode(reply))["connectionID"] as? String == requestID.uuidString.lowercased())
}

@Test func frameVectorAndSlicedHeader() throws {
    let payload = Data("{}".utf8)
    #expect(try CompanionFrame.encode(payload, maximum: 8192) == Data([0, 0, 0, 2, 123, 125]))
    let sliced = Data([255, 0, 0, 0, 2]).dropFirst()
    #expect(try CompanionFrame.payloadLength(sliced, maximum: 8192) == 2)
}

@Test(arguments: [8192, 256 * 1024]) func frameBoundaries(_ maximum: Int) throws {
    let payload = Data(repeating: 123, count: maximum)
    let frame = try CompanionFrame.encode(payload, maximum: maximum)
    #expect(try CompanionFrame.payloadLength(Data(frame.prefix(4)), maximum: maximum) == maximum)
    #expect(throws: CompanionFrame.Failure.tooLarge) { try CompanionFrame.encode(payload + Data([0]), maximum: maximum) }
    #expect(throws: CompanionFrame.Failure.empty) { try CompanionFrame.encode(Data(), maximum: maximum) }
    #expect(throws: CompanionFrame.Failure.empty) { try CompanionFrame.payloadLength(Data([0, 0, 0, 0]), maximum: maximum) }
    #expect(throws: CompanionFrame.Failure.tooLarge) { try CompanionFrame.payloadLength(Data([255, 255, 255, 255]), maximum: maximum) }
}

@Test(arguments: [Data(), Data([0]), Data([0, 0, 0]), Data([0, 0, 0, 1, 0])])
func incompleteFrameHeader(_ header: Data) {
    #expect(throws: CompanionFrame.Failure.invalidHeader) { try CompanionFrame.payloadLength(header, maximum: 8192) }
}

@Test func pairingWordsVector() {
    let list = CompanionPairingWords.list
    #expect(list.count == 256)
    #expect(Set(list).count == 256)
    let hash = SHA256.hash(data: Data((list.joined(separator: "\n") + "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(hash == "f6f1e4790020080d78f10fce0413354ae2ee81a310a51a89cda5fe230b78682a")
    // SHA-256("abc") begins ba7816: W[186], W[120], W[22].
    #expect(CompanionPairingWords.words(macSPKI: Data("a".utf8), phoneSPKI: Data("bc".utf8)) == ["muffin", "feather", "baker"])
    #expect(CompanionPairingWords.words(macSPKI: Data("bc".utf8), phoneSPKI: Data("a".utf8)) != ["muffin", "feather", "baker"])
}

private let link = "awesomuxcompanion://pair?v=1&h=192.168.1.20&p=43123&fp=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&s=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&n=Mac%20%26%20Desk&t=lan"

@Test func pairingLinkRoundTrip() throws {
    let parsed = try CompanionPairingLink(" \n" + link + "\n")
    #expect(parsed.macName == "Mac & Desk")
    #expect(parsed.host == "192.168.1.20")
    #expect(parsed.port == 43123)
    #expect(try CompanionPairingLink(parsed.string()) == parsed)
    let special = CompanionPairingLink(host: "100.100.20.30", port: 43123, macFingerprint: parsed.macFingerprint,
        secret: parsed.secret, macName: "Mac + café & ? # %", transport: "tailscale")
    #expect(try CompanionPairingLink(special.string()) == special)
}

@Test(arguments: ["&v=1", "&extra=1", "#fragment", "&n=Other"])
func malformedPairingLinks(_ suffix: String) {
    #expect(throws: CompanionPairingLink.Failure.malformed) { try CompanionPairingLink(link + suffix) }
}

@Test func unsupportedPairingVersion() {
    #expect(throws: CompanionPairingLink.Failure.unsupportedVersion) { try CompanionPairingLink(link.replacingOccurrences(of: "v=1", with: "v=2")) }
    #expect(throws: CompanionPairingLink.Failure.notAPairingLink) { try CompanionPairingLink("https://example.com") }
    #expect(throws: CompanionPairingLink.Failure.malformed) { try CompanionPairingLink(link.replacingOccurrences(of: "p=43123", with: "p=0")) }
}
