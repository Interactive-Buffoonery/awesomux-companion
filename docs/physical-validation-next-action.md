# Prepared physical validation actions

Local implementation and unsigned Debug/Release phone artifacts are prepared. Exact contribution scope and review status are recorded in physical-foreground-progress.md; a passed compile does not prove signing or real Keychain/HTTPS behavior.

## Next concrete action: development signing and installation

- Bundle identifier: `com.interactivebuffoonery.awesomux.companion`.
- Existing team: Interactive Buffoonery, the sole installed team identified by local public profile metadata; two unexpired existing profiles carry APNs entitlements, but none matches this new app.
- Build: local Debug iphoneos app from `ios/AwesoMuxCompanion.xcodeproj`, scheme AwesoMuxCompanion; use the installed team's local signing identity and automatic development provisioning only after explicit authorization.
- Persistent side effect: Apple may register this bundle identifier and create/download its development provisioning profile. No APNs key, aps-environment capability, cloud relay or paid native CI in this action.
- After signing: inspect actual entitlements/profile for the exact app/team and expected development Keychain access group, then install only on the re-resolved selected paired iPhone. Device unlock, trust/account prompts and later connection-key entry are user-only handoffs. No credential text should be requested in chat.
- Do not infer a matching profile from the existing signing identity; none was observed for this app.

## Later action: exact private-network trial

Signing/install and existing authorized phone tailnet reach come before the timed trial. Read-only version/schema/port preflight currently selects unused port 8443 on this Mac's exact Tailscale self hostname; recheck immediately before the trial. The exact private origin must match its separately authorized origin.

The trial would expose only the owned authenticated loopback bridge behind one foreground HTTPS Serve entry, preserve the existing listener, use one disposable quiet managed Codex session, and manually pair one designated phone. The launcher's and independent supervisor's shared absolute deadline is at most20minutes of awake host time (the current monotonic clock excludes sleep). Route cleanup occurs before backend reuse, with before/after ownership/preservation readback. No public Funnel, background Serve, off/reset or full-config restore.

Existing HTTPS listener was observed, but certificate issuance/Certificate Transparency history was not verified. Certificate issuance can disclose the node DNS name publicly in CT logs. Simultaneous watcher death or unacknowledged startup can require operator cleanup; an orphan route can reach another local service if its backend TCP port is later reused. These residuals must be included in the narrow exposure authorization, not treated as a hard security expiry.

Phone key is shown only through its private local client file for manual entry, never in chat, screenshots, URLs, args or review artifacts. Real GET/question/answer/reply, Keychain lifecycle and proxy Host/framing remain unverified until this action. Stop/trash owned temporary runtime and explicitly Disconnect in the phone afterward; uninstall does not guarantee Keychain deletion.
