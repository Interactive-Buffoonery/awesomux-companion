import AwesoMuxCompanionProtocol
import Darwin
import Foundation
import Observation

/// Scene-local decision content. Nothing here is written to caches, widgets or notifications.
@MainActor @Observable
final class PendingDecisionsModel {
    enum Availability { case idle, loading, available, disabled, unavailable, unsupported, denied }

    private(set) var availability: Availability = .idle
    private(set) var pending: [CompanionPendingDecision] = []
    private(set) var outcomes: [CompanionDecisionReceipt] = []
    private(set) var receipts: [CompanionDecisionReceipt] = []
    private(set) var message: String?
    private(set) var isAnswering = false

    private struct Deadline {
        let wall: Date
        let monotonic: TimeInterval
    }
    private struct Attempt {
        let answer: CompanionDecisionAnswer
        let retainUntil: TimeInterval
        var receipt: CompanionDecisionReceipt?
    }
    private struct AuthenticatedAnswer {
        let answer: CompanionDecisionAnswer
        let session: UUID
        let generation: Int
    }

    private let session: () -> UUID?
    private let isUnlocked: () -> Bool
    private let isLocked: () -> Bool
    private let authenticator: any TerminalAuthenticating
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let read: (UUID) async throws -> APIResponse
    private let submit: (CompanionDecisionAnswer, UUID, @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse
    private var active = false
    private var connection: UUID?
    private var generation = 0
    private var readGeneration = 0
    private var authenticatedAnswer: AuthenticatedAnswer?
    private var attempts: [CompanionDecisionIdentity: Attempt] = [:]
    private var deadlines: [CompanionDecisionIdentity: Deadline] = [:]
    private var closed: Set<CompanionDecisionIdentity> = []
    private var lastRead: TimeInterval?

    init(
        session: @escaping () -> UUID?, isUnlocked: @escaping () -> Bool,
        isLocked: @escaping () -> Bool = { false },
        authenticator: any TerminalAuthenticating = DeviceOwnerAuthenticator(
            reason: String(localized: "Authenticate to answer this Claude permission request.")),
        now: @escaping () -> Date = { .now },
        uptime: @escaping () -> TimeInterval = {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        },
        read: @escaping (UUID) async throws -> APIResponse,
        submit: @escaping (CompanionDecisionAnswer, UUID, @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse
    ) {
        self.session = session
        self.isUnlocked = isUnlocked
        self.isLocked = isLocked
        self.authenticator = authenticator
        self.now = now
        self.uptime = uptime
        self.read = read
        self.submit = submit
    }

    private var canUseContent: Bool { active && isUnlocked() && session() != nil }

    func sceneChanged(active: Bool, backgrounded: Bool = false) {
        self.active = active
        synchronizeConnection()
        if !active || !isUnlocked() { clearContent() }
        if backgrounded || isLocked() { invalidateAnswer() }
    }

    func connectionChanged(denied: Bool = false) {
        synchronizeConnection()
        if denied { availability = .denied }
    }

    private func synchronizeConnection() {
        guard connection != session() else { return }
        connection = session()
        invalidateAnswer()
        clearContent()
        attempts.removeAll()
        deadlines.removeAll()
        closed.removeAll()
        receipts.removeAll()
        message = nil
        availability = .idle
    }

    private func invalidateAnswer() {
        generation += 1
        authenticatedAnswer = nil
        isAnswering = false
        authenticator.cancel()
    }

    private func clearContent() {
        readGeneration += 1
        pending.removeAll()
        outcomes.removeAll()
        receipts.removeAll()
        lastRead = nil
        availability = .idle
    }

    func poll() async {
        await resumeAuthenticatedAnswer()
        while !Task.isCancelled, canUseContent {
            if !isAnswering { await refresh() }
            for _ in 0..<5 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                expire()
                guard canUseContent else { return }
            }
        }
    }

    func expire() {
        let count = pending.count
        pending.removeAll { !isLive($0.identity) }
        if pending.count < count {
            message = String(localized: "The remote answer window ended. Check your Mac.")
        }
        // A read older than one foreground poll is never authority to start an answer.
        if let lastRead, uptime() - lastRead >= 6 {
            pending.removeAll()
            self.lastRead = nil
            availability = .unavailable
        }
        // Keep tombstones until the scene model is discarded or pairing changes. Refuse
        // new identities at the bound rather than allow a remembered answer to reopen.
        attempts = attempts.filter { $0.value.retainUntil > uptime() }
        receipts = receipts.filter { attempts[$0.identity] != nil }
    }

    func refresh() async {
        guard !isAnswering else { return }
        _ = await refreshCurrent()
    }

    @discardableResult
    private func refreshCurrent() async -> Bool {
        synchronizeConnection()
        guard canUseContent, let token = session() else { clearContent(); return false }
        readGeneration += 1
        let readID = readGeneration
        let epoch = generation
        pending.removeAll()
        outcomes.removeAll()
        lastRead = nil
        availability = .loading
        do {
            let response = try await read(token)
            guard current(token, epoch), readID == readGeneration, canUseContent else {
                if readID == readGeneration { clearContent() }
                return false
            }
            guard response.remoteDecisionsEnabled == true else {
                availability = response.remoteDecisionsEnabled == false ? .disabled : .unsupported
                return false
            }
            guard let requests = response.pendingDecisions, let results = response.decisionOutcomes,
                  requests.count <= 128, results.count <= 512,
                  Set(requests.map(\.identity)).count == requests.count,
                  Set(results.map(\.identity)).count == results.count,
                  results.allSatisfy({ $0.state != .pending }),
                  Set(requests.map(\.identity)).isDisjoint(with: results.map(\.identity)),
                  closed.union(results.map(\.identity)).count <= 1024 else {
                throw MacClientFailure.invalidResponse
            }
            for result in results { closed.insert(result.identity) }
            for request in requests {
                if let old = deadlines[request.identity] {
                    deadlines[request.identity] = Deadline(wall: min(old.wall, request.remoteExpiresAt),
                        monotonic: min(old.monotonic, uptime() + max(0, request.remoteExpiresAt.timeIntervalSince(now()))))
                } else if deadlines.count < 512 {
                    deadlines[request.identity] = Deadline(wall: request.remoteExpiresAt,
                        monotonic: uptime() + min(60, max(0, request.remoteExpiresAt.timeIntervalSince(now()))))
                }
            }
            outcomes = results
            pending = requests.filter { request in
                isLive(request.identity) && !closed.contains(request.identity)
                    && attempts[request.identity]?.receipt == nil && !request.choices.isEmpty
            }.map { request in
                CompanionPendingDecision(identity: request.identity, tool: String(request.tool.prefix(100)),
                    summary: String(request.summary.prefix(2000)), remoteExpiresAt: request.remoteExpiresAt,
                    choices: request.choices)
            }
            receipts = attempts.values.compactMap(\.receipt)
            lastRead = uptime()
            availability = .available
            expire()
            return true
        } catch {
            guard current(token, epoch), readID == readGeneration else { return false }
            clearContent()
            if (error as? MacClientFailure) == .api("unsupported_operation") {
                availability = .unsupported
            } else if error.isCompanionAuthorizationFailure {
                availability = .denied
            } else {
                availability = .unavailable
            }
            return false
        }
    }

    func canAnswer(_ identity: CompanionDecisionIdentity, choice: CompanionDecisionChoice) -> Bool {
        canUseContent && !isAnswering && availability == .available && isFresh && isLive(identity)
            && attempts[identity] == nil && !closed.contains(identity) && attempts.count < 128
            && pending.contains { $0.identity == identity && $0.choices.contains(choice) }
    }

    func canRetry(_ identity: CompanionDecisionIdentity) -> Bool {
        canUseContent && !isAnswering && availability == .available && isFresh && isLive(identity)
            && attempts[identity].map { $0.receipt == nil } == true && !closed.contains(identity)
            && pending.contains { $0.identity == identity && $0.choices.contains(attempts[identity]!.answer.choice) }
    }

    private var isFresh: Bool { lastRead.map { uptime() - $0 < 6 } ?? false }

    private func isLive(_ identity: CompanionDecisionIdentity) -> Bool {
        guard let deadline = deadlines[identity] else { return false }
        return now() < deadline.wall && uptime() < deadline.monotonic
    }

    func answer(_ identity: CompanionDecisionIdentity, choice: CompanionDecisionChoice) async {
        synchronizeConnection()
        guard canAnswer(identity, choice: choice) else { return }
        await authenticate(CompanionDecisionAnswer(identity: identity, choice: choice, retryID: UUID()))
    }

    func retry(_ identity: CompanionDecisionIdentity) async {
        synchronizeConnection()
        guard canRetry(identity), let attempt = attempts[identity] else { return }
        await authenticate(attempt.answer)
    }

    private func authenticate(_ answer: CompanionDecisionAnswer) async {
        guard let token = session() else { return }
        isAnswering = true
        message = nil
        generation += 1
        let epoch = generation
        let success = await authenticator.authenticate()
        guard current(token, epoch) else {
            if belongs(token, epoch) { invalidateAnswer(); clearContent() }
            return
        }
        guard success, !Task.isCancelled else {
            isAnswering = false
            message = authenticator.failureMessage ?? String(localized: "Authentication did not complete. No answer was sent.")
            return
        }
        authenticatedAnswer = AuthenticatedAnswer(answer: answer, session: token, generation: epoch)
        // The system authentication sheet can temporarily deactivate the scene.
        // Backgrounding invalidates this success; temporary inactivity only withholds it.
        await resumeAuthenticatedAnswer()
    }

    func resumeAuthenticatedAnswer() async {
        guard canUseContent, let authenticated = authenticatedAnswer else { return }
        authenticatedAnswer = nil
        let answer = authenticated.answer
        let token = authenticated.session
        let epoch = authenticated.generation
        guard current(token, epoch), await refreshCurrent(), current(token, epoch), canUseContent,
              availability == .available, isLive(answer.identity), !closed.contains(answer.identity),
              pending.contains(where: { $0.identity == answer.identity && $0.choices.contains(answer.choice) }) else {
            if current(token, epoch) {
                isAnswering = false
                message = String(localized: "The request is no longer available. Check its latest status on your Mac.")
            }
            return
        }
        // Retain the tuple before the first byte could leave. No route failover or
        // poll may submit it automatically, and a different choice cannot replace it.
        if attempts[answer.identity] == nil {
            guard attempts.count < 128 else { isAnswering = false; return }
            attempts[answer.identity] = Attempt(answer: answer, retainUntil: uptime() + 600)
        }
        do {
            let response = try await submit(answer, token, { [weak self] in
                guard let self else { return false }
                return self.current(token, epoch) && self.canUseContent && self.isLive(answer.identity)
            })
            guard current(token, epoch), canUseContent else { finishLateAnswer(token, epoch); return }
            guard let receipt = response.decisionReceipt, receipt.identity == answer.identity,
                  receipt.state != .pending,
                  receipt.result != .recorded || (receipt.choice == answer.choice && receipt.source != nil) else {
                throw MacClientFailure.invalidResponse
            }
            attempts[answer.identity]?.receipt = receipt
            closed.insert(answer.identity)
            receipts = attempts.values.compactMap(\.receipt)
            message = nil
        } catch {
            guard current(token, epoch), canUseContent else { finishLateAnswer(token, epoch); return }
            message = String(localized: "The reply was not confirmed. Refresh status before retrying the same answer.")
        }
        guard current(token, epoch) else { return }
        // A stable receipt is not a current delivery update. A failed read clears
        // actionable content while retaining only the in-memory retry tuple.
        _ = await refreshCurrent()
        if current(token, epoch) { isAnswering = false }
    }

    private func finishLateAnswer(_ token: UUID, _ epoch: Int) {
        guard belongs(token, epoch) else { return }
        isAnswering = false
        clearContent()
    }

    private func current(_ token: UUID, _ epoch: Int) -> Bool {
        belongs(token, epoch) && !Task.isCancelled
    }

    private func belongs(_ token: UUID, _ epoch: Int) -> Bool {
        session() == token && generation == epoch
    }

    func hasAttempt(_ identity: CompanionDecisionIdentity) -> Bool { attempts[identity] != nil }
}
