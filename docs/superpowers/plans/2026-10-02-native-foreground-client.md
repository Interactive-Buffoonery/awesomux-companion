# Native foreground client implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A native iPhone Simulator app shows the real managed Codex thread, renders pending questions, submits a deliberate answer and reflects authoritative resolution.

**Architecture:** SwiftUI NavigationStack with a one-thread inbox and conversation detail, one main-actor observable store, Codable wire models and an injected URLSession client. Poll the reviewed local bridge only while active. Development connection capability is injected into the Simulator app's private container; no secrets in source, logs or launch arguments. This slice is explicitly Simulator-only; physical-device pairing/connectivity and push follow later.

**Tech Stack:** Swift 6, iOS 18+, SwiftUI/Observation/Foundation; XcodeGen for a reproducible Xcode project; local Xcode only, no hosted/native paid CI or dependencies.

**Spec:** docs/companion-v1-design.md; bridge/README.md defines the current HTTP contract.

## Constraints

- No terminal, break reminders, fake active sessions, transcript-bearing notifications or phone-ready claims.
- No composer/new-session button until the backend supports them. Only actual supported questions are answerable; secret questions/approvals remain read-only.
- Single configured loopback host, single allowlisted thread. Development configuration loading exists only for Simulator/debug builds; release/device builds have no local capability injection.
- Exact literal http://127.0.0.1:<port> endpoint required. URLSession ephemeral configuration, GET receive cap 4 MiB and POST cap 64 KiB, with explicit AsyncBytes.task cancellation on cap; both request and resource timeouts of 8 seconds, no redirects (never forward Authorization), no cache/cookies/credential storage or proxy/PAC (connectionProxyDictionary empty); cancel auth challenges, reject redirects, verify response.url matches requested fixed path. ATS local exception confined to debug Simulator development configuration; no global arbitrary loads for shipping builds.
- Token stays in private development config; no analytics or network logs. HTTP response bound 4 MiB; invalid payload cannot become controls. The current bridge bounds text by characters and may legitimately exceed this cap after serialization; abort receive before unbounded accumulation, show oversized-snapshot error and disable controls. Do not claim all valid snapshots fit. Content-Length is only an early rejection, not the enforcement mechanism.

## Failure focus

- Background/foreground: cancel polling, immediately disable controls, require a fresh fetch before re-enabling.
- HTTP loss after POST: show uncertain; never auto-resubmit. Same user-requested retry must reuse the original operation UUID and answer payload.
- Fresh snapshot resolves/removes question while POST is in flight: do not reinsert it; authoritative state wins over late submission response.
- Reconnect generation changes: clear question drafts/submission identities; old controls disabled. Prior uncertain replay needs explicit visible confirmation.
- Dynamic Type/VoiceOver: option description readable, selected state announced, large touch targets, no color-only status.

### Task 1: Native client and state

**Files:** `ios/project.yml`, `ios/AwesoMuxCompanion/App.swift`, `BridgeClient.swift`, `Models.swift`, `CompanionStore.swift`; `ios/AwesoMuxCompanionTests/CompanionStoreTests.swift`.
**Interfaces:** `BridgeAPI.fetch() async throws -> ThreadSnapshot`, `answer(AnswerOperation) async throws -> AnswerOutcome`; immutable Codable Sendable models matching actual response contract and exported ios/Fixtures snapshots: outer snake_case, camelCase question flags, nullable generation/error, updated_at Double with fractional fixture, operations [String:String] preserving unknown values read-only; decode submitted fixture with populated operation/nonpending control. Unknown control status is read-only, not a whole-snapshot failure. Store owns snapshot/freshness/connection state and submissions keyed opaque control ID; derived canAnswer requires active + fresh HTTP success (local monotonic 10-second lease anchored to request send time, revalidated at submit; invalidate immediately on fetch failure/active cancellation, never derive health from upstream updated_at) + upstream connected + no bridge error + control pending + not submitting.

- [ ] Write failing tests for decoding actual bridge-shaped fixtures, canceled/stale fetch result suppression, generation draft clearing, duplicate submit suppression, uncertainty/retry using identical operation payload, and resolution winning a late POST, a two-question control with incomplete submission suppression, failed polling after success, expired freshness lease, nullable initial/disconnected generation, oversized/invalid response and HTTP error outcome handling.
- [ ] Implement client with literal-loopback endpoint validation, no redirect forwarding, ephemeral session, timeout and bounded response data. Configuration loaded from ApplicationSupport/development-client.json only under `#if DEBUG && targetEnvironment(simulator)`; absence yields unconnected UI, never a mock.
- [ ] Implement @MainActor @Observable store. App-root foreground polling every two seconds sequentially, independent of detail navigation; leaving active (including inactive) invalidates controls and changes epoch, entering active changes epoch/refetches. Do not cancel a running POST merely for backgrounding; its immutable result can settle while controls remain disabled. Reload Simulator config on activation to accept rotated development credentials; credential rejection is distinct from disconnected. response tasks carry local lifecycle epoch and generation where applicable. Checks after await prevent stale updates. Canceled POST is uncertain because handoff may have happened; application never assumes cancellation undid the answer. Store each lowercase UUID operation with its encoded Data exactly once; explicit retries send those same bytes with original confirm flag. Cache one immutable operation per attempted control and reuse only on explicit retry with unchanged answers.
- [ ] Generate Xcode project; build and run meaningful XCTest checks locally. Review exact source and generated project. No signing credentials or provisioning changes.

