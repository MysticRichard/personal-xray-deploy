#!/usr/bin/env bash
# The subscription listener must bind 0.0.0.0 so a platform port-forward can
# reach it. Binding 127.0.0.1 makes every external request fail at the forwarder
# (FlClash shows 502) even though the service is healthy locally.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0

unit="$root/xray-sub.service"
inst="$root/install-xray.sh"

if grep -qE 'httpd -f -p 127\.0\.0\.1' "$unit"; then
  echo 'FAIL: subscription unit binds loopback only'; fail=1
fi
if grep -qE 'httpd -f -p 0\.0\.0\.0:__SUB_PORT__' "$unit"; then
  echo 'unit binds 0.0.0.0 OK'
else
  echo 'FAIL: unit does not bind 0.0.0.0'; fail=1
fi

# The generated fallback unit inside the installer must do the same.
if grep -qE 'httpd -f -p 127\.0\.0\.1:\$\{sub_port\}' "$inst"; then
  echo 'FAIL: fallback unit binds loopback only'; fail=1
fi
grep -qE 'httpd -f -p 0\.0\.0\.0:\$\{sub_port\}' "$inst" && echo 'fallback binds 0.0.0.0 OK' \
  || { echo 'FAIL: fallback does not bind 0.0.0.0'; fail=1; }

# The local self-check may still use loopback.
grep -q 'curl -fsS --max-time 5 "http://127.0.0.1:' "$inst" && echo 'self-check uses loopback OK' \
  || echo 'note: self-check address changed'

((fail == 0))
echo 'PASS: subscription binds all interfaces; local self-check unchanged'
