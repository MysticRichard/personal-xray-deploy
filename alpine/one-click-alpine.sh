#!/usr/bin/env bash
# =============================================================================
#  personal-xray-deploy :: Alpine (musl / OpenRC / Podman) edition
#  ---------------------------------------------------------------------------
#  与 Debian 版 one-click.sh 对应，但：
#    * 只跑在 Alpine (musl) 上，用 apk 装依赖，不依赖 glibc、不依赖 systemd
#    * 守护进程用 OpenRC 的 supervise-daemon（崩溃自动拉起），兼容容器内运行
#    * 默认不解压 geoip.dat / geosite.dat（省 35MB 磁盘 + 十几 MB 内存）
#    * 针对 1C / 128MB / 1GB 的机器做了内存与磁盘约束
#
#  协议：VLESS + XTLS-Vision + REALITY（无域名、无证书、抗主动探测）
#
#  用法：
#    apk add bash curl           # Alpine 默认没有 bash
#    bash one-click-alpine.sh                      # 交互式安装
#    bash one-click-alpine.sh install --yes --server 1.2.3.4 --port 443 \
#         --target www.apple.com:443 --sni www.apple.com
#    bash one-click-alpine.sh status | restart | sub | verify | manage
#    bash one-click-alpine.sh uninstall [--force]
# =============================================================================
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2026.11.01-alpine2"
HAVE_SUPERVISOR=0

# 与 Debian 版一致的、已随 FlClash/mihomo 验证过的版本组合
XRAY_VERSION="v26.6.27"
XRAY_SHA256="b3e5902d06d6282fe53cfa2fc426058b9aeaa429b2c812e20887cd47f26d08bf"

BIN=/usr/local/bin/xray
CONFIG=/usr/local/etc/xray/config.json
STATE=/usr/local/etc/xray/client.json
ASSETS=/usr/local/share/xray
SUB_ETC=/etc/xray-sub
WEBROOT=/srv/sub
SUB_BIN=/usr/local/sbin/xray-sub
ADMIN_BIN=/usr/local/sbin/xray-admin
XRAY_INIT=/etc/init.d/xray
SUB_INIT=/etc/init.d/xray-sub
LOG_DIR=/var/log/xray

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
die()  { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mWARN\033[0m  %s\n' "$*" >&2; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n\033[36m==>\033[0m %s\n' "$*" >&2; }

valid_port() { [[ ${1:-} =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)); }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行（Alpine 上一般是 sudo -i 或 su -）"
}

is_alpine() { [[ -f /etc/alpine-release ]]; }

in_container() {
  [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
  grep -qaE '(docker|podman|containerd|lxc|kubepods)' /proc/1/cgroup 2>/dev/null
}

mkd()  { mkdir -p -- "$1" && chmod "$2" -- "$1"; }  # busybox 没有 install(1) 的完整语义
putf() { mkdir -p -- "$(dirname -- "$2")"; cp -f -- "$1" "$2"; chmod "$3" -- "$2"; }

svc_pidfile() { printf '/run/%s.pid' "$1"; }

svc_running() {
  local pf pid
  pf=$(svc_pidfile "$1")
  [[ -s $pf ]] || return 1
  pid=$(tr -d ' \r\n' < "$pf")
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

svc_start() {
  local name="$1"
  /etc/init.d/"$name" start >/dev/null 2>&1 || true
  sleep 2
  svc_running "$name" && return 0
  svc_fallback "$name"
}

# 容器里 openrc 状态目录缺失时，init 脚本可能起不来；用 su-exec 直启兜底
svc_fallback() {
  local name="$1" user cmd
  case "$name" in
    xray)     user="xray:xray";         cmd=/usr/local/sbin/xray-run.sh ;;
    xray-sub) user="xray-sub:xray-sub"; cmd=/usr/local/sbin/xray-sub-run.sh ;;
    *) return 1 ;;
  esac
  command -v su-exec >/dev/null 2>&1 || {
    warn "OpenRC 启动 $name 失败，且没有 su-exec 可兜底"
    return 1
  }
  warn "OpenRC 启动 $name 失败，改用 su-exec 直启（无崩溃自动重启）"
  nohup su-exec "$user" "$cmd" >/dev/null 2>&1 &
  echo $! > "$(svc_pidfile "$name")"
  sleep 2
  svc_running "$name"
}

svc_stop() { /etc/init.d/"$1" stop >/dev/null 2>&1 || true; sleep 1; }

svc_restart() {
  /etc/init.d/"$1" restart >/dev/null 2>&1 || true
  sleep 2
  svc_running "$1" && return 0
  svc_start "$1"
}

# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
用法：bash one-click-alpine.sh [命令] [选项]

命令（省略时=交互式安装）：
  install            安装 / 重装节点（保留已有密钥与订阅令牌）
  manage             打开管理菜单（装好后等价于 xray-admin）
  status             查看进程、端口、内存
  restart            校验配置后重启
  sub                显示订阅地址
  verify             用本地 socks 回环真实跑一次代理请求
  uninstall [--force] 卸载（保留 /etc/xray-sub 与备份）

选项（install）：
  --server IP_OR_HOST    公网地址（必填）
  --port PORT            代理公网端口，默认 443
  --listen-port PORT     代理内部监听端口，默认同 --port
  --target HOST:PORT     REALITY 目标，默认 www.apple.com:443
  --sni NAME             REALITY serverName，默认取 --target 的主机名
  --sub-port PORT        订阅内部监听端口，默认 2096
  --sub-public-port PORT 订阅公网端口，默认同 --sub-port
  --plan-total SIZE      月流量，如 200GB、0=不限
  --plan-reset-day N     每月重置日 1-28
  --plan-expire YYYY-MM-DD 到期日
  --with-geo             解压 geoip.dat 并在出站规则里阻断国内 IP
  --yes | --noninteractive 完全无人值守
  -h | --help            显示本帮助

示例：
  bash one-click-alpine.sh install --yes --server 104.223.38.32 --port 443 \
       --sub-port 2096 --plan-total 200GB --plan-reset-day 1
USAGE
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
COMMAND=""
ASSUME_YES=0
WITH_GEO=0
SERVER_ADDRESS="${SERVER_ADDRESS:-}"
PUBLIC_PORT="${PUBLIC_PORT:-}"
LISTEN_PORT="${LISTEN_PORT:-}"
REALITY_DEST="${REALITY_DEST:-}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-}"
SUB_LISTEN_PORT="${SUB_LISTEN_PORT:-}"
SUB_PUBLIC_PORT="${SUB_PUBLIC_PORT:-}"
PLAN_TOTAL="${PLAN_TOTAL:-0}"
PLAN_RESET_DAY="${PLAN_RESET_DAY:-0}"
PLAN_EXPIRE_IN="${PLAN_EXPIRE_IN:-}"

