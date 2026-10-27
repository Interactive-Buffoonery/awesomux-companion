import AwesoMuxCompanionProtocol
import Foundation
import Network
import os

/// Diagnostic state only: never participates in stream ownership or retry decisions.
final class WatchDiagnostics: Sendable {
    static let watch = Logger(subsystem: "com.interactivebuffoonery.awesomux.companion", category: "watch")
    static let transport = Logger(subsystem: "com.interactivebuffoonery.awesomux.companion", category: "transport")
    static let renderer = Logger(subsystem: "com.interactivebuffoonery.awesomux.companion", category: "renderer")
    static let input = Logger(subsystem: "com.interactivebuffoonery.awesomux.companion", category: "input")
    static let lifecycle = Logger(subsystem: "com.interactivebuffoonery.awesomux.companion", category: "lifecycle")
    static let routing = Logger(subsystem: "com.interactivebuffoonery.awesomux.companion", category: "routing")
    @TaskLocal static var current: WatchDiagnostics?

    let id = UUID()
    let started = ContinuousClock.now
    private struct State {
        var ended = false
        var frames = 0
        var bytes = 0
        var generation: UInt32 = 0
        var lastFrame: ContinuousClock.Instant?
        var lastHeartbeat: ContinuousClock.Instant?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }

    func received(_ packet: WatchPacket) {
        state.withLock {
            $0.frames += 1
            $0.generation = packet.generation
            $0.lastFrame = .now
            switch packet.frame {
            case .snapshot(_, let bytes), .output(_, let bytes): $0.bytes += bytes.count
            case .heartbeat: $0.lastHeartbeat = .now
            default: break
            }
        }
    }

    /// The first caller records the initiating cause before cancellation callbacks run.
    func end(origin: String, phase: String, reason: String) {
        let snapshot = state.withLock { value -> State? in
            guard !value.ended else { return nil }
            value.ended = true
            return value
        }
        guard let snapshot else { return }
        let now = ContinuousClock.now
        let frameAge = snapshot.lastFrame.map { Self.milliseconds(now - $0) } ?? -1
        let heartbeatAge = snapshot.lastHeartbeat.map { Self.milliseconds(now - $0) } ?? -1
        Self.watch.notice("watch_end attempt_id=\(self.id, privacy: .public) origin=\(origin, privacy: .public) phase=\(phase, privacy: .public) reason=\(reason, privacy: .public) elapsed_ms=\(Self.milliseconds(now - self.started)) generation=\(snapshot.generation) frames=\(snapshot.frames) data_bytes=\(snapshot.bytes) last_frame_ms=\(frameAge) last_heartbeat_ms=\(heartbeatAge)")
    }

    static func reason(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? WatchTerminalFailure { return String(describing: error) }
        if let error = error as? WatchFailure { return String(describing: error) }
        if let error = error as? MacClientFailure {
            switch error {
            case .api: return "api_rejected"
            case .unreachable: return "unreachable"
            case .handshakeRejected: return "handshake_rejected"
            case .closed: return "closed"
            case .invalidResponse: return "invalid_response"
            case .oversizedFrame: return "oversized_frame"
            case .denied: return "denied"
            }
        }
        if error is CompanionTerminalStream.Failure { return "stream_codec" }
        return "unclassified"
    }

    static func networkError(_ error: NWError, id: UUID, phase: String) {
        let kind: String
        let code: Int32
        switch error {
        case .posix(let value): kind = "posix"; code = value.rawValue
        case .dns(let value): kind = "dns"; code = value
        case .tls(let value): kind = "tls"; code = value
        @unknown default: kind = "unknown"; code = 0
        }
        transport.error("network_error transport_id=\(id, privacy: .public) phase=\(phase, privacy: .public) kind=\(kind, privacy: .public) code=\(code)")
    }
}
