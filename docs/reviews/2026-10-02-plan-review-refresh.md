# Plan review refresh

Date: 2026-10-02
Adapter/model: Codex subagent / gpt-6-sol
Skill: review-plan
Mode: read-only remediation review; this report is the only file written.
Scope: revised `docs/superpowers/plans/2026-10-02-codex-live-control.md`, previously read approved `docs/companion-v1-design.md`, original plan-review findings, and Claude Opus 5.5 B1–B4/M1–M5 report.

## Verdict

**Proceed with the bounded inspection/probe plan. No remaining concrete plan blockers.** This approves the experimental procedure, not the still-unverified live-control capability. Architecture clarity remains **FORMING** until the explicitly gated ownership experiment establishes its result.

## Original plan-review findings

| Finding | Remediation | Result |
| --- | --- | --- |
| P1: interface cannot reject old incarnations | Immutable references include connection incarnation; reconnect invalidates references; reused identical IDs receive a deterministic check | Addressed |
| P1: fake peer may invent wire protocol | Schema-shaped fixtures, exact response fields, local metadata separated from wire fields, fixture provenance recorded | Addressed |
| P2: unsupported branch still builds client | Task 1 explicitly skips Tasks 2–3 when no candidate exists; uncertain ownership permits only minimal observation | Addressed |
| P2: question generation unspecified | Inspect mode/tool prerequisites; bounded generation; question-generation inconclusive separated from attachment; approval-only labeled partial | Addressed |
| P2: sequential suppression mislabeled server arbitration | Sequential local suppression explicitly distinguished; full verdict requires arbitration evidence from exact source or safe isolated test | Addressed |
| Cleanup/timeout gaps | Explicit bounds, finally cleanup, namespace/PID verification, teardown failure reporting | Addressed |

Remote identity, successive amx conversations and nesting are now honestly deferred to the bridge plan. Removing those tests from this one-runtime probe is proportional; no host routing abstraction is needed here.

## Claude blocking/major findings

| Finding | Remediation | Result |
| --- | --- | --- |
| B1: special launch passed as normal reuse | Normal TUI pane launch required; exact command recorded; special launch is a user decision gate and distinct verdict | Addressed |
| B2: shared runtime exposes real threads | Shared daemon prohibited; private endpoints; authoritative disposable thread allowlist; unrelated messages dropped without content logs | Addressed |
| B3: ordinary text mistaken for structured request | Method/mode prerequisites inspected; scoped recorded overrides; bounded generation; approval-only evidence distinct | Addressed |
| B4: desktop resolution not required | Desktop prompt removal/disabling required for full success; answerable prompt means partial support | Addressed |
| M1: association claimed by construction | Hook comparison conditional; missing comparison explicitly unverified; constructed identity labeled honestly | Addressed |
| M2: request ownership per connection | Only requests delivered on current client connection produce references; per-connection IDs recorded | Addressed |
| M3: local write confused with acceptance | Explicit outcomes, asynchronous resolution, retained in-memory outcomes, winning client not inferred | Addressed |
| M4: fabricated host/amx test scope | Registration/routing tests removed and deferred; local test scope now matches client responsibilities | Addressed |
| M5: unsafe amx namespace/addressing | Unique explicit ZMX_DIR, prefix removal for every command, exact socket/name verification before stop | Addressed |

## Remaining experimental unknowns

Normal TUI runtime attachment, question generation, per-connection request ownership, desktop propagation, reconnect recovery and arbitration remain unverified. The plan now names the experiment or source check for each and prevents their absence from being reported as full support. No additional speculative hardening or implementation scope is required before Task 1.

No runtime protocol behavior was exercised during this refresh, and no source/spec/plan files were modified by this reviewer.
