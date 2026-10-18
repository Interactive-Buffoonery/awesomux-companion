#!/usr/bin/env python3
"""Validate native identity and write artifact provenance without XcodeGen."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'script/validate-diagnostics-native.py')],
               check=True, stdout=subprocess.DEVNULL)
spike = root.parent / 'spikes/ios-terminal-renderer'
native_receipt = root / 'build/diagnostics-native/native-build.json'
paths = {root / 'project.yml', root / 'project-diagnostics.yml', native_receipt}
paths.update((root / 'script').glob('*diagnostics*'))
paths.add(spike / 'integrate-native.py')
paths.add(spike / 'Package.resolved')
paths.update(path for path in (spike / 'native').iterdir()
             if path.is_file() and path.suffix in {'.py', '.sh', '.patch'})
paths.update(path for path in (spike / 'IOSRendererSpike/ThirdPartyNotices').iterdir()
             if path.is_file())
for directory in ['AwesoMuxCompanion', 'AwesoMuxDiagnostics', 'Shared']:
    paths.update(path for path in (root / directory).rglob('*')
                 if path.is_file() and path.suffix in {'.swift', '.bin', '.plist'})
paths.update(root.glob('**/xcshareddata/swiftpm/Package.resolved'))
# Keep the receipt (which embeds all native build inputs), but omit build products.
paths = {path for path in paths if path == native_receipt
         or 'build' not in path.relative_to(root.parent).parts}
manifest = ''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(root.parent)}\n'
                   for path in sorted(paths))
destination = Path(sys.argv[1]).resolve()
destination.parent.mkdir(parents=True, exist_ok=True)
# The source copy is informational. Build-time output also bundles the unchanged receipt.
if destination.parent != root / 'AwesoMuxDiagnostics':
    shutil.copyfile(native_receipt, destination.parent / 'native-build.json')
destination.write_text(manifest)
