"""Hash the complete regular-file set emitted by the native XCFramework build."""
import hashlib
from pathlib import Path


def framework_hashes(directory):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise SystemExit('Expected a regular XCFramework directory')
    hashes = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink():
            raise SystemExit(f'XCFramework symlinks are unsupported: {path}')
        if path.is_dir():
            continue
        if not path.is_file():
            raise SystemExit(f'Unsupported XCFramework entry: {path}')
        hashes[str(path.relative_to(directory))] = hashlib.sha256(path.read_bytes()).hexdigest()
    if 'Info.plist' not in hashes:
        raise SystemExit('XCFramework is missing its Info.plist')
    return hashes
