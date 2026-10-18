# iOS terminal native license audit — issue 30

Updated 2026-10-18 from audit commit `907064c`. This records source checks and the acknowledgment files prepared for the renderer spike. It is not a legal opinion. No app build, signing, commit, push, IME or VoiceOver work was performed for this update.

**The missing acknowledgment texts are now in the app’s source notice folder.** All six original notices are unchanged. Sixteen additional files credit Ghostty’s dependencies, including Oniguruma, Highway, simdutf and Wuffs, which the earlier Release app’s matching debug file identifies as linked code.

**App integration verified.** The regenerated Xcode project includes all 22 notice files. Their bytes match the copies bundled in the new public-Metal Simulator app and signed device Release archive. The earlier keyboard archive predates these additions and remains unchanged.

## What was verified and added

Primary source URLs, selected file/excerpt SHA-256 values, downloaded archive SHA-256 values and all 22 app notice hashes are saved in [`verified-provenance.json`](ios-terminal-native-license-notices/verified-provenance.json). New assembled notice files also appear in this document’s supporting notice directory. Earlier source captures remain unchanged.

The earlier mirror 403 failures were resolved by requesting the same URLs with `User-Agent: curl/8.0`. The previous GitHub Wuffs 404 is still a historical acquisition failure; the exact Ghostty mirror now supplies the package and its generated-file license. No current branch was substituted.

| Component | Verified source and acknowledgment |
|---|---|
| Oniguruma 6.9.9 | Exact Ghostty mirror downloaded; its bytes equal the upstream v6.9.9 archive. `Oniguruma.txt` preserves COPYING and distinct notices from the C/header files, including generated Unicode tables. This also preserves source copyright years/holders beyond the root COPYING. |
| Highway `66486a10623fa0d72fe91260f96c892e41aceb06` | Exact mirror bytes equal the commit archive. All 252 regular files match the hash-named local cache archive after ignoring the root directory name. The tree contains LICENSE and LICENSE-BSD3, and no NOTICE file. Both licenses are in `Highway.txt`; this is not covered by Ghostty’s MIT notice. |
| simdutf **9.0.0** | Both vendored files fetched from the exact Ghostty commit. The wrapper version remains 5.2.8; the header identifies actual code as 9.0.0. `simdutf.txt` contains v9.0.0 MIT/Apache texts and the complete BSD notice embedded in the vendored ISA-detection header (Facebook, DeepMind, NYU, NEC and Idiap). Benchmark-only licenses from the upstream source archive were not treated as bundled code. Vendored file hashes are recorded, without claiming byte identity to a newly generated upstream amalgamation. |
| Wuffs package `7411f488fe2e2c205c3d3b3d28638b7356522930` | Exact mirror downloaded and byte-matched to the hash-named local cache archive. `release/c/wuffs-v0.4.c` SHA-256 is `1f8039ef82911604c063f6ac2ed57254bdb17d742aebdeae06356530d4a0fde7`. Its own header explicitly offers Apache-2.0 OR MIT. `Wuffs.txt` includes that header and the complete LICENSE, LICENSE-MIT and LICENSE-APACHE files. The generated file identifies itself as 0.4.0-alpha.10+3966.20260623 and cites generator revision `f3de3336423f041ee251c3cf7f50a19b7eebb939`; this metadata is preserved separately from the package’s source declaration. |
| FreeType 2.13.2 | Exact mirror inspected. `FreeType.txt` selects the FreeType License, includes its credit, and preserves the additional BDF, PCF, hash, gzip/zlib and HarfBuzz-derived module notices identified by LICENSE.TXT. Added conservatively because FreeType archive members were present; the earlier symbol probe did not establish which functions ship. |
| libpng 1.6.43 / zlib 1.3.1 | Exact Ghostty mirrors inspected; LICENSE files added as `libpng.txt` and `zlib.txt`. Included conservatively for archive code. |
| stb_image 2.28 / stb_image_resize 0.97 | Exact pinned Ghostty header license excerpts already saved by the earlier audit; their MIT/public-domain alternatives are now in `stb.txt`. Included conservatively for archive code. |
| uucode `9d55524551411b493cca41ca06363625d90aff1e` | Exact source archive downloaded again; SHA-256 matches the original capture (`68d23543cb2c6c5dfdbdf38b38375e0c6d412a5c5fb72ce06bd139f7a4d25132`). `uucode.txt` preserves MIT, Unicode License V3, Bjoern Hoehrmann and the wcwidth resource notices from the existing capture. Unicode/width tables may be distributed data even when their generator runs only during the build. The extra resource credits are conservative; they do not assert that every upstream implementation ships. |
| libxev `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` | Exact mirror acquired, resolving the original acquisition blocker. Its MIT LICENSE and the embedded kprotty ThreadPool MIT notice are in `libxev.txt`. The native build changes `src/backend.zig`, `src/backend/kqueue.zig` and `src/posix.zig`; the notices match upstream. |
| vaxis / zig-objc / zf | Previously captured exact-revision MIT notices copied into `vaxis.txt`, `zig-objc.txt` and `zf.txt`. Included conservatively for Ghostty integration. This does not turn their build declarations into proof of executable inclusion. |
| z2d `7dbae85c81784dba9988320bf9543ed9a81350c8` | Exact commit archive inspected. `z2d.txt` includes full LICENSE and COPYING, including MPL-2.0 and Cairo/Pixman/tiny-skia/W3C credits. Upstream test font/license notices are preserved with explicit test-resource context. Distribution handling is described below. |
| Fonts | Exact JetBrains Mono 2.304 and NerdFontsSymbolsOnly 3.4.0 mirrors downloaded. Nerd mirror LICENSE matches the existing MIT credit; both font name tables also say Copyright (c) 2016, Ryan McIntyre. JetBrains font name tables identify the 2020 project authors and OFL 1.1; v2.304 OFL text was fetched separately because the Ghostty font archive has no license file. `FontProvenance.txt` adds these credits and exact sources while preserving both original font notices. Complete font bytes for JetBrains Mono variable regular, variable italic and SymbolsNerdFont-Regular match contiguous ranges of the earlier keyboard executable. Their offsets, lengths and SHA-256 values are saved in the provenance manifest. This directly identifies those three embedded files; no extra font is inferred from a source declaration. |
| Zig runtime | Native worker’s `native/toolchains/zig-aarch64-macos-0.16.0/zig version` returns 0.16.0. `ZigRuntime.txt` preserves that distribution’s MIT LICENSE, musl COPYRIGHT and LLVM/exception texts from libc++, libc++abi and libunwind. The latter are conservative runtime credits, not a claim that complete copies of those libraries ship. Compiler-rt math source files explicitly say they were ported from musl. The earlier prebuilt binary still lacks an exact compiler commit and a per-function runtime source inventory. |

## z2d source availability

