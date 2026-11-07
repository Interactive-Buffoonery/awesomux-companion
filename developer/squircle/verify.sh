#!/bin/zsh
set -uo pipefail
cd "${0:A:h}/../.."
prepared="${1:A}"
failed=0
check() {
  if "$@"; then
    :
  else
    failed=1
  fi
}
check python3 -m unittest discover -s developer/squircle -p 'test_*.py'
check python3 developer/squircle/check-invariants.py "$prepared"
check python3 developer/squircle/check-sql.py "$prepared"
check python3 developer/squircle/check-service-policy.py "$prepared"
check python3 developer/squircle/check-dispatch.py "$prepared"
check python3 -m unittest discover -s ios/script/tests -p 'test_*.py'
check cargo test --locked --manifest-path "$prepared/Cargo.toml" --lib
check cargo build --locked --manifest-path "$prepared/Cargo.toml" --bin companion-inject
exit "$failed"
