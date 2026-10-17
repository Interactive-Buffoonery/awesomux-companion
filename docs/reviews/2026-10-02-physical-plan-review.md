# Physical foreground architecture review

Date: 2026-10-02
Adapter/model: Codex subagent / gpt-6-sol
Skill: review-plan v0.2.2
Mode: read-only implementation review; only this report written. No network, signing, device, runtime or credential mutations.
Scope: physical foreground plan; full workflow/rubric; current BridgeClient.swift, CompanionStore.swift, bridge/server.py and managed launcher; official Tailscale Serve reference.

**Clarity: FORMING. Recommendation: refine the concrete contracts below before implementing/authorizing exposure.** Single-host bounded trial is appropriate; no APNs/cloud-key work is needed.

## System diagram

```text
iPhone pairing form -> one Keychain endpoint/capability
                           |
                    URLSession HTTPS
                           |
                 private tailnet Serve listener
                           |
                bearer-auth loopback HTTP bridge
                           |
                 authenticated managed Codex
```

## Findings

### P1 — Existing authentication delegate cancels HTTPS server-trust challenges

The current `NoRedirectDelegate.didReceive challenge` cancels every authentication challenge. HTTPS adds platform server-trust evaluation, which the HTTP-only Simulator path did not exercise. Reusing that policy unchanged can reject valid trusted Tailscale TLS.

**Smallest fix:** Explicitly allow URLSession's default handling for the server-trust authentication method; cancel credential-bearing HTTP/client-certificate challenges. Do not construct a bypass credential or change trust anchors. Retain no-redirect behavior and exact endpoint checks. Add focused delegate tests for default trust handling versus rejected credential challenges; real HTTPS validation remains an exposure-stage test. This is a platform default, not custom TLS logic.

### P1 — Host replacement needs its own connection identity and failure-order contract

The plan correctly advances epochs and clears controls, but leaves partial-save/delete/load failure ordering unfinished. It also explicitly mentions old POST identity/generation while the current send path does not capture a connection epoch. Random backend generations are not a substitute for host identity, especially in tests or a re-pair to the same runtime.

**Trigger:** an old POST completes during failed re-pair; Keychain delete fails; unlocked activation reload fails while the old API remains available.

**Smallest fix:** First invalidate writable state and advance a local connection revision for any pairing/disconnect attempt. Capture that revision and immutable API for each GET/POST; completion applies only when revision and operation identity still match. On save/load/delete failure keep the UI disconnected and no active API, report typed failure, and preserve the stored prior item when replacement fails. A later explicit load/reconnect may restore that prior item; never silently restore controls inside the failed transaction. Test same generation on two fake hosts, failed save/delete, and late old POST after each. Define credential-source precedence so activating a Simulator debug file cannot silently replace an explicitly paired HTTPS host.

### P1 — Status comparison plus listener off is not an atomic ownership guarantee

Task 2 checks a current mapping before issuing listener `off`, but another actor can change the mapping between those two commands. The same gap exists between free-port preflight and start. The plan claims preservation of concurrently changed routes more strongly than those operations establish.

**Smallest fix:** Inspect installed/version-matched Serve foreground ownership behavior before selecting cleanup commands. Prefer stopping only the recorded foreground process/session and verifying its owned mapping disappeared, rather than blindly issuing a port-wide off after a stale comparison. Do not introduce whole-config restore/reset. If the installed interface cannot prevent start replacement or distinguish route ownership, state the unavoidable race explicitly and gate exposure on a short exclusive-use agreement for the chosen unused listener; mapping conflict means stop the trial and leave foreign state untouched. Include a fake race after status read, not only a change visible before that read. A same-process lock does not solve external command races.

