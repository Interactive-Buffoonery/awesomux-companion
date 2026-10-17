# Foreground bridge implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expose one owned companion-managed Codex thread as a local snapshot with safe question responses and reconnect behavior, ready for a Simulator client.

**Architecture:** A Python stdlib host process owns a single WebSocket connection through the installed Node helper. Its HTTP surface binds only to IPv4 loopback and requires an ephemeral bearer capability. It attaches only to an explicitly supplied, newly managed thread ID; it never discovers or attaches existing user sessions. One locked state owner reserves replies; writes occur outside its lock through a bounded writer queue. The upstream Codex listener also requires a separate ephemeral capability token, read by the Node helper from a protected file and sent as an Authorization header. Installed Node custom-header support was verified in a disposable handshake. The native client, network access, APNs and session launching are separate subsequent slices.

**Tech Stack:** Python 3 stdlib, installed Node WebSocket; no dependencies or configuration changes.

**Spec:** docs/companion-v1-design.md and docs/codex-live-control-findings.md.

## Global constraints

- No terminal UI, break reminders, shared daemon access, global config changes or copied credentials.
- Preserve Codex policies and host authentication. Only requestUserInput is answerable; approvals remain unsupported.
- One known host/project, one allowlisted thread. This is a local development service, not phone-ready transport.
- No listeners beyond loopback. No HTTP request or transcript logs. Tokens generated at runtime, not command-line arguments or repository files.
- Non-Git workspace: no commit/publication; future publication still needs full review gate.

## Flow

Native-client successor -> authenticated loopback HTTP -> locked bridge state -> one Codex protocol peer.
Protocol question/resolution/message events -> bridge snapshot. Reconnect clears pending controls, changes generation, resumes allowlisted thread, and restores controls only from replayed requests.

## Review focus

- Duplicate/competing reply: one write, cached operation outcome; resolution does not identify winner.
- Connection loss after write: uncertain outcome, no automatic resend.
- Reused IDs after reconnect: opaque control ID includes connection generation; stale controls reject.
- Malformed/unsupported upstream fields: no writable controls; visible unsupported capability flag.
- HTTP unauthorized/foreign Origin/oversized requests: reject before state changes, no permissive CORS.

### Task 1: State owner and protocol transport

**Files:** `bridge/state.py`, `bridge/transport.py`, `bridge/test_state.py`.
**Interfaces:** `BridgeState(thread_id)`, `apply(generation, message)`, `snapshot()`, `answer(control_id, operation_id, answers, write)`, `disconnect()`; state methods synchronize with one RLock. Under the lock, reserve each control for its first valid operation before write, then release the lock for bounded writer submission; never free the reservation on uncertain writes. Same operation/same normalized payload returns cached outcome (submitting immediately while in flight, with no enqueue); same operation/different payload conflicts; different operation on reserved control writes nothing. Each process and connection uses a fresh random nonce; control IDs are random server-created capabilities, never derived from wire request IDs. `apply(generation,message)` drops old-generation events. Snapshot returns generation, connection status, messages, pending supported questions, freshness timestamp and response outcomes. JSON contents never include token, raw request IDs, answers or unrelated threads. Store canonical answer digests for operation conflict checks; cache only valid, live-control submissions. Answers require exactly the question IDs and nonempty string arrays; option answers require matching labels unless isOther=true, while absent/null options permit free text. Validate optional isOther/isSecret booleans. Secret questions stay unsupported/read-only in this slice; do not retain or echo their answers. Replayed question with prior uncertain attempt (turn/item identity) is visibly marked prior_attempt_uncertain.

- [ ] Write failing tests for foreign threads, malformed input, question resolution, duplicate operations, conflicting operation reuse, distinct-operation concurrent answers, a new operation after uncertain write, stale control IDs, lost write and reconnect replay; disjoint control IDs across separate process instances; old-generation events ignored; snapshot/event application stays responsive while a fake writer blocks.
- [ ] Implement minimal state owner, reusing reviewed guard semantics rather than importing experimental runner lifecycle. Bound message history to 200 completed/message entries and pending controls to 32; overflow disables controls with an explicit error rather than silently dropping unresolved state. Bound operation outcomes to 256; on overflow reject further operations rather than evict retry evidence.
- [ ] Project only completed `userMessage` text content and `agentMessage.text` from `thread/resume.thread.turns[].items` and `item/completed` (`threadId`, `turnId`, `item`). Rebuild from resume response for each generation before applying buffered live events. Key by `(turnId,item.id)` and update on replay; omit nontext content and streaming deltas with an explicit completed-text-only capability. Bound each text to 16 KiB and show truncation. Resume history is limited to the returned recent slice; pagination is not implemented. Test resume history followed by repeated completion and reconnect update without duplicate entries. Installed 0.160.0 generated schemas inspected for these fields.
- [ ] Implement subprocess Node WebSocket transport with JSON line bound 16 MiB, experimental initialize and allowlisted thread/resume. Initialize/resume deadlines are 30 seconds. Each queued envelope carries the original generation and immutable proxy identity; it may write only to that proxy, never a current-connection getter. Disconnection cancels untouched envelopes, conservatively marks submitted/partial envelopes uncertain and never redirects them. Writer completions apply only to their original operation/generation and cannot downgrade resolved state. Test a delayed queued answer and delayed completion across reconnect with repeated wire IDs. The dedicated writer uses a bounded queue and nonblocking pipe writes with a finite deadline; enqueue/partial-write failure is conservatively uncertain, never replayed. No network I/O while holding state lock. Proxy stderr is discarded; stdin EOF terminates its owned WebSocket and process. Signal cleanup is best effort, not a SIGKILL guarantee. EOF/error disables controls; a quiet connected reader alone does not. No invented heartbeat. Test idle pending controls remain usable. Thread reader joins/stops only its owned proxy. Retry reconnect with capped backoff; no automatic answer replay. Signal handling performs best-effort owned subprocess shutdown.
- [ ] Unsupported, malformed, missing-thread and foreign-thread server requests receive zero bytes, including JSON-RPC error replies. Initial capabilities omit connection-bound verification support. Test unsupported approval with zero writes; initialize only experimentalApi.
- [ ] Run unit checks and read complete diff; failure-path assertions must precede success claims.

