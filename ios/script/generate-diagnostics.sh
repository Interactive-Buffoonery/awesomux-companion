#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
GHOSTTY_LOCAL_PACKAGE="$(python3 script/validate-diagnostics-native.py --allow-missing-lock)"
export GHOSTTY_LOCAL_PACKAGE
xcodegen generate --spec project-diagnostics.yml
python3 script/diagnostics-lock.py --seed
python3 script/diagnostics-manifest.py AwesoMuxDiagnostics/source-manifest.txt
