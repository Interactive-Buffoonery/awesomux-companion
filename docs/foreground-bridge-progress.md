# Foreground bridge execution ledger

2026-10-02. User authorized autonomous continuation. Plan and Claude Opus 5.5 adversarial reviews retained separately in docs/reviews. Blocking findings incorporated: per-control reservation, replay projection, idle semantics, upstream authentication, immutable connection envelopes, provenance-gated attachment, and random controls. Reviewer minor final edits incorporated, including correct-token Origin check; actual no-inference auth test passed and owned runtime/token cleaned.

Scope: local Simulator-development service only. No phone connectivity, APNs, hook registration or existing-session takeover. No Git repository; no commits/publication.

Task 1: pending. Task 2: pending. Task 3: pending.

Ruling: keep Node builtin WebSocket custom-header extension, verified installed support — avoids dependency or custom framing; installed authenticated handshake must pass before inference.

Task 1: state and authenticated transport implemented; five state checks and two transport checks passed. Task 2: local HTTP adapter implemented; two integration checks passed (nine total). Initial smoke server exited under sandbox before any endpoint/thread was created; private root trashed. Supported elevated retry running with owned authenticated listener, scrubbed environment and disposable thread.

Ruling: secret questions remain unsupported/read-only and uncertain replay requires explicit confirmation — prevents invisible secret retention or accidental retry; native client must render that capability/confirmation.

Task 3 first managed HTTP smoke passed: real question, answer, resolved completed text, pending replay, stale-control rejection, authenticated amx TUI process alive. Auth gates returned 401/401/403. Owned session absent, server stopped, endpoint closed and private directory absent verified.

Independent gpt-6-astra implementation review reproduced resolved-control capacity, escaped Unicode wire-size/reservation and partial-write stream reuse defects. Tests observed each fail, fixes pass (14 tests). Added queued-old-generation cancellation test. A refreshed real smoke now includes explicit resolution-delivery suppression and disconnect after proxy handoff, to verify uncertainty rather than claim acceptance.

Notification incident: eD! reported ALPHA/BETA Moshi pings. Owned smoke already finished with server exit 0, amx absent, endpoint closed and private directory absent. Original environment scrub did not cover all notifications. Added launch-only notify=[] and tui.notifications=false to server/TUI and scrub MOSHI_*; no global config or safety hooks changed. Exact relay cause not yet independently established; no further live inference until quiet launch verified.

No-inference elevated config/read verified notify=[] and tui.notifications=false effective; features list confirmed hooks=true. Owned inspection server exited 0. This verifies configured sinks disabled, not an observed end-to-end absence of every possible push relay. Added retained two-proxy BridgeTransport.answer replacement test; 15 checks pass. Second live smoke includes uncertain post-handoff loss, with acceptance explicitly unknown; runtime/token/session fully cleaned.
