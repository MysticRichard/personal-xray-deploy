#!/usr/bin/env bash
# Regression for provider-plan parsing; no services or network.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n '/^fail()/p; /^validate_plan()/,/^}/p' "$root/install-xray.sh" > "$work/functions"

run_plan() {
  local name=$1 expect=$2 total=$3 reset=$4 expire=$5
  local rc=0 output
  output=$(env -i PATH="$PATH" PLAN_TOTAL="$total" PLAN_RESET_DAY="$reset" PLAN_EXPIRE="$expire" \
    bash -c 'set -Eeuo pipefail; source "$1"; validate_plan; printf "%s|%s|%s\n" "$PLAN_TOTAL_BYTES" "$PLAN_RESET_DAY" "$PLAN_EXPIRE_DATE"' \
    _ "$work/functions" 2>&1) || rc=$?
  if [[ $expect == reject ]]; then
    [[ $rc == 1 ]] && grep -q '^ERROR:' <<<"$output" || { echo "FAIL: $name did not reject (rc=$rc)"; cat <<<"$output"; return 1; }
  else
    [[ $rc == 0 && $output == "$expect" ]] || { echo "FAIL: $name expected [$expect], got [$output] rc=$rc"; return 1; }
  fi
  echo "PASS: $name"
}

run_plan '100GB plan' '107374182400|1|2027-10-26' 100GB 1 2027-10-26
run_plan '1TB no expiry' '1099511627776|0|0' 1TB 0 0
run_plan 'unlimited' '0|0|0' 0 0 0
run_plan 'decimal GB' '1610612736|15|0' 1.5GB 15 0
run_plan '500MB reset day 31' '524288000|31|0' 500MB 31 0
run_plan 'invalid unit' reject 100XB 1 0
run_plan 'invalid reset day' reject 100GB 32 0
run_plan 'invalid date' reject 100GB 1 2026-02-30
echo 'ALL PLAN VALIDATION CASES PASSED'
