import CryptoKit
import Foundation
import Security
import os

struct FixtureConnection: Sendable {
    let baseURL: URL
    let token: String
    let pin: String

    init(url: String, token: String, pin: String) throws {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil,
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil,
              !token.isEmpty, !token.contains("\n"), !token.contains("\r"),
              pin.count == 64, pin.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw DiagnosticFailure.message("Enter an HTTPS URL, bearer token, and 64-digit certificate SHA256")
        }
        baseURL = parsed
        self.token = token
        self.pin = pin.lowercased()
    }
}

struct FixtureFrame: Decodable, Sendable {
    struct Event: Decodable, Sendable { let sequence: Int; let dataBase64: String }
    let schemaVersion: Int
    let runID: String
    let columns: Int
    let rows: Int
    let kind: String
    let sequence: Int?
    let dataBase64: String?
    let events: [Event]?

    func validate(kind expected: String) throws {
        guard schemaVersion == 1, UUID(uuidString: runID) != nil,
              columns == 20, rows == 6, kind == expected else {
            throw DiagnosticFailure.message("Fixture schema, generation, kind, or dimensions rejected")
        }
    }
}

final class FixtureTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.interactivebuffoonery.awesomux.diagnostics", category: "fixture-trust")
    let connection: FixtureConnection
    init(_ connection: FixtureConnection) { self.connection = connection }

    func request(_ path: String, query: [URLQueryItem] = []) async throws -> (Int, FixtureFrame?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var components = URLComponents(url: connection.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let (stream, response) = try await session.bytes(for: request, delegate: self)
        guard let response = response as? HTTPURLResponse else { throw DiagnosticFailure.message("Invalid fixture response") }
        if response.statusCode == 409 { return (409, nil) }
        guard response.statusCode == 200 else { throw DiagnosticFailure.message("Fixture HTTP \(response.statusCode)") }
        guard response.expectedContentLength <= 262_144 else { throw DiagnosticFailure.message("Fixture frame exceeds 256 KiB") }
        var data = Data()
        for try await byte in stream {
            guard data.count < 262_144 else { throw DiagnosticFailure.message("Fixture frame exceeds 256 KiB") }
            data.append(byte)
        }
        return (200, try JSONDecoder().decode(FixtureFrame.self, from: data))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(_ challenge: URLAuthenticationChallenge,
                                 completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Self.log.info("Fixture challenge method=\(challenge.protectionSpace.authenticationMethod, privacy: .public) host=\(challenge.protectionSpace.host, privacy: .public)")
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == connection.baseURL.host,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        let pinMatches = hash == connection.pin
        Self.log.info("Fixture certificate pinMatch=\(pinMatches, privacy: .public)")
        guard pinMatches else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
