#!/usr/bin/env bash
# Only execute in a disposable Debian test container.
set -Eeuo pipefail
[[ -f /DISPOSABLE_XRAY_TEST ]] || exit 1
root=$(cd "$(dirname "$0")/.." && pwd)
# Reuse shims and clean state from the one-click test.
bash "$root/tests/test-one-click.sh"
# Simulate: bash <(curl ...) — the script is executed from a pipe, not a file.
rm -f /root/xray-client/node.json
export PATH=/test-shims:$PATH
export NONINTERACTIVE=1
export SERVER_ADDRESS=203.0.113.10 PUBLIC_PORT=28443 LISTEN_PORT=18443
export REALITY_DEST=example.com:443 REALITY_SERVER_NAME=example.com
export SUB_PUBLIC_PORT=28996 SUB_LISTEN_PORT=18996
export PLAN_TOTAL=100GB PLAN_RESET_DAY=1 PLAN_EXPIRE=2027-10-26
bash <(cat "$root/one-click.sh") >/run/piped.log 2>&1 || { cat /run/piped.log; exit 1; }
[[ -s /root/xray-client/node.json ]]
systemctl is-active --quiet xray
grep -q 'XRAY_INSTALL_PAYLOAD' "$root/one-click.sh"
systemctl stop xray
echo 'PASS: runs when piped via process substitution (bash <(curl ...)), no sibling files needed'
