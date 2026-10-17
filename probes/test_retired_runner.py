import pathlib
import subprocess
import sys
import unittest

class RetiredRunnerTests(unittest.TestCase):
    def test_old_runner_fails_closed_without_arguments_or_runtime(self):
        result = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('run_live_probe.py'))], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Retired live probe', result.stderr)
        self.assertEqual(result.stdout, '')
