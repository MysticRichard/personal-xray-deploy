#!/usr/bin/env bash
# End-to-end check inside a disposable container: install, then serve subscription.
set -Eeuo pipefail
[[ -f /DISPOSABLE_XRAY_TEST ]] || exit 1
root=$(cd "$(dirname "$0")/.." && pwd)
batch="$root/tests/test-one-click.sh"
bash "$batch"

SUB_PORT=19396
export SUB_LISTEN_PORT=$SUB_PORT SUB_PUBLIC_PORT=$SUB_PORT
# Re-run only the subscription half on the already-installed instance.
rm -rf /srv/sub /etc/xray-sub /etc/systemd/system/xray-sub.service
sed -n '/^setup_subscription()/,/^}/p' "$root/install-xray.sh" > /run/sub-fn.sh
cat >> /run/sub-fn.sh <<'SH'
SELF_DIR=__SELF__
SERVER_ADDRESS=203.0.113.10
SUB_LISTEN_PORT=__PORT__
SUB_PUBLIC_PORT=__PORT__
fail() { echo "ERROR: $*" >&2; exit 1; }
setup_subscription
SH
sed -i "s#__SELF__#$root#; s#__PORT__#$SUB_PORT#" /run/sub-fn.sh
bash /run/sub-fn.sh > /run/sub.log 2>&1 || { cat /run/sub.log; exit 1; }

token=$(tr -d '\r\n' </etc/xray-sub/token)
url="http://127.0.0.1:${SUB_PORT}/${token}/config.yaml"
code=$(curl -s -o /run/sub.yaml -w '%{http_code}' --max-time 5 "$url")
[[ $code == 200 ]] || { echo "FAIL: subscription HTTP $code"; cat /run/sub.log; exit 1; }
python3 - /run/sub.yaml <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d['proxies'][0]['type'] == 'vless'
assert d['proxies'][0]['port'] == 34439, 'must publish the public port'
assert d['rules'][-1] == 'MATCH,PROXY'
assert len(d['rules']) > 10, 'rules template did not land'
assert 'private' not in str(d).lower(), 'server secret leaked'
PY
# Directory listing must not be exposed.
[[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${SUB_PORT}/${token}/") == 404 ]] \
  || { echo 'FAIL: directory listing exposed'; exit 1; }
# Editing rules and regenerating must be reflected without restarting.
printf '%s\n' '- DOMAIN-SUFFIX,edited.example,PROXY' '- MATCH,PROXY' >> /etc/xray-sub/rules.yaml
/usr/local/sbin/xray-sub >/dev/null
curl -s --max-time 5 "$url" | grep -q 'edited.example' || { echo 'FAIL: rule edit not applied'; exit 1; }
# Malformed rules must fail and leave the served file untouched.
before=$(sha256sum /srv/sub/$token/config.yaml)
printf '%s\n' 'garbage line' >> /etc/xray-sub/rules.yaml
if /usr/local/sbin/xray-sub >/dev/null 2>&1; then echo 'FAIL: bad rules accepted'; exit 1; fi
[[ $(sha256sum /srv/sub/$token/config.yaml) == "$before" ]] || { echo 'FAIL: bad rules overwrote subscription'; exit 1; }
systemctl stop xray-sub 2>/dev/null || true
systemctl stop xray 2>/dev/null || true
echo 'PASS: subscription served over HTTP, rules editable and regenerable, no leak or listing'
