# Native implementation independent review

Date: 2026-10-02. Reviewer: separate Codex subagent, explicit model `gpt-6-astra`. Adapter: collaboration agent. Read-only source review; the only workspace write is this report. No live inference, notifications, shared runtime interaction, or publication.

Initial outcome: **changes required**. Refreshed outcome: **no outstanding findings in this review scope**. Reviewed the current native implementation, updated transport-test injection seam, exported fixtures, interactive launcher/cleanup, and legacy live-probe notification mitigation. Historical bridge reports were context only and do not cover the changed launcher.

## Initial findings (all fixed and independently refreshed below)

### P1 — Disconnected and error snapshots falsely resolve an uncertain answer

Location: `ios/AwesoMuxCompanion/CompanionStore.swift:54-58`, with `bridge/state.py:disconnect` and `snapshot`.

The bridge deliberately clears its pending controls on disconnect and changes submitted operations to `uncertain`. Error/capacity snapshots also suppress the pending list. The client currently interprets any missing control as `.resolved`, even when the same snapshot says disconnected/error and the operation explicitly says uncertain. Its subsequent generation transition sees only resolved submissions, so it also loses `earlierOutcomeUnknown`. A late POST cannot repair the false resolution because `send` exits for a locally resolved operation.

Verified against the actual Swift source using a network-free compiled fake-API reproduction: submit a control; return the same generation with `connected=false`, `pending=[]`, and the operation `uncertain`; then return a new generation. Actual output:

```text
after disconnected GET: resolved
earlierOutcomeUnknown: false
```

Required change: only use control disappearance as resolution when the snapshot can authoritatively expose pending controls (connected, no bridge error); honor explicit operation outcomes, preserving uncertainty across reconnect. Required regression: the above sequence retains unknown outcome through generation change; error-hidden pending must not resolve; a healthy same-generation disappearance must still win over a late POST.

### P1 — Legacy probe can still start inference without verifying quiet server configuration

Location: `probes/run_live_probe.py:53-63`.

This entry point connects to an externally supplied server, starts a thread, and immediately invokes `turn/start`. The newly added `notify=[]`/`tui.notifications=false` overrides apply only to the TUI launched afterward. Scrubbing its child environment cannot change notification configuration already loaded by the separately supplied server. Unlike `bridge/launch_probe.py`, there is no effective `config/read` guard before inference. Running this still-executable legacy probe can therefore reproduce the notification incident despite the mitigation edits.

Required change: retire/fail closed this superseded live entry point in favor of the authenticated, quiet-gated launcher, or implement the same pre-inference readback and current authenticated transport contract. The old `ws_proxy.mjs` connects without authentication, so simply adding a config read would not make it a valid current managed-runtime path. Smallest solution is explicit retirement. Required regression: invoking the retired entry point does not spawn a process or issue any protocol request; or fake protocol coverage proves missing/nonquiet readback prevents `turn/start`.

### P2 — An older failed GET can invalidate a newer successful refresh

Location: `ios/AwesoMuxCompanion/CompanionStore.swift:70-77`; caller `InboxView.swift` `.refreshable`, concurrent with `poll()`.

Successful fetches reject out-of-order responses using `requestSequence > appliedSequence`, but the catch path checks only the lifecycle epoch. If automatic poll A is pending, pull-to-refresh B succeeds, and A subsequently fails/cancels, A clears B's fresh state, cancels B's lease, and displays a disconnected error over B's valid snapshot. This is reachable because pull-to-refresh and polling share the store and can overlap.

Required change: apply response ordering to failure handling as well. Required regression: hold A, complete newer B successfully, fail A, then assert the newer freshness/message/lease remain authoritative. Also retain the existing case where the newest failure immediately disables controls.

## Validation and scope limits

- Ran `python3 -m unittest discover -s bridge -v`: 16 passed.
- Ran `python3 -m unittest discover -s probes -v`: 5 passed.
- Ran a local standalone Swift reproduction linked to actual `Models.swift`, `BridgeClient.swift`, and `CompanionStore.swift`, with only a fake API and no network; reproduced the P1 resolution defect. Initial compilation hit `sandbox_apply: Operation not permitted`; supported elevated retry compiled and ran successfully.
- Read all 12 current XCTest methods. Parent reports all 12 passed after adding unknown-length oversized receive, invalid JSON/401, and restricted endpoint tests; this reviewer did not rerun the Simulator suite. Existing checks omit the three regressions above.
- Read native live result: quiet server booleans true before inference, an answer observed, one resolved operation, owned amx absent, server exited, endpoint closed, private root absent, no cleanup errors. Parent reports the actual Simulator displayed the completed ALPHA response. This reviewer did not independently repeat live UI/inference or claim physical-device/push readiness.
- Native lifecycle cancellation, immediate lease-based submit guard, immutable same-operation retry bytes, generation-based view identity/draft reset, explicit replay confirmation, duplicate-submit reservation, and late-POST suppression were reviewed. Receive limits count actual bytes and cancel underlying tasks; request path/token restrictions and redirect/auth challenge rejection are present. New URLSession configuration injection is internal and production defaults to ephemeral while resetting cache/cookie/credential/proxy policies.
- Updated interactive launcher correctly gates inference on selected effective server settings and uses separate native evidence output. Cleanup scopes amx by random session name/private directory and server by its owned process group; failures retain generic cleanup evidence/private-root location rather than claiming deletion. No additional concrete launcher defect found in the reviewed successful/handled-failure paths. SIGKILL cleanup is explicitly not guaranteed.

## Fix refresh and scope impact

