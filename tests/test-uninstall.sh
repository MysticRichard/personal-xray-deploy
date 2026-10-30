#!/usr/bin/env bash
# Run only inside a disposable Debian container with an installed node.
set -Eeuo pipefail
if [[ ! -f /DISPOSABLE_XRAY_TEST ]]; then
  echo 'SKIP: disposable container marker missing'
  exit 0
fi
root=$(cd "$(dirname "$0")/.." && pwd)

if [[ ! -f /usr/local/etc/xray/client.json ]]; then
  echo 'SKIP: no installed node to uninstall'
  exit 0
fi

bash "$root/install-xray.sh" --uninstall >/run/uninstall.log 2>&1 || { cat /run/uninstall.log; exit 1; }
[[ ! -e /usr/local/etc/xray/config.json ]] || { echo 'FAIL: server config survived uninstall'; exit 1; }
[[ ! -e /usr/local/bin/xray ]] || { echo 'FAIL: binary survived uninstall'; exit 1; }
[[ ! -e /etc/systemd/system/xray.service ]] || { echo 'FAIL: unit survived uninstall'; exit 1; }
[[ ! -e /usr/local/sbin/xray-admin ]] || { echo 'FAIL: admin tool survived uninstall'; exit 1; }
[[ ! -e /usr/local/sbin/xray-installer ]] || { echo 'FAIL: installer copy survived uninstall'; exit 1; }
[[ -d /etc/xray-sub ]] || { echo 'FAIL: subscription state was not preserved'; exit 1; }
[[ -d /root/xray-backups ]] || { echo 'FAIL: backups were not preserved'; exit 1; }

echo 'PASS: uninstall removes services and config but keeps subscription state and backups'
