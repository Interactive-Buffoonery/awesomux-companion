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
                             CompanionStore.Keys.previewSuppression, CompanionStore.Keys.revokedConnectionID]

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
                if let value = defaults.object(forKey: key) {
                    defaults.set(value, forKey: Self.hostKey(key, newest.macFingerprint))
                }
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
    @ObservationIgnored private let makeStore: @MainActor (() throws -> PairingRecord?) -> CompanionStore

    init(defaults: UserDefaults = .standard, pairingStore: PairingStore = .system,
         makeStore: (@MainActor (() throws -> PairingRecord?) -> CompanionStore)? = nil) {
        let make = makeStore ?? { load in CompanionStore(defaults: defaults, loadPairing: load, pairingStore: pairingStore) }
        registry = HostRegistry(defaults: defaults)
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
        // Already what the widget shows; it's republished only when the selection changes.
        selected = stores.first { $0.record?.macFingerprint == registry.selected } ?? stores.last
        path = selected?.record.map { [$0.macFingerprint] } ?? []
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
        target.showingPairing = true
        target.openPairingLink(text, review: true)
    }

    /// A tap opens the pane on the Mac that raised it. Alerts from single-host builds carry no fingerprint and open
    /// only while exactly one Mac is paired; an alert from a Mac that's no longer paired opens nothing.
    func openNotification(paneID: String?, macFingerprint: String?) {
        guard let paneID else { return }
        let target = if let macFingerprint { store(for: macFingerprint) } else { stores.count == 1 ? stores.first : nil }
        guard let target else { return }
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
        let selected = selected
        await withTaskGroup(of: Void.self) { group in
            for store in stores {
                group.addTask { @MainActor in
                    if store === selected { await store.poll() } else { await store.pollAttention() }
                }
            }
        }
    }

    /// Leaving the foreground: no Mac's failure counts as offline, and every pane stream stops.
    func suspend() {
        for store in stores { store.suspendPanes() }
    }

    /// Background refresh reads every Mac, each with its own connection; one Mac failing doesn't stop the others.
    func refreshAll() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for store in stores {
                group.addTask { @MainActor in
                    await store.refresh()
                    return store.reachable
                }
            }
            return await group.reduce(!stores.isEmpty) { $0 && $1 }
        }
    }

    // MARK: Membership

    private func wire(_ store: CompanionStore) {
        store.liveActivityEnabled = liveActivityEnabled
        store.isPairedHost = { [weak self] fingerprint in self?.store(for: fingerprint) != nil }
        store.didPair = { [weak self] store in self?.added(store) }
        store.didUnpair = { [weak self] store, record in self?.removed(store, record: record) }
        store.publishesGlance = { [weak self, weak store] in store != nil && self?.selected === store }
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
        reminders[""] = nil
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
                    .swipeActions {
                        Button("Settings", systemImage: "gearshape") { settings = store }.tint(Cat.running)
                    }
                    .contextMenu {
                        Button("Settings", systemImage: "gearshape") { settings = store }
                    }
                }
                Button { hosts.startAdding() } label: {
                    Label("pair a mac", systemImage: "plus").font(.body.monospaced()).foregroundStyle(Cat.accent)
                }
            }
            .listRowBackground(Cat.card)
            if !hosts.reminders.isEmpty {
                Section {
                    ForEach(hosts.reminderMessages, id: \.self) { message in
                        Label(message, systemImage: "info.circle").font(.subheadline).foregroundStyle(Cat.text)
                    }
                    Button("Dismiss") { hosts.dismissReminders() }
                }
                .listRowBackground(Cat.card)
            }
        }
        .listStyle(.insetGrouped)
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
        HStack(spacing: 12) {
            Circle().fill(store.isConnected ? Cat.output : Cat.needs).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.record?.macName ?? "Mac")
                    .font(.body.weight(.semibold)).foregroundStyle(Cat.text).lineLimit(2)
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
            .font(.footnote.weight(.semibold))
            if isSelected {
                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Cat.accent)
                    .accessibilityLabel("Last opened")
            }
        }
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
        let route = route.transport.title.lowercased()
        guard case .loaded(let workspaces) = store.panes.state else { return route }
        let panes = workspaces.reduce(0) { $0 + $1.panes.count }
        return String(localized: "\(route) · \(panes) panes")
    }
}
