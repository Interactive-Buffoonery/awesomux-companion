# iOS terminal renderer spike

This throwaway app embeds `GhosttyTerminal` at exact revision
`42bacd1339f323a693ddbca779295f4f77e5a697` and exercises its real Metal-backed
iOS view with an in-memory session. It does not start a shell, create a PTY, or
use the network.

The automatic launch check feeds an ANSI and UTF-8 fixture, waits for the
in-memory parser queue to drain, moves the cursor to row 5, column 10, and sends
a Device Status Report cursor query (`CSI 6 n`). It passes only when libghostty
sends the exact `CSI 5;10 R` response through the session's output callback.
This proves that the native surface attached and the terminal parser completed
a deterministic round trip. It does not prove what appeared on screen or that
accessibility works.

The app writes its latest evidence to
`Library/Application Support/IOSRendererSpike/latest-evidence.json` inside its
container. Physical-device rendering, selection, keyboard/IME, and VoiceOver
results remain `pending` until a tester records pass or fail in the app.
Evidence includes the Debug or Release configuration, a SHA-256 hash of the
bundled source manifest, and up to 100 timestamped callback chunks so a keyboard
or IME observation can be tied to the emitted bytes.

## Release gate

This pinned candidate is suitable for the experiment only. Its iOS rendering
patch explicitly looks up the private `CAIOSurfaceLayer` class, and that class
name remains in the linked app binary. Treat the release gate as failed even
when the app builds and renders: the terminal UI must not ship with this
dependency unless the private API use is removed. See
`evidence/private-api-scan.txt` for the source and linked-artifact checks.

## Simulator build

```sh
cd spikes/ios-terminal-renderer
./generate.sh
xcodebuild -project IOSRendererSpike.xcodeproj -scheme IOSRendererSpike \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Physical device

Open `IOSRendererSpike.xcodeproj`, select the connected iPhone, and run the
`IOSRendererSpike` scheme. Automatic signing uses team `7CNK4YPCQX` and bundle
identifier `com.interactivebuffoonery.awesomux.renderer-spike`.

Record each observation in the app. A parser self-check pass must not be
reported as a visual, selection, keyboard/IME, VoiceOver, or release-acceptance
pass.

## Local release archive

This produces a signed local archive only. The spike has no upload or
TestFlight path.

```sh
cd spikes/ios-terminal-renderer
./generate.sh
xcodebuild -project IOSRendererSpike.xcodeproj -scheme IOSRendererSpike \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$PWD/build/IOSRendererSpike.xcarchive" archive
```
