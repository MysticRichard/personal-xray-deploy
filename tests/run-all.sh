#!/bin/sh
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl openssl unzip jq iproute2 procps busybox systemd python3-yaml >/dev/null 2>&1

echo '########## 1. static audit ##########'
bash /work/tests/audit-assumptions.sh | tail -4

echo '########## 2. deliverable units ##########'
sh /work/tests/verify-deliverable.sh 2>&1 | grep -E '^===|^OK|FAIL|MISSING' | head -20

echo '########## 3. permissions ##########'
bash /work/tests/verify-permissions.sh 2>&1 | tail -4

echo '########## 4. subscription behaviour ##########'
sh /work/tests/run-sub-tests.sh 2>&1 | tail -8

echo '########## 5. cgi as service user ##########'
sh /work/tests/verify-cgi-user.sh 2>&1 | tail -3

echo '########## 6. namespace fallback present ##########'
bash /work/tests/test-namespace-fallback.sh

echo '########## 7. profile generator ##########'
echo '(windows-only, skipped in container)'

echo '########## 8. bundle integrity ##########'
if command -v git >/dev/null 2>&1; then
  bash /work/tests/test-public-bundle.sh
else
  # No git in this image: scan all shipped files directly instead.
  bad=0
  for needle in 'dong-nas1138423051' '100.85.255.37' '103.188.82.89'; do
    if grep -rlF "$needle" /work --include='*.sh' --include='*.yaml' --include='*.md' \
       2>/dev/null | grep -v '/tests/' | grep -q .; then
      echo "FAIL: private value in shipped file: $needle"; bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then
    echo 'PASS: no private values in shipped files'
  else
    exit 1
  fi
fi

echo 'ALL REGRESSION CHECKS DONE'
