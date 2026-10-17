# Physical foreground adversarial implementation review

Adapter Claude Code; actual model claude-opus-5-5. Tools/settings/hooks/MCP disabled. Scope manifest physical-claude-implementation-final-scope.json.

# Final implementation review: physical foreground Tasks 1–2

**Reviewer:** claude-opus-5-5. Read-only review of the embedded source, plan, spec and rulings. I ran no tools and executed nothing. Test counts were checked by enumeration only: 25 iOS and 31 bridge tests match the files.

## Verdict

**Tasks 1–2 are acceptable as local implementation, with one blocker before the Task 3 route trial (B1).** The iOS connection, quarantine and stale-intent logic held up under adversarial tracing. I found no path where an old-host or old-revision GET or POST changes current state or writes to a new connection. The bridge HTTP boundary and Serve diff logic are correct for the reviewed schema. B1 is about an assumption: the route-lifetime guarantees depend on something the code never checks.

---

## Blocking before any live Serve exposure

### B1. The owned "child" may not be the process that owns the Serve session

**Where:** `bridge/private_route.py` (`TailscaleCLI.__init__` and `command`) and `bridge/route_watchdog.py` (`WatchedChild`).

`TailscaleCLI` runs the hard-coded path `/usr/local/bin/tailscale`. On macOS GUI installs, that path is commonly one of two things:

- a symlink into `Tailscale.app`, which is fine;
- a `#!/bin/sh` wrapper that runs `.../Tailscale.app/Contents/MacOS/Tailscale "$@"` **without `exec`**.

In the wrapper case, the recorded child and its identity belong to `sh`. The process holding the `WatchIPNBus` session, and therefore the foreground entry, is a grandchild. Every lifetime path then signals only `sh`:

- the launcher's `_stop_child`;
- the supervisor's `stop_identified`;
- the deadline;
- parent-EOF handling.

SIGTERM kills `sh` and orphans the grandchild, so the route stays live past every watcher. It also outlives the backend, which is exactly the port-reuse risk the README names.

`PrivateRoute.close()` would honestly report `owned_route_absent: false`. But the deadline and single-watcher guarantees would be silently void, and the plan forbids `off` or `reset` as a recovery.

The preflight only proves the path runs (`version --json`); it doesn't prove the path *is* the CLI process.

**Minimal fix:**

1. In `TailscaleCLI.__init__` or `preflight`, resolve `os.path.realpath(executable)`.
2. Open the resolved file with `O_NOFOLLOW` and require it to be a regular file.
3. Require a Mach-O magic number (`feedfacf`, `cafebabe`, or `bebafeca`). Reject `#!` and anything else.
4. Use the resolved path in `command()` and in every `read()`.

**Regression test:** In `test_private_route.py`, cover two cases:

- a temp `#!/bin/sh` executable makes `preflight()` raise `RouteFailure`;
- a symlink to a fake Mach-O-magic file yields a `command()` that uses the resolved path.

If you'd rather record evidence than change code, a read-only `file`/`readlink` check of the installed path showing a direct Mach-O would also clear this. The source guard is cheap and keeps the guarantee if the installation changes later.

---

## Should-fix (cheap; not exposure blockers)

### S1. `launch_probe.main` rebinds `stop` during teardown

The signal handlers close over the `stop` Event:

```python
lambda *unused: stop.set()
```

In `finally`, `def stop(p):` rebinds that same cell to a function. A second SIGINT, SIGTERM or SIGHUP after that point (the operator presses Ctrl-C again) raises `AttributeError` in the main thread.

- **Inside an `attempt(...)` call:** the error is swallowed, but SIGKILL escalation for the server or desktop is skipped.
- **Outside one** (the endpoint check, the trash condition, `output.write_text`): the error aborts the rest of cleanup and the result file.

Route cleanup happens before the rebind, so this is a teardown-robustness problem, not an exposure problem.

**Fix:** rename the helper (for example `stop_process`).

**Test:** grep-level or AST check, or call the installed handler after reaching `finally` in a patched run.

### S2. Failed disconnect from `loadFailed` re-enables Pair over an unread item

`CompanionStore.disconnectHost` always sets `.quarantined(priorHost)`. That makes `canPair` true, which contradicts the plan: "typed load errors expose retry/disconnect, not a pairing form that overwrites unread data."

There is also a stale label. In `activate()`'s catch, `activeHostLabel` is not cleared, so the inbox shows the last loaded host while in `loadFailed`.

The user intent is deletion, so the risk is low, but this is a contract deviation.

**Fix:**

- In `disconnectHost`'s catch, restore `.loadFailed` if that was the prior state.
- In `activate`'s and `retryConnection`'s catch, set `activeHostLabel = nil`.

**Test:** `failLoad` → `activate` → `failDelete` → `disconnectHost` throws → assert `connectionState == .loadFailed`, `!canPair`, and `activeHostLabel == nil`.

### S3. `WatchedChild` raises the wrong exception on early supervisor exit

If the supervisor exits before the payload `os.write`, the call raises `BrokenPipeError`, not `WatchdogFailure`. Cleanup still stops the child, so this is safe. But `test_missing_readiness_stops_child_before_returning` races on it.

**Fix:** wrap the write and convert `OSError` to `WatchdogFailure`.

### S4. Cleanup waits on the wrong condition when the session ID is unknown

