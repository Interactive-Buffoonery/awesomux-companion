import ActivityKit
import Foundation

struct GlanceActivityAttributes: ActivityAttributes {
    struct TopItem: Codable, Hashable {
        let provider: String
        let workspaceName: String
        let reason: String
        let since: Date?
    }

    struct ContentState: Codable, Hashable {
        let needsYou: Int
        let working: Int
        let done: Int
        let top: TopItem?
        let updatedAt: Date
        let connected: Bool
    }

    let hostName: String
}

extension GlanceActivityAttributes.ContentState {
    init(_ snapshot: GlanceSnapshot, connected: Bool) {
        needsYou = snapshot.count(.needsYou)
        working = snapshot.count(.working)
        done = snapshot.count(.done)
        top = snapshot.topAgent.map {
            .init(provider: $0.provider, workspaceName: $0.workspaceName, reason: $0.status, since: $0.since)
        }
        updatedAt = snapshot.updatedAt
        self.connected = connected
    }
}
