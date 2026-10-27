import SwiftUI

/// Which pairings in Keychain are paired Macs, in the order they were added, and which one was opened last.
/// `PairingStore` owns the records; this list owns which of them are active, so a superseded leftover from a
/// single-host build never becomes a Mac again. Per-Mac values live under `<key>.<fingerprint>`; the Face ID
/// lock and the Live Activity switch are app-wide.
struct HostRegistry {
    static let hostsKey = "pairedHosts.v1"
    static let selectedKey = "selectedHost.v1"
    static let remindersKey = "unpairReminders.v1"
    static let legacyUnpairMessageKey = "unpairMessage"
    static let scopedKeys = [SessionSnapshotCache.key, AttentionTracker.key,
                             CompanionStore.Keys.previewSuppression, CompanionStore.Keys.revokedConnectionID,
                             CompanionStore.Keys.removalPending]

    static func hostKey(_ key: String, _ macFingerprint: String) -> String { "\(key).\(macFingerprint)" }
    static func hostKeys(_ macFingerprint: String) -> [String] { scopedKeys.map { hostKey($0, macFingerprint) } }

    let defaults: UserDefaults

    var fingerprints: [String] {
        get { defaults.stringArray(forKey: Self.hostsKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Self.hostsKey) }
    }

    var selected: String? {
        get { defaults.string(forKey: Self.selectedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.selectedKey) }
    }

    /// Macs that couldn't confirm an unpair, by fingerprint, with their names. "" is a reminder kept from a
    /// single-host build, which didn't record the Mac.
    var reminders: [String: String] {
        get { defaults.dictionary(forKey: Self.remindersKey) as? [String: String] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Self.remindersKey) }
    }

    /// Paired Macs, oldest first. Single-host builds kept no list: the newest record, the one they opened,
    /// becomes the only Mac and takes over their unscoped values. Any older record stays inert in Keychain.
    func hosts(from records: [PairingRecord]) -> [PairingRecord] {
        if defaults.stringArray(forKey: Self.hostsKey) == nil { migrate(newest: records.last) }
        let byFingerprint = Dictionary(records.map { ($0.macFingerprint, $0) }) { _, newer in newer }
        return fingerprints.compactMap { byFingerprint[$0] }
    }

    /// A Mac paired while Keychain couldn't be read at launch still settles a single-host build's values first,
    /// so they never land on the new Mac.
    func add(_ macFingerprint: String) {
        if defaults.stringArray(forKey: Self.hostsKey) == nil { migrate(newest: nil) }
        if !fingerprints.contains(macFingerprint) { fingerprints.append(macFingerprint) }
    }

    private func migrate(newest: PairingRecord?) {
        if let newest {
            for key in Self.scopedKeys {
                guard let value = defaults.object(forKey: key) else { continue }
                let matches = switch key {
                case SessionSnapshotCache.key: SessionSnapshotCache.legacyValue(value, matches: newest)
                case CompanionStore.Keys.previewSuppression: CompanionStore.legacyPreviewValue(value, matches: newest)
                case CompanionStore.Keys.revokedConnectionID: value as? String == newest.connectionID.uuidString
                case AttentionTracker.key: true // Single-host attention history belongs to the host that build opened.
                default: false
                }
                let target = Self.hostKey(key, newest.macFingerprint)
                if matches, defaults.object(forKey: target) == nil { defaults.set(value, forKey: target) }
            }
            selected = newest.macFingerprint
        }
        if defaults.string(forKey: Self.legacyUnpairMessageKey) != nil { reminders[""] = "" }
        for key in Self.scopedKeys + [Self.legacyUnpairMessageKey] { defaults.removeObject(forKey: key) }
        fingerprints = newest.map { [$0.macFingerprint] } ?? []
    }
}

/// One `CompanionStore` per paired Mac. Each keeps its own pairing, connection, caches and authority, so a
/// failure, grant or cache on one Mac never reaches another. The selected Mac is the one opened last.
@MainActor @Observable
final class Hosts {
    private(set) var stores: [CompanionStore] = []
    /// Opens at launch, polls with panes, and is the only Mac the widget and Live Activity show (B3 merges them).
    private(set) var selected: CompanionStore?
    /// The store a new Mac pairs on; it joins `stores` once its pairing is saved.
    private(set) var adding: CompanionStore
    private(set) var reminders: [String: String]
    /// Fingerprints of the screens above the host list: the open Mac's Sessions.
    var path: [String] = []
    var liveActivityEnabled: Bool {
        didSet { for store in stores + [adding] { store.liveActivityEnabled = liveActivityEnabled } }
    }

    @ObservationIgnored private let registry: HostRegistry
    @ObservationIgnored private let pairingStore: PairingStore
    @ObservationIgnored private let makeStore: @MainActor (() throws -> PairingRecord?) -> CompanionStore

