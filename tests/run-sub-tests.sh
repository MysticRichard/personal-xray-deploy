#!/bin/sh
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends python3-yaml jq busybox curl >/dev/null 2>&1
for t in test-private-rules test-sub-quota test-subscription; do
  echo "=== $t ==="
  bash /work/tests/$t.sh || exit 1
done
echo "ALL SUBSCRIPTION TESTS PASSED"