When `verify_owned_entry` failed after the route was created, `self.session` is `None`. `PrivateRoute.close` then skips its 3-second wait, because the loop condition depends on the session ID. Asynchronous foreground deletion therefore reads as a spurious conflict.

This errs conservative: the private directory is retained.

**Fix:** loop until `normalize(after) == normalize(before)` or timeout.

---

## Verified by inspection

**Late old-host responses, including the same generation and control ID.**
- Each `refresh` and `send` captures `connectionRevision` synchronously, with no suspension before capture.
- Results apply only if revision, generation and operation ID all still match.
- The lease task is fenced by `epoch`, and `invalidateConnection` bumps both revision and epoch.
- On the bridge side, `transport.answer` binds `conn` and `expected_generation`, and `ProxyConnection.write` rejects a closed or wrong-generation connection.
- Queued envelopes are cancelled by `_writer`.

**The displayed-intent regression is real.**
- In the same-host, same-generation re-pair case, `connectionRevision` is the *only* input that differs.
- `testQueuedDisplayedIntentCannotCrossReplacementOrSameHostRePair` exercises exactly that case: the factory returns the same `FakeAPI` and the same fixture control ID.
- The reported RED result is therefore consistent with a real hole.
- **Caveat:** the test drives `store.submit` directly. Two UI properties hold by inspection only:
  - The tap freezes `context`, answers and confirmation inside the Task closure.
  - `.id(revision:generation:control)` resets `@State`.
- `connectionRevision` is `@ObservationIgnored`. Identity refresh therefore relies on `snapshot = nil` always accompanying a revision bump. That is true today; making it observed would be sturdier (optional).

**Quarantine and Disconnect across activation.**
- `activate` returns early for `.quarantined`, `.loadFailed` and `explicitlyDisconnected`.
- `pair` builds the client, then saves, then activates. A failure leaves the API nil and the prior Keychain item untouched.
- Retry reloads, recreates the client (because the API is nil), and needs a fresh GET before controls enable.

**Keychain.**
- Uses `SecItemUpdate`, falling back to add only on `errSecItemNotFound`.
- Accessibility is `WhenUnlockedThisDeviceOnly`; synchronization is off; there is no access group.
- Load re-validates and has no fallback on error.

**Compile-time separation.** `DevelopmentConfiguration`, `InMemoryHostCredentialStore` and the dev init/state are all gated on `DEBUG && simulator`. Release and device builds get only `HostCredentialStore`.

**TLS and credential leakage.**
- Server trust uses `performDefaultHandling`; every other challenge is cancelled with a nil credential.
- Redirects are refused, backed by an `http.url == request.url` check.
- Credential storage, cookies and cache are nil; the proxy dictionary is empty.
- The token is restricted to printable ASCII, which blocks header injection.

**Bridge HTTP.** The order is:
1. Auth, using `compare_digest`.
2. Exactly one Host header, matching loopback or the configured proxy host. There's no forwarded-header trust and Origin is rejected.
3. Strict POST framing: no `Transfer-Encoding`, digit-only `Content-Length`, a 64 KiB cap before reading, and exact `Content-Type`.

**Serve diff.**
- Ports in TCP, Web, `AllowFunnel` and nested foreground entries all count as occupied.
- Unknown keys (for example `Services`) fail closed.
- Exactly one new foreground entry with the exact TCP/Web shape is accepted.
- The rest of the configuration must equal the baseline.
- No `off`, `reset`, `--bg` or Funnel is issued.

**Watchers.**
- The supervisor starts first and has its own session.
- Pipes are non-inheritable and `close_fds` is on, so EOF is reliable.
- The `proc_bsdinfo` offsets check out (136 bytes, start time at offset 120, zombie status = 5).
- PID reuse is fenced by start time.
- The launcher's `_watch` covers supervisor death and the deadline.
- Teardown retires the route before HTTP and the backend.

---

## Optional suggestions

- Call `session.finishTasksAndInvalidate()` in `BridgeClient` `deinit`. Replaced clients currently leak a `URLSession`; in-flight POSTs may still finish, as intended.
- In `do_POST`, catch `RecursionError` from deeply nested JSON and return 400. This only matters for authenticated callers.
- Add the plan-named "relaunch host identification" test: a fresh store with a stored item, then `activate`, then assert the label is shown and controls are disabled before `refresh`. The behaviour is right, but the explicit test is absent.
- `time.monotonic` and `systemUptime` exclude system sleep on Darwin, so "20 minutes" means awake time. While asleep the route is unreachable, but say so in the exposure authorization.
- The unit-test bundle references simulator-only types, so it won't compile for a device or Release destination. That's fine, but note it so no one expects on-device unit runs.

## Unexercised physical boundaries (not claimed)

- That the Serve readback really has the exact `TCP`/`Web`/`Proxy` shape, and that foreground session deletion happens when the recorded PID is killed. The `close()` readback will show this on the normal path. The deadline and supervisor-kill paths stay untested live.
- That Serve preserves the inbound `Host` header (`r.Out.Host = r.In.Host` is expected, but unverified) and keeps `Content-Length` framing from HTTP/2 to HTTP/1.1.
- That `URLSession` routes server-trust challenges to the per-task delegate. The test calls the method directly; default handling is safe either way.
- Phone TLS, certificate issuance and Certificate Transparency, tailnet reach, Keychain runtime behaviour on device, signing and installation.
- Combined launcher and supervisor death, and unacknowledged startup. These are documented residuals, not demands.

No Git, PR or publication evidence is claimed or implied by this review.