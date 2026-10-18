# Verification ledger

## Public renderer: 2026-10-18

The diagnostic app now uses the source-built public `CAMetalLayer` renderer from
merged PR #34. Tested application source is `0f61721569c1ef5598db99c2584ee1c98cab59a4`;
subsequent documentation/evidence changes do not change the bundled inputs.
Current results are in [`evidence/public-metal/`](evidence/public-metal/).

- A fresh `native/build.sh` run cloned the pinned sources, downloaded the local
  compiler and built both arm64 slices with isolated caches. Schema-2 receipts
  bind all seven XCFramework files, including headers and metadata, and 5,918
  native source files. Selected wrapper/Ghostty/DisplayLink revisions and Sarah's
  update ownership remain as recorded in the [renderer spike](../../docs/ios-terminal-renderer-spike.md).
- Release Simulator build and signed device Release archive passed. Strict
  signature verification passed for both app bundles. All 22 bundled notices
  match their repository sources. The public renderer is present and the private
  `CAIOSurfaceLayer` class is absent from both linked binaries.
- Both apps contain identical source manifests and native receipts. Full hashes,
  app binary hashes, notice hashes and local build-log hashes are recorded in
  [`artifact-identity.json`](evidence/public-metal/artifact-identity.json).
  The complete integrated receipt is [`native-build.json`](evidence/public-metal/native-build.json).
- Fresh replay passed on Renderer Spike Simulator and Shiny Blue iPhone using
  these Release apps: both surfaces report actual 20×6, expected viewport text,
  exact DSR `6;6` before continuation and `6;5` afterward. This exercises bytes
  supplied by the harness and renderer output callbacks; no app-local shell or
  PTY is started. JSON assertions establish parser/viewport/callback behavior.
- Simulator pinned HTTPS live output and explicit disconnect/reconnect passed:
  sequence 1064 before disconnect, fresh snapshot 1066, live sequence 1068 after
  reconnect. iPhone explicit disconnect/reconnect also passed: sequence 1278
  before disconnect, fresh snapshot 1288, live sequence 1291 after reconnect.
  Saved screenshots show terminal content on Simulator and the real device.
- Canonical shipping project generation and all four shipping regression tests
  passed, with zero failures/skips. The generated shipping project resolves no
  renderer package and its linked app contains neither renderer. The separate
  diagnostics project is arm64-only; Intel Simulators are unsupported.
- All 23 integration/receipt/dependency-lock tests passed. Endpoint authorization,
  ordering, generation and reconnect checks passed separately; endpoint JSON is
  explicitly server-only evidence. Queue eviction/concurrent-cut tests passed
  normally and with Python optimization.
- Full Codex specialist and independent Claude reviews identified the complete
  framework receipt and dependency pin gaps; both were fixed. Fresh focused
  reviews through the tested source found no verified source blockers.

The runtime JSON's manual flags remain unverified; screenshots are separate
visual evidence. Physical network interruption, background recovery, long suspension, full
scrollback retention and production transport are not inferred from automated
replay or explicit reconnect. No hosted CI, TestFlight upload or deployment is
claimed. The earlier basic keyboard/selection checks belong to #34's separately
identified public-renderer build and were not repeated by this read-only harness.

