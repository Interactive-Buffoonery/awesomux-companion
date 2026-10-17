# Physical foreground adversarial plan review

Adapter Claude Code; actual model claude-opus-5-5. Tools/settings/hooks/MCP disabled. Scope manifest physical-plan-refresh-scope.json.

# Verdict: not ready to implement as written. Three blockers remain.

Most of the initial blockers are resolved:

- **Endpoint/token binding:** the plan already requires revision + generation + operation identity on late results.
- **Challenge handling:** ServerTrust uses default handling and every other challenge is cancelled.
- **Keychain writes:** atomic `SecItemUpdate`, with add only on not-found.
- **Serve concurrency:** `If-Match` ETag plus foreground-session scoping covers concurrent Serve changes.
- **Signing and exposure:** both gates are correctly ordered.

The remaining blockers are where the stated rules meet the existing code or process structure.

## Blocking changes

**B1. Foreground re-activation silently restores the quarantined credential.**
- **Problem:** `CompanionStore.activate()` rebuilds `api` from storage on every foreground transition. After a failed replacement or failed Disconnect, the old item is still stored. The next background/foreground cycle would reload it and make it writable again. That is exactly what the review ruling forbids. The plan states the rule, but it doesn't say where the quarantine state lives, and none of the listed tests cover this path.
- **Change:** Keep an explicit in-store connection state, e.g. `.quarantined(priorHost)` or `.loadFailed(kind)`. `activate()` must honour that state rather than recompute it; only explicit Retry or Pair clears it. The state is in-memory only, because the store that just failed can't durably record its own failure. So also define relaunch: loading the preserved item is allowed, but the connected UI must always show the active host's DNS label before any control enables.
- **Minimal tests:**
  - Failed save → `deactivate()` → `activate()` leaves `api` nil and the state quarantined.
  - The same sequence after a failed delete.
  - Explicit Retry on the identified prior host needs a fresh GET before `canAnswer` returns true.

**B2. The unsigned Simulator Keychain conflicts with "load error never falls back".**
- **Problem:** `project.yml` sets `CODE_SIGNING_ALLOWED: NO`. An unsigned Simulator app has no application-identifier or default access group, so real `SecItemCopyMatching` is expected to return `errSecMissingEntitlement` (-34018) rather than not-found. Under the plan's rule, that typed error never falls back to the debug file. The Debug Simulator path would therefore always show "unavailable". The test host app and UI tests run the real `activate()` too, so injected storage in unit tests doesn't cover them.
- **Change:** Choose the store at compile time. In `DEBUG && targetEnvironment(simulator)`, either:
  - use a non-Keychain or in-memory `HostCredentialStore`, keeping the file path, or
  - enable ad-hoc Simulator signing (`CODE_SIGN_IDENTITY=-`) so Keychain works.

  Release and device builds must use only the real Keychain store. The precedence rule then only needs to hold where both sources exist.
- **Minimal test:** Launch the Debug Simulator build as currently configured, with no paired item and a debug file present. It must load the file. Also assert the device/Release binary has no file-store symbol or path.

**B3. The 20-minute exposure bound has a single point of failure: the supervisor.**
- **Problem:** The deadline and parent-death checks both live in the supervisor. If the supervisor alone is SIGKILLed, the foreground CLI keeps running with nothing to stop it. The CLI is not in a new session, but nothing signals it. The route then outlives the authorized lifetime.
- **Missing evidence:** The findings doc shows `DeleteForegroundSession` but not its caller. The claim that killing the CLI (including SIGKILL escalation) removes the entry depends on tailscaled calling it when the WatchIPNBus session ends (`WatchNotificationsAs` teardown).
- **Change:**
  1. Add that version-matched call site, with SHA and lines, to `2026-10-02-serve-ownership-findings.md`, or fail closed.
  2. Make the launcher watch the supervisor. On supervisor exit, it terminates the recorded CLI pid if that pid is still its expected descendant, then runs the ownership readback.
  3. The launcher also enforces the same absolute deadline. Document that killing both the launcher and supervisor at once is a residual case left to operator cleanup. Don't claim it is bounded.
- **Minimal tests:** Using the fake child:
  - SIGKILL the supervisor only → the child is terminated within one poll interval.
  - The child ignores SIGTERM → SIGKILL escalation happens, then readback runs. A fake LocalAPI state confirms the owned entry is gone.

## Optional suggestions

- **Bind the proxy Host once.** `make_server(..., allowed_proxy_host)` needs the actual port, but `PrivateRoute.start` returns it afterwards. Don't fall back from 8443 to 10000 after preflight; a start failure fails closed. Bind the proxy Host exactly once after the post-start readback and before the pairing origin is shown, so neither port is accepted "just in case".
- **Probe body framing, not just Host.** When confirming Serve's Host behavior, also check Content-Length versus chunked forwarding (the phone may use HTTP/2). The backend rejects chunked bodies, so this fails closed, but a 400 on the first phone POST would otherwise be misread as an auth or Host problem.
- **Unit tests don't prove delegate wiring.** The per-task delegate passed to `bytes(for:delegate:)` should receive the ServerTrust challenge, but calling the method directly doesn't prove that. The Task 3 phone GET is the real proof; if wiring is wrong it fails closed rather than leaking.
- **Treat "not found" on Disconnect as success.** An `errSecItemNotFound` result from Disconnect should count as success, so a second tap isn't reported as a storage failure.

## Hardest boundaries probed (these hold)

- **Late old POST after re-pairing to the same host process.** Same generation, cleared submissions, then a new submission on the same `control_id`. The plan's operation-identity check covers this; today's `send` keys only on `controlID`, so the test is essential.
- **A concurrent external Serve write between baseline and start.** ETag precondition failure plus new-foreground-port validation reject it; the CLI exits and nothing is touched.