# Foreground bridge adversarial refresh

Claude Code; actual claude-opus-5-5; safe mode/no tools; scope snapshot 2026-10-02-foreground-review-scope.json.

**Verdict: Ready to implement. All five prior blockers are resolved. Fold the small edits below into the plan as you go; none needs a redesign.**

## Prior blockers

| ID | Status | Note |
|---|---|---|
| B1 zero-byte replies | Resolved | Zero-write approval test present; initialize requests only experimentalApi. |
| B2 write under lock | Resolved | Reservation is taken under the lock, the bounded writer runs outside it, and a blocking-writer responsiveness test is included. |
| B3 upstream auth | Resolved, conditional | Capability token is read from a file, the pinned source rejects Origin, and the authenticated handshake smoke runs fail-closed before inference. See item 2. |
| B4 provenance | Resolved in Task 3 only | See item 1. |
| B5 control ID collision | Resolved | Random per-process nonce, IDs never derived from the wire, and a disjoint-ID test across instances. |

All eight should-fix items and the minor HTTP and token-file items are addressed.

## Remaining edits

1. **Provenance enforcement lands too late.** In Task 2, server start still accepts "loopback Codex endpoint and exact owned thread" with no provenance requirement. Enforcement only appears in Task 3. Make the provenance record a required server-start input in the Task 2 interface. Otherwise a code path exists that attaches any thread ID through any loopback endpoint, which reopens B4. Also require the endpoint to be the literal `ws://127.0.0.1:<port>`; the plan currently says only "loopback".
2. **The upstream gate can pass without exercising the Origin check.** A browser Origin attempt without a token is rejected by token auth alone, so the smoke never tests the Origin check. Add one upgrade with the correct token plus `Origin: https://example.invalid` and require rejection. This is defense in depth, since browsers can't set Authorization, but the plan claims Origin rejection, so the evidence should support it.
3. **Shutdown wording contradicts itself.** Task 1 says "Signal cleanup is best effort, not a SIGKILL guarantee" and later "Signal handling guarantees owned subprocess shutdown." Delete the second sentence; the real guarantee is stdin EOF.
4. **The `apply` signature is inconsistent.** The Interfaces line says `apply(message)` and the body says `apply(generation, message)`. Use the generation form everywhere.
5. **"Release" is ambiguous.** "Release the lock ... never release on uncertain writes" overloads the word. Write "never free the reservation on uncertain writes."
6. **Naming.** The failure table still says "cached sent". Use `submitted`.
7. **Duplicate while in flight.** A duplicate of the same operation while the first is still submitting should return an in-progress outcome immediately, not block or re-enqueue. Add one assertion to the duplicate-operation test.

Not blockers, already accepted: no heartbeat (half-open loopback is unlikely), and a reconnect loop if a resume response exceeds 16 MiB (the thread is disposable and small).