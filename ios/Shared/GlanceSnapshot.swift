import Foundation

enum GlanceGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case needsYou, working, done

    var id: Self { self }
    var title: String {
        switch self {
        case .needsYou: String(localized: "Needs you")
        case .working: String(localized: "Working")
        case .done: String(localized: "Done")
        }
    }
}

/// One agent pane, grouped by the app from `list_agents` and open alerts.
struct GlanceAgent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let workspaceName: String
    let provider: String
    let group: GlanceGroup
    let state: String
    let reason: String?
    let since: Date?

    var status: String {
        switch group {
        case .working: return String(localized: "Working")
        case .done: return String(localized: "Done")
        case .needsYou: break
        }
        switch reason {
        case "permissionPrompt": return String(localized: "Needs permission")
        case "userInputRequired": return String(localized: "Has a question")
        case "waitingForInput": return String(localized: "Waiting for you")
        case "processError", "agentError": return String(localized: "Hit an error")
        case nil where state == "waiting": return String(localized: "Waiting for you")
        case nil where state == "error": return String(localized: "Hit an error")
        default: return String(localized: "Wants your attention")
        }
    }
}

struct GlanceSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let hostName: String
    let connected: Bool
    let error: String?
    let updatedAt: Date?
    let agents: [GlanceAgent]

    func count(_ group: GlanceGroup) -> Int { agents.count { $0.group == group } }
    func agents(in group: GlanceGroup) -> [GlanceAgent] { agents.filter { $0.group == group } }
    /// Agents are ordered oldest-first within `needsYou`, so the first match is the longest wait.
    var topAgent: GlanceAgent? { agents.first { $0.group == .needsYou } ?? agents.first { $0.group == .working } }

    /// The same agents marked offline, for when the Mac can't be reached or the data has aged out.
    func offline() -> GlanceSnapshot {
        GlanceSnapshot(schemaVersion: schemaVersion, hostName: hostName, connected: false,
                       error: error ?? "unreachable", updatedAt: updatedAt, agents: agents)
    }

    enum DecodingFailure: Error { case unsupportedSchema }

    static func decode(_ data: Data) throws -> GlanceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date"))
        }
        let snapshot = try decoder.decode(GlanceSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw DecodingFailure.unsupportedSchema }
        return snapshot
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// The latest snapshot, shared with the widget extension through the App Group container.
enum SharedSnapshot {
    static let appGroup = "group.com.interactivebuffoonery.awesomux.companion"
    /// The widget shows a connected snapshot as offline once it is this old.
    static let freshFor: TimeInterval = 15 * 60

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    static func read() -> GlanceSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? GlanceSnapshot.decode(data)
    }

    static func write(_ snapshot: GlanceSnapshot) {
        guard let fileURL, let data = try? snapshot.encoded() else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
