import Foundation

/// Response strings and pane/event identifiers remain open to future Mac values.
public struct CompanionAPIResponse: Codable, Sendable {
    public struct Agent: Codable, Sendable {
        public let paneID: String
        public let workspaceID: String
        public let workspaceName: String
        public let provider: String
        public let executionLocation: String
        public let availability: String
        public let state: String
        public let attentionReason: String?
        public let observedAt: Date?
        public let unreadCount: Int?
        public let stateProvenance: String?
        public let capturedAt: Date?
        public let targetVersion: String?
        public let identityEvidence: String?
        public let providerSessionID: String?
        public let capabilities: [String]?

        public init(
            paneID: String,
            workspaceID: String,
            workspaceName: String,
            provider: String,
            executionLocation: String,
            availability: String,
            state: String,
            attentionReason: String? = nil,
            observedAt: Date? = nil,
            unreadCount: Int? = nil,
            stateProvenance: String? = nil,
            capturedAt: Date? = nil,
            targetVersion: String? = nil,
            identityEvidence: String? = nil,
            providerSessionID: String? = nil,
            capabilities: [String]? = nil
        ) {
            self.paneID = paneID
            self.workspaceID = workspaceID
            self.workspaceName = workspaceName
            self.provider = provider
            self.executionLocation = executionLocation
            self.availability = availability
            self.state = state
            self.attentionReason = attentionReason
            self.observedAt = observedAt
            self.unreadCount = unreadCount
            self.stateProvenance = stateProvenance
            self.capturedAt = capturedAt
            self.targetVersion = targetVersion
            self.identityEvidence = identityEvidence
            self.providerSessionID = providerSessionID
            self.capabilities = capabilities
        }
    }

    public struct Event: Codable, Sendable {
        public let id: String
        public let attentionID: String
        public let change: String
        public let paneID: String
        public let workspaceID: String
        public let provider: String
        public let occurredAt: Date
        public let reason: String
        public let providerSessionID: String?
        public let targetVersion: String?
        public let resolvedAt: Date?

        public init(
            id: String,
            attentionID: String,
            change: String,
            paneID: String,
            workspaceID: String,
            provider: String,
            occurredAt: Date,
            reason: String,
            providerSessionID: String? = nil,
            targetVersion: String? = nil,
            resolvedAt: Date? = nil
        ) {
            self.id = id
            self.attentionID = attentionID
            self.change = change
            self.paneID = paneID
            self.workspaceID = workspaceID
            self.provider = provider
            self.occurredAt = occurredAt
            self.reason = reason
            self.providerSessionID = providerSessionID
            self.targetVersion = targetVersion
            self.resolvedAt = resolvedAt
        }
    }

    public struct AttentionPage: Codable, Sendable {
        public let events: [Event]
        public let nextCursor: String
        public let cursorStatus: String
        public let hasMore: Bool
        public let currentStateRecoveryRequired: Bool

        public init(
            events: [Event],
            nextCursor: String,
            cursorStatus: String,
            hasMore: Bool,
            currentStateRecoveryRequired: Bool
        ) {
            self.events = events
            self.nextCursor = nextCursor
            self.cursorStatus = cursorStatus
            self.hasMore = hasMore
            self.currentStateRecoveryRequired = currentStateRecoveryRequired
        }
    }

    public let schemaVersion: Int
    public let requestID: UUID?
    public let error: String?
    public let profile: String?
    public let appInstanceID: UUID?
    public let capturedAt: Date?
    public let connectionStatus: String?
    public let agents: [Agent]?
    public let attentionEvents: AttentionPage?

    public init(
        schemaVersion: Int = CompanionProtocol.version,
        requestID: UUID? = nil,
        error: String? = nil,
        profile: String? = nil,
        appInstanceID: UUID? = nil,
        capturedAt: Date? = nil,
        connectionStatus: String? = nil,
        agents: [Agent]? = nil,
        attentionEvents: AttentionPage? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.error = error
        self.profile = profile
        self.appInstanceID = appInstanceID
        self.capturedAt = capturedAt
        self.connectionStatus = connectionStatus
        self.agents = agents
        self.attentionEvents = attentionEvents
    }
}
