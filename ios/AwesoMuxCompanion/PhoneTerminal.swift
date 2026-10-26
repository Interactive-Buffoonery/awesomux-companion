import AwesoMuxCompanionProtocol
import Foundation
import Observation

enum TerminalOpening: Hashable { case input, watch }

struct TerminalDestination: Hashable {
    let paneID: UUID
    let targetVersion: UUID
    var title = ""
    var opening = TerminalOpening.input
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

    func create(workspaceID: UUID?, canCreate: @escaping @MainActor () -> Bool,
                send: (UUID?) async throws -> CreatedTerminal, refresh: () async -> Void) async {
        guard !isCreating, canCreate() else { return }
        isCreating = true
        error = nil
        defer { isCreating = false }
        do {
            let created = try await send(workspaceID)
            guard !Task.isCancelled, canCreate() else { return }
            destination = TerminalDestination(paneID: created.paneID, targetVersion: created.targetVersion,
                                              title: String(localized: "Terminal"))
        } catch {
            guard !Task.isCancelled, canCreate() else { return }
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
