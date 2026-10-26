#!/usr/bin/env bash
# Regression: subscription service must recover when the host rejects
# mount namespaces (nested Podman/LXC), instead of aborting installation.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

# The unit must not request namespacing that nested containers reject.
if grep -qE 'ProtectSystem=strict|ProtectHome=true|PrivateTmp=true|DynamicUser=yes' "$root/xray-sub.service"; then
  echo 'FAIL: hardened unit still requires mount namespaces'
  exit 1
fi

# Installer must carry a fallback path for NAMESPACE failures.
grep -q 'NAMESPACE' "$root/install-xray.sh" || { echo 'FAIL: no namespace fallback'; exit 1; }
grep -q 'minimal' "$root/install-xray.sh" || { echo 'FAIL: no minimal unit'; exit 1; }

echo 'PASS: subscription unit avoids namespacing; installer has fallback'
