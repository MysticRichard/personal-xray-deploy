#!/bin/sh
root=/work
work=/tmp/dbg
rm -rf $work; mkdir -p $work
sed -e "s#^STATE=.*#STATE=$work/client.json#" \
    -e "s#^RULES=.*#RULES=$work/rules.yaml#" \
    -e "s#^RULES_LOCAL=.*#RULES_LOCAL=$work/rules.local.yaml#" \
    -e "s#^TOKEN_FILE=.*#TOKEN_FILE=$work/token#" \
    -e "s#^SUB_PORT_FILE=.*#SUB_PORT_FILE=$work/port#" \
    -e "s#^WEBROOT=.*#WEBROOT=$work/www#" \
    "$root/xray-sub" | sed -e "s#/etc/xray-sub/userinfo#$work/userinfo#g" -e "s#/srv/sub#$work/www#g" > "$work/xray-sub"
cat > "$work/client.json" <<'JSON'
{"uuid":"11111111-1111-4111-8111-111111111111","private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short_id":"0123456789abcdef","server":"203.0.113.10","port":34439,"listen_port":2082,"server_name":"example.com"}
JSON
tok=0123456789abcdef0123456789abcdef
printf '%s\n' "$tok" > "$work/token"
echo 2096 > "$work/port"
printf '%s\n' '- MATCH,PROXY' > "$work/rules.yaml"
bash "$work/xray-sub"
echo "=== cgi file ==="
cat "$work/www/$tok/sub.cgi"
echo "=== wsroot ==="
ls -R "$work/www" | head -20
busybox httpd -f -p 18096 -h "$work/www" >/tmp/h.log 2>&1 &
sleep 2
echo "=== fetch ==="
curl -s -D - --max-time 5 "http://127.0.0.1:18096/$tok/sub.cgi" | head -20
pkill httpd
