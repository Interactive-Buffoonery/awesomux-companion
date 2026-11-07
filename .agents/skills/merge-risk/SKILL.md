---
name: merge-risk
description: Assess how risky a Companion change is to merge and where human attention would help most. Use after verification and before opening a pull request, or when asked for merge risk on a branch or PR. Read-only and advisory.
---

# Merge risk

Assess the exposure left in a change, for reviewers. This is not merge approval
or a gate. Do not edit, build, run tests, start reviewers, post comments, upload
builds, or merge.

## Evidence

Reuse results from this revision, then read the diff and its callers. Missing,
older, or inconclusive evidence is unknown, never passing.

- PR guards test the description validator, Python build tooling with synthetic
  files and mocked commands, and the root Swift protocol package on macOS.
  They do not build, sign, launch, or test the iOS app or native renderer.
- App tests live under `ios/AwesoMuxCompanionTests`; use `ios/project.yml` and
  `ios/README.md` for the shipping build and source-built renderer. Generation
  and native receipts prove inputs, not terminal behavior.
- Simulator fixtures do not prove real pairing, Keychain or Secure Enclave
  behavior, biometric prompts, LAN/Tailscale failures, background scheduling,
  or VoiceOver speech. An archive/export does not prove upload or distribution.
- On Midnight Pro and Pinguchy, builds and tests use `process-gate` from a clean
  committed tree. Simulators use T3 Code device tools. This skill runs neither.

## Where risk lives

Paths below are relative to `ios/` unless they start with `Sources/` or `spikes/`.
The proof column names evidence to inspect, not commands this skill may run.

| The diff touches | Failure | Proof beyond PR guards | What a revert leaves |
| --- | --- | --- | --- |
| `AwesoMuxCompanion/PairingStore.swift`, `PhoneIdentity.swift`, `Hosts.swift`, pairing and unpair in `CompanionStore.swift` | Lost credentials, wrong Mac selected, or another Mac's pairing changed | App tests for failed reads/writes/deletes and migration; real multi-Mac pairing, replacement, unpair and relaunch with existing records | Keychain keys, migrated records, host lists and Mac grants remain changed; a deleted key needs pairing again; revoke leftover grants on the Mac |
| `AwesoMuxCompanion/MacClient.swift`, `TerminalLockModel.swift`, `PendingDecisionsModel.swift`, consent and send gates | Wrong peer trusted, private content exposed, or input/decisions sent without current authority | Wrong-pin rejection, permission revocation, lock/background and delayed-response tests; physical authentication and paired Mac checks; keep remote decisions production-disabled until Mac acceptance | Disclosed text and commands or answers already sent cannot be recalled; a Mac refusal or missing reply does not prove nothing ran |
| `Sources/AwesoMuxCompanionProtocol/`, phone-local envelopes in `MacClient.swift`, dependency pins and protocol tags | An installed phone and Mac stop understanding each other | Contract fixtures plus old/new Mac and phone combinations, absent capabilities, unknown fields, and real paired requests; see `docs/adr/0001-shared-companion-protocol-package.md` | Macs pin exact package releases and phones ship separately; a source revert changes neither consumer already installed. Keep wire changes additive and missing permissions default-off |
| `AwesoMuxCompanion/WatchStream.swift`, `WatchModel.swift`, `WatchInput.swift`, `WatchTerminalBoundary.swift`, `PhoneTerminal.swift`, `spikes/ios-terminal-renderer/` | Garbled replay, stale bytes, unintended input, wrong-pane control or runaway resize | App stream/order/generation tests and production renderer replay; real Mac takeover, grid-before-input, safe paste, permission changes, reconnect and suspension checks | Input already forwarded and terminal side effects remain on the Mac; lost output/history cannot be recovered by reverting. Never replay uncertain input |
| `AwesoMuxCompanion/CompanionStore.swift`, `SessionSnapshotCache.swift`, `Shared/`, widgets and `LiveActivityController.swift` | One Mac's data shown for another, stale private content, or incompatible saved state | Host-switch and late-completion tests; upgrade/relaunch with existing per-host defaults and App Group data; real widget and Live Activity lifecycle checks | Saved caches, defaults and App Group data remain; older builds must read them safely. Visible cards may need an explicit refresh or end |
| Attention tracking and notification routing in `AwesoMuxCompanion/CompanionStore.swift` and `App.swift` | Missed or duplicate alerts, or a tap opens the wrong Mac/pane | Cursor recovery and routing tests, legacy notifications, removed hosts; real notification permission, tap and background-refresh checks | Delivered notifications and saved cursors remain; a revert cannot deliver missed alerts or undo a disclosure. There is no push; iOS schedules refresh |
| `project.yml`, entitlements, `script/testflight.*`, release metadata and native dependency integration | Install/update fails, wrong artifact ships, or signing/App Group access breaks | Tooling tests plus affected archive/export, signatures, profiles, bundled notices and exact artifact identity; separately verify App Store Connect processing and intended group/version | TestFlight/App Store installs remain on phones. Stop further distribution where possible and ship a corrected build; a Git revert cannot reach installed phones or restore lost signing keys |
| `.github/`, contributor guidance and skills | PRs blocked, checks wrongly accepted, or untrusted code gains a write token | Validator/tooling tests, workflow lint and trusted-base review; after landing, inspect a real metadata run and size label | Comments and labels may remain. Revert the workflow change and rerun affected checks; app binaries are unchanged |

## Judge

Check alignment with the linked issue, then each touched row, its reach and proof.

- **Timing:** Merge, protocol tags, TestFlight upload, group distribution and
  App Store release are separate events. Name which has happened. A revert
  helps future builds; installed phones need a corrected version. Never imply
  that merging authorizes a release.
- **Detection:** Name the real signal: failed checks, app error/recovery UI,
  tester reports, or privacy-safe device/Mac logs. Watch diagnostics use the
  `watch`, `transport`, `renderer`, `input`, `lifecycle` and `routing` categories
  under `com.interactivebuffoonery.awesomux.companion`. Logs must not contain
  terminal text, input, pairing links or credentials. Do not assume central
  telemetry or background delivery.

Use low, medium, high, or unknown. High: a failure loses credentials, widens
access, sends unintended input/decisions, or strands installs, and the relevant
proof did not run at this revision. Never low with an open security finding or
missing relevant proof. Use unknown when the evidence cannot establish exposure;
state the gap. Docs-only changes need `git diff --check` and are low unless they
change a protocol, release, authority or journey contract.

## Report

Return one line for `Merge risk:` under Notes: the level, the main reason, and
how to recover. Write it, and updates to it, in simple English or ASD-STE100
(Simplified Technical English).

> Merge risk: high. Changes pairing storage without an upgrade check on an
> existing phone. Recovery: ship a corrected build; a revert cannot restore
> deleted keys, and affected phones may need to pair again.

When asked for the full assessment, add the revision, one line per row touched,
and the next action that would most reduce risk.
