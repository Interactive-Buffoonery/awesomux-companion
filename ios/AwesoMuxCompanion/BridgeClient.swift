import Foundation

protocol BridgeAPI: Sendable {
    func fetch() async throws -> ThreadSnapshot
    func answer(_ operation: AnswerOperation) async throws -> AnswerReply
}

enum BridgeFailure: Error { case invalidConfiguration, credentialsRejected, disconnected, invalidResponse, oversizedResponse }

#if DEBUG && targetEnvironment(simulator)
struct DevelopmentConfiguration: Decodable, Equatable, Sendable {
    let endpoint: String
    let token: String
    func validatedURL() throws -> URL {
        guard let c = URLComponents(string: endpoint), c.scheme == "http", c.host == "127.0.0.1",
              let port = c.port, (1...65535).contains(port), port != 80,
              c.user == nil, c.password == nil, c.path.isEmpty, c.query == nil, c.fragment == nil,
              let url = c.url, token.utf8.count >= 32, token.utf8.count <= 128,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw BridgeFailure.invalidConfiguration }
        return url
    }
    static func load() throws -> Self? {
        #if DEBUG && targetEnvironment(simulator)
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let path = folder.appendingPathComponent("development-client.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        guard data.count <= 4096 else { throw BridgeFailure.invalidConfiguration }
        let config = try JSONDecoder().decode(Self.self, from: data)
        _ = try config.validatedURL()
        return config
        #else
        return nil
        #endif
    }
}

#endif

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil) }
}

final class BridgeClient: BridgeAPI, Sendable {
    private let endpoint: URL
    private let token: String
    private let session: URLSession
    private let delegate = NoRedirectDelegate()
    convenience init(configuration: ConnectionConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) throws {
        try self.init(endpoint: configuration.validatedURL(), token: configuration.token, sessionConfiguration: sessionConfiguration)
    }
    #if DEBUG && targetEnvironment(simulator)
    convenience init(configuration: DevelopmentConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) throws {
        try self.init(endpoint: configuration.validatedURL(), token: configuration.token, sessionConfiguration: sessionConfiguration)
    }
    #endif
    private init(endpoint: URL, token: String, sessionConfiguration: URLSessionConfiguration) {
        self.endpoint = endpoint; self.token = token
        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 8
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
    }
    private func request(_ path: String, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: endpoint.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body { r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    private func receive(_ request: URLRequest, limit: Int) async throws -> (HTTPURLResponse, Data) {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.url == request.url, http.mimeType == "application/json" else {
            bytes.task.cancel(); throw BridgeFailure.invalidResponse
        }
        guard response.expectedContentLength <= Int64(limit) else { bytes.task.cancel(); throw BridgeFailure.oversizedResponse }
        var data = Data()
        do {
            for try await byte in bytes {
                if data.count >= limit { throw BridgeFailure.oversizedResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
        } catch { bytes.task.cancel(); throw error }
        return (http, data)
    }
    func fetch() async throws -> ThreadSnapshot {
        let (response, data) = try await receive(request("v1/thread"), limit: 4 * 1024 * 1024)
        if response.statusCode == 401 { throw BridgeFailure.credentialsRejected }
        guard response.statusCode == 200 else { throw BridgeFailure.disconnected }
        do { return try JSONDecoder().decode(ThreadSnapshot.self, from: data) }
        catch { throw BridgeFailure.invalidResponse }
    }
    func answer(_ operation: AnswerOperation) async throws -> AnswerReply {
        let (response, data) = try await receive(request("v1/answers", body: operation.body), limit: 64 * 1024)
        struct Envelope: Decodable { let outcome: String?; let error: String? }
        guard let decoded = try? JSONDecoder().decode(Envelope.self, from: data) else { throw BridgeFailure.invalidResponse }
        return AnswerReply(status: response.statusCode, outcome: decoded.outcome, error: decoded.error)
    }
}
