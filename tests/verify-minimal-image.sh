#!/bin/sh
# Simulate a minimal image: only what a fresh Debian container has.
# Then confirm the one-click entry point installs what it needs and the units
# it renders pass real systemd verification.
set -e
echo "=== baseline: what a fresh image already has ==="
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends systemd >/dev/null 2>&1
for c in curl jq unzip busybox ss free; do
  if command -v "$c" >/dev/null; then echo "  $c: present"; else echo "  $c: MISSING (expected on minimal)"; fi
done

echo "=== install the same set the entrypoint installs ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  ca-certificates curl openssl unzip jq iproute2 procps busybox >/dev/null 2>&1

echo "=== re-check ==="
fail=0
for c in curl openssl unzip jq ss free busybox sha256sum; do
  if command -v "$c" >/dev/null; then echo "  $c: OK"; else echo "  $c: STILL MISSING"; fail=1; fi
done

echo "=== busybox path the unit will use ==="
bb=$(command -v busybox); echo "  $bb"

echo "=== render unit with that path and verify ==="
useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray-sub 2>/dev/null || true
mkdir -p /srv/sub
sed -e "s#__SUB_PORT__#2096#g" -e "s#__BUSYBOX__#$bb#g" \
  /work/xray-sub.service > /etc/systemd/system/xray-sub.service
out=$(systemd-analyze verify /etc/systemd/system/xray-sub.service 2>&1 || true)
if [ -n "$out" ]; then printf '%s\n' "$out"; echo 'FAIL: verify warnings'; exit 1; fi
echo '  unit verify OK'

if [ $fail -eq 0 ]; then echo 'MINIMAL-IMAGE CHECK PASSED'; else echo 'FAILED'; exit 1; fi
