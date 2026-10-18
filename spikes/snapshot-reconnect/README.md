# Snapshot and reconnect investigation (#17)

Captured 2026-10-18. Shipping behavior is unchanged; a separate diagnostic app
was added after the capture. Chat view remains unbuilt.

## Result

Attach reconstructs retained terminal cells, not the original byte stream.
Use a terminal model at the Mac's dimensions for Watch. Earlier command history
cannot be reconstructed reliably: show **“earlier history incomplete”** instead
of inferring commands, wraps, or exit codes from displayed text.

## Captured behavior

- **OSC 133:** input contains A/B/C/D, including exit codes 7 and 3. Live
  output matches the injected bytes exactly. Reattach contains zero OSC 133
  sequences, both for the older scrollback command and the visible command
  written while disconnected. Prompt text survives; semantic boundaries do not.
- **Soft wraps:** 35 `W` characters at 20 columns become 20 characters, CRLF,
  then 15 characters in the snapshot. The original contains no newline there.
  A receiver cannot distinguish this from a hard newline using snapshot bytes.
- **Cursor edits:** `progress 10%\rprogress 90%` plus erase-to-end reconstructs
  only `progress 90%`. Final cells survive; the sequence of edits does not.
  Visible cursor restoration is present (`CSI 6;6 H`). This is byte evidence,
  not a completed renderer roundtrip or visual assertion.
- **Command boundaries and exit codes:** neither D;7 nor D;3 survives.
  Displayed `$ demo` / `$ next` is insufficient evidence of a command boundary.
  Shell exit or zmx task-completion messages are distinct from OSC command history.
- **While away:** `AWAY`, `$ next`, and `FINAL` written after the first terminal
  client closes are present on reconnect. This demonstrates retained final
  content, not lossless replay. Overwritten, cleared, or evicted cells cannot
  be recovered from this snapshot.

## Reproduction and artifacts

Run `python3 spikes/snapshot-reconnect/capture.py /absolute/path/to/zmx`.
The script creates a private `ZMX_DIR` under `/tmp`, starts only its own `probe`
session, and kills that session in `finally`. It leaves private logs for diagnosis.
It never connects to existing user sessions. Requires the inspected 8-byte IPC
header layout and four-byte Init size payload; this is a local spike, not a
version-independent client.

The first Init establishes a 6-row, 20-column terminal. Output injection uses
zmx's Output handler (the same terminal parser used by PTY output), avoiding
shell-dependent OSC behavior. The fixture clears prior scrollback and screen,
then sends prompt marks, a progress overwrite, a soft wrap, and enough lines to
place the first command in scrollback. After disconnecting, a second command is
injected and a fresh Init obtains the reconstruction. The injector remains
connected until its output has been processed; there is no terminal client
attached during the away phase.

- `input.bin`, `live.bin`: injected first fixture and captured live Output.
- `away.bin`: bytes injected while the terminal client is away.
- `reattach.bin`, `reattach-escaped.txt`: reconstructed Output, raw and escaped.
- `result.json`: executable identity and measured results.

The existing executable reports zmx 0.8.1 and the same Ghostty dependency hash
as the inspected manifest. Its SHA-256 is recorded. It was **not rebuilt from
this source checkout**, so runtime results describe that executable, while
source findings below describe the inspected commits separately.

## Source trace

Inspected awesoMux commit `2a0b46bf20576da64f7f5035bdea256ddb147743`, with
vendor/zmx commit `480fc5eae888d0dca7cefc80aff913efeb2eb88c`.
Paths below are relative to `vendor/zmx` in the awesoMux repository.

- `src/loop.zig:1040` (`handleInit`): only serializes after PTY output and a
  prior leader Init. A leader resizes the model before serialization, then
  resizes the PTY and signals SIGWINCH. A phone must not accidentally become
  a size-changing leader; passive Watch attachment needs an explicit contract.
- `src/util.zig:816` (`serializeTerminalState`): formats scrollback with no
  terminal extras, clears the viewport, then formats visible cells with modes,
  scrolling region, keyboard and screen state. Separately restores cwd/title.
  It does not preserve an output journal or per-command records.
- Pinned Ghostty `8af6897c0afc63037a8a3efee4162a380e3a4572`,
  `src/terminal/formatter.zig`: `Options.unwrap` defaults to false; page
  formatting emits newlines for wrapped rows in that mode. The formatter has
  no OSC 133 emission. zmx's prompt-redraw rewrite cannot restore absent marks.
- `src/loop.zig:420,1360`: PTY and injected output update the retained terminal
  model. Its configured scrollback line limit bounds what can return; the
  existing pruning test at `src/loop.zig:1501` covers oldest-line removal.

## Delivery gaps and follow-up contract

1. Keep the Mac-sized terminal model for Watch; do not treat these hard line
   breaks as recoverable logical wraps. Reflow needs a separate metadata format
   or a proven snapshot change, including the scrollback/viewport seam.
