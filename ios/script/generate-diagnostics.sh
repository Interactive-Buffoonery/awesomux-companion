#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export GHOSTTY_LOCAL_PACKAGE="$(python3 script/validate-diagnostics-native.py)"
xcodegen generate --spec project-diagnostics.yml
python3 script/diagnostics-manifest.py AwesoMuxDiagnostics/source-manifest.txt
