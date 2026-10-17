# Independent control inspection review

Verdict: clean for the gated inspection outcome. No blocking findings.

Review adapter: Codex collaboration subagent; configured model gpt-6-astra, high reasoning, fresh context (parent-supplied dispatch metadata).

- Verified all eight retained upstream source hashes and excerpt ranges against pinned commit a956835d020762cb2b570053af06f643a11c0ecc. All three contribution hashes match the final-scope manifest.
- The isolation gate is justified: checked launch paths use the shared daemon, embedded runtime, or explicit remote owner. No overlooked supported private selector preserving normal-launch ownership was found.
- Findings distinguish source evidence from exercised behavior. They neither declare normal-session control impossible nor claim attachment, accepted replies, desktop resolution, reconnect safety, server-wide race handling, or lost-ack recovery.
- The proposed remote launch is correctly labeled a product decision. The protected physical socket location is appropriately flagged for follow-on isolation planning.

Minor, deferred: docs/codex-live-control-findings.md:50 describes broader inspection than the retained evidence independently reproduces. Before a runtime probe, retain exact inspection commands/help selectors, the question wire-method mapping, and initialization/resume/error shapes. Their omission does not weaken this gate decision.

Declined to judge: live request-ID reuse, desktop/client races, uncertain-response recovery, hook correlation, and device push: no implementation or runtime exercise exists, and each is explicitly gated or outside scope.

Read-only review; no daemon/config/credential access or mutations.
