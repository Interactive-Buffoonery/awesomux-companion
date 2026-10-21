import AwesoMuxCompanionProtocol
import Foundation

enum TerminalPreviewPermission: Equatable, Sendable {
    case unknown, unsupported, disabled, enabled
    case updating(Bool)
    case failed(String)

    var allowsPreview: Bool { self == .enabled }
    var canChange: Bool {
        switch self {
        case .enabled, .disabled, .failed: true
        default: false
        }
    }
}

struct PaneWorkspace: Identifiable, Equatable {
    let id: String
    let name: String
    var panes: [ListedPane]
}

struct ListedPane: Identifiable, Equatable {
    enum Kind { case terminal, documents, unknown }
    let id: String
    let title: String
    let kind: Kind
    let availability: String
    let state: String?
    var preview: String?

    var status: String {
        switch availability {
        case "awaitingHydration": return String(localized: "Loading on Mac")
        case "unavailable": return String(localized: "Unavailable")
        case "stale": return String(localized: "Stale")
        case "attached": break
        default: return String(localized: "Status unavailable")
        }
        guard kind == .terminal else {
            return kind == .documents ? String(localized: "Documents") : String(localized: "Unsupported pane")
        }
        switch state {
        case "running", "thinking": return String(localized: "Working")
        case "waiting", "needsAttention": return String(localized: "Waiting for you")
        case "error": return String(localized: "Hit an error")
        case "idle": return String(localized: "Idle")
        case "output", "done": return String(localized: "Done")
        default: return String(localized: "Terminal")
        }
    }
}

enum PaneRosterState: Equatable {
    case idle, loading, unsupported
    case loaded([PaneWorkspace])
    case failed(String)

    var workspaces: [PaneWorkspace] {
        if case .loaded(let workspaces) = self { return workspaces }
        return []
    }
}

/// Memory-only screen content. Neither wire rosters nor previews enter the agent cache.
struct PaneRoster {
    enum Lifecycle { case suspended, active }
    enum PreviewIntent { case followHost, keepOff }
    var state: PaneRosterState = .idle
    var permission: TerminalPreviewPermission = .unknown
    var previewIntent: PreviewIntent = .followHost
    var lifecycle: Lifecycle = .suspended
    private(set) var generation = 0

    mutating func invalidate() { generation += 1 }

    mutating func reset() {
        invalidate()
        state = .idle
        permission = .unknown
        previewIntent = .followHost
    }

    mutating func suspend() {
        lifecycle = .suspended
        invalidate()
        state = .idle
        permission = .unknown
    }

    mutating func clearPreviews() {
        guard case .loaded(var workspaces) = state else { return }
        for workspace in workspaces.indices {
            for pane in workspaces[workspace].panes.indices { workspaces[workspace].panes[pane].preview = nil }
        }
        state = .loaded(workspaces)
    }

    static func permission(_ allowed: Bool?) -> TerminalPreviewPermission {
        switch allowed {
        case true: .enabled
        case false: .disabled
        case nil: .unsupported
        }
    }

    static func project(_ source: [APIResponse.Workspace], previews: Bool) -> [PaneWorkspace] {
        var workspaceIDs = Set<String>()
        var paneIDs = Set<String>()
        return source.compactMap { workspace in
            guard !workspace.workspaceID.isEmpty, workspaceIDs.insert(workspace.workspaceID).inserted else { return nil }
            return PaneWorkspace(id: workspace.workspaceID, name: workspace.name, panes: workspace.panes.compactMap { pane in
                guard !pane.paneID.isEmpty, paneIDs.insert(pane.paneID).inserted else { return nil }
                let kind: ListedPane.Kind = switch pane.kind {
                case "terminal": .terminal
                case "documentGroup": .documents
                default: .unknown
                }
                let preview = previews && kind == .terminal && pane.availability == "attached"
                    ? pane.lastOutputLine : nil
                return ListedPane(id: pane.paneID, title: pane.title, kind: kind,
                                  availability: pane.availability, state: pane.state, preview: preview)
            })
        }
    }
}

extension Error {
    var isCompanionAuthorizationFailure: Bool {
        if self is PhoneIdentity.Failure { return true }
        switch self as? MacClientFailure {
        case .denied, .api("permission_denied"), .api("credential_unavailable"), .api("access_disabled"):
            return true
        default: return false
        }
    }
}

enum CompanionDestination: Hashable {
    case agents, sessions
}

struct FocusedPaneDestination: Equatable {
    let paneID: String
    let destination: CompanionDestination
}
