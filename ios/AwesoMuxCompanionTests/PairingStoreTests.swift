import Security
import XCTest
@testable import AwesoMuxCompanion

final class PairingStoreTests: XCTestCase {
    private lazy var defaults: UserDefaults = {
        let suite = "PairingStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }()
    private let macA = Data(repeating: 0xA1, count: 32).base64URLEncodedString
    private let macB = Data(repeating: 0xB2, count: 32).base64URLEncodedString

    func testLegacyPairingMovesToItsMacOnceAndRepeatLoadsChangeNothing() throws {
        let keychain = KeychainFixture()
        let legacy = record(macA)
        try keychain.put(legacy, account: PairingStore.legacyAccount)
        let store = PairingStore(keychain: keychain)

        XCTAssertEqual(try store.loadAll(), [legacy])
        XCTAssertEqual(Set(keychain.stored.keys), [account(macA)])
        XCTAssertEqual(try keychain.record(account(macA)), legacy, "Same identity, connection and routes")

        let writes = keychain.writes
        XCTAssertEqual(try store.loadAll(), [legacy])
        XCTAssertEqual(try store.load(), legacy)
        XCTAssertEqual(keychain.writes, writes, "A finished migration never writes again")
        XCTAssertEqual(Set(keychain.stored.keys), [account(macA)])
    }

    func testFailedOrUnverifiedCopyKeepsLegacyPairingUsableAndRetries() throws {
        for fault in [KeychainFixture.Fault.failWrite, .writeGarbage] {
            let keychain = KeychainFixture()
            let legacy = record(macA)
            try keychain.put(legacy, account: PairingStore.legacyAccount)
            keychain.fault = fault
            let store = PairingStore(keychain: keychain)

            XCTAssertEqual(try store.load(), legacy, "\(fault): the pairing stays usable this launch")
            XCTAssertEqual(try keychain.record(PairingStore.legacyAccount), legacy, "\(fault): legacy item kept")

            keychain.fault = nil
            XCTAssertEqual(try store.loadAll(), [legacy])
            XCTAssertEqual(Set(keychain.stored.keys), [account(macA)], "\(fault): the next load finishes")
            XCTAssertEqual(try keychain.record(account(macA)), legacy)
        }
    }

    func testCopyInterruptedBeforeLegacyDeleteFinishesWithoutDuplicates() throws {
        let keychain = KeychainFixture()
        let legacy = record(macA)
        try keychain.put(legacy, account: PairingStore.legacyAccount)
        keychain.failDeletes = [PairingStore.legacyAccount]
        let store = PairingStore(keychain: keychain)

        XCTAssertEqual(try store.loadAll(), [legacy])
        XCTAssertEqual(Set(keychain.stored.keys), [PairingStore.legacyAccount, account(macA)])
        XCTAssertEqual(try store.loadAll(), [legacy], "Both copies read as one pairing")

        keychain.failDeletes = []
        let writes = keychain.writes
        XCTAssertEqual(try store.loadAll(), [legacy])
        XCTAssertEqual(Set(keychain.stored.keys), [account(macA)])
        XCTAssertEqual(keychain.writes, writes, "Finishing only deletes the verified legacy item")
    }

    func testStaleLegacyNeverOverwritesNewerPairingWithSameMac() throws {
        let keychain = KeychainFixture()
        let stale = record(macA, pairedAt: 100, tag: "old")
        let current = record(macA, pairedAt: 200, tag: "new")
        try keychain.put(stale, account: PairingStore.legacyAccount)
        try keychain.put(current, account: account(macA))

        XCTAssertEqual(try PairingStore(keychain: keychain).loadAll(), [current])
        XCTAssertEqual(Set(keychain.stored.keys), [account(macA)])
        XCTAssertEqual(try keychain.record(account(macA)), current)
    }

    func testNewerLegacyPairingReplacesOlderCopyForSameMac() throws {
        let keychain = KeychainFixture()
        let older = record(macA, pairedAt: 100, tag: "old")
        let newer = record(macA, pairedAt: 200, tag: "new")
        try keychain.put(older, account: account(macA))
        try keychain.put(newer, account: PairingStore.legacyAccount)

        XCTAssertEqual(try PairingStore(keychain: keychain).loadAll(), [newer])
        XCTAssertEqual(Set(keychain.stored.keys), [account(macA)])
        XCTAssertEqual(try keychain.record(account(macA)), newer)
    }

    func testReadFailureThrowsAndTouchesNothing() throws {
        let keychain = KeychainFixture()
        try keychain.put(record(macA), account: PairingStore.legacyAccount)
        let before = keychain.stored
        keychain.fault = .failRead
        let store = PairingStore(keychain: keychain)

        XCTAssertThrowsError(try store.loadAll())
        XCTAssertThrowsError(try store.clear(macFingerprint: macA))
        XCTAssertEqual(keychain.stored, before)
    }

    func testUnreadableLegacyItemStaysUntilAnotherPairingIsSaved() throws {
        let keychain = KeychainFixture()
        keychain.stored[PairingStore.legacyAccount] = Data("not a record".utf8)
        let store = PairingStore(keychain: keychain)

        XCTAssertThrowsError(try store.loadAll()) {
            guard case .invalidItem? = $0 as? PairingStoreFailure else { return XCTFail("\($0)") }
        }
        XCTAssertNotNil(keychain.stored[PairingStore.legacyAccount])

        let fresh = record(macB)
        try store.save(fresh)
        XCTAssertEqual(try store.loadAll(), [fresh])
        XCTAssertEqual(Set(keychain.stored.keys), [account(macB)])
    }

    func testEachMacKeepsItsOwnItemAndClearRemovesOnlyTheNamedMac() throws {
        let keychain = KeychainFixture()
        let a = record(macA, pairedAt: 100, tag: "a")
        let b = record(macB, pairedAt: 200, tag: "b")
        let store = PairingStore(keychain: keychain)
        try store.save(a)
        try store.save(b)

        XCTAssertEqual(try store.loadAll(), [a, b])
        XCTAssertEqual(try store.load(), b, "The single-host app opens the newest pairing")

        try store.clear(macFingerprint: macA)
        XCTAssertEqual(try store.loadAll(), [b])
        XCTAssertEqual(try keychain.record(account(macB)), b, "Another Mac keeps its identity, connection and routes")
    }

    func testClearRemovesUncopiedLegacyItemOnlyForThatMac() throws {
        let keychain = KeychainFixture()
        let legacyA = record(macA, pairedAt: 100, tag: "a")
        let b = record(macB, pairedAt: 200, tag: "b")
        try keychain.put(legacyA, account: PairingStore.legacyAccount)
        try keychain.put(b, account: account(macB))
        let store = PairingStore(keychain: keychain)

        try store.clear(macFingerprint: macB)
        XCTAssertNotNil(keychain.stored[PairingStore.legacyAccount], "Unpairing B never removes A")

        try store.clear(macFingerprint: macA)
        XCTAssertEqual(keychain.stored, [:])
        XCTAssertEqual(try store.loadAll(), [], "An unpaired legacy Mac never comes back")
    }

    func testClearFailureKeepsThePairing() throws {
        let keychain = KeychainFixture()
        let a = record(macA)
        let store = PairingStore(keychain: keychain)
        try store.save(a)
        keychain.failDeletes = [account(macA)]

        XCTAssertThrowsError(try store.clear(macFingerprint: macA))
        XCTAssertEqual(try store.loadAll(), [a])
    }

    func testOnlyCanonicalFingerprintsNameAnItem() throws {
        let store = PairingStore(keychain: KeychainFixture())
        XCTAssertThrowsError(try store.save(record("fixture-pin")))
        XCTAssertThrowsError(try store.save(record(String(macA.dropLast()) + "B")), "Non-zero trailing bits never match the pin")
        XCTAssertNil(PairingStore.account(for: macA + "="))

        let keychain = KeychainFixture()
        try keychain.put(record(macB), account: account(macA))
        XCTAssertThrowsError(try PairingStore(keychain: keychain).loadAll(), "A record under another Mac's item is unusable")
    }

    func testReadFailureAfterCopyKeepsLegacyPairingAndFinishesLater() throws {
        let keychain = KeychainFixture()
        let legacy = record(macA)
        try keychain.put(legacy, account: PairingStore.legacyAccount)
        keychain.fault = .failReadAfterWrite
        let store = PairingStore(keychain: keychain)

        XCTAssertEqual(try store.load(), legacy, "The copy can't be verified, so the legacy item is used as is")
        XCTAssertEqual(try keychain.record(PairingStore.legacyAccount), legacy)

        keychain.fault = nil
        let writes = keychain.writes
        XCTAssertEqual(try store.loadAll(), [legacy])
        XCTAssertEqual(Set(keychain.stored.keys), [account(macA)])
        XCTAssertEqual(keychain.writes, writes, "The copy was already complete, so only the legacy item is deleted")
    }

    /// Pair A, then pair B while A's item can't be deleted, unpair B and relaunch: A must not come back.
    @MainActor
    func testReplacedMacNeverReturnsWhenItsCleanupFails() async throws {
        for storedAs in [account(macA), PairingStore.legacyAccount] {
            let keychain = KeychainFixture()
            let store = PairingStore(keychain: keychain)
            let a = record(macA, pairedAt: 100, tag: "a")
            let b = record(macB, pairedAt: 200, tag: "b")
            try keychain.put(a, account: storedAs)
            keychain.failDeletes = [storedAs]
            let client = PaneClientFixture()
            let defaults = defaults
            let launch = {
                CompanionStore(defaults: defaults, loadPairing: { try store.load() }, makeClient: { _, _ in client },
                               removePairing: { try store.clear(macFingerprint: $0.macFingerprint) },
                               liveActivity: nil, writeShared: { _ in }, clearShared: {})
            }

            XCTAssertTrue(try store.replace(a, with: b), storedAs)
            let paired = launch()
            XCTAssertEqual(paired.record, b, storedAs)
            await paired.unpair()
            XCTAssertNil(paired.record, storedAs)
            XCTAssertNil(paired.message, storedAs)
            XCTAssertNil(launch().record, "\(storedAs): a replaced Mac never comes back")
            XCTAssertEqual(try store.loadAll(), [], storedAs)

            keychain.failDeletes = []
            XCTAssertEqual(try store.loadAll(), [], storedAs)
            XCTAssertEqual(keychain.stored, [:], "\(storedAs): a later load finishes deleting A")
        }
    }

    func testReplacementThatCantRetireThePreviousMacKeepsItWhole() throws {
        let keychain = KeychainFixture()
        let store = PairingStore(keychain: keychain)
        let a = record(macA, pairedAt: 100, tag: "a")
        let b = record(macB, pairedAt: 200, tag: "b")
        try store.save(a)
        keychain.failDeletes = [account(macA)]
        keychain.failWrites = [PairingStore.retiredAccount]

        XCTAssertThrowsError(try store.replace(a, with: b))
        XCTAssertEqual(try store.loadAll(), [a], "B is taken back and A stays in use")
        XCTAssertEqual(try keychain.record(account(macA)), a)

        keychain.failDeletes.insert(account(macB))
        XCTAssertFalse(try store.replace(a, with: b), "B can't be taken back, so it stays and A isn't retired")
        XCTAssertEqual(try store.loadAll(), [a, b])
        XCTAssertEqual(try store.load(), b)
    }

    func testPairingAgainWithAReplacedMacIsNeverHidden() throws {
        let keychain = KeychainFixture()
        let store = PairingStore(keychain: keychain)
        let a = record(macA, pairedAt: 100, tag: "a")
        let b = record(macB, pairedAt: 200, tag: "b")
        try store.save(a)
        keychain.failDeletes = [account(macA)]
        XCTAssertTrue(try store.replace(a, with: b))
        XCTAssertEqual(try store.loadAll(), [b])

        let again = record(macA, pairedAt: 300, tag: "again")
        XCTAssertTrue(try store.replace(b, with: again))
        XCTAssertEqual(try store.loadAll(), [again])
        XCTAssertEqual(Set(keychain.stored.keys), [account(macA)], "Nothing retired is left")
    }

    /// The real Keychain, in a service of its own.
    func testSystemKeychainMigratesAndKeepsThisDeviceOnlyAccess() throws {
        let keychain = SystemPairingKeychain(service: "PairingStoreTests.\(UUID().uuidString)")
        defer { for account in (try? keychain.items().keys).map(Array.init) ?? [] { try? keychain.delete(account: account) } }
        let legacy = record(macA, pairedAt: 100, tag: "a")
        let b = record(macB, pairedAt: 200, tag: "b")
        try keychain.write(JSONEncoder().encode(legacy), account: PairingStore.legacyAccount)
        let store = PairingStore(keychain: keychain)
        try store.save(b)

        XCTAssertEqual(try store.loadAll(), [legacy, b])
        XCTAssertEqual(Set(try keychain.items().keys), [account(macA), account(macB)])
        for account in [account(macA), account(macB)] {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychain.service,
                                          kSecAttrAccount: account, kSecReturnAttributes: true]
            var result: CFTypeRef?
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
            let attributes = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                           kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        }

        try store.clear(macFingerprint: macA)
        XCTAssertEqual(try store.loadAll(), [b])
    }

