import Darwin
import Foundation
import LocalAuthentication
import Observation

@MainActor
protocol TerminalAuthenticating {
    var failureMessage: String? { get }
    func authenticate() async -> Bool
    func cancel()
}

extension TerminalAuthenticating {
    var failureMessage: String? { nil }
}

@MainActor
final class DeviceOwnerAuthenticator: TerminalAuthenticating {
    private var context: LAContext?
    private(set) var failureMessage: String?

    func authenticate() async -> Bool {
        failureMessage = nil
        let context = LAContext()
        self.context = context
        defer { if self.context === context { self.context = nil } }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Unlock your agents and terminals."))
        } catch {
            failureMessage = Self.message(for: error)
            return false
        }
    }

    static func message(for error: Error) -> String? {
        guard (error as? LAError)?.code == .passcodeNotSet else { return nil }
        return String(localized: "Set a device passcode in iOS Settings to unlock awesoMux.")
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

    private(set) var isEnabled = false
    private(set) var isLocked = false {
        didSet { if oldValue != isLocked { securityDidChange?() } }
    }
    private(set) var isActive = false {
        didSet { if oldValue != isActive { securityDidChange?() } }
    }
    @ObservationIgnored var securityDidChange: (() -> Void)?
    private(set) var isAuthenticating = false
    private(set) var authenticationFailureMessage: String? {
        didSet { if oldValue != authenticationFailureMessage { securityDidChange?() } }
    }
    var authenticationFailed: Bool { authenticationFailureMessage != nil }

    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private let authenticator: any TerminalAuthenticating
    private var backgroundedAt: TimeInterval?
    private var generation = 0
    private var pendingSuccess: (generation: Int, disabling: Bool)?

    private var storedPreference: Bool {
        defaults.object(forKey: Self.preferenceKey) as? Bool ?? false
    }

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> TimeInterval = {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            return Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        },
        authenticator: any TerminalAuthenticating = DeviceOwnerAuthenticator()
    ) {
        self.defaults = defaults
        self.now = now
        self.authenticator = authenticator
        let enabled = storedPreference
        isEnabled = enabled
        isLocked = enabled
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
        // Only enterBackground records backgroundedAt, and it invalidates authentication.
        // Applying the grace period here cannot revive a pre-background success.
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
        let enabled = storedPreference
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
        authenticationFailureMessage = nil
        isAuthenticating = true
        let success = await authenticator.authenticate()
        guard request == generation else { return }
        guard success, !Task.isCancelled else {
            isAuthenticating = false
            authenticationFailureMessage = authenticator.failureMessage
                ?? String(localized: "Authentication did not complete. Try again.")
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
        authenticationFailureMessage = nil
        authenticator.cancel()
    }
}
