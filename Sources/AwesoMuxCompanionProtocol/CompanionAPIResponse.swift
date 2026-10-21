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
        public let exitCode: Int?
        public let durationSeconds: Double?

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
            resolvedAt: Date? = nil,
            exitCode: Int? = nil,
            durationSeconds: Double? = nil
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
            self.exitCode = exitCode
            self.durationSeconds = durationSeconds
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
    /// v2 grants only. Malformed route metadata decodes as `nil` so the rest of the response survives.
    public let routes: CompanionRoutes?

    public init(
        schemaVersion: Int = CompanionProtocol.version,
        requestID: UUID? = nil,
        error: String? = nil,
        profile: String? = nil,
        appInstanceID: UUID? = nil,
        capturedAt: Date? = nil,
        connectionStatus: String? = nil,
        agents: [Agent]? = nil,
        attentionEvents: AttentionPage? = nil,
        routes: CompanionRoutes? = nil
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
        self.routes = routes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        requestID = try container.decodeIfPresent(UUID.self, forKey: .requestID)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        appInstanceID = try container.decodeIfPresent(UUID.self, forKey: .appInstanceID)
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
        connectionStatus = try container.decodeIfPresent(String.self, forKey: .connectionStatus)
        agents = try container.decodeIfPresent([Agent].self, forKey: .agents)
        attentionEvents = try container.decodeIfPresent(AttentionPage.self, forKey: .attentionEvents)
        routes = (try? container.decodeIfPresent(CompanionRoutes.self, forKey: .routes)) ?? nil
    }
}

/// The current route set: `v` is always 2, the port is shared, and at least one route is present.
public struct CompanionRoutes: Codable, Equatable, Sendable {
    public let v: Int
    public let p: UInt16
    public let lan: String?
    public let tailscale: String?

    public init(p: UInt16, lan: String?, tailscale: String?) {
        v = 2
        self.p = p
        self.lan = lan
        self.tailscale = tailscale
    }
}