    init(defaults: UserDefaults = .standard, pairingStore: PairingStore = .system,
         makeStore: (@MainActor (() throws -> PairingRecord?) -> CompanionStore)? = nil) {
        let activity = LiveActivityController()
        let make = makeStore ?? { load in
            CompanionStore(defaults: defaults, loadPairing: load, pairingStore: pairingStore, liveActivity: activity)
        }
        registry = HostRegistry(defaults: defaults)
        self.pairingStore = pairingStore
        self.makeStore = make
        liveActivityEnabled = defaults.object(forKey: CompanionStore.Keys.liveActivity) as? Bool ?? true
        do {
            let records = registry.hosts(from: try pairingStore.loadAll())
            stores = records.map { record in make { record } }
            adding = make { nil }
        } catch {
            // The list is kept as is: an unreadable Keychain (or nothing usable in it) never unpairs a Mac.
            adding = make { throw error }
        }
        reminders = registry.reminders
        for store in stores + [adding] { wire(store) }
        // Restore the durable selection and replace any stale shared snapshot from another host.
        selected = stores.first { $0.record?.macFingerprint == registry.selected } ?? stores.last
        if let selected { registry.selected = selected.record?.macFingerprint }
        path = selected?.record.map { [$0.macFingerprint] } ?? []
        selected?.publishGlance()
    }

    /// The store showing the pairing screen: a Mac being paired again, a Mac being added, or the welcome screen.
    var pairing: CompanionStore? {
        if let store = stores.first(where: { $0.showingPairing || $0.pairingStep != .idle }) { return store }
        return stores.isEmpty || adding.showingPairing || adding.pairingStep != .idle ? adding : nil
    }

    var reminderMessages: [String] {
        reminders.sorted { $0.key < $1.key }.map { _, name in
            name.isEmpty ? String(localized: "To finish, also choose Unpair in awesoMux Settings on your Mac.")
                : String(localized: "To finish unpairing “\(name)”, also choose Unpair in awesoMux Settings on that Mac.")
        }
    }

    func store(for macFingerprint: String) -> CompanionStore? {
        stores.first { $0.record?.macFingerprint == macFingerprint }
    }

    func startAdding() {
        selected?.resignSelection()
        adding.cancelPairing()
        adding.showingPairing = true
    }

    /// Selects the Mac and shows its Sessions. Opening another Mac ends whatever the previous one was
    /// authorized to do on screen; nothing carries over.
    func open(_ store: CompanionStore) {
        guard let fingerprint = store.record?.macFingerprint, stores.contains(where: { $0 === store }) else { return }
        select(store)
        path = [fingerprint]
    }

    /// A link from the Mac waits for review on the store it belongs to: Pair Again for a paired Mac, otherwise
    /// adding it. A pairing already underway keeps the link, and rejects it there if it's for another Mac.
    func openPairingLink(_ text: String) {
        let target = pairing ?? (try? PairingLink(text)).flatMap { store(for: $0.macFingerprint) } ?? adding
        selected?.resignSelection()
        target.showingPairing = true
        target.openPairingLink(text, review: true)
    }

    /// A tap opens the pane on the Mac that raised it. Alerts from single-host builds carry no fingerprint and open
    /// only while exactly one Mac is paired; an alert from a Mac that's no longer paired opens nothing.
    func openNotification(paneID: String?, macFingerprint: String?) {
        guard let paneID else { return }
        let target = if let macFingerprint { store(for: macFingerprint) } else { stores.count == 1 ? stores.first : nil }
        guard let target else { return }
        target.resignSelection()
        open(target)
        target.focusedPaneID = paneID
    }

    func dismissReminders() {
        reminders = [:]
        registry.reminders = [:]
    }

    // MARK: Polling

    /// The selected Mac every 5 s with its panes; the others alerts and agents only, every 30 s. The caller runs this
    /// while the scene is active and restarts it when the selection or the list changes.
    func poll() async {
        let focused = stores.filter { $0 === selected && pairing == nil }
        let others = stores.filter { store in !focused.contains { $0 === store } }
        await withDiscardingTaskGroup { group in
            for store in focused { group.addTask { await store.poll() } }
            for store in others { group.addTask { await store.pollAttention() } }
        }
    }

    /// Leaving the foreground: no Mac's failure counts as offline, and every pane stream stops.
    func suspend() {
        for store in stores { store.suspendPanes() }
    }

    /// Background refresh reads every Mac, each with its own connection; one Mac failing doesn't stop the others.
    func refreshAll() async -> Bool {
        let stores = stores
        return await withTaskGroup(of: Bool.self) { group in
            for store in stores { group.addTask { await store.refresh(); return await store.reachable } }
            var reachable = !stores.isEmpty
            for await ok in group { reachable = reachable && ok }
            return reachable
        }
    }

    // MARK: Membership

    private func wire(_ store: CompanionStore) {
        store.isPairedHost = { [weak self] fingerprint in self?.store(for: fingerprint) != nil }
        store.preparePairingSave = { [weak self] in try self?.recoverHosts() }
        store.didPair = { [weak self] store in self?.added(store) }
        store.didUnpair = { [weak self] store, record in self?.removed(store, record: record) }
        store.publishesGlance = { [weak self, weak store] in store != nil && self?.selected === store }
        store.liveActivityEnabled = liveActivityEnabled
    }

