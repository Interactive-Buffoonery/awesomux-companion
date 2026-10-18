#!/usr/bin/env python3
"""Write artifact provenance without invoking project generation."""
import hashlib
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
paths = {root / 'project.yml', root / 'script/generate-diagnostics.sh',
         root / 'script/diagnostics-manifest.py'}
for directory in ['AwesoMuxCompanion', 'AwesoMuxDiagnostics', 'Shared']:
    paths.update(path for path in (root / directory).rglob('*')
                 if path.is_file() and path.suffix in {'.swift', '.bin', '.plist'})
paths.update(root.glob('**/xcshareddata/swiftpm/Package.resolved'))
paths = {path for path in paths if 'build' not in path.relative_to(root).parts}
manifest = ''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(root)}\n'
                   for path in sorted(paths))
destination = Path(sys.argv[1])
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(manifest)
