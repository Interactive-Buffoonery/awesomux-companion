import Foundation
import Observation

struct AnswerContext: Equatable, Sendable { let revision: Int; let generation: String? }

enum HostConnectionState: Equatable { case unconfigured, configured, quarantined(String?), loadFailed }

@MainActor @Observable
final class CompanionStore {
    private(set) var connectionState: HostConnectionState = .unconfigured
    private(set) var activeHostLabel: String?
    var answerContext: AnswerContext { AnswerContext(revision: connectionRevision, generation: snapshot?.generation) }
    var canPair: Bool { connectionState != .loadFailed }
    @ObservationIgnored private var connectionRevision = 0
    @ObservationIgnored private var explicitlyDisconnected = false
    @ObservationIgnored private var configuration: ConnectionConfiguration?
    @ObservationIgnored private let credentials: any HostCredentialStorage
    @ObservationIgnored private let clientFactory: (ConnectionConfiguration) throws -> any BridgeAPI
    #if DEBUG && targetEnvironment(simulator)
    @ObservationIgnored private var developmentConfiguration: DevelopmentConfiguration?
    #endif
    private(set) var snapshot: ThreadSnapshot?
    private(set) var submissions: [String: Submission] = [:]
    private(set) var isFresh = false
    private(set) var active = false
    private(set) var message: String?
    private(set) var earlierOutcomeUnknown = false
    @ObservationIgnored private var api: (any BridgeAPI)?
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var submissionFence: [String: Int] = [:]
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var appliedSequence = 0
    @ObservationIgnored private var freshUntil = 0.0
    @ObservationIgnored private var leaseTask: Task<Void, Never>?
    @ObservationIgnored private let injectedAPI: Bool

