#!/usr/bin/env bash
# Verify private rules merge before generic ones and never ship in the repo.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -e "s#^STATE=.*#STATE=$work/client.json#" \
    -e "s#^RULES=.*#RULES=$work/rules.yaml#" \
    -e "s#^RULES_LOCAL=.*#RULES_LOCAL=$work/rules.local.yaml#" \
    -e "s#^TOKEN_FILE=.*#TOKEN_FILE=$work/token#" \
    -e "s#^SUB_PORT_FILE=.*#SUB_PORT_FILE=$work/port#" \
    -e "s#^WEBROOT=.*#WEBROOT=$work/www#" \
    "$root/xray-sub" > "$work/xray-sub"

cat > "$work/client.json" <<'JSON'
{"uuid":"11111111-1111-4111-8111-111111111111","private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short_id":"0123456789abcdef","server":"203.0.113.10","port":34439,"listen_port":2082,"server_name":"example.com"}
JSON
printf '0123456789abcdef0123456789abcdef\n' > "$work/token"
echo 2096 > "$work/port"
printf '%s\n' '- DOMAIN-SUFFIX,generic.example,PROXY' '- MATCH,PROXY' > "$work/rules.yaml"

sub="$work/www/0123456789abcdef0123456789abcdef/config.yaml"

# No private file: generic only.
bash "$work/xray-sub" >/dev/null
python3 - "$sub" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d['rules'] == ['DOMAIN-SUFFIX,generic.example,PROXY', 'MATCH,PROXY']
PY

# Private rules present: they must come first, before generic and MATCH.
printf '%s\n' '# my device' '- DOMAIN,my-device.example.net,DIRECT' '- IP-CIDR,198.51.100.7/32,DIRECT,no-resolve' > "$work/rules.local.yaml"
bash "$work/xray-sub" >/dev/null
python3 - "$sub" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
rules = d['rules']
assert rules[0] == 'DOMAIN,my-device.example.net,DIRECT', rules
assert rules[1] == 'IP-CIDR,198.51.100.7/32,DIRECT,no-resolve'
assert rules[2] == 'DOMAIN-SUFFIX,generic.example,PROXY'
assert rules[-1] == 'MATCH,PROXY'
# MATCH must never precede private rules.
assert rules.index('MATCH,PROXY') == len(rules) - 1
assert 'my device' not in str(rules), 'comment leaked into rules'
PY

# Malformed private rules must fail closed.
printf '%s\n' 'not a rule' > "$work/rules.local.yaml"
if bash "$work/xray-sub" >/dev/null 2>&1; then echo 'FAIL: bad private rules accepted'; exit 1; fi

# The shipped product must not contain the reported private entries.
# tests/ is excluded because this file itself lists them as needles.
for needle in 'dong-nas1138423051' '100.85.255.37' '100.87.73.111' '100.120.158.9'; do
  if grep -rlF "$needle" "$root" 2>/dev/null | grep -v "/tests/" | grep -v '/\.git/' | grep -q .; then
    echo "FAIL: private value shipped in repo: $needle"; exit 1
  fi
done

echo 'PASS: private rules merge first, fail closed on bad input, and are absent from the repo'
