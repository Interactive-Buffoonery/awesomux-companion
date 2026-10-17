# Claude adversarial plan review

Adapter: Claude Code. Requested and actual model: `claude-opus-5-5` (confirmed by CLI `modelUsage`). Exit 0; `is_error: false`. Tools disabled; safe mode; empty MCP configuration; no session persistence.

**Identities**
- Snapshot: `/private/tmp/awesomux-ios-plan-review`
- Isolation rubric: `review-all v0.2.8`
- Reviewed: `docs/superpowers/plans/2026-10-02-codex-live-control.md` against `docs/companion-v1-design.md`, plus `AgentHookPayload.swift`, the bundled Codex `hooks.json`, and the amx addressing excerpt.
- Mode: read-only. I used no tools and made no edits. I have not verified any Codex protocol behavior. Every protocol point below is phrased as something the plan must establish, not something I am asserting.

## Blockers

**B1. Task 3 can "prove" a companion-managed launch and report it as reuse**
- **Source:** Task 3 step 2 ("Start an isolated Codex session using the supported mechanism from Task 1"); Task 4 outcome classes; spec section "Control boundary".
- **Trigger:** Task 1 might find that attachment works only when Codex is launched in a special way, for example a TUI connected to an app-server or daemon that the probe started. Task 3 would then use that launch, and the experiment would succeed.
- **Consequence:** Task 4 would record "supported and exercised" and then "reuse supported live control". That skips the explicit companion-managed-launch decision the spec requires. The spec's real question is whether the *installed TUI, launched normally inside amx*, exposes its live session. That question would go unanswered.
- **Minimal correction:**
  - Task 3 must launch the Codex TUI as the pane process inside the disposable amx session, the same way a user would.
  - It must record the exact launch command and any flags.
  - Add a fourth outcome to Task 4: "supported only with non-default launch". Route that outcome to the user decision, not to reuse.

**B2. A second client on a shared runtime can see or answer eD!'s real threads**
- **Source:** Architecture section ("never resume or manipulate eD!'s existing conversation"); Global Constraints; Task 2 `reply` interface; Task 3 step 3.
- **Trigger:** The supported transport may be a per-user daemon or socket that eD!'s live sessions also use.
- **Consequence:** The probe's routing guards only check thread and turn consistency, not ownership. Nothing confines the probe to the disposable thread, so a bug or a mismatched ID could reply into a real conversation. Starting a daemon at the default location could also attach eD!'s future sessions to a probe-owned process. That is a "global daemon" side effect the constraints forbid.
- **Minimal correction:**
  - `ProbeClient` takes an allowlist containing only the disposable thread ID, captured from the session the probe created.
  - Any message or reply outside that allowlist is refused, written nowhere, and not logged in content.
  - Any app-server, daemon, or socket the probe starts uses a unique path under `/private/tmp`.
  - If the only mechanism is the shared default daemon, stop and report. Do not connect.
  - Do not isolate by copying `CODEX_HOME`; that would be credential copying.

**B3. The experiment assumes a prompt will produce a structured pending request**
- **Source:** Task 3 step 2 ("harmless prompt that asks one multiple-choice question").
- **Trigger:** The model may answer with a plain assistant message instead of a server-initiated question request. The question request type may also depend on a mode or feature setting.
- **Consequence:** No pending request exists, so Task 3 produces "inconclusive" for an incidental reason. Worse, someone could enable the needed setting in eD!'s persistent configuration, violating "do not change persistent settings".
- **Minimal correction:**
  - In Task 1, identify the exact server-request method used for user questions and the exact conditions that trigger it.
  - Only per-launch overrides scoped to the disposable session are allowed, and each one must be recorded.
  - If no deterministic trigger exists, use an approval request for a read-only command, under the session's normal or recorded per-launch policy, as the control evidence.
  - Record that the question type itself was not exercised.

**B4. "Supported" does not require the desktop to reflect resolution**
- **Source:** Task 3 step 3 ("Record whether the desktop surface also updates"); spec requirement "A resolved request becomes read-only immediately, including when another client answered it".
- **Trigger:** The second client answers, the server resolves the request, but the TUI keeps showing an answerable prompt.
- **Consequence:** The desktop could submit a duplicate answer, yet the run would still be classified as supported. That contradicts the spec's acceptance target, which rules out duplicate work.
- **Minimal correction:** Make it a pass criterion that the TUI drops or disables the prompt after a remote answer. If the TUI then accepts input, the outcome is "partially supported" and the exact behavior is recorded.

## Major (should fix before execution)

**M1. Identity correlation is achieved by construction, not demonstrated**
- **Source:** Task 3 "Interfaces" (claims host, amx, thread, turn, and request correlation); spec "Identity: reuse existing integration".
- **Trigger:** The probe launched both the amx session and the thread, so it simply "knows" they belong together.
- **Consequence:** The bridge plan will assume the hook's `providerSessionID` (from `session_id`/`sessionId` in `AgentHookPayload.swift`) equals the app-server thread ID. Nothing in this plan checks that.
- **Minimal correction:** Either capture the disposable session's hook `providerSessionID` and compare it with the protocol thread ID, recording equal, different, or unavailable. Or state explicitly that the correlation is by construction and leave hook association as an open item for the bridge plan.

