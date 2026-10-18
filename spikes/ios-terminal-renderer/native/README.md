# Native iOS renderer source build

Build only iOS arm64 and iOS Simulator arm64 from the pinned package's
ordered patch stack, then apply `0022-ios-public-metal-layer.patch`:

```sh
./build.sh 1e9e14af5df14211892f5fc15fd21a49c7d94868
```

Requires Xcode with Metal tools, Git, Python 3, curl, and `trash`. The script
installs Zig 0.16.0 locally after checking the archive SHA-256. It never edits
an installed compiler or global cache. Each invocation uses fresh source and
output directories; generated sources, caches, toolchain and artifacts are
ignored. The package pin is `42bacd1339f323a693ddbca779295f4f77e5a697`,
Ghostty build revision 3. The downloaded prebuilt XCFramework is untouched.

The resulting `artifacts/<run>/GhosttyKit.xcframework` contains only the two
arm64 slices. Each run records the build log, ordered patch hashes, source
diff, toolchain hash, archive hashes, binary audit and `build-receipt.json`. `verify-artifacts.py`
requires both archives to contain public drawable presentation and rejects
any archive containing the private presentation class name.

The iOS patch uses a public CAMetalLayer subclass. Offscreen IOSurface-backed
textures and host-managed terminal I/O remain unchanged. The final blit and
`presentDrawable:` are encoded before commit in the rendering command buffer;
completion still releases the swap-chain permit. Nil or mismatched drawables
leave `cells_rebuilt` true under the draw mutex and schedule a deferred main
queue display request. Layer
attachment, layout and pixel-format changes run on the main thread; first display is requested
asynchronously on main when necessary. Non-iOS presentation is unchanged.

The app integration owner must link this local XCFramework, verify actual
simulator/phone behavior and gather app evidence. This build does not perform
app builds, launch devices, validate IME or validate VoiceOver.

Verified incremental rebuild: `zsh rebuild-reviewed.sh` uses the existing
`work/ghostty`, local Zig toolchain, and device/simulator caches. It requires
`artifacts/public-metal-verified` not to exist, preserving older artifacts.
After completion, `python3 audit-reviewed.py` records source hashes, exports,
exact overlay reconstruction, receipt verification, and preservation of both
older `public-metal-final` and `public-metal-reviewed` archives. The overlay
includes the new `MetalLayer.zig`; fresh-source `build.sh` applies the same patch.

Config reload can change blending and target format. Before acquiring a drawable,
a mismatched target queues an Objective-C block retaining the layer. On main,
the block checks that the display callback still exists, updates `pixelFormat`
only if needed, and requests display. The dropped frame follows the normal dirty
retry and command-buffer completion path. Requests are serialized by draw_mutex
and the main queue, but are not coalesced. Rapid reloads can cause transient stale
format requests; after the queue drains, dirty retry corrects the layer to the
current target. No synchronous dispatch or renderer pointer capture is used.

Both build entrypoints call `build-receipt.py begin` before compilation and
`finish` after packaging and binary verification. Finish rejects changed inputs
and refuses to overwrite a receipt. `build-inputs.json` contains the pre-build
snapshot; schema 2 `build-receipt.json` additionally binds the two packaged archive
hashes and the complete XCFramework regular-file set in `frameworkHashes`,
including Info.plist, headers and any other packaged metadata. Added, removed or
changed files fail integration, as do symlinks or non-regular file entries.
The identity helper's hash is itself recorded among the recipe inputs.
The receipt includes packageRevision, ghosttyRevision, patchSHA256, sourceHashes,
sourceDirectory, exact Zig version/executable hash, Apple compiler identity,
recipe/driver hashes, target configuration and ordered patch hashes. Source keys
are relative to sourceDirectory; archiveHashes keys are relative to the adjacent
GhosttyKit.xcframework. The receipt is build association evidence, not a signature.

Current integration requires a fresh schema 2 artifact-local receipt, compares
both archiveHashes and the complete frameworkHashes set, verifies patchSHA256
against the current overlay, and propagates provenance unchanged. Schema 1
receipts are historical evidence only and are rejected for current acceptance.
Run `build.sh` from source to produce a new schema 2 pre-build snapshot and
finished receipt; never augment an old receipt or attach the latest overlay hash
to an older binary. Both build entrypoints use the same begin/finish interface;
no receipt is retroactively added to older artifacts.
