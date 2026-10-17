import Foundation
import Security

struct ConnectionConfiguration: Codable, Equatable, Sendable {
    let endpoint: String
    let token: String

    func validatedURL() throws -> URL {
        guard endpoint == endpoint.lowercased(), !endpoint.contains("%"),
              let components = URLComponents(string: endpoint), components.scheme == "https",
              let host = components.host, host.utf8.count <= 253,
              let port = components.port, [8443, 10000].contains(port),
              components.user == nil, components.password == nil, components.path.isEmpty,
              components.query == nil, components.fragment == nil,
              token.utf8.count >= 32, token.utf8.count <= 128,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw BridgeFailure.invalidConfiguration }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 4, labels.suffix(2) == ["ts", "net"],
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                  && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), endpoint == "https://\(host):\(port)", let url = components.url else { throw BridgeFailure.invalidConfiguration }
        return url
    }
    var hostLabel: String { URLComponents(string: endpoint)?.host ?? "Unavailable host" }
}

@MainActor protocol HostCredentialStorage {
    func load() throws -> ConnectionConfiguration?
    func save(_ configuration: ConnectionConfiguration) throws
    func clear() throws
}

#if DEBUG && targetEnvironment(simulator)
@MainActor final class InMemoryHostCredentialStore: HostCredentialStorage {
    private var configuration: ConnectionConfiguration?
    func load() throws -> ConnectionConfiguration? { configuration }
    func save(_ configuration: ConnectionConfiguration) throws {
        _ = try configuration.validatedURL()
        self.configuration = configuration
    }
    func clear() throws { configuration = nil }
}
#else
enum CredentialStorageFailure: Error { case keychain(OSStatus), invalidItem }

@MainActor final class HostCredentialStore: HostCredentialStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.interactivebuffoonery.awesomux.companion.host",
         kSecAttrAccount as String: "managed-host",
         kSecAttrSynchronizable as String: false]
    }
    func load() throws -> ConnectionConfiguration? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStorageFailure.keychain(status) }
        guard let data = result as? Data, data.count <= 4096,
              let configuration = try? JSONDecoder().decode(ConnectionConfiguration.self, from: data),
              (try? configuration.validatedURL()) != nil else { throw CredentialStorageFailure.invalidItem }
        return configuration
    }
    func save(_ configuration: ConnectionConfiguration) throws {
        _ = try configuration.validatedURL()
        let data = try JSONEncoder().encode(configuration)
        guard data.count <= 4096 else { throw CredentialStorageFailure.invalidItem }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStorageFailure.keychain(status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStorageFailure.keychain(status) }
    }
}
#endif
