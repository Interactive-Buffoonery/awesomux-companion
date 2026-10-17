# TestFlight preparation — 2026-10-02

eD! authorized app creation and TestFlight distribution instead of tethered installation. No App Store release, public beta link, tester invitation to another person, APNs configuration, or private-network exposure is authorized by this distribution step.

## Prepared artifact

- Bundle: `com.interactivebuffoonery.awesomux.companion`; team: Interactive Buffoonery.
- Version/build: `0.1 (1)`; iPhone/iPad; iOS 18+.
- Final IPA: `ios/build/testflight/AwesoMuxCompanion-0.1-1.ipa`; signed archive: `/private/tmp/amx-testflight-preparation/AwesoMuxCompanion-final.xcarchive`.
- IPA SHA-256: `968975d99cd40e99589c88b56f04e5a2f103682e9fb46777a611a63402613745`.
- Xcode automatic archive/provisioning and App Store Connect export succeeded. Exported signature verifies; Apple Distribution identity; exact team and application identifier; `get-task-allow=false`, `beta-reports-active=true`; profile has no device list.
- Keychain uses the signed application identifier as its default isolated group; no shared-group entitlement is required. Apple reference: https://developer.apple.com/documentation/security/ksecattraccessgroup . On-device Keychain behavior remains untested.
- Existing awesoMux Icon Composer package copied unchanged from the Mac project; `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`. No Swift or bridge behavior changed for distribution. Prior 26 iOS / 34 bridge tests remain prior evidence; this slice ran archive/export/signature validation.
- Release binary has no development-client filename. No APNs entitlement; locked-device notifications remain unfinished. Foreground access requires later host pairing and an authorized private route.

## Access blocker and next steps

The saved upload API credential reads apps but its bundle registration request was denied by Apple. Xcode's existing signed-in account successfully provisioned the exact app. The saved API credential cannot currently see the new bundle; do not assume it can upload this app until read-back confirms access.

No App Store Connect app record exists through the available API view. `asc web auth status` reports unauthenticated. Computer-use inventory failed with native pipe startup error, so no browser UI was available to complete the account step.

User-only secure local login (password and verification code stay out of chat):

```sh
ASC_WEB_DONT_STORE_PASSWORD=1 asc web auth login --apple-id YOUR_APPLE_ACCOUNT_EMAIL
```

Choose Interactive Buffoonery if Apple offers multiple providers. Once authenticated, the authorized next action is to create or verify the iOS record with name `awesoMux Companion`, bundle above, primary locale `en-US`, SKU `awesomux-companion-ios`, initial version `0.1`. Avoid changing another existing app or silently selecting a renamed app.

Replace the email placeholder locally. The CLI uses Apple's web-session endpoints and retains a local session cookie, even with password storage disabled. `asc web auth logout` ends that session after delivery.

Then verify the record's exact bundle/team, upload the prepared IPA with a credential that can access it (or Xcode's account), present Apple's export-compliance questions to eD! for attestation, wait for processing `VALID`, configure an internal group for eD! alone and verify tester access before claiming TestFlight availability. No external invitation is sent without authorization. If a name conflict or account terms block creation, stop at the specific user-only decision.

Apple's export-compliance attestation is a user-only step; do not submit it on eD!'s behalf. Confirm the actual code uses URLSession platform TLS and no bundled/custom cryptography before presenting Apple's questions. App-record name/SKU/locale are routine implementation choices within app-creation authorization; review's suggested extra confirmation is not a new approval gate. SKU is permanent. No name conflict is silently resolved.

## Review follow-through and reproducibility

Actual Claude Code `claude-opus-5-5` bounded review: `reviews/2026-10-02-testflight-adversarial-review.md`. Icon compiled with 20 AppIcon renditions, iPhone/iPad Info.plist AppIcon names and legacy fallback PNG. XcodeGen's file-type spelling differs from the suggested spelling, but actual actool output and compiled assets establish correctness. Copied icon files match the Mac source byte-for-byte.

The final build adds explicit portrait, upside-down portrait, landscape left and landscape right orientations for iPad distribution validation. Run Apple's upload validation before claiming availability; no server-side validation has occurred yet. API absence is only visibility at the time of read-back, not proof of a missing Developer Portal registration: exact distribution profile establishes successful Xcode provisioning.

Archive invocation (team identifier read privately from the verified installed profiles):

```sh
xcodebuild -project ios/AwesoMuxCompanion.xcodeproj -scheme AwesoMuxCompanion -configuration Release -destination 'generic/platform=iOS' -archivePath /private/tmp/amx-testflight-preparation/AwesoMuxCompanion-final.xcarchive -derivedDataPath /private/tmp/amx-testflight-preparation/DerivedData -allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=VERIFIED_TEAM_ID archive
asc xcode export --archive-path /private/tmp/amx-testflight-preparation/AwesoMuxCompanion-final.xcarchive --ipa-path /private/tmp/amx-testflight-preparation/AwesoMuxCompanion-final.ipa --xcodebuild-flag=-allowProvisioningUpdates --timeout 5m
```

Generated export options use `method=app-store-connect`, automatic signing. Preserve final IPA under `ios/build/testflight` with private permissions, not solely in temporary storage. Check the final signing audit for its actual hash. No build number increase is required before the first upload; a partial committed upload requires checking Apple's state before any retry.

## Current outcome

Distribution artifact prepared. No upload, Apple processing, TestFlight group, invitation or physical installation has occurred. No CI launched and no live agent inference performed for this slice.


## Apple upload outcome — 2026-10-02

App record6818681453 created using user-completed web login, exact companion bundle/name/SKU/locale. Saved API credential now reads new app. Final reviewed IPA uploaded and committed; uploadCOMPLETE, build83a3789e-6be5-41d7-8521-6f2243273ddc processedVALID. Internal Personal Testing group5519e238-50c8-4768-9763-1bf9df16983f contains exactlyone verified eD! tester. Reusing older app tester failed; canonical testercreate succeeded with new app-specificrecord. No unrelated testers invited. InternalbuildstateMISSING_EXPORT_COMPLIANCE; build-group assignment denied422because not internallytestable. User-only ManageCompliance requested via exactAppStoreConnectlink. No attestation submitted, no beta-reviewsubmission, no installationclaimed. Resume assignment and verify IN_BETA_TESTING/testeraccess after userdeclaration. Machine-readable actualstate in reviews/2026-10-02-testflight-upload-state.json. No source/settings/artifact changes; previous artifactreview retained for unchanged contribution.


### TestFlight enabled — verified final state

eD! completed ManageCompliance locally. Exact validated build assigned to PersonalTesting internalgroup; Apple readback IN_BETA_TESTING, autoNotifyEnabledtrue, exactsoleeD! tester INVITED. Invitation/installation access enabled, actualphoneinstall notobserved. No publiclink/externalbeta/AppStore release. Optional Whattotest notes failedAPIpermission; no notespublished and no claimtheywere. No appsource changes. Foreground pairing/privateServe/APNs/sessioncreation remain unfinished, separately scoped. State receipt updated in reviews/2026-10-02-testflight-upload-state.json.
