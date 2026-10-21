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

## Original implementation receipt at 3bf284f (superseded below)

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

## Review-fix checkpoint before edits

Read `/tmp/companion-p9-review-all-r1.md` completely. R1 and R2 are verified in
source: display permission resets discard failed opt-out suppression, and the
unowned async mutation can outlive suspension. Keep a separate in-memory local
preview intent across read errors and scene transitions; only a new confirmed
enable or pairing reset releases it. Give permission writes an independent task
owner across suspension. New choices suppress immediately, wait for the prior
write to settle, and only the latest queued choice may send. Cancellation does
not imply undoing a server mutation.

Verified C1 against merged host `cfd459bf`: `commitCompanion` rejects changed
lease revisions with permission_denied; the request handler may return that code
without proving persistent revocation. Replace the permanent revoked latch with
recoverable pane failure plus offline agent metadata, preserving agent/widget
caches. Keychain failures recover through the same next-poll path. C2 is verified:
only idle should enter loading; empty/unsupported/error state remains during a
read. C3 is verified: reconcile unsupported panes with a known agent roster and
route notifications only to known panes. Use a stable ID+destination task key so
unrelated agent updates do not override a person's selected tab. C4 duplicates R1.
Mac-disclosed preview consent remains sufficient. R3 pane type in VoiceOver is
explicitly deferred and nonblocking; do not expand that scope.

Validation: deterministic held-response tests for both recovery sequences, owned
mutation ordering across suspend/resume, transient authorization recovery, stable
empty/unsupported reads and old-host notification routing; rerun iOS tests and
SwiftUI screenshots under the owned heavy-gate simulator session. Update fixture
time, source/binary hashes, receipts and this report. Parent owns fresh reviews.


## Review-fix receipt

Verified and addressed all blockers forwarded by the parent:

- R1/C4: pure `PaneRoster.previewIntent` retains local suppression independently
  of transient permission UI state. `testUnresolvedOptOutSurvivesReadFailureAndSuspendRecoveryUntilConfirmedEnable`
  exercises failed opt-out, read error or suspend/resume, successful recovery
  while the host still permits content, and explicit confirmed enable. Old text
  stays absent until that enable. Pairing reset/unpair clears the intent.
- R2: one `previewMutationTask` owns a write through receipt/readback regardless
  of scene suspension. New choices suppress immediately and await that owner;
  only the latest queued choice may send. Completion clears task ownership
  before releasing waiters. `testPendingEnableOwnsMutationAcrossSuspensionBeforeNewOptOutCanSend`
  holds enable before its host mutation, suspends/resumes, proves no newer wire
  write/poll can proceed, then confirms queued opt-out after the old enable
  settles. Host fixture ends false; even a later ambiguous true observation
  cannot release local suppression. Cancellation is not treated as server undo.
- C1: removed permanent revoked state and destructive cache reset on denial.
  Source verification used host commit `cfd459bf`, `commitCompanion` revision
  checks and the network handler's permission-denied reply. The authorization
  regression preserves disk/shared agent metadata offline and recovers for
  agent, pane and permission endpoints. A separate test exercises temporary
  Keychain failure plus repeated genuine denials: no pane preview is published
  while denied, and a later valid response recovers.
- C2: only idle becomes loading. A controlled repeated poll holds list_panes and
  asserts that loaded-empty, unsupported and failed state remain stable. This
  keeps empty-state consent/navigation from being torn down during polling.
- C3: unsupported rosters reconcile focus only after agent metadata is known.
  Unknown targets have no navigation destination. Tabs key notification work by
  known pane ID plus destination, so unrelated agent updates keep the same key
  and do not reselect a tab. Tests cover cold/stale old-host targets, a known
  agent with changing status, and an unknown target during a failed pane read.
- R3 is deferred, nonblocking: unavailable terminal/document rows omit pane kind
  in their combined VoiceOver text. No actual VoiceOver output is claimed.
- No forwarded correctness finding was dismissed. C4 duplicates R1. The proposed
  redundant phone opt-in for a newly Mac-approved pairing is intentionally not
  added: the host's disclosed approval and explicit status readback remain the
  consent contract. A local deliberate opt-out now requires confirmed enabling
  on this phone before content is displayed again.

Final fix validation ran through:
`heavy-gate --simulator-session E3C31483-F771-4D58-9D3D-5BBCA699BB9A -- sh /tmp/companion-p9-evidence/final-fix-job.sh`.

- Shipping iOS build plus **69 tests passed**, zero failures, including 25 roster
  tests, actual SwiftUI opt-in/opt-out/locked renderings and existing regression
  suites. No Swift compiler warnings in this run. The standard Xcode host-build
  metadata diagnostic remains in its log; it did not fail the test run.
- Exact command/log/results: `/tmp/companion-p9-evidence/final-fix-job.sh`,
  `final-fix-tests.log`, `final-fix.xcresult` and `final-fix-xcodegen.log`.
- Fresh attachments: `final-fix-attachments/manifest.json`; named screenshots under
  `final-fix-screenshots/`. Fixture capture time now uses the current run time.
- Final source and executable/dylib hashes: `fix-source-manifest.json`.
- The unchanged protocol package retains the earlier 33-test pass; it was not
  rerun for these iOS-only fixes. `git diff --check` passed.
- Owned simulator was shut down by heavy-gate. No automation daemon, push, PR,
  comments or merge. Parent owns fresh focused Codex and Claude reviews.

