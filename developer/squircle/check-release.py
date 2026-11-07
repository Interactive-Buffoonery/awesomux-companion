#!/usr/bin/env python3
"""Inspect an actual normal Release app; this does not build, sign or launch it."""
import argparse
from pathlib import Path
import plistlib
import subprocess
from configuration import load

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--config', type=Path, required=True)
args = parser.parse_args()
config = load(args.config)
info = plistlib.loads((args.app / 'Info.plist').read_bytes())
executable = args.app / info['CFBundleExecutable']
links = subprocess.check_output(['otool', '-L', str(executable)])
assert b'Squircle' not in links, 'Release links the overlay'
assert 'AwesoMuxPersonalDebug' not in info, 'Release has a personal Debug marker'
assert not list(args.app.rglob('*Squircle*')), 'Release contains overlay resources'
assert not list(args.app.rglob('client.json')), 'Release contains an embedded connection file'
assert config['coordinator'].encode() not in executable.read_bytes(), 'Release contains the pinned developer chat'
print('PASS: Release artifact excludes overlay linkage, resources, connection file and developer chat')
