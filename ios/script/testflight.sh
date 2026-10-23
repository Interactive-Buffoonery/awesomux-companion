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
result = subprocess.run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s',
                         '-k', Path(sys.argv[2]).read_text(), sys.argv[1]],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if result.returncode:
    raise SystemExit('Runner signing key authorization could not be configured')
PY
  SIGNING=("OTHER_CODE_SIGN_FLAGS=--keychain $HEAVY_GATE_SIGNING_KEYCHAIN")
fi

DISTRIBUTION_IDENTITY='Apple Distribution'
if [[ -n "${HEAVY_GATE_XCODE_EXPORT_CONFIG:-}" ]]; then
  [[ -n "${HEAVY_GATE_REMOTE_JOB:-}" ]] || {
    echo "Manual export requires an isolated heavy-gate remote job" >&2; exit 1;
  }
  python3 - "$HEAVY_GATE_XCODE_EXPORT_CONFIG" "$WORK/export.plist" <<'PYTHON'
import datetime, hashlib, json, os, plistlib, re, subprocess, sys, uuid
from xml.parsers.expat import ExpatError
from pathlib import Path

team = '7CNK4YPCQX'
bundles = {
    'com.interactivebuffoonery.awesomux.companion',
    'com.interactivebuffoonery.awesomux.companion.widgets',
}

def prepare_export():
    config = json.loads(Path(sys.argv[1]).read_text())
    if not isinstance(config, dict) or set(config) != {'signingCertificate', 'profiles'}:
        raise ValueError()
    certificate = config['signingCertificate']
    if not isinstance(certificate, str) or not re.fullmatch(r'[0-9A-F]{40}', certificate):
        raise ValueError()
    profiles = config['profiles']
    if not isinstance(profiles, dict) or set(profiles) != bundles:
        raise ValueError()
    validated = {}
    for bundle, source in profiles.items():
        if not isinstance(source, str):
            raise ValueError()
        path = Path(source)
        if not path.is_absolute() or path.suffix != '.mobileprovision':
            raise ValueError()
        contents = path.read_bytes()
        decoded = subprocess.run(['security', 'cms', '-D'], input=contents,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        profile = plistlib.loads(decoded.stdout)
        profile_uuid = profile['UUID']
        if not isinstance(profile_uuid, str) or str(uuid.UUID(profile_uuid)).upper() != profile_uuid.upper():
            raise ValueError()
        entitlements = profile['Entitlements']
        if profile['TeamIdentifier'] != [team] or entitlements['application-identifier'] != f'{team}.{bundle}':
            raise ValueError()
        if entitlements.get('get-task-allow') is not False:
            raise ValueError()
        if 'ProvisionedDevices' in profile or 'ProvisionsAllDevices' in profile:
            raise ValueError()
        expires = profile['ExpirationDate']
        if not isinstance(expires, datetime.datetime):
            raise ValueError()
        if expires.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
            raise ValueError()
        certificates = profile['DeveloperCertificates']
        if not isinstance(certificates, list) or not all(isinstance(item, bytes) for item in certificates):
            raise ValueError()
        if certificate not in {hashlib.sha1(item).hexdigest().upper() for item in certificates}:
            raise ValueError()
        if profile_uuid.casefold() in {item[0].casefold() for item in validated.values()}:
            raise ValueError()
        validated[bundle] = (profile_uuid, contents)

    directory = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
    if not directory.resolve().is_relative_to(Path.home().resolve()):
        raise ValueError()
    directory.mkdir(parents=True, exist_ok=True)
    if not directory.resolve().is_relative_to(Path.home().resolve()):
        raise ValueError()
    for profile_uuid, contents in validated.values():
        destination = directory / f'{profile_uuid}.mobileprovision'
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as installed:
            os.fchmod(installed.fileno(), 0o600)
            installed.write(contents)
    options = {
        'method': 'app-store-connect',
        'destination': 'export',
        'teamID': team,
        'signingStyle': 'manual',
        'signingCertificate': certificate,
        'provisioningProfiles': {bundle: item[0] for bundle, item in validated.items()},
        'manageAppVersionAndBuildNumber': False,
    }
    with Path(sys.argv[2]).open('wb') as output:
        plistlib.dump(options, output)

try:
    prepare_export()
except (OSError, ValueError, KeyError, TypeError, AttributeError, ExpatError, subprocess.SubprocessError):
    raise SystemExit('Manual export configuration or App Store profiles are invalid') from None
PYTHON
  DISTRIBUTION_IDENTITY="$(python3 - "$WORK/export.plist" <<'PYTHON'
import plistlib, sys
from pathlib import Path
print(plistlib.loads(Path(sys.argv[1]).read_bytes())['signingCertificate'])
PYTHON
  )"
