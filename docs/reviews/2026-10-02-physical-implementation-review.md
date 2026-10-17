# Physical foreground implementation review

2026-10-02. **Verdict: changes required before a physical trial.** Two blocking source findings; no network, signing, or physical-device readiness is claimed.

## Reviewer and exact scope

- Adapter: Codex collaboration agent, fresh independent reviewer context. Actual selected model: `gpt-6-astra` (as supplied by the dispatch); this is one independent implementation review, not specialist-panel or PR coverage.
- Original target: `/Users/edequalsawesome/Development/awesomux-ios`, a non-Git workspace. No branch, commit, or reviewed diff is invented.
- Scope: all 36 explicit files and their hashes in `docs/reviews/2026-10-02-physical-implementation-scope.json`. Manifest SHA256: `9d8fa09532059c88e410af589d993164f10d1e996ef109c1517f1eb07b855649`.
- Review/test snapshot: `/private/tmp/physical-impl-review-pu78gjem`. Copied only manifest-listed source, tests, configuration, spec, plan, and evidence. All original and copied file hashes matched the manifest before review and at completion. No source was modified. The sole authorized original-workspace write is this new report.
- Applied the read-only isolation rules from `review-all` v0.2.8; did not invoke its full-panel orchestration or claim its lanes. Reviewed Swift pairing/client/store/view/model callsites, Python launcher/route/watchdog/server and transport/state/private-file dependencies, and supplied deterministic tests against the Task 1/2 requirements and rulings. Task 3 remains unperformed.

## Blocking findings

### 1. HIGH [AUTO-FIX]: displayed answer intent is not bound to its original connection before POST

Locations: `ios/AwesoMuxCompanion/CompanionStore.swift:166-186`, `ios/AwesoMuxCompanion/QuestionCard.swift:64-65,84`, `ios/AwesoMuxCompanion/ThreadView.swift:28-30`.

`connectionRevision` correctly fences the results of requests that have already begun. It does not fence an old view's input before `submit` begins. `canAnswer` only finds the same control ID in the current snapshot; `submit` then takes the **current** snapshot generation and current API. A `PendingControl` from the old connection has neither its displayed local revision nor its displayed generation. `QuestionCard` launches an unstructured Task that reads the old card's control/answers without an immutable displayed-connection token. `retry` likewise accepts only a control ID. The card's SwiftUI identity contains server generation and control ID, not the local connection revision.

Concrete source-level reproduction: retain an unsubmitted control and answer from host A; pair/retry/activate a replacement connection B whose fresh snapshot has the same generation and control ID; invoke the retained submit intent. Every guard passes and B receives the old answer. Same-process re-pair is an ordinary way to retain server IDs. The existing `testOldFetchAndPostCannotApplyAfterSameGenerationRePair` already passes the pre-pair `control` into a post-pair submission and expects it to succeed; it tests response fencing, not rejection of an old unsent intent. Clearing `snapshot` transiently is not an immutable intent check and must not depend on SwiftUI rendering the intermediate nil frame. A real queued UI interleaving was not exercised during this review.

Minimal fix: pass a required immutable displayed connection revision and generation through the card and submit/retry callsites, check them before any mutation or network operation, freeze tap inputs before creating the Task, and include the connection revision in card identity. Do not add a default argument that silently substitutes the current revision. Current-control question/status/confirmation validation should use authoritative current state after identity validation.

Required regression: retain a displayed intent from A, replace/re-pair with identical generation/control/question IDs, fetch fresh B, then release the queued old submit and assert B receives zero operations. Repeat for same-host re-pair and stale retry intent; prove a newly displayed B intent succeeds. Keep the existing in-flight GET/POST late-result checks.

### 2. MEDIUM [AUTO-FIX], blocking primary host-identification requirement: the actionable thread always claims “Local Mac”

Location: `ios/AwesoMuxCompanion/ThreadView.swift:43`; related activation replacement at `CompanionStore.swift:54-62,80-89`.

