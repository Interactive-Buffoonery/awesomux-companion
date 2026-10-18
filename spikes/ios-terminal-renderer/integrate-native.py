#!/usr/bin/env python3
"""Generate a local Swift package that uses the rebuilt native library."""

import argparse
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
sys.path.insert(0, str(root / "native"))
from framework_identity import framework_hashes

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("artifact", type=Path)
parser.add_argument("package_source", type=Path)
parser.add_argument("--output-directory", type=Path, default=root / "build")
parser.add_argument("--validate-only", action="store_true")
args = parser.parse_args()
artifact = args.artifact.resolve()
package_source = args.package_source.resolve()
output = args.output_directory.resolve()
revision = "42bacd1339f323a693ddbca779295f4f77e5a697"
if not (artifact / "Info.plist").is_file():
    raise SystemExit("Pass the finished GhosttyKit.xcframework and pinned package checkout")
receipt_path = artifact.parent / "build-receipt.json"
if not receipt_path.is_file():
    raise SystemExit("Native artifact is missing its build-receipt.json; rebuild it first")
provenance = json.loads(receipt_path.read_text())
if provenance.get("schemaVersion") != 2:
    raise SystemExit("Native schema 2 receipt required; rebuild from source without upgrading old receipts")
if not provenance.get("frameworkHashes") or framework_hashes(artifact) != provenance["frameworkHashes"]:
    raise SystemExit("Complete XCFramework file set or hashes do not match their build receipt")
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
snapshot = json.loads((artifact.parent / "build-inputs.json").read_text())
if snapshot != {k: v for k, v in provenance.items() if k not in {"archiveHashes", "frameworkHashes"}}:
    raise SystemExit("Native receipt does not match its pre-build input snapshot")
if not provenance["sourceHashes"]:
    raise SystemExit("Unsupported or empty native build receipt")
recipe = provenance["recipe"]
recipe_path = root / "native" / Path(recipe["path"]).name
if recipe_path.name not in {"build.sh", "rebuild-reviewed.sh"}:
    raise SystemExit("Unsupported native build recipe")
for path, expected in [
    (recipe_path, recipe["sha256"]),
    (root / "native/build-receipt.py", recipe["receiptScriptSHA256"]),
    (root / "native/framework_identity.py", recipe["frameworkIdentityScriptSHA256"]),
    (package_source / "Script/build-ghostty.sh", recipe["driverSHA256"]),
    (Path(provenance["compiler"]["path"]), provenance["compiler"]["sha256"]),
]:
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Native build input no longer matches receipt: {path}")
patches = {str(p.relative_to(package_source)): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in sorted((package_source / "Patches/ghostty").glob("*")) if p.is_file()}
if patches != recipe["orderedPatchHashes"] or not patches:
    raise SystemExit("Ordered native patch stack no longer matches receipt")
if (recipe["targets"] != ["aarch64-ios", "aarch64-ios-simulator"]
        or recipe["simulatorCPU"] != "apple_a17"
        or provenance["compiler"]["version"] != "0.16.0"):
    raise SystemExit("Native compiler or targets differ from supported build")
source_directory = Path(provenance["sourceDirectory"])
for relative, expected in provenance["sourceHashes"].items():
    source = source_directory / relative
    if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Native source no longer matches its build receipt: {relative}")
subprocess.run([sys.executable, str(root / "native/verify-artifacts.py"), str(artifact)], check=True)
archive = subprocess.check_output(["git", "-C", str(package_source), "archive", revision])
digest = hashlib.sha256(archive + receipt_path.read_bytes()).hexdigest()[:16]
destination = output / f"LocalGhostty-{digest}"
expected_files = {}
expected_symlinks = {}
with tarfile.open(fileobj=io.BytesIO(archive)) as source:
    for member in source.getmembers():
        if member.isfile():
            expected_files[member.name] = source.extractfile(member).read()
        elif member.issym():
            expected_symlinks[member.name] = member.linkname
manifest_text, count = re.subn(
    r'url: "https://github.com/Lakr233/libghostty-spm/releases/download/[^"\n]+",\s*checksum: "[a-f0-9]+"',
    lambda _: 'path: "GhosttyKit.xcframework"',
    expected_files["Package.swift"].decode(),
)
if count != 1:
    raise SystemExit("Expected exactly one downloaded binary target")
expected_files["Package.swift"] = manifest_text.encode()
framework_files = {str(p.relative_to(artifact)): p for p in artifact.rglob("*") if p.is_file()}
if not destination.exists() and not args.validate_only:
    destination.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(destination, filter="data")
    (destination / "Package.swift").write_bytes(expected_files["Package.swift"])
    shutil.copytree(artifact, destination / "GhosttyKit.xcframework")
for relative, expected in expected_files.items():
    staged = destination / relative
    if staged.is_symlink() or not staged.is_file() or staged.read_bytes() != expected:
        raise SystemExit(f"Local package differs from pinned wrapper: {relative}")
for relative, target in expected_symlinks.items():
    staged = destination / relative
    if not staged.is_symlink() or str(staged.readlink()) != target:
        raise SystemExit(f"Local package symlink differs from pinned wrapper: {relative}")
if framework_hashes(destination / "GhosttyKit.xcframework") != provenance["frameworkHashes"]:
    raise SystemExit("Local XCFramework file set or hashes differ from native build receipt")
expected_paths = set(expected_files) | set(expected_symlinks) | {"GhosttyKit.xcframework/" + p for p in framework_files}
actual_paths = {str(p.relative_to(destination)) for p in destination.rglob("*")
                if (p.is_file() or p.is_symlink()) and p.relative_to(destination).parts[0] != ".build"}
if actual_paths != expected_paths:
    raise SystemExit("Unexpected files in local native package")
receipt = {
    "packageRevision": revision,
    "renderer": "GhosttyPublicMetalLayer / CAMetalLayer",
    "patchSHA256": provenance["patchSHA256"],
    "archives": archive_hashes,
    "provenance": provenance,
}
receipt_destination = (root / "IOSRendererSpike/native-build.json" if output == root / "build"
                       else output / "native-build.json")
receipt_bytes = json.dumps(receipt, indent=2) + "\n"
if args.validate_only:
    if receipt_destination.read_text() != receipt_bytes:
        raise SystemExit("Integrated native receipt differs from build provenance")
    if (output / "local-package-path.txt").read_text().strip() != str(destination):
        raise SystemExit("Local package pointer differs from validated native build")
else:
    receipt_destination.write_text(receipt_bytes)
    (output / "local-package-path.txt").write_text(str(destination) + "\n")
    (output / "native-input-paths.json").write_text(json.dumps({
        "artifact": str(artifact), "packageSource": str(package_source),
    }, indent=2) + "\n")
print(destination)
