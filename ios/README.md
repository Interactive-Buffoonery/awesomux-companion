# awesoMux Companion for iPhone

A paired companion for awesoMux. It shows which agents (Claude Code, Codex,
OpenCode, Pi, Grok) need you, are working, or are done, in four places: the app,
a Home Screen and Lock Screen widget, a Live Activity (Lock Screen and Dynamic
Island), and notifications. Terminal typing is available with the separate Mac-approved Input switch.

SwiftUI, Swift 6, iOS 26+, iPhone and iPad. The phone pairs with awesoMux on
the Mac and reads `list_agents` and `get_attention_events` over mutual TLS, as
described in the awesoMux repository's `docs/companion-pairing-protocol.md`.

## Layout

| Path | What it holds |
|------|---------------|
| `AwesoMuxCompanion/` | App target: pairing flow, phone identity, mutual TLS client, polling store, agent list, Live Activity lifecycle, notification handling |
| `AwesoMuxCompanionWidgets/` | Widget extension: the `Agents` widget (small, medium, accessory rectangular and circular) and the Live Activity UI |
| `Shared/` | Compiled into both targets: snapshot model and decoder, App Group storage, `GlanceActivityAttributes`, shared views |
| `../Sources/AwesoMuxCompanionProtocol/` | Local Swift package used by the app for wire types, framing, links, and confirmation words |

The app writes each snapshot to the App Group
`group.com.interactivebuffoonery.awesomux.companion` and reloads widget timelines
only when agents, connection, or host change. The widget never touches the
network.

## Build

Watch uses the pinned source-built public CAMetalLayer renderer. First integrate
its schema 2 native artifact using the recipe in
`../spikes/snapshot-reconnect/ios-diagnostics.md` into
`ios/build/diagnostics-native`. The original source, toolchain and receipt must
remain available. `script/generate-watch.sh` checks that integration, generates
the app project, and seeds the pinned dependency lock. Every app build validates
the native inputs and dependency pins again. There is no downloaded binary
fallback. The app bundles the renderer's third-party notices and supports arm64
Simulator and device builds.

```sh
cd ios
zsh script/generate-watch.sh
xcodebuild -project AwesoMuxCompanion.xcodeproj -scheme AwesoMuxCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

`AwesoMuxCompanion.xcodeproj`, both `Info.plist` files and both entitlements files are
generated from `project.yml`; edit the spec, not the outputs.

Signing is ad-hoc ("Sign to Run Locally"). The Simulator needs a signature to
grant the App Group from the simulated entitlements, so signing is on even
without a team. A device build needs a team and a provisioning profile with the
App Group; set `DEVELOPMENT_TEAM` and switch `CODE_SIGN_STYLE` to Automatic.

## Pairing

On the Mac, open awesoMux Settings → awesoMux Companion and choose Pair iPhone.
On the phone, scan the QR code or paste the copied
`awesomuxcompanion://pair?...` link. Both screens show the same three words;
choose Allow on the Mac.

The phone creates a P-256 key (in the Secure Enclave when available, otherwise
a this-device-only Keychain key) and a self-signed certificate for it, and pins
the Mac's SPKI fingerprint from the link. The pairing record lives in the
Keychain. Pair Again creates a fresh key; once the new pairing succeeds, the
phone asks the previous Mac to revoke the old one and then deletes the old key.
Revocation is best effort: if the previous Mac is unreachable, remove the old
pairing in its settings. Quitting during cleanup can leave the old key in Keychain.
Unpair This iPhone first asks the Mac to revoke
this phone's pairing, waiting up to three seconds. It then deletes the pairing
and key on the phone even if the Mac is unreachable or runs an older version.
If the Mac does not acknowledge the request, the welcome screen keeps a reminder
to also choose Unpair in awesoMux Settings on the Mac, including after relaunch.
A successful new pairing clears the reminder. If local deletion fails, Settings
keeps the pairing available to retry and shows a short error.

To pair the Simulator, open a link with
`xcrun simctl openurl <UDID> 'awesomuxcompanion://pair?...'`.

While the app is in the foreground it polls every 5 seconds; pull to refresh
fetches immediately. In the background it asks iOS for app refresh about every
15 minutes, which iOS schedules at its discretion.