**M2. Request ownership per connection is not tested**
- **Source:** Spec ("must be answered on its owning connection with its actual request ID"); Task 1 step 4; Task 3 step 3.
- **Trigger:** The server may deliver the request only to the connection that owns the turn, or broadcast it to every connection with different JSON-RPC IDs.
- **Consequence:** The second client may reply using an ID it never received. It is also unknown whether request IDs are reused after a reconnect, which is exactly how an "old reply reaches a replacement request".
- **Minimal correction:**
  - Record the request ID each connection receives.
  - The second client replies only with IDs delivered on its own current connection.
  - Key the stale-reply guard on `(connection incarnation, request ID)`, not on the request ID alone.

**M3. The `reply` outcome states mix up local writes and server resolution, and lose retry results**
- **Source:** Task 2 "Interfaces"; spec "Reliability" ("retain operation outcomes so a retry can report the original result").
- **Trigger:** `reply()` returns `resolved` synchronously, even though `serverRequest/resolved` arrives asynchronously. It has no outcome for a wrong-thread rejection, and keeps no record of past operations.
- **Consequence:** Tests can pass while hiding the difference between "written" and "resolved". A retry cannot report the original outcome.
- **Minimal correction:**
  - Outcomes become `rejected` (wrong thread, wrong incarnation, or outside the allowlist), `already_resolved`, `sent` (awaiting resolution), and `uncertain`.
  - Resolution is a separate state, set only from an observed `serverRequest/resolved`.
  - Keep an in-memory outcome map so a repeated `reply()` returns the stored result and writes nothing.

**M4. Some Task 2 fault cases test logic the probe does not have**
- **Source:** Task 2 step 2 ("remote versus local host identity", "two conversations sharing an amx UUID"); Plan self-review ("All five review-focus cases have Task 2 checks").
- **Trigger:** The `reply` signature takes no host or amx identity, and the probe uses a single local transport.
- **Consequence:** These tests either exercise invented scaffolding or pass vacuously, while the self-review claims the review-focus items are covered.
- **Minimal correction:** Remove the host and amx cases from the probe tests and record them as bridge-plan requirements. Alternatively, bind one `host_id` to `ProbeClient` at construction and test only "reject on mismatch". Correct the self-review either way.

**M5. The disposable amx session lives in eD!'s daemon and is addressed unsafely**
- **Source:** Task 3 steps 1 and 5; amx excerpt (`ZMX_SESSION_PREFIX` warning, `ZMX_DIR` inheritance).
- **Trigger:** The user's rc files export `ZMX_SESSION_PREFIX`, or the probe inherits a pane's `ZMX_DIR`.
- **Consequence:** Creating, killing, or checking the session could address a different name in eD!'s live daemon. `send` still exits 0, so the error is silent.
- **Minimal correction:**
  - Run every amx command through `env -u ZMX_SESSION_PREFIX`.
  - Set `ZMX_DIR` to a fresh directory under `/private/tmp`, so the session runs under a separate daemon.
  - Before stopping anything, verify the exact session name and socket path.
  - Trash that directory along with the project.

## Minor / optional hardening

- **O1. Live coverage of review focus #1.** In Task 3, start a second conversation in the same pane. Confirm a new thread ID and that the first conversation's request is not inherited.
- **O2. Stale reply after desktop resolution.** After desktop-first resolution, and only when no other request is pending in the disposable thread, send one deliberately stale reply with a harmless payload. Record the server's response. This turns the "local safeguard versus server guarantee" note into evidence.
- **O3. Process restart.** Restart the disposable Codex once. Verify that the old request ID is refused or ignored.
- **O4. Real traces in tests.** Replay sanitized traces captured in Task 3 through the Task 2 tests. This keeps the fake peer faithful to real behavior instead of to the author's model.
- **O5. Leftover artifacts.**
  - Trash `/private/tmp/awesomux-ios-codex-schema` too.
  - Note that the disposable thread may remain in eD!'s Codex history store; record it, do not delete it.
  - Hooks will run `awesoMuxAgentHook` for the disposable session; confirm this does not affect eD!'s awesoMux UI.
- **O6. Sanitization rules.** Define an allowlist of fields that evidence may keep: methods, ID shapes, abbreviated IDs, timings. Account or plan metadata from the initialize response is dropped.
- **O7. Version drift.** Record `codex --version` at both Task 1 and Task 3, in case the CLI updates in between.
- **O8. "Read the exact diff".** There is no Git repository, so there is no diff. Say "review the full created files" instead.
- **O9. Approved-spec edits.** Task 4 rewrites the approved design. Append a "Verified results" section with a link to the findings. Any change to a decision goes back to eD! for approval.
- **O10. Nested agents.** The constraint is listed but no task checks it. Either mark it deferred to the bridge plan, or record whether subagents appear as separate app-server threads.

## Verdict

**Revise before execution.** The scope, sequencing, no-PTY rule, and no-replay posture are sound. However:
- B1 and B4 could produce a false "supported" result.
- B2 could put eD!'s live conversations at risk.
- B3 could produce an "inconclusive" result for an incidental reason, or tempt a config change.

Fix B1–B4 and M1–M5, then re-review. The O-items are optional. No plan reviewer, including this one, has passed it.
