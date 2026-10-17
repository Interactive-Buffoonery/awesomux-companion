# Native reply evidence refresh review

2026-10-02. Independent reviewer: Codex collaboration agent, explicit model `gpt-6-astra`. Evidence-correction and focused UI-lifecycle follow-up to `2026-10-02-native-implementation-review.md`. Read-only source review; only this separate report was written. No live inference, notifications, Simulator interaction, or runtime launch.

Outcome: **no findings in this refreshed scope**. The correction prevents the initial user prompt from counting as a completed assistant answer. It does not retroactively validate historical `ui_answer_observed` booleans or prove lifecycle behavior.

## Reviewed change and validation

`bridge/launch_probe.py` uses one helper accepting only a projected message whose role is exactly `assistant` and whose text is exactly `Bridge received ALPHA` or `Bridge received BETA`. Both the interactive observation and smoke completion predicate use it. `BridgeState` projects assistant text from completed items/hydrated history, so user prompt text and streaming deltas cannot satisfy the predicate. This is a session-wide observation that a known completed reply exists, not proof of the winning client or a particular later turn. That scope is appropriate for the interactive metric and first smoke completion in a freshly created thread.

Read the focused regression test. Independently ran all 17 bridge tests successfully. Also exercised 12 direct cases covering exact ALPHA/BETA for both roles, prefixed/suffixed assistant text, unrelated text, empty messages, and an empty dictionary; all passed. No live rerun was performed or is claimed.

Impact: only evidence interpretation and its deterministic check changed in the launcher. Launch authorization, effective notification readback, authentication, turn requests, runtime bounds and cleanup are unaffected. Compared the previous report's hashes against current source: the native app source and unit-test files were unchanged. The subsequent UI-test target/project additions are separately reviewed below. The ledger and live-evidence paths/content changed as documented below. Native state/transport/UI review is retained on unchanged bytes; this refresh does not substitute for a separate publication gate.

## Historical evidence correction

The original implementation report hashed `docs/reviews/2026-10-02-native-live-result.json` as `292f7590567ee9ffc363cd5cb32e0b18f2c30d0f034dc261ff7c7acc2014a586`. Those exact bytes now live at `docs/reviews/2026-10-02-native-reply-live-result.json`; independently verified the SHA-256 match. The old report/hash remain historical evidence, unchanged. This report records the rename rather than assigning the old hash to later trial output.

Both historical trials predate the metric fix. Their `ui_answer_observed: true` values are invalid as standalone reply evidence because the user prompt contained the expected strings. The earlier implementation report's statement that its result showed an answer must be read with this correction. For the first trial, the parent separately observed actual UI assistant text `Codex` / `Bridge received ALPHA`; the preserved result also records one resolved operation. The UI observation is attributed to the parent and was not repeated by this reviewer. The result's quiet-launch and cleanup fields remain valid independent evidence.

The later trial was initially at `native-live-result.json` when this refresh began and was renamed during the review to `docs/reviews/2026-10-02-native-devicehub-trial-result.json`. Verified that its bytes remain SHA-256 `a834f18e01b865e40bdca1eba3dc8c4981e8eb9c8136339a2f9f0bf6dd17f78b` across that rename. It records zero resolved operations. Its invalid reply boolean is not counted as reply proof; the trial is not counted as successful same-process background/foreground validation.

As documented in the ledger, Home did not visibly leave the app, relaunch changed PID, and computer-use binding timed out. Parent-observed restart/refetch and host-disconnect behavior do not close that gap. Actual same-process background/foreground remains unverified by this trial; deterministic inactive/late-fetch unit checks are separate evidence. Later-trial cleanup fields show amx absent, server exit zero, endpoint closed, private root absent, and no cleanup errors; the parent additionally reports removing injected Simulator capability data.

## Subsequent actual lifecycle test and project refresh

After the failed Device Hub trial was preserved, the parent added a separate UI integration test and ran it against a new disposable managed runtime. Reviewed `ios/AwesoMuxCompanionUITests/ForegroundLifecycleTests.swift`, the updated XcodeGen spec, generated project UI-target wiring/build settings, and shared scheme. The test launches the app, navigates to a real pending ALPHA question, verifies its enabled state, sends XCUIDevice Home, asserts `.runningBackground`, uses `app.activate()`, asserts `.runningForeground`, and verifies the question is still present/enabled with no completed ALPHA reply. It does not submit an answer. The integration test explicitly skips when no configured session exists; this exercised run did not skip. Project changes add only the separate UI test target and scheme entry, with the existing unsigned/local build constraints retained. Reviewed setup/status documentation in root README, ios/README, and the updated execution ledger.