The parent implemented fixes while this report was being prepared. Initial findings above describe the exact source read in tool output and reproduced before the fixes; no pre-fix full-file hashes were captured. The hashes below were captured after those edits and bind the **refreshed final review**, not the initial findings. No old report is relabeled as review of new bytes.

Intervening contribution changes reviewed:

- `CompanionStore.swift`: disappearance now resolves only for connected, error-free, unexpired successful snapshots; explicit operation `resolved` remains authoritative. Failure handling now applies active/epoch/sequence checks and advances the applied sequence. Both state/concurrency findings are fixed. Re-ran the standalone Swift reproduction against the final source: `after disconnected GET: submitted`, then `earlierOutcomeUnknown: true`. This preserves the local handoff fact without inventing resolution; the reconnect correctly preserves the unknown-outcome notice.
- `CompanionStoreTests.swift`: two focused regressions added. The disconnect check includes both actual disconnect and error-hidden pending, followed by generation change; overlapping fetch check completes B before failing A. Read their fake-API scheduling support. Parent reports RED 12 pass / 2 fail before changes, GREEN 14 after changes; Simulator execution is parent evidence, not an independently rerun claim.
- `probes/run_live_probe.py`: replaced old execution path with unconditional `SystemExit` directing callers to the authenticated launcher. No process, socket, inference, or notification can be reached through this file. Read the new `probes/test_retired_runner.py`; independently reran all 6 probe tests successfully.

Review impact: refreshed state correctness, Swift concurrency/lifecycle, test coverage, and legacy launch/security/notification lanes against the edited files and their unchanged dependencies. The native views, models, fixtures, transport security settings/seam, project, and active authenticated launcher are unchanged since their initial read and retain that review. Reread the exact small state and legacy-runner changes; no new abstraction, capability, trust boundary, or physical-device claim was introduced. No outstanding concrete findings remain. This is one independent implementation review, not a claim to substitute for any separately required specialist-panel coverage or publication gate.

## Exact final reviewed source hashes

SHA-256, relative to workspace. This directory has no Git commit; hashes bind this report to source, not later changes.

| Path | SHA-256 |
| --- | --- |
| `bridge/README.md` | `d92241b76dc1f3ee36d5cea8b526eb3ed9c6c5f2e82a2c28a90d9c5edeebb91f` |
| `bridge/launch_probe.py` | `0886b05fe37d9fa78483ff57831787d029c4f9b541dcc9f8fa573851d3652088` |
| `bridge/state.py` | `5bb2e6f5600693cee24cda9b51e6b05ef748a48745c32c97e5f3906c01f17afb` |
| `docs/native-client-progress.md` | `fe054bfbb7a93cec458fe57c276ae56dc3bde207bb247f3a32755a559294f305` |
| `docs/reviews/2026-10-02-native-live-result.json` | `292f7590567ee9ffc363cd5cb32e0b18f2c30d0f034dc261ff7c7acc2014a586` |
| `docs/superpowers/plans/2026-10-02-native-foreground-client.md` | `e905b70e5ce05cac4dcde69aeeefadb78f77dca817d022cd46cdf0c9ba7b74c9` |
| `ios/AwesoMuxCompanion/App.swift` | `474206e2b563227f559c7b2b359adaa2ad7e12c32e7d9bca23513e2051dbee7a` |
| `ios/AwesoMuxCompanion/BridgeClient.swift` | `3cd88d3710275b074e28973b1cc7a7f6e5232373b5e20080b4b54ad6a9fcb02f` |
| `ios/AwesoMuxCompanion/CompanionStore.swift` | `5fa09ef388d44b1c60d4af41a61d39a8e15dace8756d5d886d1e1d553eec45af` |
| `ios/AwesoMuxCompanion/InboxView.swift` | `905e6cb1487b8111c457e84bb3dc42e280c9b51a1e83146d6d15951e8dd366c4` |
| `ios/AwesoMuxCompanion/Models.swift` | `116da0be963e16dddddbc868c00633db1b3534bae1bc4efb1d777e52f60dac30` |
| `ios/AwesoMuxCompanion/QuestionCard.swift` | `80dbd7decef227597d3a1538c02a8151916c09ca06daba372fe42673c49f36ea` |
| `ios/AwesoMuxCompanion/ThreadView.swift` | `9e84b40522b82cef9cb196732f762b961bbf8097ce769c5bda6a62d2f20c5108` |
| `ios/AwesoMuxCompanionTests/BridgeClientTests.swift` | `03e9ecd90257814d0917e9cf7fccef9cb837503772df52cca5fd4bbb81af7a09` |
| `ios/AwesoMuxCompanionTests/CompanionStoreTests.swift` | `01779fdc29617db6a22148fa2f4d06e59594a14b50a83190515018527f1e1d5a` |
| `ios/Fixtures/disconnected.json` | `5a4aee21e08a77d0de3d70d6d1908a329b32cef0d5c8fdb478ef3c453fe934ce` |
| `ios/Fixtures/pending.json` | `d2a8cf9a889dd9ee08f7a6640771751dcd5d5af3d13b1569de13617460057974` |
| `ios/Fixtures/submitted.json` | `b24d6f28a831b5c6e86395a687da7b905d37cd4e525ccd1ee8309bf9612189c4` |
| `ios/project.yml` | `3edb120cdf1a89865ba812289c86e2c2fc5257a8c19334e2b469879e2b6cbab3` |
| `probes/run_live_probe.py` | `5be353a9e10c0a3680456685de774dedbab26a7030ac7e80a5d491390aa36216` |
| `probes/test_retired_runner.py` | `352273aea838d01c5e57091b6daeeafc128c33dc28ca197a5a33c15a9ea7219a` |
