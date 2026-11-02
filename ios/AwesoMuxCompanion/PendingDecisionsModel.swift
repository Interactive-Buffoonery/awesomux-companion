import AwesoMuxCompanionProtocol
import Darwin
import Foundation
import Observation
import UIKit

/// Scene-local decision content. Nothing here is written to caches, widgets or notifications.
@MainActor @Observable
final class PendingDecisionsModel {
    enum Availability { case idle, loading, available, disabled, unavailable, unsupported, denied, capacity, clockChanged }

    private(set) var availability: Availability = .idle
    private(set) var pending: [CompanionPendingDecision] = []
    private(set) var outcomes: [CompanionDecisionReceipt] = []
    private(set) var receipts: [CompanionDecisionReceipt] = []
    private(set) var message: String?
    private(set) var isAnswering = false
    private(set) var isReading = false

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
    private let pairing: () -> UUID?
    private let isUnlocked: () -> Bool
    private let isLocked: () -> Bool
    private let authenticator: any TerminalAuthenticating
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let announce: @MainActor (String) -> Void
    private let read: @MainActor (UUID, @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse
    private let submit: @MainActor (CompanionDecisionAnswer, UUID, @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse
    private var active = false
    private var connection: UUID?
    private var pairedConnection: UUID?
    private var generation = 0
    private var readGeneration = 0
    private var authenticatedAnswer: AuthenticatedAnswer?
    private var attempts: [CompanionDecisionIdentity: Attempt] = [:]
    private var deadlines: [CompanionDecisionIdentity: Deadline] = [:]
    private var closed: [CompanionDecisionIdentity: Deadline] = [:]
    @ObservationIgnored private var wallHighWater = Date.distantPast
    private var clockInvalid = false
    private var announcedOutcomes: [CompanionDecisionIdentity: CompanionDecisionReceipt] = [:]
    private var announcedEvents: [String: TimeInterval] = [:]
    private var lastRead: TimeInterval?

    init(
        session: @escaping () -> UUID?, pairing: (() -> UUID?)? = nil, isUnlocked: @escaping () -> Bool,
        isLocked: @escaping () -> Bool = { false },
        authenticator: any TerminalAuthenticating = DeviceOwnerAuthenticator(
            reason: String(localized: "Authenticate to answer this Claude permission request.")),
        now: @escaping () -> Date = { .now },
        uptime: @escaping () -> TimeInterval = {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        },
        announce: @escaping @MainActor (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) },
        read: @escaping @MainActor (UUID, @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse,
        submit: @escaping @MainActor (CompanionDecisionAnswer, UUID, @escaping @MainActor @Sendable () -> Bool) async throws -> APIResponse
    ) {
        self.session = session
        self.pairing = pairing ?? session
        self.isUnlocked = isUnlocked
        self.isLocked = isLocked
        self.authenticator = authenticator
        self.now = now
        self.uptime = uptime
        self.announce = announce
        self.read = read
        self.submit = submit
    }

    private var canUseContent: Bool {
        active && isUnlocked() && session() != nil && connection == session() && pairedConnection == pairing()
            && !clockInvalid && now() >= wallHighWater.addingTimeInterval(-60)
    }

    func sceneChanged(active: Bool, backgrounded: Bool = false) {
        self.active = active
        synchronizeConnection()
        if !active || !isUnlocked() { clearContent() }
        if backgrounded || isLocked() { invalidateAnswer() }
        _ = observeTime()
    }

    func connectionChanged(denied: Bool = false) {
        synchronizeConnection()
        if denied { availability = .denied }
    }

    private func synchronizeConnection() {
        let changedPairing = pairedConnection != pairing()
        guard changedPairing || connection != session() else { return }
        connection = session()
        pairedConnection = pairing()
        invalidateAnswer()
        clearContent()
        if changedPairing {
            attempts.removeAll()
            deadlines.removeAll()
            closed.removeAll()
            announcedOutcomes.removeAll()
            announcedEvents.removeAll()
            wallHighWater = .distantPast
        }
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
        isReading = false
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
        guard observeTime() else { return }
        let expired = pending.filter { !isLive($0.identity) }
        if !expired.isEmpty {
            pending.removeAll { !isLive($0.identity) }
            message = String(localized: "The remote answer window ended. Check your Mac.")
            for request in expired {
                announceEvent("expiry-\(historyKey(request.identity))", message!)
            }
        }
        if let lastRead, uptime() - lastRead >= 6 {
            clearContent()
            availability = .unavailable
        }
        pruneHistory()
    }

    private var effectiveNow: Date { max(now(), wallHighWater) }

    @discardableResult
    private func observeTime() -> Bool {
        guard !clockInvalid, now() >= wallHighWater.addingTimeInterval(-60) else {
            clockInvalid = true
            invalidateAnswer()
            clearContent()
            message = nil
            availability = .clockChanged
            return false
        }
        wallHighWater = effectiveNow
        return true
    }

    private func pruneHistory() {
        // An immutable wire deadline cannot become live again after clock rollback:
        // the high-water date survives pruning for this pairing.
        func retained(_ deadline: Deadline) -> Bool {
            effectiveNow < deadline.wall.addingTimeInterval(600) || uptime() < deadline.monotonic + 600
        }
        deadlines = deadlines.filter { retained($0.value) }
        closed = closed.filter { retained($0.value) }
        attempts = attempts.filter { $0.value.retainUntil > uptime() }
        let nextReceipts = stableReceipts()
        if receipts != nextReceipts { receipts = nextReceipts }
        announcedEvents = announcedEvents.filter { uptime() - $0.value < 600 }
    }

    private func markClosed(_ identity: CompanionDecisionIdentity) {
        if closed[identity] == nil {
            closed[identity] = deadlines[identity] ?? Deadline(wall: effectiveNow, monotonic: uptime())
        }
    }

    private func stableReceipts() -> [CompanionDecisionReceipt] {
        attempts.values.sorted { $0.answer.retryID.uuidString < $1.answer.retryID.uuidString }.compactMap(\.receipt)
    }

    func refresh() async {
        guard !isAnswering else { return }
        _ = await refreshCurrent()
    }

    @discardableResult
    private func refreshCurrent() async -> Bool {
        synchronizeConnection()
        guard observeTime() else { return false }
        guard canUseContent, let token = session() else { clearContent(); return false }
        readGeneration += 1
        let readID = readGeneration
        let epoch = generation
        pruneHistory()
        isReading = true
        if availability == .idle { availability = .loading }
        defer { if readID == readGeneration { isReading = false } }
        do {
            let response = try await read(token, { [weak self] in
                guard let self else { return false }
                return self.current(token, epoch) && self.readGeneration == readID && self.canUseContent
            })
            if current(token, epoch), readID == readGeneration {
                guard observeTime() else { return false }
            }
            guard current(token, epoch), readID == readGeneration, canUseContent else {
                if readID == readGeneration { clearContent() }
                return false
            }
            guard response.remoteDecisionsEnabled == true else {
                clearContent()
                availability = response.remoteDecisionsEnabled == false ? .disabled : .unsupported
                return false
            }
            guard let requests = response.pendingDecisions, let results = response.decisionOutcomes,
                  requests.count <= 128, results.count <= 512,
                  Set(requests.map(\.identity)).count == requests.count,
                  Set(results.map(\.identity)).count == results.count,
                  results.allSatisfy({ $0.state != .pending }),
                  Set(requests.map(\.identity)).isDisjoint(with: results.map(\.identity)) else {
                throw MacClientFailure.invalidResponse
            }
            let newIdentities = requests.filter { deadlines[$0.identity] == nil && $0.remoteExpiresAt > effectiveNow }
            guard deadlines.count + newIdentities.count <= 512,
                  Set(closed.keys).union(results.map(\.identity)).count <= 1024 else {
                clearContent()
                availability = .capacity
                return false
            }
            for result in results { markClosed(result.identity) }
            for request in requests {
                if let old = deadlines[request.identity] {
                    deadlines[request.identity] = Deadline(wall: min(old.wall, request.remoteExpiresAt),
                        monotonic: min(old.monotonic, uptime() + max(0, request.remoteExpiresAt.timeIntervalSince(effectiveNow))))
                } else if request.remoteExpiresAt > effectiveNow {
                    deadlines[request.identity] = Deadline(wall: request.remoteExpiresAt,
                        monotonic: uptime() + min(60, max(0, request.remoteExpiresAt.timeIntervalSince(effectiveNow))))
                }
            }
            if outcomes != results { outcomes = results }
            let nextPending = requests.filter { request in
                isLive(request.identity) && closed[request.identity] == nil
                    && attempts[request.identity]?.receipt == nil && !request.choices.isEmpty
            }.map { request in
                CompanionPendingDecision(identity: request.identity, tool: String(request.tool.prefix(100)),
                    summary: String(request.summary.prefix(2000)), remoteExpiresAt: request.remoteExpiresAt,
                    choices: request.choices)
            }
            if pending != nextPending { pending = nextPending }
            let nextReceipts = stableReceipts()
            if receipts != nextReceipts { receipts = nextReceipts }
            lastRead = uptime()
            availability = attempts.count >= 128 && requests.contains { attempts[$0.identity] == nil } ? .capacity : .available
            announceChangedOutcomes(results)
            expire()
            return availability == .available
        } catch {
            guard belongs(token, epoch), readID == readGeneration else { return false }
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
        canUseContent && !isAnswering && !isReading && availability == .available && isFresh && isLive(identity)
            && attempts[identity] == nil && closed[identity] == nil && attempts.count < 128
            && pending.contains { $0.identity == identity && $0.choices.contains(choice) }
    }

    func canRetry(_ identity: CompanionDecisionIdentity) -> Bool {
        canUseContent && !isAnswering && !isReading && availability == .available && isFresh && isLive(identity)
            && attempts[identity].map { $0.receipt == nil } == true && closed[identity] == nil
            && pending.contains { $0.identity == identity && $0.choices.contains(attempts[identity]!.answer.choice) }
    }

    private var isFresh: Bool { lastRead.map { uptime() - $0 < 6 } ?? false }

    private func isLive(_ identity: CompanionDecisionIdentity) -> Bool {
        guard let deadline = deadlines[identity] else { return false }
        return effectiveNow < deadline.wall && uptime() < deadline.monotonic
    }

    func answer(_ identity: CompanionDecisionIdentity, choice: CompanionDecisionChoice, note: String? = nil) async {
        synchronizeConnection()
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAnswer(identity, choice: choice),
              let answer = CompanionDecisionAnswer(identity: identity, choice: choice, retryID: UUID(), note: note)
        else { return }
        await authenticate(answer)
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
            announceEvent("authentication-\(epoch)", message!)
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
        defer {
            if belongs(token, epoch) {
                isAnswering = false
                if Task.isCancelled { clearContent() }
            }
        }
        guard current(token, epoch), await refreshCurrent(), current(token, epoch), canUseContent,
              availability == .available, isLive(answer.identity), closed[answer.identity] == nil,
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
                  validReceipt(receipt, for: answer) else { throw MacClientFailure.invalidResponse }
            attempts[answer.identity]?.receipt = receipt
            markClosed(answer.identity)
            receipts = stableReceipts()
            message = nil
            let refusal: String? = switch receipt.result {
            case .expired: String(localized: "The Mac refused this answer because the remote window expired. Check your Mac.")
            case .retryConflict: String(localized: "The Mac refused a conflicting retry. Do not send a different choice; check your Mac.")
            case .capacityExceeded: String(localized: "The Mac could not accept this answer because its decision history is full. Check your Mac.")
            default: nil
            }
            if let refusal {
                announceEvent("refusal-\(answer.retryID)", String(localized: "Request \(String(answer.identity.invocationID.uuidString.prefix(8))): \(refusal)"))
            }
        } catch {
            guard current(token, epoch), canUseContent else { finishLateAnswer(token, epoch); return }
            message = String(localized: "The reply was not confirmed. Refresh status before retrying the same answer.")
            announceEvent("uncertain-\(answer.retryID)", message!)
        }
        guard current(token, epoch) else { return }
        // A stable receipt is not a current delivery update. A failed read clears
        // actionable content while retaining only the in-memory retry tuple.
        _ = await refreshCurrent()
    }

    private func validReceipt(_ receipt: CompanionDecisionReceipt, for answer: CompanionDecisionAnswer) -> Bool {
        switch receipt.result {
        case .expired, .retryConflict, .capacityExceeded: true
        case .recorded: receipt.state != .pending && receipt.choice == answer.choice && receipt.source != nil
        case .alreadyAnswered, .unknown: receipt.state != .pending
        }
    }

    private func historyKey(_ identity: CompanionDecisionIdentity) -> String {
        "\(identity.runtimeID)-\(identity.invocationID)-\(identity.revision)"
    }

    private func announceEvent(_ key: String, _ text: String) {
        guard canUseContent, !Task.isCancelled, announcedEvents.count < 1024,
              announcedEvents[key] == nil else { return }
        announcedEvents[key] = uptime()
        announce(text)
    }

    private func announceChangedOutcomes(_ results: [CompanionDecisionReceipt]) {
        guard canUseContent, !Task.isCancelled else { return }
        let listed = Set(results.map(\.identity))
        announcedOutcomes = announcedOutcomes.filter { listed.contains($0.key) }
        let changed = results.filter { announcedOutcomes[$0.identity] != $0 }
        guard !changed.isEmpty else { return }
        for result in changed { announcedOutcomes[result.identity] = result }
        var sentences = changed.prefix(3).map { result in
            let source = result.source.map { String($0.name.prefix(100)) } ?? String(localized: "not reported")
            let state: String = switch result.state {
            case .pending: String(localized: "pending")
            case .recorded: String(localized: "answer recorded; hook delivery not confirmed")
            case .delivering: String(localized: "answer delivery in progress")
            case .delivered: String(localized: "delivered to the Claude hook; tool execution not confirmed")
            case .cancelled: String(localized: "cancelled")
            case .expired: String(localized: "expired")
            case .unknown: String(localized: "outcome unknown; check your Mac")
            }
            return String(localized: "Request \(String(result.identity.invocationID.uuidString.prefix(8))): \(state). Answer source: \(source).")
        }
        if changed.count > 3 { sentences.append(String(localized: "More permission statuses changed. Review the list.")) }
        announce(sentences.joined(separator: " "))
    }

    private func finishLateAnswer(_ token: UUID, _ epoch: Int) {
        guard belongs(token, epoch) else { return }
        isAnswering = false
        clearContent()
    }

    private func current(_ token: UUID, _ epoch: Int) -> Bool {
        belongs(token, epoch) && session() == token && pairedConnection == pairing() && !Task.isCancelled
    }

    private func belongs(_ token: UUID, _ epoch: Int) -> Bool {
        connection == token && generation == epoch
    }

    func hasAttempt(_ identity: CompanionDecisionIdentity) -> Bool { attempts[identity] != nil }
}
