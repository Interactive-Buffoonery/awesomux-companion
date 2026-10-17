import Foundation
import XCTest
@testable import AwesoMuxCompanion

final class ConnectionConfigurationTests: XCTestCase {
    private let token = String(repeating: "x", count: 32)
    func testOnlyCanonicalPrivateHTTPSOriginsAreAccepted() throws {
        for port in [8443, 10000] {
            let endpoint = "https://mac.example-tailnet.ts.net:\(port)"
            XCTAssertEqual(try ConnectionConfiguration(endpoint: endpoint, token: token).validatedURL().absoluteString, endpoint)
        }
        for endpoint in ["http://mac.example.ts.net:8443", "https://mac.example.ts.net", "https://mac.ts.net:8443", "https://Mac.example.ts.net:8443", "https://mac.example.ts.net.:8443", "https://mac.example.ts.net:443", "https://user@mac.example.ts.net:8443", "https://mac.example.ts.net:8443/", "https://mac.example.ts.net:8443?key=x", "https://mac.example.ts.net:8443#x", "https://127.0.0.1:8443", "https://m%61c.example.ts.net:8443", "https://-mac.example.ts.net:8443", "https://mac..example.ts.net:8443"] {
            XCTAssertThrowsError(try ConnectionConfiguration(endpoint: endpoint, token: token).validatedURL(), endpoint)
        }
    }
    func testCapabilityRejectsWhitespaceControlAndNonASCII() {
        for key in [String(repeating: "x", count: 31), String(repeating: "x", count: 129), token + "\n", token + " ", token + "é"] {
            XCTAssertThrowsError(try ConnectionConfiguration(endpoint: "https://mac.example.ts.net:8443", token: key).validatedURL())
        }
    }
    @MainActor func testInMemoryReplacementAndIdempotentDisconnect() throws {
        let storage = InMemoryHostCredentialStore()
        XCTAssertNil(try storage.load())
        let first = ConnectionConfiguration(endpoint: "https://mac.example.ts.net:8443", token: token)
        try storage.save(first)
        XCTAssertEqual(try storage.load(), first)
        XCTAssertThrowsError(try storage.save(ConnectionConfiguration(endpoint: "http://127.0.0.1:1234", token: token)))
        XCTAssertEqual(try storage.load(), first)
        try storage.clear(); try storage.clear()
        XCTAssertNil(try storage.load())
    }
}
