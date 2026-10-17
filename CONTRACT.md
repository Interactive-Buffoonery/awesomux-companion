# Companion relay contract v1

The relay runs on the Mac, reads the awesoMux local agent API through the
bundled `awesomux-agent` helper, and serves one read-only snapshot to the
awesoMux Companion iOS app. Both sides build against this file; change it here first.

## Source: awesoMux local agent API

Helper: `<awesoMux.app>/Contents/MacOS/awesomux-agent --profile <profile>
--credential-handle <uuid> <operation> [args]`. One JSON object on stdout;
exit 0 success, 1 failure with `{"error": "<code>", ...}`. Dates are ISO 8601.

- `list_agents` -> `agents: [Agent]`
- `get_attention_events --limit 100 [--cursor C]` -> `attentionEvents:
  {events: [Event], nextCursor, cursorStatus, hasMore,
  currentStateRecoveryRequired}`

Agent fields used: `paneID`, `workspaceID`, `workspaceName`, `provider`
(display string: `Claude Code`, `Codex`, `OpenCode`, `Pi`, `Grok`, ...),
`executionLocation` (`local` or an SSH destination), `availability`
(`awaitingHydration` | `attached` | `unavailable`), `state` (`idle` |
`running` | `waiting` | `thinking` | `output` | `needsAttention` | `done` |
`error`), `attentionReason` (nullable: `bell` | `desktopNotification` |
`permissionPrompt` | `userInputRequired` | `processError` | `unknown` |
`waitingForInput` | `agentError`), `unreadCount`, `observedAt` (nullable).

Event fields used: `id`, `attentionID`, `change` (`raised` | `resolved`),
`paneID`, `workspaceID`, `provider`, `occurredAt`, `reason`, `resolvedAt`.

Cursor statuses `history_gap`, `app_restarted`, `access_changed` return no
events, `currentStateRecoveryRequired: true`, and a fresh cursor: call
`list_agents`, drop open alerts, continue from the fresh cursor.

## Relay -> phone: `GET /v1/glance`

`Authorization: Bearer <token>`. 401 bad token, 403 bad Host/any Origin,
404 other paths. Response `application/json`, `Cache-Control: no-store`:

```json
{
  "schemaVersion": 1,
  "hostName": "mac-studio",
  "connected": true,
  "error": null,
  "updatedAt": "2026-10-17T21:41:00Z",
  "agents": [
    {
      "id": "<paneID>",
      "workspaceName": "awesomux",
      "provider": "Claude Code",
      "group": "needsYou",
      "state": "needsAttention",
      "reason": "permissionPrompt",
      "location": "local",
      "since": "2026-10-17T21:39:12Z"
    }
  ]
}
```

- `connected: false` with `error` set to the helper error code (or
  `helper_failed`) when the latest read failed. `agents` then holds the last
  good list and `updatedAt` its capture time; never an empty list that hides
  the failure. Before the first good read, `agents` is empty and `updatedAt`
  is null.
- `group` is derived by the relay, never the app:
  - `needsYou`: an open (raised, unresolved) alert exists for the pane, or
    `attentionReason` is non-null, or `state` is `waiting`,
    `needsAttention`, or `error`.
  - `working`: `state` is `running`, `thinking`, or `output`.
  - `done`: everything else (`idle`, `done`).
- `reason`: the open alert's reason, else `attentionReason`, else null.
- `since`: the open alert's `occurredAt`, else `observedAt`, else null.
- Agents with `availability == "unavailable"` are omitted.
- Order: `needsYou` (oldest `since` first), then `working`, then `done`.

## Notifications

On each `raised` event first seen after relay start (events delivered in the
`initial` cursor page are history: record, do not notify), the relay sends one
push. Phase 1 delivers it with `xcrun simctl push <device> <bundle> -`;
phase 2 replaces delivery with APNs. Payload:

```json
{
  "aps": {
    "alert": {"title": "Claude Code needs permission", "body": "awesomux"},
    "sound": "default",
    "thread-id": "<paneID>",
    "content-available": 1
  },
  "paneID": "<paneID>",
  "attentionID": "<attentionID>"
}
```

Title is `<provider> <phrase>`; phrase by reason: `permissionPrompt` "needs
permission", `userInputRequired` "has a question", `waitingForInput` "is
waiting for you", `processError`/`agentError` "hit an error", anything else
"wants your attention". Body is the workspace name. No transcript content.

`content-available` lets the app refresh its snapshot, the widget, and the
Live Activity when the push arrives.

## Pairing

Phase 1 (Simulator, Debug): the relay writes `client.json`
(`{"endpoint": "http://127.0.0.1:<port>", "token": "<token>"}`) into a
mode-0700 private directory; the E2E script copies it into the app container
as `Library/Application Support/development-client.json`. Phase 2 uses the
existing HTTPS pairing screen over Tailscale.
