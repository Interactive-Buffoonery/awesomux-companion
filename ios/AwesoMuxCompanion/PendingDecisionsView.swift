import AwesoMuxCompanionProtocol
import SwiftUI

struct PendingDecisionsSection: View {
    let model: PendingDecisionsModel
    var context: (CompanionDecisionIdentity) -> DecisionContext = { DecisionContext(identity: $0) }

    var body: some View {
        Section {
            Text("Once-only Claude permissions")
                .font(.headline).foregroundStyle(Cat.text)
            Text("Each answer requires Face ID, Touch ID, or your device passcode and a fresh check with your Mac.")
                .font(.footnote).foregroundStyle(Cat.subtext0)
            switch model.availability {
            case .idle, .loading:
                ProgressView("Checking permissions…")
            case .disabled:
                Text("Remote answers are disabled on your Mac. Answer in Claude on your Mac.")
            case .unsupported:
                Text("This Mac does not provide remote permission requests.")
            case .denied:
                Text("Your Mac could not authorize Decide access. Check this iPhone’s workspace grant in Mac settings.")
            case .unavailable:
                Text("Permission status is unavailable. Refresh when your Mac is reachable.")
            case .available:
                if model.pending.isEmpty && model.outcomes.isEmpty && model.receipts.isEmpty {
                    Text("No permission requests available for this iPhone. Decide access is granted per workspace in Mac settings.")
                }
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(Cat.subtext0)
            }
            ForEach(model.pending, id: \.identity) { request in
                VStack(alignment: .leading, spacing: 12) {
                    DecisionContextView(context: context(request.identity))
                    Text(verbatim: request.tool).font(.headline)
                    Text("Request summary from Claude · untrusted content")
                        .font(.caption).foregroundStyle(Cat.subtext0)
                    Text(verbatim: request.summary).font(.callout).textSelection(.enabled)
                    Text("Remote answer window ends \(request.remoteExpiresAt.formatted(date: .omitted, time: .standard)).")
                        .font(.caption).foregroundStyle(Cat.subtext0)
                    if model.hasAttempt(request.identity) {
                        Text("An answer may have reached your Mac. A retry sends only the original answer.")
                            .font(.callout)
                        Button("Retry Same Answer") { Task { await model.retry(request.identity) } }
                            .buttonStyle(.borderless)
                            .disabled(!model.canRetry(request.identity))
                            .accessibilityHint("Authenticates again, checks the Mac, and retries the same choice and request identifier.")
                    } else {
                        // Separate rows keep both choices usable at large text sizes.
                        ForEach(request.choices, id: \.rawValue) { choice in
                            Button(choice == .allow ? "Allow Once" : "Deny Once") {
                                Task { await model.answer(request.identity, choice: choice) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(!model.canAnswer(request.identity, choice: choice))
                            .accessibilityHint("Authenticates before answering this Claude permission request.")
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            ForEach(model.outcomes, id: \.identity) { outcome in
                DecisionOutcomeView(receipt: outcome, isCurrent: true, context: context(outcome.identity))
            }
            ForEach(model.receipts.filter { receipt in !model.outcomes.contains { $0.identity == receipt.identity } }, id: \.identity) { receipt in
                DecisionOutcomeView(receipt: receipt, isCurrent: false, context: context(receipt.identity))
            }
            if model.isAnswering {
                ProgressView("Authenticating and checking your Mac…")
            }
            Button("Refresh Permission Status") { Task { await model.refresh() } }
                .disabled(model.isAnswering)
        } header: {
            Text("Permissions")
        }
        .foregroundStyle(Cat.text)
        .listRowBackground(Cat.card)
    }
}

struct DecisionOutcomeView: View {
    let receipt: CompanionDecisionReceipt
    let isCurrent: Bool
    let context: DecisionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DecisionContextView(context: context)
            Text(isCurrent ? "Latest Mac status" : "Original submission receipt")
                .font(.caption).foregroundStyle(Cat.subtext0)
            Text(status).font(.callout)
            if let choice = receipt.choice {
                Text("Recorded choice: \(choice == .allow ? String(localized: "Allow once") : String(localized: "Deny once"))")
            }
            if let source = receipt.source {
                Text("Answer source: \(source.name)")
            }
            if !isCurrent {
                Text("This receipt stays the same on retries. Refresh for the current outcome.")
                    .font(.footnote).foregroundStyle(Cat.subtext0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch receipt.state {
        case .pending: String(localized: "Pending on your Mac.")
        case .recorded: String(localized: "Answer recorded on your Mac. Hook delivery is not confirmed.")
        case .delivering: String(localized: "Answer recorded; hook delivery is in progress.")
        case .delivered: String(localized: "Delivered to the Claude hook. This does not confirm tool execution.")
        case .cancelled: String(localized: "Request cancelled. No further answer is available here.")
        case .expired: String(localized: "The remote answer window expired. Check your Mac.")
        case .unknown: String(localized: "The outcome is unknown. Check Claude on your Mac; do not send another choice.")
        }
    }
}


struct DecisionContext: Equatable {
    let workspace: String?
    let pane: String?
    let identity: CompanionDecisionIdentity

    init(workspace: String? = nil, pane: String? = nil, identity: CompanionDecisionIdentity) {
        self.workspace = workspace.map { String($0.prefix(100)) }
        self.pane = pane.map { String($0.prefix(100)) }
        self.identity = identity
    }

    var workspaceLabel: String { workspace ?? identity.workspaceID.uuidString }
    var paneLabel: String { pane ?? identity.paneID.uuidString }
    var requestLabel: String { "\(identity.invocationID.uuidString) · r\(identity.revision)" }
}

private struct DecisionContextView: View {
    let context: DecisionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Workspace: \(context.workspaceLabel)").font(.subheadline.bold())
            Text("Pane: \(context.paneLabel)").font(.subheadline)
            Text("Request: \(context.requestLabel)").font(.caption).foregroundStyle(Cat.subtext0)
        }
        .accessibilityElement(children: .combine)
    }
}