fi

if [[ "$CHECK_SIGNING" == true ]]; then
  [[ -n "${HEAVY_GATE_SIGNING_KEYCHAIN:-}" ]] || {
    echo "Signing probe requires runner credentials" >&2; exit 1;
  }
  for identity in 'Apple Development' "$DISTRIBUTION_IDENTITY"; do
    cp /usr/bin/true "$WORK/signing-probe"
    codesign --force --sign "$identity" --keychain "$HEAVY_GATE_SIGNING_KEYCHAIN" \
      --timestamp=none "$WORK/signing-probe"
    codesign --verify --strict "$WORK/signing-probe"
    echo "$identity signing passed"
  done
  echo "Runner signing probe passed"
  exit 0
fi

if [[ -z "${HEAVY_GATE_XCODE_EXPORT_CONFIG:-}" ]]; then
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
fi

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
XCODEBUILD=(xcodebuild)
if [[ -n "${HEAVY_GATE_REMOTE_JOB:-}" ]]; then
  DERIVED_DATA=(-derivedDataPath "$WORK/DerivedData")
  if [[ -n "${HEAVY_GATE_XCODE_EXPORT_CONFIG:-}" ]]; then
    XCODEBUILD=(env "CFFIXED_USER_HOME=$HOME" xcodebuild)
  fi
fi
"${XCODEBUILD[@]}" -project AwesoMuxCompanion.xcodeproj -scheme AwesoMuxCompanion -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/app.xcarchive" -allowProvisioningUpdates \
  ${DERIVED_DATA[@]+"${DERIVED_DATA[@]}"} ${AUTH[@]+"${AUTH[@]}"} ${SIGNING[@]+"${SIGNING[@]}"} \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive > "$OUTPUT/archive.log" 2>&1 \
  || { tail -20 "$OUTPUT/archive.log"; exit 1; }
EXPORT_AUTH=(-allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"})
if [[ -n "${HEAVY_GATE_XCODE_EXPORT_CONFIG:-}" ]]; then
  EXPORT_AUTH=()
fi
"${XCODEBUILD[@]}" -exportArchive -archivePath "$WORK/app.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
  -exportPath "$OUTPUT/export" ${EXPORT_AUTH[@]+"${EXPORT_AUTH[@]}"} > "$OUTPUT/export.log" 2>&1 \
  || { tail -20 "$OUTPUT/export.log"; exit 1; }

if [[ "$EXPORT_ONLY" == true ]]; then
  echo "Build $BUILD_NUMBER exported to $OUTPUT/export; upload was not requested."
  exit 0
fi

echo "Uploading and waiting for processing"
asc builds upload --app "$APP_ID" --ipa "$OUTPUT/export/AwesoMuxCompanion.ipa" --wait ${TEST_NOTES:+--test-notes "$TEST_NOTES" --locale en-US}
asc builds add-groups --app "$APP_ID" --build-number "$BUILD_NUMBER" --platform IOS --group "$GROUP"
echo "Build $BUILD_NUMBER is on TestFlight for $GROUP."