parse_args() {
  while (($#)); do
    case "$1" in
      install|manage|status|restart|sub|verify|uninstall) COMMAND="$1"; shift ;;
      --force) ASSUME_YES=1; shift ;;
      --yes|-y|--noninteractive) ASSUME_YES=1; shift ;;
      --with-geo) WITH_GEO=1; shift ;;
      --server) SERVER_ADDRESS="${2:-}"; shift 2 ;;
      --port) PUBLIC_PORT="${2:-}"; shift 2 ;;
      --listen-port) LISTEN_PORT="${2:-}"; shift 2 ;;
      --target) REALITY_DEST="${2:-}"; shift 2 ;;
      --sni) REALITY_SERVER_NAME="${2:-}"; shift 2 ;;
      --sub-port) SUB_LISTEN_PORT="${2:-}"; shift 2 ;;
      --sub-public-port) SUB_PUBLIC_PORT="${2:-}"; shift 2 ;;
      --plan-total) PLAN_TOTAL="${2:-}"; shift 2 ;;
      --plan-reset-day) PLAN_RESET_DAY="${2:-}"; shift 2 ;;
      --plan-expire) PLAN_EXPIRE_IN="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 交互询问
# ---------------------------------------------------------------------------
ask() {  # ask 变量名 提示 默认值
  local var="$1" prompt="$2" def="${3:-}" ans
  if ((ASSUME_YES)); then
    printf -v "$var" '%s' "$def"
    return 0
  fi
  [[ -t 0 ]] || die "标准输入不是终端；请用 --yes 并提供全部参数"
  if [[ -n $def ]]; then
    read -r -p "$prompt [$def]: " ans || exit 1
    ans=${ans:-$def}
  else
    read -r -p "$prompt: " ans || exit 1
  fi
  printf -v "$var" '%s' "$ans"
}

collect_answers() {
  [[ -n $SERVER_ADDRESS ]] || ask SERVER_ADDRESS 'VPS 公网 IP 或域名'
  [[ -n $PUBLIC_PORT ]]    || ask PUBLIC_PORT '代理公网端口' '443'
  [[ -n $LISTEN_PORT ]]    || LISTEN_PORT="$PUBLIC_PORT"
  [[ -n $REALITY_DEST ]]   || ask REALITY_DEST 'REALITY 目标 host:port' 'www.apple.com:443'
  if [[ -z $REALITY_SERVER_NAME ]]; then
    REALITY_SERVER_NAME="${REALITY_DEST%%:*}"
  fi
  [[ -n $SUB_LISTEN_PORT ]] || ask SUB_LISTEN_PORT '订阅内部端口' '2096'
  [[ -n $SUB_PUBLIC_PORT ]] || SUB_PUBLIC_PORT="$SUB_LISTEN_PORT"
  [[ $PLAN_TOTAL != 0 ]] || ask PLAN_TOTAL '月流量（如 200GB，0=不限）' '0'
  [[ $PLAN_RESET_DAY != 0 ]] || ask PLAN_RESET_DAY '每月重置日（1-28，0=不重置）' '0'
  [[ -n $PLAN_EXPIRE_IN ]] || ask PLAN_EXPIRE_IN '到期日 YYYY-MM-DD（留空=长期）' ''
}

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------
PLAN_TOTAL_BYTES=0
PLAN_EXPIRE_EPOCH=0
PLAN_EXPIRE_DATE=0

size_to_bytes() {
  local v="$1" num mult
  [[ $v == 0 ]] && { echo 0; return; }
  local u="${v^^}"
  if [[ $u =~ ^([0-9]+)(\.[0-9]+)?(B|KB|MB|GB|TB)$ ]]; then
    num="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    case "${BASH_REMATCH[3]}" in
      B)  mult=1 ;;
      KB) mult=1024 ;;
      MB) mult=1048576 ;;
      GB) mult=1073741824 ;;
      TB) mult=1099511627776 ;;
    esac
  elif [[ $u =~ ^[0-9]+$ ]]; then
    num="$u"; mult=1073741824   # 纯数字按 GB 处理
  else
    die "无法识别的流量大小：$v（例：200GB / 512MB / 0）"
  fi
  awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f", n * m }'
}

