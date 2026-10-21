# awesoMux Companion for iPhone

A read-only companion for awesoMux. It shows which agents (Claude Code, Codex,
OpenCode, Pi, Grok) need you, are working, or are done, in four places: the app,
a Home Screen and Lock Screen widget, a Live Activity (Lock Screen and Dynamic
Island), and notifications. You answer agents at your Mac; the phone only looks.

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

```sh
cd ios
xcodegen generate
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
  "Offline";
- once nothing needs you or is working, it ends and keeps the final card for 5
  minutes;
- it ends immediately on a host change, on disconnect, or after 30 minutes
  offline.

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

## Snapshot diagnostic app

The separate `AwesoMuxDiagnostics.xcodeproj` / `AwesoMuxDiagnostics` scheme uses
the source-built public CAMetalLayer renderer for bundled replay and
an isolated synthetic Mac-to-phone reconnect fixture, without pairing. See the
[build and usage guide](../spikes/snapshot-reconnect/ios-diagnostics.md) and
[verification ledger](../spikes/snapshot-reconnect/verification.md).

## Agent and terminal protection

Protection is on by default. The paired agent content requires Face ID, Touch ID,
or the device passcode on each launch. Settings → Privacy controls the persisted
preference; turning it off also requires authentication, including from the locked
screen. Pairing stays available without unlocking. Authentication failure or
cancellation leaves the gate closed. Devices without a passcode stay locked and
show instructions to set a passcode in iOS Settings. Enabling protection locks immediately.

The grace clock advances during device sleep. Background returns under 15 seconds keep an already unlocked session; returns at
15 seconds or later lock again. Every inactive scene gets an opaque
privacy window above app navigation and sheets, even with protection disabled.
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
and terminal/agent status. Unknown pane kinds remain metadata-only. Watching a
live terminal and an iPad-specific layout are separate follow-ups (#10 and #11).
The Agents tab, notification focus, cached agents, widgets and Live Activity keep
their existing roles.

Only active foreground polling requests `list_panes`; background refresh still
reads agents and attention events. These reads use the same paired mutual TLS
client and direct LAN/Tailscale routes. Pane failures have their own display state
and do not mark a successful agent refresh offline. An authorization denial
clears pane content and marks existing agent/widget metadata offline, preserving
the cache. The next valid poll can recover: a changed Mac lease or a temporary
Keychain failure can also cause a denial. Transport failures clear the pane list; they cannot establish whether a
phone was revoked or its Mac is offline.

Terminal previews are off unless the Mac explicitly reports permission. Sessions
and Settings offer a per-phone consent switch; enabling explains that terminal
text may contain secrets. Changes use `set_terminal_preview`, verify its receipt,
and read `get_connection_status` again before showing previews. An unsuccessful
change clears prior preview text. Local suppression survives read errors and
background returns until an explicitly confirmed enable or pairing replacement.
Permission writes retain one owner across scene transitions; newer choices wait
for the previous write to settle before sending, and only the latest queued
choice can send. While a write is unresolved, polling cannot release ownership. Permission and pairing epochs reject late
responses, including stale authorization errors. Returning to foreground reads
permission again for both v1 and v2 pairings. Older Macs keep the Agents tab and
show an update message for unsupported pane lists.

Pane rosters and previews stay in process memory, outside `GlanceSnapshot`, the
cached agent snapshot and App Group/widget storage. Backgrounding clears them
and invalidates unfinished reads. All Sessions and consent UI lives beneath
`TerminalLockContainer` and its scene privacy cover. This feature adds no live
terminal renderer, relay access, document content, saved previews or widget
previews. Simulator fixture screenshots demonstrate SwiftUI rendering; actual
paired networking, physical biometric/passcode flows and VoiceOver need separate
verification. Accessibility polish remains deferred.
