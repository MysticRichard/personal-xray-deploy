#!/usr/bin/env bash
# Generate the complete public profile with synthetic credentials for an actual
# mihomo -t check on the host. Never use the user's live node parameters.
set -Eeuo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state"
sed -e "s#^STATE=.*#STATE=$work/state/client.json#" \
    -e "s#^RULES=.*#RULES=/work/rules.template.yaml#" \
    -e "s#^RULES_LOCAL=.*#RULES_LOCAL=$work/state/no-private.yaml#" \
    -e "s#^TOKEN_FILE=.*#TOKEN_FILE=$work/state/token#" \
    -e "s#^SUB_PORT_FILE=.*#SUB_PORT_FILE=$work/state/port#" \
    -e "s#^USERINFO=.*#USERINFO=$work/state/userinfo#" \
    -e "s#^WEBROOT=.*#WEBROOT=$work/www#" /work/xray-sub > "$work/generate"
cat > "$work/state/client.json" <<'EOF'
{"uuid":"11111111-1111-4111-8111-111111111111","public_key":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","short_id":"0123456789abcdef","server":"203.0.113.10","port":28443,"server_name":"example.com"}
EOF
printf '%s\n' abcdef0123456789abcdef0123456789 > "$work/state/token"
echo 18996 > "$work/state/port"
bash "$work/generate" >/dev/null
cp "$work/www/abcdef0123456789abcdef0123456789/config.yaml" /out/profile.yaml
python3 - /out/profile.yaml <<'PY'
import sys,yaml
c=yaml.safe_load(open(sys.argv[1]))
assert len(c['rules'])==8633
assert c['rules'][-1]=='MATCH,PROXY'
assert c['find-process-mode']=='strict'
assert all('#PROXY' in d for d in c['dns']['fallback'])
print('PASS: complete 8633-rule profile and DNS fields generated')
PY
