#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
ROOT_DIR="$PWD"
OUT_DIR="$ROOT_DIR/artifacts/public-metal-verified"
[[ ! -e "$OUT_DIR" ]]
mkdir -p "$OUT_DIR"
export PATH="$ROOT_DIR/toolchains/zig-aarch64-macos-0.16.0:$PATH"
python3 build-receipt.py begin "$OUT_DIR" "$ROOT_DIR/work/ghostty" "$ROOT_DIR/work/libghostty-spm" "$ROOT_DIR/rebuild-reviewed.sh"
export ZIG_GLOBAL_CACHE_DIR="$ROOT_DIR/work/cache/global"
export BUILD_CACHE_ROOT="$ROOT_DIR/work/cache/device"
export ZIG_CPU=
./work/libghostty-spm/Script/build-ghostty.sh "$ROOT_DIR/work/ghostty" aarch64-ios "$OUT_DIR/iphoneos" > "$OUT_DIR/device-build.log" 2>&1
export BUILD_CACHE_ROOT="$ROOT_DIR/work/cache/simulator"
export ZIG_CPU=apple_a17
./work/libghostty-spm/Script/build-ghostty.sh "$ROOT_DIR/work/ghostty" aarch64-ios-simulator "$OUT_DIR/iphonesimulator" > "$OUT_DIR/simulator-build.log" 2>&1
xcodebuild -create-xcframework \
    -library "$OUT_DIR/iphoneos/lib/libghostty.a" -headers "$OUT_DIR/iphoneos/include" \
    -library "$OUT_DIR/iphonesimulator/lib/libghostty.a" -headers "$OUT_DIR/iphonesimulator/include" \
    -output "$OUT_DIR/GhosttyKit.xcframework" > "$OUT_DIR/xcframework-build.log" 2>&1
python3 verify-artifacts.py "$OUT_DIR/GhosttyKit.xcframework" > "$OUT_DIR/binary-audit.json"
python3 build-receipt.py finish "$OUT_DIR" "$ROOT_DIR/work/ghostty" "$ROOT_DIR/work/libghostty-spm" "$ROOT_DIR/rebuild-reviewed.sh"
