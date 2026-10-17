import subprocess
import unittest
from unittest.mock import patch
from probe_runtime import validate_endpoint, cleanup

class RuntimeChecks(unittest.TestCase):
    def test_endpoint_requires_actual_loopback(self):
        validate_endpoint('ws://127.0.0.1:18769')
        for endpoint in ('ws://127.0.0.1:123@elsewhere.example:80', 'ws://127.0.0.1', 'ws://127.0.0.1:0', 'wss://127.0.0.1:80', 'ws://127.0.0.1:80/path'):
            with self.assertRaises(ValueError):
                validate_endpoint(endpoint)

    def test_cleanup_survives_timeout_and_failed_list(self):
        class Process:
            stopped = False
            def poll(self): return None
            def terminate(self): self.stopped = True
            def wait(self, timeout): return 0
        desktop = Process()
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            if args[1] == 'kill': raise subprocess.TimeoutExpired(args, 10)
            return subprocess.CompletedProcess(args, 1, stdout=b'')
        result = {}
        with patch('probe_runtime.os.close') as close:
            cleanup([], desktop, 9, 'owned', {}, result, run=run)
        self.assertEqual(len(calls), 2)
        self.assertTrue(desktop.stopped)
        close.assert_called_once_with(9)
        self.assertIsNone(result['amx_absent'])
        self.assertEqual(result['owned_amx_session'], 'owned')
        self.assertTrue(result['cleanup_errors'])
