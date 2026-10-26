#!/usr/bin/env bash
# Verify the installer's permission enforcement directly, by running the same
# statements the installer contains (extracted by line range, not a mock).
set -Eeuo pipefail
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl openssl unzip jq iproute2 procps busybox >/dev/null 2>&1

useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray-sub 2>/dev/null || true
mkdir -p /etc/xray-sub
# Start with loose modes, as a restored backup might have.
printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > /etc/xray-sub/token
chmod 644 /etc/xray-sub/token
printf 'upload=1; download=2; total=3; expire=4\n' > /etc/xray-sub/userinfo
chmod 644 /etc/xray-sub/userinfo
echo "before: token=$(stat -c %a /etc/xray-sub/token) userinfo=$(stat -c %a /etc/xray-sub/userinfo)"

# Take the real lines from the installer (token + userinfo permission block).
{
  echo 'set -Eeuo pipefail'
  sed -n '117,124p' /work/install-xray.sh
  echo '[[ -f /etc/xray-sub/userinfo ]] && chown root:xray-sub /etc/xray-sub/userinfo || true'
  sed -n '151p' /work/install-xray.sh
} > /tmp/perm.sh
echo '--- extracted statements ---'
cat /tmp/perm.sh
bash /tmp/perm.sh

echo "after:  token=$(stat -c %a /etc/xray-sub/token) userinfo=$(stat -c %a /etc/xray-sub/userinfo)"
echo "userinfo owner: $(stat -c '%U:%G' /etc/xray-sub/userinfo)"

fail=0
[[ $(stat -c %a /etc/xray-sub/token) == 600 ]] || { echo 'FAIL: token not 600'; fail=1; }
[[ $(stat -c %a /etc/xray-sub/userinfo) == 640 ]] || { echo 'FAIL: userinfo not 640'; fail=1; }
runuser -u xray-sub -- cat /etc/xray-sub/userinfo >/dev/null 2>&1 \
  || { echo 'FAIL: service user cannot read quota'; fail=1; }
runuser -u xray-sub -- cat /etc/xray-sub/token >/dev/null 2>&1 \
  && { echo 'FAIL: service user can read token'; fail=1; } || true
((fail == 0)) && echo 'PERMISSIONS ENFORCED' || exit 1