IME composition/cancellation and VoiceOver are required before release in
[#36](https://github.com/Interactive-Buffoonery/awesomux-companion/issues/36).
Sarah moved them outside #30's spike acceptance; this is no test pass or waiver.
Production Watch implementation and acceptance remain in #10.

## Historical private-renderer evidence

Base: `52d4832` on `t3/snapshot-reconnect-gaps`, refreshed in `df50d91`.
PR: https://github.com/Interactive-Buffoonery/awesomux-companion/pull/35.
All app results in the following sections predate this public-renderer diagnostic
migration and describe the private renderer. They are retained as historical
results, separate from the current `public-metal/` evidence above.

## Automated endpoint evidence

Executed against the existing zmx executable identified in `result.json`:

- `verify_endpoint.py`: token rejection, snapshot then contiguous events,
  stale generation and future sequence rejection, malformed query rejection,
  fresh reconnect snapshot: passed.
- `test_fixture_server.py`: retained-event eviction boundaries and concurrent
  snapshot/event cuts: passed, including under `python3 -O`. Snapshot bytes
  must contain the marker at their declared sequence and exclude the next one.
- Slow TLS client test: a client stalled before handshake did not block valid
  HTTPS requests; the endpoint verification completed in 2.31 seconds.
- Python syntax checks and `git diff --check`: passed at this phase.

The server has a default one-hour lifetime, five-second connection timeouts,
a 256-event queue and 256 KiB response cap. Synthetic capture logs are retained
in the private run directory. SIGTERM and Ctrl-C enter session cleanup.

## Independent review

- Fresh Claude server review, task `snapshot17-server-review-r1`: eight grouped
  findings. Verified fixes: perform TLS handshakes in timed worker threads,
  drain both zmx output consumers, invalidate failed producer under its lock,
  compare authorization bytes, preserve startup errors during cleanup, handle
  SIGTERM, use checks that remain active with Python optimization, assert exact
  snapshot/sequence cut and eviction boundaries. Retained private run files are
  intentional and documented; the default runtime bounds capture-log growth.
- Full Codex specialist review (eight specialists) and independent Claude iOS review completed. Verified fixes cover per-attempt evidence/manual provenance, replay prerequisite, bounded recovery history, overflow handling, accessible viewport/status, and per-build manifest. Fresh focused review found only stale lastSequence on partial-batch failure; corrected by updating after each applied feed. Final transport correction needs fresh focused verification.

## Historical pre-refresh app evidence

Diagnostic Simulator, signed device Debug, and shipping Simulator builds passed
before runtime sizing correction. First Simulator replay failed closed because
both surfaces reported 20×4 instead of source 20×6. These builds are not replay
acceptance. Runtime sizing fix and refreshed evidence are pending.

Physical installation, renderer observations, network interruption,
background/resume, VoiceOver and production subscription behavior remain
unverified until explicitly recorded below.

## Historical pre-refresh runtime progress

Simulator and Shiny Blue iPhone both passed actual20×6 replay with expected
viewport and exact DSR6;6 before continuation, DSR6;5 afterward. Evidence files
are retained under `evidence/`; these precede the final HTTPS correction and
are explicitly named by phase. Manual rendering/reconnect remain unverified.
Initial Simulator HTTPS attempt failed closed with URLSession -1202 (default
TLS trust). Certificate challenge handling correction and network tests pending.

## Historical pre-refresh reviewed artifact and runtime evidence

Final diagnostic Simulator and signed iOS Debug builds passed after the HTTPS
callback correction; device strict codesign verification passed. Both bundled
source manifests match the current source, configurations and dependency lock.
Shipping Simulator build passed separately; the shipping target does not link
the renderer. No hosted CI or release archive was run.

Fresh focused review round 2 verified the earlier fixes and found only stale
failure `lastSequence`; this was corrected. Fresh independent Claude transport
review round 3 found no concrete regressions and verified that the sequence fix,
exact host/leaf pin, redirect refusal, bounds and cancellation remain intact.
Use a LAN IP literal or `.local` endpoint: arbitrary dotted fixture hostnames
are not covered by the diagnostic app's local-network ATS exception.

Final runtime results:

- `evidence/simulator-replay.json`: both actual20×6; viewport and exact cursor
  match expected text before and after continuation, passed.
- `evidence/phone-replay.json`: final signed build installed on Shiny Blue iPhone;
  the same real-device parser/viewport/cursor assertions passed at actual20×6.
- `evidence/simulator-disconnected.json` → `simulator-reconnected.json`:
  disconnected at sequence305; a fresh model applied snapshot320 and continued
  through331. This proves explicit disconnect/reconnect against the synthetic
  endpoint, not a physical Wi-Fi interruption.
- `evidence/simulator-wrong-pin.json`: incorrect certificate pin failed closed;
  current automatic result section was empty, manual marks unverified. Correct
  pin subsequently restored watching. No root CA or broad ATS exception added.
- Timed fixture-server shutdown cleaned up its private zmx session.
- Artifact/source scan found no per-launch fixture token in recorded evidence.

The initial URLSession call omitted its per-task delegate. Passing the delegate
explicitly to `bytes(for:delegate:)` and routing both challenge callbacks to the
same exact-pin handler corrected the observed -1202 failure without changing ATS
or production trust.

Physical network-test launch was initially rejected while the phone locked.
After unlock, the phone successfully connected over pinned HTTPS and received
live synthetic output (`evidence/phone-network.json`). The previously observed
Local Network prompt was no longer blocking; no permission was granted by the
agent. Explicit disconnect/reconnect on Shiny Blue iPhone applied a fresh model:
sequence 686 before disconnect, snapshot 729 on reconnect,
then live sequence 732 at capture. Both source and renderer reported20×6.
See `evidence/phone-disconnected.json` and `phone-reconnected.json`.

Visual rendering attestation,
VoiceOver, full scrollback comparison, and production Watch transport remain
unverified. Early evidence files explicitly named `before-tls-fix` and
`sizing-fixed` are historical, not final-artifact network acceptance.

Additional final Simulator checks: trusted HTTPS with an invalid token returned
401 (`evidence/simulator-unauthorized.json`); pausing only the synthetic endpoint
for13 seconds caused a visible timeout failure with manual results still
unverified (`simulator-endpoint-outage.json`). The endpoint was resumed in
`finally`, then explicit Connect was retried. These are local diagnostic
failure/recovery checks, not physical Wi-Fi or background-execution evidence.

## Historical pre-refresh user-operated airplane-mode trial

Sarah reported turning Wi-Fi off, enabling Airplane Mode, then restoring the
network and disabling Airplane Mode. Afterward, the captured app evidence still
reported the prior watching generation at sequence872; it contains no recorded
transport failure during the interruption. The agent then explicitly requested
Connect: a fresh model applied snapshot921 and live output continued through923
at actual20×6 (`evidence/phone-airplane-reconnected.json`). The fixture server
remained running throughout this trial.

This verifies fresh snapshot and live continuation after a user-reported physical
network interruption. It does not establish outage detection timing, automatic
reconnection, or preservation of every intervening line; no outage-time evidence
or complete scrollback comparison was captured. Manual UI attestations remain
unverified. The pre-reconnect capture is retained as
`evidence/phone-airplane-before-reconnect.json`.

## Historical pre-refresh user-operated background/resume trial

After Sarah reported leaving Diagnostics and returning, the agent captured
`evidence/phone-after-background.json` before issuing any reconnect. The phone
was watching in the same generation and snapshot921, with live sequence974
(previous capture923); its evidence timestamp was current and the renderer
remained20×6. No new snapshot, reconnect, or failure was recorded in this trial.

This confirms live continuation after the brief user-operated background/resume
trial without an explicit reconnect. App lifecycle timestamps were not captured;
it does not prove process suspension, termination/relaunch, long-background
recovery, or complete scrollback retention. Manual rendering and VoiceOver
remain unverified.

## Historical private-renderer main refresh: 2026-10-18

Rebased the diagnostic change onto current main `52d4832` as source commit
`df50d91`. The only conflict was scheme configuration; both main's shipping test
scheme and the separate diagnostic scheme are preserved. Main's stale-alert fix
and its tests are unchanged. Subsequent changes only refresh documentation,
evidence and the informational source-manifest copy.

- Diagnostic Simulator and signed device Debug builds passed. Device strict
  codesign verification passed. Both bundled manifests were checked against
  every current source entry; their SHA256 is
  `5c2fc01cf0b3670d532addf092a5e9bf27d1919afb06f2b851f3a0dc8419afc0`.
- Shipping build-for-testing and test-without-building passed: all four
  AttentionTracker stale-alert tests passed, zero skipped or failed. Summary:
  `evidence/main-refresh/shipping-test-summary.json`.
- Fresh replay on Renderer Spike Simulator and Shiny Blue iPhone passed actual
  20×6, expected viewport text, exact cursor6;6 before continuation and6;5 after.
- Fresh pinned HTTPS watching and explicit disconnect/reconnect passed on both.
  Phone: disconnected at1646, fresh snapshot1672, live1687 at capture.
  Simulator: disconnected at1660, fresh snapshot1671, live1677 at capture.
  New runtime JSON is in `evidence/main-refresh/`.
- Endpoint authorization/order/generation/future-sequence verification passed
  against the still-running synthetic server; queue eviction and concurrent-cut
  tests passed again in their own private zmx session.
- Fresh independent Claude review `snapshot17-main-refresh-review-r1` found no
  code blockers. It verified scheme integration, snapshot findings, transport,
  sequence validation and evidence safeguards. Its documentation/provenance
  findings were addressed: refreshed source hashes and artifact identity,
  historical evidence labels, current base/PR state and local lockfile caveat.

`evidence/artifact-identity.json` identifies the refreshed artifacts. The earlier
identity is retained as `artifact-identity-before-main-refresh.json`; all root
runtime evidence outside `main-refresh/` describes pre-refresh builds. The
phone airplane-mode and brief background observations above were not repeated
on the refreshed build and remain historical. No manual visual or VoiceOver
pass is inferred. Long suspension/termination, outage detection timing, complete
scrollback and production transport remain outside established evidence.
