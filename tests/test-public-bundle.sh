#!/usr/bin/env bash
# Public-repository privacy and bundle-shape checks.
# Instance-specific values are checked by a private pre-push scan outside this
# repository; do not put the real mappings back into a public test.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fail=0

mapfile -t all_files < <(git -C "$root" ls-files --cached --others --exclude-standard || true)
code_files=()
for f in "${all_files[@]}"; do
  case "$f" in
    tests/*|rules.template.yaml|one-click.sh|xray-server-deploy.zip*|*.zip|*.sha256) continue ;;
  esac
  code_files+=("$root/$f")
done

# Credential material must never be committed, including in new/untracked files.
if ((${#all_files[@]})); then
  if (cd "$root" && grep -InE 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY' "${all_files[@]}" 2>/dev/null); then
    echo 'FAIL: credential-like content committed'
    fail=1
  fi
fi

# No public IPv4 outside reserved documentation/private ranges in code/docs.
# The public rule template and the generated bundle are excluded because they
# legitimately contain public destination addresses.
if ((${#code_files[@]})); then
  if grep -rnoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' "${code_files[@]}" 2>/dev/null \
     | grep -vE ':(127\.|10\.|0\.0\.0\.0|255\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|203\.0\.113\.|198\.51\.100\.|192\.0\.2\.|198\.18\.|198\.19\.|100\.64\.|169\.254\.|224\.|240\.|1\.1\.1\.1|8\.8\.8\.8|223\.5\.5\.5|9\.9\.9\.9)' ; then
    echo 'FAIL: public IPv4 literal outside reserved ranges'
    fail=1
  fi
fi

# The public rule template must be complete and keep the final catch-all.
rules_count=$(grep -c '^- ' "$root/rules.template.yaml" 2>/dev/null || echo 0)
[[ $rules_count == 8633 ]] || { echo "FAIL: expected 8633 public rules, found $rules_count"; fail=1; }
[[ $(tail -n 1 "$root/rules.template.yaml") == '- MATCH,PROXY' ]] \
  || { echo 'FAIL: public rules do not end with MATCH,PROXY'; fail=1; }

# The generated entrypoint must carry the same rule count, not a stale template.
bundle_count=$(grep -c '^- ' "$root/one-click.sh" 2>/dev/null || echo 0)
[[ $bundle_count == 8633 ]] || { echo "FAIL: one-click bundle has $bundle_count rules, expected 8633"; fail=1; }

# A default REALITY target is allowed, but it must be documented and overridable.
grep -q 'www.apple.com:443' "$root/one-click.sh" \
  || { echo 'FAIL: documented default REALITY target missing from prompt'; fail=1; }

((fail == 0))
echo 'PASS: no committed credentials or stray public IPs; 8633 public rules and bundle shape intact'
