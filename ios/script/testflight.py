"""Prepare TestFlight runner authentication, signing, profiles, and native inputs."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid
from xml.parsers.expat import ExpatError


TEAM = '7CNK4YPCQX'
BUNDLES = {
    'com.interactivebuffoonery.awesomux.companion',
    'com.interactivebuffoonery.awesomux.companion.widgets',
}


def authentication(config_path):
    data = json.loads(config_path.read_text())
    values = [data[name] for name in ('private_key_path', 'key_id', 'issuer_id')]
    if any(not isinstance(value, str) or not value or '\n' in value for value in values):
        raise ValueError()
    return values


def unlock_keychain(keychain, password_path):
    password = password_path.read_text()
    result = subprocess.run(['security', 'unlock-keychain', '-p', password, str(keychain)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise SystemExit('Runner signing keychain could not be unlocked')
    result = subprocess.run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s',
                             '-k', password, str(keychain)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode:
        raise SystemExit('Runner signing key authorization could not be configured')


def prepare_export(config_path, output_path):
    config = json.loads(config_path.read_text())
    if not isinstance(config, dict) or set(config) != {'signingCertificate', 'profiles'}:
        raise ValueError()
    certificate = config['signingCertificate']
    if not isinstance(certificate, str) or not re.fullmatch(r'[0-9A-F]{40}', certificate):
        raise ValueError()
    profiles = config['profiles']
    if not isinstance(profiles, dict) or set(profiles) != BUNDLES:
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
        if profile['TeamIdentifier'] != [TEAM] or entitlements['application-identifier'] != f'{TEAM}.{bundle}':
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
        'teamID': TEAM,
        'signingStyle': 'manual',
        'signingCertificate': certificate,
        'provisioningProfiles': {bundle: item[0] for bundle, item in validated.items()},
        'manageAppVersionAndBuildNumber': False,
    }
    with output_path.open('wb') as output:
        plistlib.dump(options, output)

    return certificate


def integrate_native(native, output):
    receipts = list((native / 'artifacts').glob('*/build-receipt.json'))
    if len(receipts) != 1:
        raise SystemExit('Expected one fresh native renderer receipt')
    receipt = receipts[0]
    data = json.loads(receipt.read_text())
    package = Path(data['sourceDirectory']).parent / 'libghostty-spm'
    subprocess.run([sys.executable, str(native.parent / 'integrate-native.py'),
                    str(receipt.parent / 'GhosttyKit.xcframework'), str(package),
                    '--output-directory', str(output)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    auth = commands.add_parser('auth')
    auth.add_argument('config', type=Path)
    signing = commands.add_parser('unlock-keychain')
    signing.add_argument('keychain', type=Path)
    signing.add_argument('password_file', type=Path)
    export = commands.add_parser('prepare-export')
    export.add_argument('config', type=Path)
    export.add_argument('output', type=Path)
    native = commands.add_parser('integrate-native')
    native.add_argument('native', type=Path)
    native.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.command == 'auth':
        try:
            values = authentication(args.config)
        except (OSError, ValueError, KeyError, TypeError):
            raise SystemExit('Invalid Xcode authentication configuration') from None
        print('\n'.join(values))
    elif args.command == 'unlock-keychain':
        unlock_keychain(args.keychain, args.password_file)
    elif args.command == 'prepare-export':
        try:
            identity = prepare_export(args.config, args.output)
        except (OSError, ValueError, KeyError, TypeError, AttributeError, ExpatError, subprocess.SubprocessError):
            raise SystemExit('Manual export configuration or App Store profiles are invalid') from None
        print(identity)
    elif args.command == 'integrate-native':
        integrate_native(args.native, args.output)


if __name__ == '__main__':
    main()
