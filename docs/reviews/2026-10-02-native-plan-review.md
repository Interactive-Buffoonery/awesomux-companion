# Native foreground client architecture review

Date: 2026-10-02
Adapter/model: Codex subagent / gpt-6-sol
Skill: review-plan
Scope: native foreground client plan against approved design and current bridge README, server.py and state.py. Read-only; only this report written. No inference or runtime launched.

**Clarity: FORMING. Verdict: refine the small contracts below, then proceed.** Simulator-only scope, no physical-device/push readiness inferred.

## System diagram

```text
Simulator private development capability
                 |
SwiftUI -> main-actor store -> ephemeral URLSession
                 |                    |
   active epoch / immutable op    authenticated loopback bridge
                                      |
                              managed Codex thread
```

## Concrete findings

### P1 — Submission unit must be a whole control, not one question card

The actual bridge requires answers for exactly every question ID in a control. A pending control can contain multiple questions. Task 2 describes question cards with Submit Answer without defining shared control-level completeness; an implementation submitting one card at a time will be rejected or send incomplete semantics.

**Smallest fix:** A card/form owns the entire pending control and drafts for all its questions, with one deliberate submit. Require every required answer before enabling that submit; build one immutable operation containing all question IDs. Test a two-question fixture, incomplete submission suppression and one complete payload. Radio/free-text choices can remain per question inside that form. No extra view architecture is needed.

### P1 — Freshness expiration and failed polling must disable cached controls explicitly

`canAnswer` requires fresh HTTP success, but no age or failure rule defines fresh. An earlier successful snapshot can otherwise leave controls enabled after a subsequent poll timeout or parse failure while lifecycle stays active.

**Smallest fix:** Invalidate writable freshness immediately on fetch failure or cancellation of the active fetch/lifecycle. Define a finite local monotonic freshness lease (for example covering one 2-second polling interval plus its 8-second request budget); revalidate at submit time, not only in rendered button state. A successful authoritative fetch restores it. Server `updated_at` is last upstream update, not connection health: do not disable a legitimately idle thread because that timestamp is old. Test successful fetch then failed poll and stale-lease submission with an injected clock or explicit expiry transition.

### P2 — 4 MiB is not a guaranteed upper bound for a valid bridge snapshot

Bridge text is bounded to 16,384 Python characters, not UTF-8 bytes. Server json.dumps uses ASCII escapes, so 200 non-ASCII text entries can exceed 4 MiB; bounded question data adds more. The plan says bounded history can approach 4 MiB, which is narrower than the source contract.

**Smallest fix:** Keep a finite client cap, but explicitly treat exceeding it as a visible unsupported/oversized snapshot that disables controls rather than claiming all bridge snapshots fit. Enforce the cap while receiving with a delegate/byte stream or equivalent, before unbounded data accumulation; Content-Length alone is not sufficient. Test a valid over-limit response and graceful disconnected/read-only UI. Aligning bridge aggregate serialization bounds can be a later separately reviewed change; do not silently alter backend scope here.

### P2 — Test notification suppression must be an execution precondition

The interactive managed launcher extends existing inference testing after an external Moshi notification incident. The README now documents launch-only notification suppression, but Task 3 does not explicitly gate new inference on verification.

**Smallest fix:** Before any new turn, require no-inference configuration readback of the newly owned server proving `notify=[]` and `tui.notifications=false`, and apply the same recorded launch overrides to its TUI. Scrub MOSHI_* alongside existing routing keys. Fail closed if effective settings cannot be verified; preserve plugins/safety hooks/global settings. Parent reports prior test runtimes are stopped; this reviewer did not independently inspect or start them.

## Failure modes

| Trigger | User impact | Required post-failure state |
| --- | --- | --- |
| Partial multi-question form | Rejected/incomplete answer | No POST until whole control complete |
| Poll fails after success | Old question remains actionable | Cached text visible; writable freshness invalid |
| Background/canceled POST | Unknown whether response reached bridge | Uncertain immutable operation; no automatic resend |
| Late POST after resolved fetch | Resolved question reappears | Authoritative snapshot wins; never reinsert |
| New bridge generation | Draft addresses obsolete control | Clear drafts and old controls; suppress stale results |
| Oversized/invalid snapshot | Memory growth or unusable controls | Bounded receive abort; visible error; no writable controls |
| Unexpected HTTP status | Invalid success inference | Decode known outcomes/errors deliberately; unknown state is failure/uncertain |
| Managed test retains notification settings | Unwanted external ping | Verified launch-only suppression before inference |

## Hidden assumptions and shadow paths

- Configuration absent/malformed: unconnected real UI, already planned.
- Redirect/auth exposure: reject redirects and literal endpoint validation, already planned.
- `generation` can be null before upstream readiness; snapshot error is nullable; operations contain documented status strings. Actual-shaped Codable fixture coverage must include initial/disconnected state, not only happy path.
- Bridge pending controls expose submitted/submitting/uncertain status; canAnswer must require status pending and no immutable attempted operation, not merely array membership.
- HTTP 202 outcome is submission state, not accepted/winner attribution; plan correctly demands authoritative resolution.
- One local Simulator can reach host loopback: testable in planned smoke. This does not establish a physical-device route.

## Proportionality and production honesty

One main-actor store, injected client, native navigation and completed text suffice. Streaming, composers, notifications, persistence, generalized session discovery and third-party UI are properly deferred. A 20-minute owned interactive development session is bounded; cleanup and injected capability trashing must be verified.

## Framing falsification

The real Simulator UI submission followed by authoritative same-thread resolution is the right experiment. XCTest and screenshot fixtures alone cannot establish that loop. No additional product decision is needed after the small contract clarifications above.

## Recommendation

Fold in control-level submission, explicit writable freshness invalidation/expiry, honest bounded-response failure behavior and the notification-suppression gate. Then execute Simulator-only implementation and its independent Swift/security/concurrency review.
