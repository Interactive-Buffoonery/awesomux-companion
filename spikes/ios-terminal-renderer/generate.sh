#!/bin/sh
set -eu

cd "$(dirname "$0")"
if [ ! -f build/local-package-path.txt ]; then
    echo "Run integrate-native.py with the rebuilt XCFramework and pinned package checkout first." >&2
    exit 1
fi
GHOSTTY_LOCAL_PACKAGE=$(cat build/local-package-path.txt)
export GHOSTTY_LOCAL_PACKAGE
manifest_path="IOSRendererSpike/source-manifest.txt"
manifest_temp=$(mktemp "${TMPDIR:-/tmp}/renderer-spike-manifest.XXXXXX")
{
    for source in .gitignore Package.resolved README.md generate.sh integrate-native.py project.yml native/0022-ios-public-metal-layer.patch; do
        shasum -a 256 "$source"
    done
    find IOSRendererSpike -type f \
        ! -name Info.plist \
        ! -name source-manifest.txt \
        -print | LC_ALL=C sort | while IFS= read -r source; do
        shasum -a 256 "$source"
    done
} > "$manifest_temp"
mv "$manifest_temp" "$manifest_path"

xcodegen generate
lock_directory="IOSRendererSpike.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$lock_directory"
cp Package.resolved "$lock_directory/Package.resolved"
