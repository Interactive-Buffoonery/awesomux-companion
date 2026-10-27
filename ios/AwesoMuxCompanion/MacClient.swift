import AwesoMuxCompanionProtocol
import CryptoKit
import Foundation
import Network
import os
import Security

enum MacClientFailure: Error, Equatable {
    case unreachable, handshakeRejected, closed, invalidResponse, oversizedFrame, denied
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

    static let maximumResponseBytes = CompanionProtocol.maximumResponseBytes
    private static let requestTimeout: Duration = .seconds(8)

    static func frameRequest(_ payload: Data, maximum: Int = CompanionProtocol.maximumRequestBytes) throws -> Data {
        do {
            return try CompanionFrame.encode(payload, maximum: maximum)
        } catch CompanionFrame.Failure.tooLarge {
            throw MacClientFailure.oversizedFrame
        } catch {
            throw MacClientFailure.invalidResponse
        }
    }

    // MARK: Pairing

    typealias PairReply = CompanionPairingReply

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
            let request = try CompanionProtocol.encoder().encode(CompanionPairingRequest(secret: secret, phoneName: phoneName))
            try await connection.send(request)
            let reply = try await withTimeout(Self.requestTimeout) { try await connection.receiveFrame(maximum: 4096) }
            guard let decoded = try? JSONDecoder().decode(PairReply.self, from: reply), decoded.v == 1 else {
                throw MacClientFailure.invalidResponse
            }
            guard decoded.status == "confirm", let macSPKI = connection.peerSPKI else { throw MacClientFailure.denied }
            return PairingSession(words: CompanionPairingWords.words(macSPKI: macSPKI, phoneSPKI: identity.spki), connection: connection)
        } catch {
            connection.cancel()
            throw error
        }
    }

    func unpair(connectionID: UUID) async throws {
        let response = try await withTimeout(.seconds(3)) {
            try await call("unpair", connectionID: connectionID)
        }
        guard response.profile != nil, response.appInstanceID != nil, response.capturedAt != nil else {
            throw MacClientFailure.invalidResponse
        }
    }

    // MARK: Local agent API

    func call(_ operation: String, connectionID: UUID, limit: Int? = nil, cursor: String? = nil) async throws -> APIResponse {
        try await exchange(CompanionAPIRequest(operation: operation, connectionID: connectionID, limit: limit, cursor: cursor))
    }

    func call(_ operation: String, connectionID: UUID, limit: Int?, cursor: String?,
              canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse {
        try await exchange(CompanionAPIRequest(operation: operation, connectionID: connectionID,
                                              limit: limit, cursor: cursor), canSend: canSend)
    }

    func setTerminalPreview(_ allowed: Bool, connectionID: UUID) async throws -> APIResponse {
        try await exchange(Self.previewRequest(allowed, connectionID: connectionID))
    }

    static func previewRequest(_ allowed: Bool, connectionID: UUID) -> CompanionAPIRequest {
        CompanionAPIRequest(operation: CompanionOperation.setTerminalPreview.rawValue, connectionID: connectionID,
                            terminalPreviewAllowed: allowed)
    }

    func answerDecision(_ answer: CompanionDecisionAnswer, connectionID: UUID,
                        canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse {
        try await exchange(Self.decisionRequest(answer, connectionID: connectionID), canSend: canSend)
    }

    static func decisionRequest(_ answer: CompanionDecisionAnswer, connectionID: UUID) -> CompanionAPIRequest {
        CompanionAPIRequest(operation: CompanionOperation.answerDecision.rawValue,
                            connectionID: connectionID, decisionAnswer: answer)
    }

    static func watchRequest(connectionID: UUID, paneID: UUID, targetVersion: UUID,
                             preferredGrid: CompanionTerminalStream.Grid = .init(rows: 24, cols: 80)) -> CompanionAPIRequest {
        CompanionAPIRequest(operation: CompanionOperation.watchTerminal.rawValue, connectionID: connectionID,
                            paneID: paneID, targetVersion: targetVersion,
                            streamVersion: CompanionTerminalStream.version, grid: preferredGrid)
    }

    func openWatch(connectionID: UUID, paneID: UUID, targetVersion: UUID,
                   preferredGrid: CompanionTerminalStream.Grid = .init(rows: 24, cols: 80),
                   canSend: @escaping @MainActor @Sendable () -> Bool = { true }) async throws -> any WatchConnection {
        guard await canSend() else { throw CancellationError() }
        let advertised = try await exchange(CompanionAPIRequest(operation: CompanionOperation.capabilities.rawValue,
                                                               connectionID: connectionID), canSend: canSend)
        guard let limits = advertised.terminalStream else { throw WatchFailure.unsupportedStream }
        try WatchStream.validate(limits)
        guard await canSend() else { throw CancellationError() }
        let connection = try await FramedConnection.open(client: self)
        return try await Self.openWatch(connection: connection,
            request: Self.watchRequest(connectionID: connectionID, paneID: paneID, targetVersion: targetVersion, preferredGrid: preferredGrid),
            capabilities: limits, canSend: canSend)
    }

    static func openWatch(connection: any WatchFrameConnection, request: CompanionAPIRequest,
                          capabilities: CompanionTerminalStream.Capabilities,
                          canSend: @escaping @MainActor @Sendable () -> Bool = { true }) async throws -> any WatchConnection {
        let diagnostic = WatchDiagnostics.current
        WatchDiagnostics.watch.notice("watch_request attempt_id=\(diagnostic?.id.uuidString ?? "none", privacy: .public) request_id=\(request.requestID, privacy: .public)")
        do {
            try WatchStream.validate(capabilities)
            try Task.checkCancellation()
            try await connection.send(CompanionProtocol.encoder().encode(request),
                                      maximum: CompanionProtocol.maximumRequestBytes, canSend: canSend)
            let data = try await withTimeout(requestTimeout, phase: "api_reply") {
                try await connection.receiveFrame(maximum: maximumResponseBytes)
            }
            try Task.checkCancellation()
            guard await canSend() else { throw CancellationError() }
            let response = try CompanionProtocol.decoder().decode(APIResponse.self, from: data)
            guard response.schemaVersion == CompanionProtocol.version, response.requestID == request.requestID else {
                throw MacClientFailure.invalidResponse
            }
            if let error = response.error { throw MacClientFailure.api(error) }
            guard let accepted = response.terminalStreamAccepted,
                  accepted.streamVersion == CompanionTerminalStream.version,
                  accepted.role != .interactive || capabilities.inputFrameMax != nil else {
                throw MacClientFailure.invalidResponse
            }
            WatchDiagnostics.watch.notice("watch_accepted request_id=\(request.requestID, privacy: .public) role=\(accepted.role.rawValue, privacy: .public)")
            return MacWatchConnection(connection: connection, capabilities: capabilities, accepted: accepted, diagnostics: diagnostic)
        } catch {
            connection.cancel()
            throw error
        }
    }

    func createTerminal(connectionID: UUID, workspaceID: UUID?,
                        canSend: @escaping @MainActor @Sendable () -> Bool) async throws -> CreatedTerminal {
        guard await canSend() else { throw CancellationError() }
        let request = CreateTerminalRequest(connectionID: connectionID, workspaceID: workspaceID)
        let connection = try await FramedConnection.open(client: self)
        defer { connection.cancel() }
        try await connection.send(CompanionProtocol.encoder().encode(request), canSend: canSend)
        let data = try await withTimeout(Self.requestTimeout) {
            try await connection.receiveFrame(maximum: Self.maximumResponseBytes)
        }
        try Task.checkCancellation()
        guard await canSend() else { throw CancellationError() }
        return try Self.createdTerminal(from: data, requestID: request.requestID)
    }

    static func createdTerminal(from data: Data, requestID: UUID) throws -> CreatedTerminal {
        guard let response = try? CompanionProtocol.decoder().decode(CreateTerminalResponse.self, from: data),
              response.schemaVersion == CompanionProtocol.version, response.requestID == requestID else {
            throw MacClientFailure.invalidResponse
        }
        if let error = response.error { throw MacClientFailure.api(error) }
        guard let created = response.createdTerminal else { throw MacClientFailure.invalidResponse }
        return created
    }

    private func exchange(_ request: CompanionAPIRequest,
                          canSend: (@MainActor @Sendable () -> Bool)? = nil) async throws -> APIResponse {
        let connection = try await FramedConnection.open(client: self)
        defer { connection.cancel() }
        try await connection.send(CompanionProtocol.encoder().encode(request), canSend: canSend)
        let data = try await withTimeout(Self.requestTimeout) {
            try await connection.receiveFrame(maximum: Self.maximumResponseBytes)
        }
        guard let response = try? CompanionProtocol.decoder().decode(APIResponse.self, from: data),
              response.schemaVersion == 1, response.requestID == request.requestID else {
            throw MacClientFailure.invalidResponse
        }
        if let error = response.error { throw MacClientFailure.api(error) }
        return response
    }
}

typealias APIResponse = CompanionAPIResponse

// MARK: - Transport

private final class FramedConnection: WatchFrameConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let diagnostic = WatchDiagnostics.current
    private let diagnosticID = UUID()
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
        WatchDiagnostics.transport.debug("transport_open attempt_id=\(self.diagnostic?.id.uuidString ?? "none", privacy: .public) transport_id=\(self.diagnosticID, privacy: .public)")
    }

    static func open(client: MacClient) async throws -> FramedConnection {
        let framed = FramedConnection(client: client)
        do {
            try await withTimeout(.seconds(8), phase: "connect") { try await framed.start() }
        } catch {
            framed.cancel()
            throw error
        }
        return framed
    }

    private func start() async throws {
        let connection = connection
        let diagnosticID = diagnosticID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let resumed = OSAllocatedUnfairLock(initialState: false)
                @Sendable func finish(_ result: Result<Void, Error>) {
                    guard resumed.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case .failed(let error):
                        WatchDiagnostics.networkError(error, id: diagnosticID, phase: "connect_failed")
                        finish(.failure(Self.failure(error)))
                    case .waiting(let error):
                        WatchDiagnostics.networkError(error, id: diagnosticID, phase: "connect_waiting")
                        finish(.failure(Self.failure(error)))
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

    @MainActor
    func send(_ payload: Data, maximum: Int = CompanionProtocol.maximumRequestBytes,
              canSend: (@MainActor @Sendable () -> Bool)? = nil) async throws {
        let frame = try MacClient.frameRequest(payload, maximum: maximum)
        let connection = connection
        let diagnosticID = diagnosticID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, canSend?() ?? true else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error { WatchDiagnostics.networkError(error, id: diagnosticID, phase: "send") }
                    continuation.resume(with: error.map { .failure(Self.failure($0)) } ?? .success(()))
                })
            }
        } onCancel: { connection.cancel() }
    }

    func receiveFrame(maximum: Int) async throws -> Data {
        let header = try await receive(exactly: 4)
        let length: Int
        do {
            length = try CompanionFrame.payloadLength(header, maximum: maximum)
        } catch CompanionFrame.Failure.tooLarge {
            throw MacClientFailure.oversizedFrame
        } catch {
            throw MacClientFailure.invalidResponse
        }
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
        let diagnosticID = diagnosticID
        while buffer.count < count {
            try Task.checkCancellation()
            let needed = count - buffer.count
            let received = buffer.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { data, _, isComplete, error in
                    if let error {
                        WatchDiagnostics.networkError(error, id: diagnosticID, phase: "receive")
                        return continuation.resume(throwing: Self.failure(error))
                    }
                    if let data, !data.isEmpty { return continuation.resume(returning: data) }
                    WatchDiagnostics.transport.notice("receive_end transport_id=\(diagnosticID, privacy: .public) eof=\(isComplete) partial=\(received > 0) expected=\(count) actual=\(received)")
                    continuation.resume(throwing: isComplete ? MacClientFailure.closed : MacClientFailure.invalidResponse)
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

func withTimeout<T: Sendable>(_ limit: Duration, phase: String = "api_reply", _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            WatchDiagnostics.transport.notice("timeout phase=\(phase, privacy: .public) limit_ms=\(WatchDiagnostics.milliseconds(limit)) attempt_id=\(WatchDiagnostics.current?.id.uuidString ?? "none", privacy: .public)")
            WatchDiagnostics.current?.end(origin: "transport", phase: phase, reason: "timeout")
            throw MacClientFailure.unreachable
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
