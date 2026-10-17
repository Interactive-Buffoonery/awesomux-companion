# Physical plan final bounded contract review

Date: 2026-10-02
Adapter/model: Codex subagent / gpt-6-sol
Skill: review-plan v0.2.2
Mode: read-only; only this report written. No code/network/account/runtime mutations.
Plan SHA256: `284d8eaf2e6efc5cacfed646c15543622db0a3bced764010f479ee92f46ee8d6`
Scope strictly limited to quarantine lifetime, Simulator storage/entitlements, supervisor death/deadline semantics and appended foreground watcher teardown evidence. Other reviewed contracts are unchanged for this verdict.

## Verdict

**Proceed locally. The three remaining contract gaps are addressed.** No further hardening or scope expansion requested.

- Credential quarantine is explicit in-memory state honored by activation. Failed transactions cannot regain an API through ordinary foreground activation. Explicit identified retry is required within the process. Whole-app relaunch may load the preserved credential, with actual host visibly identified before controls enable; this is an honest durability ceiling when storage itself failed.
- Unsigned DEBUG Simulator compiles an in-memory pairing store and the existing private development-file fallback. Device/every Release compiles only Keychain storage. The real unsigned launch/file check prevents fake-storage unit coverage from substituting for the working Simulator path.
- Launcher and supervisor independently enforce the same absolute deadline, verify recorded child identity and monitor single-watcher loss. Readiness is required before pairing origin display. Fake tests cover launcher death, supervisor death and SIGTERM-ignoring child escalation. Simultaneous watcher death and unacknowledged startup are explicitly operator-cleanup residuals, included in exposure authorization; no universal hard deadline is claimed.

The appended version-matched WatchNotificationsAs caller connects watcher/context termination to deferred scoped DeleteForegroundSession. This is retained source evidence, not an actual Serve cleanup observation, and the plan still requires authorized live readback.

Implementation review must establish the concrete state transitions, compile-time storage branches, watcher identity checks and deadline tests. Exact account/exposure authorization and physical validation remain separate gates. This report approves the bounded contracts only.
