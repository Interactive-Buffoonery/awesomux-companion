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

    /// Pair A, then pair B while A can't be removed (its delete fails, or the app quit first). B opens, unpairing
    /// can't finish while A is stuck, and once it does a relaunch finds nothing: A never comes back.
    @MainActor
    func testReplacedMacNeverReturnsAfterUnpair() async throws {
        for (storedAs, quitBeforeCleanup) in [(account(macA), false), (PairingStore.legacyAccount, false),
                                              (account(macA), true)] {
            let label = "\(storedAs) quit=\(quitBeforeCleanup)"
            let keychain = KeychainFixture()
            let store = PairingStore(keychain: keychain)
            let identities = IdentityFixture()
            let a = record(macA, pairedAt: 100, tag: "a")
            let b = record(macB, pairedAt: 200, tag: "b")
            try keychain.put(a, account: storedAs)
            keychain.failDeletes = [storedAs]

            if quitBeforeCleanup {
                try store.save(b)
            } else {
                XCTAssertFalse(try pairAgain(a, with: b, store: store, identities: identities), label)
            }
            XCTAssertFalse(identities.deleted.contains("identity-a"), "\(label): A's key stays while A does")
            try assertCoherent(store, identities, label)
            XCTAssertEqual(launch(store, identities).record, b, "\(label): relaunch opens the replacement")

            let paired = launch(store, identities)
            await paired.unpair()
            XCTAssertEqual(paired.record, b, "\(label): unpairing can't finish while A is stuck")
            XCTAssertNotNil(paired.message, label)
            XCTAssertEqual(launch(store, identities).record, b, label)
            try assertCoherent(store, identities, label)

            keychain.failDeletes = []
            await paired.unpair()
            XCTAssertNil(paired.record, label)
            XCTAssertNil(paired.message, label)
            XCTAssertNil(launch(store, identities).record, "\(label): a replaced Mac never comes back")
            XCTAssertEqual(keychain.stored, [:], label)
            XCTAssertEqual(identities.deleted, ["identity-a", "identity-b"], label)
        }
    }

    /// An interrupted migration leaves legacy A beside its copy. Pair Again with the same Mac deletes A's key, and
    /// unpairing A2 then fails partway: A2 stays the pairing that opens, and A never comes back.
    @MainActor
    func testPairingAgainWithSameMacNeverRestoresLegacyCopy() async throws {
        for stuck in [PairingStore.legacyAccount, account(macA)] {
            let keychain = KeychainFixture()
            let store = PairingStore(keychain: keychain)
            let identities = IdentityFixture()
            let a = record(macA, pairedAt: 100, tag: "a")
            try keychain.put(a, account: PairingStore.legacyAccount)
            keychain.failDeletes = [PairingStore.legacyAccount]
            XCTAssertEqual(try store.load(), a)
            XCTAssertEqual(Set(keychain.stored.keys), [PairingStore.legacyAccount, account(macA)], stuck)

            let a2 = record(macA, pairedAt: 200, tag: "a2")
            XCTAssertTrue(try pairAgain(a, with: a2, store: store, identities: identities), stuck)
            XCTAssertEqual(identities.deleted, ["identity-a"], stuck)
            try assertCoherent(store, identities, stuck)

            keychain.failDeletes = [stuck]
            let paired = launch(store, identities)
            XCTAssertEqual(paired.record, a2, stuck)
            await paired.unpair()
            XCTAssertEqual(paired.record, a2, "\(stuck): unpairing fails and keeps A2")
            XCTAssertNotNil(paired.message, stuck)
            XCTAssertEqual(launch(store, identities).record, a2, "\(stuck): never the old legacy copy")
            try assertCoherent(store, identities, stuck)

            keychain.failDeletes = []
            await paired.unpair()
            XCTAssertNil(launch(store, identities).record, stuck)
            XCTAssertEqual(keychain.stored, [:], stuck)
        }
    }

    func testClearKeepsNewerLegacyCopyUntilItsOlderItemIsGone() throws {
        let keychain = KeychainFixture()
        let older = record(macA, pairedAt: 100, tag: "old")
        let newer = record(macA, pairedAt: 200, tag: "new")
        try keychain.put(older, account: account(macA))
        try keychain.put(newer, account: PairingStore.legacyAccount)
        keychain.failDeletes = [account(macA)]
        let store = PairingStore(keychain: keychain)

        XCTAssertThrowsError(try store.clear(macFingerprint: macA))
        XCTAssertEqual(try store.load(), newer, "The older item goes first, so a failure never leaves only it")
    }

    func testFailedSaveKeepsThePreviousPairing() throws {
        let keychain = KeychainFixture()
        let store = PairingStore(keychain: keychain)
        let identities = IdentityFixture()
        let a = record(macA, pairedAt: 100, tag: "a")
        try store.save(a)
        keychain.failWrites = [account(macB)]

        XCTAssertThrowsError(try pairAgain(a, with: record(macB, pairedAt: 200, tag: "b"), store: store,
                                           identities: identities))
        XCTAssertEqual(identities.deleted, ["identity-b"], "Only the unsaved pairing's key is deleted")
        XCTAssertEqual(try store.loadAll(), [a])
        try assertCoherent(store, identities, "failed save")
    }

    @MainActor
    func testReplacementRecoversSavedPairingAfterInitialReadFailure() throws {
        let keychain = KeychainFixture()
        let store = PairingStore(keychain: keychain)
        let identities = IdentityFixture()
        let a = record(macA, pairedAt: 200, tag: "a")
        try store.save(a)
        keychain.fault = .failRead
        let launched = launch(store, identities)
        XCTAssertNil(launched.record)

        let before = keychain.stored
        XCTAssertThrowsError(try store.replacementContext(current: launched.record,
                                                         now: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(keychain.stored, before)

        keychain.fault = nil
        let context = try store.replacementContext(current: launched.record,
                                                    now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(context.previous, a)
        XCTAssertGreaterThan(context.pairedAt, a.pairedAt)
        let b = record(macB, pairedAt: context.pairedAt.timeIntervalSince1970, tag: "b")
        keychain.failDeletes = [account(macA)]
        XCTAssertFalse(try pairAgain(try XCTUnwrap(context.previous), with: b, store: store,
                                     identities: identities))
        XCTAssertEqual(launch(store, identities).record, b)
        try assertCoherent(store, identities, "read recovery with clock behind")
    }

    @MainActor
    func testPairAgainRecoversWhenStoredPairingCannotDecode() throws {
        let keychain = KeychainFixture()
        let store = PairingStore(keychain: keychain)
        let identities = IdentityFixture()
        keychain.stored[PairingStore.legacyAccount] = Data("not a pairing".utf8)
        let launched = launch(store, identities)
        XCTAssertNil(launched.record)
        XCTAssertThrowsError(try store.load())

        let context = try store.replacementContext(current: launched.record,
                                                    now: Date(timeIntervalSince1970: 100))
        XCTAssertNil(context.previous)
        let b = record(macB, pairedAt: context.pairedAt.timeIntervalSince1970, tag: "b")
        XCTAssertTrue(try store.replace(context.previous, with: b))
        XCTAssertEqual(launch(store, identities).record, b)
        try assertCoherent(store, identities, "pair again after unreadable data")
    }

    func testPairingAgainWithASupersededMacReplacesIt() throws {
        let keychain = KeychainFixture()
        let store = PairingStore(keychain: keychain)
        let a = record(macA, pairedAt: 100, tag: "a")
        let b = record(macB, pairedAt: 200, tag: "b")
        try store.save(a)
        keychain.failDeletes = [account(macA)]
        XCTAssertFalse(try store.replace(a, with: b))
        XCTAssertEqual(try store.load(), b)

        keychain.failDeletes = []
        let again = record(macA, pairedAt: 300, tag: "again")
        XCTAssertTrue(try store.replace(b, with: again))
        XCTAssertEqual(try store.loadAll(), [again])
        XCTAssertEqual(Set(keychain.stored.keys), [account(macA)])
    }

    func testUnpairRetryFinishesAfterOnlyTheKeyWasLeft() throws {
        let keychain = KeychainFixture()
        let store = PairingStore(keychain: keychain)
        let a = record(macA, tag: "a")
        try store.save(a)

        XCTAssertThrowsError(try store.clearAll(current: a) { _ in throw PairingStoreFailure.keychain(errSecIO) })
        XCTAssertEqual(keychain.stored, [:])
        keychain.stored["mac:unreadable"] = Data("{".utf8)
        var deleted: [String] = []
        try store.clearAll(current: a) { deleted.append($0) }
        XCTAssertEqual(deleted, ["identity-a"], "Unreadable leftovers don't block finishing")
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

    /// What `CompanionStore.pair` does once the Mac allows it: `pair()` itself needs a live Mac and the system
    /// Keychain, so this mirrors its commit step. A failed save deletes the new key; `previous`'s key is deleted
    /// only once it's gone.
    private func pairAgain(_ previous: PairingRecord, with next: PairingRecord, store: PairingStore,
                           identities: IdentityFixture) throws -> Bool {
        let previousGone: Bool
        do {
            previousGone = try store.replace(previous, with: next)
        } catch {
            identities.deleted.insert(next.identityTag)
            throw error
        }
        if previousGone { identities.deleted.insert(previous.identityTag) }
        return previousGone
    }

    /// The app as launched, with the production unpair removal and a fixture in place of the identity Keychain.
    @MainActor
    private func launch(_ store: PairingStore, _ identities: IdentityFixture) -> CompanionStore {
        let client = PaneClientFixture()
        return CompanionStore(defaults: defaults, loadPairing: { try store.load() }, makeClient: { _, _ in client },
                              removePairing: { try store.clearAll(current: $0) { identities.deleted.insert($0) } },
                              liveActivity: nil, writeShared: { _ in }, clearShared: {})
    }

    /// Nothing that can open names a deleted key.
    private func assertCoherent(_ store: PairingStore, _ identities: IdentityFixture, _ label: String,
                                line: UInt = #line) throws {
        for record in try store.loadAll() {
            XCTAssertFalse(identities.deleted.contains(record.identityTag), "\(label): \(record.identityTag)", line: line)
        }
    }

    private func record(_ fingerprint: String, pairedAt: TimeInterval = 1_700_000_000, tag: String = "tag") -> PairingRecord {
        PairingRecord(macName: "Mac \(fingerprint.prefix(4))", host: nil, port: 1234, macFingerprint: fingerprint,
                      transport: nil, routes: [.init(transport: .lan, host: "192.168.1.2"),
                                               .init(transport: .tailscale, host: "100.64.0.2")],
                      connectionID: UUID(), identityTag: "identity-\(tag)", identityStorage: .secureEnclave,
                      pairedAt: Date(timeIntervalSince1970: pairedAt))
    }
}

private final class IdentityFixture: @unchecked Sendable {
    var deleted: Set<String> = []
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
