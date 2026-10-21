import LocalAuthentication
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class TerminalLockModelTests: XCTestCase {
    // Failure modes: the old absent-key default must not become consent, while
    // persisted true was only written by an explicit enable in previous builds.
    func testFreshAndLegacyDefaultsStayUnlockedWithoutAuthentication() async {
        for storedValue in [nil, false] as [Bool?] {
            let fixture = Fixture(enabled: storedValue)
            XCTAssertFalse(fixture.model.isEnabled)
            XCTAssertFalse(fixture.model.isLocked)
            fixture.model.becomeActive()
            await fixture.model.unlock()
            fixture.model.enterBackground()
            fixture.clock.time += TerminalLockModel.gracePeriod
            fixture.model.becomeActive()
            XCTAssertFalse(fixture.model.isLocked)
            XCTAssertEqual(fixture.auth.requestCount, 0)
            XCTAssertEqual(fixture.defaults.object(forKey: TerminalLockModel.preferenceKey) as? Bool, storedValue)
        }
    }

    func testLegacyExplicitEnableRemainsLocked() {
        let fixture = Fixture(enabled: true)
        XCTAssertTrue(fixture.model.isEnabled)
        XCTAssertTrue(fixture.model.isLocked)
    }

    func testExplicitProtectionOptInPersistsAuthenticatedDisable() async {
        let fixture = Fixture()
        XCTAssertTrue(fixture.model.isEnabled)
        XCTAssertTrue(fixture.model.isLocked)
        fixture.model.becomeActive()
        let request = await fixture.start { await fixture.model.setEnabled(false) }
        XCTAssertTrue(fixture.model.isEnabled)
        XCTAssertTrue(fixture.model.isLocked)
        fixture.auth.finish(true)
        await request.value
        XCTAssertFalse(fixture.model.isEnabled)
        XCTAssertFalse(fixture.model.isLocked)
        let restored = TerminalLockModel(defaults: fixture.defaults, authenticator: fixture.auth)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertFalse(restored.isLocked)
    }

    func testMissingPasscodeExplainsRecoveryWithoutUnlocking() async {
        let fixture = Fixture()
        fixture.auth.failureMessage = DeviceOwnerAuthenticator.message(for: LAError(.passcodeNotSet))
        XCTAssertNotNil(fixture.auth.failureMessage)
        XCTAssertNil(DeviceOwnerAuthenticator.message(for: LAError(.userCancel)))
        fixture.model.becomeActive()
        let request = await fixture.start { await fixture.model.unlock() }
        fixture.auth.finish(false)
        await request.value
        XCTAssertTrue(fixture.model.isLocked)
        XCTAssertTrue(fixture.model.isEnabled)
        XCTAssertEqual(fixture.model.authenticationFailureMessage, fixture.auth.failureMessage)
    }

    func testFailureAndRetryNotifyPrivacyObserverSynchronously() async {
        let fixture = Fixture()
        fixture.model.becomeActive()
        var messages: [String?] = []
        fixture.model.securityDidChange = { messages.append(fixture.model.authenticationFailureMessage) }
        defer { fixture.model.securityDidChange = nil }
        let request = await fixture.start { await fixture.model.unlock() }
        fixture.auth.finish(false)
        await request.value
        let failure = fixture.model.authenticationFailureMessage
        XCTAssertNotNil(failure)
        XCTAssertEqual(messages, [failure])

        let retry = await fixture.start { await fixture.model.unlock() }
        XCTAssertEqual(messages, [failure, nil])
        fixture.auth.finish(false)
        await retry.value
    }

    func testGraceExpiresAtFifteenSecondsAndNotBefore() async {
        for duration in [14.999, 15, 16] {
            let fixture = Fixture()
            await fixture.unlock()
            fixture.model.becomeInactive()
            fixture.model.enterBackground()
            fixture.clock.time += duration
            fixture.model.enterForeground()
            XCTAssertFalse(fixture.model.isActive)
            fixture.model.becomeActive()
            XCTAssertEqual(fixture.model.isLocked, duration >= 15, "duration: \(duration)")
        }
    }

    func testRepeatedBackgroundDoesNotExtendGrace() async {
        let fixture = Fixture()
        await fixture.unlock()
        fixture.model.enterBackground()
        fixture.clock.time += 10
        fixture.model.enterBackground()
        fixture.clock.time += 5
        fixture.model.becomeActive()
        XCTAssertTrue(fixture.model.isLocked)
    }

    func testFailedOrCanceledAuthenticationKeepsGateAndPreference() async {
        let fixture = Fixture()
        fixture.model.becomeActive()
        for disabling in [false, true] {
            let request = await fixture.start {
                if disabling { await fixture.model.setEnabled(false) }
                else { await fixture.model.unlock() }
            }
            fixture.auth.finish(false)
            await request.value
            XCTAssertTrue(fixture.model.isLocked)
            XCTAssertTrue(fixture.model.isEnabled)
            XCTAssertTrue(fixture.model.authenticationFailed)
            XCTAssertEqual(fixture.defaults.object(forKey: TerminalLockModel.preferenceKey) as? Bool, true)
        }
    }

    func testTaskCancellationCannotUnlockEvenIfAuthenticatorSucceeds() async {
        let fixture = Fixture()
        fixture.model.becomeActive()
        let request = await fixture.start { await fixture.model.unlock() }
        request.cancel()
        fixture.auth.finish(true)
        await request.value
        XCTAssertTrue(fixture.model.isLocked)
    }

    func testBackgroundInvalidatesUnlockAndDisableCompletions() async {
        for disabling in [false, true] {
            let fixture = Fixture()
            fixture.model.becomeActive()
            let request = await fixture.start {
                if disabling { await fixture.model.setEnabled(false) }
                else { await fixture.model.unlock() }
            }
            fixture.model.enterBackground()
            fixture.model.becomeActive()
            fixture.auth.finish(true)
            await request.value
            XCTAssertTrue(fixture.model.isLocked)
            XCTAssertTrue(fixture.model.isEnabled)
            XCTAssertFalse(fixture.model.isAuthenticating)
        }
    }

    func testToggleInvalidatesPendingDisableCompletion() async {
        let fixture = Fixture()
        fixture.model.becomeActive()
        let request = await fixture.start { await fixture.model.setEnabled(false) }
        await fixture.model.setEnabled(true)
        fixture.auth.finish(true)
        await request.value
        XCTAssertTrue(fixture.model.isEnabled)
        XCTAssertTrue(fixture.model.isLocked)
    }

    func testInactiveAuthenticationWaitsForActiveAndBackgroundDiscardsIt() async {
        for background in [false, true] {
            let fixture = Fixture()
            fixture.model.becomeActive()
            let request = await fixture.start { await fixture.model.unlock() }
            fixture.model.becomeInactive()
            fixture.auth.finish(true)
            await request.value
            XCTAssertTrue(fixture.model.isLocked)
            if background { fixture.model.enterBackground() }
            fixture.model.becomeActive()
            XCTAssertEqual(fixture.model.isLocked, background)
        }
    }

    func testEnablingProtectionImmediatelyLocksAndPersistsAcrossLaunch() async {
        let fixture = Fixture()
        fixture.defaults.set(false, forKey: TerminalLockModel.preferenceKey)
        let model = TerminalLockModel(defaults: fixture.defaults, authenticator: fixture.auth)
        model.becomeActive()
        await model.setEnabled(true)
        XCTAssertTrue(model.isLocked)
        let restored = TerminalLockModel(defaults: fixture.defaults, authenticator: fixture.auth)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertTrue(restored.isLocked)
    }

    func testPendingSuccessCannotSurviveBackgroundGraceExpiry() async {
        let fixture = Fixture()
        fixture.model.becomeActive()
        let request = await fixture.start { await fixture.model.unlock() }
        fixture.model.becomeInactive()
        fixture.auth.finish(true)
        await request.value
        fixture.model.enterBackground()
        fixture.clock.time += TerminalLockModel.gracePeriod
        fixture.model.enterForeground()
        fixture.model.becomeActive()
        XCTAssertTrue(fixture.model.isLocked)
        XCTAssertTrue(fixture.model.isEnabled)
        XCTAssertFalse(fixture.model.isAuthenticating)
    }

    func testExternalPreferenceChangeInvalidatesPendingSuccess() async {
        for completesWhileInactive in [false, true] {
            let fixture = Fixture()
            fixture.model.becomeActive()
            let request = await fixture.start { await fixture.model.unlock() }
            fixture.model.becomeInactive()
            if completesWhileInactive {
                fixture.auth.finish(true)
                await request.value
            }
            fixture.defaults.set(false, forKey: TerminalLockModel.preferenceKey)
            fixture.model.synchronizePreference()
            fixture.defaults.set(true, forKey: TerminalLockModel.preferenceKey)
            fixture.model.becomeActive()
            if !completesWhileInactive {
                fixture.auth.finish(true)
                await request.value
            }
            XCTAssertTrue(fixture.model.isLocked)
            XCTAssertTrue(fixture.model.isEnabled)
            XCTAssertFalse(fixture.model.isAuthenticating)
        }
    }

    func testScenesSharePreferenceButNotUnlockedSessions() async {
        let fixture = Fixture()
        let other = TerminalLockModel(defaults: fixture.defaults, authenticator: fixture.auth)
        await fixture.unlock()
        other.becomeActive()
        XCTAssertTrue(other.isLocked)
        let request = await fixture.start { await fixture.model.setEnabled(false) }
        fixture.auth.finish(true)
        await request.value
        other.synchronizePreference()
        XCTAssertFalse(other.isEnabled)
        await fixture.model.setEnabled(true)
        other.synchronizePreference()
        XCTAssertTrue(other.isEnabled)
        XCTAssertTrue(other.isLocked)
    }

    func testInactiveRequestsDoNotStartAuthentication() async {
        let fixture = Fixture()
        await fixture.model.unlock()
        await fixture.model.setEnabled(false)
        XCTAssertFalse(fixture.model.isAuthenticating)
        XCTAssertTrue(fixture.model.isLocked)
        XCTAssertEqual(fixture.auth.requestCount, 0)
    }
}

