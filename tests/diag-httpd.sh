#!/bin/sh
# Diagnose busybox httpd startup in this container.
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends busybox >/dev/null 2>&1
echo "busybox: $(busybox | head -1)"
busybox --list | grep -c httpd
mkdir -p /srv/sub/tok
printf 'proxies: []\n' > /srv/sub/tok/config.yaml
chmod -R a+rX /srv/sub
echo "--- start foreground 3s ---"
timeout 3 busybox httpd -f -p 18099 -h /srv/sub 2>&1 | head -20
echo "--- exit code: $? ---"
