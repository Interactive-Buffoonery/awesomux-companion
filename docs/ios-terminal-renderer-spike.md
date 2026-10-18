# iOS terminal renderer spike — issue 30

The source-built renderer draws through public `CAMetalLayer` APIs. It works in
the test app on Simulator and Shiny Blue (iPhone 16 Plus, iOS 27.0). The original
private-API blocker has been removed from this build. Companion’s production
terminal UI is unchanged.

## What changed

The original downloaded library looked up Apple’s private `CAIOSurfaceLayer`
class. We replaced its iOS presentation code with a `CAMetalLayer` subclass,
`GhosttyPublicMetalLayer`. Ghostty still renders into its offscreen textures;
a blit copies the final image to a drawable and presents it in the same command
buffer. The existing frame permit is released after that GPU work completes.
Unavailable or wrong-sized drawables schedule another draw. Layer callbacks are
cleared before teardown, and old layers are removed from their parent.
Blending changes update the layer’s pixel format on the main thread and retry
the frame.

The app now uses a locally rebuilt XCFramework rather than the downloaded
binary. Its bundled `native-build.json` records the patch and library hashes.
Both native slices and linked apps were checked for the new renderer and the
absence of `CAIOSurfaceLayer`. IOSurface remains in use for offscreen textures;
IOSurface itself is a public API.

## Dependency and build record

| Input | Pin |
|---|---|
| Swift wrapper | `Lakr233/libghostty-spm` at `42bacd1339f323a693ddbca779295f4f77e5a697` |
| Ghostty | `1e9e14af5df14211892f5fc15fd21a49c7d94868`, package build 3 |
| DisplayLink | 3.0.1 at `41bea2661e04bebcb1c4f15fc0b6197850100fdd` |
| Compiler | Local Zig 0.16.0; system Zig unchanged |
| Targets | iOS arm64 and iOS Simulator arm64 |
| Native patch | `spikes/ios-terminal-renderer/native/0022-ios-public-metal-layer.patch` |
| Dependency updates | Sarah |

The package’s ordered patches are applied before our renderer patch. The native
build runs in isolated source/cache/output folders. Build stages were executed
and both slices compiled; the full fresh-clone wrapper was not separately rerun.
`native/build.sh` documents that reproducible pipeline. Build logs, source hashes
and native review notes remain under its ignored `artifacts/public-metal-verified/`
folder; selected receipts are saved in the spike’s evidence folder.

## Verification

| Check | Result |
|---|---|
| Simulator build | Passed |
| Signed device Release archive | Passed; signature verified |
| iPhone install and launch | Passed |
| ANSI color, box drawing, emoji, Japanese, Arabic and combining marks | Visible in Simulator and iPhone screenshots |
| Exact parser response | Both return `ESC[5;10R` (`1B 5B 35 3B 31 30 52`) |
| Basic keyboard | Simulator callback contains `61 62 63`; Sarah confirmed the phone check |
| Show and hide keyboard | Simulator exercised; Sarah confirmed the phone check |
| Select and copy `GhosttyTerm` | Sarah confirmed on the phone |
| Rotation / resize | Simulator portrait and landscape render; Sarah confirmed the phone check |
| Switch away and back | Simulator exercised; Sarah confirmed the phone check |
| Rebuild regression | Five rebuilds on Simulator and phone; one Metal layer and a fresh cursor reply after each |
| Live blending changes | Both platforms report pixel formats 80 → 81 → 80; Simulator repeat also passes |
| Acknowledgments | All 22 source notice files match the signed app’s bundled copies |
| Private presentation class | Absent from both rebuilt archives and linked app binaries |
| IME composition and cancellation | Deferred at Sarah’s request |
| VoiceOver terminal content | Deferred at Sarah’s request |

Sarah tested the first public renderer build, before the teardown and blending
fixes. Its identity is saved in `public-metal-user-check-native-build.json`.
Final Simulator and phone builds have separate rebuild, format and screenshot
results tied to their source manifest in `public-metal-release-receipt.json`.

Sarah answered “yes it does” to the explicit phone checklist: show keyboard,
type `abc`, hide keyboard, select/copy `GhosttyTerm`, rotate, and switch away/back
while confirming the terminal still draws correctly. That is a tester report;
the JSON’s manual flags are not substituted for it. No IME or VoiceOver result is
inferred from that answer.

The cursor query proves parser/callback integration, not visual rendering.
Screenshots and the separate phone observations supply the visual checks. The
spike starts no shell or PTY and has no network transport. It does not prove a
production remote terminal, memory-pressure recovery, GPU starvation recovery,
or exhaustive create/destroy stress testing.

## Acknowledgments

The app preserves the original six notices and adds 16 files for libraries and
data bundled with Ghostty. Exact sources, file comparisons, font byte matches
and license texts are recorded in the [license audit](ios-terminal-native-license-audit.md).
z2d’s notice includes MPL-2.0 and links to the exact unmodified source revision.
The added files are bundled in the built app, not merely stored in the repo.

The old downloaded binary’s complete build records remain unavailable. That
limitation describes the earlier artifact, which this app no longer links.
The current source build records its compiler, patch stack and native inputs.

## Evidence and review

Files prefixed `public-metal` in `spikes/ios-terminal-renderer/evidence/` describe
the replacement. Earlier files describe the original downloaded binary and are
kept as historical results, including its private-API failure. They must not be
used as proof of the new build.

Fresh native source review found and then checked fixes for redraw retry and
callback/context publication ordering. A subsequent full independent review
covered repository standards, edge cases, security, accessibility, performance,
QA, Swift/iOS and the agreed scope, with no verified source blockers. A separate
cross-provider review found a layer left attached after a rebuild. The regression
check reproduced two layers before the fix and one layer after each of five
rebuilds after it. Later focused reviews checked blending reload, fresh callback
matching and build receipt validation. The last review found a repeat-run test
bug; it was fixed and the check passed twice on Simulator. No verified source
blockers remain. Astra implemented the native fixes; Codex and Claude supplied
independent review.

The final receipt records both linked app hashes, all 22 bundled notice hashes,
the source manifest and native archive hashes. The negative integration check
rejects an older artifact without a source build receipt.

IME and VoiceOver work remains deferred. This PR supplies the renderer experiment
and its public-API replacement; it does not add the production terminal UI.
