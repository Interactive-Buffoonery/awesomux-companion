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
        let fields = try Self.fields(text)
        guard fields["v"] == "1" else { throw fields["v"] == nil ? .malformed : .unsupportedVersion }
        guard Set(fields.keys) == ["v", "h", "p", "fp", "s", "n", "t"],
              let host = fields["h"], let port = fields["p"].flatMap(Self.port),
              let fingerprint = fields["fp"], let secret = fields["s"], let name = fields["n"],
              let transport = fields["t"] else { throw .malformed }
        self.init(host: host, port: port, macFingerprint: fingerprint, secret: secret, macName: name, transport: transport)
    }

    /// The query fields of a `pair` link, rejecting duplicates and anything outside the query.
    static func fields(_ text: String) throws(Failure) -> [String: String] {
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
        return fields
    }

    static func port(_ text: String) -> UInt16? {
        guard text.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(text), port > 0 else { return nil }
        return port
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

/// The v2 URL shape: up to one LAN and one Tailscale IPv4 route sharing a port.
/// Consumers validate route classes, names, pins, and secrets locally.
public struct CompanionPairingLinkV2: Equatable, Sendable {
    public let routes: CompanionRoutes
    public let macFingerprint: String
    public let secret: String
    public let macName: String

    public init(routes: CompanionRoutes, macFingerprint: String, secret: String, macName: String) {
        self.routes = routes
        self.macFingerprint = macFingerprint
        self.secret = secret
        self.macName = macName
    }

    public init(_ text: String) throws(CompanionPairingLink.Failure) {
        let fields = try CompanionPairingLink.fields(text)
        guard fields["v"] == "2" else { throw fields["v"] == nil ? .malformed : .unsupportedVersion }
        let routeKeys = Set(fields.keys).subtracting(["v", "p", "fp", "s", "n"])
        guard routeKeys.isSubset(of: ["lan", "tailscale"]), !routeKeys.isEmpty,
              fields["lan"] != "", fields["tailscale"] != "",
              let port = fields["p"].flatMap(CompanionPairingLink.port),
              let fingerprint = fields["fp"], let secret = fields["s"], let name = fields["n"] else { throw .malformed }
        self.init(routes: CompanionRoutes(p: port, lan: fields["lan"], tailscale: fields["tailscale"]),
                  macFingerprint: fingerprint, secret: secret, macName: name)
    }

    public func string() throws(CompanionPairingLink.Failure) -> String {
        guard routes.v == 2, routes.lan != nil || routes.tailscale != nil else { throw .malformed }
        var components = URLComponents()
        components.scheme = CompanionPairingLink.scheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "v", value: "2")]
            + [("lan", routes.lan), ("tailscale", routes.tailscale)].compactMap { name, value in
                value.map { URLQueryItem(name: name, value: $0) }
            }
            + [
                URLQueryItem(name: "p", value: String(routes.p)),
                URLQueryItem(name: "fp", value: macFingerprint),
                URLQueryItem(name: "s", value: secret),
                URLQueryItem(name: "n", value: macName),
            ]
        guard let link = components.string else { throw .malformed }
        return link
    }
}