2. Mark earlier history incomplete on initial attach/reconnect. Any future Chat
   history needs durable command boundaries and exit status plus an explicit
   completeness range. Do not parse prompt-looking text as commands.
3. Define snapshot/live handoff, dimensions, retention/truncation reporting, and
   stream generation/sequence identity in the phone transport before claiming
   gap-free recovery. The current iOS client exposes agent polling, not this
   terminal subscription.
4. Still unverified: phone-to-Mac reconnect, leader/follower resize behavior in
   the eventual transport, real PTY offline output, alternate screen, wide and
   combining characters, split control sequences, long outages/eviction,
   production renderer behavior and accessibility. This initial capture ran no
   iOS build or UI checks; later diagnostic results are in the verification ledger.
   No hosted CI ran.

The cheap regression signal is this fixture's live-vs-snapshot comparison:
assert semantic marks and wrap provenance explicitly before relying on them.
Changing the transport or implementing that signal as a product gate is follow-up
work, not part of this capture.

## Diagnostic app and fixture endpoint

The `AwesoMuxDiagnostics` scheme adds a separate local test app. It shares
companion source but has its own bundle identifier and does not require pairing
to open the test screen. Only that target links the experimental Ghostty renderer;
its private `CAIOSurfaceLayer` dependency remains a release blocker. This is not
a TestFlight or production Watch implementation.

`Run local replay` creates two fresh renderer models. Both must report 20×6
before any bytes are accepted. One receives `input.bin` plus `away.bin`, the
other receives `reattach.bin`. Viewport text and DSR cursor responses must match,
then match again after identical live continuation. This does not recover
semantic history or prove scrollback/visual/accessibility fidelity.

For network tests, start the synthetic fixture server on the Mac:

```sh
python3 spikes/snapshot-reconnect/fixture_server.py \
  --zmx /absolute/path/to/zmx --host 0.0.0.0 \
  --advertise-host MAC_LAN_IP --port 8769
```

It prints a private `connection.json` path, not its token. That file holds the
endpoint URL, per-launch token, exact leaf certificate SHA256, and a diagnostic
deep link. Use those values in the diagnostic app, then choose Connect. The
certificate and credentials are ephemeral; restart requires new configuration.
No pairing keys or user terminal output are exposed. TLS pinning applies only
to this explicitly configured fixture endpoint; never install a root CA or
relax production companion trust to run this experiment.

The endpoint runs a private zmx session at 20×6 and injects only the captured
fixture plus numbered synthetic output every second. Snapshot and event cuts
are serialized under one lock. `GET /snapshot` supplies a run UUID, dimensions,
sequence and base64 bytes; `GET /events?runID=UUID&after=N` supplies contiguous
later events. Wrong generation, future sequence, or evicted events returns 409,
requiring a fresh snapshot. The event queue retains 256 chunks. Both responses
and client reads have a 256 KiB cap; excessive snapshot history fails rather
than truncating silently. This polling fixture transport is not the eventual
production Watch subscription.

The server records synthetic event bytes and latest snapshot in its private
run directory. Stop with Ctrl-C to kill only that run's session. Temporary TLS
key/configuration files remain in that mode-0700 directory for the session's
lifetime and diagnosis; never commit or share them. Use `trash` for cleanup.
The endpoint is not installed as a service or scheduled task.

Endpoint checks:

```sh
python3 spikes/snapshot-reconnect/verify_endpoint.py /private/run/connection.json
python3 spikes/snapshot-reconnect/test_fixture_server.py /absolute/path/to/zmx
```

The first checks HTTPS authorization, snapshot-to-event ordering, rejected
stale generations/future sequences, and a fresh reconnect snapshot. The second
starts its own private session and checks event eviction and concurrent
snapshot/event boundaries. Neither is phone evidence.

On a physical phone, separately record rendering and reconnect observations.
Test an intentional Disconnect/Reconnect first, then background/resume and a
real network interruption while the fixture keeps producing numbered output.
Reconnect must start a fresh model; a transport failure must remain visible and
must not pass the manual reconnect check. Export JSON from the screen. Actual
production pairing, Mac leader/follower resize behavior, VoiceOver, and
production subscription recovery remain separate follow-up checks.

Current executed results and artifact limits are in [verification.md](verification.md).
The source grid is now independently checked before fixture generation: a
cursor move beyond both edges (`CUP999;999`) must serialize back as `CUP6;20`.
The fixture then clears that probe. This validates zmx's retained-model grid
without relying on the dimensions originally requested by Init; raw probe
bytes are saved. The phone still independently requires a real20×6 renderer
report. Use the Mac's LAN IP or `.local` name for HTTPS; arbitrary dotted names
are outside the diagnostic target's local-network ATS exception.
