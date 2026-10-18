#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
ROOT_DIR="$PWD"
REF=${1:?Usage: ./build.sh <exact-ghostty-ref>}
[[ "$REF" == 1e9e14af5df14211892f5fc15fd21a49c7d94868 ]]
PACKAGE_REF=42bacd1339f323a693ddbca779295f4f77e5a697
ZIG_SHA=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
ZIG_DIR="$ROOT_DIR/toolchains/zig-aarch64-macos-0.16.0"
mkdir -p toolchains work artifacts
if [[ ! -x "$ZIG_DIR/zig" ]]; then
    curl -fL https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz -o toolchains/zig.tar.xz
    [[ "$(shasum -a 256 toolchains/zig.tar.xz | cut -d' ' -f1)" == "$ZIG_SHA" ]]
    tar -xf toolchains/zig.tar.xz -C toolchains
fi
[[ "$("$ZIG_DIR/zig" version)" == 0.16.0 ]]
export PATH="$ZIG_DIR:$PATH"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="$ROOT_DIR/work/$RUN_ID"
OUT_DIR="$ROOT_DIR/artifacts/$RUN_ID"
mkdir -p "$RUN_DIR" "$OUT_DIR"
exec > >(tee "$OUT_DIR/build.log") 2>&1
PACKAGE="$RUN_DIR/libghostty-spm"
SOURCE="$RUN_DIR/ghostty"
git clone https://github.com/Lakr233/libghostty-spm.git "$PACKAGE"
git -C "$PACKAGE" checkout --detach "$PACKAGE_REF"
git clone https://github.com/ghostty-org/ghostty.git "$SOURCE"
git -C "$SOURCE" checkout --detach "$REF"
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$REF" ]]
[[ "$(tr -d '[:space:]' < "$PACKAGE/Ghostty.ref")" == "$REF" ]]
[[ "$(tr -d '[:space:]' < "$PACKAGE/Ghostty.build")" == 3 ]]
export ZIG_GLOBAL_CACHE_DIR="$RUN_DIR/cache/global"
export ZIG_LOCAL_CACHE_DIR="$RUN_DIR/cache/preparation"
"$PACKAGE/Script/apply-patches.sh" "$SOURCE"
git -C "$SOURCE" apply --check "$ROOT_DIR/0022-ios-public-metal-layer.patch"
git -C "$SOURCE" apply "$ROOT_DIR/0022-ios-public-metal-layer.patch"
cp "$ROOT_DIR/0022-ios-public-metal-layer.patch" "$PACKAGE/Patches/ghostty/0022-ios-public-metal-layer.patch"
python3 "$ROOT_DIR/prepare-driver.py" "$PACKAGE/Script/build-ghostty.sh"
python3 "$ROOT_DIR/build-receipt.py" begin "$OUT_DIR" "$SOURCE" "$PACKAGE" "$ROOT_DIR/build.sh"
for target in aarch64-ios aarch64-ios-simulator; do
    export BUILD_CACHE_ROOT="$RUN_DIR/cache/$target"
    export ZIG_CPU=
    if [[ "$target" == aarch64-ios-simulator ]]; then export ZIG_CPU=apple_a17; fi
    "$PACKAGE/Script/build-ghostty.sh" "$SOURCE" "$target" "$OUT_DIR/$target"
done
xcodebuild -create-xcframework \
    -library "$OUT_DIR/aarch64-ios/lib/libghostty.a" -headers "$OUT_DIR/aarch64-ios/include" \
    -library "$OUT_DIR/aarch64-ios-simulator/lib/libghostty.a" -headers "$OUT_DIR/aarch64-ios-simulator/include" \
    -output "$OUT_DIR/GhosttyKit.xcframework"
python3 "$ROOT_DIR/verify-artifacts.py" "$OUT_DIR/GhosttyKit.xcframework" > "$OUT_DIR/binary-audit.json"
(cd "$PACKAGE" && shasum -a 256 Patches/ghostty/*) > "$OUT_DIR/ordered-patches.sha256"
shasum -a 256 "$ROOT_DIR/0022-ios-public-metal-layer.patch" "$ZIG_DIR/zig" > "$OUT_DIR/inputs.sha256"
git -C "$SOURCE" diff --binary > "$OUT_DIR/complete-source.diff"
printf '%s\n' "package=$PACKAGE_REF" "ghostty=$REF" "zig=0.16.0" "source=$SOURCE" > "$OUT_DIR/provenance.txt"
python3 "$ROOT_DIR/build-receipt.py" finish "$OUT_DIR" "$SOURCE" "$PACKAGE" "$ROOT_DIR/build.sh"
echo "[+] Native artifact: $OUT_DIR/GhosttyKit.xcframework"
