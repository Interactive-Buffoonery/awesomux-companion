# Codex live-control findings

2026-10-02 · Task 1 inspection complete · initial inspection result: **inconclusive — isolation gate**. Historical sections below describe the first checkpoint; the authorized managed-launch results follow later.

## What was verified

Installed CLI is `codex-cli 0.160.0`. Its schema generator completed successfully. The official upstream `rust-v0.160.0` tag resolves to commit `a956835d020762cb2b570053af06f643a11c0ecc`; source evidence is version-matched to the reported CLI release, not a binary reproducibility proof.

CLI help exposes `--remote`, `--no-daemon` and `app-server proxy --sock`. `codex features list` reports `daemon_auto_start` enabled and `default_mode_request_user_input` disabled. These are selected feature readbacks, not a dump of credentials/configuration or proof of an already-running session's settings.

The normal plain launch, absent source-defined exclusions, auto-starts/attaches the shared daemon. Startup orchestration sets `LocalDaemon` from that daemon's returned socket. Its advertised control path is derived from `CODEX_HOME/app-server-control/app-server-control.sock`. No independent normal-launch private-socket selector was found in inspected help/source. Explicit `--remote unix://PATH` instead selects `AppServerTarget::Remote`; `--no-daemon` chooses an in-process server, not an exposed second-client endpoint. This is source evidence about launch paths, not a live-process observation.

Sources: [startup policy](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/tui/src/daemon_startup.rs), [startup orchestration](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/tui/src/startup_orchestration.rs), [target selection](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/tui/src/lib.rs), [socket path](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/app-server-transport/src/transport/mod.rs).

## Positive protocol evidence, not an exercised result

The generated question request requires `threadId`, `turnId`, `itemId`, `questions` and `isBlocking`; the result maps question IDs to answer arrays. `serverRequest/resolved` contains thread/request IDs. Local connection-incarnation guards must remain separate from those wire fields.

Version-matched `thread_lifecycle.rs` calls `replay_requests_to_connection_for_thread` during running-thread resume; outgoing-message handling retains pending ordinary requests by thread and removes their shared callback under a mutex when a reply arrives. Ordinary requests differ from connection-bound verification requests. These are promising recovery and single-consumption mechanisms, not proof that the desired question reaches a second client, its answer is accepted, or the desktop prompt clears.

