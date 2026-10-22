"""Check transitive dependency drift without package resolution or app builds."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'diagnostics-lock.py'
LOCK = runpy.run_path(str(SCRIPT))
validate_lock = LOCK['validate_lock']


class DiagnosticsLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.resolved = Path(self.temporary.name) / 'Package.resolved'
        self.tracked = LOCK['TRACKED']
        self.data = json.loads(self.tracked.read_text())

    def write(self, data):
        self.resolved.write_text(json.dumps(data))

    def test_seed_cli_copies_tracked_lock_before_strict_validation(self):
        root = Path(self.temporary.name)
        script = root / 'ios/script/diagnostics-lock.py'
        script.parent.mkdir(parents=True)
        script.write_bytes(SCRIPT.read_bytes())
        tracked = root / 'spikes/ios-terminal-renderer/Package.resolved'
        tracked.parent.mkdir(parents=True)
        tracked.write_bytes(self.tracked.read_bytes())
        subprocess.run([sys.executable, str(script), '--seed'], check=True)
        resolved = root / 'ios/AwesoMuxDiagnostics.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        self.assertEqual(resolved.read_bytes(), tracked.read_bytes())
        subprocess.run([sys.executable, str(script)], check=True)

    def test_shipping_project_uses_same_pinned_lock(self):
        root = Path(self.temporary.name)
        script = root / 'ios/script/diagnostics-lock.py'
        script.parent.mkdir(parents=True)
        script.write_bytes(SCRIPT.read_bytes())
        tracked = root / 'spikes/ios-terminal-renderer/Package.resolved'
        tracked.parent.mkdir(parents=True)
        tracked.write_bytes(self.tracked.read_bytes())
        subprocess.run([sys.executable, str(script), '--project', 'AwesoMuxCompanion', '--seed'], check=True)
        resolved = root / 'ios/AwesoMuxCompanion.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        self.assertEqual(resolved.read_bytes(), tracked.read_bytes())
        data = json.loads(resolved.read_text())
        data['pins'][0]['state']['revision'] = '0' * 40
        resolved.write_text(json.dumps(data))
        result = subprocess.run([sys.executable, str(script), '--project', 'AwesoMuxCompanion'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'pins differ', result.stderr)

    def test_tracked_displaylink_identity(self):
        self.assertEqual(self.data['pins'][0]['identity'], 'displaylink')
        self.assertEqual(self.data['pins'][0]['state'], {
            'revision': '41bea2661e04bebcb1c4f15fc0b6197850100fdd', 'version': '3.0.1',
        })
        self.write(self.data)
        validate_lock(self.tracked, self.resolved)

    def test_missing_lock_only_allowed_before_generation(self):
        with self.assertRaisesRegex(SystemExit, 'Missing diagnostic'):
            validate_lock(self.tracked, self.resolved)
        validate_lock(self.tracked, self.resolved, allow_missing=True)

    def test_future_version_and_other_pin_drift_rejected(self):
        for field, value in [('revision', 'a' * 40), ('version', '3.1.0'),
                             ('location', 'https://example.com/DisplayLink.git'),
                             ('kind', 'localSourceControl'), ('identity', 'replacement')]:
            with self.subTest(field=field):
                changed = copy.deepcopy(self.data)
                pin = changed['pins'][0]
                (pin['state'] if field in {'revision', 'version'} else pin)[field] = value
                self.write(changed)
                for allow_missing in [False, True]:
                    with self.assertRaisesRegex(SystemExit, 'pins differ'):
                        validate_lock(self.tracked, self.resolved, allow_missing)

    def test_origin_metadata_can_change_without_pin_drift(self):
        self.data['originHash'] = 'different project graph'
        self.write(self.data)
        validate_lock(self.tracked, self.resolved)

    def test_extra_or_duplicate_pin_rejected(self):
        self.data['pins'].append(copy.deepcopy(self.data['pins'][0]))
        self.write(self.data)
        with self.assertRaisesRegex(SystemExit, 'Duplicate'):
            validate_lock(self.tracked, self.resolved)
        self.data['pins'][1]['identity'] = 'unexpected-dependency'
        self.write(self.data)
        with self.assertRaisesRegex(SystemExit, 'pins differ'):
            validate_lock(self.tracked, self.resolved)


if __name__ == '__main__':
    unittest.main()
