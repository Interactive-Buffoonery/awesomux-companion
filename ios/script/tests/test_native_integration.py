"""Synthetic build-association tests; no compilation or runtime acceptance."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import runpy
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
SPIKE = REPO / 'spikes/ios-terminal-renderer'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class NativeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifact = self.root / 'artifact/GhosttyKit.xcframework'
        self.package = self.root / 'package'
        self.output = self.root / 'integration'
        for relative in ['Info.plist', 'ios-arm64/libghostty.a', 'ios-arm64-simulator/libghostty.a',
                         'ios-arm64/Headers/ghostty.h', 'ios-arm64-simulator/Headers/ghostty.h']:
            path = self.artifact / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'CAMetalLayer presentDrawable:')
        driver = self.package / 'Script/build-ghostty.sh'
        driver.parent.mkdir(parents=True)
        driver.write_text('prepared driver')
        overlay = self.package / 'Patches/ghostty/0022-ios-public-metal-layer.patch'
        overlay.parent.mkdir(parents=True)
        overlay.write_bytes((SPIKE / 'native/0022-ios-public-metal-layer.patch').read_bytes())
        self.source = self.root / 'source.zig'
        self.source.write_text('source')
        compiler = self.root / 'zig'
        compiler.write_text('compiler')
        self.provenance = {
            'schemaVersion': 2,
            'packageRevision': '42bacd1339f323a693ddbca779295f4f77e5a697',
            'ghosttyRevision': '1e9e14af5df14211892f5fc15fd21a49c7d94868',
            'patchSHA256': digest(overlay),
            'sourceDirectory': str(self.root), 'sourceHashes': {'source.zig': digest(self.source)},
            'compiler': {'path': str(compiler), 'sha256': digest(compiler), 'version': '0.16.0'},
            'recipe': {
                'path': str(SPIKE / 'native/build.sh'), 'sha256': digest(SPIKE / 'native/build.sh'),
                'receiptScriptSHA256': digest(SPIKE / 'native/build-receipt.py'),
                'frameworkIdentityScriptSHA256': digest(SPIKE / 'native/framework_identity.py'),
                'driverSHA256': digest(driver),
                'orderedPatchHashes': {str(overlay.relative_to(self.package)): digest(overlay)},
                'targets': ['aarch64-ios', 'aarch64-ios-simulator'], 'simulatorCPU': 'apple_a17',
            },
            'archiveHashes': {str(p.relative_to(self.artifact)): digest(p)
                              for p in self.artifact.glob('*/libghostty.a')},
        }
        self.provenance['frameworkHashes'] = {
            str(p.relative_to(self.artifact)): digest(p) for p in self.artifact.rglob('*') if p.is_file()
        }
        self.write_receipt()
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w') as tar:
            for name, data in {
                'Package.swift': b'url: "https://github.com/Lakr233/libghostty-spm/releases/download/test/a.zip", checksum: "abcd"',
                'Sources/Wrapper.swift': b'wrapper',
                'AGENTS.md': b'pinned instructions',
            }.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(data)
                tar.addfile(entry, io.BytesIO(data))
            link = tarfile.TarInfo('CLAUDE.md')
            link.type = tarfile.SYMTYPE
            link.linkname = 'AGENTS.md'
            tar.addfile(link)
        self.archive = archive.getvalue()

    def write_receipt(self):
        (self.artifact.parent / 'build-receipt.json').write_text(json.dumps(self.provenance))
        (self.artifact.parent / 'build-inputs.json').write_text(json.dumps({
            k: v for k, v in self.provenance.items() if k not in {'archiveHashes', 'frameworkHashes'}}))

    def integrate(self, validate=False):
        args = ['integrate-native.py', str(self.artifact), str(self.package),
                '--output-directory', str(self.output)] + (['--validate-only'] if validate else [])
        def check_output(command, **kwargs):
            if command[0] == 'git':
                return self.archive
            if command[:2] == ['lipo', '-archs']:
                return 'arm64'
            self.fail(f'Unexpected command: {command}')
        def run(command, **kwargs):
            self.assertEqual(Path(command[1]), SPIKE / 'native/verify-artifacts.py')
            with patch.object(sys, 'argv', command[1:]):
                runpy.run_path(command[1], run_name='__main__')
        with patch.object(sys, 'argv', args), patch('subprocess.check_output', side_effect=check_output), \
                patch('subprocess.run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(SPIKE / 'integrate-native.py'), run_name='__main__')
        return Path((self.output / 'local-package-path.txt').read_text().strip())

    def test_integrate_and_revalidate_without_recopy(self):
        package = self.integrate()
        before = (package / 'GhosttyKit.xcframework/ios-arm64/libghostty.a').stat().st_mtime_ns
        self.integrate(validate=True)
        self.assertEqual(before, (package / 'GhosttyKit.xcframework/ios-arm64/libghostty.a').stat().st_mtime_ns)
        self.assertNotIn('https:', (package / 'Package.swift').read_text())
        self.assertEqual(json.loads((self.output / 'native-build.json').read_text())['provenance'], self.provenance)

    def test_reject_staged_tampering(self):
        for relative in ['Package.swift', 'Sources/Wrapper.swift', 'GhosttyKit.xcframework/Info.plist',
                         'GhosttyKit.xcframework/ios-arm64/libghostty.a']:
            with self.subTest(relative=relative):
                package = self.integrate()
                path = package / relative
                original = path.read_bytes()
                path.write_bytes(b'substitution')
                with self.assertRaises(SystemExit):
                    self.integrate(validate=True)
                path.write_bytes(original)

    def test_pinned_symlink_layout_and_tampering(self):
        package = self.integrate()
        link = package / 'CLAUDE.md'
        self.assertTrue(link.is_symlink())
        self.assertEqual(str(link.readlink()), 'AGENTS.md')
        self.integrate(validate=True)
        # Rename preserves the pinned link while testing replacement and extra entries.
        link.rename(package / 'saved-link')
        link.symlink_to('Sources/Wrapper.swift')
        with self.assertRaisesRegex(SystemExit, 'symlink differs'):
            self.integrate(validate=True)
        link.rename(package / 'wrong-link')
        (package / 'saved-link').rename(link)
        with self.assertRaisesRegex(SystemExit, 'Unexpected files'):
            self.integrate(validate=True)

    def test_reject_original_framework_mutation_before_initial_integration(self):
        for relative in ['Info.plist', 'ios-arm64/Headers/ghostty.h']:
            with self.subTest(relative=relative):
                path = self.artifact / relative
                original = path.read_bytes()
                path.write_bytes(b'tampered before integration')
                with self.assertRaisesRegex(SystemExit, 'XCFramework file set or hashes'):
                    self.integrate()
                path.write_bytes(original)
                path.rename(self.root / 'saved-file')
                with self.assertRaises(SystemExit):
                    self.integrate()
                (self.root / 'saved-file').rename(path)
        self.assertFalse(self.output.exists())

    def test_reject_added_header_or_metadata_before_initial_integration(self):
        for relative in ['ios-arm64/Headers/injected.h', 'extra-metadata.plist']:
            with self.subTest(relative=relative):
                path = self.artifact / relative
                path.write_text('injected')
                with self.assertRaisesRegex(SystemExit, 'XCFramework file set or hashes'):
                    self.integrate()
                path.rename(self.root / Path(relative).name)
        self.assertFalse(self.output.exists())

    def test_reject_framework_symlink_substitution(self):
        header = self.artifact / 'ios-arm64/Headers/ghostty.h'
        header.rename(self.root / 'saved-header')
        header.symlink_to(self.root / 'saved-header')
        with self.assertRaisesRegex(SystemExit, 'symlinks are unsupported'):
            self.integrate()

    def test_reject_added_header_in_staged_framework(self):
        package = self.integrate()
        (package / 'GhosttyKit.xcframework/ios-arm64/Headers/injected.h').write_text('injected')
        with self.assertRaisesRegex(SystemExit, 'Local XCFramework file set or hashes'):
            self.integrate(validate=True)

    def test_reject_legacy_receipt(self):
        self.provenance['schemaVersion'] = 1
        self.provenance.pop('frameworkHashes')
        self.write_receipt()
        with self.assertRaisesRegex(SystemExit, 'schema 2 receipt required'):
            self.integrate()

    def test_reject_missing_receipt(self):
        (self.artifact.parent / 'build-receipt.json').rename(self.root / 'saved-receipt.json')
        with self.assertRaisesRegex(SystemExit, 'missing its build-receipt'):
            self.integrate()

    def test_reject_changed_source(self):
        self.source.write_text('changed')
        with self.assertRaisesRegex(SystemExit, 'Native source'):
            self.integrate()

    def test_reject_archive_mismatch(self):
        (self.artifact / 'ios-arm64/libghostty.a').write_bytes(b'changed')
        with self.assertRaisesRegex(SystemExit, 'XCFramework file set or hashes'):
            self.integrate()

    def test_reject_wrong_pin_patch_recipe_and_snapshot(self):
        for key, value in [('packageRevision', 'wrong'), ('patchSHA256', 'wrong'),
                           ('schemaVersion', 1)]:
            with self.subTest(key=key):
                original = self.provenance[key]
                self.provenance[key] = value
                self.write_receipt()
                with self.assertRaises(SystemExit):
                    self.integrate()
                self.provenance[key] = original
        self.provenance['recipe']['sha256'] = 'wrong'
        self.write_receipt()
        with self.assertRaisesRegex(SystemExit, 'build input'):
            self.integrate()
        (self.artifact.parent / 'build-inputs.json').write_text('{}')
        with self.assertRaisesRegex(SystemExit, 'pre-build input snapshot'):
            self.integrate()

    def test_reject_private_presentation_even_with_matching_receipt(self):
        archive = self.artifact / 'ios-arm64/libghostty.a'
        archive.write_bytes(b'CAIOSurfaceLayer')
        self.provenance['archiveHashes']['ios-arm64/libghostty.a'] = digest(archive)
        self.provenance['frameworkHashes']['ios-arm64/libghostty.a'] = digest(archive)
        self.write_receipt()
        with self.assertRaisesRegex(SystemExit, 'Private presentation class'):
            self.integrate()


if __name__ == '__main__':
    unittest.main()
