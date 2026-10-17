# awesoMux Companion for iPhone

A read-only companion for awesoMux. It shows which agents (Claude Code, Codex,
OpenCode, Pi, Grok) need you, are working, or are done, in four places: the app,
a Home Screen and Lock Screen widget, a Live Activity (Lock Screen and Dynamic
Island), and notifications. You answer agents at your Mac; the phone only looks.

SwiftUI, Swift 6, iOS 18+, iPhone and iPad. The data source is
`GET /v1/glance`, decoded exactly as described in [`CONTRACT.md`](../CONTRACT.md).

## Layout

| Path | What it holds |
|------|---------------|
| `AwesoMuxCompanion/` | App target: polling store, hardened HTTPS client, Keychain pairing, agent list, Live Activity lifecycle, notification handling |
| `AwesoMuxCompanionWidgets/` | Widget extension: the `Agents` widget (small, medium, accessory rectangular and circular) and the Live Activity UI |
| `Shared/` | Compiled into both targets: snapshot model and decoder, App Group storage, `GlanceActivityAttributes`, shared views |

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

## Run against a local relay

DEBUG Simulator builds read a development configuration when no host is paired.
Copy the relay's `client.json` into the app data container, mode 0600, and
relaunch:

```sh
SIM=<simulator UDID from xcrun simctl list devices booted>
APP=$(xcrun simctl get_app_container "$SIM" com.interactivebuffoonery.awesomux.companion data)
mkdir -p "$APP/Library/Application Support"
install -m 600 client.json "$APP/Library/Application Support/development-client.json"
xcrun simctl terminate "$SIM" com.interactivebuffoonery.awesomux.companion
xcrun simctl launch "$SIM" com.interactivebuffoonery.awesomux.companion
```

Development URLs must be `http://127.0.0.1:<port>` with a 32 to 128 character
printable token. Release builds ignore this path and use Keychain pairing over
private HTTPS (port 8443 or 10000).

While the app is in the foreground it polls every 5 seconds; pull to refresh
fetches immediately.

## Notifications and Live Activity

The app asks for notification permission the first time it connects and shows
banners in the foreground as well. Tapping a notification opens the app and
highlights the pane named by `paneID`. Send a contract-shaped push with:

```sh
xcrun simctl push "$SIM" com.interactivebuffoonery.awesomux.companion payload.json
```

A push with `content-available` asks the app to fetch once and refresh the
snapshot, widget, and Live Activity. On the iOS 26 Simulator `simctl push` shows
the banner but does not wake a suspended app, so that refresh only happens on a
device with real APNs. Phase 2 also needs the `aps-environment` entitlement and
a device-token upload, neither of which exists yet.

The Live Activity starts while the app is in the foreground, connected, and at
least one agent needs you or is working. It then follows each refresh:

- updates when counts or the top item change, plus a 60 second heartbeat;
- content goes stale 15 minutes after the last update, and the card then shows
  "Offline";
- once nothing needs you or is working, it ends and keeps the final card for 5
  minutes;
- it ends immediately on a host change, on disconnect, or after 30 minutes
  offline.
