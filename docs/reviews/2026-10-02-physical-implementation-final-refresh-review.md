# Physical foreground implementation: final bounded refresh

2026-10-02. **Verdict: PASS for the reviewed affected source. No remaining blocker in B1/S1/S2/S3 or regression in the traced dependent paths.** Source review does not establish physical runtime readiness or grant permission for exposure, signing, installation, or account changes.

## Provenance and scope

Adapter: Codex collaboration agent. Actual selected model: `gpt-6-astra` (dispatch identity). This is the affected-scope continuation of the independent implementation review; it is not a repeated full panel or a substitute for the concurrent Claude refresh.

Target: `/Users/edequalsawesome/Development/awesomux-ios`, non-Git workspace. Current 40-file manifest: `docs/reviews/2026-10-02-physical-implementation-final-scope.json`, SHA256 `30f3c0156f917c315250b2cb9db60bcb78940377abd3eb2f06efb878036fd21f`. Review snapshot: `/private/tmp/physical-final-review-f0rqprs8`. Every original and snapshot file matched the manifest at creation and completion. No source was changed; only this new report was written in the original workspace.

Prior reviewed manifest SHA256: `f334099b5ef84c99d70d4aaeab588c3b45eda6c6adbe224727da4420e866c0fd`. Prior reports remain unchanged. Independently reverse-applied all eight source/test diffs in `2026-10-02-physical-adversarial-fix-impact.json` to current text and verified that each reconstructed file exactly matches its prior reviewed SHA256. The manifest comparison also identifies three changed documentation files: bridge README, iOS README, and the physical execution ledger; their updated claims/rulings were read separately.

Reviewed actual Claude report: `2026-10-02-physical-claude-implementation-final.md`, reporting adapter Claude Code and model `claude-opus-5-5`. Its original B1/S1/S2/S3/S4 findings were treated as hypotheses and traced against the source and supplied current-installation evidence.

## Findings and rulings

**B1 — route process ownership: addressed.** `TailscaleCLI` now defaults directly to the installed native binary, resolves an explicitly supplied symlink once, opens the resolved path with `O_NOFOLLOW`/nonblocking flags, requires a regular file and recognized Mach-O magic, and validates again before every read or command construction. Both read and route-launch paths use that resolved path. A shell wrapper is rejected before execution. This removes the wrapper-parent/grandchild assumption from the prepared route command while preserving version/commit pinning and the existing exact foreground readback. The parent's local inspection found the original 73-byte wrapper uses `exec`; the report therefore does **not** claim an observed current orphaning defect. The guard addresses installation drift and the process-ownership precondition. It is not code-signature verification or a defense against a same-user malicious binary replacement; those are outside this owned-tool trust model.

**S1 — signal Event shadowed during teardown: resolved.** The helper is `stop_process`; both desktop/server teardown callsites use it. Signal closures continue referring to the original Event throughout `finally`. The regression executes the actual Event/handler/helper AST bindings and invokes each captured handler after defining the teardown helper, proving the specific closure-binding failure is gone without launching a managed session.

**S2 — failed deletion after failed credential load: resolved.** `disconnectHost` captures whether it entered from `.loadFailed` and restores that state on deletion failure, keeping `canPair` false. Both load-error paths clear the stale host label. API/snapshot/submission invalidation occurs before deletion; failed deletion does not enable implicit activation, restore the old API, or mutate the unread item through pairing. Retry remains explicit; a successful delete still becomes unconfigured. The new regression starts with a previously loaded host, then fails load and deletion, and asserts `.loadFailed`, no pairing, no stale label, and preserved stored item. Inbox and PairHostView callsites continue exposing retry/disconnect while withholding Pair in this state.

**S3 — early supervisor payload failure: resolved.** `os.write` failures become `WatchdogFailure` and pass through the existing exception cleanup. The new disposable-child regression forces BrokenPipeError, checks the typed result, and verifies recorded children have exited. No exception is converted into a successful readiness handshake.

**S4 — unknown-session cleanup may report an early conflict: consciously retained, nonblocking for this bounded trial.** Cleanup still stops only the recorded child and reports absence/preservation from observed state. When startup did not establish a session ID, it may report conflict before asynchronous foreground deletion completes. That is a conservative failure requiring follow-up readback, not false success; it does not reset/overwrite unrelated config. The original residual and retained private-directory behavior remain documented. Deferred optional items do not silently become completed work.

The updated README/ledger qualify the operational deadline as 20 minutes of awake-host monotonic time. This is consistent with the existing implementation; simultaneous watcher death and unacknowledged startup remain explicit residuals, not a hard wall-clock security guarantee.

## Validation and retained coverage

Executed in the private snapshot:

`python3 -m unittest -v test_private_route test_route_watchdog test_launch_probe`

**15 tests passed in 6.372 seconds.** Coverage includes wrapper rejection/resolved native path, route fake-command baseline/ownership/cleanup, deadline and ignored TERM, parent/supervisor death, readiness/forced BrokenPipe cleanup, signal closure binding, and assistant-result classification. This command used supported escalation solely because its test-created directory is cleaned with Trash, whose sandbox limitation had already been established. No real Tailscale command, network exposure, Codex inference, signing, or device operation ran.

The parent reports 34/34 bridge tests and 26/26 iOS tests, including RED-to-GREEN signal/readiness/credential regressions. These full-suite numbers are parent evidence; this reviewer independently executed only the 15 targeted bridge checks and inspected the new Swift test/state transitions.

The displayed AnswerContext intent fences, card identity and actual thread-host label are byte-for-byte unchanged from the first refresh outside the narrow CompanionStore error-state edits. The exact intervening diff leaves submission, retry, response-generation/revision and uncertainty handling unchanged. TLS/URL/bearer code, real Keychain storage operations, HTTP adapter, state/transport wire handling, app entrypoint, project settings and their unchanged dependencies retain their prior reviewed coverage. Changed route/launcher/watchdog contracts were refreshed here rather than inheriting approval merely from old file names. No unavailable review lane is inferred as passed.

## Runtime boundaries

Physical TLS and actual Serve forwarding/framing, Keychain locked/denied behavior, signing/provisioning/install, phone foreground/network transitions, and live before/after route preservation remain unexercised by this reviewer. The parent's concrete exposure action and pending Claude affected-scope review remain separate gates. This report authorizes no new operation and claims no Git/PR/publication coverage.

## Current production hashes

- `bridge/launch_probe.py`: `9ed0382cf1b0854054e5b94281eecd85a0621572afc6719b9733d5f495683d7d`
- `bridge/private_route.py`: `a4d0f3c295da8c3aaf1bd4f3e61f51b8cb693f03b3c1970791ff03b5e8a1211b`
- `bridge/route_watchdog.py`: `77ba1ec0f009e034b23dd57ab6e6c1a7475ab20739cbbc4bd53122135c0c6e83`
- `ios/AwesoMuxCompanion/CompanionStore.swift`: `254b55d4049e7712b436a772cf350055df930c6b27fee3463f8c0766878a4d1f`

Cleanup: the reviewer-owned private snapshot was moved to Trash after retaining this report, and its original path was verified absent. No source or prior reports were removed.
