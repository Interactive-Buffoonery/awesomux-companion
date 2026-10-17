# Native foreground adversarial refresh

Claude Code; actual model claude-opus-5-5; safe mode/no tools; snapshot native-refresh-scope.json.

**Verdict:** Approve once two fixture/schema gaps are closed. The safety model is coherent now. Locks, epochs, uncertainty, the retry identity, the size cap and ATS/redirect handling all fail closed, and I found no remaining path that sends an answer from stale or undecoded state. The two blockers below won't cause unsafe behavior, but they would likely stop the Task 3 real loop.

## Blockers

1. **`updated_at` numeric type is hidden by normalization.** The fixtures normalize it to integer `0`. If BridgeState emits `time.time()`, real snapshots carry a fractional value, and a Swift `Int` decode will fail on every live GET. Pin the type in the README (number, possibly fractional) and keep a non-integer value in the exported fixtures, for example `1.5`. Otherwise the fixture tests pass and the real loop is permanently "invalid response".

2. **`operations` value shape is unspecified and unexercised.** The README says only "UUID-to-outcome object", and both fixtures have `{}`. After the first real answer, every snapshot will carry a populated entry, and pending controls may carry non-`pending` statuses. Pick one:
   - Specify the value shape (an outcome string or an object with named fields) and export a post-submission fixture with a populated `operations` entry and a non-pending control status. Add tests that decode it and that treat unknown values as read-only.
   - Or state in the plan that the client does not decode `operations` at all, and add a test proving an arbitrary value there doesn't fail the snapshot.

   Either is fine. The current text leaves it to the implementer, and the most literal reading (a strict typed map) breaks right after the first submission.

## Tighten in-place (not blockers)

- **`confirmation_required`:** state that it triggers an immediate refetch and invalidates freshness. Confirmation UI then appears only if the fresh snapshot has `prior_attempt_uncertain: true`. If the flag is absent, the control stays locked with a status rather than silently becoming editable.
- **Status/outcome pairing:** treat a status with a mismatched or missing `outcome`, such as a bare 404 `{"error":...}` from an unknown route, as uncertain, not as `rejected`. Add one test for it.
- **Free-text answers:** the README requires every displayed question ID, so define "required" as all questions. Also decide empty versus non-empty trimmed text. Otherwise the detail question in the fixture is ambiguous and ends in 400 → refetch → stuck editing.
- **Cancelling the receive at the cap:** when the 4 MiB (GET) or 64 KiB (POST) cap trips, cancel `AsyncBytes.task` explicitly. Don't rely on breaking out of the loop to stop the transfer. Put the 64 KiB POST cap in the plan text too, since only the README mentions it.
- **Lease anchor:** start the 10-second lease at request send, not response receipt, so a slow 8-second GET can't stretch staleness to about 18 seconds. The server stays authoritative either way, so this is a correctness nicety.
- **Media type:** compare `HTTPURLResponse.mimeType`, not the raw `Content-Type`, so a `; charset=` parameter doesn't fail every response.
- **TUI notification readback:** the config readback in Task 3 verifies the server only. If the amx TUI loads its own config, record that its argv overrides were applied. Don't let the server readback imply the TUI setting.

No scope expansion is needed. The deferred backend trim and the decision to skip a separate instance ID are both sound for this slice.