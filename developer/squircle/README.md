# Personal Companion development

This is an opt-in personal **Debug** build for Sarah or Ed. It adds Squircle's
in-app coding overlay after archiving, then re-signs and exports locally. Normal
Companion generation, Release, App Store and TestFlight paths do not invoke it.
`ios/script/testflight.sh` is unchanged. Installation always needs a separate,
explicit decision on the selected phone. This integration has not yet passed
physical-phone acceptance; see [VALIDATION.md](VALIDATION.md).

## Architecture and authority

The upstream source is pinned to Squircle
`737f2e881483a4c7237b49d5696adff7d44cad1b`, under the included MIT license.
The adapter derives from Organized Glitter PR 98 at
`f8438e8dcfb3e92ee74c233a2e9019aa815382ed` (see `LICENSE-OG` for its Apache-2.0
license), including its Swift 6 fixes, protocol-2 client, V2-only SQL and
explicit Keychain enrollment. OG PR 98 advanced to `e8287a6` during grounding;
its adapter patch and enrollment source were unchanged. Companion started at
`76e944a78f7f1bb701aca50c8aaf1338a02a7d34`, ahead of the prior research revision.

The existing shared service selects OG through `SQUIRCLE_OVERLAY_PROJECT`.
**Do not change it.** This workflow builds a private framework and invokes the
pinned injector in an offline executable, with that variable set only for its
child process. It never starts, restarts, installs or configures a service,
agent, provider, network route or hook approval. Do not run `squircle agent setup`,
`service install`, `app import` or `app register` for this setup. Register is only
metadata; import would save a build recipe that defaults to Release. Neither
solves overlay selection. The supported recipe here explicitly archives Debug.
Do not submit Companion builds for shared-service injection: that would select
OG's adapter. Local IPAs are not automatically published in the service's Builds
list. Delivery hosting is a separate approved action.

The only permitted T3 mutation commands are `message.dispatch`, `run.interrupt`
with a known active run, and explicit `runtime-request.respond`, addressed to
the configured existing chat. Dispatch strips model and runtime-mode changes.
Attachment persistence occurs only after this boundary. No thread creation or
provider/mode switch is added. The project card opens that same chat even with
no imported Squircle app. These are client checks: the underlying T3 session
credential retains its full authority. Use only a session you trust with that
access. Messages do not authorize merges, releases, PR comments or deployments.

The client targets protocol 2 and the OG-tested T3 version
`0.1.8-nightly.20261104.4179`. A different T3 build requires a compatibility
check before enrollment, not a silent upgrade or provider override. Retained
upstream features include screenshots, attachments, activity, explicit questions
and approvals, cancellation, and cursor reconnection. They need runtime acceptance
with Companion; source fixtures do not prove these interactions.

## Each person's prerequisites

Use a Mac with Xcode supporting iOS 26, XcodeGen, Python 3, Rust/Cargo and Git.
The iPhone needs iOS 26+, Developer Mode for development installs, and explicit
coverage in both personal app/widget profiles. The Mac must remain awake with
T3 and its existing providers running. Use trusted, reachable HTTPS endpoints
for T3 and Squircle, including from the phone's network; a loopback URL on the
phone cannot reach the Mac. TLS verification stays on. Cellular access is a
separate checkpoint; do not expose a public service or change tailnet routes
implicitly. A paired Companion Mac connection is separate from this developer
session; no production pairing or entitlement expansion is required.

Sarah and Ed each need their own local config and enrollment. Ed must use his
own signing identity/account, device coverage and trusted session; nobody signs
as Ed on his behalf. If sharing Sarah's Apple team, a team operator must grant
Ed access and issue matching profiles that include Ed's phone. Merely receiving
an IPA or joining TestFlight does not grant signing or device coverage.

1. In this checkout, create the ignored directory `ios/.squircle` and copy
   `developer/squircle/config.example.json` to `ios/.squircle/config.json`.
   The five fields contain no credentials. Confirm the existing Companion T3
   project and this authorized development chat, or select an existing chat you
   own. Use the exact IDs from T3, not a newly invented provider or agent.
2. **Same team:** keep the example team, app ID and App Group only if authorized
   on that team. This installs under the existing app ID and may replace the
   installed Companion, retaining its data; get explicit approval first.
