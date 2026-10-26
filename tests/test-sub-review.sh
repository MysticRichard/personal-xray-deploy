#!/usr/bin/env bash
# Review subscription generator: public rules only, no device-specific VPS rules.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state"
sed -e "s#^STATE=.*#STATE=$work/state/client.json#" \
    -e "s#^RULES=.*#RULES=$work/state/rules.yaml#" \
    -e "s#^TOKEN_FILE=.*#TOKEN_FILE=$work/state/token#" \
    -e "s#^SUB_PORT_FILE=.*#SUB_PORT_FILE=$work/state/port#" \
    -e "s#^USERINFO=.*#USERINFO=$work/state/userinfo#" \
    -e "s#^WEBROOT=.*#WEBROOT=$work/www#" "$root/xray-sub" > "$work/xray-sub"
chmod +x "$work/xray-sub"
cat > "$work/state/client.json" <<'JSON'
{"uuid":"11111111-1111-4111-8111-111111111111","private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","public_key":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","short_id":"0123456789abcdef","server":"203.0.113.10","port":34439,"server_name":"example.com"}
JSON
printf '2096\n' > "$work/state/port"
printf '0123456789abcdef0123456789abcdef\n' > "$work/state/token"
printf '%s\n' '- DOMAIN-SUFFIX,generic.example,PROXY' '- MATCH,PROXY' > "$work/state/rules.yaml"
bash "$work/xray-sub" >/dev/null
config="$work/www/$(cat "$work/state/token")/config.yaml"
grep -q 'generic.example' "$config"
! grep -qE 'private|device|nas|100\.85|100\.87|100\.120' "$config"
before=$(sha256sum "$config")
printf '%s\n' 'garbage line' > "$work/state/rules.yaml"
if bash "$work/xray-sub" >/dev/null 2>&1; then echo 'FAIL: invalid public rules accepted'; exit 1; fi
[[ $(sha256sum "$config") == "$before" ]] || { echo 'FAIL: invalid rules replaced artifact'; exit 1; }
echo 'PASS: public generator excludes private rules and fails closed'
