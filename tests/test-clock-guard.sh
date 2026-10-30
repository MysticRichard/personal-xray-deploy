#!/usr/bin/env bash
# A skewed clock must stop the install before TLS produces a misleading error.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -n '/^check_clock() {/,/^}/p' "$root/install-xray.sh" > "$work/clock.sh"
{
  echo 'fail() { printf "ERROR: %s\n" "$*" >&2; exit 1; }'
  echo 'command -v timeout >/dev/null || timeout() { shift; "$@"; }'
  echo 'REALITY_SERVER_NAME=example.com'
  echo 'CLOCK_SKEW_LIMIT=120'
  cat "$work/clock.sh"
  echo 'check_clock'
} > "$work/run.sh"

mkdir -p "$work/bin-old" "$work/bin-ok"
cat > "$work/bin-old/curl" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nDate: %s\r\n\r\n' "$(date -u -d '-1 hour' '+%a, %d %b %Y %H:%M:%S GMT')"
EOF
cat > "$work/bin-ok/curl" <<'EOF'
#!/usr/bin/env bash
printf 'HTTP/2 200\r\nDate: %s\r\n\r\n' "$(date -u '+%a, %d %b %Y %H:%M:%S GMT')"
EOF
chmod +x "$work/bin-old/curl" "$work/bin-ok/curl"

if PATH="$work/bin-old:$PATH" bash "$work/run.sh" >/dev/null 2>&1; then
  echo 'FAIL: one-hour clock skew accepted'
  exit 1
fi

PATH="$work/bin-ok:$PATH" bash "$work/run.sh" | grep -q 'skew=0s' \
  || { echo 'FAIL: correct clock not reported'; exit 1; }

# Without an HTTP Date header the check must warn, not fabricate a failure.
mkdir -p "$work/bin-empty"
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/bin-empty/curl"
chmod +x "$work/bin-empty/curl"
PATH="$work/bin-empty:$PATH" bash "$work/run.sh" 2>&1 | grep -q 'WARN:' \
  || { echo 'FAIL: missing Date header did not warn'; exit 1; }

echo 'PASS: clock skew stops install; correct and unknown clocks handled'
