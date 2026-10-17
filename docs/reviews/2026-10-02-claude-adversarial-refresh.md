# Claude adversarial refresh evidence

Adapter: Claude Code. Requested and actual model: `claude-opus-5-5`, verified in CLI `modelUsage`. Exit 0; `is_error: false`. Safe mode, tools disabled, empty MCP configuration, no session persistence. Reviewed input hashes verified unchanged after completion.

# Claude adversarial plan review: refresh 1

**Identities**
- Reviewer: Claude Opus 5.5, model ID `claude-opus-5-5`. This is self-reported; confirmation via CLI `modelUsage` belongs to the invoking harness.
- Snapshot: `/private/tmp/awesomux-ios-plan-review`
- Isolation rubric: `review-all v0.2.8`
- Reviewed: `docs/superpowers/plans/2026-10-02-codex-live-control.md` (revised), checked against `docs/companion-v1-design.md`, my original `docs/reviews/2026-10-02-claude-adversarial.md`, and `docs/reviews/2026-10-02-plan-review.md` for context.
- Mode: read-only, no tools, no edits. I computed no content hashes; bind this report to the snapshot's file hashes externally. Cycle: one remediation cycle. I verified no Codex protocol behavior.

## Disposition of original findings

| ID | Disposition | Where addressed |
|---|---|---|
| **B1** False reuse via special launch | **Resolved** | Task 3 step 2 launches the normal TUI as the pane process and records the command and every override. A private endpoint selector is allowed only if source proves normal ownership semantics; otherwise it goes to the special-launch gate. Task 1's gate returns special launch to eD! before exercising it. Task 4 adds the verdict "supported only with non-default launch". |
| **B2** Shared runtime exposure | **Resolved** | The `ProbeClient` thread allowlist is captured from the disposable launch, with a stop if the ID is unavailable without unrelated-thread access. Out-of-allowlist traffic is dropped without content logs. All endpoints live under a unique `/private/tmp` root. Shared-default-daemon-only access means stop without connecting. No `CODEX_HOME` or credential copying, and no global daemon changes. |
| **B3** Structured question not guaranteed | **Resolved** | Task 1 identifies the question method and its prerequisites. Only recorded per-launch overrides are allowed, with no policy changes. A timeout is classified as "question-generation inconclusive". Read-only approval evidence is labeled approval-only, never question support. |
| **B4** Desktop resolution not a pass criterion | **Resolved** | Task 3 step 5 requires the desktop question to be removed or disabled for full success. A still-answerable desktop prompt means partial support. Resolution alone never establishes that our answer won. |
| **M1** Identity correlation by construction | **Resolved** | Task 3 step 3 compares `providerSessionID` with the thread ID if safely available. Otherwise the plan leaves hook association explicitly unverified and labels any correlation as by construction. The env scrub in step 1 will likely make the comparison "unavailable"; the plan permits that outcome honestly. |
| **M2** Per-connection request ownership | **Resolved** | `PendingRequestRef` includes `connection_incarnation`. References are created only from requests delivered on the client's current connection. Request IDs are recorded per connection. A test covers an identical ID, thread, and turn reused after reconnect. |
| **M3** Outcome states and retry results | **Resolved** | Outcomes are `rejected`, `already_resolved`, `sent`, and `uncertain`. An in-memory map keyed by the full reference returns stored state without writing. Resolution is asynchronous and separate from the write outcome. |
| **M4** Tests for logic the probe lacks | **Resolved** | Host and amx cases are removed and deferred to the bridge plan. The self-review now says review-focus cases are gated, guarded, or measured, rather than all covered by Task 2. |
| **M5** amx addressing | **Resolved** | Every amx command uses `env -u ZMX_SESSION_PREFIX` with an explicit unique `ZMX_DIR`. Teardown verifies the exact namespace, socket, and name before stopping anything, then trashes the root. |

## Remaining blockers

**None.**

One non-blocking wording note, not new scope: Task 3 says unverified arbitration "prevents a full companion-ready verdict". That term doesn't appear in Task 4's verdict list. When writing findings, state explicitly whether "supported and exercised" requires verified arbitration. Otherwise a reader of Task 4 alone could advance to the bridge plan with arbitration unverified.

## Verdict

**PASS from this adversarial reviewer** on B1–B4 and M1–M5 for this remediation cycle. No optional hardening was requested or added, and O1–O10 remain optional.

This is not a final execution pass. The plan itself requires both reviews to refresh, and the plan skill refresh is still running.
