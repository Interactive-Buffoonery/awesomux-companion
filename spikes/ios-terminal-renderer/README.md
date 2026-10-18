# iOS terminal renderer spike

This small app tests Ghostty’s iOS renderer with an in-memory byte stream. It
starts no shell or PTY and uses no network transport. Companion’s production UI
is unchanged.

The Swift wrapper is pinned to `Lakr233/libghostty-spm` revision
`42bacd1339f323a693ddbca779295f4f77e5a697`. The native library is rebuilt from
Ghostty `1e9e14af5df14211892f5fc15fd21a49c7d94868`, the package’s ordered patches,
and our public `CAMetalLayer` patch. It replaces the original private
`CAIOSurfaceLayer` presentation path. See `native/README.md` for build details.

## Build the library and app

```sh
cd spikes/ios-terminal-renderer
./native/build.sh 1e9e14af5df14211892f5fc15fd21a49c7d94868
# Use the output paths printed by that build:
python3 integrate-native.py /path/to/GhosttyKit.xcframework /path/to/libghostty-spm
./generate.sh
xcodebuild -project IOSRendererSpike.xcodeproj -scheme IOSRendererSpike \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' build
```

Integration copies the exact pinned Swift package into the ignored build folder
and changes its binary target to the local XCFramework. It checks both native
slices against the source build receipt, records their hashes in the app’s `native-build.json`, and never falls
back to downloading the original binary. `generate.sh` requires that integration
step and includes all files under `ThirdPartyNotices/` as app resources.

For a signed local device archive:

```sh
xcodebuild -project IOSRendererSpike.xcodeproj -scheme IOSRendererSpike \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$PWD/build/IOSRendererSpike.xcarchive" archive
```

Signing uses team `7CNK4YPCQX` and bundle identifier
`com.interactivebuffoonery.awesomux.renderer-spike`. There is no upload path.

## Checks

Launch feeds ANSI and Unicode, moves the cursor to row 5, column 10, and queries
its position. The check passes only for the exact callback `ESC[5;10R`.
Screenshots and device observations establish visual behavior separately.

Use Show keyboard, type `abc`, then Hide keyboard. Input is sent to the output
callback; it is not echoed into the terminal. Select and copy `GhosttyTerm`,
rotate the device, and switch away and back to check drawing after layout and
app changes. The “Check surface rebuilds” button changes the font configuration
five times and requires a fresh cursor reply and exactly one Metal layer after
each rebuild. It also switches blending from native to linear and back, checking
the Metal pixel format after each change. The check can be run repeatedly.
Launch with `--check-surface-rebuilds` to run that check
automatically. IME and VoiceOver checks are deferred.

The app writes JSON to
`Library/Application Support/IOSRendererSpike/latest-evidence.json`. It includes
the build configuration, source-manifest hash and timestamped callback chunks.
The report and saved results are in `../../docs/ios-terminal-renderer-spike.md`
and `evidence/`. Earlier evidence files describe the original downloaded binary;
files prefixed `public-metal` describe the replacement.
