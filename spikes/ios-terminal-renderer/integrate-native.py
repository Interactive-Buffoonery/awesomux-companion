#!/usr/bin/env python3
"""Generate a local Swift package that uses the rebuilt native library."""

import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

root = Path(__file__).resolve().parent
artifact = Path(sys.argv[1]).resolve()
package_source = Path(sys.argv[2]).resolve()
revision = "42bacd1339f323a693ddbca779295f4f77e5a697"
if not (artifact / "Info.plist").is_file():
    raise SystemExit("Pass the finished GhosttyKit.xcframework and pinned package checkout")
receipt_path = artifact.parent / "build-receipt.json"
if not receipt_path.is_file():
    raise SystemExit("Native artifact is missing its build-receipt.json; rebuild it first")
provenance = json.loads(receipt_path.read_text())
patch_hash = hashlib.sha256((root / "native/0022-ios-public-metal-layer.patch").read_bytes()).hexdigest()
if provenance["packageRevision"] != revision or provenance["ghosttyRevision"] != "1e9e14af5df14211892f5fc15fd21a49c7d94868":
    raise SystemExit("Native build revisions do not match the pinned inputs")
if provenance["patchSHA256"] != patch_hash:
    raise SystemExit("Native artifact was built with a different renderer patch")
archive_hashes = {
    str(path.relative_to(artifact)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(artifact.glob("*/libghostty.a"))
}
if len(archive_hashes) != 2 or provenance["archiveHashes"] != archive_hashes:
    raise SystemExit("Native archive hashes do not match their build receipt")
source_directory = Path(provenance["sourceDirectory"])
for relative, expected in provenance["sourceHashes"].items():
    source = source_directory / relative
    if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Native source no longer matches its build receipt: {relative}")
subprocess.run([sys.executable, str(root / "native/verify-artifacts.py"), str(artifact)], check=True)
archive = subprocess.check_output(["git", "-C", str(package_source), "archive", revision])
digest = hashlib.sha256(archive + receipt_path.read_bytes()).hexdigest()[:16]
destination = root / "build" / f"LocalGhostty-{digest}"
destination.mkdir(parents=True, exist_ok=True)
with tarfile.open(fileobj=io.BytesIO(archive)) as source:
    source.extractall(destination, filter="data")
shutil.copytree(artifact, destination / "GhosttyKit.xcframework", dirs_exist_ok=True)
for relative, expected in archive_hashes.items():
    if hashlib.sha256((destination / "GhosttyKit.xcframework" / relative).read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Copied native archive differs from its build receipt: {relative}")
manifest = destination / "Package.swift"
text, count = re.subn(
    r'url: "https://github.com/Lakr233/libghostty-spm/releases/download/[^"\n]+",\s*checksum: "[a-f0-9]+"',
    lambda _: 'path: "GhosttyKit.xcframework"',
    manifest.read_text(),
)
if count != 1:
    raise SystemExit("Expected exactly one downloaded binary target")
manifest.write_text(text)
receipt = {
    "packageRevision": revision,
    "renderer": "GhosttyPublicMetalLayer / CAMetalLayer",
    "patchSHA256": provenance["patchSHA256"],
    "archives": archive_hashes,
    "provenance": provenance,
}
(root / "IOSRendererSpike/native-build.json").write_text(json.dumps(receipt, indent=2) + "\n")
(root / "build/local-package-path.txt").write_text(str(destination) + "\n")
print(destination)
