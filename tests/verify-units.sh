#!/bin/sh
# Validate generated units with the real systemd unit verifier instead of a mock.
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends systemd busybox sudo >/dev/null 2>&1
echo "=== verifier available ==="
systemd-analyze --version | head -1

mkdir -p /etc/systemd/system
# Case 1: unit pointing at a missing binary and a missing user (what shipped before).
cat > /etc/systemd/system/bad.service <<'UNIT'
[Unit]
Description=bad
[Service]
ExecStart=/usr/bin/busybox httpd -f -p 127.0.0.1:2096 -h /srv/sub
User=nobody
[Install]
WantedBy=multi-user.target
UNIT
echo "=== case1: missing busybox + nobody ==="
systemd-analyze verify /etc/systemd/system/bad.service 2>&1 | head -12 || true

# Case 2: correct binary, dedicated user created.
useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray-sub 2>/dev/null || true
mkdir -p /srv/sub
cat > /etc/systemd/system/good.service <<UNIT
[Unit]
Description=good
[Service]
ExecStart=$(command -v busybox) httpd -f -p 127.0.0.1:2096 -h /srv/sub
User=xray-sub
Group=xray-sub
NoNewPrivileges=true
CapabilityBoundingSet=
[Install]
WantedBy=multi-user.target
UNIT
echo "=== case2: resolved binary + dedicated user ==="
systemd-analyze verify /etc/systemd/system/good.service 2>&1 | head -12 || true
echo "=== done ==="
