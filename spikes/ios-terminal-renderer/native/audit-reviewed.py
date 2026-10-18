"""Record reproducible source, patch reconstruction, and archive evidence."""
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent
out = root / 'artifacts/public-metal-verified'
source = root / 'work/ghostty'
files = ['src/renderer/Metal.zig', 'src/renderer/metal/Frame.zig',
         'src/renderer/metal/MetalLayer.zig']

def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs)

def hashes(paths):
    return ''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}\n'
                   for p in paths)

check = out / 'patch-reconstruction'
check.mkdir(exist_ok=False)
for relative, baseline in zip(files[:2], ['Metal.zig', 'Frame.zig']):
    dest = check / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / 'work/baseline' / baseline, dest)
patch = root / '0022-ios-public-metal-layer.patch'
run('git', 'apply', '--check', str(patch), cwd=check)
run('git', 'apply', str(patch), cwd=check)
for relative in files:
    assert (check / relative).read_bytes() == (source / relative).read_bytes(), relative
(out / 'patch-reconstruction.txt').write_text('PASS: overlay applies to saved pre-overlay baseline; all three renderer files match built source byte-for-byte.\n')
(out / 'source.sha256').write_text(hashes([source / p for p in files]))
(out / 'inputs.sha256').write_text(hashes([patch, root / 'toolchains/zig-aarch64-macos-0.16.0/zig', root / 'work/libghostty-spm/Script/build-ghostty.sh', root / 'rebuild-reviewed.sh', root / 'audit-reviewed.py']))
diff = run('git', 'diff', '--binary', cwd=source)
for relative in run('git', 'ls-files', '--others', '--exclude-standard', cwd=source).splitlines():
    p = source / relative
    if p.suffix == '.zig':
        diff += ''.join(difflib.unified_diff([], p.read_text().splitlines(True), fromfile='/dev/null', tofile='b/' + relative))
(out / 'complete-source.diff').write_text(diff)
source_files = run('git', 'ls-files', '-m', '--others', '--exclude-standard', cwd=source).splitlines()
(out / 'all-modified-source.sha256').write_text(hashes([source / p for p in sorted(set(source_files)) if (source / p).is_file()]))
shutil.copyfile(patch, out / patch.name)
(out / 'ordered-upstream-patches.sha256').write_text(hashes(sorted((root / 'work/libghostty-spm/Patches/ghostty').glob('*'))))
shutil.copyfile(root / 'work/upstream-patches.log', out / 'upstream-patches.log')
required = ['_ghostty_app_new', '_ghostty_surface_new', '_ghostty_surface_refresh', '_ghostty_surface_free']
exports = {}
for archive in sorted((out / 'GhosttyKit.xcframework').glob('*/libghostty.a')):
    symbols = set(line.split()[-1] for line in run('nm', '-gU', str(archive)).splitlines() if line.split())
    assert set(required) <= symbols, str(archive)
    exports[str(archive.relative_to(root))] = {'required_exported_symbols': required}
(out / 'export-audit.json').write_text(json.dumps(exports, indent=2) + '\n')
receipt = json.loads((out / 'build-receipt.json').read_text())
assert receipt['patchSHA256'] == hashlib.sha256(patch.read_bytes()).hexdigest()
for relative, expected in receipt['sourceHashes'].items():
    assert hashlib.sha256((source / relative).read_bytes()).hexdigest() == expected, relative
for relative, expected in receipt['archiveHashes'].items():
    assert hashlib.sha256((out / 'GhosttyKit.xcframework' / relative).read_bytes()).hexdigest() == expected, relative
(out / 'provenance.txt').write_text(
    'package=' + receipt['packageRevision'] + '\n'
    'ghostty=' + receipt['ghosttyRevision'] + '\n'
    'zig=' + receipt['compiler']['version'] + '\n'
    'source=' + receipt['sourceDirectory'] + '\n'
    'execution=rebuild-reviewed.sh: both native slices, packaging, binary audit, input stability check, build-receipt.json\n'
    'overlay_sha256=' + receipt['patchSHA256'] + '\n')
print((out / 'inputs.sha256').read_text())

old_hashes = {
    'ios-arm64': 'fcba49bf385ee77a6c6400c26663476f41b8bcd25dba8f0a6d542ea58740c505',
    'ios-arm64-simulator': 'ded93c39be6df347d25befcfd96ef70c31b17726d3134de64addef5b9a16d0d9',
}
for slice_name, expected in old_hashes.items():
    old = root / 'artifacts/public-metal-final/GhosttyKit.xcframework' / slice_name / 'libghostty.a'
    assert hashlib.sha256(old.read_bytes()).hexdigest() == expected, slice_name
(out / 'previous-artifact-preserved.txt').write_text('PASS: both public-metal-final archives retain their original SHA-256 hashes.\n')

reviewed_hashes = {
    'ios-arm64': 'ce82677c4ae8ec5148d1a0304dab4cc531d06df5e55c4027384fb7a0a108e285',
    'ios-arm64-simulator': '89b4cc987d179e20a0ada85d4c6148ca4aa7d97cc9a54b7669a752ddb46f41be',
}
for slice_name, expected in reviewed_hashes.items():
    old = root / 'artifacts/public-metal-reviewed/GhosttyKit.xcframework' / slice_name / 'libghostty.a'
    assert hashlib.sha256(old.read_bytes()).hexdigest() == expected, slice_name
with (out / 'previous-artifact-preserved.txt').open('a') as stream:
    stream.write('PASS: both public-metal-reviewed archives retain their original SHA-256 hashes.\n')
