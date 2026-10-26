#!/usr/bin/env bash
# Regression: subscription service must not depend on a busybox path that may
# not exist, must use a dedicated user, and must let the service read quota.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
unit="$root/xray-sub.service"
inst="$root/install-xray.sh"
fail=0

check() { grep -qF "$1" "$2" || { echo "FAIL: $3"; fail=1; }; }
absent() { grep -qF "$1" "$2" && { echo "FAIL: $3"; fail=1; } || true; }

# ExecStart must be a placeholder resolved at install time.
check 'ExecStart=__BUSYBOX__ httpd' "$unit" 'ExecStart not templated'
absent 'ExecStart=/usr/bin/busybox' "$unit" 'hardcoded /usr/bin/busybox'

# "nobody" is flagged unsafe by systemd; require a dedicated account.
absent 'User=nobody' "$unit" '"nobody" still used'
check 'User=xray-sub' "$unit" 'dedicated user missing'

# No mount-namespacing options (nested containers reject them).
for opt in 'ProtectSystem=strict' 'ProtectHome=true' 'PrivateTmp=true' 'DynamicUser=yes'; do
  absent "$opt" "$unit" "$opt requires mount namespace"
done

# Installer must install busybox and create the user when missing.
check 'apt-get install -y --no-install-recommends busybox' "$inst" 'busybox not installed on demand'
check 'useradd --system' "$inst" 'service user not created'
check 'xray-sub' "$inst" 'service user name missing'

# Quota file must be readable by the service group, not world-readable.
check 'chmod 640' "$root/xray-sub" 'quota group-readable mode missing'

((fail == 0))
echo 'PASS: templated busybox path, dedicated user, no namespacing, quota readable by service'
