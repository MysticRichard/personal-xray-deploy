#!/bin/sh
# Can busybox httpd emit custom response headers via CGI?
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends busybox curl >/dev/null 2>&1
mkdir -p /srv/www/cgi-bin
printf 'proxies: []\n' > /srv/www/config.yaml
cat > /srv/www/cgi-bin/sub.cgi <<'CGI'
#!/bin/sh
printf 'Content-Type: text/yaml\r\n'
printf 'Subscription-Userinfo: upload=1024; download=2048; total=107374182400; expire=1790000000\r\n'
printf '\r\n'
cat /srv/www/config.yaml
CGI
chmod 755 /srv/www/cgi-bin/sub.cgi
busybox httpd -f -p 18098 -h /srv/www >/tmp/h.log 2>&1 &
sleep 2
echo "=== direct file ==="
curl -s -D - -o /dev/null --max-time 5 http://127.0.0.1:18098/config.yaml | head -6
echo "=== cgi ==="
curl -s -D - --max-time 5 http://127.0.0.1:18098/cgi-bin/sub.cgi | head -8
pkill httpd 2>/dev/null