### Task 2: Local HTTP adapter

**Files:** `bridge/server.py`, `bridge/test_server.py`, `bridge/README.md`.
**Interfaces:** GET `/v1/thread` returns state; POST `/v1/answers` accepts opaque control ID, caller operation UUID and answers map. Only explicit supported fields accepted. Body limit 64 KiB, finite header/body read timeout, JSON content type. Server start requires a protected managed-launch provenance record and matching literal ws://127.0.0.1:<port> endpoint and exact owned thread; checks occur before transport creation; generates an ephemeral HTTP token (distinct from Codex token) and chosen HTTP port, and writes them only to a mode-0600 local file inside explicitly supplied private temporary directory for native-development access. Resolve directory alias first, require lstat directory owned by current uid with mode 0700, open it without following symlinks and create capability files using O_CREAT|O_EXCL|O_NOFOLLOW, mode 0600, dir_fd; never overwrite an existing file. Caller owns trashing the token directory after shutdown; service does not unlink files; no token displayed in console.

- [ ] Write failing integration tests with fake protocol transport for missing/wrong auth, Origin/Host restrictions, oversized/malformed body, unknown control, duplicate operations and connection loss. Bind an ephemeral loopback port locally only.
- [ ] Implement handlers with exact method/path checks, constant-time bytes token comparison; authenticate before reading body; require Content-Length and reject Transfer-Encoding; no CORS, reject any Origin header, exact loopback Host/port check. Return bounded errors without echoing tokens or raw exception details. Disable default request logs and handle_error traceback output. Responses use explicit JSON Content-Type and Cache-Control: no-store. Bind port 0 and require Host exactly 127.0.0.1:<chosen-port>.
- [ ] Document explicit managed launch/environment scrubbing, foreground-only access, unsupported approvals, token lifecycle, operation semantics and teardown. Verify caller trashes owned token directory after service shutdown.

### Task 3: Real isolated smoke and independent review

- [ ] Add `bridge/launch_probe.py` for managed smoke provenance: spawn a fresh server with --ws-auth capability-token --ws-token-file <private-file>, and a separate protected provenance record containing owned PID, exact endpoint, project path and thread ID returned from its own thread/start. Bridge accepts only matching provenance and performs thread/read with includeTurns=false to check cwd before thread/resume (payload threadId only, no policy/model overrides). Fake tests reject endpoint/thread/project mismatch and check exact resume payload.
- [ ] Reuse a fresh separately launched server with scrubbed awesoMux/ZMX routing environment and a newly created disposable thread. No shared daemon or existing-server connection. Record launch env key names, ownership PIDs and cleanup, never env values or credentials.
- [ ] Before inference verify correct-token-plus-Origin upgrade and missing/wrong-token upgrades reject; correct-token Node initialize succeeds. No unauthenticated upstream listener is permitted. Fail closed if installed auth semantics differ.
- [ ] Produce a real question; GET pending state, POST one answer, observe resolved state and completed response through the same bridge. Drop transport with another pending question; also stop proxy immediately after submission and record uncertain state without resend; confirm stale control rejects and replay restores a new control.
- [ ] Stop exact owned runtime; verify amx absence only on successful listing, verify endpoint closed, trash private temp/token after retaining non-sensitive results. Leave user history untouched.
- [ ] Run independent final implementation review, resolve concrete findings, rerun affected checks. Record explicit model/scope and limits. No claim of phone, hook correlation, notifications or ordinary-session takeover.

## Failure responses

| Trigger | Response |
| --- | --- |
| Upstream closed/timeout | disconnected snapshot; disable controls; bounded reconnect |
| Pending request resolves elsewhere | remove control; cached submitted remains distinct from accepted |
| Write fails | uncertain operation; no resend |
| Host process restarts | new generation/token; prior controls invalid |
| State/line/body bounds exceeded | explicit error, controls disabled; no silent retry |
| Unauthorized HTTP | reject before protocol action |
| Unsupported approval | visible capability gap; desktop resolution |

No private remote access mechanism is selected here. Exposing this loopback service remotely requires a separate reviewed authenticated transport decision.