    /// A launch-time Keychain failure must not let a later successful addition hide the existing Mac.
    /// Resolve the old registry before saving the new record, while its original newest record is still known.
    private func recoverHosts() throws {
        guard stores.isEmpty else { return }
        let records: [PairingRecord]
        do {
            records = try pairingStore.loadAll()
        } catch PairingStoreFailure.invalidItem {
            // As in B1, unusable records may be replaced, but never become active hosts.
            records = []
        }
        stores = registry.hosts(from: records).map { record in makeStore { record } }
        for store in stores { wire(store) }
        if let restored = stores.first(where: { $0.record?.macFingerprint == registry.selected }) ?? stores.last {
            select(restored)
        }
    }

    private func select(_ store: CompanionStore) {
        guard selected !== store else { return }
        selected?.resignSelection()
        selected = store
        registry.selected = store.record?.macFingerprint
        store.publishGlance()
    }

    private func added(_ store: CompanionStore) {
        guard store === adding, let fingerprint = store.record?.macFingerprint else { return }
        stores.append(store)
        registry.add(fingerprint)
        reminders[fingerprint] = nil
        registry.reminders = reminders
        adding = makeStore { nil }
        wire(adding)
        open(store)
    }

    /// Only this Mac leaves the list; the others keep their pairings, identities, caches and authority.
    private func removed(_ store: CompanionStore, record: PairingRecord) {
        let fingerprint = record.macFingerprint
        stores.removeAll { $0 === store }
        registry.fingerprints.removeAll { $0 == fingerprint }
        if store.unpairMessage != nil {
            reminders[fingerprint] = record.macName
            registry.reminders = reminders
        }
        path.removeAll { $0 == fingerprint }
        guard selected === store else { return }
        selected = nil
        registry.selected = nil
        if let next = stores.last { select(next) }
    }
}

// MARK: Screen

/// Flat rows, one per Mac: name, route or offline age, and what needs you there.
struct HostsView: View {
    let hosts: Hosts
    @State private var settings: CompanionStore?

    var body: some View {
        List {
            Section {
                ForEach(hosts.stores) { store in
                    Button { hosts.open(store) } label: {
                        HostRow(store: store, isSelected: hosts.selected === store)
                    }
                    .contextMenu {
                        Button("Settings", systemImage: "gearshape") { settings = store }
                    }
                }
                Button { hosts.startAdding() } label: {
                    Label("pair a mac", systemImage: "plus").font(.body.monospaced()).foregroundStyle(Cat.accent)
                }
            }
            .listRowBackground(Color.clear)
            if !hosts.reminders.isEmpty {
                Section {
                    ForEach(hosts.reminderMessages, id: \.self) { message in
                        Label(message, systemImage: "info.circle").font(.subheadline).foregroundStyle(Cat.text)
                    }
                    Button("Dismiss") { hosts.dismissReminders() }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Cat.page)
        .navigationTitle("Hosts")
        .toolbarBackground(Cat.page, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AppSettingsView(hosts: hosts) } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Settings")
                }
            }
        }
        .sheet(item: $settings) { store in
            NavigationStack {
                SettingsView(store: store, showsDecisions: hosts.selected === store)
                    .task { store.resumePanes(); await store.refreshPanes() }
                    .onDisappear { if hosts.selected !== store { store.suspendPanes() } }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = nil } }
                    }
            }
        }
    }
}

struct HostRow: View {
    let store: CompanionStore
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(store.isConnected ? "●" : "○")
                .foregroundStyle(store.isConnected ? Cat.output : Cat.subtext0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.record?.macName ?? "Mac")
                    .font(.body.monospaced().weight(.semibold)).foregroundStyle(Cat.text).lineLimit(2)
                Text(status).font(.footnote.monospaced()).foregroundStyle(Cat.subtext0)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let needs = store.snapshot?.count(.needsYou), needs > 0 {
                    Text("\(needs) need you").foregroundStyle(Cat.needs)
                }
                if let working = store.snapshot?.count(.working), working > 0 {
                    Text("\(working) working").foregroundStyle(Cat.subtext0)
                }
            }
            .font(.footnote.monospaced().weight(.semibold))
            if isSelected {
                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Cat.accent)
                    .accessibilityLabel("Last opened")
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "lan · 4 panes", "offline · seen 5 min ago", or "connecting…". No latency: the app doesn't measure it.
    private var status: String {
        guard store.isConnected, let route = store.activeRoute else {
            guard let updatedAt = store.snapshot?.updatedAt else {
                return store.message == nil ? String(localized: "connecting…") : String(localized: "offline")
            }
            return String(localized: "offline · seen \(updatedAt.formatted(.relative(presentation: .named)))")
        }
        let transport = route.transport.title.lowercased()
        guard case .loaded(let workspaces) = store.panes.state else { return transport }
        let panes = workspaces.reduce(0) { $0 + $1.panes.count }
        return String(localized: "\(transport) · \(panes) panes")
    }
}
