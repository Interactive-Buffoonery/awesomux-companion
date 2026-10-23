"""Exercise TestFlight configuration without Apple credentials or build tools."""
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / 'testflight.py'
TOOLS = runpy.run_path(str(HELPER))


class TestFlightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_auth_rejects_invalid_later_field_without_partial_output(self):
        config = self.root / 'auth.json'
        config.write_text(json.dumps({'private_key_path': '/synthetic/key.p8',
                                      'key_id': 'example', 'issuer_id': 'bad\nissuer'}))
        result = subprocess.run([sys.executable, str(HELPER), 'auth', str(config)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('Invalid Xcode authentication configuration', result.stderr)

    def profiles(self):
        certificate = b'synthetic-public-certificate'
        fingerprint = hashlib.sha1(certificate).hexdigest().upper()
        profiles, decoded, expected = {}, {}, {}
        for index, suffix in enumerate(['', '.widgets']):
            bundle = 'com.interactivebuffoonery.awesomux.companion' + suffix
            profile_uuid = f'abcdef00-0000-0000-0000-00000000000{index}'
            path = self.root / f'{index}.mobileprovision'
            path.write_bytes(str(index).encode())
            profiles[bundle] = str(path)
            expected[bundle] = profile_uuid
            decoded[path.read_bytes()] = plistlib.dumps({
                'UUID': profile_uuid, 'TeamIdentifier': ['7CNK4YPCQX'],
                'Entitlements': {'application-identifier': '7CNK4YPCQX.' + bundle,
                                 'get-task-allow': False},
                'ExpirationDate': datetime.datetime(2035, 1, 1),
                'DeveloperCertificates': [certificate]})
        config = self.root / 'export.json'
        config.write_text(json.dumps({'signingCertificate': fingerprint, 'profiles': profiles}))
        def decode(arguments, **kwargs):
            self.assertEqual(arguments, ['security', 'cms', '-D'])
            return subprocess.CompletedProcess(arguments, 0, decoded[kwargs['input']], b'')
        return config, fingerprint, expected, decode

    def test_export_returns_identity_and_preserves_issued_profile_uuids(self):
        config, fingerprint, expected, decode = self.profiles()
        output = self.root / 'export.plist'
        with patch.object(Path, 'home', return_value=self.root), \
                patch.object(subprocess, 'run', side_effect=decode):
            identity = TOOLS['prepare_export'](config, output)
        self.assertEqual(identity, fingerprint)
        options = plistlib.loads(output.read_bytes())
        self.assertEqual(options['signingCertificate'], identity)
        self.assertEqual(options['provisioningProfiles'], expected)
        self.assertEqual(options['destination'], 'export')
        directory = self.root / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
        for profile_uuid in expected.values():
            self.assertEqual((directory / f'{profile_uuid}.mobileprovision').stat().st_mode & 0o777, 0o600)

    def test_export_rejects_redirect_before_creating_outside_directories(self):
        config, _, _, decode = self.profiles()
        home, outside = self.root / 'home', self.root / 'outside'
        home.mkdir()
        outside.mkdir()
        (home / 'Library').symlink_to(outside, target_is_directory=True)
        with patch.object(Path, 'home', return_value=home), \
                patch.object(subprocess, 'run', side_effect=decode), self.assertRaises(ValueError):
            TOOLS['prepare_export'](config, self.root / 'export.plist')
        self.assertEqual(list(outside.iterdir()), [])

    def test_integration_requires_one_receipt_and_uses_its_original_package(self):
        native = self.root / 'native'
        with self.assertRaisesRegex(SystemExit, 'one fresh native renderer receipt'):
            TOOLS['integrate_native'](native, self.root / 'output')
        receipt = native / 'artifacts/build/build-receipt.json'
        receipt.parent.mkdir(parents=True)
        receipt.write_text(json.dumps({'sourceDirectory': str(self.root / 'original/ghostty')}))
        with patch.object(subprocess, 'run') as run:
            TOOLS['integrate_native'](native, self.root / 'output')
        self.assertEqual(run.call_args.args[0], [
            sys.executable, str(native.parent / 'integrate-native.py'),
            str(receipt.parent / 'GhosttyKit.xcframework'), str(self.root / 'original/libghostty-spm'),
            '--output-directory', str(self.root / 'output')])
        self.assertTrue(run.call_args.kwargs['check'])


if __name__ == '__main__':
    unittest.main()