    init(api: (any BridgeAPI)? = nil, credentials: (any HostCredentialStorage)? = nil,
         clientFactory: @escaping (ConnectionConfiguration) throws -> any BridgeAPI = { try BridgeClient(configuration: $0) },
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.api = api; self.now = now; injectedAPI = api != nil
        self.clientFactory = clientFactory
        #if DEBUG && targetEnvironment(simulator)
        self.credentials = credentials ?? InMemoryHostCredentialStore()
        #else
        self.credentials = credentials ?? HostCredentialStore()
        #endif
    }
    private func invalidateConnection() {
        earlierOutcomeUnknown = earlierOutcomeUnknown || submissions.values.contains { $0.status != .resolved }
        connectionRevision += 1; epoch += 1; isFresh = false; leaseTask?.cancel()
        api = nil; snapshot = nil; submissions.removeAll(); submissionFence.removeAll()
        #if DEBUG && targetEnvironment(simulator)
        developmentConfiguration = nil
        #endif
    }
    private func loadConnection() throws {
        let next = try credentials.load()
        if let next {
            _ = try next.validatedURL()
            if configuration != next || api == nil {
                invalidateConnection()
                api = try clientFactory(next)
            }
            configuration = next; activeHostLabel = next.hostLabel; connectionState = .configured
            message = nil
        } else {
            #if DEBUG && targetEnvironment(simulator)
            let development = try DevelopmentConfiguration.load()
            if let development {
                if developmentConfiguration != development || api == nil || configuration != nil {
                    invalidateConnection(); api = try BridgeClient(configuration: development)
                }
                developmentConfiguration = development; configuration = nil
                activeHostLabel = "Local Mac"; connectionState = .unconfigured; message = nil
                return
            }
            #endif
            invalidateConnection(); configuration = nil; activeHostLabel = nil; connectionState = .unconfigured
            message = "Connect a host to see your sessions."
        }
    }
    func activate() {
        epoch += 1; active = true; isFresh = false; leaseTask?.cancel()
        guard !injectedAPI, !explicitlyDisconnected else { return }
        switch connectionState {
        case .quarantined, .loadFailed: return
        default: break
        }
        // Retain the same client across ordinary foreground changes; a POST may still settle.
        do { try loadConnection() }
        catch { invalidateConnection(); connectionState = .loadFailed; activeHostLabel = nil; message = "Saved host unavailable. Retry or disconnect to continue." }
    }
    func pair(_ next: ConnectionConfiguration) throws {
        guard canPair else { throw BridgeFailure.invalidConfiguration }
        _ = try next.validatedURL()
        let priorHost = activeHostLabel
        invalidateConnection(); connectionState = .quarantined(priorHost)
        do {
            let candidate = try clientFactory(next)
            try credentials.save(next)
            api = candidate; configuration = next; activeHostLabel = next.hostLabel
            connectionState = .configured; explicitlyDisconnected = false; message = "Connecting to host…"
        } catch { message = "Connection could not be saved. The previous host remains unavailable until you retry."; throw error }
    }
    func disconnectHost() throws {
        let wasLoadFailed = connectionState == .loadFailed
        let priorHost = activeHostLabel
        invalidateConnection(); connectionState = .quarantined(priorHost)
        do {
            try credentials.clear(); configuration = nil; activeHostLabel = nil
            connectionState = .unconfigured; explicitlyDisconnected = true; message = "Connect a host to see your sessions."
        } catch {
            if wasLoadFailed { connectionState = .loadFailed; activeHostLabel = nil }
            message = "Saved connection could not be removed. Retry or disconnect again."; throw error
        }
    }
    func retryConnection() throws {
        explicitlyDisconnected = false
        invalidateConnection()
        do { try loadConnection() }
        catch { connectionState = .loadFailed; activeHostLabel = nil; message = "Saved host unavailable. Retry or disconnect to continue."; throw error }
    }
    func deactivate() { epoch += 1; active = false; isFresh = false; leaseTask?.cancel() }
    func poll() async {
        while active && !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    func refresh() async {
        guard active, let api else { return }
        let requestRevision = connectionRevision
        let requestEpoch = epoch; sequence += 1; let requestSequence = sequence; let sentAt = now()
        do {
            let next = try await api.fetch()
            try Task.checkCancellation()
            guard active, connectionRevision == requestRevision, epoch == requestEpoch, requestSequence > appliedSequence else { return }
            appliedSequence = requestSequence
            if snapshot?.generation != next.generation {
                earlierOutcomeUnknown = earlierOutcomeUnknown || submissions.values.contains { $0.status != .resolved }
                submissions.removeAll(); submissionFence.removeAll()
            }
            snapshot = next
            for (id, var submission) in submissions {
                guard requestSequence > (submissionFence[id] ?? 0) else { continue }
                if next.operations[submission.operation.operationID] == "resolved" || (next.connected && next.error == nil && now() < sentAt + 10 && !next.pending.contains(where: { $0.id == id })) {
                    submission.status = .resolved; submissions[id] = submission
                }
            }
            freshUntil = sentAt + 10
            isFresh = next.connected && next.error == nil && now() < freshUntil
            message = next.error != nil ? "This session is temporarily unavailable." : (next.connected ? nil : "Host disconnected. Showing the last update.")
            leaseTask?.cancel()
            let remaining = max(0, freshUntil - now())
            leaseTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                guard let self, self.epoch == requestEpoch, self.appliedSequence == requestSequence else { return }
                self.isFresh = false
            }
        } catch {
            guard active, connectionRevision == requestRevision, epoch == requestEpoch, requestSequence > appliedSequence else { return }
            appliedSequence = requestSequence
            isFresh = false; leaseTask?.cancel()
            if error is CancellationError { return }
            switch error {
            case BridgeFailure.credentialsRejected: message = "Host credentials were rejected."
            case BridgeFailure.oversizedResponse: message = "This thread is too large to load right now."
            default: message = "Host disconnected. Showing the last update."
            }
        }
    }
    func canAnswer(_ control: PendingControl, context: AnswerContext) -> Bool {
        guard let current = snapshot?.pending.first(where: { $0.id == control.id }) else { return false }
        return context == answerContext && context.generation != nil && active && isFresh && now() < freshUntil
        && snapshot?.connected == true && snapshot?.error == nil && current.status == "pending"
        && current.isSupported && current.questions == control.questions
        && current.priorAttemptUncertain == control.priorAttemptUncertain && submissions[control.id] == nil
    }
    private func valid(_ control: PendingControl, answers: [String: String]) -> Bool {
        guard Set(answers.keys) == Set(control.questions.map(\.id)) else { return false }
        return control.questions.allSatisfy { q in
            guard let answer = answers[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty, answer.count <= 8192 else { return false }
            return q.options == nil || q.isOther || q.options!.contains { $0.label == answer }
        }
    }
    func submit(_ control: PendingControl, context: AnswerContext, answers: [String: String], confirmUncertain: Bool) async {
        guard canAnswer(control, context: context),
              let currentControl = snapshot?.pending.first(where: { $0.id == control.id }),
              valid(currentControl, answers: answers), let generation = context.generation,
              !currentControl.priorAttemptUncertain || confirmUncertain else { return }
        do {
            let operation = try AnswerOperation(control: currentControl, generation: generation, answers: answers, confirmUncertain: confirmUncertain)
            guard operation.body.count <= 65536 else { message = "That answer is too long to send."; return }
            submissionFence[control.id] = sequence
            submissions[control.id] = Submission(operation: operation, status: .submitting)
            await send(operation)
        } catch { message = "That answer could not be prepared." }
    }
    func retry(_ controlID: String, operationID: String, context: AnswerContext) async {
        guard context == answerContext, active, isFresh, now() < freshUntil, let submission = submissions[controlID],
              submission.status == .uncertain, submission.operation.operationID == operationID, snapshot?.generation == submission.operation.generation,
              snapshot?.pending.contains(where: { $0.id == controlID }) == true else { return }
        submissions[controlID]?.status = .submitting
        await send(submission.operation)
    }
    private func send(_ operation: AnswerOperation) async {
        guard let api else { return }
        let requestRevision = connectionRevision
        let result: AnswerReply?
        do { result = try await api.answer(operation) } catch { result = nil }
        guard connectionRevision == requestRevision, snapshot?.generation == operation.generation,
              var local = submissions[operation.controlID], local.operation.operationID == operation.operationID else { return }
        // A newer authoritative snapshot removing this control wins over a late POST.
        guard local.status != .resolved else { return }
        if let result, result.status == 200, result.outcome == "resolved" { local.status = .resolved }
        else if let result, result.status == 202, ["submitted", "submitting", "uncertain"].contains(result.outcome ?? "") {
            local.status = result.outcome == "submitted" ? .submitted : (result.outcome == "submitting" ? .submitting : .uncertain)
        } else if let result, result.status == 409, ["conflict", "already_submitted"].contains(result.outcome ?? "") { local.status = .conflict }
        else if let result, (result.status == 409 && result.outcome == "confirmation_required") || (result.status == 404 && result.outcome == "rejected") || ([400,401,403,413].contains(result.status) && result.error != nil && result.outcome == nil) {
            submissions.removeValue(forKey: operation.controlID); submissionFence.removeValue(forKey: operation.controlID); isFresh = false
            message = result.outcome == "confirmation_required" ? "Check the current question before answering again." : "The answer was not submitted. Refreshing the thread."
            if active { await refresh() }
            return
        } else { local.status = .uncertain }
        submissions[operation.controlID] = local
    }
}
