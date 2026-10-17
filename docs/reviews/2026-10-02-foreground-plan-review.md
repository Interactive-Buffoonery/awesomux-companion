# Foreground bridge architecture review

Date: 2026-10-02
Adapter/model: Codex subagent / gpt-6-sol
Skill: review-plan
Scope: foreground-bridge plan, approved companion design, live-control findings, existing ProbeClient and Node WebSocket helper. Read-only review; this report is the only file written.

**Clarity: FORMING. Recommendation: refine the three concrete contracts below, then proceed.** This is a loopback development bridge review, not a remote/mobile production review.

## System diagram

```text
authenticated local HTTP client
  GET snapshot / POST opaque control + operation + answers
                    |
             locked BridgeState
                    |
        owned Node WebSocket subprocess
                    |
     explicitly owned app-server + one thread
```

The boundary and limited scope are sound. Keeping approvals unsupported, skipping networking/APNs, using a single state lock and avoiding experimental runner lifecycle reuse are proportionate.

## Findings and smallest fixes

### P1 — One-operation deduplication is not the same as one-control consumption

Task 1 caches operation outcomes, but does not finish the state contract for a second operation UUID targeting the same question while the first is sent or uncertain. The reviewed ProbeClient guards by request reference; the new HTTP adapter introduces a second identity. Merely caching by operation UUID permits a different UUID to write the same pending control again.

**Trigger:** two callers submit distinct operation UUIDs before server resolution, or one retries an uncertain answer under a new UUID.

**Impact:** duplicate write despite the stated one-write guarantee.

**Smallest fix:** Under the same RLock, reserve the control for its first valid operation before invoking write. Cache operation identity together with control and normalized answers. Same UUID/same payload returns stored outcome; same UUID/different payload conflicts; a different UUID for an already reserved control writes nothing and reports already submitted/uncertain. Do not release reservation on uncertain writes. Test distinct UUIDs racing for one control and a new UUID following a failed write. No durable database is needed for this process-scoped capability.

### P2 — The message snapshot contract lacks a concrete protocol projection

The goal includes thread messages, but Task 1 only names generic message events and completed/message history bounds. It does not specify what `thread/resume` history and streaming item events project into the snapshot, or how replay avoids duplicating/upsetting entries. The existing ProbeClient only handles questions and resolution, so message projection is genuinely new behavior.

**Trigger:** resume returns prior items and a live event updates/replays the same item; assistant text arrives in chunks.

**Impact:** blank history, duplicate messages or incorrect displayed text after reconnect, while question tests still pass.

**Smallest fix:** Inspect installed resume/item schemas and define the minimal supported user/assistant text projection. Key entries by authoritative item identity (and turn where necessary), update rather than append on replay, and explicitly state whether text deltas are supported or only completed text. Prefer completed text for this slice if sufficient. Test one resume-history fixture plus its repeated completed event and one reconnect update. Unsupported item types can stay omitted with the documented capability limitation.

### P2 — Connection timeout versus ordinary idle time is ambiguous

Task 1 says timeouts disable controls and retry reconnect, without defining which operations have deadlines. An app-server conversation can legitimately remain silent while the user thinks; treating a quiet reader as failed rotates generation and invalidates the pending control repeatedly.

**Trigger:** question stays unanswered or completed session is idle longer than read timeout.

**Impact:** valid question controls repeatedly expire; unnecessary reconnects.

**Smallest fix:** Apply finite deadlines to initialize/resume and proxy shutdown. Idle connected reads alone do not constitute failure; use transport close/error, or an actually supported heartbeat with its own explicit failure condition. Keep HTTP socket read timeouts distinct. Add a small idle-state test showing a pending question remains usable absent a transport failure.

## Failure modes

| Failure | Trigger | Post-failure state and response | Coverage |
| --- | --- | --- | --- |
| Duplicate control write | Different operation UUIDs for one unresolved control | First reservation retained; subsequent writes rejected | Contract correction P1 |
| Lost write acknowledgement | Transport closes after submission | Uncertain outcome retained; control never resent automatically | Planned |
| Old generation control | Reconnect/restart | Reject old control; replay creates fresh identity | Planned |
| Foreign thread | Upstream message for other thread | Drop without content logging or controls | Planned |
| Unsupported approval | Approval request arrives | Visible capability gap; desktop guidance; no reply | Planned |
| Duplicate message replay | Resume plus repeated item event | One authoritative projected message | Contract correction P2 |
| Idle mistaken for failure | No events while awaiting user | Remain connected without arbitrary invalidation | Contract correction P2 |
| Capacity exhaustion | Pending/outcome bound reached | Explicit disabled/error state; retained evidence | Planned |
| Unauthorized/malformed HTTP | Wrong capability, Origin, Host, fields/body | Bounded error before any state mutation | Planned |

## Hidden assumptions and shadow paths

- Owned endpoint and thread are supplied correctly: verifiable through managed launch/smoke; do not treat caller-supplied thread ID alone as proof of ownership.
- Pending replay remains authoritative: exercised for the managed runtime; schema/version must still match the installed CLI.
- HTTP GET can return cached history during disconnect: acceptable when freshness and disconnected status remain explicit and controls are absent.
- Empty/malformed answers, missing fields and unknown controls must produce no write; tests already call for input validation.
- Upstream malformed/unsupported items must not become writable controls; unsupported capability reporting is explicitly planned.
- Token creation/cleanup failure must be reported honestly. The plan's mode/private-path checks and no-overwrite rule are appropriate; no new credential store is needed.

## Unfinished thoughts

Answer reservation, text projection and idle timeout semantics are the only implementation-blocking gaps identified. The HTTP adapter should document its actual response codes/outcomes alongside implementation; an elaborate error taxonomy is unnecessary.

## Proportionality and production honesty

The six implementation/test files plus README are reasonable for separating state, transport and HTTP. This process intentionally has bounded in-memory outcomes and one thread. Restart rotates capability/generation, so durable retry storage and multi-host routing are unnecessary here. Do not add real remote deployment, APNs, generalized provider interfaces or extra transport adapters.

## Framing falsification

The controlled managed-runtime smoke is the right falsifier: real question → GET → POST → same-turn resolved/completed state, then transport drop/replay. It must remain explicitly a separately owned runtime experiment; it does not establish normal-session takeover or mobile transport.

## Recommendation

Fold in the three small contracts above. Then implement the foreground slice and independently review its actual protocol projection, reply reservation and HTTP behavior. No additional product decision is required for this authorized loopback scope.