The inbox displays `activeHostLabel`, but the actual answer screen hardcodes `Text("Local Mac")`. Every paired phone host is consequently mislabeled while controls are actionable. If activation reloads a changed stored credential while a thread is open, the store switches to the replacement host and enables controls after its fresh GET without naming that host in the visible thread. This breaks the plan's visible-host safeguard around preserved/reloaded credentials and makes host changes ambiguous at the point of answering.

Minimal fix: show the store's actual host label in ThreadView, with an unavailable placeholder when absent. Keep the Simulator's existing “Local Mac” label only when that is the store's actual development label. Verify visible host identification before fresh controls enable, including activation reload with the thread open.

## Checks and positive findings

Executed only disposable local Python checks in the private snapshot:

`python3 -m unittest -v test_private_route test_route_watchdog test_server test_launch_probe`

**17 tests passed in 8.900 seconds.** These exercised fake-route occupied ports/schema/foreground entry/readback/baseline conflicts, failed startup and changed cleanup state; real disposable child deadline/ignored TERM/readiness/parent SIGKILL/supervisor SIGKILL behavior; loopback and exact proxy Host/auth/Origin/body-framing/size rejection; and assistant-evidence classification. No Tailscale commands or Codex inference ran.

Source findings supporting the prepared approach:

- Canonical HTTPS origin and bearer validation rejects aliases, paths, embedded credentials, token control characters, and unsupported ports. Redirect handling refuses the new request. TLS trust uses platform default handling with nil credentials; credential-bearing challenges are cancelled. Session caches, cookies, credential storage, and explicit proxy settings are cleared.
- Device/Release storage uses a single validated Keychain JSON item with WhenUnlockedThisDeviceOnly, update-before-add, idempotent missing-item delete, and no plaintext fallback. Failed load/save/delete retires the active client and prevents implicit activation from clearing quarantine. Real Security.framework failure semantics were inspected in code, not runtime tested.
- Request revision/epoch/sequence and operation-identity checks protect late GET/POST results, preserve unknown outcomes, and require fresh state after activation. They do not resolve finding 1's earlier intent boundary.
- Route startup pins the reviewed Tailscale version/commit, treats candidate occupancy conservatively, verifies one exact foreground entry and unchanged unrelated baseline, and stops only the recorded owned process on conflicts. Cleanup never issues off/reset or restores an entire configuration. The supervisor's parent pipe, readiness handshake and child-creation identity plus the launcher's recorded-child monitor match the documented single-watcher failure model. Tests and source do not imply a guarantee after simultaneous watcher death or unacknowledged startup failure.
- Backend exact Host and bearer/Origin checks remain in the same HTTP adapter. POST chunked framing is rejected, so actual Serve forwarding still needs the explicitly scoped live check rather than a relaxed parser/allowlist.

## Limits and declined boundaries

The parent supplied 23 passing iOS tests, 31 passing bridge tests, an actual unsigned Simulator file-loading observation, and an unsigned Release device-path compile. These are reported parent evidence, not reruns by this reviewer. The scope manifest omits iOS fixture assets/UI-test sources referenced by the project; no expanded original-workspace fixture scan or Swift build/macro execution was performed. The included Swift tests were read, including their missing old-intent assertion identified above.

No real route creation or certificate issuance, network/account/device inventory, signing/provisioning, device installation, real Keychain access, APNs setup/delivery, or secret inspection was attempted. Reviewed upstream ownership evidence is supplied source evidence; it is not observed live Serve cleanup. Real HTTPS trust/redirect behavior, Serve Host and HTTP/2-to-backend framing, physical Keychain lock/denial behavior, phone network transitions, and before/after route-preservation readback remain Task 3 checks behind its concrete authorization boundaries.

After the two fixes, rerun affected iOS tests and refresh this review on a new explicit scope manifest. Preserve this report as evidence of the original reviewed scope; do not relabel it as approval of later edits.
