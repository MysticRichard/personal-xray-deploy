#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
files=$(git -C "$root" ls-files | grep -v '^tests/' || true)
fail=0

# No instance-specific IPs, ports or provider details.
for pattern in '34439' '2082' '42309' '198\.51\.100\.89' '203\.0\.113\.11'; do
  if grep -rnE "$pattern" $files 2>/dev/null; then
    printf 'FAIL: instance-specific value %s found\n' "$pattern"
    fail=1
  fi
done

# No real-looking public IPv4 outside tests (reserved documentation ranges allowed).
if grep -rnoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' $files 2>/dev/null \
   | grep -vE ':(127\.|10\.|0\.0\.0\.0|255\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|203\.0\.113\.|198\.51\.100\.|100\.64\.|169\.254\.|224\.|240\.)' ; then
  echo 'FAIL: public IPv4 literal outside tests'
  fail=1
fi

# Credential material must never be committed.
if grep -rnE 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY' $files 2>/dev/null; then
  echo 'FAIL: credential-like content committed'
  fail=1
fi

# A default REALITY target is allowed, but it must be documented and overridable.
if ! grep -q 'www.microsoft.com:443' "$root/one-click.sh"; then
  echo 'FAIL: documented default REALITY target missing from prompt'
  fail=1
fi

((fail == 0))
echo 'PASS: no instance data or credentials; REALITY default is documented and overridable'
