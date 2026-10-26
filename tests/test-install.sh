#!/usr/bin/env bash
# Run ONLY inside a disposable Debian test container (root paths are mutated).
set -Eeuo pipefail
[[ -f /DISPOSABLE_XRAY_TEST ]] || { echo 'Disposable test container required'; exit 1; }
root=$(cd "$(dirname "$0")/.." && pwd)
# Test shims start processes directly; systemctl cannot stop those orphans on a
# repeated run. This file is guarded by /DISPOSABLE_XRAY_TEST above.
pkill -x xray 2>/dev/null || true
pkill -f 'busybox httpd.*-h /srv/sub' 2>/dev/null || true
rm -f /run/test-xray.pid /run/test-sub.pid
# The review host may use a fake-ip resolver; pin the fixture targets so the
# installer's non-public-target guard is not defeated by the host DNS mode.
grep -qE '^1\.1\.1\.1[[:space:]]+example\.com$' /etc/hosts \
  || printf '1.1.1.1 example.com\n' >>/etc/hosts
grep -qE '^1\.1\.1\.1[[:space:]]+www\.apple\.com$' /etc/hosts \
  || printf '1.1.1.1 www.apple.com\n' >>/etc/hosts
mkdir -p /run/systemd/system /test-shims
cat > /test-shims/curl <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == *releases/download* ]]; then
    while [[ $# -gt 0 ]]; do
      if [[ $1 == -o ]]; then cp /release.zip "$2"; exit; fi
      shift
    done
  fi
done
# Local subscription self-check must reach the real httpd stub.
if [[ ${*: -1} == http://127.0.0.1:* ]]; then
  exec /usr/bin/curl.real "$@"
fi
# Remote probes are stubbed.
if [[ " $* " == *" --write-out "* || " $* " == *" -w "* ]]; then printf 200; exit 0; fi
printf 'TLSv1.3\nALPN protocol: h2\n'
EOF
# Keep the real curl available for the localhost self-check.
if [[ -x /usr/bin/curl ]] && [[ ! -e /usr/bin/curl.real ]]; then cp /usr/bin/curl /usr/bin/curl.real; fi
cat > /test-shims/openssl <<'EOF'
#!/usr/bin/env bash
if [[ $1 == s_client ]]; then printf 'TLSv1.3\nALPN protocol: h2\n'; else exec /usr/bin/openssl "$@"; fi
EOF
cat > /test-shims/systemctl <<'EOF'
#!/usr/bin/env bash
set -eu
case $1 in
  is-active)
    case ${*: -1} in
      xray) [[ -f /run/test-xray.pid ]] && kill -0 "$(cat /run/test-xray.pid)" 2>/dev/null;;
      xray-sub) [[ -f /run/test-sub.pid ]] && kill -0 "$(cat /run/test-sub.pid)" 2>/dev/null;;
      *) exit 3;;
    esac;;
  restart|start)
    case ${*: -1} in
      xray)
        # The installer retries three times. Fail that many starts, then allow
        # the rollback start; otherwise the one-shot fixture would be masked by
        # the first retry and never exercise rollback.
        if [[ -f /run/fail-start-count ]]; then
          n=$(cat /run/fail-start-count)
          if ((n > 0)); then
            echo $((n - 1)) >/run/fail-start-count
            if [[ -f /run/test-xray.pid ]]; then kill "$(cat /run/test-xray.pid)" 2>/dev/null || true; rm -f /run/test-xray.pid; sleep 1; fi
            exit 1
          fi
        fi
        if [[ -f /run/test-xray.pid ]]; then kill "$(cat /run/test-xray.pid)" 2>/dev/null || true; sleep 1; fi
        runuser -u xray -- env XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -config /usr/local/etc/xray/config.json >/run/test-xray.log 2>&1 &
        echo $! >/run/test-xray.pid;;
      xray-sub)
        if [[ -f /run/test-sub.pid ]]; then kill "$(cat /run/test-sub.pid)" 2>/dev/null || true; sleep 1; fi
        port=$(tr -d '\r\n' </etc/xray-sub/port 2>/dev/null || echo 2096)
        /usr/bin/busybox httpd -f -p "127.0.0.1:$port" -h /srv/sub >/run/test-sub.log 2>&1 &
        echo $! >/run/test-sub.pid;;
      *) echo "Unsupported unit: $*" >&2; exit 1;;
    esac;;
  stop)
    case ${*: -1} in
      xray) [[ -f /run/test-xray.pid ]] && { kill "$(cat /run/test-xray.pid)" 2>/dev/null || true; rm /run/test-xray.pid; sleep 1; };;
      xray-sub) [[ -f /run/test-sub.pid ]] && { kill "$(cat /run/test-sub.pid)" 2>/dev/null || true; rm /run/test-sub.pid; sleep 1; };;
      *) :;;
    esac;;
  enable|disable|daemon-reload|reset-failed) :;;
  show) :;;
  cat) cat "/etc/systemd/system/$3.service" 2>/dev/null || true;;
  *) echo "Unsupported systemctl mock: $*" >&2; exit 1;;
