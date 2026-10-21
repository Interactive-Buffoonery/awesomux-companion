import Foundation
import Security

/// What the phone keeps after a successful pairing. Stored as one Keychain item, this device only.
struct PairingRecord: Codable, Equatable, Sendable {
    let macName: String
    /// v1 pairings: the one route the grant allows.
    var host: String?
    let port: UInt16
    let macFingerprint: String
    var transport: CompanionTransport?
    /// v2 pairings, LAN first. The Mac may replace these through connection status; v1 pairings never gain any.
    var routes: [CompanionRoute]?
    let connectionID: UUID
    let identityTag: String
    let identityStorage: PhoneIdentity.Storage
    let pairedAt: Date

    var allRoutes: [CompanionRoute] {
        if let routes { return routes }
        guard let host, let transport else { return [] }
        return [CompanionRoute(transport: transport, host: host)]
    }
}

enum PairingStoreFailure: Error { case keychain(OSStatus), invalidItem }

enum PairingStore {
    private static var query: [CFString: Any] { [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.interactivebuffoonery.awesomux.companion.pairing",
        kSecAttrAccount: "mac",
        kSecAttrSynchronizable: false,
    ] }

    static func load() throws -> PairingRecord? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PairingStoreFailure.keychain(status) }
        guard let data = result as? Data, data.count <= 4096,
              let record = try? JSONDecoder().decode(PairingRecord.self, from: data) else { throw PairingStoreFailure.invalidItem }
        return record
    }

    static func save(_ record: PairingRecord) throws {
        let data = try JSONEncoder().encode(record)
        // After first unlock so background refresh can still read it while the phone is locked.
        let attributes: [CFString: Any] = [kSecValueData: data,
                                           kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PairingStoreFailure.keychain(status) }
    }

    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingStoreFailure.keychain(status) }
    }
}