validate() {
  local host_re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'

  [[ -n $SERVER_ADDRESS && ${#SERVER_ADDRESS} -le 253 && $SERVER_ADDRESS =~ $host_re ]] \
    || die '--server 必须是 IPv4 或域名（不支持 IPv6 字面量）'
  valid_port "$PUBLIC_PORT" || die "非法公网端口：$PUBLIC_PORT"
  valid_port "$LISTEN_PORT" || die "非法监听端口：$LISTEN_PORT"
  valid_port "$SUB_LISTEN_PORT" || die "非法订阅端口：$SUB_LISTEN_PORT"
  valid_port "$SUB_PUBLIC_PORT" || die "非法订阅公网端口：$SUB_PUBLIC_PORT"
  ((10#$SUB_LISTEN_PORT >= 1024)) || die '订阅内部端口必须 >= 1024（订阅服务以非 root 用户运行）'
  [[ $SUB_LISTEN_PORT != "$LISTEN_PORT" ]] || die '订阅端口不能与代理监听端口相同'
  [[ $SUB_PUBLIC_PORT != "$PUBLIC_PORT" ]] || die '订阅公网端口不能与代理公网端口相同'

  [[ $REALITY_DEST =~ ^([A-Za-z0-9][A-Za-z0-9.-]*):([1-9][0-9]{0,4})$ ]] \
    || die '--target 必须形如 host:port'
  DEST_HOST="${BASH_REMATCH[1]}"
  DEST_PORT="${BASH_REMATCH[2]}"
  valid_port "$DEST_PORT" || die "非法目标端口：$DEST_PORT"
  [[ ${#REALITY_SERVER_NAME} -le 253 && $REALITY_SERVER_NAME =~ $host_re ]] \
    || die '--sni 不合法'
  [[ ${DEST_HOST,,} == "${REALITY_SERVER_NAME,,}" ]] \
    || die '单节点模板要求 target 主机名与 serverName 一致'

  PLAN_TOTAL_BYTES=$(size_to_bytes "$PLAN_TOTAL") \
    || die "无法识别的流量大小：$PLAN_TOTAL（例：200GB / 512MB / 0）"
  if [[ $PLAN_RESET_DAY != 0 ]]; then
    [[ $PLAN_RESET_DAY =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || die '--plan-reset-day 只能是 1-28'
  fi
  if [[ -n $PLAN_EXPIRE_IN ]]; then
    PLAN_EXPIRE_EPOCH=$(date -u -d "$PLAN_EXPIRE_IN" +%s 2>/dev/null) \
      || die "无法解析到期日：$PLAN_EXPIRE_IN（用 YYYY-MM-DD）"
    PLAN_EXPIRE_DATE="$PLAN_EXPIRE_IN"
  fi
}

# ---------------------------------------------------------------------------
# 预检
# ---------------------------------------------------------------------------
preflight() {
  need_root
  is_alpine || die "本脚本只支持 Alpine（当前系统没有 /etc/alpine-release）"
  [[ $(uname -m) == x86_64 ]] || die "脚本内置的校验和只对应 amd64"

  info "脚本版本 $SCRIPT_VERSION"
  info "Alpine $(cat /etc/alpine-release)"
  info "内核 $(uname -r) / $(uname -m)"
  if in_container; then
    info "运行环境：容器内（端口映射由宿主机负责）"
  fi

  local mem_kb avail_kb
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  info "内存：总计 $((mem_kb/1024))MB / 可用 $((avail_kb/1024))MB"
  ((mem_kb >= 96000)) || warn '可用内存偏小，Xray 已按 GOMEMLIMIT=48MiB 收紧，仍建议加 swap'

  local df_kb
  df_kb=$(df -Pk / | awk 'NR==2 {print $4}')
  info "根分区可用：$((df_kb/1024))MB"
  ((df_kb > 120000)) || die '根分区可用空间不足 120MB，装不下 xray 二进制与回滚副本'

  validate

  info "目标解析：$REALITY_DEST"
  local addrs
  addrs=$(timeout 10 getent ahosts "$DEST_HOST" 2>/dev/null | awk '{print $1}' | sort -u) || true
  [[ -n $addrs ]] || die "REALITY 目标 $DEST_HOST 解析失败"

  local addr bad=0
  while read -r addr; do
    [[ -n $addr ]] || continue
    case "$addr" in
      10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|0.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-2][0-9].*)
        bad=1; warn "目标解析到内网地址：$addr" ;;
    esac
  done <<< "$addrs"
  ((bad == 0)) || die 'REALITY 目标必须是公网地址'

  step "校验目标是否支持 TLS1.3 + h2（REALITY 的硬性前提）"
  local probe
  probe=$(timeout 20 openssl s_client -4 -connect "$REALITY_DEST" -servername "$REALITY_SERVER_NAME" \
            -tls1_3 -alpn h2 </dev/null 2>&1) || \
  probe=$(timeout 20 openssl s_client -connect "$REALITY_DEST" -servername "$REALITY_SERVER_NAME" \
            -tls1_3 -alpn h2 </dev/null 2>&1) || true

  if [[ $probe != *"ALPN protocol: h2"* ]]; then
    printf '%s\n' "$probe" | tail -8 >&2
    die "目标未协商出 h2；换一个支持 TLS1.3 + HTTP/2 的目标（例：www.apple.com:443）"
  fi
  info "TLS1.3 + h2 通过"

  [[ -f /usr/share/zoneinfo/UTC ]] || true
  if ! date -u >/dev/null 2>&1; then
    die 'date 命令异常，检查系统时间'
  fi
  local skew
  skew=$(timeout 15 curl -sS -I -o /dev/null -w '%{time_total}' https://www.apple.com 2>/dev/null) || true
  [[ -n $skew ]] || warn '外网 HTTPS 探测失败，若后续下载失败请检查网络'
  info "PASS: preflight"
}

# ---------------------------------------------------------------------------
# 依赖
# ---------------------------------------------------------------------------
install_deps() {
  local need=() pkg
  for pkg in curl openssl unzip jq ca-certificates iproute2 procps openrc su-exec; do
    apk info -e "$pkg" >/dev/null 2>&1 || need+=("$pkg")
  done
  if ((${#need[@]})) || ! command -v supervise-daemon >/dev/null 2>&1; then
    step "apk 安装依赖：${need[*]:-openrc}"
    apk add --no-cache --no-progress "${need[@]:-openrc}" >/dev/null 2>&1 \
      || die 'apk add 失败，检查 /etc/apk/repositories 与网络'
  fi
  for pkg in curl openssl unzip jq sha256sum timeout getent ss; do
    command -v "$pkg" >/dev/null 2>&1 || die "缺少命令：$pkg"
  done
  if command -v supervise-daemon >/dev/null 2>&1; then
    HAVE_SUPERVISOR=1
  else
    HAVE_SUPERVISOR=0
    warn '没有 supervise-daemon（openrc 组件），进程崩溃后不会自动拉起'
  fi
}

# ---------------------------------------------------------------------------
# 下载 Xray
# ---------------------------------------------------------------------------
# busybox 的 sha256sum 只有 -c，没有 --check/--status；
# 用它做 `sha256sum --check` 会直接失败，看起来就像"校验和不匹配"。
archive_sha256() {
  local f="$1" h
  h=$(sha256sum -- "$f" 2>/dev/null | awk 'NR==1 {print tolower($1)}') || return 1
  [[ -n $h ]] || return 1
  printf '%s\n' "$h"
}

verify_archive() {  # verify_archive <文件> <来源描述>
  local f="$1" label="${2:-下载文件}" got
  [[ -s $f ]] || { warn "$label 是空文件"; return 1; }

  # 镜像挂掉或被人插一层 HTML 错误页时，文件不是 zip，先挡掉
  if [[ $(head -c 2 -- "$f" 2>/dev/null) != PK ]]; then
    warn "$label 不是 zip（开头不是 PK），大概率是错误页或缓存劫持"
    return 1
  fi

  got=$(archive_sha256 "$f") || { warn "$label 无法计算 sha256"; return 1; }
  if [[ $got == "$XRAY_SHA256" ]]; then
    info "校验和通过 ${got:0:16}…"
    return 0
  fi
  warn "$label 校验和不匹配"
  warn "  期望 $XRAY_SHA256"
  warn "  实际 $got"
  return 1
}

download_release() {
  local out="$1"
  local release_path="XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip"
  local -a urls=()
  if [[ -n ${XRAY_URL:-} ]]; then
    urls=("$XRAY_URL")
  else
    urls=(
      "https://github.com/$release_path"
      "https://ghfast.top/https://github.com/$release_path"
      "https://gh-proxy.com/https://github.com/$release_path"
      "https://ghproxy.net/https://github.com/$release_path"
    )
  fi

  if [[ -n ${XRAY_ARCHIVE:-} ]]; then
    [[ -f $XRAY_ARCHIVE ]] || die "XRAY_ARCHIVE 不存在：$XRAY_ARCHIVE"
    cp -f -- "$XRAY_ARCHIVE" "$out" || die "复制 $XRAY_ARCHIVE 失败"
    verify_archive "$out" "本地包 $XRAY_ARCHIVE" \
      || die 'XRAY_ARCHIVE 校验和不匹配，已中止（防止被投毒）'
    return 0
  else
    local best_url="" best_speed=0 url probe code speed
    for url in "${urls[@]}"; do
      probe=$(curl -sSL --range 0-262143 --max-time 8 --connect-timeout 5 \
                -o /dev/null -w '%{http_code} %{speed_download}' "$url" 2>/dev/null) || continue
      code=${probe%% *}
      speed=${probe##* }
      [[ $code == 200 || $code == 206 ]] || continue
      if [[ -z $best_url ]] || awk -v s="$speed" -v b="$best_speed" 'BEGIN { exit !(s > b) }'; then
        best_url=$url; best_speed=$speed
      fi
    done
    [[ -n $best_url ]] || best_url="${urls[0]}"
    info "下载源：$best_url（探测 ${best_speed%.*} B/s）"

    local -a tries=("$best_url")
    for url in "${urls[@]}"; do
      [[ $url == "$best_url" ]] || tries+=("$url")
    done

    local ok=0
    for url in "${tries[@]}"; do
      rm -f "$out"
      if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
             --connect-timeout 15 --max-time 600 --speed-time 60 --speed-limit 1024 \
             "$url" -o "$out"; then
        warn "下载失败：$url"
        continue
      fi
      verify_archive "$out" "$url" && { ok=1; break; }
      warn "换下一个源重试"
    done
    ((ok)) || die '所有下载源都失败或校验和不匹配；可设置 XRAY_ARCHIVE=/path/to.zip 离线安装'
  fi
}

# ---------------------------------------------------------------------------
# 渲染服务端配置
# ---------------------------------------------------------------------------
render_config() {
  local out="$1" ips
  # geoip:private 是内置关键字，不需要 geoip.dat；geoip:cn 需要数据文件
  ips='"geoip:private","0.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","224.0.0.0/4","240.0.0.0/4","::1/128","fc00::/7","fe80::/10","ff00::/8"'
  if ((WITH_GEO)) && [[ -s $ASSETS/geoip.dat ]]; then
    ips="\"geoip:cn\",$ips"
  fi

  cat > "$out" <<JSON
{
  "log": {"access": "none", "loglevel": "warning"},
  "inbounds": [{
    "tag": "personal",
    "listen": "0.0.0.0",
    "port": $LISTEN_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$CLIENT_UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "$REALITY_DEST",
        "xver": 0,
        "serverNames": ["$REALITY_SERVER_NAME"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {"type": "field", "ip": [$ips], "outboundTag": "block"},
      {"type": "field", "network": "tcp,udp", "port": "25,465,587,137-139,445", "outboundTag": "block"},
      {"type": "field", "inboundTag": ["personal"], "outboundTag": "direct"}
    ]
  }
}
JSON
}

# ---------------------------------------------------------------------------
# 用户
# ---------------------------------------------------------------------------
ensure_user() {  # ensure_user <name>
  local u="$1"
  getent group "$u" >/dev/null 2>&1 || addgroup -S "$u" || die "创建组 $u 失败"
  id "$u" >/dev/null 2>&1 || adduser -S -D -H -h /nonexistent -s /sbin/nologin -G "$u" "$u" \
    || die "创建用户 $u 失败"
  [[ $(id -u "$u") -ne 0 ]] || die "$u 不能是 root"
}

# ---------------------------------------------------------------------------
# OpenRC 服务脚本
# ---------------------------------------------------------------------------
write_launchers() {
  local sub_port="$1"
  mkdir -p /usr/local/sbin

  # exec 保持 pid 不变，输出重定向进日志；这样 supervise-daemon 与
  # start-stop-daemon 两种模式行为一致，也不会丢日志。
  cat > /usr/local/sbin/xray-run.sh <<'RUN'
#!/bin/sh
exec /usr/local/bin/xray run -config /usr/local/etc/xray/config.json >> /var/log/xray/xray.log 2>&1
RUN
  chmod 755 /usr/local/sbin/xray-run.sh

  cat > /usr/local/sbin/xray-sub-run.sh <<RUN
#!/bin/sh
exec /bin/busybox httpd -f -p 0.0.0.0:${sub_port} -h /srv/sub >> /var/log/xray/xray-sub.log 2>&1
RUN
  chmod 755 /usr/local/sbin/xray-sub-run.sh

  : > "$LOG_DIR/xray.log"
  : > "$LOG_DIR/xray-sub.log"
  chown xray:xray "$LOG_DIR/xray.log" 2>/dev/null || true
  chown xray-sub:xray-sub "$LOG_DIR/xray-sub.log" 2>/dev/null || true
  chmod 640 "$LOG_DIR/xray.log" "$LOG_DIR/xray-sub.log"
}

write_xray_init() {
  {
    printf '%s\n' '#!/sbin/openrc-run'
    printf '%s\n' 'description="Personal Xray node (VLESS + REALITY)"'
    printf '%s\n' 'command="/usr/local/sbin/xray-run.sh"'
    printf '%s\n' 'command_user="xray:xray"'
    printf '%s\n' 'pidfile="/run/xray.pid"'
    if ((HAVE_SUPERVISOR)); then
      printf '%s\n' 'supervisor="supervise-daemon"'
      printf '%s\n' 'respawn_delay=5'
      printf '%s\n' 'respawn_max=0'
    else
      printf '%s\n' 'command_background=true'
    fi
    printf '%s\n' 'export XRAY_LOCATION_ASSET="/usr/local/share/xray"'
    printf '%s\n' 'export GOMEMLIMIT="48MiB"'
    printf '%s\n' 'export GOGC="30"'
    printf '%s\n' 'depend() {'
    printf '\t# 容器里没有 netifrc，"need net" 会直接卡住启动，这里只用 after\n'
    printf '\tafter net localmount firewall\n'
    printf '\tuse logger\n'
    printf '}'
  } > "$XRAY_INIT"
  chmod 755 "$XRAY_INIT"
}

write_sub_init() {
  {
    printf '%s\n' '#!/sbin/openrc-run'
    printf '%s\n' 'description="Personal Clash subscription (busybox httpd)"'
    printf '%s\n' 'command="/usr/local/sbin/xray-sub-run.sh"'
    printf '%s\n' 'command_user="xray-sub:xray-sub"'
    printf '%s\n' 'pidfile="/run/xray-sub.pid"'
    if ((HAVE_SUPERVISOR)); then
      printf '%s\n' 'supervisor="supervise-daemon"'
      printf '%s\n' 'respawn_delay=5'
      printf '%s\n' 'respawn_max=0'
    else
      printf '%s\n' 'command_background=true'
    fi
    printf '%s\n' 'depend() {'
    printf '\tafter net localmount\n'
    printf '\tuse logger\n'
    printf '}'
  } > "$SUB_INIT"
  chmod 755 "$SUB_INIT"
}

enable_service() {
  local name="$1"
  if command -v rc-update >/dev/null 2>&1 && [[ -d /etc/runlevels/default ]]; then
    rc-update add "$name" default >/dev/null 2>&1 || true
  fi
  # 容器里没有 openrc-init 时，用 Alpine 的 local 服务兜底开机自启
  if in_container; then
    mkd /etc/local.d 755
    printf '#!/bin/sh\n/etc/init.d/%s start\n' "$name" > "/etc/local.d/90-$name.start"
    chmod 755 "/etc/local.d/90-$name.start"
    rc-update add local default >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# 订阅服务（busybox httpd + CGI）
# ---------------------------------------------------------------------------
install_sub_renderer() {
  cat > "$SUB_BIN" <<'SUB'
#!/usr/bin/env bash
# 由 one-click-alpine.sh 安装：把 client.json 渲染成 Clash 订阅
set -Eeuo pipefail
umask 027

STATE=/usr/local/etc/xray/client.json
TOKEN_FILE=/etc/xray-sub/token
SUB_PORT_FILE=/etc/xray-sub/port
USERINFO=/etc/xray-sub/userinfo
RULES=/etc/xray-sub/rules.yaml
WEBROOT=/srv/sub

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f $STATE ]] || die "缺少 $STATE，请先安装 Xray"
[[ -s $TOKEN_FILE ]] || die "缺少 $TOKEN_FILE"
command -v jq >/dev/null || die '缺少 jq（apk add jq）'

TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
[[ $TOKEN =~ ^[A-Za-z0-9_-]{16,64}$ ]] || die '订阅令牌格式不正确'

uuid=$(jq -er .uuid "$STATE")
pub=$(jq -er .public_key "$STATE")
sid=$(jq -er .short_id "$STATE")
server=$(jq -er .server "$STATE")
port=$(jq -er .port "$STATE")
sni=$(jq -er .server_name "$STATE")
[[ $uuid =~ ^[0-9a-fA-F-]{36}$ ]] || die '状态文件里的 UUID 不正确'
[[ ${#pub} -ge 40 && ${#sid} -ge 1 ]] || die '状态文件里的 REALITY 密钥不正确'

out_dir="$WEBROOT/$TOKEN"
mkdir -p "$WEBROOT/cgi-bin" "$out_dir"
chmod 755 "$WEBROOT" "$WEBROOT/cgi-bin" "$out_dir"

tmp=$(mktemp "$out_dir/.config.XXXXXX")
cgi_tmp=$(mktemp "$WEBROOT/cgi-bin/.cgi.XXXXXX")
trap 'rm -f "$tmp" "$cgi_tmp"' EXIT

# 规则来源：优先用户自定义，否则内置精简规则
if [[ -s $RULES ]]; then
  rules_src="$RULES"
else
  rules_src=$(mktemp)
  trap 'rm -f "$tmp" "$cgi_tmp" "$rules_src"' EXIT
  cat > "$rules_src" <<'R'
- IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
- IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
- IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
- IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
- IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
- DOMAIN-SUFFIX,local,DIRECT
- MATCH,PROXY
R
fi

count=0; matches=0; last=""
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
  [[ $line == '- '* ]] || die "规则格式错误（应以 \"- \" 开头）：$line"
  payload=${line#- }
  [[ $payload == *,* ]] || die "规则缺少参数：$payload"
  [[ ${payload%%,*} =~ ^[A-Z0-9_-]+$ ]] || die "规则类型不合法：$payload"
  [[ $payload == 'MATCH,PROXY' ]] && matches=$((matches + 1))
  count=$((count + 1)); last="$payload"
done < "$rules_src"
((count > 0)) || die '规则为空'
((matches == 1)) || die '规则里必须且只能有一条 MATCH,PROXY'
[[ $last == 'MATCH,PROXY' ]] || die 'MATCH,PROXY 必须是最后一条'

{
  cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
  default-nameserver:
    - 223.5.5.5
    - 1.1.1.1
  nameserver:
    - https://223.5.5.5/dns-query
  fallback:
    - 'https://1.1.1.1/dns-query#PROXY'
    - 'https://8.8.8.8/dns-query#PROXY'

proxies:
  - name: "Personal-VPS"
    type: vless
    server: "$server"
    port: $port
    uuid: "$uuid"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    servername: "$sni"
    reality-opts:
      public-key: "$pub"
      short-id: "$sid"

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "Personal-VPS"
      - DIRECT

rules:
EOF
  grep -v -E '^[[:space:]]*(#|$)' "$rules_src"
} > "$tmp"

grep -q 'Personal-VPS' "$tmp" || die '生成的订阅缺少节点'
[[ $(wc -c < "$tmp") -gt 400 ]] || die '生成的订阅过小'

chmod 644 "$tmp"
mv -f "$tmp" "$out_dir/config.yaml"

cat > "$cgi_tmp" <<CGI
#!/bin/sh
set -eu
printf 'Content-Type: text/yaml; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
if [ -s "$USERINFO" ]; then
  quota=\$(/bin/cat "$USERINFO")
  if printf '%s\n' "\$quota" | /bin/busybox awk 'NR==1 && /^upload=[0-9]+; download=[0-9]+; total=[0-9]+; expire=[0-9]+\$/ {ok=1} NR>1 {ok=0} END {exit ok?0:1}'; then
    printf 'Subscription-Userinfo: %s\r\n' "\$quota"
  fi
fi
printf 'Profile-Update-Interval: 24\r\n\r\n'
exec /bin/cat "$out_dir/config.yaml"
CGI
chmod 755 "$cgi_tmp"
mv -f "$cgi_tmp" "$WEBROOT/cgi-bin/$TOKEN"

# 清理换过令牌的旧产物
for old_dir in "$WEBROOT"/*; do
  [[ -d $old_dir && $old_dir != "$out_dir" ]] || continue
  old_name=${old_dir##*/}
  [[ $old_name =~ ^[A-Za-z0-9_-]{16,64}$ ]] || continue
  rm -f -- "$old_dir/config.yaml"
  rmdir -- "$old_dir" 2>/dev/null || true
done
for old_cgi in "$WEBROOT/cgi-bin"/*; do
  [[ -f $old_cgi ]] || continue
  old_name=${old_cgi##*/}
  [[ $old_name =~ ^[A-Za-z0-9_-]{16,64}$ && $old_name != "$TOKEN" ]] || continue
  rm -f -- "$old_cgi"
done

sport=$(tr -d '\r\n' < "$SUB_PORT_FILE" 2>/dev/null || echo 2096)
printf '订阅文件已生成：%s/config.yaml\n' "$out_dir"
printf '规则条数：%s\n' "$((count))"
printf '本地地址：http://127.0.0.1:%s/cgi-bin/%s\n' "${sport:-2096}" "$TOKEN"
SUB
  chmod 755 "$SUB_BIN"
}

setup_subscription() {
  local sub_port="$SUB_LISTEN_PORT"

  step "准备订阅服务"
  mkd "$SUB_ETC" 750
  mkd /srv 755          # umask 077 下 mkdir -p 会把 /srv 建成 700，httpd 就进不去
  mkd "$WEBROOT" 755
  mkd "$LOG_DIR" 755

  [[ -s $SUB_ETC/token ]] || openssl rand -hex 16 > "$SUB_ETC/token"
  chmod 600 "$SUB_ETC/token"
  local token
  token=$(tr -d '\r\n' < "$SUB_ETC/token")

  printf '%s\n' "$sub_port" > "$SUB_ETC/port"
  printf '%s\n' "$SUB_PUBLIC_PORT" > "$SUB_ETC/public_port"
  chmod 644 "$SUB_ETC/port" "$SUB_ETC/public_port"

  {
    printf 'total_display=%s\n' "$PLAN_TOTAL"
    printf 'total_bytes=%s\n' "$PLAN_TOTAL_BYTES"
    printf 'reset_day=%s\n' "$PLAN_RESET_DAY"
    printf 'expire_date=%s\n' "$PLAN_EXPIRE_DATE"
    printf 'expire_epoch=%s\n' "$PLAN_EXPIRE_EPOCH"
  } > "$SUB_ETC/provider-plan"
  chmod 600 "$SUB_ETC/provider-plan"

  ensure_user xray-sub
  write_launchers "$sub_port"
  chown root:xray-sub "$SUB_ETC" 2>/dev/null || true
  chmod 750 "$SUB_ETC"

  # 首次安装写入额度快照；重装不覆盖已有统计
  if [[ ! -f $SUB_ETC/userinfo ]] && (( PLAN_TOTAL_BYTES > 0 || PLAN_EXPIRE_EPOCH > 0 )); then
    printf 'upload=0; download=0; total=%s; expire=%s\n' "$PLAN_TOTAL_BYTES" "$PLAN_EXPIRE_EPOCH" \
      > "$SUB_ETC/userinfo"
  fi
  if [[ -f $SUB_ETC/userinfo ]]; then
    chown root:xray-sub "$SUB_ETC/userinfo" 2>/dev/null || true
    chmod 640 "$SUB_ETC/userinfo"
  fi

  install_sub_renderer
  "$SUB_BIN" >/dev/null || die '订阅生成失败'

  write_sub_init
  enable_service xray-sub

  svc_stop xray-sub
  svc_start xray-sub || {
    tail -n 20 "$LOG_DIR/xray-sub.log" >&2 2>/dev/null || true
    die '订阅服务未能启动'
  }

  curl -fsS --max-time 5 "http://127.0.0.1:${sub_port}/cgi-bin/${token}" -o /dev/null \
    || die '订阅本地自检失败'

  printf '\n%s\n' '============================================================'
  printf '%s\n' ' 订阅地址（粘到 FlClash 的订阅栏）：'
  printf '\n   http://%s:%s/cgi-bin/%s\n\n' "$SERVER_ADDRESS" "$SUB_PUBLIC_PORT" "$token"
  printf '%s\n' " 说明：公网 $SUB_PUBLIC_PORT 需由平台/防火墙映射到实例的 $sub_port"
  printf '%s\n' " 规则文件：$SUB_ETC/rules.yaml（不存在则用内置精简规则）"
  printf '%s\n' " 额度文件：$SUB_ETC/userinfo（xray-admin 菜单可改）"
  printf '%s\n' " 随时查看：xray-admin --sub"
  printf '%s\n' '============================================================'
}

# ---------------------------------------------------------------------------
# 管理脚本
# ---------------------------------------------------------------------------
install_admin() {
  cat > "$ADMIN_BIN" <<'ADMIN'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '请用 root 执行'; exit 1; }

BIN=/usr/local/bin/xray
CONFIG=/usr/local/etc/xray/config.json
STATE=/usr/local/etc/xray/client.json
SUB_ETC=/etc/xray-sub
LOG_DIR=/var/log/xray
SUB_BIN=/usr/local/sbin/xray-sub

svc_running() {
  local pf="/run/$1.pid" pid
  [[ -s $pf ]] || return 1
  pid=$(tr -d ' \r\n' < "$pf")
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}
svc_start() {
  /etc/init.d/"$1" start >/dev/null 2>&1 || true
  sleep 2
  svc_running "$1" && return 0
  local user cmd
  case "$1" in
    xray)     user="xray:xray";         cmd=/usr/local/sbin/xray-run.sh ;;
    xray-sub) user="xray-sub:xray-sub"; cmd=/usr/local/sbin/xray-sub-run.sh ;;
    *) return 1 ;;
  esac
  command -v su-exec >/dev/null 2>&1 || return 1
  echo "OpenRC 启动失败，改用 su-exec 直启 $1"
  nohup su-exec "$user" "$cmd" >/dev/null 2>&1 &
  echo $! > "/run/$1.pid"
  sleep 2
  svc_running "$1"
}
svc_stop()    { /etc/init.d/"$1" stop    >/dev/null 2>&1 || true; }
svc_restart() { /etc/init.d/"$1" restart >/dev/null 2>&1 || true; sleep 2; svc_running "$1" || svc_start "$1"; }

sub_url() {
  [[ -f $STATE && -s $SUB_ETC/token ]] || { echo '尚未配置订阅'; return 1; }
  local server token pubp
  server=$(jq -er .server "$STATE")
  token=$(tr -d '\r\n' < "$SUB_ETC/token")
  pubp=$(tr -d '\r\n' < "$SUB_ETC/public_port" 2>/dev/null || echo 2096)
  printf 'http://%s:%s/cgi-bin/%s\n' "$server" "$pubp" "$token"
}

show_plan() {
  [[ -f $SUB_ETC/provider-plan ]] || { echo '套餐：未记录'; return 1; }
  local total reset expire
  total=$(sed -n 's/^total_display=//p' "$SUB_ETC/provider-plan")
  reset=$(sed -n 's/^reset_day=//p' "$SUB_ETC/provider-plan")
  expire=$(sed -n 's/^expire_date=//p' "$SUB_ETC/provider-plan")
  echo "月流量：${total:-未记录}"
  [[ $reset == 0 || -z $reset ]] && echo '重置日：无固定重置日' || echo "重置日：每月 ${reset} 日"
  [[ $expire == 0 || -z $expire ]] && echo '到期日：长期有效' || echo "到期日：${expire}"
}

show_sub() {
  echo
  echo '订阅地址（复制到 FlClash 订阅栏）：'
  sub_url || return 1
  echo
  echo "规则文件：$SUB_ETC/rules.yaml"
  [[ -f $SUB_ETC/rules.yaml ]] && echo "通用规则：$(grep -c '^- ' "$SUB_ETC/rules.yaml" 2>/dev/null || echo 0) 条" \
                               || echo '通用规则：使用内置精简规则'
  show_plan || true
  echo '注意：订阅链接里的令牌控制访问，但 HTTP 不加密传输。'
  svc_running xray-sub && echo '订阅服务：运行中' || echo '订阅服务：未运行'
}

status() {
  echo "--- xray ---"
  svc_running xray && echo '进程：运行中' || echo '进程：未运行'
  local pid mem
  pid=$(tr -d ' \r\n' < /run/xray.pid 2>/dev/null || true)
  if [[ -n $pid && -r /proc/$pid/status ]]; then
    mem=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")
    echo "RSS：$((mem/1024))MB"
  fi
  echo "--- 订阅 ---"
  svc_running xray-sub && echo '进程：运行中' || echo '进程：未运行'
  echo "--- 监听 ---"
  ss -lntp 2>/dev/null | awk 'NR==1 || /xray|busybox/' || ss -lnt
  echo "--- 内存 ---"
  free -m 2>/dev/null || awk '/MemTotal|MemAvailable/ {print}' /proc/meminfo
  echo "--- 磁盘 ---"
  df -h / 2>/dev/null | tail -2
}

logs() { tail -n 40 "$LOG_DIR/xray.log" 2>/dev/null || echo '暂无日志'; }

check_config() {
  XRAY_LOCATION_ASSET=/usr/local/share/xray "$BIN" run -test -config "$CONFIG"
}

restart() {
  if ! check_config; then echo '配置检查失败，未重启'; return 1; fi
  if svc_restart xray; then echo '已重启，进程正常'; else echo '重启失败，请看日志'; return 1; fi
}

set_quota() {
  local f=$SUB_ETC/userinfo backup="" tmp up down total expire
  local pt=0 pe=0
  [[ -f $SUB_ETC/provider-plan ]] || { mkdir -p "$SUB_ETC"; : > "$SUB_ETC/provider-plan"; chmod 600 "$SUB_ETC/provider-plan"; }
  pt=$(sed -n 's/^total_bytes=//p' "$SUB_ETC/provider-plan"); pt=${pt:-0}
  pe=$(sed -n 's/^expire_epoch=//p' "$SUB_ETC/provider-plan"); pe=${pe:-0}
  echo '设置客户端显示的用量。这是手动快照，不会自动统计或限速。'
  read -r -p '已上传字节数 [0]: ' up; up=${up:-0}
  read -r -p '已下载字节数 [0]: ' down; down=${down:-0}
  read -r -p "总流量字节数（0=不限） [$pt]: " total; total=${total:-$pt}
  read -r -p "到期时间戳（0=长期） [$pe]: " expire; expire=${expire:-$pe}
  local v
  for v in "$up" "$down" "$total" "$expire"; do
    [[ $v =~ ^[0-9]+$ ]] || { echo '只接受非负整数'; return 1; }
  done
  [[ -f $f ]] && { backup=$(mktemp); cp -p "$f" "$backup"; }
  tmp=$(mktemp)
  printf 'upload=%s; download=%s; total=%s; expire=%s\n' "$up" "$down" "$total" "$expire" > "$tmp"
  chown root:xray-sub "$tmp" 2>/dev/null || true
  chmod 640 "$tmp"
  mv -f "$tmp" "$f"
  if ! "$SUB_BIN" >/dev/null; then
    [[ -n $backup ]] && cp -p "$backup" "$f" || rm -f "$f"
    echo '重新生成失败，已回滚'; return 1
  fi
  [[ -n $backup ]] && rm -f "$backup"
  echo '已保存，FlClash 下拉刷新即可看到。'
}

edit_rules() {
  local target=$SUB_ETC/rules.yaml backup
  if [[ ! -f $target ]]; then
    echo '当前使用内置规则。要自定义就先创建一份模板：'
    cp "$SUB_ETC/rules.builtin" "$target" 2>/dev/null || {
      cat > "$target" <<'R'
# 每行一条 Clash 规则，最后一行必须是 MATCH,PROXY
- IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
- MATCH,PROXY
R
    }
    echo "已创建 $target"
  fi
  backup="$SUB_ETC/rules.yaml.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$target" "$backup"
  "${EDITOR:-vi}" "$target" || { echo '编辑异常'; return 1; }
  if "$SUB_BIN"; then echo '已重新生成，FlClash 里下拉刷新'; else cp -p "$backup" "$target"; echo '生成失败，已回滚'; return 1; fi
}

export_sub_info() {
  local out=/root/xray-subscription.txt
  {
    echo '# 个人 Xray 订阅信息'
    echo "# 生成时间：$(date -u '+%Y-%m-%d %H:%M UTC')"
    echo
    echo '## 订阅地址'
    sub_url
    echo
    echo '## 端口'
    echo "代理端口：$(jq -er .port "$STATE" 2>/dev/null || echo 未知)"
    echo "订阅端口：$(tr -d '\r\n' < "$SUB_ETC/public_port" 2>/dev/null || echo 未知)"
    echo
    echo '## 套餐'
    show_plan || true
  } > "$out"
  chmod 600 "$out"
  echo "已生成：$out（这文件等同凭据，请下载到本机保存）"
}

backup_all() {
  local file="/root/xray-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  local paths=(usr/local/etc/xray usr/local/sbin/xray-admin usr/local/sbin/xray-sub etc/xray-sub etc/init.d/xray etc/init.d/xray-sub usr/local/bin/xray srv/sub)
  local existing=() p
  for p in "${paths[@]}"; do [[ -e /$p ]] && existing+=("$p"); done
  tar -czf "$file" -C / "${existing[@]}"
  chmod 600 "$file"
  echo "备份：$file"
}

uninstall() {
  local force=${1:-0} answer
  if ((force == 0)); then
    read -r -p '将停止并删除 Xray 与订阅服务（保留 /etc/xray-sub）。输入 yes 继续: ' answer || return 1
    [[ $answer == yes ]] || { echo '已取消'; return 1; }
  fi
  svc_stop xray-sub; svc_stop xray
  rc-update del xray default >/dev/null 2>&1 || true
  rc-update del xray-sub default >/dev/null 2>&1 || true
  rm -f /etc/local.d/90-xray.start /etc/local.d/90-xray-sub.start
  rm -f /etc/init.d/xray /etc/init.d/xray-sub /usr/local/bin/xray \
        /usr/local/sbin/xray-admin /usr/local/sbin/xray-sub
  rm -rf /usr/local/etc/xray /usr/local/share/xray /srv/sub /var/log/xray
  echo '已卸载；/etc/xray-sub 与 /root 下的备份保留。'
}

case "${1:-}" in
  --sub) show_sub; exit 0 ;;
  --plan) show_plan; exit 0 ;;
  --status) status; exit 0 ;;
  --restart) restart; exit 0 ;;
  --uninstall) uninstall 0; exit 0 ;;
  --uninstall-force) uninstall 1; exit 0 ;;
esac

while true; do
  cat <<'MENU'

个人 Xray 管理（Alpine / OpenRC）
   1. 状态、端口、内存
   2. 最近日志
   3. 检查配置并重启
   4. 查看订阅地址
   5. 编辑通用规则（rules.yaml）
   6. 重新生成订阅
   7. 设置流量额度（客户端显示）
   8. 导出订阅信息到文件
   9. 备份
  10. 导出客户端节点 JSON
  11. 套餐信息
  12. 卸载
   0. 退出
MENU
  read -r -p '选择: ' option || exit 0
  case $option in
    1) status ;;
    2) logs ;;
    3) restart || true ;;
    4) show_sub || true ;;
    5) edit_rules || true ;;
    6) "$SUB_BIN" && echo '已重新生成' || echo '生成失败' ;;
    7) set_quota || true ;;
    8) export_sub_info || true ;;
    9) backup_all || true ;;
    10) mkdir -p /root/xray-client && chmod 700 /root/xray-client
        jq '{proxies:[{name:"Personal-VPS",type:"vless",server:.server,port:.port,uuid:.uuid,network:"tcp",tls:true,udp:true,flow:"xtls-rprx-vision","client-fingerprint":"chrome",servername:.server_name,"reality-opts":{"public-key":.public_key,"short-id":.short_id}}]}' \
          "$STATE" > /root/xray-client/node.json
        chmod 600 /root/xray-client/node.json
        echo '已导出 /root/xray-client/node.json' ;;
    11) show_plan || true ;;
    12) uninstall 0 || true ;;
    0) exit 0 ;;
    *) echo '无效选项' ;;
  esac
