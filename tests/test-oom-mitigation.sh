#!/usr/bin/env bash
# Only in a disposable Debian container: verify the 128MB OOM mitigation.
set -Eeuo pipefail
[[ -f /DISPOSABLE_XRAY_TEST ]] || exit 1
root=$(cd "$(dirname "$0")/.." && pwd)
# The staging archive must be removed before service start.
grep -q 'rm -f "$stage/core.zip"' "$root/install-xray.sh"
# A failed start must be retried rather than aborting on the first OOM.
grep -q 'for attempt in 1 2 3' "$root/install-xray.sh"
# Explicit heap ceiling must reach the service environment.
grep -q 'Environment=GOMEMLIMIT=48MiB' "$root/install-xray.sh"
grep -q 'MemoryMax=112M' "$root/install-xray.sh"
bash "$root/tests/test-one-click.sh"
# Confirm the installed unit actually carries the limits (read the file: the
# test systemctl stub does not implement 'cat').
grep -qE 'GOMEMLIMIT=48MiB' /etc/systemd/system/xray.service || {
  echo 'FAIL: installed unit lost GOMEMLIMIT'; exit 1; }
grep -qE 'MemoryMax=112M' /etc/systemd/system/xray.service || {
  echo 'FAIL: installed unit lost MemoryMax'; exit 1; }
grep -qE 'GOGC=30' /etc/systemd/system/xray.service || {
  echo 'FAIL: installed unit lost GOGC'; exit 1; }
echo 'PASS: OOM mitigations present in source and installed unit'