3. **Alternate team or side-by-side app:** choose your own reverse-DNS bundle
   ID, its `.widgets` extension ID, and an App Group under `group.<bundle_id>`.
   Register both IDs and that group in your Apple developer account. Enable the
   same App Group for both IDs. Create matching development profiles (or ad-hoc
   profiles for `release-testing`) covering the intended phone and certificate.
   A new bundle namespace has independent pairing, Keychain and app data.
   The generator updates both targets and their runtime group together through
   `AwesoMuxAppGroup` in both plists. The default group stays unchanged for normal
   builds. Background-task IDs and the existing pairing URL scheme stay aligned
   with the unchanged runtime. With both apps installed, paste the pairing link
   inside the intended app; system-wide `awesomuxcompanion://` routing can select
   either app. Do not override `PRODUCT_BUNDLE_IDENTIFIER` globally in Xcode: it
   would give app and widget the same ID.
4. Keep profiles, export options and connection JSON outside Git, under the
   ignored directory or another private directory. `chmod 700 ios/.squircle`
   and `chmod 600` private files. Never commit tokens, endpoints, device IDs,
   APNs material, signing keys or profiles. Profile files are ignored already.

## Prepare and check

Choose a fresh absolute destination; preparation refuses an existing path.
It clones the pin, applies `integration.patch`, renders the validated namespace
and chat IDs, and adds the offline injector. It never edits upstream or OG.

```sh
python3 developer/squircle/prepare.py /absolute/new/companion-squircle \
  --config ios/.squircle/config.json
process-gate zsh developer/squircle/verify.sh /absolute/new/companion-squircle
```

On Midnight Pro/Pinguchy, use process-gate from a clean committed tree for all
builds/tests. On other Macs use the same command without `process-gate` if it is
not installed. Do not bypass a busy gate or use someone else's device session.

First source-build and integrate the pinned public renderer by following
`spikes/ios-terminal-renderer/native/README.md` and
`spikes/snapshot-reconnect/ios-diagnostics.md`. Keep its original receipt and
inputs available. The personal generator runs `generate-watch.sh`, then writes
an ignored `ios/project.squircle.local.yml` and regenerates the existing project.
It retains `watch-manifest.py` and dependency-lock validation on every app build.
It does not substitute a downloaded renderer or fabricate a receipt.

To inspect the personal project in Xcode without archiving:

```sh
process-gate python3 developer/squircle/personal.py generate \
  --config ios/.squircle/config.json
```

## Archive, inject, sign and export

Use profiles already installed through your own Xcode account. In a private
export-options plist, set `method` to `debugging` (older Xcode: `development`),
`teamID` to your configured team, `signingStyle` to `manual`, `signingCertificate`
to the uppercase 40-hex certificate SHA-1 fingerprint, `destination` to `export`,
and `provisioningProfiles` to a dictionary mapping the exact app and widget IDs
to their respective profile UUIDs. For ad-hoc profiles use `release-testing`
(older Xcode: `ad-hoc`). The archive configuration is still **Debug**. No App
Store, enterprise or upload method is accepted. Do not use TestFlight scripts.

```sh
process-gate python3 developer/squircle/personal.py export \
  --config ios/.squircle/config.json \
  --prepared /absolute/new/companion-squircle \
  --export-options ios/.squircle/export-options.plist \
  --app-profile ios/.squircle/app.mobileprovision \
  --widget-profile ios/.squircle/widgets.mobileprovision \
  --output /absolute/new/personal-export
```

This checks exact profile IDs, team, expiry, explicit device coverage, App Group,
certificate and export method before building. It archives Debug into a new
output directory, verifies app/widget signatures and group configuration, builds
its own overlay, injects with Squircle's pinned Mach-O injector, and requires
unchanged host/widget entitlements. It exports and verifies both signatures and
the framework's presence again, then writes a build ID and IPA SHA-256 receipt.
No IPA is uploaded or installed. Match the intended device to **both** profiles
privately before approving installation; the helper checks coverage exists but
does not choose a phone. Profile prefixes may differ from Team IDs.

Do not share a build made with embedded credentials. This adapter never loads
`client.json` resources; enrollment is imported on each phone. Still inspect
artifacts before sharing, and do not share private logs or intermediate archives.

