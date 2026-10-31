import Foundation

/// Exact hook identity issued by the Mac. Devices echo it; they never create authority.
public struct CompanionDecisionIdentity: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: UUID
    public let workspaceID: UUID
    public let paneID: UUID
    public let targetVersion: UUID
    public let providerSessionID: String
    public let invocationID: UUID
    public let revision: Int

    public init(
        runtimeID: UUID, workspaceID: UUID, paneID: UUID, targetVersion: UUID,
        providerSessionID: String, invocationID: UUID, revision: Int
    ) {
        self.runtimeID = runtimeID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.targetVersion = targetVersion
        self.providerSessionID = providerSessionID
        self.invocationID = invocationID
        self.revision = revision
    }
}

public enum CompanionDecisionChoice: String, Codable, Sendable { case allow, deny }
public enum CompanionDecisionState: String, Codable, Sendable {
    case pending, recorded, delivering, delivered, cancelled, expired, unknown
}
public struct CompanionDecisionSource: Codable, Equatable, Sendable {
    public let deviceID: UUID?
    public let name: String
    public init(deviceID: UUID? = nil, name: String) { self.deviceID = deviceID; self.name = name }
}
public struct CompanionPendingDecision: Codable, Equatable, Sendable {
    public let identity: CompanionDecisionIdentity
    public let tool: String
    public let summary: String
    public let remoteExpiresAt: Date
    public let choices: [CompanionDecisionChoice]
    public init(
        identity: CompanionDecisionIdentity, tool: String, summary: String,
        remoteExpiresAt: Date, choices: [CompanionDecisionChoice]
    ) {
        self.identity = identity; self.tool = tool; self.summary = summary
        self.remoteExpiresAt = remoteExpiresAt; self.choices = choices
    }
}
public struct CompanionDecisionAnswer: Codable, Equatable, Sendable {
    /// Counted in Unicode scalars so the Mac's hook reply stays within its transport frame.
    public static let maximumNoteLength = 500
    public let identity: CompanionDecisionIdentity
    public let choice: CompanionDecisionChoice
    public let retryID: UUID
    /// Text for Claude; only a deny carries one, because Claude's hook accepts a message only there.
    public let note: String?
    public init(identity: CompanionDecisionIdentity, choice: CompanionDecisionChoice, retryID: UUID) {
        self.identity = identity; self.choice = choice; self.retryID = retryID; self.note = nil
    }

    /// Nil when the note breaks ``accepts(note:for:)``, so an invalid answer can't be built or sent.
    public init?(identity: CompanionDecisionIdentity, choice: CompanionDecisionChoice, retryID: UUID, note: String?) {
        guard Self.accepts(note: note, for: choice) else { return nil }
        self.identity = identity; self.choice = choice; self.retryID = retryID; self.note = note
    }

    public static func accepts(note: String?, for choice: CompanionDecisionChoice) -> Bool {
        guard let note else { return true }
        return choice == .deny && note.contains { !$0.isWhitespace } && note.unicodeScalars.count <= maximumNoteLength
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(CompanionDecisionIdentity.self, forKey: .identity)
        choice = try container.decode(CompanionDecisionChoice.self, forKey: .choice)
        retryID = try container.decode(UUID.self, forKey: .retryID)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        guard Self.accepts(note: note, for: choice) else {
            throw DecodingError.dataCorruptedError(
                forKey: .note, in: container, debugDescription: "A note needs a deny and 1...500 characters")
        }
    }
}
public struct CompanionDecisionReceipt: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable {
        case recorded, alreadyAnswered, expired, unknown, retryConflict, capacityExceeded
    }
    public let identity: CompanionDecisionIdentity
    public let result: Result
    public let state: CompanionDecisionState
    public let choice: CompanionDecisionChoice?
    public let source: CompanionDecisionSource?
    public init(
        identity: CompanionDecisionIdentity, result: Result, state: CompanionDecisionState,
        choice: CompanionDecisionChoice? = nil, source: CompanionDecisionSource? = nil
    ) {
        self.identity = identity; self.result = result; self.state = state
        self.choice = choice; self.source = source
    }
}
