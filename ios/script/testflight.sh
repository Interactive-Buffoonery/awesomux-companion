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
EXPORT_ONLY=false
CHECK_SIGNING=false
case "${1:-}" in
  "") ;;
  --export-only) EXPORT_ONLY=true ;;
  --check-signing) CHECK_SIGNING=true ;;
  *) echo "Usage: script/testflight.sh [--export-only|--check-signing]" >&2; exit 64 ;;
esac
[[ "$#" -le 1 ]] || { echo "Too many arguments" >&2; exit 64; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/companion-testflight.XXXXXX")"
mkdir -p "$IOS_DIR/../.build/testflight"
OUTPUT="$(mktemp -d "$IOS_DIR/../.build/testflight/build.XXXXXXXX")"
cleanup() {
  local status=$?
  if [[ -n "${HEAVY_GATE_SIGNING_KEYCHAIN:-}" ]]; then
    security lock-keychain "$HEAVY_GATE_SIGNING_KEYCHAIN" || status=1
  fi
  # Remote cleanup owns the whole job directory, including WORK.
  if [[ -z "${HEAVY_GATE_REMOTE_JOB:-}" ]]; then
    trash "$WORK" || status=1
  fi
  exit "$status"
}
trap cleanup EXIT

AUTH=()
if [[ -n "${HEAVY_GATE_XCODE_AUTH_CONFIG:-}" ]]; then
  # Read only the three Xcode fields; never print the API private key.
  while IFS= read -r value; do AUTH+=("$value"); done < <(
    python3 - "$HEAVY_GATE_XCODE_AUTH_CONFIG" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
for name in ('private_key_path', 'key_id', 'issuer_id'):
    value = data[name]
    if not isinstance(value, str) or not value or '\n' in value:
        raise SystemExit('Invalid Xcode authentication configuration')
    print(value)
PY
  )
  [[ "${#AUTH[@]}" -eq 3 && -r "${AUTH[0]}" ]] || {
    echo "Xcode API authentication is unavailable" >&2; exit 1;
  }
  AUTH=(-authenticationKeyPath "${AUTH[0]}" -authenticationKeyID "${AUTH[1]}" -authenticationKeyIssuerID "${AUTH[2]}")
fi
SIGNING=()
if [[ -n "${HEAVY_GATE_SIGNING_KEYCHAIN:-}" ]]; then
  [[ -n "${HEAVY_GATE_REMOTE_JOB:-}" ]] || {
    echo "Runner signing requires an isolated heavy-gate remote job" >&2; exit 1;
  }
  # These preferences belong to the disposable job HOME, not the user's login.
  mkdir -p "$HOME/Library/Preferences"
  security list-keychains -d user -s "$HEAVY_GATE_SIGNING_KEYCHAIN"
  security default-keychain -d user -s "$HEAVY_GATE_SIGNING_KEYCHAIN"
  python3 - "$HEAVY_GATE_SIGNING_KEYCHAIN" "$HEAVY_GATE_SIGNING_PASSWORD_FILE" <<'PY'
from pathlib import Path
import subprocess, sys
result = subprocess.run(['security', 'unlock-keychain', '-p', Path(sys.argv[2]).read_text(), sys.argv[1]],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if result.returncode:
    raise SystemExit('Runner signing keychain could not be unlocked')
PY
  SIGNING=("OTHER_CODE_SIGN_FLAGS=--keychain $HEAVY_GATE_SIGNING_KEYCHAIN")
fi

if [[ "$CHECK_SIGNING" == true ]]; then
  [[ -n "${HEAVY_GATE_SIGNING_KEYCHAIN:-}" ]] || {
    echo "Signing probe requires runner credentials" >&2; exit 1;
  }
  cp /usr/bin/true "$WORK/signing-probe"
  REAL_USER_HOME="$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
  HOME="$REAL_USER_HOME" codesign --force --sign 'Apple Development' --keychain "$HEAVY_GATE_SIGNING_KEYCHAIN" \
    --timestamp=none "$WORK/signing-probe"
  codesign --verify --strict "$WORK/signing-probe"
  echo "Runner signing probe passed"
  exit 0
fi

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
if [[ -n "${HEAVY_GATE_REMOTE_JOB:-}" ]]; then
  # Fresh runner checkouts need the source-built renderer and its original inputs.
  NATIVE="$IOS_DIR/../spikes/ios-terminal-renderer/native"
  zsh "$NATIVE/build.sh" 1e9e14af5df14211892f5fc15fd21a49c7d94868
  python3 - "$NATIVE" "$IOS_DIR/build/diagnostics-native" <<'PYTHON'
import json, subprocess, sys
from pathlib import Path
native = Path(sys.argv[1])
receipts = list((native / 'artifacts').glob('*/build-receipt.json'))
if len(receipts) != 1:
    raise SystemExit('Expected one fresh native renderer receipt')
receipt = receipts[0]
data = json.loads(receipt.read_text())
package = Path(data['sourceDirectory']).parent / 'libghostty-spm'
subprocess.run([sys.executable, str(native.parent / 'integrate-native.py'),
                str(receipt.parent / 'GhosttyKit.xcframework'), str(package),
                '--output-directory', sys.argv[2]], check=True)
PYTHON
fi
zsh script/generate-watch.sh
echo "Archiving build $BUILD_NUMBER (logs in $OUTPUT)"
DERIVED_DATA=()
if [[ -n "${HEAVY_GATE_REMOTE_JOB:-}" ]]; then
  DERIVED_DATA=(-derivedDataPath "$WORK/DerivedData")
fi
xcodebuild -project AwesoMuxCompanion.xcodeproj -scheme AwesoMuxCompanion -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/app.xcarchive" -allowProvisioningUpdates \
  ${DERIVED_DATA[@]+"${DERIVED_DATA[@]}"} ${AUTH[@]+"${AUTH[@]}"} ${SIGNING[@]+"${SIGNING[@]}"} \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive > "$OUTPUT/archive.log" 2>&1 \
  || { tail -20 "$OUTPUT/archive.log"; exit 1; }
xcodebuild -exportArchive -archivePath "$WORK/app.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
  -exportPath "$OUTPUT/export" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} > "$OUTPUT/export.log" 2>&1 \
  || { tail -20 "$OUTPUT/export.log"; exit 1; }

if [[ "$EXPORT_ONLY" == true ]]; then
  echo "Build $BUILD_NUMBER exported to $OUTPUT/export; upload was not requested."
  exit 0
fi

echo "Uploading and waiting for processing"
asc builds upload --app "$APP_ID" --ipa "$OUTPUT/export/AwesoMuxCompanion.ipa" --wait ${TEST_NOTES:+--test-notes "$TEST_NOTES" --locale en-US}
asc builds add-groups --app "$APP_ID" --build-number "$BUILD_NUMBER" --platform IOS --group "$GROUP"
echo "Build $BUILD_NUMBER is on TestFlight for $GROUP."
