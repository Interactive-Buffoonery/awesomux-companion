# Companion Squircle evidence

Initial state: clean `feat/squircle-development` at `76e944a`, identical to fetched
`origin/main`; no open Companion PRs or other Companion Squircle owner found.
Upstream Squircle HEAD still matched the pinned `737f2e8`. The active OG owner
was read only; its service, checkout, devices and build state were not changed.

Preparation into a fresh `/tmp/companion-squircle-prepared` succeeded from the
upstream pin. The adapter includes the MIT license and parameterizes only
validated, credential-free Companion identifiers.

Checks and artifact results are recorded below after execution. A source check
is not a build, and a build is not an interactive or signed-device pass.

Pending: fixture suite, Rust tests/offline injector build, Swift 6 overlay device
SDK build, renderer validation, normal Release exclusion, signed Debug export,
app/widget entitlement proof, enrollment/forget/renewal, RPC mutation/approval,
physical install/launch and LAN/cellular/background/reconnect acceptance.
No phone has been selected or touched. No service mutation or publication.
