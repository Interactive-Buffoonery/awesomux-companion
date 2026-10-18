"""Verify schema 2 receipt output without invoking a compiler or native build."""
import hashlib
import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

NATIVE = Path(__file__).resolve().parents[3] / 'spikes/ios-terminal-renderer/native'
with patch.object(sys, 'path', [str(NATIVE), *sys.path]):
    RECEIPT = runpy.run_path(str(NATIVE / 'build-receipt.py'))
finish_receipt = RECEIPT['finish_receipt']


class NativeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        self.framework = self.output / 'GhosttyKit.xcframework'
        self.files = ['Info.plist', 'ios-arm64/libghostty.a', 'ios-arm64/Headers/ghostty.h',
                      'ios-arm64-simulator/libghostty.a', 'ios-arm64-simulator/Headers/ghostty.h']
        for relative in self.files:
            path = self.framework / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)
        self.inputs = {'schemaVersion': 2, 'sourceHashes': {'example.zig': 'source hash'}}
        (self.output / 'build-inputs.json').write_text(json.dumps(self.inputs))

    def test_build_driver_begin_finish_cli_contract(self):
        (self.output / 'build-inputs.json').rename(self.output / 'saved-inputs.json')
        main = RECEIPT['main']
        with patch.dict(main.__globals__, {'inputs': lambda source, package, recipe: self.inputs}):
            for mode in ['begin', 'finish']:
                with patch.object(sys, 'argv', ['build-receipt.py', mode, str(self.output),
                                               str(self.output / 'source'), str(self.output / 'package'),
                                               str(NATIVE / 'build.sh')]):
                    main()
        receipt = json.loads((self.output / 'build-receipt.json').read_text())
        self.assertEqual(receipt['schemaVersion'], 2)
        self.assertEqual(set(receipt['frameworkHashes']), set(self.files))

    def test_finish_binds_every_packaged_file_and_preserves_snapshot(self):
        snapshot = (self.output / 'build-inputs.json').read_bytes()
        finish_receipt(self.output, self.inputs)
        receipt = json.loads((self.output / 'build-receipt.json').read_text())
        self.assertEqual(receipt['schemaVersion'], 2)
        self.assertEqual(receipt['frameworkHashes'], {
            relative: hashlib.sha256((self.framework / relative).read_bytes()).hexdigest()
            for relative in self.files
        })
        self.assertEqual(receipt['archiveHashes'], {
            relative: receipt['frameworkHashes'][relative]
            for relative in self.files if relative.endswith('/libghostty.a')
        })
        self.assertEqual(snapshot, (self.output / 'build-inputs.json').read_bytes())
        self.assertEqual({k: v for k, v in receipt.items()
                          if k not in {'archiveHashes', 'frameworkHashes'}}, self.inputs)
        with self.assertRaises(FileExistsError):
            finish_receipt(self.output, self.inputs)

    def test_finish_rejects_changed_inputs_without_issuing_receipt(self):
        with self.assertRaisesRegex(SystemExit, 'Build inputs changed'):
            finish_receipt(self.output, {**self.inputs, 'extra': 'changed'})
        self.assertFalse((self.output / 'build-receipt.json').exists())

    def test_finish_rejects_symlinks_without_issuing_receipt(self):
        (self.framework / 'linked.h').symlink_to('ios-arm64/Headers/ghostty.h')
        with self.assertRaisesRegex(SystemExit, 'symlinks are unsupported'):
            finish_receipt(self.output, self.inputs)
        self.assertFalse((self.output / 'build-receipt.json').exists())


if __name__ == '__main__':
    unittest.main()
