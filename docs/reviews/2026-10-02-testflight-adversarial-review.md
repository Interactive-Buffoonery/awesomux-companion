# TestFlight distribution preparation review

Claude Code; actual claude-opus-5-5. Read-only isolated context; source scope testflight-scope.json.

# Verdict: PASS, with three gates to clear before upload

The claims are scoped honestly, and the Keychain claim is correct. I found nothing misleading enough to block. These items must be resolved or confirmed before the upload or App Store Connect step. None of them invalidates the prepared artifact.

## Keychain default group: correct

Apple's `kSecAttrAccessGroup` documentation sets the default access group in this order:

1. The first `keychain-access-groups` entry.
2. Otherwise, `application-identifier`.
3. Otherwise, app groups.

The audit shows `explicit_keychain_groups_present: false` and a matching `application-identifier`. The default is therefore `TEAMID.com.interactivebuffoonery.awesomux.companion`, which is isolated to this app. The claim holds only if the Swift code never passes `kSecAttrAccessGroup` explicitly. The prior source review should already cover that, so it's worth one line in the handoff. "On-device behavior remains untested" is the right caveat. The tests ran with `CODE_SIGNING_ALLOWED: NO` on the simulator, so they did not exercise the signed entitlement.

## Gates before upload

**1. The icon is not shown to be in the IPA.**
- Archive success does not prove the `.icon` package compiled.
- If XcodeGen treated `AppIcon.icon` as a plain folder instead of `folder.iconcomposer.icon`, two things happen:
  - `icon.json` and the PNG get copied as loose resources.
  - No icon is compiled, and upload validation then rejects the build for a missing icon.
- Neither the handoff nor the audit JSON records an icon check.
- Verify before upload:
  - The generated `project.pbxproj` lists `lastKnownFileType = folder.iconcomposer.icon`.
  - The IPA's `Info.plist` has `CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconName = AppIcon`.
  - `Assets.car` contains AppIcon renditions.
  - `Assets/awesoMux Logo Smoothest.png` exists inside the package. Only `icon.json` was supplied for review.
- This requires Xcode 26+ actool. With an iOS 18 deployment target, it also needs the generated fallback images.

**2. The export-compliance declaration is the account holder's decision.**
- "Resolve … from the actual app's OS-only HTTPS use" reads as a determination already made.
- It is a legal attestation and should be put to eD! explicitly. It should not be answered by the agent.
- Confirm the bridge or pairing transport really is OS-provided crypto only (URLSession/Network.framework TLS, CryptoKit). Any custom or bundled crypto changes the answer.

**3. Confirm the permanent App Store Connect identifiers.**
- The authorization covers "app creation," but the SKU can't be changed later.
- The bundle ID is locked to the record once a build is uploaded.
- The app name is reserved and shows in TestFlight.
- eD! should confirm `awesoMux Companion` / `awesomux-companion-ios` / `en-US` before the record is created.

## Accuracy notes (non-blocking)

- **Signing reproducibility.** `project.yml` sets `CODE_SIGNING_ALLOWED: NO` and has no `DEVELOPMENT_TEAM` or `CODE_SIGN_STYLE`. The signed archive therefore depended on command-line overrides that aren't recorded. Add the exact archive and export invocation, including `exportOptions` and the method, to the handoff. The post-export signature verification makes the artifact trustworthy, but the build can't be reproduced from the repo as written.
- **"The saved API credential cannot currently see the new bundle."** This is fine if it came from a read-back that showed the bundle absent. If it was inferred from the 403, say "was not visible at time of check," because API visibility can lag.
- **Artifact location.** The artifact sits in `/private/tmp`, which is cleared on reboot. The SHA-256 is recorded, so a rebuild can be detected, but the build would have to be rebuilt.
- **Title.** "TestFlight delivery" overstates the current state. "TestFlight preparation" would match the Current outcome section.
- **iPad.** `TARGETED_DEVICE_FAMILY: '1,2'` is set with no explicit orientation keys. Run Xcode's Validate App (or `altool --validate-app`) before uploading. It catches orientation or multitasking rejections without publishing anything. This is outside this slice's change, but it is a TestFlight upload risk.

## Workflow and publishing boundaries: sound

- The scope exclusions are explicit and correct: no external testers, public link, other-person invites, APNs, or network exposure.
- An internal group with only eD!, verified before claiming availability, is the right gate. Internal testing doesn't need Beta App Review.
- Stopping on a name conflict or account-terms prompt is correct.
- `ASC_WEB_DONT_STORE_PASSWORD=1 asc web auth login`, run by the user locally, keeps secrets out of chat. Note two caveats in the handoff:
  - It uses Apple's unofficial web-session endpoints, not the official API, and the official API cannot create app records.
  - The session cookie still persists locally. Log out afterwards if that matters.
- The build number is `1`. A retry after a partial upload needs build `2`.