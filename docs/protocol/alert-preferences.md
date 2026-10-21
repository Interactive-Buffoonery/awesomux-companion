# Per-device alert preferences

Shared wire contract for awesoMux #791. These types do not enable a Mac
operation or change phone notification delivery by themselves. The Mac must
consume a merged package commit and implement the authenticated operations;
phone settings UI follows separately.

`CompanionAlertPreferences.categories` is a set encoded as a JSON array in the
order below. The default includes all categories; an empty array disables all
five categories for this pairing. Generic reasons remain eligible as below. Unknown categories and malformed payloads fail
decoding. Adding a category requires explicit version or capability negotiation,
because older strict decoders reject unknown category values. A missing preferences field on an older envelope remains absent;
the Mac migrates a missing stored grant preference to all categories.

| Category | Meaning |
| --- | --- |
| `permission` | Agent permission requests |
| `waiting` | Agent waiting for input |
| `error` | Agent errors |
| `commandFailed` | Failed command completion facts |
| `commandCompleted` | Successful long-running command completion facts |

Both operations use the existing version-1 request envelope, direct pinned
mutual TLS, and the authenticated device's `connectionID`:

```json
{"schemaVersion":1,"requestID":"<uuid>","operation":"get_alert_preferences","connectionID":"<uuid>"}
```

```json
{"schemaVersion":1,"requestID":"<uuid>","operation":"set_alert_preferences","connectionID":"<uuid>","alertPreferences":{"categories":["permission","commandFailed"]}}
```

A successful get or set response contains `alertPreferences` in the standard
response envelope. Set replaces the full set, including an empty set. Get
accepts no arguments; set requires exactly one preferences payload and no
pane, cursor, scope, command-event mode, or other operation arguments. The Mac
validates operation-specific fields; the shared DTO does not authorize requests.
Old Macs reject unsupported operations; clients must show that an update is
needed and must not treat an absent response preference as a successful save.

The Mac stores preferences with that paired grant, never with a global phone
identity. Only the authenticated pairing can read or change its preferences.
An effective change rotates the grant revision, invalidates pending leases,
and causes existing event cursors to recover with `access_changed`. An identical
set is a no-op. Persistence failure must preserve the previous preferences and
authority. Revocation and replacement keep their existing semantics.

The host evaluates presence when recording an event: suppress a raised alert
only when its pane is visible and focused on the active Mac. Suppressed or
filtered events still consume journal positions. Preserve resolution events so
clients can clear an already surfaced alert. Filters do not broaden status
scope, opt into command events, acknowledge pane state, or change cursor mode.

Delivery remains direct LAN/Tailscale polling. This contract adds no relay,
push registration, notification extension, terminal input, or decision authority.

Mac reason mapping: `permissionPrompt` maps to `permission`;
`userInputRequired` and `waitingForInput` map to `waiting`; `processError` and
`agentError` map to `error`; `commandFailed` maps to `commandFailed`;
`commandFinished` maps to `commandCompleted`. Generic `bell`,
`desktopNotification`, and `unknown` reasons remain eligible because none of
the five categories covers them. Presence applies to all raised events,
including those generic events.
