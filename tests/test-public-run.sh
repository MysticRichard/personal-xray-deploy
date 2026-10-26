#!/usr/bin/env bash
# Only execute in a disposable Debian test container.
set -Eeuo pipefail
[[ -f /DISPOSABLE_XRAY_TEST ]] || exit 1
root=$(cd "$(dirname "$0")/.." && pwd)
bash "$root/tests/test-one-click.sh"
# Simulate the public one-liner with the address/ports typed; REALITY target and
# serverName are accepted via Enter (documented defaults).
rm -f /root/xray-client/node.json /usr/local/etc/xray/client.json /usr/local/etc/xray/config.json
export PATH=/test-shims:$PATH
unset SERVER_ADDRESS PUBLIC_PORT LISTEN_PORT REALITY_DEST REALITY_SERVER_NAME SUB_PUBLIC_PORT SUB_LISTEN_PORT
printf '%s\n' \
  '203.0.113.10' \
  '28443' \
  '18443' \
  '' \
  '' \
  '28996' \
  '18996' > /run/answers.txt
bash <(cat "$root/one-click.sh") </run/answers.txt >/run/public.log 2>&1 || { cat /run/public.log; exit 1; }
[[ -s /root/xray-client/node.json ]]
jq -e '.proxies[0].port == 28443 and .proxies[0].server == "203.0.113.10"' /root/xray-client/node.json >/dev/null
grep -q 'www.apple.com' /usr/local/etc/xray/config.json
systemctl is-active --quiet xray
ss -lntH 'sport = :18443' | grep -q .
systemctl stop xray
echo 'PASS: piped public run accepts blank defaults for target and installs correctly'
