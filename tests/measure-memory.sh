#!/usr/bin/env bash
# Measure Xray startup memory with and without geoip database use.
set -Eeuo pipefail
export XRAY_LOCATION_ASSET=/core
keys=$(/core/xray x25519)
PRIVATE_KEY=$(printf '%s\n' "$keys" | sed -n 's/^PrivateKey: //p')

make_config() {
  local with_geoip="$1" out="$2"
  local geoip_rules=''
  if [[ $with_geoip == yes ]]; then
    geoip_rules='"geoip:private", "geoip:cn", '
  fi
  cat > "$out" <<EOF
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
  "outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {"type": "field", "ip": [${geoip_rules}"0.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4", "::/128", "fc00::/7", "fe80::/10", "ff00::/8"], "outboundTag": "block"},
      {"type": "field", "network": "tcp,udp", "port": "25,465,587,137-139,445", "outboundTag": "block"},
      {"type": "field", "inboundTag": ["personal"], "outboundTag": "direct"}
    ]
  }
}
EOF
}

run_case() {
  local label="$1" cfg="$2"
  local log="/tmp/run-$label.log"
  /core/xray run -config "$cfg" >"$log" 2>&1 &
  local pid=$!
  local peak=0
  for _ in $(seq 1 40); do
    sleep 0.05
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    local rss
    rss=$(awk '/VmRSS:/ {print $2}' /proc/$pid/status 2>/dev/null || echo 0)
    ((rss > peak)) && peak=$rss
  done
  if kill -0 "$pid" 2>/dev/null; then
    local alive=yes
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  else
    local alive=no
    wait "$pid" 2>/dev/null || true
  fi
  printf '%-24s peak_rss=%6s kB  alive=%s\n' "$label" "$peak" "$alive"
  if [[ $alive == no ]]; then tail -3 "$log" | sed 's/^/    /'; fi
}

make_config yes /tmp/geoip.json
make_config no /tmp/nogeoip.json
/core/xray run -test -config /tmp/geoip.json >/dev/null
/core/xray run -test -config /tmp/nogeoip.json >/dev/null
run_case "with-geoip" /tmp/geoip.json
sleep 1
run_case "without-geoip" /tmp/nogeoip.json
