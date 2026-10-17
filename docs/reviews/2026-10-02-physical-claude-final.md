# Physical foreground adversarial plan review

Adapter Claude Code; actual model claude-opus-5-5. Tools/settings/hooks/MCP disabled. Scope manifest physical-plan-final-scope.json.

# Plan gate review: physical foreground connection (final refresh)

## Verdict

**Approve to proceed with implementation. I found no remaining blocker.**

All three refreshed findings now close their prior blockers. No new concrete blocker appeared in the five review areas. The remaining items below are optional hardening, not gate conditions.

## Prior blockers, checked against the exact changes

### 1. Quarantine across activate, and host identity after relaunch

**Status: closed.**

- **Old defect:** today `CompanionStore.activate()` rebuilds `api` from storage on every call. After a failed save or delete, that let deactivate → activate silently restore a writable prior host.
- **Fix:** the plan adds an explicit in-memory state (`unconfigured`, `configured`, `quarantined(priorHost)`, `loadFailed`). `activate` must honor it, and only Retry or Pair clears it. That removes the restore path.
- **Required tests are present:**
  - failed save/delete, then reactivation, stays API-nil
  - explicit prior-host Retry requires a fresh GET
  - relaunch identifies the host
- **Late results are fenced.** The existing generation-only fence in `send()` would accept a late POST after re-pairing to the same bridge process, because the generation is unchanged. The plan adds a connection revision captured by every GET/POST, and re-pair also clears the snapshot (so `snapshot?.generation` becomes nil), which defeats that guard. Fenced twice.
- **Relaunch fallback is acceptable.** Because storage failed, quarantine cannot be persisted, so relaunch may load the preserved item. That is bounded by:
  - the visible DNS label shown before any control enables
  - the fresh-GET requirement
  - the host-side 20-minute token lifetime
  - the bridge's authoritative `prior_attempt_uncertain`, which covers the in-memory `earlierOutcomeUnknown` notice lost on relaunch

### 2. Storage selection (DEBUG Simulator vs device/Release)

**Status: closed.**

- **Correct gate:** the selector is `DEBUG && targetEnvironment(simulator)`, not `DEBUG` alone. This matters because the Task 3 development-signed device build is almost certainly a Debug configuration. The plan's wording ("DEBUG Simulator" for in-memory/file; "device and every Release build" for Keychain only) is correct.
- **Precedence is sound:**
  - An in-memory pair resets on relaunch, so the dev file is used only when nothing is paired.
  - A locked, corrupt or unreadable Keychain item is typed (`loadFailed`), never treated as missing, so there is no fallback or overwrite.
- **Integration is covered:** a real unsigned Simulator file-loading check is required, plus an artifact inspection for absence of the device file path.

### 3. Dual watcher and teardown call site

**Status: closed, with the residual honestly stated.**

- **Teardown chain is complete.** The `local.go` excerpt supplies the missing link: the watcher's context ends, then the deferred `DeleteForegroundSession(sessionID)` runs under the mutex.
  - So the death of the owned foreground CLI by any signal, including SIGKILL, scopes cleanup to that session alone.
  - The only real hazard is therefore the CLI outliving its owners. The design addresses that:
    - the supervisor kills it on parent-pipe EOF
    - the launcher kills it on supervisor exit
    - both enforce the deadline
- **Ordering is safe:**
  - The CLI is not put in a new session, so terminal SIGINT/SIGHUP reaches it and naturally ends the route.
  - Signal handlers are installed before any children start.
- **Tests match the single-failure claims:**
  - launcher SIGKILL after readiness
  - supervisor SIGKILL alone
  - CLI ignoring SIGTERM, with SIGKILL escalation
  - failed readiness handshake
  - two-second deadline
- **Residuals are explicitly excluded** from the hard-deadline claim and must appear in the exposure authorization: simultaneous death of both watchers, and failure during unacknowledged startup.

## Other areas probed with no blocker found

- **Endpoint/token binding:**
  - Hostname rules are strict: canonical lowercase `*.ts.net`, at least two labels, ports 8443/10000 only.
  - Redirects are nil'd, and the existing `http.url == request.url` check stays.
  - Authentication challenges: server trust gets default handling; every other method is cancelled; `useCredential` is never used.
  - A persisted HTTP origin is rejected on device.
- **Serve ownership:**
  - The CLI's own `If-Match` covers the gap between our status read and its write.
  - Backend validation rejects a new foreground session on an occupied port.
  - Treating a port with `AllowFunnel` set as occupied, plus post-start Funnel readback, closes the "inherit a pre-existing Funnel grant" path.
  - No off/reset is ever issued.
- **Backend Host allowlist:** an exact `<dns>:<port>` match, with forwarded identity headers ignored. Actual Host and body framing are verified diagnostically before claiming connectivity, never widened.
- **Signing gates:**
  - Read-only inspection comes first.
  - Provisioning needs authorization naming the exact bundle ID and team.
  - APNs eligibility comes from account metadata, not certificate inference.
  - `aps-environment` must be absent from this slice.

## Optional suggestions (not gating)

1. **Backend port reuse in the residual window.** If both watchers die, or the launcher dies before the supervisor acknowledges, the orphaned route points at a `127.0.0.1` port the dead launcher released. Any later local listener on that port would then be reachable over the tailnet.
   - Name this explicitly in the exposure authorization's residual text.
   - Optionally add a preflight check that flags any foreground Serve entry not created in this run.
2. **Startup ordering.** Start the supervisor (with the parent pipe) before the CLI, then hand over the CLI identity. This shrinks the unacknowledged window to the handoff itself.
   - Test: SIGKILL the launcher between the CLI spawn and the handoff in the fake harness, and assert the residual is reported, not silently passed.
3. **Relaunch after a failed Disconnect.** The user asked to disconnect, deletion failed, and relaunch reconnects (label shown).
   - A non-secret UserDefaults marker ("disconnect incomplete for `<label>`") would let relaunch require explicit Retry for that case. This does not reuse the failed storage, so it doesn't contradict the ruling.
   - Test: inject a delete failure, relaunch, and assert API-nil until Retry.
4. **Keychain survives app deletion on iOS.** A reinstall will load the old item.
   - That is harmless given token expiry and the label gate. Note it in Task 3 cleanup so "removed the app" is not reported as credential removal.
5. **Re-check the Tailscale version/commit at route start,** not only in preflight. An auto-update between the two would invalidate the source evidence. Keep the existing fail-closed rule.
6. **Optional slow ownership readback.** The supervisor could periodically re-read the owned entry's `AllowFunnel`/handler (e.g., every 30 s) and end the route on drift. This catches concurrent edits made after startup readback.

## Hardest boundary probed

The launcher was SIGKILLed after the foreground CLI's `SetServeConfig` succeeded but before supervisor readiness was acknowledged. In that state:

- the route is live
- its backend loopback port is released
- no watcher holds the CLI identity

The plan does not claim a deadline there; it classifies this as a stated operator-cleanup residual. That is the honest position, but suggestions 1–2 are the cheapest ways to narrow it.

Second hardest: a late POST from before a re-pair to the same bridge process (same generation). It is fenced by both the connection revision and the cleared snapshot.