# iOS libghostty feasibility spike (issue #30)

Result: NO-GO for this candidate as a release dependency. Physical-device acceptance
is incomplete. Do not start M1 terminal UI on the strength of this experiment.

The isolated app lives in `spikes/ios-terminal-renderer`. It feeds terminal bytes
into a host-managed libghostty surface without a local process or network session.
It is an experiment, not the Companion terminal UI.

## Dependency decision

Candidate Swift package: https://github.com/Lakr233/libghostty-spm

Exact package revision under test: `42bacd1339f323a693ddbca779295f4f77e5a697`.
Underlying Ghostty revision: `1e9e14af5df14211892f5fc15fd21a49c7d94868`,
patch/build revision `3`. DisplayLink resolved to
`41bea2661e04bebcb1c4f15fc0b6197850100fdd`.

Its manifest pins the binary asset `upstream.1e9e14af5df1-3` with SHA-256
`0bf7e5e13f8e42ffca040a6cef7e985fc30bcaa81ff513bd2a93eb097398c6d8`.

The package adds host-managed I/O and iOS rendering/platform fixes to Ghostty.
The experiment uses that maintained distribution; it does not create a new fork.
A final dependency choice depends on the checks below and license verification.

Sarah owns dependency updates (confirmed in this session). Updates should review
the upstream revision, patch stack, wrapper changes, binary checksum, and notices,
then repeat the device checks before accepting a new pin.

## Acceptance record

No check is a pass until its evidence is recorded.

| Check | Simulator | Physical device |
| --- | --- | --- |
| Render ANSI and UTF-8 bytes supplied by host | Observed in retained screenshot | Observed in retained screenshot, iPhone 16 Plus |
| Terminal protocol response through output callback | PASS: exact `ESC[5;10R` response | PASS: exact `ESC[5;10R` response |
| Keyboard input through output callback | Pending | PASS: Sarah confirmed `abc`; callback chunks contain `61`, `62`, `63` |
| IME composition and committed text | Pending | Pending |
| Selection and copy | Pending | Selection handles and Copy menu confirmed by Sarah and screenshot; copied text pending |
| VoiceOver navigation and spoken terminal content | Pending | Pending |
| Release build/archive and bundled resources | Debug build passed | Signed Release archive, installation, and launch passed; release adoption blocked |

## Device availability

Apple's `devicectl` found a paired iPhone 16 Plus running iOS 27.0 with Developer
Mode enabled. T3 `device_list` listed simulators only; `device_open` rejected the
physical phone ID with `No device ... on host local`. Apple device tooling is the
fallback for installation and launch. Device interaction results remain separate
from build results.

## Source findings

The existing awesoMux upstream Ghostty pin `6301810a48aaa3426887a4316668f18833a40138`
has iOS platform/Metal code, but its termio backend supports only `exec`. It cannot
provide the required host-fed byte surface unchanged. `libghostty-vt` provides
terminal state for custom renderers, not the existing Metal terminal view.