### Task 2: Inbox and thread views

**Files:** `InboxView.swift`, `ThreadView.swift`, `QuestionCard.swift`.

- [ ] Inbox has a single real session row with Codex, Local Mac, last message preview, needs-input count and freshness/disconnected state. Empty unconnected state uses plain connection guidance, no fake button.
- [ ] Thread shows completed user/assistant text, truncation indicator and active supported question cards. Completed messages keyed by turn/item. Native grouped surfaces, restrained warm background and one accent; no custom gesture/navigation machinery. Use semantic system colors for contrast/dark mode.
- [ ] One control-level form owns drafts for all its questions and has exactly one Submit Answer button; all required answers must be present before one immutable whole-control payload is sent. Question rows show full question/option descriptions, radio selection or free-text input when permitted, optional Other only when isOther, explicit Submit Answer, and prior-uncertain confirmation from the bridge prior_attempt_uncertain flag before submission. Never infer it only from client memory or automatically enable it after a confirmation_required reply. Disable immediately when freshness/lifecycle/upstream disallows. A scheduled main-actor lease expiry updates observable freshness; submit synchronously revalidates. Local attempted operation locks its control even if an earlier GET returns pending. Every GET carries sequence/epoch, and stale GETs cannot remove operation locks. Submitted/submitting/uncertain controls show status and no editable second submission. Explicit retry repeats original operation only; replayed new control is a separate acknowledged answer.
- [ ] Preserve scroll position during polling; item identity uses turn/item composite. Use text selection and accessibility labels/selected traits, minimum native touch target, Dynamic Type. Show unsupported capability without pretending to approve anything.
- [ ] Build and inspect real UI, test one stale/disconnected state and accessibility hierarchy. Previews may use clearly named fixtures only; runtime uses real backend.

### Task 3: Real native loop and independent review

- [ ] Extend the owned managed launcher with an explicit interactive mode: create/authenticate the runtime and bridge, write client.json, wait for explicit stop (bounded 20-minute lifetime), retain only generic outcomes. Reuse existing safe cleanup. No unattended indefinite secret-bearing service.
- [ ] Before any new inference verify effective config/read on the freshly owned server confirms notify=[] and tui.notifications=false. Apply same per-launch TUI overrides and scrub MOSHI_* plus awesoMux/ZMX routing keys. Fail closed on missing readback; preserve global config/plugins/safety hooks. Retain only selected config booleans, no full config dump.
- [ ] Build/install on a local iPhone Simulator, inject the generated config into its private ApplicationSupport directory with mode 0600, open inbox/thread, answer a real question using UI, observe resolved state and completed response on same managed thread. Use XcodeBuildMCP screenshot/UI tools (source-derived controls only).
- [ ] Verify backgrounding disables controls and foreground refetch restores actual current state; stop host and verify disabled/disconnected UI. Remove/trash injected config and owned runtime/token directory after validation. Do not claim physical-phone reach or push.
- [ ] Independent Swift/concurrency/security review of actual source and outcome evidence; fix concrete findings and rerun affected checks. Preserve explicit model/report scope. No PR until a repository exists and full publication lanes pass.

## POST interpretation

202 known submitted/submitting/uncertain -> locked local operation, never call it accepted. 200 resolved -> locked/resolved, never infer winner. 409 conflict/already_submitted -> locked; confirmation_required -> discard only the rejected unreserved operation and immediately invalidate freshness/refetch and require visible confirmation only from a fresh prior_attempt_uncertain flag; absent flag remains locked. 400/401/403/413 or 404 rejected -> known no new reservation; invalidate freshness and refetch before editing. Any timeout, cancellation, 3xx, 5xx, malformed/unknown response -> uncertain locked operation, explicit identical retry only within same generation. A fresh snapshot removing a control wins over every late POST and does not reinsert it. Generation changes retain a non-actionable earlier-outcome-unknown notice, not answer controls. CFNetwork transport retries depend on operation-ID idempotency.

Response bytes are counted while receiving (bytes(for:) or delegate), including unknown length; fail closed on valid over-limit snapshots. Backend aggregate trimming is deferred, explicitly documented in bridge README; no backend contract change is needed for safe local UI. Client endpoint excludes port 80, credentials and any path/query/fragment; validate printable ASCII token with no CR/LF. Exact application/json request content type and httpBody Data provide Content-Length, never chunked body. Check response mimeType/status and exact known status/outcome pairing (mismatch/missing becomes uncertain for POST) before interpretation.

Every displayed question is required; trim free text and require nonempty content. Record TUI argv notification overrides separately from server config readback.
