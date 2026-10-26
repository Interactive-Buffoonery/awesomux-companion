import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class SessionSnapshotCacheTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "SessionSnapshotCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    func testSaveRestoresSnapshotUnchanged() async {
        await withDefaults { defaults in
            let record = pairing()
            let original = snapshot()
            SessionSnapshotCache(defaults: defaults).save(original, for: record)

            let restored = SessionSnapshotCache(defaults: defaults).restore(for: record)

            XCTAssertEqual(restored, original)
            XCTAssertEqual(restored?.agents.first?.workspaceName, "Cached workspace")
            XCTAssertEqual(restored?.updatedAt, original.updatedAt)
        }
    }

    func testChangedConnectionOrFingerprintCannotRestoreSameNamedMac() async {
        await withDefaults { defaults in
            let record = pairing()
            let cache = SessionSnapshotCache(defaults: defaults)
            for replacement in [pairing(connectionID: UUID()), pairing(fingerprint: "another-pin")] {
                cache.save(snapshot(), for: record)
                XCTAssertNil(cache.restore(for: replacement))
                XCTAssertNil(cache.restore(for: record), "A mismatch must discard the old entry")
            }
        }
    }

    func testMissingPairingDiscardsCache() async {
        await withDefaults { defaults in
            let record = pairing()
            let cache = SessionSnapshotCache(defaults: defaults)
            cache.save(snapshot(), for: record)
            XCTAssertNil(cache.restore(for: nil))
            XCTAssertNil(cache.restore(for: record))
        }
    }

    func testCorruptAndUnsupportedEntriesAreDiscarded() async throws {
        try await withDefaults { defaults in
            let record = pairing()
            let cache = SessionSnapshotCache(defaults: defaults)
            cache.save(snapshot(), for: record)
            let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("pairedSessionSnapshot.") })
            defaults.set(Data("invalid".utf8), forKey: key)
            XCTAssertNil(cache.restore(for: record))
            XCTAssertNil(defaults.data(forKey: key))

            let unsupported = GlanceSnapshot(schemaVersion: 2, hostName: record.macName, connected: true,
                                            error: nil, updatedAt: nil, agents: [])
            cache.save(unsupported, for: record)
            XCTAssertNil(cache.restore(for: record))
            XCTAssertNil(defaults.data(forKey: key))
        }
    }

    func testStoreRestoresImmediatelyThenReplacesAndPersistsSuccessfulRead() async {
        await withDefaults { defaults in
            let record = pairing()
            let cache = SessionSnapshotCache(defaults: defaults)
            cache.save(snapshot(), for: record)
            let client = SessionClientStub()
            let store = self.store(defaults: defaults, record: record, client: client)
            XCTAssertEqual(store.snapshot, snapshot())
            XCTAssertTrue(store.isSnapshotCached)
            XCTAssertFalse(store.reachable)
            XCTAssertFalse(store.isConnected)

            await store.refresh()

            XCTAssertTrue(store.reachable)
            XCTAssertTrue(store.isConnected)
            XCTAssertFalse(store.isSnapshotCached)
            XCTAssertEqual(store.snapshot?.agents.first?.workspaceName, "Live workspace")
            let relaunched = self.store(defaults: defaults, record: record, client: client)
            XCTAssertEqual(relaunched.snapshot, store.snapshot)
            XCTAssertTrue(relaunched.isSnapshotCached)
            XCTAssertFalse(relaunched.isConnected)
        }
    }

    func testUnchangedRosterPersistsLatestReadTimestamp() async {
        await withDefaults { defaults in
            let record = pairing()
            let client = SessionClientStub()
            let store = self.store(defaults: defaults, record: record, client: client)
            await store.refresh()
            let first = store.snapshot
            let later = Date(timeIntervalSince1970: 1_700_000_200)
            await client.setCapturedAt(later)

            await store.refresh()

            XCTAssertEqual(store.snapshot?.agents, first?.agents)
            XCTAssertEqual(store.snapshot?.updatedAt, later)
            XCTAssertEqual(SessionSnapshotCache(defaults: defaults).restore(for: record)?.updatedAt, later)
        }
    }

    func testAgentRefreshPreservesNotificationSelectionUntilPaneRosterArrives() async {
        await withDefaults { defaults in
            let record = pairing()
            SessionSnapshotCache(defaults: defaults).save(snapshot(), for: record)
            let store = self.store(defaults: defaults, record: record, client: SessionClientStub())
            store.focusedPaneID = "exited-pane"
            XCTAssertTrue(store.isSnapshotCached)
            XCTAssertEqual(store.focusedPaneID, "exited-pane")

            await store.refresh()
            XCTAssertEqual(store.focusedPaneID, "exited-pane")

            store.focusedPaneID = "pane"
            await store.refresh()
            XCTAssertEqual(store.focusedPaneID, "pane")
        }
    }

    func testRouteMetadataChangePreservesSamePairingCache() async {
        await withDefaults { defaults in
            let original = pairing()
            let updated = PairingRecord(macName: original.macName, host: "new-route.invalid", port: 4321,
                                        macFingerprint: original.macFingerprint, transport: .tailscale,
                                        connectionID: original.connectionID, identityTag: original.identityTag,
                                        identityStorage: original.identityStorage, pairedAt: original.pairedAt)
            SessionSnapshotCache(defaults: defaults).save(snapshot(), for: original)
            let store = self.store(defaults: defaults, record: updated, client: SessionClientStub())
            XCTAssertEqual(store.snapshot, snapshot())
            XCTAssertTrue(store.isSnapshotCached)
        }
    }

    func testStoreFailedReadKeepsCacheUnconfirmed() async {
        await withDefaults { defaults in
            let record = pairing()
            SessionSnapshotCache(defaults: defaults).save(snapshot(), for: record)
            let client = SessionClientStub(fails: true)
            let store = self.store(defaults: defaults, record: record, client: client)
            await store.refresh()
            XCTAssertEqual(store.snapshot, snapshot())
            XCTAssertTrue(store.isSnapshotCached)
            XCTAssertFalse(store.reachable)
            XCTAssertNotNil(store.message)
        }
    }

    func testStoreWithoutMatchingPairingNeverShowsCachedList() async {
        await withDefaults { defaults in
            let record = pairing()
            let cache = SessionSnapshotCache(defaults: defaults)
            for replacement in [nil, pairing(connectionID: UUID()), pairing(fingerprint: "another-pin")] {
                cache.save(snapshot(), for: record)
                let store = self.store(defaults: defaults, record: replacement, client: SessionClientStub())
                XCTAssertNil(store.snapshot)
                XCTAssertFalse(store.isSnapshotCached)
            }
            cache.save(snapshot(), for: record)
            let unreadable = CompanionStore(defaults: defaults, loadPairing: { throw MacClientFailure.denied },
                                             liveActivity: nil, writeShared: { _ in }, clearShared: {})
            XCTAssertNil(unreadable.snapshot)
            XCTAssertNotNil(unreadable.message)
            XCTAssertEqual(cache.restore(for: record), snapshot(),
                           "A transient Keychain read failure must preserve the cache for a later launch")
        }
    }

    func testUnpairClearsBeforeMacAnswersAndLateReadCannotRepopulate() async {
        await withDefaults { defaults in
            let record = pairing()
            let cache = SessionSnapshotCache(defaults: defaults)
            cache.save(snapshot(), for: record)
            let client = SessionClientStub(holdsRoster: true, holdsUnpair: true)
            let store = self.store(defaults: defaults, record: record, client: client)
            let refresh = Task { await store.refresh() }
            await client.waitForRoster()
            let unpair = Task { await store.unpair() }
            await client.waitForUnpair()

            XCTAssertTrue(store.isUnpairing)
            XCTAssertNil(store.snapshot)
            XCTAssertFalse(store.isSnapshotCached)
            XCTAssertNil(cache.restore(for: record))

            await client.releaseRoster()
            await refresh.value
            XCTAssertNil(store.snapshot)
            XCTAssertNil(cache.restore(for: record))

            await client.releaseUnpair()
            await unpair.value
            XCTAssertNil(store.record)
            XCTAssertNil(cache.restore(for: record))
        }
    }

    func testUnpairFailureDoesNotRestoreDeletedCache() async {
        await withDefaults { defaults in
            let record = pairing()
            let cache = SessionSnapshotCache(defaults: defaults)
            cache.save(snapshot(), for: record)
            let store = self.store(defaults: defaults, record: record, client: SessionClientStub(fails: true),
                              removePairing: { _ in throw MacClientFailure.denied })
            await store.unpair()
            XCTAssertEqual(store.record, record)
            XCTAssertNil(store.snapshot)
            XCTAssertNotNil(store.message)
            XCTAssertNil(cache.restore(for: record))
            XCTAssertNil(self.store(defaults: defaults, record: record, client: SessionClientStub()).snapshot)
        }
    }

    func testEmptyCacheStaysUnconfirmedUntilSuccessfulEmptyRead() async {
        await withDefaults { defaults in
            let record = pairing()
            let empty = GlanceSnapshot(schemaVersion: 1, hostName: record.macName, connected: true,
                                      error: nil, updatedAt: Self.capturedAt, agents: [])
            SessionSnapshotCache(defaults: defaults).save(empty, for: record)
            let store = self.store(defaults: defaults, record: record, client: SessionClientStub(empty: true))
            XCTAssertEqual(store.snapshot?.agents, [])
            XCTAssertFalse(store.isConnected, "An empty cache must not read as \"No agents running\"")
            XCTAssertTrue(store.isSnapshotCached)
            await store.refresh()
            XCTAssertEqual(store.snapshot?.agents, [])
            XCTAssertTrue(store.isConnected)
            XCTAssertFalse(store.isSnapshotCached)
        }
    }

    private func store(defaults: UserDefaults, record: PairingRecord?, client: SessionClientStub,
                       removePairing: @escaping (PairingRecord) throws -> Void = { _ in }) -> CompanionStore {
        CompanionStore(defaults: defaults, loadPairing: { record }, makeClient: { _, _ in client },
                       removePairing: removePairing, liveActivity: nil, writeShared: { _ in }, clearShared: {})
    }

    private static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func pairing(connectionID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
                         fingerprint: String = "mac-pin") -> PairingRecord {
        PairingRecord(macName: "Same Mac", host: "example.invalid", port: 1234, macFingerprint: fingerprint,
                      transport: .lan, connectionID: connectionID, identityTag: "test-only",
                      identityStorage: .keychain, pairedAt: Self.capturedAt)
    }

    private func snapshot() -> GlanceSnapshot {
        GlanceSnapshot(schemaVersion: 1, hostName: "Same Mac", connected: true, error: nil,
                       updatedAt: Self.capturedAt,
                       agents: [GlanceAgent(id: "pane", workspaceName: "Cached workspace", provider: "Codex",
                                            group: .working, state: "running", reason: nil, since: Self.capturedAt)])
    }
}

