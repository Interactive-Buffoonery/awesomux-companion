# Codex Live Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a reproducible safe way to observe and answer a question in the same normally launched Codex session inside amx, or identify the missing capability precisely.

**Architecture:** Inspect the installed protocol before building a bridge or phone app. Probe a disposable normal Codex TUI with a second client. Fake-peer checks prove local guards; only the isolated real runtime establishes server guarantees.

**Tech Stack:** Installed Codex CLI, amx, Python 3 standard library and generated JSON Schema; no new dependencies.

**Spec:** [Approved companion design](../../companion-v1-design.md). This plan implements delivery step 1 only. The bridge, SwiftUI, APNs and creation plans follow the verified control contract.

## Global Constraints

- No terminal, break reminders, or broad provider support in this first scope.
- Codex credentials and execution remain on the host.
- Absent identity means unassociated, never guessed from cwd.
- Never replay an uncertain response blindly.
- Preserve Codex's approval policy, sandbox, plugins, and configuration. No persistent settings changes or copied `CODEX_HOME`/credentials.
- No active user-session mutation, connection to a shared default daemon, global daemon changes, remote-control enablement or paid native CI.
- Every probe-owned project/socket/amx `ZMX_DIR` lives in a unique root under `/private/tmp`. Every amx command uses `env -u ZMX_SESSION_PREFIX` and that explicit `ZMX_DIR`.
- Delete disposable artifacts with `trash`. There is no Git repository: review full created files and preserve content hashes, not imaginary commits or diffs.

## Review Focus

- False reuse: specially launched sessions must not count as control of the normal TUI.
- Shared runtime exposure: no connection, content logging or replies to existing user threads.
- Reused request IDs after reconnect: stale references must not address replacement requests.
- Desktop/client race: local suppression does not prove server-wide arbitration.
- Lost acknowledgement: outcome stays uncertain; authoritative recovery precedes any retry.

Remote/local backend association, successive conversations sharing amx and nested-agent parent suppression belong to the later bridge plan. This probe reports hook identity comparison if safely observable, without claiming those registration guarantees.

## Files and Flow

- Create `docs/codex-live-control-findings.md`: versions, exact launch/transport, sanitized evidence, outcome and next decision.
- Conditionally create `probes/codex_control_probe.py`: minimal schema-shaped client for an established candidate.
- Conditionally create `probes/test_codex_control_probe.py`: one stdlib runnable local-guard check.
- Append verified results to `docs/companion-v1-design.md`; preserve approved decisions.

```text
normal Codex TUI in isolated amx -> owning runtime -> pending request
                                      |
                           supported private connection?
                                      |
                             allowlisted ProbeClient
                                reply / resolution
```

### Task 1: Identify the supported live-control surface

**Interfaces:** Consumes installed help, generated schemas and version-matched source; produces exact wire shapes, ownership evidence and the gate decision.

- [ ] Read local workflows and referenced awesoMux hook/identity source. No awesoMux source edits are part of this probe.
- [ ] Capture `codex --version`, `codex --help`, `codex app-server --help` and `codex app-server proxy --help`. Generate schemas with `codex app-server generate-json-schema --out <unique-root>/schema`. Inspect initialization, live subscription, pending-request discovery/recovery, responses, JSON-RPC errors and resolution events.
- [ ] Trace normal installed TUI ownership in official documentation or version-matched source, recording source version. Distinguish history access and `thread/resume` in another runtime from the original live runtime.
- [ ] Identify the structured-question method and its mode/capability prerequisites. Only recorded per-launch question-generation overrides are allowed; do not change sandbox/approval policy. If no supported question trigger exists, a harmless read-only approval under unchanged policy may establish approval control, but not question support.
- [ ] **Gate:** no supported candidate means skip Tasks 2-3 and finish Task 4 with exact interface/version evidence. Shared-default-daemon-only access means do not connect and record an isolation limitation, not unsupported control. A special launch means return that product decision to eD! before exercising it. If ownership remains uncertain, permit only the smallest isolated observation needed to resolve it before reply-client scaffolding.

### Task 2: Verify local reply guards for the candidate

**Interfaces:** Bind one `ProbeClient` to the disposable thread allowlist and a unique connection incarnation. Define immutable `PendingRequestRef(connection_incarnation: str, request_id: str | int, thread_id: str, turn_id: str | None)`, `handle_message(message: dict) -> None`, `reply(ref: PendingRequestRef, result: dict) -> str` and `disconnect() -> None`. Optional turn ID is allowed only if that inspected request type lacks it. Create references only from requests actually delivered on this client's current connection, never from desktop-only IDs.

`reply` outcomes are `rejected`, `already_resolved`, `sent` and `uncertain`. Keep a small in-memory outcome map keyed by the full reference: repeated attempts return stored state and write nothing. Request resolution updates state asynchronously; it does not prove this client won. Reconnect changes incarnation, invalidates old references and recovers requests only through verified authoritative protocol support.

- [ ] Write `probes/test_codex_control_probe.py` with `unittest`, a fake line-oriented peer and installed-schema-shaped fixtures. Assert exactly the required response fields. Thread/turn/incarnation are local checks, not extra wire fields unless the protocol requires them. Unknown/malformed request methods/shapes produce no reply.
- [ ] Assert out-of-allowlist requests are dropped without content logs; wrong thread/incarnation writes nothing; identical RPC/thread/turn IDs reused after reconnect reject the old reference; resolved/repeated replies write nothing; disconnect after write yields uncertain with no replay. Sequential desktop-resolution delivery tests only local suppression.
- [ ] Run `python3 probes/test_codex_control_probe.py` and observe failure for the absent client. Implement the minimum stdlib client and rerun to green. No host/amx routing scaffolding for tests outside this probe's scope.
- [ ] Bound startup/read operations to 30 seconds, question generation to 120 seconds and each JSON line to 1 MiB. EOF, timeout, oversized/malformed JSON or RPC errors produce an explicit observation and controlled teardown. These are probe bounds, not product limits.
- [ ] Review complete created files; record fixture provenance and separate local safeguards from server guarantees.

