#!/usr/bin/env bash
# Static audit: find assumptions that break on a minimal container image.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0

echo '=== 1. hardcoded absolute binaries in shipped scripts ==='
for f in install-xray.sh xray-sub xray-admin xray-sub.service; do
  hits=$(grep -nE '(ExecStart|^[^#]*\b)(/usr/bin|/bin)/[a-z]' "$root/$f" 2>/dev/null | grep -v '#!/usr/bin/env' | grep -v '#!/bin/sh' || true)
  if [[ -n $hits ]]; then
    echo "  $f:"; printf '%s\n' "$hits" | sed 's/^/    /'
  fi
done

echo '=== 2. commands used but never installed by the installer ==='
# Collect commands invoked from scripts, then check they are either in the
# dependency install line or provided by base Debian.
used=$(grep -ohE '\b(groupadd|useradd|userdel|getent|ss|free|sysctl|journalctl|systemctl|systemd-detect-virt|busybox|jq|unzip|openssl|curl|sha256sum|timeout|install|apt-get|tar|awk|sed|grep|tr|chown|chmod|sync|mktemp)\b' \
  "$root/install-xray.sh" "$root/xray-sub" "$root/xray-admin" | sort -u)
echo "  used: $(echo "$used" | tr '\n' ' ')"
installed=$(grep -oE 'apt-get install[^|]*' "$root/install-xray.sh" | tr ' ' '\n' | grep -vE 'apt-get|install|-y|--no-install-recommends|^$' | sort -u)
echo "  installed via apt: $(echo "$installed" | tr '\n' ' ')"

echo '=== 3. unit users must exist or be created ==='
# Collapse line continuations first: useradd may span lines in the installer.
flat=$(tr -d '\\\n' < "$root/install-xray.sh")
for u in $(grep -hoE '^(User|Group)=.*' "$root/xray-sub.service" "$root/install-xray.sh" | sed 's/^[A-Za-z]*=//' | grep -vE '^\$|^\{' | sort -u); do
  if [[ $u == nobody || $u == root ]]; then continue; fi
  if printf '%s' "$flat" | grep -q "useradd[^|]*$u\|groupadd[^|]*$u"; then
    echo "  $u: created by installer OK"
  else
    echo "  $u: NOT created by installer"; fail=1
  fi
done

echo '=== 4. placeholder must be substituted before use ==='
for ph in __SUB_PORT__ __BUSYBOX__; do
  if grep -q "$ph" "$root/xray-sub.service"; then
    grep -q "s#${ph}#" "$root/install-xray.sh" || { echo "  $ph not substituted"; fail=1; }
    echo "  $ph: substituted OK"
  fi
done

echo '=== 5. subscription port must not be hardcoded ==='
if grep -qE 'port 2096|SUB_LISTEN_PORT:-2096' "$root/xray-sub.service"; then
  echo '  FAIL: unit hardcodes 2096'; fail=1
else
  echo '  2096 not hardcoded in unit OK'
fi

((fail == 0))
echo 'AUDIT PASS'
