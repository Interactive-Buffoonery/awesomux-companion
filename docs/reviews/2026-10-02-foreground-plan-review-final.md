# Foreground plan affected-scope review

Date: 2026-10-02
Adapter/model: Codex subagent / gpt-6-sol
Skill: review-plan
Mode: read-only; only this report written.
Scope: current foreground plan changes for unsupported requests, unlocked bounded writes, upstream authentication, provenance, control identity, event generation, projection and local HTTP capability handling.

## Verdict

**One concrete P1 contract correction remains before implementing the asynchronous writer.** Other affected changes are addressed at plan level. This is a bounded loopback development procedure; no remote-production scope is requested.

## P1: outgoing queued replies must remain bound to their original connection

The revised plan explicitly generation-tags incoming events, but does not give queued outgoing work the equivalent guarantee. Reserving under a lock, releasing it, then submitting to a writer allows disconnect/reconnect to occur between reservation and emission. If a worker obtains the current proxy at write time, an old valid wire request ID can reach the new connection. A late writer completion can also overwrite a newer uncertain/resolved operation state.

**Trigger:** reply reserves generation A; writer blocks or submission is delayed; transport reconnects to B; writer resumes.

**Smallest fix:** Bind each queued submission to the original generation and exact owned proxy/pipe. Never retarget queued bytes to a replacement transport. Closing a generation cancels its unsent queue; reserved operations conservatively remain uncertain and are never replayed. Apply writer completion under the state lock only to its original operation/generation and never downgrade resolved/uncertain state using a late success. Add one blocked-writer → disconnect/reconnect → unblock test asserting zero bytes on the replacement peer and no stale completion overwrite. This is a small queue record/check, not another transport abstraction.

## Addressed affected scope

| Area | Assessment |
| --- | --- |
| Unsupported requests | Explicit zero-byte policy, including RPC errors, avoids accidentally resolving approvals |
| State responsiveness | Reservation under lock and bounded submission outside lock correctly remove network I/O from snapshot/event critical section |
| Upstream authentication | Separate protected capability, before-inference good/bad-token and Origin handshake gate, fail-closed semantics explicitly planned |
| Owned-runtime provenance | Managed launch record, endpoint/thread/project match and read-only cwd verification give this single-process development slice a concrete ownership check |
| Restart/reused IDs | Random process/connection/control identity and generation-tagged incoming events address stale controls and old callbacks |
| Completed projection | Resume rebuild followed by buffered events, authoritative keys, explicit bounds and omitted streaming are proportional |
| HTTP/token handling | Exact Host/Origin, auth before body, bounded framing, suppressed logs/errors, private exclusive capability-file creation are concrete |
| Prior uncertain attempt | Replay visibly preserves uncertainty rather than implying an earlier response failed |

## Small documentation correction

Task 1 states both best-effort signal cleanup and a guarantee of subprocess shutdown. Keep the best-effort wording and require observable teardown checks; SIGKILL cannot satisfy a shutdown guarantee. This does not require additional runtime machinery.

## Production honesty and scope

Actual installed auth behavior remains an execution gate, not a reviewer-certified fact. The provenance mechanism assumes the local current-user caller is trusted; it is appropriate here and is not an external trust/authentication service. No extra database, remote connectivity, provider layer or mobile functionality is warranted.

After binding queued replies and completions to their original generation/transport, proceed with implementation and its planned independent review. No further product decision is required.
