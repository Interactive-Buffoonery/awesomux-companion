# awesoMux companion: Codex first

2026-10-02 · design approved by eD! · supersedes the terminal-first initial scope in the September exploration.

## Outcome

eD! can leave the desk, receive a useful notification from an amx-associated Codex session, open its conversation, answer a question, and start a new task in a known project. The first app is a native iPhone companion with session threads. No terminal, break reminders, or broad provider support in this first scope.

## First usable flow

An inbox puts sessions needing input first. Each row identifies project, host, agent, and freshness. A thread displays user/agent messages and explicit pending questions or approvals. A composer sends deliberate text responses. A resolved request becomes read-only immediately, including when another client answered it.

New session creation selects a configured host/project and Codex, sends an initial prompt, and opens the resulting thread. Session creation must return an authoritative identity before displaying it as started.

The acceptance target is one real question delivered to a locked physical iPhone, answered there, and resolved in the original live Codex session. A second answer, expired notification, reconnect, and host disconnect must not cause unintended input or duplicate work.

## Identity: reuse existing integration

The existing bundled Codex hooks invoke `awesoMuxAgentHook`. Its payload parser already captures `session_id`/`sessionId` as `providerSessionID`. The shared helper is the intended registration point; do not duplicate registration logic in each provider plugin.

Keep these identities separate:

| Identity | Source | Meaning |
| --- | --- | --- |
| Host/backend namespace | Host registration | Machine and persistence owner |
| Terminal session | `ZMX_SESSION` | Persistent amx/zmx process container |
| UI pane | `AWESOMUX_PANE_ID` | Stable pane routing/correlation |
| Agent thread | Hook `providerSessionID` | Codex conversation |

`AWESOMUX_SESSION_ID` is the launch workspace, not the terminal UUID or current workspace. Remote-owned sessions must be addressed on their owning host. Absent identity means unassociated, never guessed from cwd. Multiple successive conversations in a terminal remain distinct threads. Nested agents must not replace their parent's identity.

## Control boundary and proposed architecture

Use Codex app-server's structured protocol for messages, pending questions, and approvals. A small host bridge connects the app to that protocol and associates threads with amx identity. Codex credentials and execution remain on the host. SwiftUI supplies the inbox/thread UI; native notifications supply locked-device entry into a thread.

The hook side channel is currently a one-way status channel. It does not supply transcript streaming or an authoritative response transport. A pending app-server request must be answered on its owning connection with its actual request ID, thread ID, and turn ID. `serverRequest/resolved` is the resolution signal. Resuming stored history in another server is not proof of control of the original live process.

Before choosing the host bridge implementation, verify whether the installed Codex TUI and daemon expose the same live session to another supported client. If they do, reuse that connection. If they do not, propose a companion-managed Codex launch path explicitly; do not silently substitute a second agent or type approvals into the PTY. This is the main unresolved feasibility question.

Start with one known Mac and configured project. Prefer existing private connectivity for foreground access. Locked-device push additionally needs an APNs-capable sender and device provisioning; the phone cannot rely on an indefinitely open background connection. Select the smallest authenticated push delivery path after the live response probe. Notification payloads contain opaque routing IDs and generic text by default, not transcripts or credentials.

## Reliability and permissions

The host owns pending requests and validates their continued existence before replying. Serialize competing replies and retain operation outcomes so a retry can report the original result. Never replay an uncertain response blindly. Reconnect fetches current state; cached content visibly carries its age. Restarted host/agent instances invalidate old pending controls.

Preserve Codex's approval policy, sandbox, plugins, and configuration. Support only rendered request types whose actual protocol semantics are understood; unsupported requests remain visible with desktop resolution guidance. Commands, paths, and requested permission scope must be visible before approval. The default UI grants one request, not blanket session permission.

## Delivery sequence

1. Read-only protocol inspection and isolated control probe: prove or disprove live terminal-session attachment without modifying an active conversation.
2. One-host foreground loop: thread messages, a real pending question, reply, resolved state, and reconnect.
3. Native iPhone inbox/thread UI against that working path.
4. Physical-device locked push into the exact pending request.
5. New session creation for a configured project.

Checks must cover wrong-session routing, duplicate replies, desktop/phone races, expired requests, process restart, and disconnection. Use a fake protocol peer for deterministic fault checks; real device/agent checks establish the end-to-end result. Do not claim push or live control based on a mock screen.

## Evidence and limits

- Local installed CLI: `codex-cli 0.160.0`; `app-server --help` exposes stdio, Unix socket, WebSocket, daemon, and proxy surfaces. Help output alone does not establish shared TUI ownership.
- Existing awesoMux source: `docs/amx-automation.md`, `docs/agent-runtime-side-channel.md`, `Sources/AwesoMuxAgentHookSupport/AgentHookPayload.swift`, and the bundled Codex `hooks/hooks.json`.
- Official protocol: https://learn.chatgpt.com/docs/app-server — conversation operations, server-initiated approvals/user questions, and resolution events.
- Inspiration: https://github.com/pingdotgg/t3code/tree/main/apps/mobile and its mobile-notification documentation. Borrow the thread/notification interaction, not its entire harness or infrastructure.

At the initial design checkpoint, no app, runtime control probe, APNs provisioning, host service, or product implementation had been completed. The later managed-launch probe is described below. This folder is not currently a Git repository; publication and commit-bound review are not yet applicable.


## Verified inspection results — 2026-10-02

[Live-control findings](codex-live-control-findings.md): installed Codex 0.160 supports a shared-daemon control surface and has promising pending-request replay/callback handling. The approved isolated probe stopped before live attachment because normal launch can access the shared daemon; special launch needs an explicit decision. No existing-session control, mobile app or push delivery is claimed. Approved product decisions above remain unchanged.


### Managed-launch result after authorization

The disposable managed-launch path now has exercised evidence: a real question answered through another client, pending-question replay after reconnect, stale-reference rejection, and two competing-response trials with observed completed turns with the winning answer visible in the amx TUI. This establishes a viable starting point for the foreground bridge; it does not establish takeover of existing terminal sessions, exact desktop prompt-state behavior, or mobile push. See the [updated findings](codex-live-control-findings.md).
