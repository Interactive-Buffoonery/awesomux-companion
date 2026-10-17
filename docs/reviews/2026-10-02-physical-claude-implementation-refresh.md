# Physical foreground adversarial implementation review

Adapter Claude Code; actual model claude-opus-5-5. Tools/settings/hooks/MCP disabled. Scope manifest physical-claude-implementation-refresh-scope.json.

# Affected-scope refresh: physical foreground B1 / S1 / S2 / S3

**Reviewer:** claude-opus-5-5. This was a read-only review of the embedded current files, the intervening diffs and the original final report, which I have not relabelled. I ran no tools, did not compute SHA-256 values, and executed no tests. I checked that each diff is consistent with the corresponding embedded current file. Hash verification and the RED/GREEN counts (34 bridge, 26 iOS) are your reported evidence, not mine. The counts match by enumeration: 31 + 3 bridge tests and 25 + 1 iOS tests.

## Verdict

**PASS for the prepared source. No remaining blocker.**

- **B1** is resolved in source.
- **S1, S2 and S3** are fixed, each with a regression test that targets the original defect.
- **S4** stays deferred. This is acceptable because it fails conservative: data is retained and nothing is reset.
- I found no new blocker in the affected dependencies.

---

## B1: native executable guard

**Magic-number set.** Comparing the first 4 on-disk bytes:

| Bytes | Format |
|---|---|
| `feedface` / `cefaedfe` | 32-bit Mach-O, big- and little-endian |
| `feedfacf` / `cffaedfe` | 64-bit Mach-O, big- and little-endian; `cffaedfe` is a thin arm64/x86_64 binary |
| `cafebabe` / `bebafeca` | Fat (universal) binary and its byte-swapped form |
| `cafebabf` / `bfbafeca` | 64-bit fat binary |

- This set is complete and correct for Apple Mach-O, including little-endian thin binaries.
- `#!` scripts are rejected.
- A short read (fewer than 4 bytes) fails the membership check, so the file is rejected.
- Java class files share `cafebabe`, but `execve` would fail on one rather than orphan a grandchild. This has no impact.

**Open path.**
- `realpath`, then `O_NOFOLLOW | O_NONBLOCK`, then `fstat` with `S_ISREG`.
- A symlink swapped in after `realpath` gives `ELOOP`, which becomes `OSError`, then `RouteFailure`.
- A FIFO cannot block the open.
- `RouteFailure` is not an `OSError`, so it propagates.
- The `finally` always closes the file descriptor.

**Every call is guarded.**
- `__init__` validates.
- `read()` validates, and serves both `preflight` reads plus `status()`.
- `command()` validates, and its argv is the only one the watcher runs.
- No other `subprocess` call uses `self.executable`.

**Failure paths stay owned.**
- If construction fails, `PrivateRoute(deadline=…)` raises in `launch_probe` before `root` or any process exists.
- If `command()` fails inside `start`, the error is caught by the `except BaseException` wrapping it, then `close()` runs; there is no watcher yet.
- If validation fails during `close()`'s readback, the result is `absent` / `preserved = False`. That is conservative. Process stop does not depend on the CLI, because it uses the `Popen` handle and the supervisor identity.

**Residuals (not blockers):**
- **Validate-then-exec window.** There is a gap between the check and `execve` by path, so this is not fd-exec. Exploiting it requires same-user write access to `/Applications/Tailscale.app`, which already defeats the threat model.
- **What Mach-O proves.** It proves the binary is not a shell wrapper. It does not prove the binary never forks a helper that owns the Serve session.
  - Your read-only finding that the installed wrapper `exec`s is your evidence; I did not review it.
  - The live `close()` readback remains the actual proof of ownership.
- **Test gap: "current drift".** `test_shell_wrapper_rejected_and_symlink_resolves_binary` rewrites the binary and then constructs a *new* `TailscaleCLI(str(link))`. The rejection therefore comes from `__init__`, not from the per-call revalidation in `command()`.
  - Per-call revalidation is correct by inspection only.
  - Cheap hardening: construct the CLI before the rewrite, then call `command()` (and ideally `read()`).

## S1: launcher teardown helper rename

- `def stop` is now `def stop_process`, and all three call sites are updated (the definition, desktop and server).
- `stop` is now assigned only by `stop=threading.Event()`. No other rebinding exists in `main`, so the handler closure cell stays an Event through `finally`.
- **The test is sound.**
  - It compiles the actual `stop` assignment, the `for sig` loop and the `killpg` helper into one function scope, so the closure semantics match `main`.
  - Under the old name, the returned `stop` would be a function and the handler would raise `AttributeError`, which explains the reported RED.
- **Limitation:** the test only guards rebinding by the `killpg` helper, not by any future `stop` assignment elsewhere in `main`. This is acceptable.

## S2: failed delete from `loadFailed`

- `disconnectHost` captures `wasLoadFailed` before invalidation. On a failed `clear()` it restores `.loadFailed` and sets `activeHostLabel = nil`, so `canPair` becomes false.
- The `activate` and `retryConnection` catch blocks now clear the stale label.
- **Re-activation after a failed delete stays offline.** `activate()` returns early for `.loadFailed`, `explicitlyDisconnected` is untouched (false), and `retryConnection()` is the only re-entry. The non-`loadFailed` failed-delete path still lands in `.quarantined(priorHost)`, and `activate()` returns early there too; the existing deleting loop covers this.
- A failed delete while `.quarantined` (after a failed pair) keeps `canPair` true. That is consistent with the plan, because the item was readable.
- The new test's sequence reaches `.loadFailed` through real activation before the delete fails. It asserts:
  - the state;
  - `!canPair`;
  - the nil label;
  - that the item is unchanged.

## S3: typed payload failure

- `os.write` `OSError` (`BrokenPipeError`, because Python ignores `SIGPIPE`) now becomes `WatchdogFailure`.
- The outer `except BaseException` then calls `close()`:
  - `_stop_child` kills the unreaped `Popen` child, so PID reuse is impossible;
  - `write_fd` is closed;
  - the supervisor is waited on.
- **Early-supervisor cleanup is still owned.**
  - A supervisor that never read the payload has `value=None`, so it takes no kill action.
  - One that read it stops only on an identity match.
  - The launcher side never signals anything except its own `Popen` handles.
- This also makes `test_missing_readiness_stops_child_before_returning` deterministic: whichever side of the race occurs, the result is `WatchdogFailure`.
- **Test note:** `patch('route_watchdog.os.write')` patches the shared `os` module process-wide while the block runs. That is acceptable for a serial `unittest` run. Nothing else in that window calls `os.write` from Python, and the supervisor is a separate interpreter, so it is unaffected.

## Deferred items

- **S4 deferral** is acceptable: a spurious conflict leaves the private root in place and resets nothing.
- **Awake-time lifetime** is now stated in the concrete action. There is a trivial typo in `docs/physical-validation-next-action.md`: `at most20minutes`.
- The optional suggestions remain optional.

## Coverage statement

- **Re-reviewed:** the full current text of `private_route.py`, `route_watchdog.py`, `launch_probe.py`, `test_private_route.py`, `test_route_watchdog.py`, `test_launch_probe.py`, `CompanionStore.swift`, `PairingStoreTests.swift`, the impact JSON, and the next-action doc.
- **Carried over:** all other source coverage comes from the original report, for unchanged dependencies only.
- **Not claimed:** network route, provisioning, signing, installation, Keychain runtime behaviour or live inference.
- No Git, PR or publication evidence is claimed.