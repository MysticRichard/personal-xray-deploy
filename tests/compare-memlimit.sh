#!/usr/bin/env bash
# Compare startup behaviour with and without Go heap limits under a tight cap.
set -Eeuo pipefail
export XRAY_LOCATION_ASSET=/core
keys=$(/core/xray x25519)
PRIVATE_KEY=$(printf '%s\n' "$keys" | sed -n 's/^PrivateKey: //p')
cat > /tmp/t.json <<EOF
{
  "log": {"access": "none", "loglevel": "warning"},
  "inbounds": [{
    "tag": "personal", "listen": "0.0.0.0", "port": 18443,
    "protocol": "vless",
    "settings": {"clients": [{"id": "11111111-1111-4111-8111-111111111111", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "raw", "security": "reality",
      "realitySettings": {"show": false, "target": "www.microsoft.com:443", "xver": 0,
        "serverNames": ["www.microsoft.com"], "privateKey": "$PRIVATE_KEY", "shortIds": ["0123456789abcdef"]}
    }
  }],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}],
  "routing": {"domainStrategy": "IPOnDemand", "rules": [
    {"type": "field", "ip": ["geoip:private", "geoip:cn"], "outboundTag": "block"},
    {"type": "field", "inboundTag": ["personal"], "outboundTag": "direct"}]}
}
EOF
/core/xray run -test -config /tmp/t.json >/dev/null
for mode in plain limited; do
  if [[ $mode == limited ]]; then
    export GOMEMLIMIT=48MiB GOGC=30
  else
    unset GOMEMLIMIT GOGC
  fi
  /core/xray run -config /tmp/t.json >/tmp/$mode.log 2>&1 &
  pid=$!
  peak=0
  vpeak=0
  for _ in $(seq 1 60); do
    sleep 0.02
    kill -0 "$pid" 2>/dev/null || break
    rss=$(awk '/VmRSS:/ {print $2}' /proc/$pid/status 2>/dev/null || echo 0)
    vsz=$(awk '/VmPeak:/ {print $2}' /proc/$pid/status 2>/dev/null || echo 0)
    ((rss > peak)) && peak=$rss
    ((vsz > vpeak)) && vpeak=$vsz
  done
  if kill -0 "$pid" 2>/dev/null; then s=alive; kill "$pid"; else s=dead; fi
  wait "$pid" 2>/dev/null || true
  printf '%-8s peak_rss=%6s kB  peak_vsz=%8s kB  %s\n' "$mode" "$peak" "${vpeak:-0}" "$s"
  unset vpeak
  sleep 1
done
