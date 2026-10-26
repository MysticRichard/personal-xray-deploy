#!/bin/sh
# Verify the units the installer actually generates, using real systemd.
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends systemd busybox jq curl ca-certificates openssl unzip >/dev/null 2>&1

# Simulate install-time state: user, dirs, binary.
useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray-sub 2>/dev/null || true
mkdir -p /srv/sub /etc/xray-sub /usr/local/etc/xray /usr/local/share/xray /usr/local/bin
cp "$(command -v busybox)" /usr/local/bin/busybox
printf 'tok\n' > /etc/xray-sub/token
printf '2096\n' > /etc/xray-sub/port
printf 'x\n' > /etc/xray-sub/userinfo
printf '%s\n' '{ "log": {"loglevel": "warning"}, "inbounds": [], "outbounds": [{"protocol":"freedom"}] }' > /usr/local/etc/xray/config.json

# Render the subscription unit exactly as the installer does.
sed -e "s#__SUB_PORT__#2096#g" -e "s#__BUSYBOX__#/usr/local/bin/busybox#g" \
  /work/xray-sub.service > /etc/systemd/system/xray-sub.service
echo "=== rendered xray-sub.service ==="
cat /etc/systemd/system/xray-sub.service
echo "=== verify xray-sub.service ==="
systemd-analyze verify /etc/systemd/system/xray-sub.service 2>&1 | head -20 || true

# Also verify the minimal fallback unit embedded in the installer.
sed -n '/Description=Personal Clash subscription (minimal)/,/WantedBy=multi-user.target/p' \
  /work/install-xray.sh > /tmp/fallback.body
{ printf '[Unit]\n'; cat /tmp/fallback.body; } > /etc/systemd/system/xray-sub-min.service
sed -i 's#\${busybox_bin}#/usr/local/bin/busybox#; s#\${sub_port}#2096#' /etc/systemd/system/xray-sub-min.service
echo "=== verify fallback unit ==="
systemd-analyze verify /etc/systemd/system/xray-sub-min.service 2>&1 | head -20 || true
echo "=== done ==="
