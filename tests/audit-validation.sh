#!/usr/bin/env bash
# Probe the installer for input-validation gaps found by review.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
inst="$root/install-xray.sh"
fail=0

note() { printf '%s\n' "$*"; }
bad() { printf 'GAP: %s\n' "$*"; fail=1; }

# 1. Are the subscription ports validated at all?
if grep -qE 'valid_port "\$SUB_LISTEN_PORT"|valid_port "\$SUB_PUBLIC_PORT"' "$inst"; then
  note 'subscription ports: validated'
else
  bad 'SUB_LISTEN_PORT / SUB_PUBLIC_PORT are never range-checked'
fi

# 2. Can they collide with the proxy port?
if grep -q 'SUB_LISTEN_PORT.*==.*LISTEN_PORT\|same port' "$inst"; then
  note 'port collision: checked'
else
  bad 'no check that SUB_LISTEN_PORT differs from LISTEN_PORT'
fi

# 3. Is the subscription port tested for availability before bind?
if grep -q 'port_busy\|sport = :\$sub_port' "$inst"; then
  note 'subscription port availability: checked'
else
  bad 'subscription port availability not checked before starting the unit'
fi

# 4. Does rollback cover subscription files?
if grep -q 'rules.yaml\|xray-sub.service' <<<"$(sed -n '/^  cleanup()/,/^  }/p' "$inst")"; then
  note 'rollback covers subscription files'
else
  bad 'rollback does not restore subscription unit/rules on failure'
fi

# 5. Does the Xray port check handle a legacy state file without listen_port?
if grep -q 'listen_port//\|listen_port //\|has("listen_port")' "$inst"; then
  note 'legacy state without listen_port: handled'
else
  bad 'jq -er .listen_port fails hard when the field is missing (cryptic exit)'
fi

exit $fail