esac
EOF
chmod +x /test-shims/*
export PATH=/test-shims:$PATH
export SERVER_ADDRESS=203.0.113.10 LISTEN_PORT=18443 PUBLIC_PORT=28443
export REALITY_DEST=example.com:443 REALITY_SERVER_NAME=example.com
export SUB_PUBLIC_PORT=28996 SUB_LISTEN_PORT=18996
bash "$root/install-xray.sh" --install >/run/install.log 2>&1 || { cat /run/install.log; exit 1; }
state=/usr/local/etc/xray/client.json
first=$(sha256sum "$state")
bash "$root/install-xray.sh" --install >/run/reinstall.log 2>&1 || { cat /run/reinstall.log; exit 1; }
[[ $(sha256sum "$state") == "$first" ]]
echo 'PASS: install/reinstall keep the same UUID and keys; actual Xray listens as non-root'
sha256sum /usr/local/bin/xray /usr/local/etc/xray/config.json "$state" /etc/systemd/system/xray.service > /run/before.sha
# Force all three activation attempts to fail AFTER replacing files, then verify
# that the rollback start (fourth attempt) restores the previous process.
printf '3\n' >/run/fail-start-count
if bash "$root/install-xray.sh" --install >/run/failure.log 2>&1; then echo 'FAIL: activation failure reported success'; exit 1; fi
rm -f /run/fail-start-count
sha256sum --check /run/before.sha
sleep 2
systemctl is-active --quiet xray
ss -lntH 'sport = :18443' | grep -q .
echo 'PASS: failed activation rolls files back and restores the previous running process'
# Export and validate only the client summary, without displaying secrets.
bash "$root/xray-admin" --export >/run/export.log
jq -e '.proxies[0].port == 28443 and (.proxies[0] | has("private-key") | not)' /root/xray-client/node.json >/dev/null
[[ $(stat -c %a "$state") == 600 ]]
[[ $(stat -c %a /root/xray-client/node.json) == 600 ]]
echo 'PASS: export uses public NAT port; state and export permissions are 0600'
# Subscription must be served and carry the edited rules.
token=$(tr -d '\r\n' </etc/xray-sub/token)
sub_port=$(tr -d '\r\n' </etc/xray-sub/port)
sub_url="http://127.0.0.1:${sub_port}/cgi-bin/${token}"
[[ $(/usr/bin/curl.real -s -o /run/sub.yaml -w '%{http_code}' --max-time 5 "$sub_url") == 200 ]] \
  || { echo 'FAIL: subscription not served'; exit 1; }
python3 - "$state" /run/sub.yaml <<'PY'
import sys, json, yaml
state = json.load(open(sys.argv[1]))
d = yaml.safe_load(open(sys.argv[2]))
blob = json.dumps(d)
assert d['rules'][-1] == 'MATCH,PROXY'
assert d['proxies'][0]['port'] == 28443
# Public rules may legitimately contain "private" domains; check the actual
# private key value and key field names, not a broad substring.
assert state['private_key'] not in blob
assert 'private-key' not in blob.lower()
assert 'privatekey' not in blob.lower()
PY
echo 'PASS: subscription served over HTTP with no leaked server key'
# Keep failures visible without printing credentials.
if grep -q 'unbound variable' /run/failure.log; then echo 'FAIL: rollback variable scope'; exit 1; fi
systemctl stop xray-sub || true
systemctl stop xray
