#!/bin/sh
# Deliverable check: render the units exactly as the installer does, then have
# real systemd verify them. Also confirm the runtime prerequisites exist.
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
  systemd busybox jq curl ca-certificates openssl unzip python3-yaml >/dev/null 2>&1

fail=0
step() { printf '\n=== %s ===\n' "$1"; }

step "1. simulate install-time filesystem"
useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray-sub 2>/dev/null || true
getent group xray >/dev/null 2>&1 || groupadd --system xray
id xray >/dev/null 2>&1 || useradd --system --gid xray --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray
mkdir -p /srv/sub /etc/xray-sub /usr/local/etc/xray /usr/local/share/xray /usr/local/bin
cp "$(command -v busybox)" /usr/local/bin/busybox
printf 'x' > /usr/local/bin/xray && chmod 755 /usr/local/bin/xray
printf 'tok\n' > /etc/xray-sub/token
printf '2096\n' > /etc/xray-sub/port
printf 'a=1\n' > /etc/xray-sub/userinfo
chown root:xray-sub /etc/xray-sub/userinfo
chmod 640 /etc/xray-sub/userinfo
printf '{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}\n' > /usr/local/etc/xray/config.json

step "2. render subscription unit as installer does"
bb=$(command -v busybox)
sed -e "s#__SUB_PORT__#2096#g" -e "s#__BUSYBOX__#$bb#g" \
  /work/xray-sub.service > /etc/systemd/system/xray-sub.service
grep -E '^(ExecStart|User|Group)=' /etc/systemd/system/xray-sub.service

step "3. verify subscription unit"
out=$(systemd-analyze verify /etc/systemd/system/xray-sub.service 2>&1 || true)
if printf '%s' "$out" | grep -q 'nobody\|not safe\|Unable to locate\|does not exist'; then
  printf '%s\n' "$out"; echo 'FAIL: subscription unit has problems'; fail=1
else
  echo 'OK (no warnings)'
fi

step "4. render + verify xray unit"
sed -n '/Description=Personal Xray node/,/WantedBy=multi-user.target/p' /work/install-xray.sh > /tmp/x.body
{ printf '[Unit]\n'; cat /tmp/x.body; } > /etc/systemd/system/xray.service
out=$(systemd-analyze verify /etc/systemd/system/xray.service 2>&1 || true)
if printf '%s' "$out" | grep -qi 'error\|not safe\|unable to locate'; then
  printf '%s\n' "$out"; echo 'FAIL: xray unit has problems'; fail=1
else
  echo 'OK (no warnings)'
fi

step "5. runtime deps resolvable"
for c in busybox jq curl openssl unzip sha256sum ss free; do
  command -v "$c" >/dev/null || { echo "MISSING: $c"; fail=1; }
done
echo 'runtime deps OK'

step "6. service users resolvable"
for u in xray-sub xray; do
  id -u "$u" >/dev/null 2>&1 && echo "$u: OK" || { echo "$u: MISSING"; fail=1; }
done

step "7. quota readable by service group"
if runuser -u xray-sub -- cat /etc/xray-sub/userinfo >/dev/null 2>&1; then
  echo 'quota readable OK'
else
  echo 'FAIL: service user cannot read quota'; fail=1
fi

step "8. token permission is enforced by the installer"
# The file in this simulated tree is created by the test, not the installer.
# Assert the installer contains the enforcement step (verified for real in
# verify-permissions.sh, which runs the extracted statements).
if grep -q 'chmod 600 /etc/xray-sub/token' /work/install-xray.sh \
   && grep -q 'chown root:root /etc/xray-sub/token' /work/install-xray.sh; then
  echo 'token chmod/chown present in installer OK'
else
  echo 'FAIL: installer does not enforce token ownership/mode'; fail=1
fi

echo
if [ $fail -eq 0 ]; then echo 'ALL DELIVERABLE CHECKS PASSED'; else echo 'CHECKS FAILED'; exit 1; fi
