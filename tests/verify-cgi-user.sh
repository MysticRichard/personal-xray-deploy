#!/bin/sh
set -e
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends busybox curl >/dev/null 2>&1
useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray-sub 2>/dev/null || true

mkdir -p /srv/sub/cgi-bin /etc/xray-sub
printf 'rules:\n  - MATCH,DIRECT\n' > /srv/sub/config.yaml
chmod 644 /srv/sub/config.yaml
printf 'upload=1; download=2; total=3; expire=4\n' > /etc/xray-sub/userinfo
chown root:xray-sub /etc/xray-sub/userinfo
chmod 640 /etc/xray-sub/userinfo
chmod 755 /etc/xray-sub

cat > /srv/sub/cgi-bin/tok <<'CGI'
#!/bin/sh
printf 'Content-Type: text/yaml\r\n'
if [ -s /etc/xray-sub/userinfo ]; then
  printf 'Subscription-Userinfo: %s\r\n' "$(cat /etc/xray-sub/userinfo)"
fi
printf '\r\n'
cat /srv/sub/config.yaml
CGI
chmod 755 /srv/sub/cgi-bin/tok

echo '--- as service user ---'
runuser -u xray-sub -- busybox httpd -f -p 18094 -h /srv/sub >/tmp/h.log 2>&1 &
pid=$!
sleep 2
curl -s -D /tmp/hdr.txt -o /tmp/body.yaml --max-time 5 http://127.0.0.1:18094/cgi-bin/tok || echo 'curl failed'
echo '--- headers ---'
cat /tmp/hdr.txt
echo '--- body ---'
cat /tmp/body.yaml
kill $pid 2>/dev/null || true
if grep -qi 'Subscription-Userinfo' /tmp/hdr.txt; then
  echo 'PASS: quota readable as service user'
else
  echo 'FAIL: service user cannot read quota'
fi
