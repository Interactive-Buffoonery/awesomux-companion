# Foreground bridge adversarial review

Claude Code; requested claude-opus-5-5, actual modelUsage claude-opus-5-5; safe-mode, no tools/MCP, supplied scoped plan/design/findings. Original plan scope before plan-review refinements.

# Review: foreground bridge plan

**Verdict: Not ready to implement as written. Approve after the amendments below.** The overall shape is sound: one owned peer, one locked state owner, generation-scoped controls, no automatic resend, and no remote listener. Five concrete gaps can still cause unintended input to the live session or a hung bridge. Each needs only a small plan edit, not a redesign.

---

## Blockers

### B1. Unsupported server requests must get no reply at all
**Gap:** The plan says only `requestUserInput` is answerable and approvals stay unsupported. It never says what goes back on the wire for other requests. The usual JSON-RPC client behavior is to answer unknown methods with an error. The findings say ordinary pending requests are shared by thread and consumed by the first reply under a mutex. An error reply from the bridge could therefore resolve or deny an approval that the TUI user should decide. That is unintended input, which the design forbids.
**Fix:** Add a Task 1 rule: *for any server request that is not a supported, allowlisted-thread `requestUserInput`, write zero bytes.* This covers approvals, other threads, missing `threadId`, and malformed requests. Add a fake-peer test that sends an approval request and asserts the transport write count stays at 0. Also list in the plan which connection-bound request types the bridge's `initialize` capabilities could attract, and opt out of them at initialize.

### B2. `answer(..., write)` under the RLock can deadlock
**Gap:** If `write` runs while the state lock is held, this can happen:
1. The Node proxy's stdout pipe fills.
2. The reader thread blocks in `apply()` waiting for the lock.
3. The proxy stops draining stdin.
4. The write blocks while still holding the lock.

GET `/v1/thread` then hangs too. Python pipe writes have no timeout.
**Fix:**
- Under the lock, move the control from `pending` to `submitting` and record the operation.
- Release the lock, then hand the line to a dedicated writer thread through a bounded queue with a timeout.
- Reacquire the lock to record `submitted`, `failed` (nothing written), or `uncertain`.
- Add a test with a fake writer that blocks on an Event while `apply()` and `snapshot()` run concurrently.

### B3. The upstream app-server WebSocket is an unauthenticated sibling of the bridge
**Gap:** The bridge hardens its own HTTP with a bearer token, Origin rejection, and a Host check. The `codex app-server --listen ws://127.0.0.1:PORT` it depends on has no stated authentication. Two parties could reach it:
- **Any web page in the user's browser.** WebSocket handshakes are not subject to CORS, so this works unless the server checks Origin.
- **Any other local OS account**, because loopback is shared across users.

Either could start turns or answer questions on the managed thread using the host's credentials. Until this is resolved, the "unauthorized HTTP rejects before protocol action" property only holds at the bridge's own front door.
**Fix:** Add a gate before Task 3:
1. Test a handshake to the owned app-server with `Origin: https://example.invalid`, and one from a second local user if one exists.
2. If it is rejected, record that as evidence.
3. If it is accepted, either retry `--listen unix://` inside a 0700 private directory (the earlier failure was not shown to be a real incompatibility), or record this as an explicitly accepted risk for the disposable session: short lifetime, server stopped right after the smoke run, and no claim of a security boundary.

Either way, the README must state that the app-server listener, not the bridge, is the weakest local boundary.

### B4. "Newly managed thread only" is asserted, not enforced
**Gap:** The bridge accepts any supplied thread ID. A separately launched app-server shares `CODEX_HOME`, so `thread/resume` with an existing user thread ID could load and attach a real user conversation in a second server. The design explicitly says this is not control of the original process, and it forbids it. Endpoint provenance is also unchecked: any loopback app-server could be passed in.
**Fix:**
- The launcher writes a 0600 provenance file in the private directory containing the server PID, port, and the thread ID returned by its own `thread/start`.
- The bridge refuses to start unless the supplied endpoint and thread match that file.
- If the schema has a read-only thread read, also check before resuming that the thread's cwd is inside the private `project` directory.
- Send `thread/resume` with `threadId` only. Add a test asserting the exact outgoing payload has no model, cwd, sandbox, or approval overrides, which preserves Codex policy.

### B5. Control IDs can collide across process restarts
**Gap:** "Opaque control ID includes connection generation" only protects within one process. After a restart the generation counter starts over, and the findings show app-server request IDs repeat after reconnect. A client that reloads the new token and retries a POST could therefore hit a *different* question with the same `gen:reqId`. The failure table claims "prior controls invalid", but nothing enforces it.
**Fix:** Build control IDs from a random per-process nonce plus the generation plus a server-side counter, using `secrets.token_urlsafe`. Map them to request IDs internally and never derive them from wire IDs. Add a test: two `BridgeState` instances given identical event sequences must produce disjoint control IDs.

---

## Should fix (high/medium, small)