The official [Serve reference](https://tailscale.com/docs/reference/tailscale-cli/serve) documents configuration operations; installed foreground session behavior still needs source/help verification. No actual Serve command was run during this review.

### P2 — Manual key handoff must occur inside the live trial's bounded lifetime

The launcher presently runs a 20-minute interactive session beginning before pairing/signing/user interaction. Physical provisioning or key entry can consume the whole window. Stopping/restarting rotates the token and makes a saved key unusable; the plan does not state when the pairing form reports a successful connection versus merely saving credentials.

**Smallest fix:** Complete signing/install before starting the exposure window. Start the bound at route activation, show the generic remaining trial status, and expire/tear down independently of user input. Saving credentials means configured, not authenticated/paired; show connected only after a successful authenticated current-host GET. Wrong/unreachable host remains read-only with correction/disconnect access. No background extension or longer-lived service is required.

## Failure modes

| Failure | Trigger | User impact | Post-failure state | Coverage |
| --- | --- | --- | --- | --- |
| Trust challenge canceled | Valid HTTPS connection | Cannot connect | Default platform TLS handling; other auth challenges rejected | P1 correction |
| Failed credential transaction | Locked/denied Keychain save/delete/load | Old credentials could remain active | API disabled; typed failure; stored data preserved as appropriate | P1 correction |
| Cross-host completion | Late old GET/POST | Old outcome mutates new connection | Connection revision and operation fence discard result | P1 correction |
| Foreign Serve mapping race | External change after preflight/read | Unrelated listener overwritten/removed | Version-verified session ownership or explicit exclusive-use gate | P1 correction |
| Trial expires during entry | Slow provisioning/key entry | Saved key points to stopped runtime | Configured/disconnected UI; fresh trial/key required | P2 correction |
| Network loss after POST | Tailnet disconnect | Outcome unknown | Existing immutable operation uncertainty, no resend | Planned |
| Route/host conflict | Unexpected proxy Host or listener change | Rejected request/cleanup conflict | No widened allowlist or foreign cleanup | Planned |
| Signing unavailable | No matching profile/account access | Cannot install | Finish local preparation, exact user-only handoff | Planned |

## Hidden assumptions

| Assumption | Classification | Risk if wrong |
| --- | --- | --- |
| Selected iPhone has active authorized Tailscale access to this Mac | Verifiable, not established by pairing record | Installed app cannot reach private origin |
| Serve preserves the expected Host including nondefault port | Verifiable through controlled request | Backend rejects valid requests; do not widen blindly |
| HTTPS enablement/certificates available | Verifiable, may require admin action | Exposure cannot begin |
| Sole signing identity can provision chosen identifier/device | Verifiable, not proved by installed identity | User-only signing gate |
| Foreground Serve ownership can safely isolate cleanup | Verifiable through installed help/source | External config race must be acknowledged/gated |

Check phone tailnet connectivity as an explicit validation prerequisite without requesting keys or dumping network inventory.

## Shadow paths

- Missing/empty URL/token: local validation rejection, no Keychain mutation or request.
- Stored item missing: unconnected UI; locked/denied/corrupt item: typed unavailable state, no plaintext fallback.
- Unreachable host/401/invalid TLS: no fresh controls, explicit corrective pairing access.
- POST loss: immutable outcome unknown; replacing host leaves notice, never transfers operation to new API.
- Serve command error/status unavailable: no ownership inference, no broad cleanup; report exact owned leftover scope privately.

## Unfinished thoughts and proportionality

Only TLS-default handling, credential transaction sequencing, connection fencing, Serve atomicity honesty and trial timing need clarification. One Keychain item and two candidate ports are enough. No multi-host database, device discovery layer, certificate pinning, push registration or new credential transfer mechanism is warranted.

## Production readiness and framing falsification

This is a development trial with deliberate manual pairing and ephemeral host capability. App Disconnect deletes a local item; actual host revocation is runtime/token teardown, not Keychain deletion. Device signing and active tailnet reach are unverified gates. The cheapest end-to-end falsifier is authenticated phone GET followed by whole-control answer and same-thread resolution, after exact route authorization and quiet-launch verification. A Mac curl or Simulator TLS success cannot substitute for that result.

## Recommendation

Fold in the small contracts, then implement/test/review locally before presenting the exact listener origin, backend, duration and preservation conditions for exposure authorization. Physical install and secret entry remain the named user-only handoffs where needed. No external action was performed by this reviewer.
