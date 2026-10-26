#!/bin/sh
# End-to-end: run the real installer inside a systemd-enabled container and
# let the REAL systemd start the units. No systemctl mocks.
set -e
echo "=== PID1 ==="
ps -p 1 -o comm= 2>/dev/null || cat /proc/1/comm
systemctl is-system-running 2>&1 | head -2 || true

apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl openssl unzip jq iproute2 procps systemd busybox python3-yaml >/dev/null 2>&1

workdir=/opt/deploy
mkdir -p $workdir
cp /work/install-xray.sh /work/xray-admin /work/rules.template.yaml \
   /work/xray-sub /work/xray-sub.service $workdir/

export SERVER_ADDRESS=203.0.113.10
export PUBLIC_PORT=34439
export LISTEN_PORT=18443
export REALITY_DEST=example.com:443
export REALITY_SERVER_NAME=example.com
export SUB_PUBLIC_PORT=34441
export SUB_LISTEN_PORT=18996

echo '=== install ==='
cd $workdir
bash ./install-xray.sh --install 2>&1 | tail -40

echo '=== units ==='
systemctl --no-pager status xray 2>&1 | head -12 || true
systemctl --no-pager status xray-sub 2>&1 | head -12 || true

echo '=== listeners ==='
ss -lntp 2>/dev/null | grep -E '18443|18996' || echo 'none'

echo '=== subscription fetch ==='
tok=$(tr -d '\r\n' </etc/xray-sub/token)
curl -s -D - -o /tmp/s.yaml --max-time 5 "http://127.0.0.1:18996/cgi-bin/$tok" | head -8 || true
grep -c 'MATCH,PROXY' /tmp/s.yaml 2>/dev/null || true
echo '=== done ==='
