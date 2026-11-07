"""Security/configuration cases with synthetic files; no accounts or user data."""
import copy
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from configuration import load, personal_spec, ROOT
from personal import export_options, profile, METHODS


class PersonalTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((ROOT / 'developer/squircle/config.example.json').read_text())
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'fixture'
        self.cert = b'synthetic certificate'
        self.fingerprint = hashlib.sha1(self.cert).hexdigest().upper()
        self.options = {'method': 'debugging', 'teamID': self.config['team_id'], 'signingStyle': 'manual',
                        'signingCertificate': self.fingerprint, 'provisioningProfiles': {
                            self.config['bundle_id']: '11111111-1111-1111-1111-111111111111', self.config['bundle_id'] + '.widgets': '22222222-2222-2222-2222-222222222222'}}

    def write_json(self, data):
        self.path.write_text(json.dumps(data))
        return self.path

    def test_configuration_rejects_injection_and_credentials(self):
        self.assertEqual(load(self.write_json(self.config)), self.config)
        for key in self.config:
            for value in ['x"; fatalError(); //', 'line\nbreak', '', None, 'https://private.invalid']:
                with self.subTest(key=key, value=value):
                    bad = {**self.config, key: value}
                    with self.assertRaises(ValueError):
                        load(self.write_json(bad))
        with self.assertRaises(ValueError):
            load(self.write_json({**self.config, 't3_token': 'synthetic'}))

    def test_alternate_namespace_covers_both_targets_and_group(self):
        config = {**self.config, 'bundle_id': 'net.example.companion', 'app_group': 'group.net.example.companion', 'team_id': 'ABCDEFGHIJ'}
        spec = personal_spec(config)
        self.assertNotIn(self.config['bundle_id'], spec)
        self.assertNotIn(self.config['app_group'], spec)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: net.example.companion.widgets', spec)
        self.assertEqual(spec.count('AwesoMuxAppGroup: group.net.example.companion'), 2)
        self.assertIn('Verify public renderer', spec)
        self.assertIn('watch-manifest.py', spec)

    def test_export_method_and_destination_matrix(self):
        for method in METHODS | {'app-store', 'app-store-connect', 'enterprise', '', 'Debug'}:
            for destination in ['export', 'upload']:
                options = {**self.options, 'method': method, 'destination': destination}
                self.path.write_bytes(plistlib.dumps(options))
                if method in METHODS and destination == 'export':
                    self.assertEqual(export_options(self.path, self.config), options)
                else:
                    with self.assertRaises(ValueError):
                        export_options(self.path, self.config)

    def test_export_requires_exact_profiles_and_identity(self):
        for change in [{'teamID': 'ABCDEFGHIJ'}, {'signingStyle': 'automatic'}, {'signingCertificate': 'Apple Development'},
                       {'provisioningProfiles': {self.config['bundle_id']: '11111111-1111-1111-1111-111111111111'}}]:
            self.path.write_bytes(plistlib.dumps({**self.options, **change}))
            with self.assertRaises(ValueError):
                export_options(self.path, self.config)

    def test_profile_mismatch_fails_before_build(self):
        bundle = self.config['bundle_id']
        data = {'UUID': '11111111-1111-1111-1111-111111111111', 'ApplicationIdentifierPrefix': ['OLDPREFIX1'], 'TeamIdentifier': [self.config['team_id']],
                'ExpirationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) + datetime.timedelta(days=1),
                'ProvisionedDevices': ['synthetic-device'], 'DeveloperCertificates': [self.cert],
                'Entitlements': {'application-identifier': 'OLDPREFIX1.' + bundle,
                                 'com.apple.developer.team-identifier': self.config['team_id'], 'get-task-allow': True,
                                 'com.apple.security.application-groups': [self.config['app_group']]}}
        def check(candidate):
            with patch('personal.run', return_value=subprocess.CompletedProcess([], 0, plistlib.dumps(candidate))):
                return profile(self.path, bundle, self.config, self.options)
        self.assertEqual(check(data), '11111111-1111-1111-1111-111111111111')
        for key, value in [('ExpirationDate', datetime.datetime(2000, 1, 1)), ('ProvisionedDevices', []),
                           ('ProvisionsAllDevices', True), ('TeamIdentifier', ['ABCDEFGHIJ']),
                           ('UUID', 'WRONG'), ('DeveloperCertificates', [])]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                check({**data, key: value})
        for key, value in [('application-identifier', 'OLDPREFIX1.*'), ('get-task-allow', False),
                           ('com.apple.security.application-groups', ['group.example.wrong'])]:
            bad = copy.deepcopy(data)
            bad['Entitlements'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                check(bad)


if __name__ == '__main__':
    unittest.main()
