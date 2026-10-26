#!/usr/bin/env bash
# Exercise real validation functions. Missing fail() must never mask a reject.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n '/^fail()/p; /^valid_port()/p; /^validate()/,/^}/p' "$root/install-xray.sh" > "$work/functions"
case_run() {
  local name=$1 expect=$2; shift 2
  local rc=0
  env -i PATH="$PATH" "$@" bash -c 'set -Eeuo pipefail; source "$1"; validate' _ "$work/functions" > "$work/out" 2>&1 || rc=$?
  if [[ $expect == reject ]]; then
    [[ $rc == 1 ]] && grep -q '^ERROR:' "$work/out" || { echo "FAIL: $name did not reject with a validation error (rc=$rc)"; return 1; }
  else
    [[ $rc == 0 ]] || { echo "FAIL: $name unexpectedly rejected"; cat "$work/out"; return 1; }
  fi
  echo "PASS: $name ($expect)"
}
base=(SERVER_ADDRESS=203.0.113.10 LISTEN_PORT=18443 PUBLIC_PORT=28443 REALITY_DEST=example.com:443 REALITY_SERVER_NAME=example.com)
case_run 'base parameters' accept "${base[@]}"
case_run 'matching internal ports' reject "${base[@]}" SUB_LISTEN_PORT=18443
case_run 'subscription port too large' reject "${base[@]}" SUB_LISTEN_PORT=70000
case_run 'subscription public nonnumeric' reject "${base[@]}" SUB_PUBLIC_PORT=abc
case_run 'mismatched SNI' reject "${base[@]}" REALITY_SERVER_NAME=other.example
case_run 'zero listener' reject "${base[@]}" LISTEN_PORT=0
case_run 'distinct subscription ports' accept "${base[@]}" SUB_LISTEN_PORT=18996 SUB_PUBLIC_PORT=28996