### Task 3: Exercise same-runtime control safely

**Interfaces:** Consumes the normal-launch candidate and guarded client; produces independent runtime/request ownership, TUI-resolution and recovery evidence. Constructed identity is not hook-correlation evidence.

- [ ] Recheck CLI version; if changed, regenerate/reinspect before running. Create a unique temporary project, amx namespace and socket root. Verify installed amx commands. Scrub inherited `AWESOMUX_AGENT_*`, `AWESOMUX_PANE_ID` and `AWESOMUX_SESSION_ID` for the disposable process so hooks cannot write to a real pane; global plugin installation stays unchanged.
- [ ] Launch the normal Codex TUI as the pane process, recording exact command and every override. No separately started server may silently become its owner. A private endpoint selector is acceptable only if source proves it retains normal ownership semantics; otherwise use the special-launch decision gate. All owned endpoints live under the unique root. If normal launch would use the shared/default daemon, stop before launch with an isolation limitation.
- [ ] Capture the disposable thread ID from its authoritative launch/event output before constructing the allowlist. If unavailable without unrelated-thread access, stop with an identity-discovery limitation. Record actual `ZMX_SESSION`; compare hook `providerSessionID` with protocol thread ID if safely available, otherwise explicitly leave hook association unverified and label any correlation by construction.
- [ ] Trigger one real structured question through the inspected mode/tool, writing no project files. No pending request by the deadline is **question-generation inconclusive**, not unsupported attachment. Read-only approval evidence is **approval-only**, not question support.
- [ ] Connect only to the verified private endpoint. Record request IDs received on each connection; reply only with this connection's own reference. Require authoritative resolution, original-runtime continuation and removal/disabling of the desktop question for full success. Still-answerable desktop prompts mean partial support. Record whether the winning responder can be identified; resolution alone never establishes our answer was accepted.
- [ ] Exercise desktop-first resolution and reconnect with a pending question. No authoritative recovery means disabled controls and a capability gap. Verify server-wide competing-response arbitration through exact source or a safe isolated test; sequential notification handling alone leaves it unverified and prevents a full companion-ready verdict.
- [ ] Guarantee `finally` cleanup on success/failure/interruption: close owned client, stop only recorded owned PIDs/session after verifying exact namespace/socket/name; never broad-kill Codex/amx. Verify teardown, report exact owned artifacts if it fails, and trash the temporary root/schema only after teardown. Record disposable history entries left behind; do not delete user history.

### Task 4: Close the feasibility decision

- [ ] Record separate attachment, question-generation, reply-ownership, desktop-resolution, recovery and arbitration outcomes. Overall verdict: **supported and exercised**, **partially supported**, **supported only with non-default launch**, **unsupported by inspected interfaces**, or **inconclusive** with exact reason. Full support requires every normal-launch live-question criterion; approval-only is partial.
- [ ] Evidence allowlist: methods, required response-field shapes, abbreviated IDs, versions, timing and outcomes. Drop transcript/question content, credentials, account/plan metadata and unrelated-thread data.
- [ ] Append a verified-results link to the approved design without rewriting decisions. Obtain independent review of actual probe/evidence, resolve blocking findings and rerun affected checks. Eventual PRs additionally require all publication review gates.
- [ ] Proven normal control permits the next foreground bridge plan using that exact contract. Non-default launch requires eD!'s product decision; isolation/generation failures require missing evidence, not an unsupported claim. No UI/push scaffolding while control remains unsettled.

## Failure Responses

| Failure | Trigger | Response / final state |
| --- | --- | --- |
| Shared runtime | Only default daemon available | Do not connect; isolation-limited finding |
| Special launch | New owner/launch required | Decision gate; no false reuse verdict |
| Missing question | Ordinary text or timeout | Generation inconclusive; no reply |
| Stale identity | Missing fields or reused IDs | Reject; disabled controls |
| Protocol failure | Invalid/empty JSON, error, EOF or limit | Record failure; controlled cleanup |
| Competing answer | Desktop resolves first | Clear controls; winner unknown unless proven |
| Lost acknowledgement | Disconnect after write | Uncertain; no replay |
| Cleanup failure | Owned resource survives | Record exact artifact; no cleanup-complete claim |

## Review Incorporation and Self-Review

Initial reviews: [plan skill report](../../reviews/2026-10-02-plan-review.md), [Claude Opus 5.5 adversarial report](../../reviews/2026-10-02-claude-adversarial.md). Both required revision. This revision addresses all blocking/major findings: incarnation-bound references, exact wire/local separation, early stop gates, question prerequisites, normal-launch honesty, daemon/thread isolation, desktop resolution, hook-correlation honesty, connection ownership, asynchronous outcomes, proportional tests and isolated amx addressing.

Optional hostile stale-response experiments and real remote deployment are not added. Only delivery step 1 is covered; registration/nesting/remote routing remain bridge-plan requirements. Review-focus cases are gated in Task 1, guarded in Task 2 or measured in Task 3; mocks never establish server guarantees. Both affected reviews must refresh before execution.
