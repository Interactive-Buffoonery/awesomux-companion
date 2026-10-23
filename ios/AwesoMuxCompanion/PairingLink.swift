import AwesoMuxCompanionProtocol
import Foundation

enum CompanionTransport: String, Codable, Sendable {
    case lan, tailscale

    var title: String {
        switch self {
        case .lan: String(localized: "Local network")
        case .tailscale: String(localized: "Tailscale")
        }
    }
}

/// One address the Mac listens on.
struct CompanionRoute: Codable, Equatable, Sendable {
    let transport: CompanionTransport
    let host: String

    /// Only a dotted-quad IPv4 address in the route's own class: RFC1918 for LAN, 100.64/10 for Tailscale.
    /// The Mac checks which interface owns it; the phone can only check the range.
    static func validated(_ transport: CompanionTransport, _ host: String) -> CompanionRoute? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> UInt8? in
            guard (1...3).contains(part.count), part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || !part.hasPrefix("0") else { return nil }
            return UInt8(part)
        }
        guard parts.count == 4, octets.count == 4 else { return nil }
        let eligible = switch transport {
        case .lan: octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
        case .tailscale: octets[0] == 100 && (64...127).contains(octets[1])
        }
        return eligible ? CompanionRoute(transport: transport, host: host) : nil
    }

    /// LAN first, then Tailscale. Every entry must be valid; a v2 route set has at least one.
    static func routes(_ routes: CompanionRoutes) -> [CompanionRoute]? {
        let candidates: [(CompanionTransport, String?)] = [(.lan, routes.lan), (.tailscale, routes.tailscale)]
        var valid: [CompanionRoute] = []
        for case let (transport, host?) in candidates {
            guard let route = validated(transport, host) else { return nil }
            valid.append(route)
        }
        return routes.v == 2 && !valid.isEmpty ? valid : nil
    }

    /// The reported routes, plus each saved route whose kind the report omits, LAN first. A route the Mac
    /// can't currently see (Tailscale still coming up after wake) keeps its last-known address until reported again.
    static func merged(_ reported: [CompanionRoute], keeping saved: [CompanionRoute]) -> [CompanionRoute] {
        let kept = saved.filter { route in !reported.contains { $0.transport == route.transport } }
        return (reported + kept).sorted { $0.transport == .lan && $1.transport != .lan }
    }
}

/// A v1 link names one route (`h`, `t`); a v2 link carries up to one LAN and one Tailscale route on one port.
struct PairingLink: Equatable, Sendable {
    let version: Int
    /// LAN first.
    let routes: [CompanionRoute]
    let port: UInt16
    /// Base64url SHA-256 of the Mac certificate's SubjectPublicKeyInfo DER.
    let macFingerprint: String
    let secret: String
    let macName: String

    enum Failure: Error, Equatable {
        case notAPairingLink, unsupportedVersion, malformed

        var message: String {
            switch self {
            case .notAPairingLink: String(localized: "That isn't an awesoMux pairing link. On your Mac, open Settings → awesoMux Companion and choose Pair iPhone.")
            case .unsupportedVersion: String(localized: "This pairing link needs a newer version of awesoMux Companion.")
            case .malformed: String(localized: "This pairing link is damaged or incomplete. Choose Pair iPhone on your Mac to make a new one.")
            }
        }
    }

    init(_ text: String) throws(Failure) {
        let routes: [CompanionRoute]?
        let port: UInt16, fingerprint: String, secret: String, name: String
        do {
            do {
                let raw = try CompanionPairingLink(text)
                version = 1
                routes = CompanionTransport(rawValue: raw.transport).flatMap { CompanionRoute.validated($0, raw.host) }.map { [$0] }
                (port, fingerprint, secret, name) = (raw.port, raw.macFingerprint, raw.secret, raw.macName)
            } catch .unsupportedVersion {
                let raw = try CompanionPairingLinkV2(text)
                version = 2
                routes = CompanionRoute.routes(raw.routes)
                (port, fingerprint, secret, name) = (raw.routes.p, raw.macFingerprint, raw.secret, raw.macName)
            }
        } catch {
            switch error {
            case .notAPairingLink: throw .notAPairingLink
            case .unsupportedVersion: throw .unsupportedVersion
            case .malformed: throw .malformed
            }
        }
        guard let routes,
              Data(base64URL: fingerprint)?.count == 32,
              Data(base64URL: secret)?.count == 32,
              !name.isEmpty, name.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw .malformed }
        self.routes = routes
        self.port = port
        macFingerprint = fingerprint
        self.secret = secret
        macName = name
    }
}

extension Data {
    /// Strict base64url without padding, as used throughout the pairing contract.
    init?(base64URL text: String) {
        guard !text.isEmpty, text.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        self.init(base64Encoded: standard)
    }

    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
