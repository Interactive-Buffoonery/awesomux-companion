# Verification ledger

Base companion commit: `bafc253` on `t3/snapshot-reconnect-gaps`.
This ledger describes local uncommitted diagnostic changes. No production Watch
or Chat implementation, PR, deployment service, or TestFlight upload is included.

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

## App evidence

Diagnostic Simulator, signed device Debug, and shipping Simulator builds passed
before runtime sizing correction. First Simulator replay failed closed because
both surfaces reported 20×4 instead of source 20×6. These builds are not replay
acceptance. Runtime sizing fix and refreshed evidence are pending.

Physical installation, renderer observations, network interruption,
background/resume, VoiceOver and production subscription behavior remain
unverified until explicitly recorded below.

## Runtime progress

Simulator and Shiny Blue iPhone both passed actual20×6 replay with expected
viewport and exact DSR6;6 before continuation, DSR6;5 afterward. Evidence files
are retained under `evidence/`; these precede the final HTTPS correction and
are explicitly named by phase. Manual rendering/reconnect remain unverified.
Initial Simulator HTTPS attempt failed closed with URLSession -1202 (default
TLS trust). Certificate challenge handling correction and network tests pending.

## Final reviewed artifact and runtime evidence

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

## User-operated airplane-mode trial

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

## User-operated background/resume trial

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
