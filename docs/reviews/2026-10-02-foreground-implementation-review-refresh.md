# Foreground implementation affected-scope refresh

Date: 2026-10-02
Adapter: Codex collaboration subagent, independent reviewer context.
Configured model: `gpt-6-astra`, high reasoning, according to parent dispatch metadata; provider/runtime identity is not independently exposed.
Prior review: `2026-10-02-foreground-implementation-review.md`, preserved unchanged as historical evidence. This is a fresh affected-scope review, not a relabeling of that report.

## Verdict

**No remaining blocking findings in the reviewed local foreground bridge implementation.** F1–F4 from the original report are resolved with the qualifications below. Fifteen deterministic tests pass in this review. Notification suppression remains an unverified live-launch remediation; this report does not certify silent future inference runs.

## Finding resolution and affected review coverage

| Prior finding / changed area | Fresh inspection and outcome |
| --- | --- |
| F1 partial-write corruption | `_writer` now marks the exact connection closed on write failure, completes/cancels queued envelopes and exits; reader observes closure and the existing owner closes/reconnects that proxy. The partial-write regression checks that the following envelope is not written. Resolved. |
| F2 Unicode reservation leak | State preflights the exact UTF-8 wire encoding before reservation, matching transport `ensure_ascii=False`. Oversize input does not create an operation. Writer ValueError after reservation becomes uncertain. Unicode and failed-writer regression tests pass. Resolved. |
| F3 resolved-control capacity | Resolution removes completed controls while operation digest/status evidence remains. Cached operation lookup precedes live-control lookup so known duplicate results remain available after removal. Forty sequential resolutions preserve new pending capacity. Resolved. |
| F4 delayed transport/reconnect coverage | Retained tests now include actual `BridgeTransport.answer` with two distinct proxy objects, an original write delayed across disconnect/reconnect, the same reused wire request ID, and a replacement `current`. Result is uncertain, neither proxy receives stale bytes, and the new control remains pending. Actual writer queue generation/cancellation tests complement it. Resolved. |
| F4 live post-handoff loss coverage | Refreshed retained live JSON reports uncertain after deliberate resolution suppression and disconnect immediately after proxy pipe handoff. Acceptance is explicitly unknown. This is an injected live transport observation, not a naturally occurring failure or proof of remote nonacceptance. Resolved for the bounded planned uncertainty trial. |
| Notification mitigation | Runner adds launch-only `notify=[]` and `tui.notifications=false` to server/TUI argument lists and removes inherited MOSHI_* variables. README shell quoting is corrected. No global configuration, policy override, safety-hook disabling or new sender was introduced. Actual silence is not demonstrated by the retained live JSON, which predates this mitigation. |

Independent read-only reproduction additionally exercised two-proxy replacement outside the retained test: blocked original peer, disconnect, new generation/hydration with repeated request ID, replacement current peer, release original write. Observed outcome uncertain, zero destination writes and fresh control pending. The equivalent runnable test was then inspected and run as part of the final 15-test suite.

## Scope and impact decisions

State and transport changes received renewed correctness/concurrency/failure-path inspection, including operation-cache behavior, generation capture, wire encoding, queue cancellation and reader shutdown. State/transport test changes were inspected directly and executed. Launch-probe changes received lifecycle, notification-boundary and retained-evidence inspection. README/findings/progress changes received scope and evidence-honesty inspection.

The HTTP adapter, private-file handling, WebSocket helper, HTTP tests, approved design and foreground plan retain their original reviewed hashes, so the prior conclusions for their unchanged mechanisms are retained. Integration tests were rerun against changed state/transport dependencies. This is an implementation-review refresh only; it does not claim a separately dispatched full specialist panel or external adversarial review.

## Validation and limits

- Ran `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s bridge -v`: **15 passed**.
- No real Codex server, inference, amx runtime, existing daemon, notification delivery or native CI was launched by this reviewer. HTTP unit tests use bounded fake-answer loopback listeners.
- The retained live JSON supports answer/resolution, replay/stale rejection, injected post-handoff uncertainty, and owned cleanup (amx absent, endpoint closed, private root absent, no cleanup errors). This review inspected those results rather than rerunning them.
- `loss_automatic_resend=false` in the live record is consistent with inspected implementation and deterministic tests; the runner assigns that field rather than measuring upstream response-frame counts. Do not describe it as packet-level proof.
- User-reported ALPHA/BETA Moshi notifications are a real incident. Documentation appropriately records the event, mitigation and unconfirmed exact relay cause. Removing MOSHI_* and overriding the two known settings does not prove every inherited plugin/hook notification path is silent. No further inference should be described as quiet without separate evidence.
- Phone access, APNs, ordinary-session takeover and exact desktop prompt state remain outside the exercised result. No readiness claim for those surfaces is made.

## Final reviewed hashes

Hashes below bind this refresh to the inspected source and evidence. Compare against the original report to retain only demonstrably unchanged scope.

| File | Since original review | SHA-256 |
| --- | --- | --- |
| `bridge/README.md` | changed | `459241e23c06ebbe2ddfc40e9f9ddf2b2a0cb4f69f8ee1fda782959338efac93` |
| `bridge/launch_probe.py` | changed | `1a71a3ce6620e55015d790f85486873f8f2146c9806c00c4e22d7bf34ea79793` |
| `bridge/private_files.py` | unchanged | `b88412fc60f0259cc7780936c35596e4d6d113851afdbe7307b534ce1a737ba7` |
| `bridge/server.py` | unchanged | `2d3a6bb843278f99e81911415272e477835d69d3fd55e5d828d4781874fd8e78` |
| `bridge/state.py` | unchanged | `5bb2e6f5600693cee24cda9b51e6b05ef748a48745c32c97e5f3906c01f17afb` |
| `bridge/test_server.py` | unchanged | `c9139a7f7e8e2c08e1eaa192e9691c15976df9aa4a120486a1c48e39d30ca9f2` |
| `bridge/test_state.py` | changed | `706f6e907b8e1cc4c6f64f20edb4240817d40c30225b1a6dc80f083fbd949fbf` |
| `bridge/test_transport.py` | changed | `a994201a8fa0e443d97c29eb981eade410a9db42d334fbf9092b70d741a20705` |
| `bridge/transport.py` | unchanged | `b6fe1cadf06d53341d179804f4e029f306f10fe21ac5467ebcdeb93f3e48ca7a` |
| `bridge/ws_peer.mjs` | unchanged | `4665f3873f7544906a0c4fa8ac6f90485cc4b6f1c0ee8e1882dbbc8b1298c649` |
| `docs/codex-live-control-findings.md` | changed | `4edd52cec54727be8bfae47d9e1a6a779de6ac4b701639e23d3e8977c993c4b6` |
| `docs/companion-v1-design.md` | unchanged | `656fe42f5aff93e199959f30f66f48e1d2691b13e8899ac84092b881a1b6498d` |
| `docs/foreground-bridge-progress.md` | additional evidence | `23e54245e5e10b0bb0974b519ce9a38737c5bd3697b332453ab7d91d0f85c1bd` |
| `docs/reviews/2026-10-02-foreground-live-result.json` | changed | `633ea70fa371107614562734c78af550a23b19c47ea3b696e5f63a007c94b6ad` |
| `docs/superpowers/plans/2026-10-02-foreground-bridge.md` | unchanged | `258ecd84ae50ce480ee1b8c0cb7a07684ef6c2ec7caec7940092dc5caf6d7d0b` |