The exact source is available at [revision 7dbae85c81784dba9988320bf9543ed9a81350c8](https://github.com/vancluever/z2d/tree/7dbae85c81784dba9988320bf9543ed9a81350c8), with a [downloadable source archive](https://github.com/vancluever/z2d/archive/7dbae85c81784dba9988320bf9543ed9a81350c8.tar.gz). Both links are included in the app notice, along with MPL-2.0. This supplies a source location for the unmodified revision rather than only naming its license.

[MPL-2.0 sections 3.1–3.3](https://www.mozilla.org/en-US/MPL/2.0/) describe source availability for covered files distributed in executable form and allow those files to be part of a larger work. For a build that includes unmodified z2d code, preserve its notices/license and make that revision’s source available to recipients. If the native build changes any MPL-covered files, make those changed files available too and update the notice’s source location. The upstream archive alone would not describe local modifications. The native build’s resolved z2d package contains 56 regular files. Every file matches the exact upstream archive, including every file under `src/` and both build files; the source archive additionally contains documentation/test resources omitted by its package `.paths`. The source link therefore covers that resolved native package with no local z2d changes observed. This update did not establish whether the old prebuilt app contains z2d or whether its vendor modified it; the notice remains conservative for that artifact. Source merely used by an unshipped build tool is distinct from code or generated data copied into the app.

## Native source comparison

Read-only checks against the native worker’s isolated `native/work/ghostty/zig-pkg` confirm all resolved regular files match the downloaded sources for Oniguruma (178 files), Highway (252), Wuffs (14), JetBrains Mono (52), Nerd Fonts (5), z2d (56) and pinned uucode (42). z2d and uucode omit upstream resources according to their package `.paths`; no resolved file differs. Both native vendored simdutf files match the exact pinned Ghostty raw files. libxev has the three native platform changes recorded above; its license and ThreadPool header remain unchanged. These comparisons do not mutate the package cache or the Mac vendor tree.

## What remains to check

- All 22 notices were verified in the new app by the integration owner. The notice worker itself did not build the app.
- Preserve the verified z2d source location when distributing the native build. If later edits change its covered files, distribute those changed sources and update that location. The current resolved z2d package is unchanged from the linked upstream source.
- For the old prebuilt release, exact compiler commit, vendor modifications and a complete runtime source inventory remain unavailable. Three embedded font files are now byte-matched as described above. The added notices are a concrete improvement, not a claim that the vendor supplied an exhaustive build attestation.
- The earlier package resource checks found compiled Ghostty terminfo and shell integration; the existing Ghostty and bash-preexec notices remain. A generator such as `tic` is not itself a shipped ncurses library. Exact compiled terminfo source matching was not performed in this update.
- IME and VoiceOver remain deferred and are unrelated to these source/notice changes.

## Earlier archive evidence

The following identity and symbol/archive evidence describes the keyboard Release archive inspected before these notice additions. It does not describe a rebuilt app.

## Artifact identity and evidence strength

- libghostty-spm checkout HEAD: `42bacd1339f323a693ddbca779295f4f77e5a697`.
- DisplayLink checkout HEAD: `41bea2661e04bebcb1c4f15fc0b6197850100fdd` (Package.resolved 3.0.1).
- Ghostty.ref: `1e9e14af5df14211892f5fc15fd21a49c7d94868`; Ghostty.build: `3`.
- Binary URL: `https://github.com/Lakr233/libghostty-spm/releases/download/upstream.1e9e14af5df1-3/GhosttyKit.xcframework.zip`; Package.swift ZIP checksum `0bf7e5e13f8e42ffca040a6cef7e985fc30bcaa81ff513bd2a93eb097398c6d8`. ZIP itself was not retained/rehashed in this audit; extracted archive hash below is a separate identity.
- `codesign --verify --deep --strict` succeeds. This establishes signature integrity, not source/license provenance.
- App/dSYM UUIDs match: `F774E4DB-CC43-3E47-A5C8-B293999C7099` (arm64). Executable is stripped; matching dSYM supplies symbols for code linked into the app.
- dSYM strings include runner path `zig-aarch64-macos-0.16.0/lib/std`; pinned package CI also selects Zig 0.16.0. Exact compiler commit, runtime license inventory and release build attestation are absent.

| Artifact | SHA-256 |
|---|---|
| `spikes/ios-terminal-renderer/Package.resolved` | `42674b67c2eede443d998d70a24bb943bc132af7fb7d97da7ff45b6135307bee` |
| `spikes/ios-terminal-renderer/build/DerivedData/SourcePackages/checkouts/libghostty-spm/Package.swift` | `f9719abb299da80e1f67be10d275f7d6755361ae6e19a12e9edceca6f64690f2` |
| `spikes/ios-terminal-renderer/build/DerivedData/SourcePackages/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/ios-arm64/libghostty.a` | `f434797b8094936d521ea978d8085ffa60ffedf0844d3ae6ed5aa84ef2cf0960` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/IOSRendererSpike` | `5ae9a17f1158411b4f5ac9e50e61f6c6fa68a69c105c9fab6b82a9717c9b736b` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/dSYMs/IOSRendererSpike.app.dSYM/Contents/Resources/DWARF/IOSRendererSpike` | `6fb2b0484d0834604e555b19c35c7bde9bf70e3dd82bbcd3fa19fdde7427ce20` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/_CodeSignature/CodeResources` | `63a0d8cf5928945154e9d2df1f0963a594c8bac46b2bbcaa6aac613084073619` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/DisplayLink.txt` | `66a30500fd584c78230ce52ee8737a8039fb54d8e239c2f777715b4f35d9a730` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/Ghostty.txt` | `1e1c0ca6e922f77dbfa25cec6a96ebf66c5eefe59b209041068b674cbac3bf2b` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/JetBrainsMono-OFL.txt` | `57839f26b13cb183cef0e95165f418c99bf231a207cfa33d4eeccb836b681e58` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/NerdFontsSymbolsOnly.txt` | `89e4d11dc0b454d4f59cdf65d348fc460aa6948ba0e4408494359070a5b8fcdd` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/bash-preexec.txt` | `d5f4dfec9be8ed5a3e630215f2f4ef8e8076b15ab263cefe0208813a8b1e57fa` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/libghostty-spm.txt` | `bc8800e5af52ebfe6d615c0a25a580ce26b0a5420d48b39d2940c80a11817815` |
| `spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive/Products/Applications/IOSRendererSpike.app/source-manifest.txt` | `64ea03080ece627aee30101600651ca0d5474ed593a1a691e2d8025de99b3755` |

## Reproducible read-only verification

Run from the worktree; none of these commands build, sign or modify source:

```sh
P=spikes/ios-terminal-renderer/build/DerivedData/SourcePackages/checkouts/libghostty-spm
A=spikes/ios-terminal-renderer/build/DerivedData/SourcePackages/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/ios-arm64/libghostty.a
R=spikes/ios-terminal-renderer/build/IOSRendererSpike-keyboard.xcarchive
APP="$R/Products/Applications/IOSRendererSpike.app"
D="$R/dSYMs/IOSRendererSpike.app.dSYM/Contents/Resources/DWARF/IOSRendererSpike"
cat spikes/ios-terminal-renderer/Package.resolved
git -C "$P" rev-parse HEAD
cat "$P/Ghostty.ref" "$P/Ghostty.build"
shasum -a 256 "$A" "$APP/IOSRendererSpike" "$D"
codesign --verify --deep --strict "$APP"
dwarfdump --uuid "$APP/IOSRendererSpike" "$D"
ar -t "$A"
nm "$D" | rg 'onig_new|hwy|simdutf|wuffs|FT_Init_FreeType|png_create|_inflate|stbi'
strings "$D" | rg 'zig-aarch64-macos|zig-pkg'
otool -L "$APP/IOSRendererSpike"
find "$APP" -type f
find spikes/ios-terminal-renderer/build -iname '*linkmap*' -o -iname '*.map'
curl -fL https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/pkg/simdutf/vendor/simdutf.h | rg 'SIMDUTF_VERSION'
```

To retrieve exact declarations, use the pinned raw GitHub base in source excerpts below; fetch `pkg/{freetype,libpng,zlib,oniguruma,highway,wuffs}/build.zig.zon`. Their URLs and Zig content hashes are preserved verbatim below. Do not substitute current branches. Those earlier urllib requests returned HTTP 403, and Wuffs/libxev GitHub requests returned HTTP 404. The mirror acquisition failures were resolved in this update with a curl User-Agent; see the current inventory and provenance manifest above.

### Library symbols in the app’s matching debug file

| Dependency | Probe | Matches | First evidence |
|---|---|---:|---|
| FreeType | `FT_Init_FreeType` | 0 | No match; not proof of total absence |
| libpng | `png_create` | 0 | No match; not proof of total absence |
| zlib | `\b_inflate` | 0 | No match; not proof of total absence |
| Oniguruma | `onig_new` | 3 | `00000001000bf9cc T _onig_new` |
| Highway | `hwy` | 10 | `00000001000e01f4 t __ZN3hwy13FunctionCacheImJPKhmPDiPmEE13ChooseAndCallIXadsoKPFmS2_mS3_S4_EL_ZN7ghosttyL45DecodeUTF8UntilControlSeqHighwayDispatchTableEEEEEEmS2_mS3_S4_` |
| simdutf | `simdutf` | 95 | `00000001000d05c4 T __ZN7simdutf10count_utf8EPKcm` |
| Wuffs | `wuffs` | 375 | `00000001000eed90 T _sizeof__wuffs_jpeg__decoder` |
| stb | `stbi` | 0 | No match; not proof of total absence |
| libxev | `xev\.` | 0 | No match; not proof of total absence |
| z2d | `z2d\.` | 0 | No match; not proof of total absence |
| uucode | `uucode` | 0 | No match; not proof of total absence |
| vaxis | `vaxis` | 0 | No match; not proof of total absence |
| zf | `zf\.` | 0 | No match; not proof of total absence |
| Zig compiler runtime | `compiler_rt` | 0 | No match; not proof of total absence |

### Complete device archive member list

```text
__.SYMDEF SORTED
autofit.o
ftbase.o
ftbbox.o
ftbdf.o
ftbitmap.o
ftcid.o
ftfstype.o
ftgasp.o
ftglyph.o
ftgxval.o
ftinit.o
ftmm.o
ftotval.o
ftpatent.o
ftpfr.o
ftstroke.o
ftsynth.o
fttype1.o
ftwinfnt.o
bdf.o
ftbzip2.o
ftcache.o
cff.o
type1cid.o
ftgzip.o
ftlzw.o
pcf.o
pfr.o
psaux.o
pshinter.o
psnames.o
raster.o
sdf.o
sfnt.o
smooth.o
svg.o
truetype.o
type1.o
type42.o
winfnt.o
ftsystem.o
ftdebug.o
png.o
pngerror.o
pngget.o
pngmem.o
pngpread.o
pngread.o
pngrio.o
pngrtran.o
pngrutil.o
pngset.o
pngtrans.o
pngwio.o
pngwrite.o
pngwtran.o
pngwutil.o
adler32.o
compress.o
crc32.o
deflate.o
gzclose.o
gzlib.o
gzread.o
gzwrite.o
inflate.o
infback.o
inftrees.o
inffast.o
trees.o
uncompr.o
zutil.o
regerror.o
regparse.o
regext.o
regcomp.o
regexec.o
reggnu.o
regenc.o
regsyntax.o
regtrav.o
regversion.o
st.o
onig_init.o
unicode.o
ascii.o
utf8.o
utf16_be.o
utf16_le.o
utf32_be.o
utf32_le.o
euc_jp.o
sjis.o
iso8859_1.o
iso8859_2.o
iso8859_3.o
iso8859_4.o
iso8859_5.o
iso8859_6.o
iso8859_7.o
iso8859_8.o
iso8859_9.o
iso8859_10.o
iso8859_11.o
iso8859_13.o
iso8859_14.o
iso8859_15.o
iso8859_16.o
euc_tw.o
euc_kr.o
big5.o
gb18030.o
koi8_r.o
cp1251.o
euc_jp_prop.o
sjis_prop.o
unicode_unfold_key.o
unicode_fold1_key.o
unicode_fold2_key.o
unicode_fold3_key.o
simdutf.o
abort.o
per_target.o
targets.o
libhighway_zcu.o
zig_macos.o
ext.o
base64.o
codepoint_width.o
index_of.o
vt.o
stb.o
wuffs-v0.4.o
libghostty_zcu.o
compiler_rt.o
libcxx-verbose-abort-compat.o
```

## Additional notice/resource comparisons

- Archived `Ghostty` resources: 5 files; 0 missing from pinned checkout; 0 byte differences. Thus copied bytes match package checkout, while the package’s upstream generation provenance remains a separate question.
- Archived `terminfo` resources: 2 files; 0 missing from pinned checkout; 0 byte differences. Thus copied bytes match package checkout, while the package’s upstream generation provenance remains a separate question.
- Pinned upstream Ghostty LICENSE text is contained verbatim in archived `Ghostty.txt`: True.
- Pinned libghostty-spm and DisplayLink LICENSE texts are each contained verbatim in their archived root notices (verified).
- Archived bash-preexec resource and root notice have different descriptive preambles; the complete MIT license starting at `The MIT License` matches verbatim (including Ryan Caloras/contributors copyright).

## What remains to finish the acknowledgments

1. Get the build records for this binary, including the compiler version, source revisions, build options and linker map. These should show which code and generated data ended up in the app.
2. Find the exact Wuffs and libxev sources, explain the simdutf version mismatch, and check whether z2d ships. Check the notices for compiler runtime code and Unicode data too.
3. Match the embedded fonts and bundled resources to their source files and licenses.
4. Put the required credits and license texts in the app’s acknowledgments, including any required source information. Check that the final app includes them.

## Exact upstream source excerpts

### src/build/SharedDeps.zig
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/src/build/SharedDeps.zig

```zig
450:     // on the standard search list. i.e. GTK is often in /usr/lib/x86_64-linux-gnu
451:     // on x86_64.
452:     if (step.rootModuleTarget().os.tag == .linux) {
453:         const triple = try step.rootModuleTarget().linuxTriple(b.allocator);
454:         const path = b.fmt("/usr/lib/{s}", .{triple});
455:         if (std.Io.Dir.accessAbsolute(b.graph.io, path, .{})) {
456:             step.root_module.addLibraryPath(.{ .cwd_relative = path });
457:         } else |_| {}
458:     }
459: 
460:     // nothings/stb headers
461:     try translate_c.addImportToModule(b, "stb_c", step.root_module, .{
462:         .source = .{ .includes = .{ .files = &.{
463:             .{ .path = "stb_image.h" },
464:             .{ .path = "stb_image_resize.h" },
465:         } } },
466:         .target = target,
467:         .optimize = optimize,
468:         .include_paths = &.{b.path("src/stb")},
469:     });
470: 
471:     // C files
472:     step.root_module.link_libc = true;
473:     step.root_module.addIncludePath(b.path("src/stb"));
474:     // Disable ubsan for MSVC: Zig's ubsan runtime cannot be bundled
475:     // on Windows (LNK4229), leaving __ubsan_handle_* unresolved when
476:     // the static archive is consumed by an external linker.
477:     step.root_module.addCSourceFiles(.{
478:         .files = &.{"src/stb/stb.c"},
479:         .flags = if (step.rootModuleTarget().abi == .msvc)
480:             &.{ "-fno-sanitize=undefined", "-fno-sanitize-trap=undefined" }
510:     // Other dependencies, mostly pure Zig
511:     if (b.lazyDependency("opengl", .{})) |dep| {
512:         step.root_module.addImport("opengl", dep.module("opengl"));
513:     }
514:     if (b.lazyDependency("vaxis", .{
515:         .target = target,
516:         .optimize = optimize,
517:         .external_uucode = true,
518:     })) |dep| {
519:         const vaxis = dep.module("vaxis");
520:         step.root_module.addImport("vaxis", vaxis);
521:         vaxis.addImport("uucode", self.uucode_mod);
522:     }
523:     if (b.lazyDependency("wuffs", .{
524:         .target = target,
525:         .optimize = optimize,
526:     })) |dep| {
527:         step.root_module.addImport("wuffs", dep.module("wuffs"));
528:     }
529:     if (b.lazyDependency("libxev", .{
530:         .target = target,
531:         .optimize = optimize,
532:     })) |dep| {
533:         step.root_module.addImport("xev", dep.module("xev"));
534:     }
535:     if (b.lazyDependency("z2d", .{
536:         .target = target,
537:         .optimize = optimize,
538:     })) |dep| {
539:         step.root_module.addImport("z2d", dep.module("z2d"));
540:     }
541:     if (b.lazyDependency("zf", .{
542:         .target = target,
543:         .optimize = optimize,
544:         .with_tui = false,
545:     })) |dep| {
546:         step.root_module.addImport("zf", dep.module("zf"));
547:     }
548: 
549:     // Mac Stuff
550:     if (step.rootModuleTarget().os.tag.isDarwin()) {
551:         if (b.lazyDependency("zig_objc", .{
552:             .target = target,
553:             .optimize = optimize,
554:         })) |objc_dep| {
555:             step.root_module.addImport(
556:                 "objc",
557:                 objc_dep.module("objc"),
558:             );
559:         }
560: 
561:         if (b.lazyDependency("macos", .{
562:             .target = target,
563:             .optimize = optimize,
564:         })) |macos_dep| {
565:             step.root_module.addImport(
566:                 "macos",
567:                 macos_dep.module("macos"),
568:             );
569:             step.root_module.linkLibrary(
570:                 macos_dep.artifact("macos"),
571:             );
612:             b.allocator,
613:             dep.artifact("dcimgui").getEmittedBin(),
614:         );
615:     }
616: 
617:     // Fonts
618:     {
619:         // JetBrains Mono
620:         if (b.lazyDependency("jetbrains_mono", .{})) |jb_mono| {
621:             step.root_module.addAnonymousImport(
622:                 "jetbrains_mono_regular",
623:                 .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Regular.ttf") },
624:             );
625:             step.root_module.addAnonymousImport(
626:                 "jetbrains_mono_bold",
627:                 .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Bold.ttf") },
628:             );
629:             step.root_module.addAnonymousImport(
630:                 "jetbrains_mono_italic",
631:                 .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Italic.ttf") },
632:             );
633:             step.root_module.addAnonymousImport(
634:                 "jetbrains_mono_bold_italic",
635:                 .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-BoldItalic.ttf") },
636:             );
637:             step.root_module.addAnonymousImport(
638:                 "jetbrains_mono_variable",
639:                 .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono[wght].ttf") },
640:             );
641:             step.root_module.addAnonymousImport(
642:                 "jetbrains_mono_variable_italic",
643:                 .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono-Italic[wght].ttf") },
644:             );
645:         }
646: 
647:         // Symbols-only nerd font
648:         if (b.lazyDependency("nerd_fonts_symbols_only", .{})) |nf_symbols| {
649:             step.root_module.addAnonymousImport(
650:                 "nerd_fonts_symbols_only",
651:                 .{ .root_source_file = nf_symbols.path("SymbolsNerdFont-Regular.ttf") },
652:             );
653:         }
654:     }
655: 
656:     // If we're building an exe then we have additional dependencies.
657:     if (step.kind != .lib) {
658:         // We always statically compile glad
659:         step.root_module.addIncludePath(b.path("vendor/glad/include/"));
660:         step.root_module.addCSourceFile(.{
890: ) !void {
891:     const target = m.resolved_target.?;
892:     const optimize = m.optimize.?;
893:     const system_highway = b.systemIntegrationOption("highway", .{ .default = false });
894: 
895:     // Simdutf
896:     if (b.systemIntegrationOption("simdutf", .{})) {
897:         m.linkSystemLibrary("simdutf", dynamic_link_opts);
898:     } else {
899:         if (b.lazyDependency("simdutf", .{
900:             .target = target,
901:             .optimize = optimize,
902:             .no_libcxx = true,
903:         })) |simdutf_dep| {
904:             m.linkLibrary(simdutf_dep.artifact("simdutf"));
905:             if (static_libs) |v| try v.append(
906:                 b.allocator,
907:                 simdutf_dep.artifact("simdutf").getEmittedBin(),
908:             );
909:         }
910:     }
911: 
912:     // Highway
913:     if (system_highway) {
914:         m.linkSystemLibrary("libhwy", dynamic_link_opts);
915:     } else {
916:         if (b.lazyDependency("highway", .{
917:             .target = target,
918:             .optimize = optimize,
919:         })) |highway_dep| {
920:             m.linkLibrary(highway_dep.artifact("highway"));
921:             if (static_libs) |v| try v.append(
922:                 b.allocator,
923:                 highway_dep.artifact("highway").getEmittedBin(),
924:             );
925:         }
926:     }
927: 
928:     // SIMD C++ files
929:     m.addIncludePath(b.path("src"));
930:     {
931:         // From hwy/detect_targets.h
932:         const HWY_AVX10_2: c_int = 1 << 3;
933:         const HWY_AVX3_SPR: c_int = 1 << 4;
934:         const HWY_AVX3_ZEN4: c_int = 1 << 6;
935:         const HWY_AVX3_DL: c_int = 1 << 7;
936:         const HWY_AVX3: c_int = 1 << 8;
937: 
938:         var flags: std.ArrayListUnmanaged([]const u8) = .empty;
939: 
940:         // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
```

### src/build/GhosttyLib.zig
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/src/build/GhosttyLib.zig

```zig
20: 
21: pub fn initStatic(
22:     b: *std.Build,
23:     deps: *const SharedDeps,
24: ) !GhosttyLib {
25:     const lib = b.addLibrary(.{
26:         .name = "ghostty",
27:         .root_module = b.createModule(.{
28:             .root_source_file = b.path("src/main_c.zig"),
29:             .target = deps.config.target,
30:             .optimize = deps.config.optimize,
31:             .strip = deps.config.strip,
32:             .omit_frame_pointer = deps.config.omitFramePointer(),
33:             .unwind_tables = if (deps.config.strip) .none else .sync,
34:             .link_libc = true,
35:         }),
36: 
37:         // Fails on self-hosted x86_64 on macOS
38:         .use_llvm = true,
39:     });
40: 
41:     // These must be bundled since we're compiling into a static lib.
42:     // Otherwise, you get undefined symbol errors.
43:     lib.bundle_compiler_rt = true;
44:     lib.bundle_ubsan_rt = true;
45: 
46:     if (deps.config.target.result.os.tag == .windows) {
47:         // Zig's ubsan emits /exclude-symbols linker directives that
48:         // are incompatible with the MSVC linker (LNK4229).
49:         lib.bundle_ubsan_rt = false;
50:     }
51: 
52:     // Add our dependencies. Get the list of all static deps so we can
53:     // build a combined archive.
54:     var lib_list = try deps.add(lib);
55:     try lib_list.append(b.allocator, lib.getEmittedBin());
56: 
57:     // Combine all archives into a single fat static library so
58:     // consumers only need to link one file.
59:     const combined = CombineArchivesStep.create(b, deps.config.target, "ghostty-internal", lib_list.items);
60:     combined.step.dependOn(&lib.step);
61: 
62:     // On Darwin, prefer libSystem's libc/libm over the bundled
63:     // compiler-rt for consumers of this archive. See
64:     // libsystem_override.sh for details. This is a no-op elsewhere.
65:     const override = LibsystemOverrideStep.create(
66:         b,
67:         deps.config.target,
68:         combined.output,
69:         "libghostty-internal.a",
70:     );
71: 
72:     return .{
73:         .step = override.step orelse combined.step,
74:         .output = override.output,
75: 
76:         // Static libraries cannot have dSYMs because they aren't linked.
77:         .dsym = null,
78:         .pkg_config = null,
79:         .pkg_config_static = null,
80:     };
```

### src/build/UnicodeTables.zig
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/src/build/UnicodeTables.zig

```zig
1: const UnicodeTables = @This();
2: 
3: const std = @import("std");
4: 
5: /// The exe.
6: props_exe: *std.Build.Step.Compile,
7: symbols_exe: *std.Build.Step.Compile,
8: 
9: /// The output path for the unicode tables
10: props_output: std.Build.LazyPath,
11: symbols_output: std.Build.LazyPath,
12: 
13: pub fn init(b: *std.Build, uucode_tables: std.Build.LazyPath) !UnicodeTables {
14:     const props_exe = b.addExecutable(.{
15:         .name = "props-unigen",
16:         .root_module = b.createModule(.{
17:             .root_source_file = b.path("src/unicode/props_uucode.zig"),
18:             .target = b.graph.host,
19:             .strip = false,
20:             .omit_frame_pointer = false,
21:             .unwind_tables = .sync,
22:         }),
23: 
24:         // TODO: x86_64 self-hosted crashes
25:         .use_llvm = true,
26:     });
27: 
28:     const symbols_exe = b.addExecutable(.{
29:         .name = "symbols-unigen",
30:         .root_module = b.createModule(.{
31:             .root_source_file = b.path("src/unicode/symbols_uucode.zig"),
32:             .target = b.graph.host,
33:             .strip = false,
34:             .omit_frame_pointer = false,
35:             .unwind_tables = .sync,
36:         }),
37: 
38:         // TODO: x86_64 self-hosted crashes
39:         .use_llvm = true,
40:     });
41: 
42:     if (b.lazyDependency("uucode", .{
43:         .target = b.graph.host,
44:         .tables_path = uucode_tables,
45:         .build_config_path = b.path("src/build/uucode_config.zig"),
46:     })) |dep| {
47:         inline for (&.{ props_exe, symbols_exe }) |exe| {
48:             exe.root_module.addImport("uucode", dep.module("uucode"));
49:         }
50:     }
51: 
52:     const props_run = b.addRunArtifact(props_exe);
53:     const symbols_run = b.addRunArtifact(symbols_exe);
54: 
55:     // Generated Zig files have to end with .zig
56:     const wf = b.addWriteFiles();
57:     const props_output = wf.addCopyFile(props_run.captureStdOut(.{}), "props.zig");
58:     const symbols_output = wf.addCopyFile(symbols_run.captureStdOut(.{}), "symbols.zig");
59: 
60:     return .{
61:         .props_exe = props_exe,
62:         .symbols_exe = symbols_exe,
63:         .props_output = props_output,
64:         .symbols_output = symbols_output,
65:     };
66: }
67: 
68: /// Add the "unicode_tables" import.
69: pub fn addImport(self: *const UnicodeTables, step: *std.Build.Step.Compile) void {
70:     self.props_output.addStepDependencies(&step.step);
71:     self.symbols_output.addStepDependencies(&step.step);
72:     self.addModuleImport(step.root_module);
73: }
74: 
75: /// Add the "unicode_tables" import to a module.
76: pub fn addModuleImport(
77:     self: *const UnicodeTables,
78:     module: *std.Build.Module,
79: ) void {
80:     module.addAnonymousImport("unicode_tables", .{
81:         .root_source_file = self.props_output,
82:     });
83:     module.addAnonymousImport("symbols_tables", .{
84:         .root_source_file = self.symbols_output,
85:     });
86: }
87: 
88: /// Install the exe
89: pub fn install(self: *const UnicodeTables, b: *std.Build) void {
90:     b.installArtifact(self.props_exe);
91:     b.installArtifact(self.symbols_exe);
92: }
```

### src/build/uucode_config.zig
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/src/build/uucode_config.zig

```zig
1: const std = @import("std");
2: const assert = std.debug.assert;
3: const config = @import("config.zig");
4: 
5: const Allocator = std.mem.Allocator;
6: 
7: pub const fields = &config.mergeFields(config.fields, &.{
8:     .{ .name = "width", .type = u2 },
9:     .{ .name = "is_symbol", .type = bool },
10: });
11: pub const build_components = &config.mergeComponents(config.build_components, &.{
12:     .{
13:         .Impl = WidthComponent,
14:         .inputs = &.{
15:             "wcwidth_standalone",
16:             "wcwidth_zero_in_grapheme",
17:             "is_emoji_modifier",
18:             "grapheme_break_no_control",
19:         },
20:         .fields = &.{"width"},
21:     },
22:     .{
23:         .Impl = IsSymbolComponent,
24:         .inputs = &.{ "block", "general_category" },
25:         .fields = &.{"is_symbol"},
26:     },
27: });
28: 
29: pub const get_components: []const config.Component = &.{};
30: 
31: pub const tables = [_]config.Table{
32:     .{
33:         .name = "runtime",
34:         .fields = &.{
35:             "is_emoji_presentation",
36:             "case_folding_full",
37:         },
38:     },
39:     .{
40:         // Fields that libvaxis needs that aren't included in the `runtime`
41:         // table.
42:         .name = "libvaxis_only",
43:         .fields = &.{
44:             "east_asian_width",
45:             "general_category",
46:             "grapheme_break",
47:         },
48:     },
49:     .{
50:         .name = "buildtime",
51:         // Unpacked, because a packed table this size cannot be evaluated
52:         // at comptime by Zig 0.16.0 and this one has to be, whether or not
53:         // anything reads it.
54:         //
55:         // `uucode.get.FieldEnum` is built by walking `@TypeOf(tables)`, so
56:         // instantiating anything that names a field -- `grapheme.Iterator`,
57:         // among others -- materialises every table including this one. In a
58:         // packed layout its rows are a `@bitCast` of a 32000 element `[_]u10`,
59:         // and the compiler gives up on it two different ways depending on
60:         // build options:
61:         //
62:         //     tables.zig: error: unable to evaluate comptime expression
63:         //     thread panic: TODO implement writeToPackedMemory for more types
64:         //
65:         // Ghostty does not hit this, because its own uses of these fields go
66:         // through the tables generated at build time rather than through
67:         // `uucode.get`. A downstream pairing this config with libvaxis does:
68:         // vaxis measures grapheme widths with `grapheme.Iterator`, so any
69:         // program calling `Vaxis.render` fails to compile.
70:         //
71:         // The cost is the size of a table nothing reads at runtime. The fix
72:         // belongs upstream in uucode or in the compiler; this is what makes
73:         // the pairing build today.
74:         .packing = .unpacked,
75:         .fields = &.{
76:             "width",
77:             "wcwidth_zero_in_grapheme",
78:             "grapheme_break_no_control",
79:             "is_symbol",
80:             "is_emoji_vs_base",
81:         },
82:     },
83: };
84: 
85: const WidthComponent = struct {
86:     pub fn build(
87:         comptime InputRow: type,
88:         comptime Row: type,
89:         allocator: std.mem.Allocator,
90:         io: std.Io,
91:         inputs: config.MultiSlice(InputRow),
92:         rows: *config.MultiSlice(Row),
93:         backing: anytype,
94:         tracking: anytype,
95:     ) !void {
96:         _ = allocator;
97:         _ = io;
98:         _ = backing;
99:         _ = tracking;
100: 
101:         rows.len = config.num_code_points;
102:         const items = rows.items(.width);
103:         const standalone = inputs.items(.wcwidth_standalone);
104:         const zero_in_grapheme = inputs.items(.wcwidth_zero_in_grapheme);
105:         const is_emoji_modifier = inputs.items(.is_emoji_modifier);
106:         const grapheme_break_no_control = inputs.items(.grapheme_break_no_control);
107: 
108:         // This condition is needed as Ghostty currently has a singular concept for
109:         // the `width` of a code point, while `uucode` splits the concept into
110:         // `wcwidth_standalone` and `wcwidth_zero_in_grapheme`. The two cases where
111:         // we want to use the `wcwidth_standalone` despite the code point occupying
112:         // zero width in a grapheme (`wcwidth_zero_in_grapheme`) are emoji
113:         // modifiers and prepend code points. For emoji modifiers we want to
114:         // support displaying them in isolation as color patches, and if prepend
115:         // characters were to be width 0 they would disappear from the output with
116:         // Ghostty's current width 0 handling. Future work will take advantage of
117:         // the new uucode `wcwidth_standalone` vs `wcwidth_zero_in_grapheme` split.
118:         for (0..config.num_code_points) |i| {
119:             if (zero_in_grapheme[i] and !is_emoji_modifier[i] and grapheme_break_no_control[i] != .prepend) {
120:                 items[i] = 0;
121:             } else {
122:                 items[i] = @min(2, standalone[i]);
123:             }
124:         }
125:     }
126: };
127: 
128: const IsSymbolComponent = struct {
129:     pub fn build(
130:         comptime InputRow: type,
```

### src/font/embedded.zig
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/src/font/embedded.zig

```zig
1: //! Fonts that can be embedded with Ghostty. Note they are only actually
2: //! embedded in the binary if they are referenced by the code, so fonts
3: //! used for tests will not result in the final binary being larger.
4: //!
5: //! Be careful to ensure that any fonts you embed are licensed for
6: //! redistribution and include their license as necessary.
7: 
8: /// Default fonts that we prefer for Ghostty.
9: pub const variable = @embedFile("jetbrains_mono_variable");
10: pub const variable_italic = @embedFile("jetbrains_mono_variable_italic");
11: 
12: /// Symbols-only nerd font.
13: pub const symbols_nerd_font = @embedFile("nerd_fonts_symbols_only");
14: 
15: /// Static jetbrains mono faces, currently unused.
16: pub const regular = @embedFile("jetbrains_mono_regular");
17: pub const bold = @embedFile("jetbrains_mono_bold");
18: pub const italic = @embedFile("jetbrains_mono_italic");
19: pub const bold_italic = @embedFile("jetbrains_mono_bold_italic");
20: 
21: /// Emoji fonts
22: pub const emoji = @embedFile("res/NotoColorEmoji.ttf");
23: pub const emoji_text = @embedFile("res/NotoEmoji-Regular.ttf");
24: 
25: // Fonts below are ONLY used for testing.
26: 
27: /// Fonts with general properties
28: pub const arabic = @embedFile("res/KawkabMono-Regular.ttf");
29: 
30: /// A font for testing which is patched with nerd font symbols.
31: pub const test_nerd_font = @embedFile("res/JetBrainsMonoNerdFont-Regular.ttf");
32: 
33: /// Specific font families below:
34: pub const code_new_roman = @embedFile("res/CodeNewRoman-Regular.otf");
35: pub const inconsolata = @embedFile("res/Inconsolata-Regular.ttf");
36: pub const geist_mono = @embedFile("res/GeistMono-Regular.ttf");
37: pub const jetbrains_mono = @embedFile("res/JetBrainsMonoNoNF-Regular.ttf");
38: pub const julia_mono = @embedFile("res/JuliaMono-Regular.ttf");
39: 
40: /// Cozette is a unique font because it embeds some emoji characters
41: /// but has a text presentation.
42: pub const cozette = @embedFile("res/CozetteVector.ttf");
43: 
44: /// Monaspace has weird ligature behaviors we want to test in our shapers
45: /// so we embed it here.
46: pub const monaspace_neon = @embedFile("res/MonaspaceNeon-Regular.otf");
47: 
48: /// Terminus TTF is a scalable font with bitmap glyphs at various sizes.
49: pub const terminus_ttf = @embedFile("res/TerminusTTF-Regular.ttf");
50: 
51: /// Spleen is a monospaced bitmap font available in multiple formats.
52: /// Used for testing bitmap font support across different file formats.
53: pub const spleen_bdf = @embedFile("res/spleen-8x16.bdf");
54: pub const spleen_pcf = @embedFile("res/spleen-8x16.pcf");
55: pub const spleen_otb = @embedFile("res/spleen-8x16.otb");
```

## Saved pinned source declarations


### build.zig.zon.txt

```text
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/build.zig.zon

.{
    .name = .ghostty,
    .version = "1.3.2-dev",
    .paths = .{""},
    .fingerprint = 0x64407a2a0b4147e5,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        // Our higher-level C translation helper (this also helps ensure we
        // only need to maintain one external dependency point)
        .translate_c = .{ .path = "./pkg/translate-c" },

        // Zig libs
        .libxev = .{
            // mitchellh/libxev
            .url = "https://deps.files.ghostty.org/libxev-9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf.tar.gz",
            .hash = "libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F",
            .lazy = true,
        },
        .vaxis = .{
            // rockorager/libvaxis
            .url = "https://deps.files.ghostty.org/vaxis-1dbbe575dff4586fe51e3217aa5c3fecdcbb6089.tar.gz",
            .hash = "vaxis-0.6.0-BWNV_CrbCQCscGpzsAlR402rYQ_tV3aAl081c2iRRkka",
            .lazy = true,
        },
        .z2d = .{
            // vancluever/z2d
            .url = "https://deps.files.ghostty.org/z2d-7dbae85c81784dba9988320bf9543ed9a81350c8.tar.gz",
            .hash = "z2d-0.12.1-j5P_Hsw8EQAKyZTQICCQnAH2xYkLDW8k9uefbsYdfPZ-",
            .lazy = true,
        },
        .zig_objc = .{
            // mitchellh/zig-objc
            .url = "https://deps.files.ghostty.org/zig_objc-c8de82ff80281215ad92900866dab7103a8efa8b.tar.gz",
            .hash = "zig_objc-0.0.0-Ir_Sp9gsAQCPAJc0oF5xoWePHWP6Y6tCphDeyNUThJoi",
            .lazy = true,
        },
        .zig_js = .{
            // mitchellh/zig-js
            .url = "https://deps.files.ghostty.org/zig_js-3c23860e47fdcdc5af805efb7fd0bdac5fd3e9bc.tar.gz",
            .hash = "zig_js-0.0.0-rjCAV7-GAADvMTBL7lPMuvDk7xgS9PCMIZWiOUXLZSlj",
            .lazy = true,
        },
        .uucode = .{
            // jacobsandlund/uucode
            .url = "https://github.com/jacobsandlund/uucode/archive/9d55524551411b493cca41ca06363625d90aff1e.tar.gz",
            .hash = "uucode-0.2.0-ZZjBPuuFVgC8YZ8eld4fOKsZANLIhTFMzULQxhkLi1C7",
        },
        .zig_wayland = .{
            // codeberg ifreund/zig-wayland
            .url = "https://deps.files.ghostty.org/wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX.tar.gz",
            .hash = "wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX",
            .lazy = true,
        },
        .zf = .{
            // natecraddock/zf
            .url = "https://deps.files.ghostty.org/zf-c35c421f84895193246db06c40683c1a30e616ef.tar.gz",
            .hash = "zf-0.11.0-OIRy8X-RAAAwaRXHMYpj2uvBnuGTZWEE_3V7acqHQNtW",
            .lazy = true,
        },
        .gobject = .{
            // https://github.com/ghostty-org/zig-gobject based on zig_gobject
            // Temporary until we generate them at build time automatically.
            .url = "https://deps.files.ghostty.org/gobject-2026-07-28-36-1.tar.zst",
            .hash = "gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3",
            .lazy = true,
        },

        // C libs
        .dcimgui = .{ .path = "./pkg/dcimgui", .lazy = true },
        .fontconfig = .{ .path = "./pkg/fontconfig", .lazy = true },
        .freetype = .{ .path = "./pkg/freetype", .lazy = true },
        .gtk4_layer_shell = .{ .path = "./pkg/gtk4-layer-shell", .lazy = true },
        .harfbuzz = .{ .path = "./pkg/harfbuzz", .lazy = true },
        .highway = .{ .path = "./pkg/highway", .lazy = true },
        .libintl = .{ .path = "./pkg/libintl", .lazy = true },
        .libpng = .{ .path = "./pkg/libpng", .lazy = true },
        .macos = .{ .path = "./pkg/macos", .lazy = true },
        .oniguruma = .{ .path = "./pkg/oniguruma", .lazy = true },
        .opengl = .{ .path = "./pkg/opengl", .lazy = true },
        .sentry = .{ .path = "./pkg/sentry", .lazy = true },
        .simdutf = .{ .path = "./pkg/simdutf", .lazy = true },
        .wuffs = .{ .path = "./pkg/wuffs", .lazy = true },
        .zlib = .{ .path = "./pkg/zlib", .lazy = true },

        // Shader translation
        .glslang = .{ .path = "./pkg/glslang", .lazy = true },
        .spirv_cross = .{ .path = "./pkg/spirv-cross", .lazy = true },

        // Wayland
        .wayland = .{
            .url = "https://deps.files.ghostty.org/wayland-9cb3d7aa9dc995ffafdbdef7ab86a949d0fb0e7d.tar.gz",
            .hash = "N-V-__8AAKrHGAAs2shYq8UkE6bGcR1QJtLTyOE_lcosMn6t",
            .lazy = true,
        },
        .wayland_protocols = .{
            .url = "https://deps.files.ghostty.org/N-V-__8AAFdWDwA0ktbNUi9pFBHCRN4weXIgIfCrVjfGxqgA.tar.gz",
            .hash = "N-V-__8AAFdWDwA0ktbNUi9pFBHCRN4weXIgIfCrVjfGxqgA",
            .lazy = true,
        },
        .plasma_wayland_protocols = .{
            .url = "https://deps.files.ghostty.org/plasma_wayland_protocols-12207e0851c12acdeee0991e893e0132fc87bb763969a585dc16ecca33e88334c566.tar.gz",
            .hash = "N-V-__8AAKYZBAB-CFHBKs3u4JkeiT4BMvyHu3Y5aaWF3Bbs",
            .lazy = true,
        },

        // Fonts
        .jetbrains_mono = .{
            .url = "https://deps.files.ghostty.org/JetBrainsMono-2.304.tar.gz",
            .hash = "N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x",
            .lazy = true,
        },
        .nerd_fonts_symbols_only = .{
            .url = "https://deps.files.ghostty.org/NerdFontsSymbolsOnly-3.4.0.tar.gz",
            .hash = "N-V-__8AAMVLTABmYkLqhZPLXnMl-KyN38R8UVYqGrxqO26s",
            .lazy = true,
        },

        // Other
        .apple_sdk = .{ .path = "./pkg/apple-sdk" },
        .android_ndk = .{ .path = "./pkg/android-ndk" },
        .iterm2_themes = .{
            .url = "https://deps.files.ghostty.org/ghostty-themes-release-20261005-151109-31756e7.tgz",
            .hash = "N-V-__8AADNBBQDD4MFOa3Y7R_A8PHIeWQ1IZdOiBFZS3nZ7",
            .lazy = true,
        },
    },
}

```

### pkg-freetype-build.zig.zon.txt

```text
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/pkg/freetype/build.zig.zon

.{
    .name = .freetype,
    .version = "2.13.2",
    .fingerprint = 0xac2059b6f7bbfe0a,
    .paths = .{""},
    .dependencies = .{
        // freetype/freetype
        .freetype = .{
            .url = "https://deps.files.ghostty.org/freetype-1220b81f6ecfb3fd222f76cf9106fecfa6554ab07ec7fdc4124b9bb063ae2adf969d.tar.gz",
            .hash = "N-V-__8AAKLKpwC4H27Ps_0iL3bPkQb-z6ZVSrB-x_3EEkub",
            .lazy = true,
        },

        .apple_sdk = .{ .path = "../apple-sdk" },
        .libpng = .{ .path = "../libpng" },
        .translate_c = .{ .path = "../translate-c" },
        .zlib = .{ .path = "../zlib" },
    },
}

```

### pkg-highway-build.zig.zon.txt

```text
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/pkg/highway/build.zig.zon

.{
    .name = .highway,
    .version = "1.2.0",
    .fingerprint = 0xdbcf1a7425023274,
    .paths = .{""},
    .dependencies = .{
        // google/highway
        .highway = .{
            .url = "https://deps.files.ghostty.org/highway-66486a10623fa0d72fe91260f96c892e41aceb06.tar.gz",
            .hash = "N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE",
            .lazy = true,
        },

        .android_ndk = .{ .path = "../android-ndk" },
        .apple_sdk = .{ .path = "../apple-sdk" },
    },
}

```

### pkg-libpng-build.zig.zon.txt

```text
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/pkg/libpng/build.zig.zon

.{
    .name = .libpng,
    .version = "1.6.43",
    .fingerprint = 0xb7a09eb437ca8a79,
    .paths = .{""},
    .dependencies = .{
        // glennrp/libpng
        .libpng = .{
            .url = "https://deps.files.ghostty.org/libpng-1220aa013f0c83da3fb64ea6d327f9173fa008d10e28bc9349eac3463457723b1c66.tar.gz",
            .hash = "N-V-__8AAJrvXQCqAT8Mg9o_tk6m0yf5Fz-gCNEOKLyTSerD",
            .lazy = true,
        },

        .zlib = .{ .path = "../zlib", .lazy = true },
        .apple_sdk = .{ .path = "../apple-sdk" },
    },
}

```

### pkg-oniguruma-build.zig.zon.txt

```text
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/pkg/oniguruma/build.zig.zon

.{
    .name = .oniguruma,
    .version = "6.9.9",
    .fingerprint = 0xe3b537b18c5785a8,
    .paths = .{""},
    .dependencies = .{
        // kkos/oniguruma
        .oniguruma = .{
            .url = "https://deps.files.ghostty.org/oniguruma-1220c15e72eadd0d9085a8af134904d9a0f5dfcbed5f606ad60edc60ebeccd9706bb.tar.gz",
            .hash = "N-V-__8AAHjwMQDBXnLq3Q2QhaivE0kE2aD138vtX2Bq1g7c",
            .lazy = true,
        },

        .apple_sdk = .{ .path = "../apple-sdk" },
        .translate_c = .{ .path = "../translate-c" },
    },
}

```

### pkg-wuffs-build.zig.zon.txt

```text
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/pkg/wuffs/build.zig.zon

.{
    .name = .wuffs,
    .version = "0.0.0",
    .fingerprint = 0x67c0c059de921c4f,
    .dependencies = .{
        .translate_c = .{ .path = "../translate-c" },

        // google/wuffs
        .wuffs = .{
            .url = "https://deps.files.ghostty.org/wuffs-7411f488fe2e2c205c3d3b3d28638b7356522930.tar.gz",
            .hash = "N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI",
            .lazy = true,
        },

        // make-github-pseudonymous-again/pixels
        .pixels = .{
            .url = "https://deps.files.ghostty.org/pixels-12207ff340169c7d40c570b4b6a97db614fe47e0d83b5801a932dcd44917424c8806.tar.gz",
            .hash = "N-V-__8AADYiAAB_80AWnH1AxXC0tql9thT-R-DYO1gBqTLc",
            .lazy = true,
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "include",
        "src",
    },
}

```

### pkg-zlib-build.zig.zon.txt

```text
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/pkg/zlib/build.zig.zon

.{
    .name = .zlib,
    .version = "1.3.1",
    .fingerprint = 0x73887d3aef823f9e,
    .paths = .{""},
    .dependencies = .{
        // madler/zlib
        .zlib = .{
            .url = "https://deps.files.ghostty.org/zlib-1220fed0c74e1019b3ee29edae2051788b080cd96e90d56836eea857b0b966742efb.tar.gz",
            .hash = "N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o",
            .lazy = true,
        },

        .apple_sdk = .{ .path = "../apple-sdk" },
    },
}

```

### src-font-embedded.zig.txt

```text
Source: https://raw.githubusercontent.com/ghostty-org/ghostty/1e9e14af5df14211892f5fc15fd21a49c7d94868/src/font/embedded.zig

//! Fonts that can be embedded with Ghostty. Note they are only actually
//! embedded in the binary if they are referenced by the code, so fonts
//! used for tests will not result in the final binary being larger.
//!
//! Be careful to ensure that any fonts you embed are licensed for
//! redistribution and include their license as necessary.

/// Default fonts that we prefer for Ghostty.
pub const variable = @embedFile("jetbrains_mono_variable");
pub const variable_italic = @embedFile("jetbrains_mono_variable_italic");

/// Symbols-only nerd font.
pub const symbols_nerd_font = @embedFile("nerd_fonts_symbols_only");

/// Static jetbrains mono faces, currently unused.
pub const regular = @embedFile("jetbrains_mono_regular");
pub const bold = @embedFile("jetbrains_mono_bold");
pub const italic = @embedFile("jetbrains_mono_italic");
pub const bold_italic = @embedFile("jetbrains_mono_bold_italic");

/// Emoji fonts
pub const emoji = @embedFile("res/NotoColorEmoji.ttf");
pub const emoji_text = @embedFile("res/NotoEmoji-Regular.ttf");

// Fonts below are ONLY used for testing.

/// Fonts with general properties
pub const arabic = @embedFile("res/KawkabMono-Regular.ttf");

/// A font for testing which is patched with nerd font symbols.
pub const test_nerd_font = @embedFile("res/JetBrainsMonoNerdFont-Regular.ttf");

/// Specific font families below:
pub const code_new_roman = @embedFile("res/CodeNewRoman-Regular.otf");
pub const inconsolata = @embedFile("res/Inconsolata-Regular.ttf");
pub const geist_mono = @embedFile("res/GeistMono-Regular.ttf");
pub const jetbrains_mono = @embedFile("res/JetBrainsMonoNoNF-Regular.ttf");
pub const julia_mono = @embedFile("res/JuliaMono-Regular.ttf");

/// Cozette is a unique font because it embeds some emoji characters
/// but has a text presentation.
pub const cozette = @embedFile("res/CozetteVector.ttf");

/// Monaspace has weird ligature behaviors we want to test in our shapers
/// so we embed it here.
pub const monaspace_neon = @embedFile("res/MonaspaceNeon-Regular.otf");

/// Terminus TTF is a scalable font with bitmap glyphs at various sizes.
pub const terminus_ttf = @embedFile("res/TerminusTTF-Regular.ttf");

/// Spleen is a monospaced bitmap font available in multiple formats.
/// Used for testing bitmap font support across different file formats.
pub const spleen_bdf = @embedFile("res/spleen-8x16.bdf");
pub const spleen_pcf = @embedFile("res/spleen-8x16.pcf");
pub const spleen_otb = @embedFile("res/spleen-8x16.otb");

```

## Supporting notice file hashes

- `9d55524551411b493cca41ca06363625d90aff1e.txt`: `57a2362f222df8413b929eaa8d7d13bcb3bf5e1aa983aa241497d683fb8283db`
- `FreeType-FTL.txt`: `09fae0e47cfa0315d6f6faec699a39186df41de7f71998796521d1c563a73fb3`
- `Highway-LICENSE.txt`: `63ad3102b8ff6f1342fef15fa5da5c768124dae87bb712791da42e78b13316ed`
- `Oniguruma-COPYING.txt`: `52141eb3bb664ee2e8484b4f85c1e152b82e805c28cbac97e5c5973518225f1a`
- `libpng-LICENSE.txt`: `2a2f009a23146b39a1b475210dd7561ad100453e0b09cd7748e51539834a77c2`
- `simdutf-licenses.txt`: `f8b700200c0e053dbf301c4268a8ea140720e85f7389ba52c51dc9cbcaab898a`
- `src-stb-stb_image.h.txt`: `329ecb75f4691b7b6108c50f796e927107ee908134f8befedbc06201af46a648`
- `src-stb-stb_image_resize.h.txt`: `1392a4be488bf3989945aba0121ca9b2881778649be1471da60c615ffb4f7aee`
- `vaxis-LICENSE.txt`: `32b554a8beef40edf5ada8ec96245f889fe47a99c8f942d0e3bd2404bc8f8da9`
- `z2d-LICENSE.txt`: `8111ad25e35049e7ff759b818ff72beba199b4a694e1b0680242ad89b6fa34b4`
- `zf-LICENSE.txt`: `aac775bf747502b69b3dcd993b9f3211d30e4339cc0c8c61e93331e7cd0e0bab`
- `zig-objc-LICENSE.txt`: `d14be8b6e13a19b6bfdf966fd70a60b67f98080e2c3cddb3d394e4e935b506ac`
- `zlib-LICENSE.txt`: `b0b07cb28f1b1a4c5dae0aa6f0041a33906deb980a450b54ca23ae329e7bbc49`
