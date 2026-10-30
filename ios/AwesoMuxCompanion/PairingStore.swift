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
/// The single-host app opens the newest pairing; any older one is superseded and removed before it on unpair.
struct PairingStore: Sendable {
    static let system = PairingStore(keychain: SystemPairingKeychain())
    static let legacyAccount = "mac"

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
        try loadAll(allowUnusable: false)
    }

    private func loadAll(allowUnusable: Bool) throws -> [PairingRecord] {
        let items = try keychain.items()
        var records: [String: PairingRecord] = [:]
        var unusable = false
        for (account, data) in items where account != Self.legacyAccount {
            guard let record = Self.decode(data), Self.account(for: record.macFingerprint) == account else {
                unusable = true
                continue
            }
            records[account] = record
        }
        if let data = items[Self.legacyAccount] {
            if let legacy = Self.decode(data), let account = Self.account(for: legacy.macFingerprint) {
                if let current = records[account], current.pairedAt >= legacy.pairedAt {
                    // Already copied, or a newer pairing with the same Mac replaced it.
                    try? keychain.delete(account: Self.legacyAccount)
                } else {
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
        if records.isEmpty, unusable, !allowUnusable { throw PairingStoreFailure.invalidItem }
        return records.values.sorted { ($0.pairedAt, $0.macFingerprint) < ($1.pairedAt, $1.macFingerprint) }
    }

    /// Replaces only the pairing with this record's Mac.
    func save(_ record: PairingRecord) throws {
        guard let account = Self.account(for: record.macFingerprint) else { throw PairingStoreFailure.invalidItem }
        try keychain.write(JSONEncoder().encode(record), account: account)
    }

    func replacementContext(current: PairingRecord?, now: Date = .now) throws
        -> (previous: PairingRecord?, pairedAt: Date) {
        let previous = try current ?? loadAll(allowUnusable: true).last
        return (previous, max(now, previous?.pairedAt.addingTimeInterval(1) ?? .distantPast))
    }

    /// Saves `next`, which as the newest pairing is the one that opens from then on, and throws having changed
    /// nothing if it can't. Returns true once `previous` is gone, so its identity can be deleted; otherwise it
    /// stays whole but superseded until unpairing removes it.
    func replace(_ previous: PairingRecord?, with next: PairingRecord) throws -> Bool {
        try save(next)
        guard let previous else { return true }
        // The save overwrote it; a leftover legacy copy is older, so it never opens and clearing removes it first.
        if previous.macFingerprint == next.macFingerprint { return true }
        // ponytail: pairing another Mac still replaces the previous one; multi-host adds it alongside instead.
        return (try? clear(macFingerprint: previous.macFingerprint)) != nil
    }

    /// Removes only this Mac's pairing, including a legacy item for it that hasn't been copied yet.
    func clear(macFingerprint: String) throws {
        let items = try keychain.items()
        var accounts = Self.account(for: macFingerprint).map { [$0] } ?? []
        if let legacy = items[Self.legacyAccount].flatMap(Self.decode), legacy.macFingerprint == macFingerprint {
            // The item loading would open goes last, so a failed delete never leaves an older pairing in its place.
            let legacyOpens = accounts.first.flatMap { items[$0] }.flatMap(Self.decode)
                .map { $0.pairedAt < legacy.pairedAt } ?? true
            accounts.insert(Self.legacyAccount, at: legacyOpens ? accounts.count : 0)
        }
        for account in accounts { try keychain.delete(account: account) }
    }

    /// Unpairing in the single-host app: removes every pairing, `current` last, so a failure leaves `current` the
    /// one that opens. Each identity is deleted only after its pairing is gone.
    func clearAll(current: PairingRecord, deletingIdentity deleteIdentity: (String) throws -> Void) throws {
        let others: [PairingRecord]
        do { others = try loadAll() } catch PairingStoreFailure.invalidItem { others = [] }
        for other in others where other.macFingerprint != current.macFingerprint {
            try clear(macFingerprint: other.macFingerprint)
            try? deleteIdentity(other.identityTag)
        }
        try clear(macFingerprint: current.macFingerprint)
        try deleteIdentity(current.identityTag)
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
