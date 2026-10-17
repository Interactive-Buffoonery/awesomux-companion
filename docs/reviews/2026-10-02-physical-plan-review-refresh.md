# Physical foreground plan review refresh

Date: 2026-10-02
Adapter/model: Codex subagent / gpt-6-sol
Skill: review-plan v0.2.2
Mode: read-only remediation review; only this report written. No implementation/network/signing/device/runtime mutation.
Reviewed plan SHA256: `068917ccc832b62859d446cbdcbe1e62416ea077b2cc82d7bd9a9a5cc382ad57`

## Verdict

**Proceed with local implementation and tests. No remaining concrete plan blockers for the bounded single-host trial.** Actual exposure, account provisioning and physical pairing remain the explicit separate gates.

## Bounded impact and remediation

| Prior finding | Revised scope | Result |
| --- | --- | --- |
| TLS challenge cancellation | Default server-trust handling; all credential-bearing challenges canceled; no trust bypass | Addressed |
| Partial credential replacement / cross-host completion | Fail-closed API reset; explicit identified prior-host retry; connection revision plus immutable API/operation checks; debug file precedence defined | Addressed |
| Status/off ownership race | Version-matched ETag and foreground session evidence; no off/reset; only owned process termination; scoped readback and conflict reporting | Addressed |
| Pairing consumes exposure lifetime | Signing/install and phone tailnet readiness precede trial; independent route deadline/parent-death supervisor; configured versus authenticated status separate | Addressed |

Reviewed the retained Serve ownership findings: installed version/commit alignment, ETag/If-Match, new foreground-port conflict checks, mutex-scoped foreground-session deletion. This provides concrete source evidence for the chosen ownership mechanism. I did not independently rerun local version/tag verification or mutate Serve; actual route/session readback remains an execution obligation.

Affected additions are bounded and appropriate: exact nondefault port Host, occupied AllowFunnel exclusion, selected listener certificate-transparency check, no automatic provisioning without exact bundle/team authorization, local signed artifact entitlement expectations, and supervisor crash/deadline tests. These do not broaden the product transport or APNs scope.

Unchanged bridge request identity/idempotency, native writable freshness and managed-runtime authentication retain the prior reviewed contracts. Credential/state changes, HTTPS delegate changes and route supervisor require their fresh implementation reviews after coding; this report is not an implementation receipt.

## Remaining gates and limits

- Sole team/certificate and existing profiles do not prove the new companion identifier is provisioned. Exact signing gate remains.
- Existing APNs-capable profiles are metadata evidence only, not proof of provider credentials or companion APNs entitlement; no push readiness claim.
- Selected phone must demonstrate authorized private-network reach. Pairing record alone does not establish it.
- Fake SIGKILL/deadline checks and source ownership evidence do not establish real Serve cleanup until the authorized trial records owned-entry absence and unrelated mappings unchanged.
- Manual secret entry stays user-only; no token output, screenshots or transfer through chat.

The stricter failed-credential transaction is coherent: preserve prior stored item where applicable, disable API, and require explicit identified retry. No automatic fallback is needed. Proceed locally without expanding into multi-host storage, custom TLS trust, cloud relay or notification infrastructure.
