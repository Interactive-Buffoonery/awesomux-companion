import os
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
    private let reason: String

    init(reason: String = String(localized: "Unlock your agents and terminals.")) {
        self.reason = reason
    }
    private(set) var failureMessage: String?

    func authenticate() async -> Bool {
        failureMessage = nil
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        self.context = context
        defer { if self.context === context { self.context = nil } }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason)
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

    private(set) var isEnabled = false {
        didSet { if (oldValue && sessionLocked) != isLocked { notifySecurityChange() } }
    }
    var isLocked: Bool { isEnabled && sessionLocked }
    private var sessionLocked = true {
        didSet { if (isEnabled && oldValue) != isLocked { notifySecurityChange() } }
    }
    private(set) var isActive = false {
        didSet { if oldValue != isActive { notifySecurityChange() } }
    }
    @ObservationIgnored var securityDidChange: (() -> Void)?
    @ObservationIgnored private var securityObservers: [UUID: () -> Void] = [:]

    func observeSecurityChanges(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        securityObservers[id] = observer
        return id
    }

    func removeSecurityObserver(_ id: UUID) {
        securityObservers[id] = nil
    }

    private func notifySecurityChange() {
        WatchDiagnostics.lifecycle.notice("security_changed origin=lifecycle active=\(self.isActive) locked=\(self.isLocked) lock_enabled=\(self.isEnabled) authenticating=\(self.isAuthenticating)")
        securityDidChange?()
        for observer in Array(securityObservers.values) { observer() }
    }

    private(set) var isAuthenticating = false
    private(set) var authenticationFailureMessage: String? {
        didSet { if oldValue != authenticationFailureMessage { notifySecurityChange() } }
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
        isEnabled = storedPreference
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
            sessionLocked = true
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
        if enabled { sessionLocked = true }
        isEnabled = enabled
    }

    func unlock() async {
        guard isEnabled, isLocked else { return }
        await authenticate(disabling: false)
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            invalidateAuthentication()
            guard !isEnabled else { return }
            sessionLocked = true
            isEnabled = true
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
        if disabling {
            isEnabled = false
            defaults.set(false, forKey: Self.preferenceKey)
        } else {
            sessionLocked = false
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
