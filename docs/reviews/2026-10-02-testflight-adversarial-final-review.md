# TestFlight preparation affected-scope refresh

Claude Code actual claude-opus-5-5; read-only isolated context, hooks/tools/MCP disabled. Scope testflight-final-scope.json.

# Verdict: PASS

The prepared-artifact blocker is cleared. The additions close all three earlier gates as they apply to the artifact. The remaining open items are upload-time or account-holder steps, and the handoff already labels them that way. Nothing below blocks proceeding to the user-only login.

## Prior gates, re-checked

**Icon (was gate 1): closed.**
- The audit records `compiled_icon_renditions: 20`.
- `CFBundleIconName` is `AppIcon` for both iPhone and iPad.
- `legacy_icon_fallback_present: true` covers the iOS 18 deployment target.
- The source files are byte-identical to the Mac project.
- Compiled `Assets.car` and Info.plist output is stronger evidence than the `lastKnownFileType` spelling I asked for. Accepting actool output in its place is correct.

**iPad orientations (was non-blocking): closed for the artifact.**
- `project.yml` sets all four orientations through `INFOPLIST_KEY_UISupportedInterfaceOrientations`, which applies to both device families.
- The audit's `supported_orientations` matches.
- The generated launch screen is present.
- Together these satisfy iPad multitasking requirements without `UIRequiresFullScreen`.
- Server-side validation is still pending, and the doc says so explicitly.

**Export compliance (was gate 2): closed.**
- The doc states the attestation is user-only and must not be submitted on eD!'s behalf.
- The doc requires confirming URLSession and platform TLS, with no bundled crypto, before presenting Apple's questions.
- `ITSAppUsesNonExemptEncryption` is correctly absent from the Info.plist. Adding it would itself be an attestation.

**Name/SKU/locale (was gate 3):** Treated as routine within the existing app-creation authorization. It is not re-raised here, as instructed.

## Artifact integrity: consistent

- The SHA-256 `968975d9…613745` matches between the handoff and the final audit.
- The audit's absolute `artifact_path` resolves to the handoff's `ios/build/testflight/AwesoMuxCompanion-0.1-1.ipa`. The hash was taken at the persistent location, not the `/private/tmp` export path, so the copy is verified.
- These values agree across `project.yml`, the handoff and the audit:
  - bundle ID
  - version `0.1`
  - build `1`
- Signing flags match the TestFlight requirements:
  - `get_task_allow: false`
  - `beta_reports_active: true`
  - Distribution authority present
  - No device list
  - No push entitlement
  - No development strings
- The archive and export commands are now recorded. `DEVELOPMENT_TEAM=VERIFIED_TEAM_ID` is a placeholder, and `method=app-store-connect` is stated. This resolves the reproducibility note.
- The login command uses the `YOUR_APPLE_ACCOUNT_EMAIL` placeholder, so no account identifier appears in the doc.

## Findings (non-blocking)

1. **File permissions are asserted, not audited.** "Private permissions" is written as an instruction in the handoff. The audit JSON doesn't record the IPA's file mode. Add the mode (for example `0600`) to the audit if you want it to be evidence. Also confirm `ios/build/` is gitignored so the IPA can't be committed.
2. **Export-compliance wording is inconsistent.** The next-steps paragraph says "resolve Apple's export-compliance declaration from the actual app's OS-only HTTPS use." That still reads like the agent makes the determination. The later paragraph correctly makes it user-only. Changing the first sentence to "present Apple's export-compliance questions to eD! for attestation" removes the contradiction.
3. **The Keychain claim lacks its source-check line.** The default-group claim holds only if no Swift call passes `kSecAttrAccessGroup` explicitly. No Swift changed in this slice, so prior source review covers it. The handoff still doesn't state that check, so one line would make the claim self-contained.
4. **The retry guidance is better than my earlier advice.** "Check Apple's state before any retry" is more accurate than my earlier "retry needs build 2." No change is needed.