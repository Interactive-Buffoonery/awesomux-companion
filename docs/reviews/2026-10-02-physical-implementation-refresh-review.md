# Physical foreground implementation: affected-scope refresh

2026-10-02. **Verdict: PASS for the affected prepared source scope. Both original blocking findings are resolved.** This verdict does not establish physical transport/Keychain runtime readiness or authorize network exposure, signing, account changes, or installation.

## Identity and scope

- Adapter: Codex collaboration agent, independent implementation-review context. Actual selected model: `gpt-6-astra`, supplied by dispatch. This is the bounded refresh of the original independent review, not a new specialist panel or PR review receipt.
- Original non-Git target: `/Users/edequalsawesome/Development/awesomux-ios`.
- Current manifest: `docs/reviews/2026-10-02-physical-implementation-fixed-scope.json`, SHA256 `f334099b5ef84c99d70d4aaeab588c3b45eda6c6adbe224727da4420e866c0fd`, listing 40 files with their exact current hashes.
- Current private snapshot: `/private/tmp/physical-review-refresh-596n4wta`. All 40 original and snapshot hashes matched the manifest before and after review. No source changes or runtime actions were performed; the sole authorized workspace write is this new report.
- Prior manifest: `2026-10-02-physical-implementation-scope.json`, SHA256 `9d8fa09532059c88e410af589d993164f10d1e996ef109c1517f1eb07b855649`.
- Prior report preserved: `2026-10-02-physical-implementation-review.md`, SHA256 `8846105696cf165d9c5050864accb799e0b76ce5dc24117ec09f119b93951529`. Its historical changes-required verdict remains valid for its original scope.
- Independently compared both manifests: exactly the 11 changed/added paths recorded in `2026-10-02-physical-review-impact.json`; no omitted intervening file change in the manifest scope. Seven original files changed, and four previously omitted fixture/UI-test files were added to review scope.

Current behavior-bearing production hashes:

| File | SHA256 |
| --- | --- |
| `ios/AwesoMuxCompanion/CompanionStore.swift` | `1c58d887da5b35ca5aebc1e61bd5f9fb1c720b2ac26112c18252cde96b9d719e` |
| `ios/AwesoMuxCompanion/QuestionCard.swift` | `c223f2e3c1bc6db34de38ea38613067c4a7eb8365063f0b13c53cfffceca89a1` |
| `ios/AwesoMuxCompanion/ThreadView.swift` | `20b1a53780477609985710c583f4a56178ee26358c7382593554a07c8df6e8d3` |
| `ios/AwesoMuxCompanionTests/PairingStoreTests.swift` | `d56520be3ec525d35cfa2a956ee29258a06bf099dd0b2d3eb484147067eeb8c4` |
| `ios/AwesoMuxCompanionTests/CompanionStoreTests.swift` | `c7e6f0396f4e4769ce5fb86794e0e2d74589ca9b01361c7e18c530c4dd2b893f` |

## Finding disposition

### Original finding 1 — old displayed intent crossing a replacement connection: RESOLVED

The new immutable `AnswerContext` contains the local connection revision and server generation. `canAnswer`, `submit`, and `retry` require it explicitly; there is no default that substitutes the current context. Every production callsite was searched and reviewed. ThreadView supplies the displayed context to QuestionCard, and the card identity includes revision, generation, and control ID. Replacement/re-pair retires the revision even when the host process and its server IDs remain identical.

QuestionCard copies mutable answer and confirmation values before scheduling its submit Task. Its control and context are immutable value properties captured with the card, so a delayed Task carries the displayed identity rather than reading the current context from the store. The guard runs before reservation or POST. Current supported/status/question/uncertainty data must match the displayed control; submission validation and serialization use the authoritative current control. Existing in-flight response fences remain unchanged.

Retry carries both the immutable displayed context and the displayed submission's operation ID. It cannot select a different replacement operation merely because its control ID matches. The current operation's immutable bytes remain the retry payload.

Reviewed regression `testQueuedDisplayedIntentCannotCrossReplacementOrSameHostRePair` retains an old control/context, performs same-host and other-host pairing with identical fixture generation/control IDs, fetches fresh state, and verifies the old intent causes zero writes while the new displayed intent causes one. `testStaleRetryContextOrOperationCannotRetryReplacementAnswer` rejects old revision and old operation identity independently, then verifies a current retry reuses the current operation body. Existing delayed GET/POST result tests are retained and now submit a freshly obtained replacement control.

### Original finding 2 — thread hardcodes “Local Mac”: RESOLVED

ThreadView now displays `store.activeHostLabel ?? "Unavailable host"` and exposes `connected-host` for UI verification. The label follows the same observed store used by pairing and activation reload; current code sets the actual host before fresh controls can enable. The development path alone supplies the “Local Mac” label. There is no longer a hardcoded local-host claim on the actionable thread.

No remaining blocking findings were found in the affected paths. No additional speculative requirements are added by this refresh.

## Retained coverage and impact decisions

All 16 `bridge/` manifest entries are byte-for-byte unchanged, including launcher, route/watchdog lifecycle, server framing/authentication, state/transport, private capability files, and their tests. The spec, physical plan, upstream Serve ownership evidence, Swift URL/TLS client, credential-store implementation, app lifecycle entrypoint, pairing form, inbox, models, and project configuration are also unchanged. The iOS fixes do not alter their network, wire, storage, ownership, or cleanup contracts. Therefore the original source assessment and its 17 passing targeted private-snapshot Python tests remain applicable to those exact unchanged files. They are retained historical coverage, not relabeled as new executions.

Refreshed coverage includes the actual changed store/view code, every submit/retry/canAnswer/card callsite, modified unit tests, README and execution-ledger claims, and the newly supplied JSON fixtures/UI lifecycle source. The fixture IDs are intentionally identical across replacement tests and therefore exercise the original missing boundary. The existing UI lifecycle test covers background/resume of a managed question; it does not assert the new host label or physically validate Keychain/TLS, and this report does not claim otherwise.

The parent supplied RED evidence (24 tests: 23 pass, old-intent regression fails), followed by GREEN and then 25/25 passing iOS tests including stale retry checks. The reviewer inspected those test sources and their assertions but did not independently rerun Swift builds, macros, or Simulator UI. No additional unchanged Python tests were rerun in this bounded refresh. The ledger explicitly dates unsigned device builds before the intent fix; they are source-path preparation evidence, not final device execution.

The full final Claude/Opus 5.5 adversarial review was still independently running at dispatch. This report neither predicts nor substitutes for its actual returned coverage.

## Remaining runtime boundaries

No live Serve mutation, certificate issuance, account/device inventory, signing/provisioning, phone install, Codex inference, real Keychain operation, or APNs work occurred in this refresh. Phone TLS, actual proxy Host/framing, Keychain denial/lock behavior, network transition behavior, and scoped route cleanup require the separately authorized physical trial. The documented simultaneous-watcher/startup residual remains unchanged. This source review allows the parent to finish its remaining review and concrete authorization preparation; it does not itself grant the runtime permissions.

Cleanup addendum: both reviewer-owned private snapshots named above and in the original report were moved to Trash after retaining these reports; original temporary paths verified absent. Initial sandbox Trash access was denied; the same narrow command succeeded through supported escalation. No source files were removed. After report completion, the parent additionally reported final unchanged-scope 25/25 iOS tests, a 1-pass/0-skip actual Simulator lifecycle check, and latest unsigned Debug/Release device builds; these remain parent validation evidence, not this reviewer's own executions.
