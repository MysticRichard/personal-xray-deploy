#!/usr/bin/env bash
# Verify quota headers are served through CGI, behind the token.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
port=18095

sed -e "s#^STATE=.*#STATE=$work/client.json#" \
    -e "s#^RULES=.*#RULES=$work/rules.yaml#" \
    -e "s#^TOKEN_FILE=.*#TOKEN_FILE=$work/token#" \
    -e "s#^SUB_PORT_FILE=.*#SUB_PORT_FILE=$work/port#" \
    -e "s#^USERINFO=.*#USERINFO=$work/userinfo#" \
    -e "s#^WEBROOT=.*#WEBROOT=$work/www#" \
    "$root/xray-sub" > "$work/xray-sub"

cat > "$work/client.json" <<'JSON'
{"uuid":"11111111-1111-4111-8111-111111111111","private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short_id":"0123456789abcdef","server":"203.0.113.10","port":28443,"listen_port":18444,"server_name":"example.com"}
JSON
tok=fe0123456789abcdef0123456789abcd
printf '%s\n' "$tok" > "$work/token"
echo "$port" > "$work/port"
printf '%s\n' '- MATCH,PROXY' > "$work/rules.yaml"

bash "$work/xray-sub" >/dev/null
[[ -x "$work/www/cgi-bin/$tok" ]] || { echo 'FAIL: token CGI missing'; exit 1; }

busybox httpd -f -p "$port" -h "$work/www" >/tmp/q.log 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
trap 'kill $pid 2>/dev/null || true; rm -rf "$work"' EXIT
sleep 2
url="http://127.0.0.1:$port/cgi-bin/$tok"

# No quota file: no header, body still served.
hdr=$(curl -s -D - -o /tmp/q.yaml --max-time 5 "$url")
grep -qi '^Subscription-Userinfo:' <<<"$hdr" && { echo 'FAIL: header without quota file'; exit 1; }
grep -q 'MATCH,PROXY' /tmp/q.yaml || { echo 'FAIL: body missing'; exit 1; }

# With quota file: exact header, body intact, executable not leaked.
printf 'upload=0; download=53687091200; total=107374182400; expire=1800000000\n' > "$work/userinfo"
bash "$work/xray-sub" >/dev/null
hdr=$(curl -s -D - -o /tmp/q.yaml --max-time 5 "$url")
grep -qi '^Subscription-Userinfo: upload=0; download=53687091200; total=107374182400; expire=1800000000' <<<"$hdr" \
  || { echo 'FAIL: quota header wrong'; printf '%s\n' "$hdr"; exit 1; }
grep -q 'MATCH,PROXY' /tmp/q.yaml || { echo 'FAIL: body missing with quota'; exit 1; }

# Wrong token must not serve anything.
[[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/cgi-bin/wrongtoken") == 404 ]] \
  || { echo 'FAIL: wrong token served'; exit 1; }

echo 'PASS: quota headers served via token CGI; body intact; wrong token rejected'
