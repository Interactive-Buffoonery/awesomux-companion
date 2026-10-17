# Native foreground plan adversarial review

Claude Code; actual model claude-opus-5-5; safe mode, no tools/MCP; original native plan scope manifest retained.

# Adversarial review: native foreground client plan + bridge HTTP contract

I worked only from the two documents, with no tools and no edits. Physical-device pairing and push are out of scope as you asked. Findings are ordered by severity, and each gives the smallest fix I'd accept.

## Blockers (fix the plan/contract before Task 1)

**B1. The response contract doesn't exist, so the plan can't decode "exact coding keys."**
- The README defines only the POST request body. It doesn't define:
  - the GET snapshot schema
  - the POST outcome schema
  - outcome enum values
  - the error envelope
  - the status codes
  - the `client.json` keys
  - the generation, freshness, upstream-connected and bridge-error fields
- The plan also uses `isOther` (camelCase) while claiming snake_case.
- *Fix:* add a response-contract section to `bridge/README.md` and have a bridge unittest emit canonical JSON fixtures. Check those fixtures in as the Swift test fixtures. An unknown enum value must fail closed for that control, not for the whole snapshot.

**B2. There's no POST status-to-state mapping, and the uncertain rule depends on one.**
- *Fix:* add a table to the plan.
  - Only rejections the bridge documents as *pre-reservation* return the control to editable. Examples: 400 validation, 401/403, 413/415.
  - 409 conflict means "already reserved." The control stays locked and is never editable again.
  - Everything else becomes `uncertain`: timeouts, transport errors, cancellation, 5xx, an undecodable 2xx, and any 3xx.

**B3. Prior-uncertain confirmation can't come from client memory.**
- The plan clears submission identities when the generation changes. Control IDs rotate, and a bridge restart wipes all server state.
- So after a reconnect the client cannot know a replayed control needs `confirm_uncertain`.
- *Fix:* the bridge exposes a per-control flag, e.g. `requires_uncertain_confirmation`. The UI shows the confirmation step only when that flag is set.
- A "confirmation required" rejection maps to showing the prompt, never to automatically setting the flag.

**B4. A retry won't be byte-identical, so it risks a 409 conflict or a 400.**
- `UUID().uuidString` is uppercase. The bridge requires a "canonical UUID," which in Python usually means lowercase.
- `JSONEncoder` key order isn't guaranteed to be stable between two encodes.
- Adding `confirm_uncertain` later would change the payload.
- *Fix:*
  - Lowercase the operation ID.
  - Encode the body once when the operation is created and store that `Data`.
  - Retry sends the stored bytes.
  - The confirm flag is fixed for the operation's whole life.

**B5. The 4 MiB bound can't be enforced, and the bridge doesn't guarantee the snapshot fits.**
- `URLSession.data(for:)` buffers the entire response before you can check its size.
- The snapshot can hold 200 × 16 KiB of text *before* JSON escaping. Python's default `ensure_ascii` can grow non-ASCII text up to about 6× (emoji become `\ud83d\ude00`).
- A long-lived thread could therefore become permanently unloadable.
- *Fix (client):* use `bytes(for:)` with a counting abort, and reject any declared Content-Length above the limit up front.
- *Fix (bridge):* cap the *serialized* size by dropping the oldest items and setting a `history_truncated` flag. Add a unittest using worst-case non-ASCII text.
- POST responses should get a much smaller bound, e.g. 64 KiB.

**B6. An "8-second request timeout" isn't a total timeout.**
- `timeoutIntervalForRequest` is an *idle* interval, so a response that trickles in slowly never times out.
- *Fix:* also set `timeoutIntervalForResource = 8`.

**B7. Freshness is time-based, but nothing re-renders when time passes.**
- If a fetch hangs for up to 8 seconds, no state changes, so `canAnswer` stays true.
- *Fix:*
  - Store `freshUntil` from `ContinuousClock` (monotonic, not `Date`), and schedule a main-actor task that flips `isFresh` when it expires.
  - Clear freshness when any fetch fails.
  - Re-check `canAnswer` synchronously inside `submit` before the first `await`.
  - Inject the clock so tests can drive it.

