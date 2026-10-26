#!/usr/bin/env bash
set -Eeuo pipefail
export SERVER_ADDRESS=203.0.113.10 LISTEN_PORT=18444
export REALITY_DEST=example.com:443 REALITY_SERVER_NAME=example.com
export CLIENT_UUID=11111111-1111-4111-8111-111111111111 SHORT_ID=0123456789abcdef
keys=$(/core/xray x25519)
PRIVATE_KEY=$(printf '%s\n' "$keys" | sed -n 's/^PrivateKey: //p')
PUBLIC_KEY=$(printf '%s\n' "$keys" | sed -n 's/^Password (PublicKey): //p')
export PRIVATE_KEY PUBLIC_KEY
bash /work/install-xray.sh --render /tmp/server.json
/core/xray run -test -config /tmp/server.json
/core/xray run -config /tmp/server.json >/tmp/xray.log 2>&1 &
p=$!
trap 'kill "$p" 2>/dev/null || true' EXIT
sleep 3
kill -0 "$p"
sed -n '/VmRSS:/p;/VmPeak:/p' /proc/$p/status
echo 'PASS: generated keys and real core startup under 128MB memory cap (idle only)'
