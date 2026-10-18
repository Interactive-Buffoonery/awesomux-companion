#!/usr/bin/env python3
"""Revalidate the local public renderer before generation and every app build."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--allow-missing-lock', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
subprocess.run([
    sys.executable, str(root / 'script/diagnostics-lock.py'),
    *(['--allow-missing'] if args.allow_missing_lock else []),
], check=True)
output = root / 'build/diagnostics-native'
inputs = output / 'native-input-paths.json'
if not inputs.is_file():
    raise SystemExit('Missing local native integration. See spikes/snapshot-reconnect/ios-diagnostics.md')
paths = json.loads(inputs.read_text())
subprocess.run([
    sys.executable, str(root.parent / 'spikes/ios-terminal-renderer/integrate-native.py'),
    paths['artifact'], paths['packageSource'], '--output-directory', str(output), '--validate-only',
], check=True, stdout=subprocess.DEVNULL)
package = (output / 'local-package-path.txt').read_text().strip()
expected = os.environ.get('DIAGNOSTICS_NATIVE_PACKAGE')
if expected and Path(expected).resolve() != Path(package):
    raise SystemExit('Generated project has a different native package; regenerate diagnostics')
print(package)
