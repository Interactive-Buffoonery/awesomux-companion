#!/usr/bin/env python3
"""Seed and enforce the diagnostic app's tracked transitive dependency pins."""
import argparse
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
TRACKED = ROOT.parent / 'spikes/ios-terminal-renderer/Package.resolved'
RESOLVED = ROOT / 'AwesoMuxDiagnostics.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'


def pins(path):
    lock = json.loads(path.read_text())
    entries = lock['pins']
    if lock['version'] != 3 or not entries:
        raise SystemExit('Unsupported or empty diagnostic dependency lock')
    identities = [entry['identity'] for entry in entries]
    if len(set(identities)) != len(identities):
        raise SystemExit('Duplicate diagnostic dependency pins')
    return sorted(entries, key=lambda entry: entry['identity'])


def validate_lock(tracked=TRACKED, resolved=RESOLVED, allow_missing=False):
    expected = pins(tracked)
    if not resolved.is_file():
        if allow_missing:
            return
        raise SystemExit('Missing diagnostic Package.resolved; regenerate diagnostics before building')
    # originHash describes the project graph; every dependency field must match.
    if pins(resolved) != expected:
        raise SystemExit('Diagnostic dependency pins differ from the tracked renderer lock')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--seed', action='store_true')
    mode.add_argument('--allow-missing', action='store_true')
    args = parser.parse_args()
    if args.seed:
        pins(TRACKED)
        RESOLVED.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(TRACKED, RESOLVED)
    validate_lock(allow_missing=args.allow_missing)


if __name__ == '__main__':
    main()