1. **Tag events with their generation.** `apply(message)` should become `apply(generation, message)`, and `apply` should drop events from an older generation. Otherwise an old reader thread that is still draining can resolve or create controls in the new generation, since request IDs repeat.
2. **Rebuild history on reconnect.** On each new generation, replace message history from the resume response, then apply live events. Appending causes duplicates, and events during the disconnect window are otherwise silently lost. Mark the snapshot as rebuilt.
3. **The 1 MiB line bound will break resume on non-trivial threads.** Resume responses carry turn history with tool output, which easily exceeds 1 MiB. Either measure resume payloads in Task 3 and set the transport bound from the result (for example 16 MiB), keeping retained state bounded separately, or truncate per item. Python `readline(limit)` returns partial lines, so treat a line with no newline at the limit as fatal for that generation.
4. **Bound entry size, not just entry count.** 200 entries times 1 MiB is a 200 MiB ceiling. Truncate text per entry and per in-progress delta, with a visible `truncated` flag.
5. **Invalid requests can exhaust the outcome cache.** Record outcomes only for operations that matched a live control and passed validation. Otherwise a client retrying with fresh UUIDs against unknown controls fills the 256 slots and permanently disables answering.
6. **Validate answers and store only a digest.**
   - Reject the answer map unless its question IDs exactly match the control's questions.
   - Where options exist, the answer must be one of them unless the schema allows "other".
   - For conflicting-reuse checks, store a digest of the canonical answers, not the plaintext.
   - Never echo answers in the snapshot. This matters if the schema has a secret-input flag.
7. **Link retries to prior uncertain attempts.** When a replayed question has the same `(turnId, itemId)` as an earlier `uncertain` operation, mark the new control `prior_attempt_uncertain`. The user then answers again knowingly. This is still no automatic replay.
8. **Make the shutdown guarantee real.** Signal handlers cannot guarantee child cleanup on SIGKILL. Make the Node proxy exit on stdin EOF and treat that as the guarantee, with signal handling as best effort. Also drain proxy stderr continuously and discard it: an undrained stderr pipe blocks the proxy, and logging it could leak transcript content.

## Minor (fold into Task 2)

- **HTTP parsing:**
  - Require `Content-Length` and reject any `Transfer-Encoding`; `BaseHTTPRequestHandler` does not decode chunked bodies.
  - Check auth before reading the body.
  - Compare tokens with `hmac.compare_digest` on bytes; non-ASCII strings raise `TypeError`, which must be caught.
- **Logging:** Override `log_message` and the server's `handle_error`. The defaults print tracebacks to stderr, which conflicts with "no request logs".
- **Response headers:** Add `Cache-Control: no-store` and set the content type explicitly.
- **Binding:** Bind `127.0.0.1` on port 0. Write the chosen port next to the token, because the plan doesn't say how the client discovers it. Require the Host header to be exactly `127.0.0.1:<port>`, with no `localhost`, and require the upstream endpoint to use the literal `127.0.0.1`.
- **Token file:**
  - Resolve the supplied directory with `realpath` first; `/tmp` is a symlink on macOS, so a naive symlink rejection would block every `/tmp` path.
  - `lstat` the directory and require it to be owned by the current uid with mode 0700.
  - Create the file with `os.open(..., O_CREAT|O_EXCL|O_NOFOLLOW, 0o600, dir_fd=...)`.
- **Contradiction:** Task 2 says the caller trashes the token. It also says to verify token cleanup after owned shutdown. Pick one rule: the server unlinks the file it created on clean shutdown, and the caller trashes the directory.
- **Naming:** Use `submitted` rather than `sent` for outcomes. A successful pipe write only proves the proxy received the bytes.
- **Task 3 test gap:** Kill the proxy right after a write and confirm the outcome is `uncertain` with no resend. The findings list lost acknowledgements in the live transport as unexercised.

---

## Correctly out of scope for this slice

Production-mobile gaps are not blockers here. Restate them in the plan's closing section so the "ready for a native client" goal isn't over-read:

- **Remote reach:** A physical iPhone cannot reach loopback. The next native slice can only target the Simulator until the deferred authenticated-transport decision is made, so "ready for a native client" should read "ready for a Simulator client".
- **Push:** APNs sender, device provisioning, locked-device push and notification payloads.
- **Session creation:** Starting new sessions and returning an authoritative identity at launch.
- **Approvals:** Rendering approvals (command, path and scope visibility, single-grant UI).
- **Identity:** Hook `providerSessionID` to thread correlation and amx pane/session association.
- **Existing sessions:** Attaching to them through the shared daemon.
- **Desktop prompt state:** Confirming the TUI prompt clears after a bridge answer. Task 3 should not claim this.
- **Scale and durability:** Multiple hosts, projects or threads, and outcome eviction or persistence across restarts. Rejecting operations after the 256-outcome limit is acceptable for local development.

**Summary:** Apply B1–B5 as plan edits, especially zero bytes on unsupported requests, writes outside the lock, provenance-gated attach, and nonce-based control IDs. Add the app-server Origin gate before the Task 3 smoke run. After that the plan is a sound, appropriately narrow local foreground slice.