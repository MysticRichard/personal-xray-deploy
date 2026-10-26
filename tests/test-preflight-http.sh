#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/install-xray.sh"
fail=0

# The HTTP status probe must not be able to abort installation.
if grep -q "fail 'Target HTTP check failed.'" "$script"; then
  echo 'FAIL: HTTP timeout still fatal'
  fail=1
fi
if grep -q 'Target returned HTTP' "$script"; then
  echo 'FAIL: HTTP status still treated as fatal'
  fail=1
fi

# TLS1.3 + h2 plus certificate verification must remain mandatory.
grep -q "fail 'Target TLS/certificate check failed.'" "$script" || { echo 'FAIL: TLS check removed'; fail=1; }
grep -q 'verify_hostname' "$script" || { echo 'FAIL: hostname verification removed'; fail=1; }
grep -q 'verify_return_error' "$script" || { echo 'FAIL: cert error tolerance loosened'; fail=1; }
grep -q "fail 'Target did not negotiate TLS1.3 and h2.'" "$script" || { echo 'FAIL: TLS1.3/h2 gate removed'; fail=1; }

((fail == 0))
echo 'PASS: TLS1.3/h2/cert still enforced; HTTP status is informational only'
