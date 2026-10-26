#!/usr/bin/env bash
# Run in personal-xray-review:local; dependencies installed once in Dockerfile.
# Never filter pipelines: every nonzero test status must abort the runner.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${1:-} == --failure-self-test ]]; then
  bash -c 'exit 23'
  echo 'FAIL: child exit was swallowed'
  exit 0
fi
bash "$root/tests/test-validation-behaviour.sh"
bash "$root/tests/test-plan-validation.sh"
bash "$root/tests/test-preflight-http.sh"
bash "$root/tests/test-bind-address.sh"
bash "$root/tests/test-sub-unit.sh"
bash "$root/tests/test-sub-review.sh"
bash "$root/tests/test-sub-quota.sh"
bash "$root/tests/test-subscription.sh"
bash "$root/tests/test-entrypoint-prompts.sh"
DISPOSABLE_XRAY_TEST=1 bash "$root/tests/test-install-review.sh" --inside
if [[ -d /run/systemd/system && $(tr -d '\n' </proc/1/comm 2>/dev/null) == systemd ]]; then
  DISPOSABLE_XRAY_TEST=1 bash "$root/tests/test-real-systemd.sh" --inside
else
  echo 'SKIP: real-systemd test needs the xray-review-systemd container (docker exec ...)'
fi
# The failure check intentionally gets a nonzero status and verifies it.
rc=0
bash "$0" --failure-self-test >/dev/null 2>&1 || rc=$?
[[ $rc == 23 ]] || { echo 'FAIL: runner masks child failures'; exit 1; }
echo 'PASS: regression runner propagates child failures'
echo 'ALL REVIEW REGRESSION TESTS PASSED'