**B8. A stale GET can unlock a control after a POST.**
- Sequence: a GET starts → the POST returns `submitted` → the GET returns, showing the control as pending with no outcome → the control looks editable again.
- *Fix:* once an operation exists for `(generation, control_id)`, keep the control locked locally. It unlocks only when:
  - the snapshot shows an outcome for it, or
  - the control disappears, or
  - the POST got a definite pre-reservation rejection.
- Tag each GET with a request sequence number. A GET that started before the latest POST settled can never unlock a control. Add this exact interleaving as a test.

## High

**H1. Request construction must match the bridge's strict checks.**
- Send `Content-Type` as exactly `application/json`, with no `; charset`.
- Set the body as `httpBody` `Data`. A `httpBodyStream` produces chunked encoding, which the bridge rejects.
- Before decoding, require status 200 and `Content-Type: application/json`.
- Validate the endpoint with `URLComponents`:
  - scheme is `http`
  - host is exactly `127.0.0.1`
  - the port is explicit and isn't 80, so `Host` keeps its `:port`
  - no user, password, path, query or fragment
- Build `/v1/thread` and `/v1/answers` from fixed paths.

**H2. Session hardening beyond "ephemeral."**
- Set `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCredentialStorage = nil`, and `requestCachePolicy = .reloadIgnoringLocalCacheData`.
- Set `connectionProxyDictionary = [:]`. The Simulator inherits the Mac's proxy/PAC settings, which could route the bearer token through a proxy.
- The redirect delegate returns `nil`, and any 3xx is treated as an error (uncertain for POST).
- Cancel authentication challenges instead of performing default handling.
- Assert that `response.url` matches the request URL.

**H3. Lifecycle handling is incomplete.**
- Disable controls whenever `scenePhase != .active`, not just on background. `.inactive` covers the app switcher and Control Center.
- Bump the epoch on both leaving and entering `.active`.
- The store owns polling based on the app-level `scenePhase`, not a view `.task`. A view task would be cancelled and restarted on navigation.
- Do **not** cancel an in-flight POST on background. Let it settle to an outcome or to uncertain.
- Re-read the config on every activation, because a bridge restart rotates the token.
- Show a 401 as a distinct "credentials rejected" state rather than a generic disconnect.

**H4. A bridge restart is indistinguishable from a generation bump.**
- *Fix:* add a random `instance_id` to the snapshot.
- If the instance changes while a local operation is submitting or uncertain, show a non-actionable notice: "Earlier answer outcome unknown — check the thread."

**H5. The UI copy must not overclaim.**
- `submitted` means "Sent — waiting for Codex," not "Answered."
- `resolved` must never imply this client won; the desktop may have answered.
- An identical retry only re-reports the current outcome once the bridge has seen the operation. Label it "Check / try again" and say so in the UI.

## Medium

- **Answer validity:**
  - Require every displayed question ID before enabling Submit.
  - The wire format for "Other" text and multi-select is unspecified; add both to the contract. Until then, render multi-select controls read-only.
  - Reject empty or whitespace-only free text.
  - Key drafts by `(generation, control_id, question_id)` and drop a draft if the question's schema changes.
- **ATS:**
  - First check whether a loopback IP needs an exception at all.
  - If it does, put only `NSAllowsLocalNetworking` in a Debug-only `INFOPLIST_FILE`.
  - Add a build check that the Release plist has no `NSAppTransportSecurity` key.
- **Config injection:**
  - `Library/Application Support` may not exist before the app's first launch, so create it during injection.
  - The container path changes on reinstall.
  - Validate the token as printable ASCII with no CR/LF.
  - Mode 0600 doesn't protect against processes running as the same host user; say so in the report.
- **Logging:**
  - Error types must never interpolate the request or its headers.
  - Don't set `CFNETWORK_DIAGNOSTICS` in the scheme.
- **Swift 6:**
  - `BridgeAPI: Sendable`.
  - The redirect/challenge delegate should be a stateless `final class` that is `Sendable`.
- **CFNetwork retries:** CFNetwork may transparently resend a request on a dropped keep-alive connection. That's safe here only because of operation-ID idempotency, so record that dependency in the plan.

## Verdict

B1–B5 need contract or bridge changes: the response schema, a confirmation flag, a serialized size cap, and probably `instance_id` (H4). Settle those first. B6–B8 and the High items are client-side changes to the plan text and can go straight into Task 1's tests.