Evidence limits are unchanged: synthetic app-hosted SwiftUI/client responses,
not real paired LAN/Tailscale, live Mac permission races, production touch/dialog
navigation, physical biometric/app-switcher behavior or VoiceOver. Notification
routing here has state/task-key coverage, not an interaction-tested cold scroll.

The final run also includes recovery-oriented authorization error text; prior
`fix.xcresult` is the preceding 69-test pass before that copy adjustment. The
source manifest records the final-fix artifact and its committed sources.

## R2 / Claude r2 implementation checkpoint

Verified before editing: the latest accepted choice is owned by its waiting
caller, whose lifecycle/cancellation guard can drop an opt-out queued before
suspension. A store-owned worker will drain the latest accepted choice through
receipt/readback, independent of caller lifetime and scene state. Ownership stays
continuous until the queue settles; pairing replacement detaches that worker and
uses an ID fence so its late completion cannot release a new pairing's owner.
No queued write is automatically replayed across process death.

Persist only a suppression preference, keyed by connection ID, Mac fingerprint
and phone identity tag. Write it before an explicit permission change; restore
it for the same pairing at initialization. Confirmed enable clears it; unpair or
pairing replacement clears it. Neither previews nor rosters enter defaults.
Repeated authorization denials should publish an offline shared snapshot only
on the connected-to-offline transition, respecting Live Activity enablement.

Add controlled regressions for suspension after enqueue, cancellation of the
waiting caller, store recreation after failed/successful opt-out and confirmed
enable, identity scoping, repeated denials, and a held old-pairing mutation while
the replacement pairing reads and changes consent. Preserve earlier recovery,
focus and empty-state tests. Rerun the iOS suite and SwiftUI rendering under the
owned heavy-gate simulator lease, then refresh exact evidence hashes and receipt.

## R2 / Claude r2 final receipt

The earlier R2 receipt is superseded by this worker fix. No new finding was
dismissed; F1 is the same accepted-choice loss found by Codex r2.

- F1/R2: `drainPreviewChoices` owns delivery rather than a waiting caller.
  `testQueuedOptOutDrainsWhenSuspendedAfterAcceptance` and
  `testQueuedOptOutDrainsWhenWaitingCallerIsCancelled` hold enable before its
  host mutation, accept opt-out, suspend or cancel its caller, then settle both.
  The host ends disabled and no updating state is abandoned. Both tests also
  hold the queued opt-out after the enable settles and prove polling cannot
  enter during that handoff (F3). Existing lifecycle/recovery tests still pass.
- F2: suppression is persisted before writes and restored only for the same
  connection ID, Mac fingerprint and phone identity tag. The recreation test
  covers failed opt-out and successful opt-out followed by Mac re-enable, and
  verifies that explicit receipt/readback-confirmed enable clears persistence.
  Identity-scope tests cover each identity field and clearing on unpair. No
  terminal content or pending network operation is persisted.
- F4: authorization failures publish the shared offline snapshot only when it
  was connected, and only sync Live Activity when enabled. The repeated-denial
  test counts one offline write across repeated pane and agent/status denials,
  preserves agent metadata and then recovers. Existing C1 behavior is retained.
- F5: pairing reset detaches mutation ownership. An ID fence prevents old work
  from releasing or publishing into a new owner. The old-pairing mutation test
  holds an enable, unpairs and installs a replacement fixture pairing, reads
  its roster and holds its opt-out, then settles the old request first. The
  replacement owner remains intact and ends disabled. This uses the same
  persisted-record installation method as successful production pairing;
  actual Keychain/network pairing is not exercised.

Final validation command:
`heavy-gate --simulator-session E3C31483-F771-4D58-9D3D-5BBCA699BB9A -- sh /tmp/companion-p9-evidence/r2-final-job.sh`.

The iOS build and **75 tests passed**, zero failures, including 31 pane roster
and fresh actual SwiftUI rendering tests. No compiler warnings. The existing
Xcode host-build metadata diagnostic remains nonfatal. The unchanged protocol
package retains its earlier 33-test pass; it was not rerun for iOS-only changes.
`git diff --check` passed. All builds, tests and screenshot capture/export used
the owned simulator lease; heavy-gate shut it down and released the lease.
No automation daemon was started. Device-panel opening was unavailable inside
the job because this session has no terminal ACP transport; no separate
lease-less device open was attempted.

Final evidence under `/tmp/companion-p9-evidence/`:

- `r2-final-job.sh`, `r2-final-xcodegen.log`, `r2-final-tests.log`,
  `r2-final.xcresult` and `r2-final-attachments/manifest.json`.
- `r2-final-screenshots/`: preview off/on, after opt-out and locked SwiftUI list.
  Current-time fixture, visually inspected; no preview remains after opt-out.
- `r2-source-manifest.json`: final commit, source/docs, built code and screenshot
  hashes. `r2-handoff.txt` identifies the final artifact for parent review.
- `r2-worker.xcresult` is the preceding 75-test pass before strengthening the
  held queued-write polling assertion; use `r2-final.xcresult` for final sources.

Earlier R1/C1-C3 fixes remain covered. R3 VoiceOver pane-type omission stays
explicitly deferred. Evidence remains synthetic client/app-hosted SwiftUI;
real paired LAN/Tailscale, physical authentication/privacy timing, production
consent touches and cold-notification scrolling remain unverified. No push,
PR, GitHub comment or merge. Fresh focused Codex/Claude reviews are parent-owned.
