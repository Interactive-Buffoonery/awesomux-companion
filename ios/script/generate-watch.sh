#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
GHOSTTY_LOCAL_PACKAGE="$(python3 script/validate-diagnostics-native.py --project AwesoMuxCompanion --allow-missing-lock)"
export GHOSTTY_LOCAL_PACKAGE
xcodegen generate --spec project.yml
python3 script/diagnostics-lock.py --project AwesoMuxCompanion --seed
