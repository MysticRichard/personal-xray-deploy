#!/bin/sh
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends jq python3-yaml >/dev/null 2>&1
w=/tmp/t
rm -rf $w; mkdir -p $w
sed -e "s#^STATE=.*#STATE=$w/client.json#" \
    -e "s#^RULES=.*#RULES=$w/rules.yaml#" \
    -e "s#^TOKEN_FILE=.*#TOKEN_FILE=$w/token#" \
    -e "s#^SUB_PORT_FILE=.*#SUB_PORT_FILE=$w/port#" \
    -e "s#^USERINFO=.*#USERINFO=$w/userinfo#" \
    -e "s#^WEBROOT=.*#WEBROOT=$w/www#" /work/xray-sub > $w/sub.sh
cat > $w/client.json <<'JSON'
{"uuid":"11111111-1111-4111-8111-111111111111","private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short_id":"0123456789abcdef","server":"203.0.113.10","port":28443,"listen_port":18444,"server_name":"example.com"}
JSON
tok=0123456789abcdef0123456789abcdef
printf '%s\n' $tok > $w/token
echo 2096 > $w/port
printf '%s\n' '- MATCH,PROXY' > $w/rules.yaml
printf 'upload=1; download=2; total=3; expire=4\n' > $w/userinfo
bash $w/sub.sh > /tmp/sub.out 2>&1 || { cat /tmp/sub.out; exit 1; }
echo '=== generated CGI ==='
cat $w/www/cgi-bin/$tok
echo '=== run it directly (as root) ==='
sh $w/www/cgi-bin/$tok | head -6
echo '=== done ==='
