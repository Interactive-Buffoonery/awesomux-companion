#!/usr/bin/env python3
"""Prepare a new pinned adapter without touching an existing checkout/service."""
import argparse
import json
from pathlib import Path
import subprocess
from configuration import load, render

PIN = "737f2e881483a4c7237b49d5696adff7d44cad1b"
ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--source", default="https://github.com/achimala/Squircle.git")
    args = parser.parse_args()
    config = load(args.config)
    if args.destination.exists() or args.destination.is_symlink():
        parser.error("destination must not exist; preserve existing checkouts")
    subprocess.run(["git", "clone", "--no-checkout", args.source, str(args.destination)], check=True)
    subprocess.run(["git", "-C", str(args.destination), "checkout", "--detach", PIN], check=True)
    patch = args.destination / "companion-integration.patch"
    patch.write_text(render((ROOT / "integration.patch").read_text(), config))
    subprocess.run(["git", "-C", str(args.destination), "apply", "--check", str(patch.resolve())], check=True)
    subprocess.run(["git", "-C", str(args.destination), "apply", str(patch.resolve())], check=True)
    enrollment = render((ROOT / "DeveloperEnrollment.swift").read_text(), config)
    (args.destination / "app/Squircle/Sources/DeveloperEnrollment.swift").write_text(enrollment)
    (args.destination / "companion-enrollment.swift").write_text(enrollment)
    (args.destination / "companion-config.json").write_text(json.dumps(config, sort_keys=True))
    binary = args.destination / "src/bin/companion-inject.rs"
    binary.parent.mkdir(exist_ok=True)
    binary.write_bytes((ROOT / "companion-inject.rs").read_bytes())
    print("Prepared Companion adapter. No service, provider, signing or network changes.")


if __name__ == "__main__":
    main()