Sources: [running-thread replay](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/app-server/src/request_processors/thread_lifecycle.rs), [pending requests and callbacks](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/app-server/src/outgoing_message.rs), [official protocol](https://learn.chatgpt.com/docs/app-server).

Question exposure additionally depends on the experimental request-input setting and allowed collaboration modes. Installed default-mode request input is disabled; a generic multiple-choice prompt is insufficient evidence. A future isolated test must use the inspected supported mode/tool, and distinguish no generated question from failed attachment.

## Gate outcome

The approved plan forbids connecting to the shared default daemon and requires a decision before exercising a non-default launch. A plain TUI launch could touch that daemon; therefore no disposable Codex/amx session was launched, no shared socket was contacted, no inference was sent, and no existing conversation was accessed or changed. Tasks 2–3 were gated off; no reply client or fake tests were built for an unresolved transport.

| Criterion | Outcome |
| --- | --- |
| Installed protocol/schema inspection | Completed |
| Normal TUI ownership | Shared-daemon path established by version-matched source, subject to launch exclusions |
| Same live thread attachment | Not exercised — isolation gate |
| Real question generation | Not exercised |
| Reply ownership / acceptance | Not exercised |
| Desktop prompt resolution | Not exercised |
| Foreground reconnect recovery | Pending replay found in source; not exercised |
| Competing response arbitration | Ordinary callback single consumption found in source; not exercised |
| Hook/amx-to-Codex correlation | Existing helper contract inspected; not exercised |
| Physical-device push / mobile app | Outside this plan; not built |

## Concrete next decision

Recommended next probe: start a separate disposable app-server and point a disposable amx TUI at it using `codex --remote unix://<private-path>`. This changes the launch ownership, so it must be labeled **companion-managed launch**, never normal-session reuse. Preserve existing authentication on the host and policy/configuration; do not copy credentials or change global daemon settings. The Unix-socket implementation uses a protected rendezvous alias, so the follow-on isolation plan must account for its physical socket location and clean up only its owned files.

The alternative is explicitly authorize a tightly allowlisted test against the shared daemon. That would require a new reviewed safety procedure before connecting. This inspection does not show that normal-session control is impossible, nor establish that companion-managed launch is necessary for the final product.

## Evidence and validation

[Captured schema and source excerpts](reviews/2026-10-02-control-inspection-evidence.json) contain source hashes, release identity, selected feature readbacks and generated wire schemas. Local help/schema/feature inspection completed; no product tests or live-control checks are claimed. Temporary download/schema artifacts are disposed after evidence retention; no probe-owned runtime was started.

## Authorized managed-launch probe — 2026-10-02

After the inspection, eD! explicitly authorized the disposable managed launch and continued autonomous work. This supersedes the earlier decision gate for that experiment only; the original existing-session result above remains unexercised.

A separate `codex app-server --listen ws://127.0.0.1:18769` hosted the disposable threads. Each amx session used a unique name and temporary `ZMX_DIR`; its pane process ran `codex --remote ws://127.0.0.1:18769 resume <new-thread-id> --no-alt-screen`. The retained runner scrubs inherited awesoMux routing variables for peers and the TUI. Server launch scrubbing was performed during the experiment, but its exact environment was not retained as independently inspectable evidence; that broader isolation detail remains a provenance limitation. No shared daemon connection, configuration change, credential copy, new dependency, or policy weakening was used. The configured model returned by thread creation was `gpt-6.1-sol`.

The Unix-socket attempt did not initialize its proxy before the deadline. A sandboxed amx attempt also exited immediately. Narrow elevated execution enabled the amx test; loopback WebSocket initialization succeeded using Node's installed native WebSocket implementation. These attempts do not establish a general Unix-socket incompatibility. A newly created thread cannot be resumed before it has a rollout; starting its first harmless turn before attaching resolved the observed `no rollout found` error.

### Exercised results

- The companion received `item/tool/requestUserInput` for its newly created thread and replied using the actual request ID on that connection.
- Codex emitted `serverRequest/resolved`, completed the same turn and returned the selected answer. The amx TUI displayed that continuation.
- Disconnecting the companion before answering and resuming the same thread replayed the pending question. The old local connection reference was rejected.
- Two connected protocol clients raced ALPHA and BETA responses. The captured run showed BETA in the response and emitted a completed turn; event multiplicity was not measured. This is one bounded observed race, supported by the previously inspected callback code; it is not an exhaustive concurrency proof.
- Repeating the companion's local reply did not issue another write. The runnable fake-peer checks also cover out-of-scope requests, resolved requests, ID reuse after reconnect, and partial-write uncertainty with no replay.

Raw VT capture was insufficient to prove the desktop question's exact displayed/disabled state. The observed TUI continuation is narrower evidence. Desktop-first UI resolution, process restart, lost acknowledgements in the live transport, hook-to-thread registration and physical-device push remain unexercised. The outcome is therefore **supported only with a non-default managed launch, with specific live checks passed**, not full companion readiness or takeover of existing sessions.

[First live result](reviews/2026-10-02-managed-live-first-result.json) and [reconnect/race result](reviews/2026-10-02-managed-live-reconnect-race-result.json) retain only method names, abbreviated thread IDs and outcome flags. Trial threads remain in Codex history; none were deleted. The results' `duplicate_outcome: sent` is a cached local outcome, not evidence of a second send.

### Runnable artifacts

`python3 -m unittest discover -s probes -p 'test_*.py'` runs the small reply-guard checks. `probes/run_live_probe.py` plus `probes/ws_proxy.mjs` reproduce the managed-session test against a separately started, owned loopback server. They are feasibility tools, not an authenticated phone-facing bridge.

Create a fresh `/private/tmp/amx-ios-live-*` directory with `project` and `amx` subdirectories, start a separate app-server on an unused loopback port, then run. Before launching the server, remove every `AWESOMUX_AGENT_*` variable and `AWESOMUX_PANE_ID`, `AWESOMUX_SESSION_ID`, `ZMX_SESSION`, and `ZMX_SESSION_PREFIX` from its subprocess environment. The runner separately scrubs its peers/TUI; it cannot sanitize an already running server. Preserve all other host configuration and authentication.

```sh
python3 probes/run_live_probe.py /private/tmp/amx-ios-live-EXAMPLE ws://127.0.0.1:PORT
```

The runner cleans up its own amx session and protocol peers. The caller owns stopping the separate server and trashing the temporary directory after retaining `result.json`. Do not point this probe at the shared/default daemon or an existing user server.

The [retained runner verification](reviews/2026-10-02-managed-live-final-result.json) repeated reconnect/race successfully with ALPHA winning and the resolved local reply returning `already_resolved`. Both observed races produced a completed-turn event; full desktop prompt-state verification remains outside these captures.

### Notification side effect discovered

eD! reported Moshi pings containing ALPHA/BETA during the later bridge smoke. The test agents invoked only request_user_input; their owned rollout tool names show no notification-send tool. Scrubbing awesoMux routing variables did not isolate every notification path. Existing `notify` configuration invokes the computer-use turn-ended notifier, and Codex also has TUI notification channels; exact downstream Moshi routing remains unconfirmed. All owned smoke runtimes were already stopped/cleaned when reported. Future disposable launches explicitly override `notify=[]` and `tui.notifications=false` on server/TUI, and remove `MOSHI_*` from inherited environment. Global notification configuration and safety hooks remain unchanged. These overrides are a new remediation, not retrospectively verified silent runs.
