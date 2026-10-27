import Foundation
import Security

/// What the phone keeps after a successful pairing. Stored as one Keychain item per Mac, this device only.
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

/// Generic password items in one service, by account. Tests swap in a fixture to fail reads, writes and deletes.
protocol PairingKeychain: Sendable {
    func items() throws -> [String: Data]
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

struct SystemPairingKeychain: PairingKeychain {
    var service = "com.interactivebuffoonery.awesomux.companion.pairing"

    private var query: [CFString: Any] { [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrSynchronizable: false,
    ] }

    func items() throws -> [String: Data] {
        var query = query
        query[kSecReturnAttributes] = true
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw PairingStoreFailure.keychain(status) }
        guard let found = result as? [[String: Any]] else { throw PairingStoreFailure.invalidItem }
        var items: [String: Data] = [:]
        for item in found {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            items[account] = item[kSecValueData as String] as? Data ?? Data()
        }
        return items
    }

    func write(_ data: Data, account: String) throws {
        var query = query
        query[kSecAttrAccount] = account
        // After first unlock so background refresh can still read it while the phone is locked.
        let attributes: [CFString: Any] = [kSecValueData: data,
                                           kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PairingStoreFailure.keychain(status) }
    }

    func delete(account: String) throws {
        var query = query
        query[kSecAttrAccount] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingStoreFailure.keychain(status) }
    }
}

/// One Keychain item per Mac, keyed by its pinned fingerprint. Earlier builds kept a single item under `mac`;
/// loading copies it to its Mac's item and deletes it only once the copy reads back unchanged.
/// `retired` lists the connections of replaced pairings whose items couldn't be deleted yet; loading hides them.
struct PairingStore: Sendable {
    static let system = PairingStore(keychain: SystemPairingKeychain())
    static let legacyAccount = "mac"
    static let retiredAccount = "retired"

    let keychain: any PairingKeychain

    /// Nil unless the fingerprint is the canonical encoding the TLS pin compares against.
    static func account(for macFingerprint: String) -> String? {
        guard let pin = Data(base64URL: macFingerprint), pin.count == 32,
              pin.base64URLEncodedString == macFingerprint else { return nil }
        return "mac:" + macFingerprint
    }

    /// The newest pairing, for the single-host app.
    func load() throws -> PairingRecord? {
        try loadAll().last
    }

    /// Oldest pairing first. Throws when the Keychain can't be read, or when nothing stored is usable.
    func loadAll() throws -> [PairingRecord] {
        let items = try keychain.items()
        let retired = Self.retired(in: items)
        var records: [String: PairingRecord] = [:]
        var unusable = false
        for (account, data) in items where account != Self.legacyAccount && account != Self.retiredAccount {
            guard let record = Self.decode(data), Self.account(for: record.macFingerprint) == account else {
                unusable = true
                continue
            }
            if !retired.contains(record.connectionID) { records[account] = record }
        }
        if let data = items[Self.legacyAccount] {
            if let legacy = Self.decode(data), let account = Self.account(for: legacy.macFingerprint) {
                if let current = records[account], current.pairedAt >= legacy.pairedAt {
                    // Already copied, or a newer pairing with the same Mac replaced it.
                    try? keychain.delete(account: Self.legacyAccount)
                } else if !retired.contains(legacy.connectionID) {
                    // Used as is when the copy fails; the next load tries again.
                    records[account] = legacy
                    try? migrate(legacy, to: account)
                }
            } else if records.isEmpty {
                unusable = true
            } else {
                // A usable pairing exists, so the unreadable one is superseded, as saving over it once did.
                try? keychain.delete(account: Self.legacyAccount)
            }
        }
        if !retired.isEmpty { finishRetiring(retired) }
        if records.isEmpty, unusable { throw PairingStoreFailure.invalidItem }
        return records.values.sorted { ($0.pairedAt, $0.macFingerprint) < ($1.pairedAt, $1.macFingerprint) }
    }

    /// Replaces only the pairing with this record's Mac.
    func save(_ record: PairingRecord) throws {
        guard let account = Self.account(for: record.macFingerprint) else { throw PairingStoreFailure.invalidItem }
        try keychain.write(JSONEncoder().encode(record), account: account)
    }

    /// Saves `next` in place of `previous`, and throws having changed nothing when that can't be done safely.
    /// Returns false only when `previous`, with another Mac, couldn't be retired and `next` couldn't be taken back:
    /// both stay whole and `next`, the newest, opens.
    func replace(_ previous: PairingRecord?, with next: PairingRecord) throws -> Bool {
        try save(next)
        // ponytail: pairing another Mac still replaces the previous one; multi-host adds it alongside instead.
        guard let previous, previous.macFingerprint != next.macFingerprint else { return true }
        do {
            try retire(previous)
            return true
        } catch {
            guard let account = Self.account(for: next.macFingerprint), (try? keychain.delete(account: account)) != nil
            else { return false }
            throw error
        }
    }

    /// Removes only this Mac's pairing, including a legacy item for it that hasn't been copied yet.
    func clear(macFingerprint: String) throws {
        let legacy = try keychain.items()[Self.legacyAccount].flatMap(Self.decode)
        if let account = Self.account(for: macFingerprint) { try keychain.delete(account: account) }
        if legacy?.macFingerprint == macFingerprint { try keychain.delete(account: Self.legacyAccount) }
    }

    /// Deletes a replaced pairing. If that fails, records it as retired so it never opens again.
    private func retire(_ record: PairingRecord) throws {
        guard (try? clear(macFingerprint: record.macFingerprint)) == nil else { return }
        let retired = try Self.retired(in: keychain.items()).union([record.connectionID])
        try keychain.write(JSONEncoder().encode(retired), account: Self.retiredAccount)
    }

    /// Deletes what's left of retired pairings, and forgets each one once nothing of it remains.
    private func finishRetiring(_ retired: Set<UUID>) {
        guard let items = try? keychain.items() else { return }
        var left: Set<UUID> = []
        for (account, data) in items where account != Self.retiredAccount {
            guard let record = Self.decode(data), retired.contains(record.connectionID) else { continue }
            if (try? keychain.delete(account: account)) == nil { left.insert(record.connectionID) }
        }
        guard left != retired else { return }
        if left.isEmpty {
            try? keychain.delete(account: Self.retiredAccount)
        } else {
            try? keychain.write(JSONEncoder().encode(left), account: Self.retiredAccount)
        }
    }

    private static func retired(in items: [String: Data]) -> Set<UUID> {
        items[retiredAccount].flatMap { try? JSONDecoder().decode(Set<UUID>.self, from: $0) } ?? []
    }

    private func migrate(_ legacy: PairingRecord, to account: String) throws {
        try keychain.write(JSONEncoder().encode(legacy), account: account)
        guard try keychain.items()[account].flatMap(Self.decode) == legacy else { throw PairingStoreFailure.invalidItem }
        try keychain.delete(account: Self.legacyAccount)
    }

    private static func decode(_ data: Data) -> PairingRecord? {
        guard data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(PairingRecord.self, from: data)
    }
}
