import CryptoKit
import Foundation
import Network
import os
import Security

enum MacClientFailure: Error, Equatable {
    case unreachable, handshakeRejected, closed, invalidResponse, oversizedResponse, denied
    case api(String)
}

/// Talks to the awesoMux listener over mutual TLS 1.3, pinning the Mac's SPKI fingerprint from the
/// pairing link. Frames are a 4-byte big-endian length followed by that many bytes of JSON, matching
/// the local agent API. The Mac serves one request per connection, so every call opens its own.
struct MacClient: Sendable {
    let host: String
    let port: UInt16
    let macFingerprint: String
    let identity: PhoneIdentity

    static let maximumResponseBytes = 256 * 1024
    private static let requestTimeout: Duration = .seconds(8)

    // MARK: Pairing

    struct PairReply: Decodable {
        let v: Int
        let status: String
        let connectionID: UUID?
        let macName: String?
    }

    /// An open pairing-only session: `pair` was answered with `confirm` and the Mac is asking its user.
    struct PairingSession: Sendable {
        let words: [String]
        fileprivate let connection: FramedConnection

        /// Waits for the Mac's Allow or Don't Allow (it gives up after two minutes).
        func outcome() async throws -> PairReply {
            defer { connection.cancel() }
            let reply = try await withTimeout(.seconds(150)) {
                try await connection.receiveFrame(maximum: 4096)
            }
            guard let decoded = try? JSONDecoder().decode(PairReply.self, from: reply), decoded.v == 1 else {
                throw MacClientFailure.invalidResponse
            }
            guard decoded.status == "paired", decoded.connectionID != nil else { throw MacClientFailure.denied }
            return decoded
        }

        func cancel() { connection.cancel() }
    }

    func beginPairing(secret: String, phoneName: String) async throws -> PairingSession {
        let connection = try await FramedConnection.open(client: self)
        do {
            let request = try JSONSerialization.data(
                withJSONObject: ["v": 1, "op": "pair", "secret": secret, "phoneName": phoneName], options: [.sortedKeys])
            try await connection.send(request)
            let reply = try await withTimeout(Self.requestTimeout) { try await connection.receiveFrame(maximum: 4096) }
            guard let decoded = try? JSONDecoder().decode(PairReply.self, from: reply), decoded.v == 1 else {
                throw MacClientFailure.invalidResponse
            }
            guard decoded.status == "confirm", let macSPKI = connection.peerSPKI else { throw MacClientFailure.denied }
            return PairingSession(words: try PairingWords.words(macSPKI: macSPKI, phoneSPKI: identity.spki), connection: connection)
        } catch {
            connection.cancel()
            throw error
        }
    }

    // MARK: Local agent API

    /// No `profile` or `credential`: the Companion listener binds requests to its own profile and the paired certificate.
    struct Request: Encodable {
        let schemaVersion = 1
        let requestID = UUID()
        let operation: String
        let connectionID: UUID
        let limit: Int?
        let cursor: String?
    }

    func call(_ operation: String, connectionID: UUID, limit: Int? = nil, cursor: String? = nil) async throws -> APIResponse {
        let request = Request(operation: operation, connectionID: connectionID, limit: limit, cursor: cursor)
        let connection = try await FramedConnection.open(client: self)
        defer { connection.cancel() }
        try await connection.send(JSONEncoder().encode(request))
        let data = try await withTimeout(Self.requestTimeout) {
            try await connection.receiveFrame(maximum: Self.maximumResponseBytes)
        }
        guard let response = try? APIResponse.decoder.decode(APIResponse.self, from: data),
              response.schemaVersion == 1, response.requestID == request.requestID else {
            throw MacClientFailure.invalidResponse
        }
        if let error = response.error { throw MacClientFailure.api(error) }
        return response
    }
}

struct APIResponse: Decodable, Sendable {
    struct Agent: Decodable, Sendable {
        let paneID: String
        let workspaceID: String
        let workspaceName: String
        let provider: String
        let executionLocation: String
        let availability: String
        let state: String
        let attentionReason: String?
        let observedAt: Date?
    }

