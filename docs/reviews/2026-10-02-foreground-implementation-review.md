# Foreground bridge final implementation review

Date: 2026-10-02
Adapter: Codex collaboration subagent, independent fresh context, read-only product inspection.
Configured model: `gpt-6-astra`, high reasoning, per parent dispatch metadata. The tool did not independently expose provider/runtime identity; no stronger runtime attestation is claimed.
Workspace: `/Users/edequalsawesome/Development/awesomux-ios`, non-Git.

## Verdict

**Changes required: three reproduced implementation defects and missing required failure-path validation.** Nine current deterministic tests pass, but do not exercise the defects below. No source, tests, configuration, or product documents were changed; this report is the sole written artifact.

## Blocking findings

### F1 — P1: retire a pipe after a partial writer failure

Location: `bridge/transport.py:47-64`.

The writer catches a partial-write error or deadline, sets only that envelope's error, then continues processing the queue on the same pipe. Node readline retains the incomplete first JSON line. The next envelope therefore appends to that prefix, corrupting framing. It can be reported submitted even though the combined line is invalid, and requests can remain stuck on an apparently connected bridge.

A deterministic mocked-pipe reproduction wrote the first three bytes of `{"id":1}\n`, raised OSError on the remaining bytes, and queued `{"id":2}\n`. Observed write calls were the full first line, its remainder, and the full second line; envelope 1 had error=True while envelope 2 had error=None. This proves continued use of a poisoned framing stream without launching a process.

Smallest correction: any writer error after possible bytes invalidates this owned connection, rejects/cancels all untouched queued envelopes, and makes the reader/reconnect path observe failure. Never continue another envelope on that pipe. Leave affected operations uncertain and do not resend. Add a deterministic partial-write-plus-next-envelope check.

### F2 — P2: reject oversize encoded answers before reserving an operation

Location: `bridge/state.py:153-178`, `bridge/transport.py:36-45`, `bridge/server.py:47-50`.

The HTTP body and per-answer character checks admit answers that become larger than the transport's 64 KiB limit after default JSON ASCII escaping. `ProxyConnection.write` raises ValueError; BridgeState catches only OSError/EOFError/TimeoutError, leaving the new control/operation permanently submitting. The HTTP adapter returns invalid_request even though the operation has been reserved. Same-operation retries report submitting and a corrected answer conflicts.

Reproduced with one free-text answer containing 6,000 emoji: complete UTF-8 HTTP body was 24,143 bytes; transport raised `ValueError: outgoing line limit`; snapshot retained operation status `submitting`. This is below both the HTTP body limit and the 8,192-character answer limit.

Smallest correction: use a consistent byte-bounded wire serialization and reject deterministic encoding/size failures before reservation, or otherwise reconcile the reservation explicitly before returning. Preserve uncertainty for failures that might actually have written bytes. Add a UTF-8 body/escaped-wire regression and verify a corrected valid submission remains possible after rejection.

### F3 — P2: resolved controls exhaust the pending-control budget

Location: `bridge/state.py:94-103`, `bridge/state.py:115-123`.

Resolution marks controls resolved but never removes them. The 32-entry check counts these retained resolved entries, so an ordinary long-running connection with one question at a time permanently disables controls after the 32nd resolution. This is a pending-capacity error with zero pending questions, unlike the plan's limit of 32 unresolved controls.

Reproduced by applying 33 distinct question requests followed immediately by their resolution events. Result: `error='pending_capacity'`, retained_controls=32, pending=0. No operation submissions were needed.

Smallest correction: bound unresolved controls independently from retry evidence and retire resolved controls safely; preserve the documented cached operation outcomes without retaining arbitrary old question payloads forever. Add sequential-resolution and cached-duplicate coverage.

### F4 — P2: final validation does not cover the approved failure boundary

`bridge/test_transport.py:test_old_envelope_never_redirects` only exercises early closed/generation checks on an object created with `__new__`; it never queues a write, blocks a real/fake pipe writer, reconnects a BridgeTransport, or checks the replacement destination. The state test does cover late completion preserving a fresh control, but is not an outgoing-transport generation test. The plan explicitly requires a delayed queued answer across reconnect with repeated wire IDs.

