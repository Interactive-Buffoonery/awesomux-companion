import Foundation

public enum CompanionProtocol {
    public static let version = 1
    public static let maximumRequestBytes = 8 * 1024
    public static let maximumResponseBytes = 256 * 1024
    public static let maximumAttentionPageSize = 100

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date"))
        }
        return decoder
    }
}

public enum CompanionOperation: String, Codable, CaseIterable, Sendable {
    case connectionStatus = "get_connection_status"
    case unpair
    case listAgents = "list_agents"
    case attentionEvents = "get_attention_events"
}

public struct CompanionAPIRequest: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let operation: String
    public let connectionID: UUID
    public let limit: Int?
    public let cursor: String?

    public init(operation: String, connectionID: UUID, limit: Int? = nil, cursor: String? = nil, requestID: UUID = UUID()) {
        schemaVersion = CompanionProtocol.version
        self.requestID = requestID
        self.operation = operation
        self.connectionID = connectionID
        self.limit = limit
        self.cursor = cursor
    }
}

public struct CompanionPairingRequest: Codable, Sendable {
    public let v: Int
    public let op: String
    public let secret: String
    public let phoneName: String

    public init(secret: String, phoneName: String) {
        v = CompanionProtocol.version
        op = "pair"
        self.secret = secret
        self.phoneName = phoneName
    }
}

public struct CompanionPairingReply: Codable, Sendable {
    public let v: Int
    public let status: String
    public let connectionID: UUID?
    public let macName: String?

    public init(status: String, connectionID: UUID? = nil, macName: String? = nil) {
        v = CompanionProtocol.version
        self.status = status
        self.connectionID = connectionID
        self.macName = macName
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(connectionID?.uuidString.lowercased(), forKey: .connectionID)
        try container.encodeIfPresent(macName, forKey: .macName)
    }
}
