"""Bind a fresh native build to its inputs before compilation and verify after."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(source, package, recipe):
    zig = root / 'toolchains/zig-aarch64-macos-0.16.0/zig'
    paths = run('git', '-C', str(source), 'ls-files', '-z', '--cached',
                '--others', '--exclude-standard').split('\0')
    source_hashes = {p: digest(source / p) for p in sorted(set(paths))
                     if p and (source / p).is_file()}
    package_revision = run('git', '-C', str(package), 'rev-parse', 'HEAD')
    ghostty_revision = run('git', '-C', str(source), 'rev-parse', 'HEAD')
    assert package_revision == '42bacd1339f323a693ddbca779295f4f77e5a697'
    assert ghostty_revision == '1e9e14af5df14211892f5fc15fd21a49c7d94868'
    return {
        'schemaVersion': 1,
        'packageRevision': package_revision,
        'ghosttyRevision': ghostty_revision,
        'patchSHA256': digest(root / '0022-ios-public-metal-layer.patch'),
        'sourceDirectory': str(source),
        'sourceHashes': source_hashes,
        'compiler': {
            'path': str(zig), 'version': run(str(zig), 'version'),
            'sha256': digest(zig),
            'clang': run('xcrun', 'clang', '--version'),
            'xcode': run('xcodebuild', '-version'),
            'developerDirectory': run('xcode-select', '-p'),
        },
        'recipe': {
            'path': str(recipe), 'sha256': digest(recipe),
            'receiptScriptSHA256': digest(Path(__file__).resolve()),
            'driverPath': str(package / 'Script/build-ghostty.sh'),
            'driverSHA256': digest(package / 'Script/build-ghostty.sh'),
            'orderedPatchHashes': {
                str(p.relative_to(package)): digest(p)
                for p in sorted((package / 'Patches/ghostty').glob('*')) if p.is_file()
            },
            'targets': ['aarch64-ios', 'aarch64-ios-simulator'],
            'simulatorCPU': 'apple_a17',
        },
    }


mode, output_arg, source_arg, package_arg, recipe_arg = sys.argv[1:]
out, source, package, recipe = map(lambda p: Path(p).resolve(),
                                 [output_arg, source_arg, package_arg, recipe_arg])
snapshot = out / 'build-inputs.json'
receipt = out / 'build-receipt.json'
current = inputs(source, package, recipe)
if mode == 'begin':
    with snapshot.open('x') as stream:
        json.dump(current, stream, indent=2)
        stream.write('\n')
elif mode == 'finish':
    recorded = json.loads(snapshot.read_text())
    if recorded != current:
        raise SystemExit('Build inputs changed during compilation; refusing receipt')
    archives = sorted((out / 'GhosttyKit.xcframework').glob('*/libghostty.a'))
    if len(archives) != 2:
        raise SystemExit('Expected two XCFramework archives')
    recorded['archiveHashes'] = {
        str(p.relative_to(out / 'GhosttyKit.xcframework')): digest(p) for p in archives
    }
    with receipt.open('x') as stream:
        json.dump(recorded, stream, indent=2)
        stream.write('\n')
else:
    raise SystemExit('Expected begin or finish')
