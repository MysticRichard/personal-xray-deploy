#!/usr/bin/env bash
# Only execute in a disposable Debian test container.
set -Eeuo pipefail
[[ -f /DISPOSABLE_XRAY_TEST ]] || exit 1
root=$(cd "$(dirname "$0")/.." && pwd)
[[ -f "$root/one-click.sh" ]] || { echo 'FAIL: single-file entrypoint missing'; exit 1; }
# Reuse installation checks and shims; then install using ONLY a standalone copy.
bash "$root/tests/test-install.sh"
mkdir -p /isolated-one-click
cp "$root/one-click.sh" /isolated-one-click/install.sh
rm -f /root/xray-client/node.json
export PATH=/test-shims:$PATH
export NONINTERACTIVE=1
export SERVER_ADDRESS=203.0.113.10 PUBLIC_PORT=28443 LISTEN_PORT=18443
export REALITY_DEST=example.com:443 REALITY_SERVER_NAME=example.com
export SUB_PUBLIC_PORT=28996 SUB_LISTEN_PORT=18996
export PLAN_TOTAL=100GB PLAN_RESET_DAY=1 PLAN_EXPIRE=2027-10-26
before=$(sha256sum /usr/local/etc/xray/client.json)
cd /isolated-one-click
bash install.sh >/run/one-click.log 2>&1 || { cat /run/one-click.log; exit 1; }
[[ $(sha256sum /usr/local/etc/xray/client.json) == "$before" ]]
[[ -s /root/xray-client/node.json ]]
jq -e '.proxies[0].port == 28443 and .proxies[0].type == "vless"' /root/xray-client/node.json >/dev/null
systemctl is-active --quiet xray
[[ $(stat -c %a /root/xray-client/node.json) == 600 ]]
printf '0\n' | bash /usr/local/sbin/xray-admin >/run/admin-menu.log
if find /tmp -maxdepth 1 -name 'xray-one-click.*' | grep -q .; then echo 'FAIL: temporary payload left behind'; exit 1; fi
systemctl stop xray
echo 'PASS: standalone one-file install, automatic export, persistent menu, key reuse and cleanup'
