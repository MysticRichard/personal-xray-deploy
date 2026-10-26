#!/bin/sh
# Verify the Xray unit the installer writes actually passes real systemd checks
# in a nested-container-like environment (no mount namespace support).
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends systemd busybox >/dev/null 2>&1

getent group xray >/dev/null || groupadd --system xray
id xray >/dev/null 2>&1 || useradd --system --gid xray --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray
mkdir -p /usr/local/etc/xray /usr/local/share/xray /usr/local/bin
printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}\n' > /usr/local/etc/xray/config.json
cp "$(command -v busybox)" /usr/local/bin/xray

sed -n '/^echo .\[Unit\]$/,/^EOF$/p' /work/install-xray.sh | head -0 || true
sed -n '/Description=Personal Xray node/,/WantedBy=multi-user.target/p' /work/install-xray.sh > /tmp/xray.body
{ printf '[Unit]\n'; cat /tmp/xray.body; } > /etc/systemd/system/xray.service
echo '=== rendered xray.service ==='
cat /etc/systemd/system/xray.service
echo '=== verify ==='
systemd-analyze verify /etc/systemd/system/xray.service 2>&1 | head -20 || true
echo '=== done ==='