done
ADMIN
  chmod 700 "$ADMIN_BIN"
}

# ---------------------------------------------------------------------------
# 安装主流程
# ---------------------------------------------------------------------------
do_install() {
  collect_answers
  need_root
  is_alpine || die "本脚本只支持 Alpine（当前系统没有 /etc/alpine-release）"
  install_deps          # 依赖先装好，后面的 openssl/curl 预检才有工具可用
  preflight

  local stage backup
  # Alpine 的 /tmp 是 tmpfs（吃内存）：21MB 包 + 37MB 解压 ≈ 58MB，128MB 机器会 OOM
  mkd /var/tmp 1777 2>/dev/null || true
  stage=$(mktemp -d /var/tmp/xray-stage.XXXXXX 2>/dev/null) \
    || stage=$(mktemp -d /tmp/xray-stage.XXXXXX)
  backup="/root/xray-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkd /root/xray-backups 700
  mkdir -p "$backup"
  chmod 700 "$backup"

  cleanup_stage() { rm -rf "$stage"; }
  trap cleanup_stage EXIT

  # 备份现有安装，失败时能回到原样
  local p
  for p in "$CONFIG" "$STATE" "$BIN" "$XRAY_INIT" "$SUB_INIT" "$ADMIN_BIN" "$SUB_BIN"; do
    [[ -e $p ]] && cp -a "$p" "$backup/$(basename "$p")" 2>/dev/null || true
  done
  [[ -d $SUB_ETC ]] && cp -a "$SUB_ETC" "$backup/xray-sub-etc" 2>/dev/null || true

  step "1/7 下载 Xray $XRAY_VERSION"
  download_release "$stage/core.zip"

  step "2/7 解压"
  if ((WITH_GEO)); then
    unzip -q -j "$stage/core.zip" xray geoip.dat -d "$stage/core"
  else
    unzip -q -j "$stage/core.zip" xray -d "$stage/core"
  fi
  rm -f "$stage/core.zip"
  chmod 755 "$stage/core/xray"
  local ver
  ver=$("$stage/core/xray" version 2>/dev/null | head -1 || true)
  [[ -n $ver ]] || die '下载的 xray 无法执行（架构不对或 musl 不兼容）'
  info "$ver"

  step "3/7 生成或复用密钥"
  if [[ -f $STATE ]] && jq -e .uuid "$STATE" >/dev/null 2>&1; then
    CLIENT_UUID=$(jq -er .uuid "$STATE")
    PRIVATE_KEY=$(jq -er .private_key "$STATE")
    PUBLIC_KEY=$(jq -er .public_key "$STATE")
    SHORT_ID=$(jq -er .short_id "$STATE")
    info "复用已有节点身份（UUID 不变，客户端无需重新导入）"
  else
    CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 8)
    local keys
    keys=$("$stage/core/xray" x25519)
    PRIVATE_KEY=$(printf '%s\n' "$keys" | awk -F': *' '/^(PrivateKey|Private key):/ {print $2; exit}')
    PUBLIC_KEY=$(printf '%s\n' "$keys" | awk -F': *' '/^(Password \(PublicKey\)|Password|PublicKey|Public key):/ {print $2; exit}')
    [[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || die 'REALITY 密钥生成失败'
    info "新节点身份：UUID=${CLIENT_UUID:0:8}… shortId=$SHORT_ID"
  fi

  step "4/7 渲染并校验配置"
  mkd "$ASSETS" 755
  if ((WITH_GEO)); then
    putf "$stage/core/geoip.dat" "$ASSETS/geoip.dat" 644
  fi
  render_config "$stage/config.json"
  XRAY_LOCATION_ASSET="$stage/core" "$stage/core/xray" run -test -config "$stage/config.json" \
    || die '配置校验失败'

  step "5/7 安装文件"
  ensure_user xray
  ensure_user xray-sub
  mkd /usr/local/etc/xray 750
  mkd "$LOG_DIR" 755
  chown -R xray:xray "$LOG_DIR" 2>/dev/null || true
  write_launchers "$SUB_LISTEN_PORT"

  putf "$stage/core/xray" "$BIN" 755
  putf "$stage/config.json" "$CONFIG" 640
  chown root:xray "$CONFIG" 2>/dev/null || true

  jq -n --arg uuid "$CLIENT_UUID" --arg private_key "$PRIVATE_KEY" \
        --arg public_key "$PUBLIC_KEY" --arg short_id "$SHORT_ID" \
        --arg server "$SERVER_ADDRESS" --argjson port "$PUBLIC_PORT" \
        --argjson listen_port "$LISTEN_PORT" --arg server_name "$REALITY_SERVER_NAME" \
        --arg reality_dest "$REALITY_DEST" \
        '{uuid:$uuid,private_key:$private_key,public_key:$public_key,short_id:$short_id,
          server:$server,port:$port,listen_port:$listen_port,server_name:$server_name,
          reality_dest:$reality_dest}' > "$stage/client.json"
  putf "$stage/client.json" "$STATE" 600

  write_xray_init
  enable_service xray
  install_admin

  step "6/7 启动代理"
  svc_stop xray
  local attempt ok=0
  for attempt in 1 2 3; do
    svc_start xray && { ok=1; break; }
    warn "启动失败（第 $attempt 次），2 秒后重试"
    sync; sleep 2
  done
  ((ok)) || { tail -n 20 "$LOG_DIR/xray.log" >&2 2>/dev/null || true; die 'Xray 未能启动'; }

  ss -lntH "sport = :$LISTEN_PORT" 2>/dev/null | grep -q . \
    || die '进程在跑但端口没有监听，检查端口冲突'

  step "7/7 配置订阅"
  setup_subscription

  printf '\n\033[32m安装完成\033[0m（备份：%s）\n' "$backup"
  printf '%s\n' '下一步：'
  printf '%s\n' "  1) 在平台放行/映射 TCP $PUBLIC_PORT 与 $SUB_PUBLIC_PORT"
  printf '%s\n' "  2) bash one-click-alpine.sh verify   # 用本地回环真跑一次代理"
  printf '%s\n' "  3) 把上面的订阅地址粘进 FlClash"
}

