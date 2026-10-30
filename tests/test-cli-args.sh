#!/usr/bin/env bash
# Argument parsing must work without root and must fail closed on typos.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/install-xray.sh"

bash "$script" --help | grep -q -- '--verify' || { echo 'FAIL: help omits --verify'; exit 1; }
bash "$script" --help | grep -q -- '--open-firewall' || { echo 'FAIL: help omits --open-firewall'; exit 1; }

if bash "$script" --bogus-option >/dev/null 2>&1; then
  echo 'FAIL: unknown argument accepted'
  exit 1
fi

if bash "$script" --render >/dev/null 2>&1; then
  echo 'FAIL: --render without output accepted'
  exit 1
fi

# No installed state on a clean host: verify must refuse instead of pretending.
if [[ ! -f /usr/local/etc/xray/client.json ]]; then
  if bash "$script" --verify >/dev/null 2>&1; then
    echo 'FAIL: --verify passed without an installed node'
    exit 1
  fi
fi

# Target-only input derives the SNI instead of requiring it twice.
grep -q 'REALITY_SERVER_NAME=${REALITY_DEST%:\*}' "$script" \
  || { echo 'FAIL: SNI is not derived from --target'; exit 1; }

# The loopback smoke test must stay wired: REALITY + Vision + SOCKS check.
grep -q 'socks5-hostname' "$script" || { echo 'FAIL: smoke test lost SOCKS check'; exit 1; }
grep -q 'fingerprint: "chrome"' "$script" || { echo 'FAIL: smoke test lost REALITY client config'; exit 1; }
grep -q 'install-xray.sh" --verify' "$root/one-click.sh" \
  || { echo 'FAIL: one-click no longer runs the smoke test'; exit 1; }

echo 'PASS: CLI arguments parse, typos fail, and --verify refuses a missing node'