The candidate package provides host-managed I/O, UIKit `UITextInput`, and selection
wrappers. However, its exact pinned [iOS rendering patch](https://github.com/Lakr233/libghostty-spm/blob/42bacd1339f323a693ddbca779295f4f77e5a697/Patches/ghostty/0005-ios-metal-rendering.sh#L97)
explicitly looks up and subclasses private `CAIOSurfaceLayer`. This is a release
blocker for selecting this pin, independent of build or rendering success.

Alternative source candidate: [madeye/ghostty at 7fb9e90363a431d15a67a22ff661e33c1be59060](https://github.com/madeye/ghostty/tree/7fb9e90363a431d15a67a22ff661e33c1be59060),
with passthrough I/O. It was not built in this experiment. Its example uses
`UIKeyInput`, so complete IME and VoiceOver support still need implementation and
device evidence. No alternative has passed the acceptance gate.

## License and packaging

The app bundles notices for Ghostty, libghostty-spm, DisplayLink, and
bash-preexec. Review identified embedded JetBrains Mono and Symbols Nerd Font
data; their exact upstream notice texts are bundled (JetBrains Mono OFL,
Symbols Nerd Font artifact MIT). The package source license guard
passed: `[+] no GPL license text; shell-integration holds only the MIT files`.
That source check does not audit the native archive. A complete native
dependency/embedded resource notice inventory remains a release gate.

The [native license audit](ios-terminal-native-license-audit.md) records the
Release artifact inventory and supporting notices. It confirms retained
Oniguruma, Highway, simdutf and Wuffs code missing from the current app notices.
Exact-source provenance, embedded font identity and some dependency retention
remain unresolved; the audit does not clear this release gate. Its supporting
notice files are evidence candidates, not a completed distribution notice set.

## Evidence handling and review

The app writes `latest-evidence.json` in its application-support directory.
Observations reset on launch. Copy that file to a separate platform-specific
artifact before each relaunch; do not combine simulator and phone results.
Retain the app commit, build configuration, device/OS, timestamp, callback bytes,
viewport text, and screenshots alongside each result.

Fresh focused source review checked callback lifetime and the test contract.
The reviewer found repeated viewport reads after the first cursor response;
implementation now guards the first transition. Cross-provider review initially
hit a rate limit, then resumed and completed. It confirmed callback lifetime and
pins, and requested deterministic cursor-response validation, matching
screenshot/JSON artifacts, and embedded font notices. Those fixes are implemented and simulator evidence was refreshed from one run.
The source manifest binds that run to the actual app inputs; its hash is
`64ea03080ece627aee30101600651ca0d5474ed593a1a691e2d8025de99b3755`.

The pinned UIKit wrapper has no identified terminal-content accessibility
implementation. The spike's fixed surface label is not terminal reading support.
VoiceOver remains unverified unless real device behavior supplies evidence.

## Build and phone receipt (2026-10-18)

Toolchain: Xcode 27.1 (`27A9275`), XcodeGen 2.46.0, iPhoneOS and Simulator SDK
27.1. Simulator runtime iOS 26.5; physical iPhone 16 Plus iOS 27.0.

A signed arm64 Release archive completed with `** ARCHIVE SUCCEEDED **`;
`codesign --verify --deep --strict` passed. The resource bundle
`GhosttyKit_GhosttyTerminal.bundle` and all six retained notice files are present.
`strings` on the Release executable also confirms `CAIOSurfaceLayer`, so the
private-API finding is not limited to the Debug simulator binary.

Initial phone installation failed with CoreDeviceError 3002 /
`IXRemoteErrorDomain 6: Connection invalid`. A single retry succeeded. Launch
failed with CoreDeviceError 10002 / FBSOpenApplicationErrorDomain 7:
`Locked: Unable to launch ... because the device was not, or could not be, unlocked`.
Sarah then unlocked the phone. The final Release build installed and launched
successfully, rendered the fixture, and returned exactly `ESC[5;10R`. Its
retained screenshot and JSON are in the spike's `evidence/physical-device*` files.
Keyboard/IME, selection, and VoiceOver remain pending hands-on observations.
Installing a signed archive is not an App Store acceptance check. Nothing was
uploaded to App Store Connect or TestFlight.

Local build logs and archives live under the spike's ignored `build/` directory.
The committed evidence includes sanitized receipts, simulator artifacts, and
physical rendering/selection screenshots and JSON.

## Remaining work before terminal UI

- Exercise native keyboard input, Japanese/Chinese marked-text composition,
  cancellation/replacement, touch selection/copy, and VoiceOver speech.
- Select or implement a public-API iOS rendering path; repeat the proof against
  its exact dependency pin. The alternative fork has not been validated.
- Finish the native library/font/resource notice inventory and release audit.

Issue #30 remains open. This experiment records feasibility evidence and
blockers; it does not meet the real-device acceptance gate.

The final simulator probe drains the fixture queue, explicitly moves the cursor
to row 5, column 10, then requests `CSI 6 n`. The retained callback is exactly
`1B 5B 35 3B 31 30 52` (`ESC[5;10R`). A two-second response deadline reports
failure if no matching callback arrives. Callback chunks are timestamped and
bounded to the latest 100 entries for later input/IME examination.

The final Release executable SHA-256 is
`5ae9a17f1158411b4f5ac9e50e61f6c6fa68a69c105c9fab6b82a9717c9b736b`.
`evidence/release-receipt.txt` records the exact archive command, signing check,
resource inspection, install/launch result, and the remaining release blockers.
The source manifest was verified against all tracked app inputs after building.

Sarah confirmed selection handles over terminal text and a Copy menu.
`evidence/physical-selection.png` shows `GhosttyTerm` selected with the native
Copy menu and keyboard. This proves selection affordances, not pasted clipboard
contents or IME behavior. The blinking terminal cursor is parked at 5;10 by the
probe and is independent of selection handles.

During the phone check Sarah found that the test view had no explicit keyboard
dismissal control. An always-visible navigation-bar Hide keyboard button now
resigns the UIKit responder. The simulator and signed Release archive were
rebuilt, reinstalled/relaunched, and their evidence refreshed after that change.
A fresh focused source review found no blocker in the dismissal action.
Hands-on dismissal confirmation remains pending.

## Follow-up keyboard confirmation

Sarah confirmed typing `abc` reached the output callback. The extracted
`evidence/physical-keyboard-evidence.json` contains timestamped `61`, `62`, and
`63` chunks from the same Release artifact and source manifest. Lack of visible
echo is expected: this app has no shell and deliberately does not loop callback
bytes back into the renderer.

The app's four manual observation controls were also set to passed. Those are
retained as tester-entered results. Specific IME composition/cancellation and
VoiceOver spoken-content observations were not described, so the detailed
acceptance gates above remain pending rather than inferred from the combined
controls. Clipboard contents and keyboard dismissal still lack a specific
recorded confirmation.
