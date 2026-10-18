# Companion snapshot diagnostic build

Generate with `ios/script/generate-diagnostics.sh` (runs XcodeGen and refreshes the source hash manifest). Build scheme
`AwesoMuxDiagnostics`; its bundle identifier is
`com.interactivebuffoonery.awesomux.diagnostics`. Only this target links
GhosttyTerminal at revision `42bacd1339f323a693ddbca779295f4f77e5a697`.
The renderer uses private CAIOSurfaceLayer and remains experimental.

The app root opens Watch diagnostics without pairing. Companion sources are
compiled into the diagnostic target, but fixture requests use their own transport.
No terminal callback is sent to a server or shell. The surface ignores touch input.

Local replay bundles exact copies of input.bin, away.bin, and reattach.bin.
It creates two fresh models: uninterrupted input+away versus reattach, compares
readViewportText and DSR cursor reports, then appends the same continuation to
both and compares again. JSON contains fixture/continuation hashes, observed
renderer dimensions, text/cursor assertions, and separate manual observations.
Use Export JSON evidence to share the persisted application-support file.

The pinned package has no fixed grid option in TerminalSurfaceOptions. The wrapper
sizes its surface from reported cell pixel metrics and measured non-cell area.
When the pinned iOS binary reports zero cell metrics, bounded sizing feedback
uses the actual reported grid to converge; explicit fixed sizing prevents
SwiftUI compression. Requested point sizes and raw pixel/cell metrics are exported.
Every feed requires an actual 20-column, 6-row report; sizing times out closed.
Build success does not establish that dimensions converge or replay passes.

Diagnostic action links `awesomuxdiagnostics://replay`, `awesomuxdiagnostics://connect`, and `awesomuxdiagnostics://disconnect` drive smoke checks without changing manual results. Configuration links remain load-only.

Enter the fixture HTTPS URL, per-launch bearer token, and exact leaf certificate
DER SHA256, or open an `awesomuxdiagnostics://fixture` configuration link. Never
include that link or token in shared evidence. Requests require TLS 1.2+, match
the configured host and exact certificate pin, reject redirects, and limit JSON
to 256 KiB. This explicitly pinned selfsigned fixture trust is independent of
normal companion pairing. Physical HTTP is rejected.

Connect/reconnect always fetches a fresh snapshot and replaces the entire terminal
model before polling events. A 409 fetches a new snapshot; mismatched run IDs,
dimensions, schema, or noncontiguous sequences fail closed. Disconnect cancels
work and changes generation identity. After a transport failure, press
Connect / reconnect to recover. Manual physical reconnect and rendering results
start unverified and must be recorded separately after observation.

Compilation alone does not establish runtime replay or network recovery.
Recorded Simulator and physical-phone results are in [verification.md](verification.md).

Connect (including its action link) requires a successful local replay from this
app process with matching fixture-set and source-manifest hashes. Evidence keeps
that prerequisite's originating generation separately from the current attempt.
Snapshot sequence Int.max and overflowing event successors are rejected.
A last-32 recovery log preserves connect/disconnect, transport/validation failure,
409 origin run/sequence, and subsequent fresh-snapshot run/sequence/outcome.

Accessible screen text distinguishes live/reference and restored viewports.
Accessibility announcements occur on phase transitions, not sequence updates.
Manual marks record tester-attested phase, generation, run, and timestamp; pass
requires replayPassed/watching for rendering and watching on a physical device
for physical reconnect. New attempts, configuration changes, and replacement
network snapshots reset marks to unverified.

The diagnostic target runs script/diagnostics-manifest.py before every build.
It writes directly into the app bundle and includes Swift sources, fixture bytes,
Info.plists, project.yml, generation scripts, and Package.resolved. It does not
invoke XcodeGen recursively. The source-manifest.txt source copy is informational
and excluded from target resources; pre-build output is authoritative.

## Build and run on another Mac or phone

Requires Xcode, XcodeGen, Python 3, and a compatible zmx executable for network
fixtures. From the repository root:

```sh
ios/script/generate-diagnostics.sh
xcodebuild -project ios/AwesoMuxCompanion.xcodeproj \
  -scheme AwesoMuxDiagnostics \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/build/DiagnosticsSimulator build
```

For a phone, open the generated project in Xcode, select **AwesoMuxDiagnostics**,
choose your signing team and connected device, then Run. Keep this separate
bundle installed alongside the companion app; it opens diagnostics directly.
Do not use the shipping scheme or TestFlight script for this experimental app.

1. Tap **Run local replay** and wait for a pass before connecting.
2. Start the Mac fixture endpoint using the command in [README.md](README.md).
3. Configure the app with that run's private URL/token/pin or configuration link.
   Keep the phone and Mac on the same reachable LAN. Allow Local Network access
   on the phone when prompted.
4. Tap **Connect/reconnect**. For an outage trial, disable phone networking while
   the Mac continues output, restore networking, then explicitly reconnect.
5. Export JSON evidence. Record visual and accessibility observations separately;
   automated parser assertions do not establish those results.

A server restart creates new credentials and requires reconfiguration. Bundled
replay works without the fixture server. See the verification ledger for tested
behavior and remaining gaps.
