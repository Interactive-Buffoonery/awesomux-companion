import Foundation

/// The v1 URL shape. Consumers validate endpoint eligibility, names, pins, and secrets locally.
public struct CompanionPairingLink: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let macFingerprint: String
    public let secret: String
    public let macName: String
    public let transport: String

    public static let scheme = "awesomuxcompanion"

    public enum Failure: Error, Equatable {
        case notAPairingLink, unsupportedVersion, malformed
    }

    public init(host: String, port: UInt16, macFingerprint: String, secret: String, macName: String, transport: String) {
        self.host = host
        self.port = port
        self.macFingerprint = macFingerprint
        self.secret = secret
        self.macName = macName
        self.transport = transport
    }

    public init(_ text: String) throws(Failure) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048, let components = URLComponents(string: text),
              components.scheme == Self.scheme, components.host == "pair" else { throw .notAPairingLink }
        guard components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems else { throw .malformed }
        var fields: [String: String] = [:]
        for item in items {
            guard let value = item.value, fields.updateValue(value, forKey: item.name) == nil else { throw .malformed }
        }
        guard fields["v"] == "1" else { throw fields["v"] == nil ? .malformed : .unsupportedVersion }
        guard Set(fields.keys) == ["v", "h", "p", "fp", "s", "n", "t"],
              let host = fields["h"], let portText = fields["p"],
              portText.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(portText), port > 0,
              let fingerprint = fields["fp"], let secret = fields["s"], let name = fields["n"],
              let transport = fields["t"] else { throw .malformed }
        self.init(host: host, port: port, macFingerprint: fingerprint, secret: secret, macName: name, transport: transport)
    }

    public func string() throws(Failure) -> String {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "fp", value: macFingerprint),
            URLQueryItem(name: "s", value: secret),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "t", value: transport),
        ]
        guard let link = components.string else { throw .malformed }
        return link
    }
}