private actor SessionClientStub: CompanionSessionClient {
    let fails: Bool
    let empty: Bool
    let holdsRoster: Bool
    let holdsUnpair: Bool
    private var capturedAt = Date(timeIntervalSince1970: 1_700_000_100)
    private var rosterStarted = false
    private var unpairStarted = false
    private var rosterWaiter: CheckedContinuation<Void, Never>?
    private var unpairWaiter: CheckedContinuation<Void, Never>?
    private var rosterReply: CheckedContinuation<Void, Never>?
    private var unpairReply: CheckedContinuation<Void, Never>?

    init(fails: Bool = false, empty: Bool = false, holdsRoster: Bool = false, holdsUnpair: Bool = false) {
        self.fails = fails
        self.empty = empty
        self.holdsRoster = holdsRoster
        self.holdsUnpair = holdsUnpair
    }

    func call(_ operation: String, connectionID: UUID, limit: Int?, cursor: String?) async throws -> APIResponse {
        if fails { throw MacClientFailure.unreachable }
        if operation == "get_attention_events" {
            return APIResponse(attentionEvents: .init(events: [], nextCursor: "cursor", cursorStatus: "initial",
                                                      hasMore: false, currentStateRecoveryRequired: false))
        }
        if holdsRoster {
            await withCheckedContinuation { continuation in
                rosterReply = continuation
                rosterStarted = true
                rosterWaiter?.resume(); rosterWaiter = nil
            }
        }
        return APIResponse(capturedAt: capturedAt, agents: empty ? [] : [
            .init(paneID: "pane", workspaceID: "workspace", workspaceName: "Live workspace", provider: "Codex",
                  executionLocation: "local", availability: "available", state: "running")
        ])
    }

    func unpair(connectionID: UUID) async throws {
        if fails { throw MacClientFailure.unreachable }
        if holdsUnpair {
            await withCheckedContinuation { continuation in
                unpairReply = continuation
                unpairStarted = true
                unpairWaiter?.resume(); unpairWaiter = nil
            }
        }
    }

    func waitForRoster() async {
        if !rosterStarted { await withCheckedContinuation { rosterWaiter = $0 } }
    }

    func waitForUnpair() async {
        if !unpairStarted { await withCheckedContinuation { unpairWaiter = $0 } }
    }

    func setCapturedAt(_ date: Date) { capturedAt = date }
    func releaseRoster() { rosterReply?.resume(); rosterReply = nil }
    func releaseUnpair() { unpairReply?.resume(); unpairReply = nil }
}
