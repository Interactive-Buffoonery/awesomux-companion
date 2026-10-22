#!/usr/bin/env python3
"""Validate the public renderer and bundle its unchanged build receipt."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'script/validate-diagnostics-native.py'),
                '--project', 'AwesoMuxCompanion'], check=True)
destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
receipt = root / 'build/diagnostics-native/native-build.json'
shutil.copyfile(receipt, destination / 'native-build.json')
paths = [root / 'project.yml', receipt]
for directory in ['AwesoMuxCompanion', 'Shared', 'script']:
    paths.extend(path for path in (root / directory).rglob('*')
                 if path.is_file() and path.suffix in {'.swift', '.py', '.sh'})
(destination / 'watch-source-manifest.txt').write_text(''.join(
    f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(root)}\n'
    for path in sorted(set(paths))))
