#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export SERVER_ADDRESS=203.0.113.10 LISTEN_PORT=18444 PUBLIC_PORT=28443
export REALITY_DEST=example.com:443 REALITY_SERVER_NAME=example.com
export CLIENT_UUID=11111111-1111-4111-8111-111111111111
export PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
export PUBLIC_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
export SHORT_ID=0123456789abcdef
bash "$root/install-xray.sh" --render "$work/config.json"
python3 - "$work/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
assert len(c['inbounds']) == 1, 'Extra unauthenticated listeners'
i = c['inbounds'][0]
assert i['protocol'] == 'vless' and i['streamSettings']['security'] == 'reality'
assert i['settings']['clients'][0]['flow'] == 'xtls-rprx-vision'
r = c['routing']
assert r['domainStrategy'] == 'IPOnDemand', 'Domain destinations bypass IP rules'
assert r['rules'][0]['outboundTag'] == 'block'
assert 'geoip:private' in r['rules'][0]['ip']
assert c['log']['access'] == 'none'
assert i['streamSettings']['realitySettings']['shortIds'] == ['0123456789abcdef']
PY
if [[ -n "${XRAY_BIN:-}" ]]; then
  "$XRAY_BIN" run -test -config "$work/config.json"
fi
hash="$(sha256sum "$work/config.json")"
if CLIENT_UUID='bad"uuid' bash "$root/install-xray.sh" --render "$work/config.json" >/dev/null 2>&1; then
  echo 'FAIL: invalid UUID accepted' >&2; exit 1
fi
[[ "$(sha256sum "$work/config.json")" == "$hash" ]]
if LISTEN_PORT=70000 bash "$root/install-xray.sh" --render "$work/bad.json" >/dev/null 2>&1; then
  echo 'FAIL: invalid port accepted' >&2; exit 1
fi
if REALITY_DEST='example.com:0' bash "$root/install-xray.sh" --render "$work/bad.json" >/dev/null 2>&1; then
  echo 'FAIL: invalid target port accepted' >&2; exit 1
fi
if bash "$root/install-xray.sh" --render "$work/config.json" >/dev/null 2>&1; then
  echo 'FAIL: existing config overwritten' >&2; exit 1
fi
[[ "$(sha256sum "$work/config.json")" == "$hash" ]]
echo 'PASS: real renderer, security settings, input rejection, no overwrite'
