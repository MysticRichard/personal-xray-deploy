#!/usr/bin/env bash
# Firewall detection must report, and only change rules when explicitly asked.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -n '/^firewall_report() {/,/^}/p' "$root/install-xray.sh" > "$work/fw.sh"
{
  echo 'fail() { printf "ERROR: %s\n" "$*" >&2; exit 1; }'
  echo 'PUBLIC_PORT=24443'
  echo 'SUB_PUBLIC_PORT=24996'
  echo 'SUB_LISTEN_PORT=14996'
  cat "$work/fw.sh"
  echo 'firewall_report'
} > "$work/run.sh"

mkdir -p "$work/bin"
cat > "$work/bin/ufw" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
  status) printf 'Status: active\n';;
  allow) printf '%s\n' "${2:-}" >> "$UFW_LOG";;
  *) exit 0;;
esac
EOF
chmod +x "$work/bin/ufw"

out=$(PATH="$work/bin:$PATH" bash "$work/run.sh")
grep -q 'ufw active' <<<"$out" || { echo "FAIL: active ufw not reported: $out"; exit 1; }
grep -q 'allow before testing' <<<"$out" || { echo "FAIL: rules changed without opt-in: $out"; exit 1; }

log="$work/ufw.log"
: > "$log"
out=$(PATH="$work/bin:$PATH" UFW_LOG="$log" OPEN_FIREWALL=1 bash "$work/run.sh")
grep -qx '24443/tcp' "$log" || { echo 'FAIL: proxy port not opened on request'; exit 1; }
grep -qx '24996/tcp' "$log" || { echo 'FAIL: subscription port not opened on request'; exit 1; }

# No ufw/firewalld on a clean PATH: the report must say so instead of failing.
mkdir -p "$work/empty"
bash_bin=$(command -v bash)
out=$(PATH="$work/empty" "$bash_bin" "$work/run.sh" 2>&1 || true)
grep -q 'no active ufw/firewalld' <<<"$out" || { echo "FAIL: missing firewall not reported: $out"; exit 1; }

echo 'PASS: firewall is reported; rules change only with OPEN_FIREWALL=1'
