import Foundation

public extension CompanionAPIResponse {
    /// Workspaces follow sidebar order; panes follow layout leaf order.
    struct Workspace: Codable, Sendable {
        public let workspaceID: String
        public let name: String
        public let panes: [Pane]

        public init(workspaceID: String, name: String, panes: [Pane]) {
            self.workspaceID = workspaceID
            self.name = name
            self.panes = panes
        }
    }

    /// Terminal previews are optional active-screen content, never document content.
    /// Kind, availability, and state strings remain open to future Mac values.
    struct Pane: Codable, Sendable {
        public let paneID: String
        public let kind: String
        public let title: String
        public let availability: String
        public let state: String?
        public let lastOutputLine: String?

        public init(
            paneID: String, kind: String, title: String, availability: String,
            state: String? = nil, lastOutputLine: String? = nil
        ) {
            self.paneID = paneID
            self.kind = kind
            self.title = title
            self.availability = availability
            self.state = state
            self.lastOutputLine = lastOutputLine
        }
    }
}