Inspect a separately built normal Release app before distribution:

```sh
python3 developer/squircle/check-release.py /absolute/normal/Release.app \
  --config ios/.squircle/config.json
```

This inspects the artifact only. A signature check and a signed archive/export
remain separate evidence from an unsigned SDK build.

## Enroll, connect and renew on each phone

After explicit phone/install approval, manually install the verified personal
IPA with Xcode/Apple Configurator, or use an approved HTTPS manifest/IPA delivery
route with manual iOS confirmation. No delivery route is configured here. A
successful archive, download, or install link does not prove installation.
Manually launch and match the build receipt separately. No silent self-update.

Create a private JSON file through your existing authorized session-enrollment
process, containing only the upstream fields `t3_url`, `t3_token`,
`squircle_url`, `squircle_token`, `diagnostic_token`. URLs must be HTTPS. The
last credential is used for a launch receipt only. Obtain secrets through a
private secret-input card when working with an agent, never chat. Do not copy
OG's credentials or read its service config wholesale. Transfer the file through
a private method you trust to your own phone, then:

1. Open the personal app; choose **Import connection file** in Developer tools.
2. Import your file and choose **Connect** explicitly. The app stores it in its
   private, when-unlocked, this-device-only Keychain item. No shared Keychain
   group is added; Companion pairing credentials are separate.
3. Send a harmless request to the configured chat and check the exact destination
   in T3. Exercise screenshots only with nonprivate content. Check question
   answers, explicit approval denial/acceptance, known-run Stop, background,
   network interruption and reconnect. Never replay an uncertain mutation blindly.
4. Use **Developer connection** in the conversation menu to disconnect and import
   fresh enrollment after expiry or revocation. **Forget connection** removes
   this phone's developer enrollment; revoke the session on the Mac separately.
   **Continue without developer tools** leaves a Developer tools launcher.
5. Delete the transferred enrollment file from Files and its transfer location
   after import. Forget does not erase copies of that file or revoke its tokens.

The service HTTP boundary permits reads and explicit build install-link creation,
plus launch diagnostics under its separate token. Build creation, agent restarts
and service-mediated approvals stay disabled. In-app requests for a new build
reach the existing chat; an authorized operator runs this local helper and
prepares a separately approved delivery action.

## Troubleshooting and rollback

- Missing renderer/receipt or dependency-lock drift: stop and restore/rebuild the
  original pinned inputs using the renderer guide. Never weaken validation.
- Swift/T3 compatibility failure: keep the existing service running; collect a
  privacy-safe local error and check the pin. Do not reinstall/update T3.
- Profile/signature failure: check exact app and `.widgets` IDs, team, App Group,
  certificate/private key, expiry and device coverage. No automatic account or
  profile changes are attempted. Ed handles his identity on his Mac.
- No developer UI: verify the personal Debug IPA contains
  `SquircleOverlay.framework`, its Mach-O load command and your configured bundle
  guard. A normal Release/TestFlight build intentionally has no overlay.
- Unauthorized/expired connection: import fresh own enrollment. HTTPS failure:
  check trust and phone reachability without disabling TLS or exposing services.
- To restore normal generation, run `zsh ios/script/generate-watch.sh` through
  process-gate and build normally. It overwrites the ignored personal project
  and generated plists/entitlements. Never archive TestFlight from a personal
  generated project; the TestFlight path regenerates its own normal project.
- On the phone, Forget the developer connection and revoke its session on the
  Mac. A separately approved normal build removes the injected overlay. Deleting
  an app may leave Keychain items; do not rely on deletion as revocation. A Git
  revert cannot undo sent messages/answers or change an installed phone.

## Approval boundary

No shared-service change is needed for local archive/export. Using the shared
service for Companion injection would require a reviewed per-app adapter
selection change and a restart; that affects OG's running build delivery. Before
any such change, prepare the exact new selector, affected build recipes, queued
build impact, rollback to OG's existing selector and restart window for Sarah's
approval. Do not change service configuration as a setup shortcut.

Public push/PR, delivery publication, phone selection/installation, and any
service/network changes remain separate explicit approvals. No merge, release,
TestFlight upload, PR comments or release approvals are included.
