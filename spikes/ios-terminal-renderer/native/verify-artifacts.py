import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
archives = sorted(root.glob("*/libghostty.a"))
if len(archives) != 2:
    raise SystemExit("Expected device and simulator archives")
results = []
for archive in archives:
    data = archive.read_bytes()
    if b"CAIOSurfaceLayer" in data:
        raise SystemExit(f"Private presentation class found: {archive}")
    if b"CAMetalLayer" not in data or b"presentDrawable:" not in data:
        raise SystemExit(f"Public drawable presentation missing: {archive}")
    arch = subprocess.check_output(["lipo", "-archs", str(archive)], text=True).strip()
    if arch != "arm64":
        raise SystemExit(f"Unexpected architectures: {arch}")
    results.append({"path": str(archive), "sha256": hashlib.sha256(data).hexdigest(),
                    "bytes": len(data), "architecture": arch,
                    "private_class_absent": True, "public_presentation_present": True})
print(json.dumps(results, indent=2))
