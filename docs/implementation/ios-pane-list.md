# iOS pane list checkpoint

Scope: companion #9 p9 on `feat/ios-pane-list`, based on protocol merge
`76da4e0383c447104fcab4027d6314843f0160ac`. Read companion PR #46 and
awesoMux PR #865 (base `main`, merged host `cfd459bf`). No publication.

## Design before implementation

Keep `GlanceSnapshot`, agent caching, widgets, Live Activities and notification
routing intact. Add a memory-only typed pane roster and preview permission value.
A Sessions tab renders host-ordered workspace sections with pane title, native
status, safe fallback for future kinds/availability, and optional terminal-only
preview. The existing Agents tab remains available. Notification focus chooses
Agents for known agents and Sessions for other current panes. There is no Watch
renderer, document content, relay or iPad-specific layout in this change.

Use existing paired mTLS transport and LAN/Tailscale failover. Preview mutation
uses `set_terminal_preview` with a Boolean, verifies its receipt and separate
`get_connection_status` readback, then refreshes the roster. Do not optimistically
show enabled previews. Permission changes invalidate reads and clear previews
immediately; pairing changes, disconnection, background and auth failure clear
pane content. Response generations prevent late reads repopulating content.
Treat missing permission as unknown/off and missing roster/unsupported operation
as older-host compatibility. Unknown kinds never expose preview content.

All Sessions, previews and consent UI remain descendants of the scene's
`TerminalLockContainer`. Transport remains outside the local authentication gate.
Pane content never enters UserDefaults, session cache, shared snapshots or widgets.

## Throughput checkpoint

- Blocking first steps: read merged contract, host endpoint and revoke paths,
  existing lock, polling, cache, selection and tests; write this checkpoint.
- Independent workstreams: n/a; this implementation worker owns coupled iOS
  model, transport, UI and tests. Parent owns fresh independent reviews.
- Shared mutable state: one main-actor CompanionStore and a pure typed roster value; monotonic request generation
  across permission/pairing/lifecycle changes. Agent state retains its existing owner.
- Smallest safe decomposition: one implementation owner avoids competing edits
  to polling/navigation. Validate model/transport, then actual SwiftUI rendering.

## Evidence required

Deterministic tests for ordered grouping, unsupported/unknown panes, consent
readback, opt-out clearing, stale reads, pairing/lifecycle invalidation, revoke
fail-closed behavior, and direct route/request behavior. Run all tests/builds,
simulator automation and screenshots inside heavy-gate. Use one dedicated owned
shut-down iPhone simulator with one foreground simulator-session job and cleanup.
Record commands, results and artifact identity. Runtime fixture evidence must be
labelled synthetic; it cannot establish real paired LAN/Tailscale or physical
biometric/device behavior. Accessibility polish and manual VoiceOver deferred.

Design update before validation: pane fetches run only from active polling via
`refreshPanes`, separate from background agent `refresh`/`readFeed`. Always read
permission status for v1 and v2; roster need not echo permission. Synchronous
scene inactivity invalidates the pane generation, including unstructured reads.
Keep notification focus until a loaded pane roster can reconcile both lists.

## Implementation and validation receipt

Implemented `CompanionStore`-owned foreground reads plus pure `PaneRoster` state;
Sessions/Agents tabs; grouped native rows; consent in Sessions and Settings;
self-only permission mutation using existing mTLS; permission/pairing generations
checked before routing, publication and error handling. Permission changes also
fence older agent authorization replies. Cold notification selection survives an
agent-only refresh and reconciles after both rosters are available. Terminal,
document, empty workspace, unavailable and future-kind projection is covered.

Commands ran inside `heavy-gate --simulator-session
E3C31483-F771-4D58-9D3D-5BBCA699BB9A -- sh
/tmp/companion-p9-evidence/verified-job.sh`:

- `swift test`: 33 protocol tests passed.
- `xcodegen generate`, then `xcodebuild test -project
  AwesoMuxCompanion.xcodeproj -scheme AwesoMuxCompanion -destination
  platform=iOS Simulator,id=E3C31483-F771-4D58-9D3D-5BBCA699BB9A
  -derivedDataPath /tmp/companion-p9-evidence/DerivedData
  -resultBundlePath /tmp/companion-p9-evidence/verified.xcresult
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=`: 62 tests passed, zero failures.
- Includes 18 roster/consent/lifecycle/route tests, 4 MacClient framing/request
  tests, and the new app-hosted SwiftUI rendering test. Existing cache, attention,
  route, terminal-lock model and terminal-lock rendering suites also passed.
- Exported XCTest screenshot attachments with `xcresulttool` inside the same job.
  Visually inspected the actual SwiftUI list with preview on, after opt-out,
  and with the terminal lock gate. Workspace order, terminal preview, document
  status, unavailable terminal and empty workspace render correctly. Opt-out
  screenshot contains no old preview; the lock screenshot covers the list.
- `git diff --check`: passed. Owned simulator was shut down by heavy-gate after
  every run, including failures. No automation daemon was launched.

Evidence root: `/tmp/companion-p9-evidence/`.

- `verified-tests.log`, `verified.xcresult`: successful iOS build/test receipt.
- `protocol-tests.log`: successful shared-protocol suite.
- `verified-job.sh`: exact foreground lifecycle command script.
- `screenshots/`: named copies of exported XCTest screenshots.
- `attachments/manifest.json`: original attachment-to-test mapping.
- `source-manifest.json`: tested sources and built application binary hashes.
- Earlier `initial`, `full`, `second`, and `final` logs/xcresults retain compile
  failures, XCTest actor-setup correction, and one route-fixture correction.
  They are superseded by the successful `verified` run.

Runtime scope: app-hosted UIKit/SwiftUI on dedicated iPhone 17, iOS 26.5,
synthetic client responses. No production trust changes, app launch bypass,
real identity, user credentials or live terminal content. T3 `device_list` was
read; no user-visible device stream was opened because this process has no
configured ACP terminal transport to invoke `device_open` inside its gate lease.
The XCTest runtime and screenshots stayed inside the lease.

Remaining evidence: real paired LAN/Tailscale exchanges; actual Mac permission
switch/revocation in flight; production navigation/touch consent dialog; cold
notification scrolling; physical Face ID/passcode/app-switcher behavior; manual
VoiceOver, large Dynamic Type and dark-mode inspection. Accessibility polish is
deferred. Live terminal Watch/p10 and iPad layout/p11 remain outside scope.
The parent owns fresh review-all and Claude review. No PR, push, comments or merge.
