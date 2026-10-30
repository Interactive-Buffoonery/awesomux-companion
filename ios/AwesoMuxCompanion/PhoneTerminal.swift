import AwesoMuxCompanionProtocol
import Foundation
import Observation

struct TerminalDestination: Hashable {
    let paneID: UUID
    let targetVersion: UUID
    var title = ""
    var workspace = ""
    /// The Mac this pane is on; a terminal connects only through that Mac's pairing.
    var macFingerprint = ""
    var host = ""

    /// Stamps the Mac whose list opened it.
    func on(_ record: PairingRecord?) -> TerminalDestination {
        var target = self
        target.macFingerprint = record?.macFingerprint ?? ""
        target.host = record?.macName ?? ""
        return target
    }

    var path: String {
        let pane = title.isEmpty ? String(localized: "Terminal") : title
        return workspace.isEmpty ? pane : "\(workspace)/\(pane)"
    }

    /// The host is always named, so a long pane or workspace can never hide which Mac receives typing.
    static func hostName(_ macName: String?) -> String {
        guard let macName, !macName.isEmpty else { return String(localized: "Mac") }
        return macName
    }

    func accessibilityHeader(host: String) -> String {
        let pane = title.isEmpty ? String(localized: "Terminal") : title
        return workspace.isEmpty ? String(localized: "\(pane) on \(host)")
            : String(localized: "\(pane) in \(workspace) on \(host)")
    }
}

struct TerminalAccess: Equatable {
    var inputAllowed = false
    var createWorkspaceAllowed = false
    var createPaneAllowed = false

    init() {}

    init(_ status: APIResponse) {
        inputAllowed = status.terminalInputAllowed == true
        createWorkspaceAllowed = inputAllowed && status.createWorkspaceAllowed == true
        createPaneAllowed = inputAllowed && status.createPaneAllowed == true
    }
}

struct CreateTerminalRequest: Encodable, Sendable {
    let schemaVersion = CompanionProtocol.version
    let requestID = UUID()
    let operation = "create_terminal"
    let connectionID: UUID
    let workspaceID: UUID?
}

struct CreatedTerminal: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let paneID: UUID
    let targetVersion: UUID
}

struct CreateTerminalResponse: Codable, Sendable {
    let schemaVersion: Int
    let requestID: UUID?
    let error: String?
    let createdTerminal: CreatedTerminal?
}

@MainActor @Observable
final class TerminalCreationModel {
    private(set) var isCreating = false
    var destination: TerminalDestination?
    var error: String?

    /// `isCurrent` is the same visible pairing; `canCreate` is the Mac's grant, which may change mid-request.
    func create(workspaceID: UUID?, workspaceName: String = "", isCurrent: @escaping @MainActor () -> Bool,
                canCreate: @escaping @MainActor () -> Bool,
                send: (UUID?) async throws -> CreatedTerminal, refresh: () async -> Void) async {
        guard !isCreating, isCurrent(), canCreate() else { return }
        isCreating = true
        error = nil
        defer { isCreating = false }
        do {
            let created = try await send(workspaceID)
            guard !Task.isCancelled, isCurrent() else { return }
            if canCreate() {
                destination = TerminalDestination(paneID: created.paneID, targetVersion: created.targetVersion,
                                                  title: String(localized: "Terminal"), workspace: workspaceName)
            } else {
                self.error = String(localized: "Access changed on the Mac. Check Sessions for the new terminal.")
            }
        } catch {
            guard !Task.isCancelled, isCurrent() else { return }
            if let failure = error as? MacClientFailure, case .api = failure {
                self.error = WatchModel.message(for: error)
            } else {
                self.error = String(localized: "Couldn't confirm the new terminal. Check Sessions before trying again.")
            }
        }
        // A lost acknowledgement may still have created a terminal. Never replay the write.
        await refresh()
    }
}
