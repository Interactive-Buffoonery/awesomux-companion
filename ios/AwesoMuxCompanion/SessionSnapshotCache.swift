import Foundation

/// Last known roster for one pairing; never establishes that the Mac is reachable.
struct SessionSnapshotCache {
    private struct Entry: Codable {
        let connectionID: UUID
        let macFingerprint: String
        let snapshot: GlanceSnapshot
    }

    private let defaults: UserDefaults
    private let key = "pairedSessionSnapshot.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restore(for record: PairingRecord?) -> GlanceSnapshot? {
        guard let record, let data = defaults.data(forKey: key),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.connectionID == record.connectionID,
              entry.macFingerprint == record.macFingerprint,
              entry.snapshot.schemaVersion == 1 else {
            clear()
            return nil
        }
        return entry.snapshot.offline()
    }

    func save(_ snapshot: GlanceSnapshot, for record: PairingRecord) {
        let entry = Entry(connectionID: record.connectionID, macFingerprint: record.macFingerprint, snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(entry) else { clear(); return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
