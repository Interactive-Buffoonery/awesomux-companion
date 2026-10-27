import Foundation

/// Last known roster for each paired Mac, under `pairedSessionSnapshot.v1.<fingerprint>`. Restored as saved:
/// age alone isn't a failure, and `CompanionStore.reachable` (not `connected`) says whether the Mac answered this launch.
struct SessionSnapshotCache {
    static let key = "pairedSessionSnapshot.v1"

    private struct Entry: Codable {
        let connectionID: UUID
        let macFingerprint: String
        let snapshot: GlanceSnapshot
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restore(for record: PairingRecord?) -> GlanceSnapshot? {
        guard let record else { return nil }
        guard let data = defaults.data(forKey: key(record)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.connectionID == record.connectionID,
              entry.macFingerprint == record.macFingerprint,
              entry.snapshot.schemaVersion == 1 else {
            clear(for: record)
            return nil
        }
        return entry.snapshot
    }

    func save(_ snapshot: GlanceSnapshot, for record: PairingRecord) {
        let entry = Entry(connectionID: record.connectionID, macFingerprint: record.macFingerprint, snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(entry) else { clear(for: record); return }
        defaults.set(data, forKey: key(record))
    }

    /// Only this Mac's roster; other Macs' cached rosters stay.
    func clear(for record: PairingRecord?) {
        guard let record else { return }
        defaults.removeObject(forKey: key(record))
    }

    private func key(_ record: PairingRecord) -> String {
        HostRegistry.hostKey(Self.key, record.macFingerprint)
    }
}
