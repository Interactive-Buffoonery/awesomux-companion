# Companion Squircle evidence

## Scope and revisions

Initial clean branch `feat/squircle-development` and fetched `origin/main`:
`76e944a78f7f1bb701aca50c8aaf1338a02a7d34`. No open Companion PR or other
Companion Squircle owner was found. Upstream Squircle still matched pin
`737f2e881483a4c7237b49d5696adff7d44cad1b`. OG PR98 advanced from the reviewed
`f8438e8` to `e8287a6`; its reused core adapter/enrollment were unchanged.
The OG checkout/thread were read only. Its service/build/device state was not
changed. No phone, service, provider, hook, delivery or release change was made.

## Executed evidence

- Fresh pinned preparation succeeded repeatedly, including a new
  `/tmp/companion-squircle-reviewed` from the current adapter templates.
  This proves cloning/application/rendering, not compilation.
- First gated run: five then-current synthetic Python tests passed. The source
  checker then failed with `NameError: adapter is not defined`; the runner
  stopped. The checker was fixed and expanded to compare the complete rendered
  patch, enrollment, injector and bundled notices. No current passing rerun is
  claimed.
- Current full-suite rerun was blocked **before start** by process-gate's occupied
  local slot, initially attributed to OG xcodebuild, later owner unknown. This
  custom job has no supported remote route. The owned admission wrapper alone
  was terminated (exit 143); no test child started and no automation remains.
  No gate bypass, lock removal or cancellation of another owner's job occurred.
- `git diff --check` passes. The installed T3 Nightly CLI's read-only
  `auth session issue --help` confirms the documented scope/TTL/JSON flags.
- Matching local app/widget development profiles and a local signing identity
  are available, but no signing/build proof follows from their presence. Local
  inputs are private/ignored; neither identity nor device/profile data is
  recorded here.

## Independent review ledger

One focused cross-provider Fable source review identified:

| ID | Severity | Resolution |
| --- | --- | --- |
| S1 | should | Personal XcodeGen metadata now goes to ignored `.squircle/generated` paths; normal App Group metadata uses the existing generated-Info build-setting pattern. A regression checks all four personal paths. |
| S2 | should | Offline injector rejects absent/false personal Debug marker before framework building/signing. Rust fixtures cover rejection and explicit acceptance. |
| N1 | nit | Prepared patch comparison now pins Git prefix, abbreviation, color and external-diff settings. |
| N2 | nit | Dedicated single-App-Group profiles are documented as an intentional fail-closed constraint. |

The alternate-namespace background-task regression also caught a mismatch:
bundle replacement is now confined to product IDs and preserves the task ID
registered by `App.swift`. A second fresh focused Fable source recheck approved the code through
`6b4bb42` and confirmed S1/S2 fixed. Its remaining Git-format nit was narrowed
with explicit prefixes/context/algorithm. Its proposed Release metadata check
was added for both app and widget. The suggested failure rationale (absent key
breaks normal widgets) does not apply: `GlanceSnapshot` retains the existing
App Group fallback. Actual generated metadata remains an execution checkpoint.
Source approval does not replace execution evidence.

## Remaining checks and acceptance

Run from a clean committed tree through process-gate on Midnight Pro/Pinguchy:

1. `zsh developer/squircle/verify.sh /absolute/prepared-overlay`: config/export/
   profile fixtures, complete adapter integrity, V2 SQL fixtures, compiled Swift
   service-policy/dispatch fixtures, existing iOS tooling tests, shared Swift
   protocol tests, pinned Rust library/injector tests and injector compilation.
2. Integrate the pinned source-built renderer with its original receipt using
   the existing guide; run the personal Debug export recipe in `README.md`.
   Verify Swift 6 overlay compilation, actual Info markers, signatures, matching
   host/widget App Groups and unchanged entitlements after injection/export,
   notices, Mach-O load command and absence of embedded credentials.
3. Regenerate the normal project and build Release separately. Inspect that
   actual app with `check-release.py`. An unsigned device-SDK build is separate
   from a signed archive, phone install and release/distribution proof.
4. After Sarah explicitly selects a phone and authorizes installation, use T3
   device tools for agent-driven interactions. Import private enrollment,
   Connect/Forget/renew, validate exact chat destination, questions/approvals,
   known-run interruption, attachments, background and reconnect. Use harmless
   content and never replay an uncertain mutation blindly. Ed signs/enrolls on
   his own behalf. LAN and cellular/remote connectivity need separate proof.

No simulator, physical-phone, remote/cellular or runtime acceptance is claimed.
No public push/PR exists. Public content, phone installation, delivery and any
shared-service/network action require their own explicit approval.

## Publication assessment

Merge risk: high. Personal sessions can perform more operations than this
client displays, and signing and runtime acceptance have not run. Recovery:
Forget enrollment, revoke its Mac session and install an approved normal build.
A source revert cannot retract messages or answers already sent.

The two focused source-review rounds used `claude-fable-5-1` at medium effort.
Both confirmed no shared-service/provider mutation. The second approved source
through `6b4bb42`; subsequent changes are enrollment/evidence docs and stronger
artifact/Git-format checks. No native/runtime approval is implied.
