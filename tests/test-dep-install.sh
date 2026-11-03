#!/usr/bin/env bash
# 依赖安装必须逐个包进行，并在失败时给出可判断的报告。
# 128 MB 机器上一批装九个依赖会被 OOM 杀掉，这里锁住这个行为。
# 只在一次性 Debian 容器内运行（run-all.sh 会带 DISPOSABLE_XRAY_TEST=1）。
set -Eeuo pipefail
if [[ ! -f /DISPOSABLE_XRAY_TEST && ${DISPOSABLE_XRAY_TEST:-0} != 1 ]]; then
  echo 'SKIP: disposable container marker missing'
  exit 0
fi
root=$(cd "$(dirname "$0")/.." && pwd)
entry=$root/one-click.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. 静态断言：写法和顺序不能退化
grep -q 'dependency install (begin)' "$entry" || { echo 'FAIL: 缺少依赖安装块标记'; exit 1; }
grep -q 'for pkg in ca-certificates curl openssl unzip jq iproute2 procps busybox nano; do' "$entry" \
  || { echo 'FAIL: 依赖不再逐个安装'; exit 1; }
grep -q 'Dpkg::Use-Pty=0' "$entry" || { echo 'FAIL: 依赖安装缺少 Dpkg::Use-Pty=0'; exit 1; }
grep -q 'avail_kb < 153600' "$entry" || { echo 'FAIL: 安装前没有磁盘检查'; exit 1; }
grep -q 'dep_memory_mb' "$entry" || { echo 'FAIL: 没有按 cgroup 读取内存上限'; exit 1; }
grep -q 'dep_fail_report' "$entry" || { echo 'FAIL: 没有失败报告函数'; exit 1; }
grep -q 'lxc|openvz|docker|podman' "$entry" || { echo 'FAIL: 容器场景缺少提示'; exit 1; }
if grep -qE 'apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=60 ca-certificates curl' "$entry"; then
  echo 'FAIL: 仍存在一次安装九个依赖的旧写法'
  exit 1
fi

# 2. 行为断言：抽出依赖块，用假的 apt-get/dpkg/df 跑
sed -n '/dependency install (begin)/,/dependency install (end)/p' "$entry" > "$work/block.sh"
cat > "$work/run.sh" <<'EOS'
set -Eeuo pipefail
missing=1
apt-get() { printf '%s\n' "$*" >> "${APT_LOG:?}"; return "${APT_RC:-0}"; }
dpkg() {
  case "${1:-}" in
    -s) return 1 ;;
    *) return 0 ;;
  esac
}
df() {
  if [[ ${1:-} == -Pk ]]; then
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 1048576 100000 %s 10%% /\n' "${FAKE_AVAIL_KB:-900000}"
  else
    command df "$@"
  fi
}
EOS
cat "$work/block.sh" >> "$work/run.sh"

# 2a. 正常路径：九个包各装一次，每次装完 clean
: > "$work/calls.log"
APT_LOG="$work/calls.log" bash "$work/run.sh" > "$work/ok.log" 2>&1 \
  || { cat "$work/ok.log"; echo 'FAIL: 正常路径退出码非 0'; exit 1; }
installs=$(grep -c '^install' "$work/calls.log" || true)
[[ $installs == 9 ]] || { echo "FAIL: 期望 9 次安装，实际 $installs"; cat "$work/calls.log"; exit 1; }
# 每个 install 之后紧跟一次 clean（首行另有一次开工前的 clean）
awk '/^install/ {
  if ((getline nxt) <= 0) { print "FAIL: install 之后没有剩余命令"; exit 1 }
  if (nxt != "clean") { print "FAIL: 装完没有 apt-get clean: " $0; exit 1 }
}' "$work/calls.log" || exit 1
updates=$(grep -c '^update' "$work/calls.log" || true)
[[ $updates == 1 ]] || { echo "FAIL: apt-get update 应调用一次，实际 $updates"; exit 1; }
awk '/^install/ {
  n = 0
  for (i = 1; i <= NF; i++)
    if ($i ~ /^(ca-certificates|curl|openssl|unzip|jq|iproute2|procps|busybox|nano)$/) n++
  if (n != 1) { print "FAIL: 一条命令装了多个包: " $0; exit 1 }
}' "$work/calls.log" || exit 1
grep -q 'Dpkg::Use-Pty=0' "$work/calls.log" || { echo 'FAIL: 安装命令缺少 Dpkg::Use-Pty=0'; exit 1; }

# 2b. 失败路径：给出报告并以非 0 退出
: > "$work/calls.log"
rc=0
APT_RC=100 APT_LOG="$work/calls.log" bash "$work/run.sh" > "$work/fail.log" 2>&1 || rc=$?
[[ $rc != 0 ]] || { echo 'FAIL: apt 失败后仍然退出 0'; exit 1; }
grep -q '依赖安装未完成' "$work/fail.log" || { cat "$work/fail.log"; echo 'FAIL: 失败时没有报告'; exit 1; }
grep -q '虚拟化' "$work/fail.log" || { cat "$work/fail.log"; echo 'FAIL: 失败报告缺少虚拟化信息'; exit 1; }
grep -qE '容器内无法自行加 swap|临时加 256 MB swap' "$work/fail.log" \
  || { cat "$work/fail.log"; echo 'FAIL: 失败报告缺少处置提示'; exit 1; }

# 2c. 磁盘不足：提示清楚，且不调用 apt-get install
: > "$work/calls.log"
rc=0
FAKE_AVAIL_KB=1000 APT_LOG="$work/calls.log" bash "$work/run.sh" > "$work/disk.log" 2>&1 || rc=$?
[[ $rc != 0 ]] || { echo 'FAIL: 磁盘不足仍然继续安装'; exit 1; }
grep -q '不足 150 MB' "$work/disk.log" || { cat "$work/disk.log"; echo 'FAIL: 磁盘不足没有明确提示'; exit 1; }
if grep -q '^install' "$work/calls.log"; then
  echo 'FAIL: 磁盘不足时不应尝试安装'
  cat "$work/calls.log"
  exit 1
fi

# 3. 提示默认值：内部端口回车等于公网端口，订阅内部端口回车等于 2096
sed -n '/^ask() {/,/^export SERVER_ADDRESS PUBLIC_PORT/p' "$entry" > "$work/ask.sh"
cat >> "$work/ask.sh" <<'EOF'
printf '%s\n' "$LISTEN_PORT" "$SUB_LISTEN_PORT"
EOF
out=$(env -u SERVER_ADDRESS -u PUBLIC_PORT -u LISTEN_PORT -u REALITY_DEST -u REALITY_SERVER_NAME -u SUB_PUBLIC_PORT -u SUB_LISTEN_PORT -u PLAN_TOTAL -u PLAN_RESET_DAY -u PLAN_EXPIRE bash "$work/ask.sh" <<< $'203.0.113.10\n28443\n\n\n\n28996\n\n\n\n\n')
[[ $out == $'28443\n2096' ]] || { echo "FAIL: 端口默认值不对: $out"; exit 1; }

echo 'PASS: 依赖逐个安装、失败报告、磁盘保护与端口默认值'