The live runner and retained live result exercise disconnect **before** submission, replay, stale-control rejection and a successful replayed answer. They do not perform the planned stop-immediately-after-submission uncertain-outcome trial. Therefore Task 3 cannot be reported completely exercised under the current plan. Add the required deterministic queued/reconnect check and the authorized bounded live post-submission observation, or explicitly record the live acceptance item as unexercised rather than marking it complete. A legitimately observed resolved outcome in that race must stay resolved, not be relabeled uncertain.

## Positive checks and evidence limits

- Ran `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s bridge -v`: all 9 tests passed. These tests create bounded ephemeral loopback HTTP listeners with fake answer sinks. No app-server, inference, amx process, existing daemon, native CI, or external reviewer was launched by this review.
- Inspected all bridge source files, all tests and README, approved design/findings, the foreground plan and prior plan/adversarial remediation reports, and retained live JSON.
- State reservation is under one RLock; actual writes occur outside it. Reply destinations capture a specific ProxyConnection and generation. Old-generation event guards and resolved-before-late-completion ordering are sensible. These positive observations do not replace the missing queue-level test.
- Auth checks happen before HTTP body interpretation. Exact Host, rejected Origin, duplicate auth rejection, token comparison, request logging suppression, no-store JSON responses, loopback-only binding and private exclusive capability-file creation are appropriate for the approved trusted-current-user development boundary.
- Provenance is a trusted local launcher contract, not proof against another process running as the same user. No malicious-same-user hardening is demanded for this scope. Actual server ownership and current HTTP/WS behavior were not re-exercised here; live findings rely on retained evidence.
- Retained live JSON supports successful answer/resolution, authenticated upgrade rejection, replay/stale rejection and owned-runtime cleanup. It explicitly does not inspect exact desktop prompt state. No phone, APNs, ordinary-session takeover or production readiness is inferred.

## Reviewed file hashes

SHA-256 captured after reproductions and before report creation; reports must not be reused for changed source without affected-scope refresh.

| File | SHA-256 |
| --- | --- |
| `bridge/README.md` | `987bc94d7fb6ae40773124c4cff85e6677508cbec4d7dd51c6a6d12ac16ac0dd` |
| `bridge/launch_probe.py` | `203807ad11bf2ca0905de8299f6bf7b94a705578af535842a5dc7c62bb4b8787` |
| `bridge/private_files.py` | `b88412fc60f0259cc7780936c35596e4d6d113851afdbe7307b534ce1a737ba7` |
| `bridge/server.py` | `2d3a6bb843278f99e81911415272e477835d69d3fd55e5d828d4781874fd8e78` |
| `bridge/state.py` | `5bb2e6f5600693cee24cda9b51e6b05ef748a48745c32c97e5f3906c01f17afb` |
| `bridge/test_server.py` | `c9139a7f7e8e2c08e1eaa192e9691c15976df9aa4a120486a1c48e39d30ca9f2` |
| `bridge/test_state.py` | `335b913c17e717af5e47b2464810ca45ffb249a876667b192d832029f8c7bd46` |
| `bridge/test_transport.py` | `172b3ea18f1d7b6d57d523e63bce8066a21fb1e781b4c73dd0e315d854ae5902` |
| `bridge/transport.py` | `b6fe1cadf06d53341d179804f4e029f306f10fe21ac5467ebcdeb93f3e48ca7a` |
| `bridge/ws_peer.mjs` | `4665f3873f7544906a0c4fa8ac6f90485cc4b6f1c0ee8e1882dbbc8b1298c649` |
| `docs/codex-live-control-findings.md` | `1c2208bd72592b00b0958305ede9dfe29b07a8ba0e274e431ec9ceffb1b29da8` |
| `docs/companion-v1-design.md` | `656fe42f5aff93e199959f30f66f48e1d2691b13e8899ac84092b881a1b6498d` |
| `docs/reviews/2026-10-02-foreground-live-result.json` | `6f08caece81f4b8f1ea5d3e5c6a78ea1a258e9c9d3428c5f693a7639679b51bc` |
| `docs/superpowers/plans/2026-10-02-foreground-bridge.md` | `258ecd84ae50ce480ee1b8c0cb7a07684ef6c2ec7caec7940092dc5caf6d7d0b` |