## Notifications and Live Activity

The app asks for notification permission right after the first successful
pairing, or from Settings → Notifications. Each new attention event becomes a
local notification, shown in the foreground too; events already open when the
phone first connects do not notify. Tapping a notification opens the app and
highlights the pane named by `paneID`. There is no push: notifications arrive
only when the app refreshes.

The Live Activity starts while the app is in the foreground, connected, and at
least one agent needs you or is working, unless it is turned off in Settings. It
then follows each refresh:

- updates when counts or the top item change, plus a 60 second heartbeat;
- content goes stale 15 minutes after the last update, and the card then shows
  its update age (for example, "Updated 20 min ago");
- once nothing needs you or is working, it ends and keeps the final card for 5
  minutes;
- it ends immediately on a host change or unpairing, or when a confirmed
  foreground connection failure leaves data more than 30 minutes old.

A failed refresh only marks shared agent metadata offline if the read started
and failed during the same active scene session. Inactive transitions and
background failures preserve the last snapshot; age alone does not establish
that the Mac is offline.

## TestFlight

`./script/testflight.sh` archives a build, uploads it with the [`asc`](https://asccli.sh) CLI, and adds it to the internal "Personal Testing" group. That group's distribution is Manual, so the script adds each build to it after processing.

### One-time setup

1. Sign in to Xcode with an Apple account on team 7CNK4YPCQX (Xcode → Settings → Accounts). Signing uses this account.
2. Install the tools: `brew install asc xcodegen`.
3. Create an App Store Connect API key with the App Manager role at [Users and Access → Integrations](https://appstoreconnect.apple.com/access/integrations/api). Download the `.p8` file (Apple only lets you download it once) and note the Key ID and Issuer ID.
4. Store the key in your Keychain:

   ```sh
   asc auth login --key-id KEY_ID --issuer-id ISSUER_ID --private-key ~/Downloads/AuthKey_KEY_ID.p8 --fix-permissions
   ```

   Then delete the downloaded `.p8`.
5. Check it works: `asc apps list` should show awesoMux Companion.

### Upload a build

From `ios/`:

```sh
TEST_NOTES="What changed in this build" ./script/testflight.sh
```

The build number is the current UTC time, so it always increases. The script waits until App Store Connect finishes processing, then the build appears for the group's testers. Set `TESTFLIGHT_GROUP` to send it to a different internal group.

### Minimighty runner

From a clean repository root, `process-gate ./ios/script/testflight.sh` can run on
minimighty using its dedicated signing keychain and App Store Connect API key.
Use `--export-only` to archive and export an IPA without uploading or assigning
it to a testing group. Logs and the IPA return under `.build/testflight/`.
The archive and DerivedData use the job's SSD-backed TMPDIR.
Use `--check-signing` for a small signing and signature-verification probe before
a full archive. Runner setup installs Apple's public WWDR G3 intermediate in
the login keychain so the system chain builder can discover it; private signing
keys stay in the dedicated runner keychain.

Only a TestFlight job sources runner settings that export `HEAVY_GATE_XCODE_AUTH_CONFIG` pointing to a restricted JSON
file with `private_key_path`, `key_id`, and `issuer_id`, plus
`HEAVY_GATE_SIGNING_KEYCHAIN` and `HEAVY_GATE_SIGNING_PASSWORD_FILE` pointing to
the dedicated keychain and its restricted password file. `ASC_CONFIG_PATH` and
`ASC_BYPASS_KEYCHAIN=1` let asc use the same API credential from the isolated job
HOME. Local runs keep using Xcode's existing account when these are absent.

For manual App Store export, runner settings can also supply
`HEAVY_GATE_XCODE_EXPORT_CONFIG`, a restricted JSON file with exactly these fields:

```json
{
  "signingCertificate": "UPPERCASE_40_HEX_SHA1",
  "profiles": {
    "com.interactivebuffoonery.awesomux.companion": "/absolute/app.mobileprovision",
    "com.interactivebuffoonery.awesomux.companion.widgets": "/absolute/widgets.mobileprovision"
  }
}
```

Replace the certificate placeholder with the distribution certificate's uppercase
40-character SHA-1 fingerprint. Both profiles must be unexpired App Store profiles
for team `7CNK4YPCQX`, match their exact bundle IDs, and include that certificate.
The script validates their UUIDs and requires `get-task-allow` to be false and both
`ProvisionedDevices` and `ProvisionsAllDevices` to be absent. It decodes profiles
without printing their contents and installs mode-0600 copies in the disposable
HOME's `Library/Developer/Xcode/UserData/Provisioning Profiles` directory, used by
Xcode 16 and later.

This configuration is accepted only in an isolated remote job. Export uses manual
signing with the certificate fingerprint and profile UUIDs, avoiding cloud
signing. Archive retains API authentication and provisioning-update flags; manual
export omits them. With manual export configured, remote `xcodebuild` invocations
set `CFFIXED_USER_HOME` to the disposable HOME so Xcode discovers those profiles
and keeps its home writes isolated.
`--check-signing` validates and installs the configured profiles before probing
signing, using the configured distribution certificate. Without this configuration,
export keeps automatic signing; local Xcode behavior is unchanged.

The gate forwards TEST_NOTES, TESTFLIGHT_GROUP and BUILD_NUMBER as literal data.
Never check credentials into this repository.

## Snapshot diagnostic app

The separate `AwesoMuxDiagnostics.xcodeproj` / `AwesoMuxDiagnostics` scheme uses
the source-built public CAMetalLayer renderer for bundled replay and
an isolated synthetic Mac-to-phone reconnect fixture, without pairing. See the
[build and usage guide](../spikes/snapshot-reconnect/ios-diagnostics.md) and
[verification ledger](../spikes/snapshot-reconnect/verification.md).

## Agent and terminal protection

App locking is optional and off by default. Settings → Privacy → Lock App
opts in to Face ID, Touch ID, or device passcode authentication for paired agent
content on each launch. Turning it off requires authentication, including from
the locked screen. On upgrade, an absent preference from the previous forced
default becomes off; an explicitly saved on or off choice is preserved. Previous
builds wrote on only when the user enabled the setting. Pairing stays available
without unlocking. With Lock App enabled, authentication failure or cancellation
leaves the gate closed. Devices without a passcode stay locked and show
instructions to set a passcode in iOS Settings. Enabling Lock App locks immediately.

The grace clock advances during device sleep. Background returns under 15 seconds keep an already unlocked session; returns at
15 seconds or later lock again. Every inactive scene gets an opaque
privacy window above app navigation and sheets, even with Lock App disabled.
Backgrounding cancels pending authentication and rejects late results. Temporary
inactivity during the system authentication prompt withholds success until active.
Polling, notifications, widgets and Live Activities run independently of this
screen lock; their existing content visibility is unchanged.

Issue #10 should reuse `TerminalLockContainer` at the terminal entry point, with
one scene-owned `TerminalLockModel`. Today the app root gates paired agent content
because there is no shipping terminal view. Keep transport, phone identity and
background refresh outside the container: this is local screen protection, not
cryptographic proof of user presence to the Mac.

`project.yml` supplies the Face ID usage text through the app's
`INFOPLIST_KEY_NSFaceIDUsageDescription` build setting. The source plist contains no
second copy. The scene bridge uses the model's synchronous security-change hook
for lock, activity and authentication-failure updates.

`TerminalLockModelTests` uses an injected monotonic clock, isolated preferences and
controlled authentication completions without needing a window scene.
`TerminalLockRenderingTests` is an app-hosted integration test: it renders the gate
and checks the cover above a sheet using the host's active scene and owned windows.
It keeps screenshot attachments
in the xcresult and restores those windows without posting synthetic lifecycle
notifications to the rest of the app.

A fresh roster clears notification selections for panes that have exited. A
selection for an existing pane waits for unlock and yields to list rendering before
scrolling and starting the highlight timer. Store tests cover stale selection
cleanup; cold-list scrolling still needs interaction verification.

Unit renderings do not verify the actual iOS app switcher, biometric or passcode
UI, accessibility focus, or device lifecycle timing. Verify those separately on a
device, including sheets, backgrounding during authentication and a grace return.

## Sessions and terminal previews

Sessions lists the Mac's workspaces and panes in their native order, including
plain shells, split terminals and document groups. Each row shows availability
and terminal/agent status. Unknown pane kinds remain metadata-only. Every
terminal with a target version opens, including panes awaiting hydration on the Mac. When Input is on, opening
claims control at the phone's grid after the snapshot and raises the keyboard.
Choose Watch from the row's context menu to open without claiming. Input off or
missing permission metadata keeps the existing Watch behavior.

Sessions offers New Workspace under + when the Mac permits workspace creation,
and New Pane in each workspace when pane creation is permitted. Both require
Input. The phone opens the returned target ready to type. Creation uses one
route with no automatic retry; after a missing acknowledgement, Sessions refreshes
so you can check whether the terminal was created before trying again. Remote-owned
workspaces cannot be identified from the roster and show the Mac's refusal.

The Mac must send optional `terminalInputAllowed`, `createWorkspaceAllowed` and
`createPaneAllowed` Booleans on `get_connection_status`; absent fields mean false.
The `create_terminal` endpoint uses phone-local Codable envelopes and does not add
a shared operation. The iPad-specific layout remains #11.
Agents appear as ◆ rows in Sessions. Notification focus, cached agents, widgets
and Live Activity keep their existing roles.

Only active foreground polling requests `list_panes`; background refresh still
reads agents and attention events. These reads use the same paired mutual TLS
client and direct LAN/Tailscale routes. Pane failures have their own display state
and do not mark a successful agent refresh offline. An authorization denial
clears pane content and, within an uninterrupted active session, marks existing
agent/widget metadata offline, preserving the cache. The next valid poll can
recover: a changed Mac lease or a temporary Keychain failure can also cause a denial. Transport failures clear the pane list; they cannot establish whether a
phone was revoked or its Mac is offline.

Terminal previews are off unless the Mac explicitly reports permission. Sessions
and Settings offer a per-phone consent switch; enabling explains that terminal
text may contain secrets. Changes use `set_terminal_preview`, verify its receipt,
and read `get_connection_status` again before showing previews. An unsuccessful
change clears prior preview text. Suppression persists for this pairing across
read errors, scene transitions and app relaunches. It is a non-content preference
scoped to the connection ID, Mac fingerprint and phone identity. Only a confirmed
enable clears it; successfully replacing or removing the pairing resets it.
An unsuccessful unpair preserves suppression while its pairing remains installed.
A store-owned worker drains the latest accepted choice even if its caller is
cancelled or its scene suspends. New choices suppress immediately and wait for
older writes to settle. Polling cannot release ownership between queued choices.
A replacement pairing has independent ownership; late old completions are fenced.
Permission and pairing epochs reject late responses. The active poll reads
permission again for both v1 and v2 pairings. Older Macs list agents from the glance
snapshot under an update message for unsupported pane lists.

Pane rosters and previews stay in process memory, outside `GlanceSnapshot`, the
cached agent snapshot and App Group/widget storage. Backgrounding clears them
and invalidates unfinished reads. All Sessions and consent UI lives beneath
`TerminalLockContainer` and its scene privacy cover. Sessions adds no relay access, document content, saved previews or widget
previews. Simulator fixture screenshots demonstrate SwiftUI rendering; actual
paired networking, physical biometric/passcode flows and VoiceOver need separate
verification. Accessibility polish remains deferred.

## Inline Claude permission answers (issue #22, first layer)

Sessions links to once-only Allow and Deny (also in Settings) for requests issued by the Mac's
permission core over the existing paired LAN/Tailscale connection. Requests
show a bounded, plain-text untrusted summary, workspace and pane names joined
by exact IDs (or the IDs when names are unavailable), and the invocation ID and
revision. Outcomes retain the same request context and name the winning source.
There are no notification or lock-screen actions in this layer.

**Production remote decisions remain disabled.** The phone first reads
`get_connection_status`; a false `remoteDecisionsEnabled` shows the disabled
state without calling the currently denied production list. Missing capability
metadata is unsupported, not permission to answer. An enabled Mac must also
return a complete fresh pending/outcome list under a separate Mac-approved
Decide switch for this phone, which covers every workspace. Pairing and agent attention never
create decision authority. ADR-0038's real Claude native-prompt race acceptance
is still required before any provider/version can be enabled on the Mac.

Every answer and explicit retry uses a new device-owner authentication context,
even with Lock App off or an already unlocked app. Authentication failure sends
nothing. The phone re-reads the Mac after authentication and checks the exact
identity, supported choice, expiry, active scene and unlocked gate again before
sending. A background transition, pairing replacement or lock invalidates late
authentication. Temporary inactivity caused by the authentication sheet withholds
success until active and then performs the fresh read. The mutual TLS client
rechecks the scene/pairing gate after connecting, immediately before enqueueing
the decision frame.

Reads retain normal route failover. A decision write uses one route; a dropped
reply never causes automatic replay on a second route. The phone reconciles
using a fresh list. Only a still-pending exact request offers Retry Same Answer,
which requires authentication again and preserves identity, choice and retry
UUID. No new or conflicting choice can replace a possibly sent answer. There
is no offline queue. Original receipts and fresh outcomes are displayed
separately: recorded means the Mac accepted an answer, delivered means the hook
acknowledged it, and neither proves that Claude executed a tool. Expired,
cancelled and unknown states are inert.

Decide denial clears decision content and invalidates decision
operations without changing agent, pane, widget or Live Activity connectivity.
Authentication generations are separate from pairing identity: a temporary
authority loss retains the same pairing's bounded retry tuples and deadline
history; replacing or removing the pairing clears them. Remote refusal receipts
are shown as refusals even when the Mac's local request remains pending. An
original losing receipt identifies the winning source and says this phone's
attempt was not used; fresh list statuses describe the current state without
implying that every list entry is a losing phone submission.

Decision summaries and outcomes live only in the scene model. Inactivity,
locking, backgrounding, stale/failed reads and pairing changes clear displayed
content. Decisions never enter the agent cache, App Group, widgets, Live Activity
or notifications. Fixed wall and sleep-aware monotonic deadlines prevent repeated
reads or clock rollback from extending a remote window. In-memory retry tuples
expire after ten minutes. Identity/deadline history prunes only after its fixed
wall and monotonic deadlines plus a retry horizon. A per-pairing wall-clock high
water mark prevents an immutable expired wire deadline from reopening after
pruning and clock rollback. Saturated history shows an explicit capacity state.
Foreground polling refreshes every five seconds. Pending and outcome rows remain
stable during an unchanged successful poll while answer authority is withheld;
a failed read clears them. Content becomes non-actionable after six seconds
without a fresh read. Guarded reads recheck scene and lock state between status
and list, on route retries, and just before each request frame is sent.
Accessibility announcements cover authentication failure, uncertain submission,
expiry and changed outcomes only while active and unlocked, with repeated poll
results deduplicated. Model tests control clocks, authentication and asynchronous completions;
store tests cover production gate discovery, route handling and authority at
send. App-hosted fixture renderings exercise request context and status copy;
physical authentication, live paired networking, native Claude races and
VoiceOver still need separate acceptance.

## Watch

Tap an attached terminal in Sessions to watch its real paired snapshot and live
output over the direct LAN/Tailscale connection. Watch is one switch per phone
in Mac Companion settings, covering every workspace, separately from terminal
previews. A Mac
without the stream contract needs an update. Documents and unknown pane kinds
remain metadata-only.

Every attach, reconnect and overflow resync starts a fresh generation. The phone
checks target identity, dimensions, contiguous byte sequences and snapshot byte
counts before continuing. Truncated or out-of-order streams discard the model.
Earlier history is always labeled incomplete: snapshots retain terminal cells,
but do not recover logical wraps, command boundaries or exit codes. Retention
is bounded; Watch never invents missing history.

The terminal fills the phone's view, the way a tmux client does. Ghostty measures
the grid that fits at the chosen text size, and while the phone drives it resizes
the Mac pane to that grid. Resizes wait briefly for the layout to settle, so the
Mac sees about ten per second at most, and an input opening waits for the first
measured grid. The keyboard, rotation and
text size all change the measured grid. While watching only, plain output
rewraps to the phone's width; full-screen apps drawn for the Mac's size settle
once the phone takes over. Local selection, copy and history scrolling do not
send input. Native query replies, clipboard escape sequences, notifications and
link opening are suppressed. Watch-only streams never send input, takeover,
reply or resize frames, including when no Mac client leads. Chat (#18) and iPad
layout (#11) remain separate work.

When the Mac accepts an interactive stream and advertises `inputFrameMax`, Take
over claims with the phone's grid. Attaching remains a follower. The first key, and the next key after a phone-grid change, send the latest
grid before input, allowing the Mac to apply it atomically with that key's claim. While the phone
has control or the keyboard is up, each new measured grid is sent right away. The keyboard toggle
opens a compact Esc, Tab, one-shot/locked Ctrl and Alt, and arrow bar. Double-tap
a modifier to lock it; tap again to turn it off. Its menu and accessibility
actions also provide Lock/Unlock without timed taps. A lone Escape owns its frame.

Input uses a separate UIKit responder. The pinned renderer exposes a combined
write callback for both keys and replies, without a provenance-aware encoder,
so the app encodes ordinary terminal keys separately and keeps every renderer
write local. Paste and arrow keys query mode 2004 and DECCKM from the actual
phone emulator using local DECRQM reports. Probes wait for a complete UTF-8 and
control-sequence boundary and a drained renderer, so they cannot interrupt
split output. Fresh random marker reports fence earlier mode reports without
reimplementing native parameter parsing; an unavailable probe
shows not sent. The Swift paste port follows
Ghostty's text-insertion strip set, safety checks and bracket/CR encoding. One
paste is one frame, at most 64 KiB after encoding. Unsafe text needs Send/Cancel
confirmation; pending confirmation ends with its generation. Snippets, rerun,
composer/dictation and terminal reply frames are outside this layer.

Paste status distinguishes sent (Mac ack), not sent, and may have run after two
seconds or disconnect. Sent means forwarded to the daemon socket, not executed
or accepted by the daemon. Late acks in the same generation can settle an
uncertain paste. Unacked typing shows a brief notice after two seconds or
disconnect. Nothing is
replayed across reconnect, resync or route change.

Mac integration is awesomux #788. For the driving label, the relay must map a
Mac leader to `mac` and this phone's leader to its paired connection UUID;
unknown daemon attachment IDs display “Another terminal is driving”. The
current protocol advertises no mapping from opaque daemon IDs to device names.
Real Mac integration must also verify grid-before-input, acknowledgements,
permission changes, concurrent typing and safe-paste behavior in real TUIs.

Watch closes its connection and clears terminal content when inactive, locked
or dismissed. Foreground recovery uses a new attach and snapshot, with bounded
retry delays for transport failures. Permission refusals stop retries. Content
stays in memory and never enters agent caches, widgets, notifications or logs.
The screen uses the scene's existing terminal lock and privacy cover.

Regression checks reuse #35's bundled replay bytes with the production renderer,
plus controlled paired-stream frames for ordering, reconnect and lifecycle
failures. Physical devices, VoiceOver, real paired LAN/Tailscale interruptions,
long suspension/relaunch and complete selection/scrollback interaction still
require acceptance. The synthetic HTTPS fixture remains test tooling only.

Remote TestFlight jobs build the pinned native renderer from source before
generation, retaining its original inputs and schema 2 receipt for validation.
This adds a full native build to each fresh runner job.

## Watch disconnect diagnostics

Connect the iPhone to the Mac, open Console.app, select the iPhone, and enable
Info and Debug messages. Filter by subsystem
`com.interactivebuffoonery.awesomux.companion`, then reproduce the disconnect.
Capture the Mac side at the same time:

```sh
log stream --level debug --style compact --predicate 'subsystem == "com.interactivebuffoonery.awesomux" AND category BEGINSWITH "companion."'
```

Correlate `watch_request` and `watch_attach` using `attempt_id`, then use the
public `request_id` to find the Mac's connection mapping. `watch_end` preserves
the first initiating close cause; later cancellation callbacks cannot replace it.
Lifecycle events expose inactive scenes and lock state independently. An age of
`-1` means no frame or heartbeat has arrived. Byte counts contain no payload.
Terminal output, input, names, pairing material and credentials are never logged.
Native renderer and package terminal logging remain disabled.
