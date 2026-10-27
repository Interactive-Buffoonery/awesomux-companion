import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class HostsTests: XCTestCase {
    private lazy var defaults: UserDefaults = {
        let suite = "HostsTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }()
    private let macA = Data(repeating: 0xA1, count: 32).base64URLEncodedString
    private let macB = Data(repeating: 0xB2, count: 32).base64URLEncodedString
    private let keychain = KeychainFixture()
    private var clients: [String: PaneClientFixture] = [:]
    private var removed: [String] = []
    private var shared: [String] = []

    // MARK: Migration

    /// A single-host build kept one pairing and unscoped values. The newest record becomes the only Mac and takes
    /// those values; an older leftover stays inert; the unconfirmed-unpair message becomes a reminder.
    func testSingleHostValuesMoveOnlyToTheMacThatBuildOpened() throws {
        let older = record(macA, pairedAt: 100)
        let newest = record(macB, pairedAt: 200)
        try keychain.put(older, account: PairingStore.account(for: macA)!)
        try keychain.put(newest, account: PairingStore.legacyAccount)
        for key in HostRegistry.scopedKeys { defaults.set("legacy \(key)", forKey: key) }
        defaults.set("To finish…", forKey: HostRegistry.legacyUnpairMessageKey)

        let registry = HostRegistry(defaults: defaults)
        XCTAssertEqual(registry.hosts(from: try PairingStore(keychain: keychain).loadAll()), [newest])
        for key in HostRegistry.scopedKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
            XCTAssertEqual(defaults.string(forKey: HostRegistry.hostKey(key, macB)), "legacy \(key)", key)
            XCTAssertNil(defaults.object(forKey: HostRegistry.hostKey(key, macA)), key)
        }
        XCTAssertNil(defaults.object(forKey: HostRegistry.legacyUnpairMessageKey))

        let hosts = launch()
        XCTAssertEqual(hosts.stores.compactMap(\.record), [newest], "A superseded leftover never becomes a Mac")
        XCTAssertTrue(hosts.selected === hosts.stores.first)
        XCTAssertEqual(hosts.path, [macB], "One Mac opens straight to its Sessions")
        XCTAssertEqual(hosts.reminders, ["": ""])

        defaults.set("later", forKey: HostRegistry.scopedKeys[0])
        XCTAssertEqual(launch().stores.compactMap(\.record), [newest], "Migration runs once")
        XCTAssertEqual(defaults.string(forKey: HostRegistry.scopedKeys[0]), "later")
    }

    func testUnreadableKeychainKeepsTheListAndAddingSettlesLegacyValues() throws {
        try keychain.put(record(macA), account: PairingStore.legacyAccount)
        defaults.set("legacy", forKey: CompanionStore.Keys.previewSuppression)
        keychain.fault = .failRead
        let unreadable = launch()
        XCTAssertEqual(unreadable.stores.count, 0)
        XCTAssertTrue(unreadable.pairing === unreadable.adding)
        XCTAssertNotNil(unreadable.adding.message)
        XCTAssertNil(defaults.object(forKey: HostRegistry.hostsKey), "A failed read never writes the list")

        keychain.fault = nil
        XCTAssertEqual(launch().stores.compactMap(\.record?.macFingerprint), [macA])

        let registry = HostRegistry(defaults: freshDefaults())
        registry.defaults.set("legacy", forKey: CompanionStore.Keys.previewSuppression)
        registry.add(macB)
        XCTAssertEqual(registry.fingerprints, [macB])
        XCTAssertNil(registry.defaults.object(forKey: CompanionStore.Keys.previewSuppression))
        XCTAssertNil(registry.defaults.object(forKey: HostRegistry.hostKey(CompanionStore.Keys.previewSuppression, macB)),
                     "Values from an unread Mac never land on the new one")
    }

    // MARK: Pairing

    func testPairAgainStaysWithItsMacAndAddingNeverReplacesAPairedMac() throws {
        let hosts = try twoHosts()
        let a = try XCTUnwrap(hosts.store(for: macA))

        a.openPairingLink(link(macB, name: "Studio"), review: true)
        guard case .failed(let message) = a.pairingStep else { return XCTFail("\(a.pairingStep)") }
        XCTAssertTrue(message.contains("+ pair a mac"), message)

        hosts.startAdding()
        hosts.adding.openPairingLink(link(macA, name: "Desk"), review: true)
        guard case .failed(let added) = hosts.adding.pairingStep else { return XCTFail("\(hosts.adding.pairingStep)") }
        XCTAssertTrue(added.contains("Pair Again"), added)

        hosts.adding.cancelPairing(); hosts.adding.showingPairing = false
        hosts.openPairingLink(link(macA, name: "Desk"))
        XCTAssertTrue(hosts.pairing === a, "A link for a paired Mac opens that Mac's Pair Again")
        a.cancelPairing(); a.showingPairing = false
        hosts.openPairingLink(link(Data(repeating: 0xC3, count: 32).base64URLEncodedString, name: "New"))
        XCTAssertTrue(hosts.pairing === hosts.adding)
        guard case .review = hosts.adding.pairingStep else { return XCTFail("\(hosts.adding.pairingStep)") }
    }

    // MARK: Unpair

    func testUnpairingOneMacKeepsTheOther() async throws {
        let hosts = try twoHosts()
        let a = try XCTUnwrap(hosts.store(for: macA)), b = try XCTUnwrap(hosts.store(for: macB))
        hosts.open(b)
        for store in [a, b] { await store.refresh() }
        let keptKeys = HostRegistry.hostKeys(macA).filter { defaults.object(forKey: $0) != nil }
        XCTAssertFalse(keptKeys.isEmpty)
        clients[macB]?.errors["unpair"] = .unreachable

        await b.unpair()
        XCTAssertEqual(removed, ["identity-\(macB.prefix(4))"])
        XCTAssertTrue(hosts.stores.count == 1 && hosts.stores.first === a)
        XCTAssertTrue(hosts.selected === a, "Selection moves to the Mac that's left")
        XCTAssertEqual(defaults.stringArray(forKey: HostRegistry.hostsKey), [macA])
        XCTAssertEqual(hosts.reminders, [macB: "Mac \(macB.prefix(4))"], "B couldn't confirm, so it's remembered")
        XCTAssertNil(hosts.path.firstIndex(of: macB))
        for key in HostRegistry.hostKeys(macB) { XCTAssertNil(defaults.object(forKey: key), key) }
        for key in keptKeys { XCTAssertNotNil(defaults.object(forKey: key), key) }
        XCTAssertNotNil(a.snapshot)
        XCTAssertEqual(try PairingStore(keychain: keychain).loadAll().map(\.macFingerprint), [macA])
        XCTAssertEqual(launch().stores.compactMap(\.record?.macFingerprint), [macA])
    }

    // MARK: Isolation

    func testOneMacFailingNeverReachesAnotherAndOnlyTheSelectedMacPublishes() async throws {
        let hosts = try twoHosts()
        let a = try XCTUnwrap(hosts.store(for: macA)), b = try XCTUnwrap(hosts.store(for: macB))
        hosts.open(a)
        shared = []
        for store in [a, b] { store.resumePanes(); await store.refresh() }
        XCTAssertEqual(shared, [macA], "Only the selected Mac writes the widget")

        clients[macB]?.errors["get_attention_events"] = .unreachable
        clients[macB]?.errors["list_agents"] = .unreachable
        await b.refresh()
        XCTAssertFalse(b.reachable)
        XCTAssertEqual(b.snapshot?.connected, false)
        XCTAssertTrue(a.reachable)
        XCTAssertEqual(a.snapshot?.connected, true)
        XCTAssertNil(a.message)
        XCTAssertEqual(shared, [macA], "B going offline never marks the widget offline")

        let refreshed = await hosts.refreshAll()
        XCTAssertFalse(refreshed, "Background refresh reports B's failure")
        XCTAssertTrue(a.reachable, "and still reads A")
    }

    // MARK: Authority

    func testOpeningAnotherMacEndsWhatThePreviousOneAuthorized() throws {
        let hosts = try twoHosts()
        let a = try XCTUnwrap(hosts.store(for: macA)), b = try XCTUnwrap(hosts.store(for: macB))
        hosts.open(a)
        a.resumePanes()
        a.focusedPaneID = "pane"
        let pairing = a.decisionPairing, session = a.decisionSession

        hosts.open(b)
        XCTAssertNotNil(a.decisionPairing)
        XCTAssertNotEqual(a.decisionPairing, pairing, "A terminal opened on A can no longer send")
        XCTAssertNotEqual(a.decisionSession, session, "A decision read on A can no longer be answered")
        XCTAssertNil(a.focusedPaneID)
        XCTAssertFalse(a.panes.terminalAccess.inputAllowed)
        XCTAssertEqual(hosts.path, [macB])
        XCTAssertEqual(defaults.string(forKey: HostRegistry.selectedKey), macB)
        XCTAssertTrue(launch().selected?.record?.macFingerprint == macB, "Opens the last-used Mac")

        let pane = TerminalDestination(paneID: UUID(), targetVersion: UUID()).on(b.record)
        XCTAssertEqual(pane.macFingerprint, macB)
        XCTAssertEqual(pane.host, b.record?.macName)
    }

    // MARK: Notifications

    func testNotificationsOpenOnlyTheMacThatRaisedThem() throws {
        let hosts = try twoHosts()
        let a = try XCTUnwrap(hosts.store(for: macA)), b = try XCTUnwrap(hosts.store(for: macB))
        hosts.open(a)
        XCTAssertEqual(CompanionStore.notificationInfo(paneID: "p", attentionID: "e", macFingerprint: macB)["macFingerprint"],
                       macB)

        hosts.openNotification(paneID: "pane-b", macFingerprint: macB)
        XCTAssertTrue(hosts.selected === b)
        XCTAssertEqual(b.focusedPaneID, "pane-b")
        XCTAssertNil(a.focusedPaneID)

        hosts.openNotification(paneID: "legacy", macFingerprint: nil)
        hosts.openNotification(paneID: "removed", macFingerprint: Data(repeating: 0xC3, count: 32).base64URLEncodedString)
        XCTAssertTrue(hosts.selected === b, "Ambiguous or unknown alerts open nothing")
        XCTAssertEqual(b.focusedPaneID, "pane-b")

        let single = launchOne()
        single.openNotification(paneID: "legacy", macFingerprint: nil)
        XCTAssertEqual(single.selected?.focusedPaneID, "legacy", "With one Mac, an old alert opens it")
    }

    // MARK: Polling

    func testPollingEndsWhenCancelled() async throws {
        let hosts = try twoHosts()
        let poll = Task { await hosts.poll() }
        try await Task.sleep(for: .milliseconds(200))
        poll.cancel()
        let finished = expectation(description: "every Mac's loop ended")
        Task { await poll.value; finished.fulfill() }
        await fulfillment(of: [finished], timeout: 2)
        let reads = clients.values.map { $0.calls.count }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(clients.values.map { $0.calls.count }, reads, "No worker outlives the poll")
        XCTAssertTrue(clients.values.allSatisfy { !$0.calls.isEmpty })
    }

    // MARK: Fixtures

    private func twoHosts() throws -> Hosts {
        defaults.set([macA, macB], forKey: HostRegistry.hostsKey)
        let store = PairingStore(keychain: keychain)
        try store.save(record(macA, pairedAt: 100))
        try store.save(record(macB, pairedAt: 200))
        return launch()
    }

    private func launchOne() -> Hosts {
        let other = freshDefaults()
        let keychain = KeychainFixture()
        try? keychain.put(record(macA), account: PairingStore.account(for: macA)!)
        return Hosts(defaults: other, pairingStore: PairingStore(keychain: keychain)) { load in
            CompanionStore(defaults: other, loadPairing: load, makeClient: { _, _ in PaneClientFixture() },
                           removePairing: { _ in }, liveActivity: nil, writeShared: { _ in }, clearShared: {})
        }
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "HostsTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func launch() -> Hosts {
        let pairingStore = PairingStore(keychain: keychain)
        return Hosts(defaults: defaults, pairingStore: pairingStore) { [unowned self] load in
            CompanionStore(defaults: defaults, loadPairing: load, pairingStore: pairingStore,
                           makeClient: { [unowned self] record, _ in client(record.macFingerprint) },
                           removePairing: { [unowned self] record in
                               try pairingStore.clear(macFingerprint: record.macFingerprint)
                               removed.append(record.identityTag)
                           },
                           liveActivity: nil,
                           writeShared: { [unowned self] in shared.append($0.hostName == "Mac \(macA.prefix(4))" ? macA : macB) },
                           clearShared: {})
        }
    }

    private func client(_ fingerprint: String) -> PaneClientFixture {
        if let client = clients[fingerprint] { return client }
        let client = PaneClientFixture()
        clients[fingerprint] = client
        return client
    }

    private func record(_ fingerprint: String, pairedAt: TimeInterval = 100) -> PairingRecord {
        PairingRecord(macName: "Mac \(fingerprint.prefix(4))", host: "fixture.invalid", port: 1234,
                      macFingerprint: fingerprint, transport: .lan, routes: nil, connectionID: UUID(),
                      identityTag: "identity-\(fingerprint.prefix(4))", identityStorage: .keychain,
                      pairedAt: Date(timeIntervalSince1970: pairedAt))
    }

    private func link(_ fingerprint: String, name: String) -> String {
        "awesomuxcompanion://pair?v=2&lan=192.168.1.20&p=43123&fp=\(fingerprint)&s=\(String(repeating: "A", count: 43))&n=\(name)"
    }
}
