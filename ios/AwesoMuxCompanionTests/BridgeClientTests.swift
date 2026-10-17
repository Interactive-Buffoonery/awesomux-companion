import Foundation
import XCTest
@testable import AwesoMuxCompanion

private final class StubResponse: @unchecked Sendable {
    let lock = NSLock()
    var body = Data()
    var headers: [String: String] = [:]
    var status = 200
    func set(_ body: Data, headers: [String: String], status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        self.body = body; self.headers = headers; self.status = status
    }
    func read() -> (Data, [String: String], Int) {
        lock.lock(); defer { lock.unlock() }
        return (body, headers, status)
    }
}
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let response = StubResponse()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, headers, status) = Self.response.read()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class BridgeClientTests: XCTestCase {
    private func client() throws -> BridgeClient {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubProtocol.self]
        return try BridgeClient(configuration: DevelopmentConfiguration(endpoint: "http://127.0.0.1:54321", token: String(repeating: "x", count: 32)), sessionConfiguration: session)
    }
    func testReceiveRejectsOversizedStreamWithoutContentLength() async throws {
        StubProtocol.response.set(Data(repeating: 32, count: 4 * 1024 * 1024 + 1), headers: ["Content-Type":"application/json"])
        do { _ = try await client().fetch(); XCTFail("oversized stream accepted") }
        catch BridgeFailure.oversizedResponse {} catch { XCTFail("unexpected error: \(error)") }
    }
    func testInvalidJSONAndCredentialsAreTypedFailures() async throws {
        StubProtocol.response.set(Data("invalid".utf8), headers: ["Content-Type":"application/json"])
        do { _ = try await client().fetch(); XCTFail("invalid JSON accepted") }
        catch BridgeFailure.invalidResponse {} catch { XCTFail("unexpected error: \(error)") }
        StubProtocol.response.set(Data("{}".utf8), headers: ["Content-Type":"application/json"], status: 401)
        do { _ = try await client().fetch(); XCTFail("unauthorized snapshot accepted") }
        catch BridgeFailure.credentialsRejected {} catch { XCTFail("unexpected error: \(error)") }
    }
    func testEndpointRejectsNonLoopbackAndEmbeddedCredentials() throws {
        for endpoint in ["http://example.com:54321", "http://localhost:54321", "http://127.0.0.1", "http://user@127.0.0.1:54321", "http://127.0.0.1:54321/path"] {
            XCTAssertThrowsError(try DevelopmentConfiguration(endpoint: endpoint, token: String(repeating: "x", count: 32)).validatedURL())
        }
    }
}