    struct Event: Codable, Sendable {
        let id: String
        let attentionID: String
        let change: String
        let paneID: String
        let workspaceID: String
        let provider: String
        let occurredAt: Date
        let reason: String
    }

    struct AttentionPage: Decodable, Sendable {
        let events: [Event]
        let nextCursor: String
        let cursorStatus: String
        let hasMore: Bool
        let currentStateRecoveryRequired: Bool
    }

    let schemaVersion: Int
    let requestID: UUID?
    let error: String?
    let capturedAt: Date?
    let connectionStatus: String?
    let agents: [Agent]?
    let attentionEvents: AttentionPage?

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date"))
        }
        return decoder
    }()
}

enum PairingWords {
    private static let list: [String] = {
        guard let url = Bundle.main.url(forResource: "companion-pairing-words", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }()

    /// `SHA-256(macSPKI || phoneSPKI)`, first three bytes as indexes into the shared 256-word list.
    static func words(macSPKI: Data, phoneSPKI: Data) throws -> [String] {
        guard list.count == 256 else { throw MacClientFailure.invalidResponse }
        return SHA256.hash(data: macSPKI + phoneSPKI).prefix(3).map { list[Int($0)] }
    }
}

// MARK: - Transport

private final class FramedConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.interactivebuffoonery.awesomux.companion.connection")
    private let pin: OSAllocatedUnfairLock<Data?>
    /// The Mac certificate's SPKI, captured once the pinned handshake succeeds.
    var peerSPKI: Data? { pin.withLock { $0 } }

    private init(client: MacClient) {
        let pin = OSAllocatedUnfairLock<Data?>(initialState: nil)
        self.pin = pin
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        if let identity = sec_identity_create(client.identity.identity) {
            sec_protocol_options_set_local_identity(options, identity)
        }
        let expected = client.macFingerprint
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  let spki = DER.subjectPublicKeyInfo(ofCertificate: SecCertificateCopyData(leaf) as Data),
                  Data(SHA256.hash(data: spki)).base64URLEncodedString == expected else {
                return complete(false)
            }
            pin.withLock { $0 = spki }
            complete(true)
        }, queue)
        connection = NWConnection(
            host: NWEndpoint.Host(client.host), port: NWEndpoint.Port(rawValue: client.port)!,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    }

    static func open(client: MacClient) async throws -> FramedConnection {
        let framed = FramedConnection(client: client)
        do {
            try await withTimeout(.seconds(8)) { try await framed.start() }
        } catch {
            framed.cancel()
            throw error
        }
        return framed
    }

    private func start() async throws {
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                @Sendable func finish(_ result: Result<Void, Error>) {
                    guard resumed.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case .failed(let error): finish(.failure(Self.failure(error)))
                    case .waiting(let error): finish(.failure(Self.failure(error)))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func failure(_ error: NWError) -> MacClientFailure {
        if case .tls = error { return .handshakeRejected }
        return .unreachable
    }

    func cancel() { connection.cancel() }

    func send(_ payload: Data) async throws {
        var frame = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
        frame.append(payload)
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    continuation.resume(with: error.map { .failure(Self.failure($0)) } ?? .success(()))
                })
            }
        } onCancel: { connection.cancel() }
    }

    func receiveFrame(maximum: Int) async throws -> Data {
        let header = try await receive(exactly: 4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0 else { throw MacClientFailure.invalidResponse }
        guard length <= maximum else { throw MacClientFailure.oversizedResponse }
        return try await receive(exactly: length)
    }

    /// Cancelling the task cancels the connection, which completes any pending receive.
    private func receive(exactly count: Int) async throws -> Data {
        let connection = connection
        return try await withTaskCancellationHandler {
            try await receiveLoop(connection, exactly: count)
        } onCancel: { connection.cancel() }
    }

    private func receiveLoop(_ connection: NWConnection, exactly count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let needed = count - buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { data, _, isComplete, error in
                    if let error { return continuation.resume(throwing: Self.failure(error)) }
                    if let data, !data.isEmpty { return continuation.resume(returning: data) }
                    continuation.resume(throwing: isComplete ? MacClientFailure.closed : MacClientFailure.invalidResponse)
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

private func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw MacClientFailure.unreachable
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
