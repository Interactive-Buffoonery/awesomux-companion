## Architecture Review

**Proposal:** Codex Live Control Implementation Plan, against approved companion design.  
**Reviewer:** Codex subagent, explicit model `gpt-6-sol`, read-only `review-plan` skill.  
**Clarity rating:** **FORMING**  
**Recommendation:** Refine the probe contract, then proceed. No product architecture rethink required.

Read the complete plan/spec, `AgentHookPayload.swift`, `AgentHookCommand.swift`, relevant amx identity documentation, installed app-server help, and [official app-server documentation](https://learn.chatgpt.com/docs/app-server). No implementation or live session mutation performed.

### System Diagram

```text
amx disposable container
  └─ Codex desktop/TUI ── owning runtime ── pending server request
                              │
                    supported second connection?
                              │
                         ProbeClient
                              │
            reply original RPC ID → authoritative resolution
```

The unresolved edge is deliberately the subject of the experiment. Good scope choice.

### Blocking Findings

**P1 — Task 2 specifies safeguards its public interface cannot express.**  
`reply(request_id, thread_id, turn_id, result)` provides no expected connection incarnation or host identity, while tests require rejecting old-incarnation and remote/local collisions. If reconnect reuses an RPC ID and the same thread/turn, a caller holding an old request can inadvertently address the replacement.

**Exact fix:** Capture a pending-request reference containing the connection incarnation, host namespace, original RPC ID, thread and turn; require that reference when replying, or add expected incarnation/host arguments to the existing method. Validate against the pending record immediately before the single write. Keep this tiny and in-memory. Test an identical ID/thread/turn reused after reconnect and across two host namespaces. These are local guards, not proof of server-wide arbitration.

**P1 — The fake peer may “prove” a protocol invented by the probe.**  
Task 2 says a reply “carries the original RPC ID and correct thread/turn,” but a JSON-RPC response need not carry thread/turn on the wire. Those identifiers may only be local correlation from the server’s original request. The plan otherwise correctly promises schema-derived shapes.

**Exact fix:** Explicitly separate exact schema-shaped wire response from local validation metadata. Capture fixtures from generated schemas/version-matched examples; assert the wire contains precisely the required response fields. Do not add host, incarnation, thread or turn to the response unless the inspected protocol requires them. Document request-specific response results and JSON-RPC errors separately.

**P2 — The “unsupported” branch still appears to require unnecessary client implementation.**  
Task 1 says stop the *real attachment portion* if no supported candidate exists, yet Task 2 remains unconditional. That spends time implementing a client for a transport that may not exist and risks using mocks to conceal the result.

**Exact fix:** Make Task 1 an explicit gate: if no candidate exists, skip Tasks 2–3 and complete Task 4 with source/version evidence and the companion-managed alternative. If ownership remains unknown, allow only the minimal experiment needed to distinguish it before building reply machinery.

**P2 — Request generation is underspecified.**  
A harmless prompt asking for a multiple-choice question can produce ordinary assistant text rather than an actual server-initiated pending request. A timeout could therefore be misclassified as unsupported attachment.

**Exact fix:** Record the precise request tool/mode/capability prerequisites before Task 3. Use a bounded prompt that invokes that supported mechanism. If no structured request occurs within the deadline, classify **question-generation inconclusive**, separately from **second-client attachment unsupported**. Never weaken approval/sandbox policy to force the test.

**P2 — Real race evidence currently verifies only a resolved-state observation.**  
“Desktop-first resolution” followed by observing `serverRequest/resolved` tests notification propagation and stale local suppression. It does not establish what happens when two clients already emitted competing valid responses before receiving that notification.

**Exact fix:** Distinguish (a) deterministic fake-client local serialization, (b) sequential desktop-first suppression, and (c) actual server-wide arbitration. Test (c) in an isolated bounded experiment if the protocol safely permits it, or explicitly mark server arbitration unverified. Avoid claiming “only first valid reply takes effect” from (a)/(b).

### Failure Modes

| Failure | Trigger | User impact | State afterward / response | Handled? |
|---|---|---|---|---|
| Wrong pending request | Same amx session starts another conversation | Misrouted answer | Reject using authoritative thread/request identity | Planned |
| Reused request identity | Reconnect/restart reuses IDs | Old answer reaches new request | Incarnation-bound pending reference | Gap P1 |
| Wire mismatch | Local metadata inserted in RPC response | Protocol failure or false test confidence | Exact schema-shaped response; local checks separate | Gap P1 |
| No structured question | Model emits text | False infeasibility result | Bounded timeout; classify generation separately | Gap P2 |
| Double emission | Desktop and client reply concurrently | Duplicate/unintended action | Verify server arbitration; local locks insufficient | Gap P2 |
| Lost acknowledgement | Disconnect after write | Unknown outcome | Remain uncertain; no replay | Planned |
| Missing recovery API | Reconnect with pending request | Cannot safely recover controls | Report capability gap, disable reply until authoritative recovery | Planned |
| Cleanup interrupted | Timeout/exception during probe | Disposable process/session survives | `finally` cleanup of owned IDs/PIDs; cleanup verification on failure too | Needs explicit wording |
| Malformed/oversized input | Peer outputs bad JSON/large line | Crash/hang | Bounded line read, reject malformed input, deadline and controlled teardown | Partially planned |

### Hidden Assumptions

| Assumption | Classification | Risk if wrong |
|---|---|---|
| Installed protocol supports second-client access to TUI runtime | Verifiable, intentionally unresolved | No existing-session companion path |
| Second client sees and can answer requests owned by desktop connection | Verifiable | Observation works but replies do not |
| `serverRequest/resolved` reaches interested clients | Verifiable | Phone cannot safely update controls |
| Pending requests can be recovered authoritatively | Verifiable | Reconnect must invalidate controls |
| Prompt reliably generates a structured question | Hopeful until capability/mode specified | False unsupported outcome |
| Host identity exists for this isolated probe | Not yet specified | Remote/local check becomes arbitrary fake metadata |
| Existing nested-agent suppression covers all providers/nesting | Unverified | Parent identity replacement if later registration expands |

Existing helper explicitly suppresses Codex under `CLAUDE_CODE_CHILD_SESSION=1`; that supports one case, not a general nested-agent guarantee. No helper change is required for this probe.

### Shadow Paths

- **Identity:** missing/empty identity → leave unassociated; correct existing rule.
- **Protocol:** missing fields, empty questions/options, unknown method and JSON-RPC error → reject/report; do not invent defaults or send replies.
- **Attachment:** unreachable socket/closed process → distinguish connection failure from unsupported ownership.
- **Resolution:** absent/late acknowledgement → uncertain; request disappearance alone must not imply this client’s answer was accepted.
- **Recovery:** no pending state API → stale/disabled controls; no replay.

### Unfinished Thoughts

Add explicit maximum startup/question/read deadlines and guaranteed cleanup on failures. Inspect source/version before asserting wire fields. Specify how “resolved” differs from “our answer accepted”: another client may win and still produce the same resolution event.

### Second-System Check

The four-file ceiling and deferral of host service, UI, APNs and session creation are proportional. Make the no-candidate stop gate real. Remote identity coverage should be two synthetic namespaces, not an actual remote deployment.

### Production Readiness

All proposed code is an isolated feasibility probe. Local safeguards are reusable evidence, not production bridge implementation or physical-device acceptance. Preserve this distinction in findings.

### Framing Falsification

Cheapest falsifier: supported second client connects to a disposable TUI-owned runtime, observes the same pending request, answers it and the original runtime continues. A fresh app-server followed by `thread/resume` is not that experiment. Until exercised, ownership remains unverified and clarity stays FORMING.

### Recommendation

Fold in the two P1 contract corrections and bounded Task 1 gate before implementation. Add the P2 evidence distinctions to prevent false positive/negative results. Then proceed with inspection first; no additional user product decision is needed unless existing-session control proves unavailable.
