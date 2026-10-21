import Foundation

public enum CompanionAlertCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case permission
    case waiting
    case error
    case commandFailed
    case commandCompleted
}

/// Pairing-local delivery preferences. Authorization and presence remain host policy.
public struct CompanionAlertPreferences: Codable, Equatable, Sendable {
    public let categories: Set<CompanionAlertCategory>

    public init(categories: Set<CompanionAlertCategory> = Set(CompanionAlertCategory.allCases)) {
        self.categories = categories
    }

    private enum CodingKeys: String, CodingKey {
        case categories
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CompanionAlertCategory.allCases.filter(categories.contains), forKey: .categories)
    }
}
