#!/usr/bin/env bash
# Execute only the actual entrypoint input block; no apt/service mutations.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -n '/^ask() {/,/^export SERVER_ADDRESS PUBLIC_PORT/p' "$root/one-click.sh" > "$work/ask.sh"
cat >> "$work/ask.sh" <<'EOF'
printf '%s\n' "$SERVER_ADDRESS" "$PUBLIC_PORT" "$LISTEN_PORT" "$REALITY_DEST" "$REALITY_SERVER_NAME" "$SUB_PUBLIC_PORT" "$SUB_LISTEN_PORT" "$PLAN_TOTAL" "$PLAN_RESET_DAY" "$PLAN_EXPIRE"
EOF
# All saved values exist: new answers must still be read, not skipped.
answers=$'new.example\n28443\n18443\ncustom.example:443\n\n28996\n18996\n100GB\n1\n2027-10-26\n'
result=$(env SERVER_ADDRESS=old.example PUBLIC_PORT=24443 LISTEN_PORT=14443 REALITY_DEST=old.example:443 REALITY_SERVER_NAME=old.example SUB_PUBLIC_PORT=24996 SUB_LISTEN_PORT=14996 PLAN_TOTAL=50GB PLAN_RESET_DAY=15 PLAN_EXPIRE=2026-12-31 bash "$work/ask.sh" <<<"$answers")
[[ $result == $'new.example\n28443\n18443\ncustom.example:443\ncustom.example\n28996\n18996\n100GB\n1\n2027-10-26' ]] || { echo 'FAIL: saved values skipped prompts or SNI default wrong'; exit 1; }
# Keep saved values via Enter; default SNI derived from selected target.
result=$(env SERVER_ADDRESS=saved.example PUBLIC_PORT=24443 LISTEN_PORT=14443 REALITY_DEST=saved.example:443 REALITY_SERVER_NAME=saved.example SUB_PUBLIC_PORT=24996 SUB_LISTEN_PORT=14996 PLAN_TOTAL=50GB PLAN_RESET_DAY=15 PLAN_EXPIRE=2026-12-31 bash "$work/ask.sh" <<< $'\n\n\n\n\n\n\n\n\n\n')
[[ $result == $'saved.example\n24443\n14443\nsaved.example:443\nsaved.example\n24996\n14996\n50GB\n15\n2026-12-31' ]] || { echo 'FAIL: saved defaults lost'; exit 1; }
if env NONINTERACTIVE=1 bash "$work/ask.sh" </dev/null >/dev/null 2>&1; then echo 'FAIL: unattended missing parameters accepted'; exit 1; fi

# Existing installed state must become prompt defaults even in interactive mode.
# The real entrypoint installs jq; a minimal host Git Bash may not have it.
if command -v jq >/dev/null 2>&1; then
mkdir -p "$work/root/usr/local/etc/xray" "$work/root/etc/xray-sub"
cat > "$work/root/usr/local/etc/xray/client.json" <<'JSON'
{"server":"old.example","port":24443,"listen_port":14443,"server_name":"old.example"}
JSON
cat > "$work/root/usr/local/etc/xray/config.json" <<'JSON'
{"inbounds":[{"tag":"personal","streamSettings":{"realitySettings":{"target":"old.example:443"}}}]}
JSON
printf '24996\n' > "$work/root/etc/xray-sub/public_port"
printf '14996\n' > "$work/root/etc/xray-sub/port"
cat > "$work/root/etc/xray-sub/provider-plan" <<'PLAN'
total_display=100GB
total_bytes=107374182400
reset_day=1
expire_date=2027-10-26
expire_epoch=1792972799
PLAN
{
  echo 'set -Eeuo pipefail'
  sed -n '/^saved=/,/^export SERVER_ADDRESS PUBLIC_PORT/p' "$root/one-click.sh" \
    | sed "s#/usr/local/etc/xray#$work/root/usr/local/etc/xray#g; s#/etc/xray-sub#$work/root/etc/xray-sub#g"
  printf '%s\n' 'printf "%s\\n" "$SERVER_ADDRESS" "$PUBLIC_PORT" "$LISTEN_PORT" "$REALITY_DEST" "$REALITY_SERVER_NAME" "$SUB_PUBLIC_PORT" "$SUB_LISTEN_PORT" "$PLAN_TOTAL" "$PLAN_RESET_DAY" "$PLAN_EXPIRE"'
} > "$work/defaults.sh"
result=$(env -u SERVER_ADDRESS -u PUBLIC_PORT -u LISTEN_PORT -u REALITY_DEST -u REALITY_SERVER_NAME -u SUB_PUBLIC_PORT -u SUB_LISTEN_PORT -u PLAN_TOTAL -u PLAN_RESET_DAY -u PLAN_EXPIRE bash "$work/defaults.sh" <<< $'\n\n\n\n\n\n\n\n\n\n')
[[ $result == $'old.example\n24443\n14443\nold.example:443\nold.example\n24996\n14996\n100GB\n1\n2027-10-26' ]] \
  || { echo "FAIL: saved state was not used as prompt defaults: $result"; exit 1; }
# Explicit unattended mode consumes the same state without prompting.
result=$(env -u SERVER_ADDRESS -u PUBLIC_PORT -u LISTEN_PORT -u REALITY_DEST -u REALITY_SERVER_NAME -u SUB_PUBLIC_PORT -u SUB_LISTEN_PORT -u PLAN_TOTAL -u PLAN_RESET_DAY -u PLAN_EXPIRE NONINTERACTIVE=1 bash "$work/defaults.sh" </dev/null)
[[ $result == $'old.example\n24443\n14443\nold.example:443\nold.example\n24996\n14996\n100GB\n1\n2027-10-26' ]] \
  || { echo "FAIL: unattended saved state was not reused: $result"; exit 1; }
echo 'PASS: saved state is used as interactive and unattended defaults'
else
  echo 'SKIP: saved-state defaults (jq unavailable on this host; covered by the review container)'
fi
echo 'PASS: ten interactive prompts; custom target SNI derived; plan examples accepted; unattended inputs enforced'
