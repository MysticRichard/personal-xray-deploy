#!/usr/bin/env bash
# Trigger a real routed request so geoip lookups actually run, then measure peak RSS.
set -Eeuo pipefail
export XRAY_LOCATION_ASSET=/core
keys=$(/core/xray x25519)
PRIVATE_KEY=$(printf '%s\n' "$keys" | sed -n 's/^PrivateKey: //p')

cat > /tmp/load.json <<EOF
{
  "log": {"access": "none", "loglevel": "warning"},
  "inbounds": [
    {
      "tag": "test-socks", "listen": "127.0.0.1", "port": 18080,
      "protocol": "socks", "settings": {"udp": false}
    },
    {
      "tag": "personal", "listen": "127.0.0.1", "port": 18443,
      "protocol": "vless",
      "settings": {"clients": [{"id": "11111111-1111-4111-8111-111111111111", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {
        "network": "raw", "security": "reality",
        "realitySettings": {"show": false, "target": "www.microsoft.com:443", "xver": 0,
          "serverNames": ["www.microsoft.com"], "privateKey": "$PRIVATE_KEY", "shortIds": ["0123456789abcdef"]}
      }
    }
  ],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {"type": "field", "ip": ["geoip:private", "geoip:cn"], "outboundTag": "block"},
      {"type": "field", "inboundTag": ["test-socks"], "outboundTag": "direct"}
    ]
  }
}
EOF

/core/xray run -test -config /tmp/load.json
/core/xray run -config /tmp/load.json >/tmp/load.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 2
kill -0 "$pid" || { echo 'died before load'; tail -5 /tmp/load.log; exit 1; }
base=$(awk '/VmRSS:/ {print $2}' /proc/$pid/status)
# Requests force domain resolution + geoip:cn matching to run for real.
for host in www.microsoft.com www.baidu.com example.com www.github.com; do
  for _ in 1 2 3; do
    curl -s --max-time 8 -o /dev/null -x socks5h://127.0.0.1:18080 "https://$host/" 2>/dev/null || true
  done
done
sleep 1
peak=$(awk '/VmRSS:/ {print $2}' /proc/$pid/status)
printf 'rss_after_start=%s kB  rss_after_lookups=%s kB\n' "$base" "$peak"
kill -0 "$pid" && echo 'alive=yes' || { echo 'alive=no'; tail -5 /tmp/load.log; }