Independently read the result bundle using both `xcrun xcresulttool get test-results summary` and `... tests`. Bundle:

`/Users/edequalsawesome/Library/Developer/XcodeBuildMCP/workspaces/awesomux-ios-7eed4cb13b56/result-bundles/test_sim_2026-10-02T22-09-21-994Z_pid31315_ab38a908.xcresult`

Observed result: **1 passed, 0 failed, 0 skipped**, specifically `ForegroundLifecycleTests/testManagedQuestionSurvivesBackgroundAndResume()`, iPhone 17 Pro Simulator iOS 26.5. This closes the actual foreground/background journey gap left by the Device Hub trial. Immediate disabling during inactivity and rejection of late fetches remain unit-test evidence, not a background UI assertion. This reviewer read the executed result and source rather than rerunning the live test.

The current `docs/reviews/2026-10-02-native-live-result.json` is now a **third distinct trial**, recorded using the corrected reply metric. It has `ui_answer_observed: false`, zero resolved operations, and successful quiet-launch/cleanup fields. Those values are expected for a lifecycle-only trial; they are not reply evidence. Parent reports Xcode migrated the data container and that cleanup re-read the current container before removing its capability file. This is attributed cleanup evidence, not independently repeated device inspection.

Retained reviews: app source, models, network client and unit tests remain at the earlier reviewed hashes. Refreshed lanes: evidence correctness, UI lifecycle test behavior, test-target wiring, and setup/status documentation. No new production behavior, notification capability, paid CI or device-support claim is introduced. Local loopback success is measured on iOS 26.5; docs correctly leave minimum-version networking compatibility unverified.

## Exact refresh scope hashes

SHA-256. Current bytes bind this refresh; historical hashes remain recorded in the sections above.

| Path | SHA-256 |
| --- | --- |
| `bridge/launch_probe.py` | `878264205f4c3bade8796ab78b91ec654ed48c9a478646ebf6e11968a529ee31` |
| `bridge/test_launch_probe.py` | `6061e7a763a77edf1b2548642aed28c02873bf84f3edb881ae9863b8201ee33b` |
| `bridge/state.py` | `5bb2e6f5600693cee24cda9b51e6b05ef748a48745c32c97e5f3906c01f17afb` |
| `ios/AwesoMuxCompanionUITests/ForegroundLifecycleTests.swift` | `9da6b2bb969d425071da906ae48af90c9e4ef97db8903182ae8578552a572ba6` |
| `ios/project.yml` | `2db59772d9bc93382bfd734dc1fd5541eee287834082022cd5ad3e11581f2604` |
| `ios/AwesoMuxCompanion.xcodeproj/project.pbxproj` | `f38b97aa831bfc8804cf26ecb3efbdfd47d302627fa0732ceefc4e3fc4f08efd` |
| `ios/AwesoMuxCompanion.xcodeproj/xcshareddata/xcschemes/AwesoMuxCompanion.xcscheme` | `2a58276cb46733d6e3fc0de846719856d9bce4af8ee59d6606e8f5a6097d02d0` |
| `README.md` | `3338f8a3ea4fb1653d1284288d8c03cd295dd1e59da45f101510cc3e0b0df584` |
| `ios/README.md` | `86dda71c93189fa5652ba2e121f494ea6fc1eaf6b68fb3ed373c48df6e77e960` |
| `docs/native-client-progress.md` | `0048628e24ef3072379ada40d3718357aa48eadfc719c84eb397140ce3788c46` |
| `docs/reviews/2026-10-02-native-reply-live-result.json` | `292f7590567ee9ffc363cd5cb32e0b18f2c30d0f034dc261ff7c7acc2014a586` |
| `docs/reviews/2026-10-02-native-devicehub-trial-result.json` | `a834f18e01b865e40bdca1eba3dc8c4981e8eb9c8136339a2f9f0bf6dd17f78b` |
| `docs/reviews/2026-10-02-native-live-result.json` | `f68d1060c1f5a26baaadf641c7150cfa8e19f0bc450851e01ec928785fa185e0` |
