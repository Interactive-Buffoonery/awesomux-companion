#!/bin/bash
# Archive the app, upload it with the asc CLI, and give it to the internal TestFlight group.
#
# One-time setup: see "TestFlight" in ios/README.md.
set -euo pipefail

APP_ID=6818681453
GROUP="${TESTFLIGHT_GROUP:-Personal Testing}"
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ponytail: timestamp build numbers are always increasing, so nothing is committed per upload.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
WORK="$(mktemp -d /tmp/companion-testflight.XXXXXX)"

cat > "$WORK/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>export</string>
<key>teamID</key><string>7CNK4YPCQX</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

cd "$IOS_DIR"
zsh script/generate-watch.sh
echo "Archiving build $BUILD_NUMBER (logs in $WORK)"
xcodebuild -project AwesoMuxCompanion.xcodeproj -scheme AwesoMuxCompanion -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/app.xcarchive" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive > "$WORK/archive.log" 2>&1 \
  || { tail -20 "$WORK/archive.log"; exit 1; }
xcodebuild -exportArchive -archivePath "$WORK/app.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
  -exportPath "$WORK/export" -allowProvisioningUpdates > "$WORK/export.log" 2>&1 \
  || { tail -20 "$WORK/export.log"; exit 1; }

echo "Uploading and waiting for processing"
asc builds upload --app "$APP_ID" --ipa "$WORK/export/AwesoMuxCompanion.ipa" --wait ${TEST_NOTES:+--test-notes "$TEST_NOTES" --locale en-US}
asc builds add-groups --app "$APP_ID" --build-number "$BUILD_NUMBER" --platform IOS --group "$GROUP"
echo "Build $BUILD_NUMBER is on TestFlight for $GROUP."