    private func account(_ fingerprint: String) -> String { PairingStore.account(for: fingerprint)! }

    private func record(_ fingerprint: String, pairedAt: TimeInterval = 1_700_000_000, tag: String = "tag") -> PairingRecord {
        PairingRecord(macName: "Mac \(fingerprint.prefix(4))", host: nil, port: 1234, macFingerprint: fingerprint,
                      transport: nil, routes: [.init(transport: .lan, host: "192.168.1.2"),
                                               .init(transport: .tailscale, host: "100.64.0.2")],
                      connectionID: UUID(), identityTag: "identity-\(tag)", identityStorage: .secureEnclave,
                      pairedAt: Date(timeIntervalSince1970: pairedAt))
    }
}

/// In-memory items with the same account semantics as the Keychain: one item per account, and each fault
/// fails the operation the real Keychain could fail.
private final class KeychainFixture: PairingKeychain, @unchecked Sendable {
    enum Fault { case failRead, failReadAfterWrite, failWrite, writeGarbage }

    var stored: [String: Data] = [:]
    var fault: Fault?
    var failDeletes: Set<String> = []
    var failWrites: Set<String> = []
    private(set) var writes = 0

    func items() throws -> [String: Data] {
        if fault == .failRead || fault == .failReadAfterWrite && writes > 0 {
            throw PairingStoreFailure.keychain(errSecInteractionNotAllowed)
        }
        return stored
    }

    func write(_ data: Data, account: String) throws {
        if fault == .failWrite || failWrites.contains(account) { throw PairingStoreFailure.keychain(errSecIO) }
        writes += 1
        stored[account] = fault == .writeGarbage ? Data("{".utf8) : data
    }

    func delete(account: String) throws {
        if failDeletes.contains(account) { throw PairingStoreFailure.keychain(errSecIO) }
        stored[account] = nil
    }

    func put(_ record: PairingRecord, account: String) throws {
        stored[account] = try JSONEncoder().encode(record)
    }

    func record(_ account: String) throws -> PairingRecord? {
        try stored[account].map { try JSONDecoder().decode(PairingRecord.self, from: $0) }
    }
}
