# Native implementation handoff

New artifact ready for parent integration:

`artifacts/public-metal-verified/GhosttyKit.xcframework`

Receipt: `artifacts/public-metal-verified/build-receipt.json`

- Device arm64 SHA-256: `daa1ba707fa347de5fab3c6f5d1c6dcfc55303ab44bdb2b4d7f04e460c195820`
- Simulator arm64 SHA-256: `ac806f2cf37c52af88d69fc2fa3f105ef898c3ba45d8ecd42639c4243f885e2b`
- Overlay SHA-256: `763846996501ab05b07d72612b5365518e1f6545a585c72abed39b7221d4c0bf`
- Receipt SHA-256: `e820227c96bc317bdd5fe6084f1a5036babfb5669d5f9f7a9d887afedc98d1e9`

Dynamic blending is handled. Config reload changes api.blending and invalidates
frame targets under draw_mutex. encodePresent compares the target format with
the layer before nextDrawable; on mismatch it queues a retained-layer block to
main and drops presentation of this frame. The block changes pixelFormat only
when needed, then calls setNeedsDisplay. Existing cells_rebuilt/deferred retry
and command-buffer completion release the permit normally. Compatible frames
still blit and present in the same command buffer.

The block captures objc.c.id, which the pinned zig-objc copy/dispose helpers
retain/release. It captures no renderer/target pointer. It skips work after
main-thread teardown clears display_cb; removeFromSuperlayer remains in teardown.
There is no synchronous main dispatch or display callback invocation under the
draw mutex. Top-left gravity and the callback/context null guard remain intact.

Queued format requests are not coalesced. Rapid configuration changes may produce
transient stale requests; after main drains them, dirty retry corrects to the
current target. No unresolved source blocker was found in the focused self-review.
This is not an independent review or runtime proof. Parent should exercise
blending reload in both directions and its repeated-rebuild layer-count harness.

Both build.sh and the executed rebuild-reviewed.sh now snapshot inputs before
compilation and generate artifact-local build-receipt.json after both slices,
packaging, binary audit, and input stability verification. The receipt records
packageRevision, ghosttyRevision, patchSHA256, 5918 relative sourceHashes,
sourceDirectory, exact Zig version/executable hash, Apple compiler/Xcode identity,
recipe and driver hashes, ordered patch hashes, and relative archiveHashes.
Archive keys are relative to GhosttyKit.xcframework; source keys to sourceDirectory.
Parent must verify actual archive hashes and current overlay hash, then propagate
the receipt unchanged. Older artifacts were not retroactively stamped.

Executed successfully:

- zsh rebuild-reviewed.sh: both native slices using local incremental caches,
  XCFramework packaging, binary audit, and receipt creation.
- python3 audit-reviewed.py: exact overlay reconstruction against saved pre-overlay
  baseline, all three renderer files byte-identical to build source, source and
  receipt hash verification, C export checks, and older artifact preservation.
- Negative receipt check: altered pre-build overlay hash rejected with no receipt.
- Zig formatting, native source diff checks, Python compilation, shell syntax.

Both archives are arm64, contain CAMetalLayer and presentDrawable:, omit
CAIOSurfaceLayer, and export required app/surface C APIs. Evidence is beside the
XCFramework: binary-audit.json, export-audit.json, build-inputs.json,
build-receipt.json, source-review.txt, receipt-validation.txt, source.sha256,
all-modified-source.sha256, inputs.sha256, complete-source.diff,
patch-reconstruction.txt, previous-artifact-preserved.txt, and build logs.

public-metal-final and public-metal-reviewed archives retain their original
hashes. The fresh-clone build.sh wrapper was updated but not rerun. No app builds,
device operations, commits, pushes, or parent-file edits were performed. Parent
owns integration and runtime validation. IME and VoiceOver remain deferred.
