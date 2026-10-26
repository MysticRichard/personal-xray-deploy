#!/bin/sh
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends busybox curl >/dev/null 2>&1
mkdir -p /srv/sub/tok
printf 'proxies: []\n' > /srv/sub/tok/config.yaml
chmod -R a+rX /srv/sub
busybox httpd -f -p 18099 -h /srv/sub >/tmp/h.log 2>&1 &
sleep 3
echo "httpd procs: $(ps -eo pid,comm | grep -c httpd)"
echo "hit: $(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:18099/tok/config.yaml)"
echo "miss: $(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:18099/nope/config.yaml)"
echo "list: $(curl -s --max-time 5 http://127.0.0.1:18099/tok/ | head -c 80 | tr '\n' ' ')"
for p in $(ps -eo pid,comm | awk '/httpd/ {print $1}'); do
  echo "rss pid=$p: $(awk '/VmRSS:/ {print $2}' /proc/$p/status 2>/dev/null) kB"
done
pkill httpd 2>/dev/null
