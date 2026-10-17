# Physical foreground adversarial plan review

Adapter Claude Code; actual model claude-opus-5-5. Tools/settings/hooks/MCP disabled. Scope manifest physical-plan-original-scope.json.

# Verdict: changes required before execution

The client-side late-result design is sound. The plan already calls for operation-identity comparison, epoch advance and cleared controls. The blockers below are in TLS challenge handling, Serve ownership and cleanup, the bounded-lifetime claim, the content of the exposure authorization, in-memory/Keychain consistency, and the Apple account gate.

## Blocking changes

**B1. HTTPS cannot work through the existing challenge delegate.** `ios/AwesoMuxCompanion/BridgeClient.swift:37` cancels every task-level challenge. The session itself has no delegate, so the server-trust challenge goes to this task-level method. As written, every Tailscale HTTPS request fails TLS. That failure also creates pressure to "fix" it with a trust bypass.
- Change: for `NSURLAuthenticationMethodServerTrust`, return `.performDefaultHandling`. Cancel every other method (Basic, Digest, NTLM, client certificate). Never construct `URLCredential(trust:)`.
- Test: a delegate unit test using a fake protection space. Server trust gives default handling, other methods give cancel. Also scan the source to confirm `URLCredential(trust:` and `.useCredential` don't appear.

**B2. "Compare current mapping, then off" is a TOCTOU and conflicts with foreground semantics.** The CLI `off` has no compare-and-swap. A mapping added on the same port between the check and the `off` would be deleted. Foreground-mode config also belongs to the CLI's IPN-bus session, and tailscaled removes it when that process exits.
- Change: ownership is the owned foreground CLI process. Cleanup means terminating that process, then reading back state. Never issue `off` or `reset`.
- After start, read back state. Require exactly one new foreground entry with the chosen port and the `http://127.0.0.1:<backend>` target. Require the background config and the other foreground entries to be identical to the baseline. Otherwise terminate the owned process and report a conflict.
- After stop, read back again. If the port is still mapped, report a generic conflict and leave it alone.
- Tests (fake command):
  - A background mapping appears on the owned port before cleanup. Assert no `off` or `reset` is ever invoked, the owned process is terminated, and a conflict is reported.
  - The baseline changes during start. Assert the owned process is terminated and start fails.
  - The CLI version or status lacks the foreground field. Assert start fails closed.

**B3. "Maximum 20 minutes" isn't enforced if the parent dies.** In `launch_probe.py`, the signal handlers are installed only inside the interactive branch. SIGHUP is not handled at all. The existing pattern of spawning children with `start_new_session=True` would let a route child outlive a killed parent, and foreground Serve stays up exactly as long as that CLI lives.
- Change:
  - Install SIGINT, SIGTERM and SIGHUP handlers before starting the route.
  - Do not start the route in a new session.
  - Enforce the deadline outside the parent, for example a tiny supervisor that kills the CLI at the deadline or when `getppid()` changes.
  - Alternatively, drop the hard-bound claim and say "best effort" as the README already does.
- Test: a fake route child with a 2-second deadline. SIGKILL the parent and assert the child is gone within the deadline plus a small margin.

**B4. The exposure authorization omits two facts.**
- (a) If no certificate has been issued yet for this node name, the first HTTPS request issues one. That publishes `<host>.<tailnet>.ts.net` to public Certificate Transparency logs, which is an irreversible outward disclosure. Determine read-only whether an HTTPS cert or listener already exists for that name, and state the result in the authorization request.
- (b) A leftover `AllowFunnel` entry for a candidate host:port with no handler would make the new route public. Treat any `AllowFunnel` entry on the candidate port as occupied, and recheck it in the post-start readback.
- Test: a fake status with `AllowFunnel[<dns>:8443]` and no handler. Assert 10000 is chosen, or the start fails if 10000 is also unavailable.

**B5. In-memory state and Keychain state can diverge.** `activate()` (`ios/AwesoMuxCompanion/CompanionStore.swift:25`) rebuilds `api` from storage on every activation.
- If `pair()` swaps the client before the save succeeds and the save then fails, the next foreground silently reconnects to the old host while the UI implied the new one.
- Change: validate, then save, then (only on success) advance the epoch, clear state and swap the client. A failed save leaves the prior client, snapshot and epoch untouched and shows an error.
- Load must distinguish item-not-found (offer pairing) from a read error (show an error, offer no pairing that would overwrite).
- Tests (injected storage):
  - Save throws: the old endpoint is still in use, and after `activate()` it is still the old endpoint.
  - Load throws: the client is nil, the message is not the "Connect a host" prompt, and no save happens.
  - A stored `http://127.0.0.1` item: load rejects it on a device or Release path.

**B6. Automatic signing mutates the Apple developer account.** `-allowProvisioningUpdates` or Xcode automatic signing registers the App ID `com.interactivebuffoonery.awesomux.companion`, may register the device, and creates a profile. That is a persistent external change, and a deleted App ID's identifier generally can't be reused.
- Change: make this an explicit authorization gate that names the exact bundle ID and team.
- Confirm the team type first. A personal team can't take APNs, which would strand the next slice on this App ID.
- Test or gate: before authorization, the only allowed signing operations are read-only checks. Verify no xcodebuild invocation includes `-allowProvisioningUpdates`.
- Fix the artifact check so it expects `get-task-allow`, `application-identifier`, `team-identifier` and the default `keychain-access-groups`. Require no `aps-environment` entitlement. As written, "no development capability" would fail on any development-signed build.

**B7. The Host allowlist must be port-exact, and the client's port set must match the route's.** Serve forwards the client's Host header, which includes `:8443` or `:10000`. Port 443 would produce a portless Host. Either drop 443 from client validation or make the allowlist string `<dns>:<port>` derived from the actual route.
- Test: return 403 for each of these Host values:
  - `<dns>` with no port
  - `<dns>:<other port>`
  - uppercase
  - trailing dot
  - `x.<tailnet>.ts.net:<port>`

## Minimal added tests (beyond those above)

- **Late POST after re-pair to the same host.** Re-pair to the same host process, so the generation is unchanged. Submit a new operation on the same control. When the old POST reply arrives, the new operation's status must not change.
- **Pairing origin not leaked to the results file.** The `docs/reviews/*-result.json` output contains no `ts.net` substring and no token.

## Optional suggestions

- Build the URL from validated ASCII `[a-z0-9-]` labels rather than parsing the user's string, which closes IDNA, punycode and percent-decoding gaps.
- Trim a pasted trailing newline from the key, with a specific error message for it.
- In teardown, terminate the route first, so exposure ends before the bridge and session stop.
- `connectionProxyDictionary = [:]` may not disable a system or PAC proxy. TLS still protects the token, but connectivity failures would be confusing.
- Warn against Universal Clipboard for key transfer, because it syncs through iCloud.
- Note for the APNs slice: `WhenUnlockedThisDeviceOnly` blocks reading the credential while the device is locked.
- iOS Keychain items survive app reinstall. That's harmless here because tokens are per-process, but it's worth stating in the pairing UX.