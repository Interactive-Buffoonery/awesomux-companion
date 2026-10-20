import Foundation
import LocalAuthentication
import Observation

@MainActor
protocol TerminalAuthenticating {
    func authenticate() async -> Bool
    func cancel()
}

@MainActor
final class DeviceOwnerAuthenticator: TerminalAuthenticating {
    private var context: LAContext?

    func authenticate() async -> Bool {
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Unlock your agents and terminals."))
        } catch {
            return false
        }
    }

    func cancel() {
        context?.invalidate()
        context = nil
    }
}

@MainActor @Observable
final class TerminalLockModel {
    static let preferenceKey = "terminalProtectionEnabled"
    static let gracePeriod: TimeInterval = 15

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool {
        didSet { if oldValue != isLocked { securityDidChange?() } }
    }
    private(set) var isActive = false {
        didSet { if oldValue != isActive { securityDidChange?() } }
    }
    @ObservationIgnored var securityDidChange: (() -> Void)?
    private(set) var isAuthenticating = false
    private(set) var authenticationFailed = false

    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private let authenticator: any TerminalAuthenticating
    private var backgroundedAt: TimeInterval?
    private var generation = 0
    private var pendingSuccess: (generation: Int, disabling: Bool)?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        authenticator: any TerminalAuthenticating = DeviceOwnerAuthenticator()
    ) {
        self.defaults = defaults
        self.now = now
        self.authenticator = authenticator
        isEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        isLocked = isEnabled
    }

    func becomeInactive() {
        isActive = false
        // LocalAuthentication itself can make the scene inactive. Only backgrounding
        // invalidates that request; success is withheld until the scene is active.
    }

    func enterBackground() {
        isActive = false
        if backgroundedAt == nil { backgroundedAt = now() }
        invalidateAuthentication()
    }

    func enterForeground() {
        if let backgroundedAt, now() - backgroundedAt >= Self.gracePeriod {
            isLocked = isEnabled
        }
    }

    func becomeActive() {
        synchronizePreference()
        enterForeground()
        backgroundedAt = nil
        isActive = true
        if let pendingSuccess {
            finishAuthentication(generation: pendingSuccess.generation, disabling: pendingSuccess.disabling)
        }
    }

    func synchronizePreference() {
        let enabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
        guard enabled != isEnabled else { return }
        invalidateAuthentication()
        isEnabled = enabled
        isLocked = enabled
    }

    func unlock() async {
        guard isEnabled, isLocked else { return }
        await authenticate(disabling: false)
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            invalidateAuthentication()
            guard !isEnabled else { return }
            isEnabled = true
            isLocked = true
            defaults.set(true, forKey: Self.preferenceKey)
        } else {
            guard isEnabled else { return }
            await authenticate(disabling: true)
        }
    }

    private func authenticate(disabling: Bool) async {
        guard isActive, !isAuthenticating else { return }
        generation += 1
        let request = generation
        authenticationFailed = false
        isAuthenticating = true
        let success = await authenticator.authenticate()
        guard request == generation else { return }
        guard success, !Task.isCancelled else {
            isAuthenticating = false
            authenticationFailed = true
            return
        }
        pendingSuccess = (request, disabling)
        if isActive { finishAuthentication(generation: request, disabling: disabling) }
    }

    private func finishAuthentication(generation request: Int, disabling: Bool) {
        guard request == generation, isActive else { return }
        pendingSuccess = nil
        isAuthenticating = false
        isLocked = false
        if disabling {
            isEnabled = false
            defaults.set(false, forKey: Self.preferenceKey)
        }
    }

    private func invalidateAuthentication() {
        generation += 1
        pendingSuccess = nil
        isAuthenticating = false
        authenticationFailed = false
        authenticator.cancel()
    }
}