@MainActor
private final class Fixture {
    let suite = "TerminalLockTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let auth = ControlledAuthenticator()
    let clock: TestClock
    let model: TerminalLockModel

    init(enabled: Bool? = true) {
        defaults = UserDefaults(suiteName: suite)!
        if let enabled { defaults.set(enabled, forKey: TerminalLockModel.preferenceKey) }
        let clock = TestClock()
        self.clock = clock
        model = TerminalLockModel(defaults: defaults, now: { [clock] in clock.time }, authenticator: auth)
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    func start(_ action: @escaping @MainActor () async -> Void) async -> Task<Void, Never> {
        let task = Task { await action() }
        await auth.waitForRequest()
        return task
    }

    func unlock() async {
        model.becomeActive()
        let request = await start { await self.model.unlock() }
        auth.finish(true)
        await request.value
    }
}

@MainActor
private final class TestClock {
    var time: TimeInterval = 100
}

@MainActor
private final class ControlledAuthenticator: TerminalAuthenticating {
    var failureMessage: String?
    private var completion: CheckedContinuation<Bool, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    func authenticate() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            completion = continuation
            started?.resume()
            started = nil
        }
    }

    func waitForRequest() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ success: Bool) {
        let continuation = completion
        completion = nil
        continuation?.resume(returning: success)
    }

    // Deliberately retain the continuation to simulate an uncooperative stale reply.
    func cancel() {}
}
