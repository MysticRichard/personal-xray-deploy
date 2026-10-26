#!/usr/bin/env bash
# Verify xray-sub renders a valid subscription and rejects bad templates.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Redirect the script's fixed paths into the temp dir by running a copy.
sed -e "s#^STATE=.*#STATE=$work/client.json#" \
    -e "s#^RULES=.*#RULES=$work/rules.yaml#" \
    -e "s#^TOKEN_FILE=.*#TOKEN_FILE=$work/token#" \
    -e "s#^SUB_PORT_FILE=.*#SUB_PORT_FILE=$work/port#" \
    -e "s#^WEBROOT=.*#WEBROOT=$work/www#" \
    "$root/xray-sub" > "$work/xray-sub"
chmod +x "$work/xray-sub"

cat > "$work/client.json" <<'JSON'
{"uuid":"11111111-1111-4111-8111-111111111111","private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short_id":"0123456789abcdef","server":"203.0.113.10","port":34439,"listen_port":2082,"server_name":"example.com"}
JSON
printf '0123456789abcdef0123456789abcdef\n' > "$work/token"
echo 2096 > "$work/port"
printf '%s\n' \
  '# comment' \
  '- DOMAIN-SUFFIX,example.com,PROXY' \
  '- IP-CIDR,127.0.0.0/8,DIRECT,no-resolve' \
  '- MATCH,PROXY' > "$work/rules.yaml"

bash "$work/xray-sub" > "$work/out.log"
sub="$work/www/0123456789abcdef0123456789abcdef/config.yaml"
[[ -f $sub ]] || { echo 'FAIL: subscription file not created'; exit 1; }

python3 - "$sub" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d['proxies'][0]['type'] == 'vless', 'node type'
assert d['proxies'][0]['port'] == 34439, 'public port must be used'
assert d['proxies'][0]['reality-opts']['short-id'] == '0123456789abcdef'
assert d['proxy-groups'][0]['name'] == 'PROXY'
assert d['rules'][-1] == 'MATCH,PROXY', 'final rule lost'
assert len(d['rules']) == 3, 'comment lines must not enter rules'
assert 'private-key' not in str(d), 'server private key must never be published'
assert d['dns']['enable'] is True
PY

# Malformed template must fail closed and leave the previous file intact.
before=$(sha256sum "$sub")
printf '%s\n' '- DOMAIN,a.com,PROXY' 'this is not a rule' > "$work/rules.yaml"
if bash "$work/xray-sub" >/dev/null 2>&1; then echo 'FAIL: malformed template accepted'; exit 1; fi
[[ $(sha256sum "$sub") == "$before" ]] || { echo 'FAIL: bad template overwrote subscription'; exit 1; }

# Node or rules missing must also fail.
printf -- '- MATCH,PROXY\n' > "$work/rules.yaml"
rm -f "$work/client.json"
if bash "$work/xray-sub" >/dev/null 2>&1; then echo 'FAIL: missing state accepted'; exit 1; fi

echo 'PASS: subscription renders valid YAML, hides private key, rejects bad input'
