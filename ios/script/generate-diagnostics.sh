#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate --spec project.yml
python3 script/diagnostics-manifest.py AwesoMuxDiagnostics/source-manifest.txt
