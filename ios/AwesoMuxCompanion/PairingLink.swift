import AwesoMuxCompanionProtocol
import Foundation
import Network

enum CompanionTransport: String, Codable, Sendable {
    case lan, tailscale

    var title: String {
        switch self {
        case .lan: String(localized: "Local network")
        case .tailscale: String(localized: "Tailscale")
        }
    }
}

/// `awesomuxcompanion://pair?v=1&h=<IPv4>&p=<port>&fp=<macFP>&s=<secret>&n=<macName>&t=<lan|tailscale>`
struct PairingLink: Equatable, Sendable {
    let host: String
    let port: UInt16
    /// Base64url SHA-256 of the Mac certificate's SubjectPublicKeyInfo DER.
    let macFingerprint: String
    let secret: String
    let macName: String
    let transport: CompanionTransport

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

    static let scheme = CompanionPairingLink.scheme

    init(_ text: String) throws(Failure) {
        let raw: CompanionPairingLink
        do {
            raw = try CompanionPairingLink(text)
        } catch {
            switch error {
            case .notAPairingLink: throw .notAPairingLink
            case .unsupportedVersion: throw .unsupportedVersion
            case .malformed: throw .malformed
            }
        }
        let host = raw.host
        let fingerprint = raw.macFingerprint
        let secret = raw.secret
        let name = raw.macName
        guard IPv4Address(host) != nil, !host.hasPrefix("0."),
              Data(base64URL: fingerprint)?.count == 32,
              Data(base64URL: secret)?.count == 32,
              !name.isEmpty, name.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let transport = CompanionTransport(rawValue: raw.transport) else { throw .malformed }
        self.host = host
        self.port = raw.port
        macFingerprint = fingerprint
        self.secret = secret
        macName = name
        self.transport = transport
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
