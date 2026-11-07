#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
prepared="$1"
python3 -m unittest discover -s developer/squircle -p 'test_*.py'
python3 developer/squircle/check-invariants.py "$prepared"
python3 developer/squircle/check-sql.py "$prepared"
python3 developer/squircle/check-service-policy.py "$prepared"
python3 -m unittest discover -s ios/script/tests -p 'test_*.py'
(cd "$prepared" && cargo test --locked --lib && cargo build --locked --bin companion-inject)