# ---------------------------------------------------------------------------
# 自检：真的走一次代理
# ---------------------------------------------------------------------------
do_verify() {
  need_root
  [[ -f $STATE ]] || die '还没安装，先跑 install'
  local uuid pub sid sni port sock tmp pid code
  uuid=$(jq -er .uuid "$STATE")
  pub=$(jq -er .public_key "$STATE")
  sid=$(jq -er .short_id "$STATE")
  sni=$(jq -er .server_name "$STATE")
  port=$(jq -er .listen_port "$STATE")
  sock=$(( 20000 + RANDOM % 20000 ))
  tmp=$(mktemp -d /tmp/xray-verify.XXXXXX)

  cat > "$tmp/client.json" <<JSON
{
  "log": {"loglevel": "error"},
  "inbounds": [{"listen": "127.0.0.1", "port": $sock, "protocol": "socks", "settings": {"udp": false}}],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "127.0.0.1", "port": $port,
      "users": [{"id": "$uuid", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {"serverName": "$sni", "fingerprint": "chrome",
        "publicKey": "$pub", "shortId": "$sid"}
    }
  }]
}
JSON

  step "启动临时客户端并回环握手"
  "$BIN" run -c "$tmp/client.json" >/dev/null 2>&1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
  sleep 3

  code=$(curl -sS --max-time 20 -x "socks5h://127.0.0.1:$sock" -o /dev/null \
           -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null) || code=000

  kill "$pid" 2>/dev/null || true
  rm -rf "$tmp"

  if [[ $code == 204 || $code == 200 ]]; then
    printf '\033[32mPASS\033[0m 代理链路正常（%s）\n' "$code"
    printf '%s\n' '只验证了本机回环；公网可达性仍需从外部网络测一次。'
    return 0
  fi
  printf '\033[31mFAIL\033[0m 回环请求失败（code=%s）\n' "$code" >&2
  printf '%s\n' '常见原因：UUID/flow 不匹配、REALITY 目标不可用、系统时间偏差。' >&2
  return 1
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
parse_args "$@"

case "$COMMAND" in
  "")            do_install ;;
  install)       do_install ;;
  manage)        [[ -x $ADMIN_BIN ]] || die '还没安装，先跑 install'; exec "$ADMIN_BIN" ;;
  status)        [[ -x $ADMIN_BIN ]] || die '还没安装'; exec "$ADMIN_BIN" --status ;;
  restart)       [[ -x $ADMIN_BIN ]] || die '还没安装'; exec "$ADMIN_BIN" --restart ;;
  sub)           [[ -x $ADMIN_BIN ]] || die '还没安装'; exec "$ADMIN_BIN" --sub ;;
  verify)        do_verify ;;
  uninstall)     need_root
                 [[ -x $ADMIN_BIN ]] || die '未找到管理脚本，可能还没安装'
                 if ((ASSUME_YES)); then exec "$ADMIN_BIN" --uninstall-force
                 else exec "$ADMIN_BIN" --uninstall; fi ;;
  *)             usage; exit 1 ;;
esac
