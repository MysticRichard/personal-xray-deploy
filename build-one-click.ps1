$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$installer = [IO.File]::ReadAllText((Join-Path $root 'install-xray.sh')).Replace("`r`n", "`n").TrimEnd()
$admin = [IO.File]::ReadAllText((Join-Path $root 'xray-admin')).Replace("`r`n", "`n").TrimEnd()
$sub = [IO.File]::ReadAllText((Join-Path $root 'xray-sub')).Replace("`r`n", "`n").TrimEnd()
$subUnit = [IO.File]::ReadAllText((Join-Path $root 'xray-sub.service')).Replace("`r`n", "`n").TrimEnd()
$rules = [IO.File]::ReadAllText((Join-Path $root 'rules.template.yaml')).Replace("`r`n", "`n").TrimEnd()
$header = @'
#!/usr/bin/env bash
# Generated installer + maintenance menu + subscription renderer.
set -Eeuo pipefail
set +x
umask 077
SCRIPT_VERSION=2026.10.30-review2
printf '个人 Xray 安装脚本 %s\n' "$SCRIPT_VERSION"
[[ $EUID -eq 0 ]] || { echo '请使用 root 运行'; exit 1; }
[[ -f /etc/debian_version && -d /run/systemd/system ]] || { echo '需要 Debian + systemd'; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo '当前脚本仅支持 amd64'; exit 1; }
trap 'echo "安装未完成，请保留最后的错误输出；不要重置服务器。" >&2' ERR
missing=0
for tool in curl openssl unzip jq ss free sha256sum timeout busybox nano; do
  command -v "$tool" >/dev/null || missing=1
done
if ((missing)) || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -o Acquire::Retries=2 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20
  apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=60 ca-certificates curl openssl unzip jq iproute2 procps busybox nano
fi
for tool in curl openssl unzip jq ss free sha256sum timeout busybox nano; do
  command -v "$tool" >/dev/null || { echo "缺少依赖：$tool" >&2; exit 1; }
done
# `curl ... | bash` feeds the script body on stdin, so prompts would consume
# code instead of answers. Require a terminal, or explicit unattended mode.
if [[ ${NONINTERACTIVE:-0} != 1 && ! -t 0 ]]; then
  cat >&2 <<'EOT'
检测到标准输入不是终端（例如 curl ... | bash）。
请改用：bash <(curl -fsSL <链接>)
或先下载脚本再执行。
无人值守请设置 NONINTERACTIVE=1 并传入全部参数。
EOT
  exit 1
fi
usage() {
  cat <<'USAGE'
用法：bash one-click.sh [选项]
  --yes                     无人值守；所有必填项必须由参数或环境变量给出
  --server IP_OR_HOST       公网地址
  --port PORT               代理公网 TCP 端口
  --listen-port PORT        代理内部 TCP 端口
  --target HOST:PORT        REALITY 目标
  --sni NAME                REALITY serverName
  --sub-port PORT           订阅公网 TCP 端口
  --sub-listen-port PORT    订阅内部 TCP 端口
  --plan-total SIZE         月流量，例如 200GB 或 0
  --plan-reset DAY          重置日 0-31
  --plan-expire DATE        YYYY-MM-DD 或 0
  --archive FILE            本地发布包（仍校验 SHA256）
  --url URL                 自定义下载地址
  --proxy URL               下载用 HTTP(S) 代理
  --open-firewall           自动放行 ufw/firewalld 端口
  --skip-smoke              跳过安装后的链路自检
  -h, --help                显示本帮助
USAGE
}
while (($#)); do
  case "$1" in
    --yes) NONINTERACTIVE=1;;
    --server) SERVER_ADDRESS=$2; shift;;
    --port) PUBLIC_PORT=$2; shift;;
    --listen-port) LISTEN_PORT=$2; shift;;
    --target) REALITY_DEST=$2; shift;;
    --sni) REALITY_SERVER_NAME=$2; shift;;
    --sub-port) SUB_PUBLIC_PORT=$2; shift;;
    --sub-listen-port) SUB_LISTEN_PORT=$2; shift;;
    --plan-total) PLAN_TOTAL=$2; shift;;
    --plan-reset) PLAN_RESET_DAY=$2; shift;;
    --plan-expire) PLAN_EXPIRE=$2; shift;;
    --archive) XRAY_ARCHIVE=$2; shift;;
    --url) XRAY_URL=$2; shift;;
    --proxy) XRAY_PROXY=$2; shift;;
    --open-firewall) OPEN_FIREWALL=1;;
    --skip-smoke) SKIP_SMOKE=1;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数：$1（用 --help 查看用法）" >&2; exit 1;;
  esac
  shift
done
# A target-only call derives the SNI, matching install-xray.sh --target.
if [[ -n ${REALITY_DEST:-} && -z ${REALITY_SERVER_NAME:-} ]]; then
  REALITY_SERVER_NAME=${REALITY_DEST%:*}
fi
saved=/usr/local/etc/xray/client.json
# Existing values are defaults for the prompts. Interactive runs still show and
# read every item; NONINTERACTIVE=1 is the only mode that may skip prompting.
if [[ -f $saved ]]; then
  SERVER_ADDRESS=${SERVER_ADDRESS:-$(jq -er .server "$saved" 2>/dev/null || true)}
  PUBLIC_PORT=${PUBLIC_PORT:-$(jq -er .port "$saved" 2>/dev/null || true)}
  LISTEN_PORT=${LISTEN_PORT:-$(jq -er '.listen_port // .port' "$saved" 2>/dev/null || true)}
  REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-$(jq -er .server_name "$saved" 2>/dev/null || true)}
fi
if [[ -f /usr/local/etc/xray/config.json ]]; then
  REALITY_DEST=${REALITY_DEST:-$(jq -er '.inbounds[] | select(.tag == "personal") | .streamSettings.realitySettings | .target // .dest' /usr/local/etc/xray/config.json 2>/dev/null || true)}
fi
if [[ -s /etc/xray-sub/public_port ]]; then
  SUB_PUBLIC_PORT=${SUB_PUBLIC_PORT:-$(tr -d '\r\n' </etc/xray-sub/public_port)}
fi
if [[ -s /etc/xray-sub/port ]]; then
  SUB_LISTEN_PORT=${SUB_LISTEN_PORT:-$(tr -d '\r\n' </etc/xray-sub/port)}
fi
plan_file=/etc/xray-sub/provider-plan
if [[ -f $plan_file ]]; then
  PLAN_TOTAL=${PLAN_TOTAL:-$(sed -n 's/^total_display=//p' "$plan_file")}
  PLAN_RESET_DAY=${PLAN_RESET_DAY:-$(sed -n 's/^reset_day=//p' "$plan_file")}
  PLAN_EXPIRE=${PLAN_EXPIRE:-$(sed -n 's/^expire_date=//p' "$plan_file")}
fi
# Every interactive run shows all ten settings. Existing values are defaults,
# never silently skipped. NONINTERACTIVE=1 is for explicit unattended deployment.
ask() {
  local name=$1 label=$2 default=${3:-} answer
  if [[ ${NONINTERACTIVE:-0} == 1 ]]; then
    [[ -n ${!name:-} ]] || { echo "缺少非交互参数：$name" >&2; exit 1; }
    return
  fi
  if ! read -r -p "$label${default:+ [$default]}: " answer; then
    echo '未读取到输入，请在终端运行安装命令。' >&2; exit 1
  fi
  answer=${answer:-$default}
  [[ -n $answer ]] || { echo "$label 不能为空" >&2; exit 1; }
  printf -v "$name" '%s' "$answer"
}
ask SERVER_ADDRESS 'VPS 公网 IP 或域名' "${SERVER_ADDRESS:-}"
ask PUBLIC_PORT '代理公网 TCP 端口' "${PUBLIC_PORT:-}"
ask LISTEN_PORT '代理内部 TCP 端口（无 NAT 时与公网相同）' "${LISTEN_PORT:-}"
ask REALITY_DEST 'REALITY 目标 host:port（默认值并不保证防封，安装时会校验）' "${REALITY_DEST:-www.apple.com:443}"
# A custom target should not silently retain the Microsoft SNI.
default_sni=${REALITY_DEST%:*}
ask REALITY_SERVER_NAME 'REALITY serverName' "$default_sni"
ask SUB_PUBLIC_PORT '订阅公网 TCP 端口（平台外部端口，可任意）' "${SUB_PUBLIC_PORT:-}"
ask SUB_LISTEN_PORT '订阅内部 TCP 端口（须 ≥1024；无 NAT 时与公网相同）' "${SUB_LISTEN_PORT:-}"
ask PLAN_TOTAL '月流量（示例 100GB / 1TB / 0=不限，1024 进制）' "${PLAN_TOTAL:-0}"
ask PLAN_RESET_DAY '流量重置日（1-31，0=无固定重置日）' "${PLAN_RESET_DAY:-0}"
ask PLAN_EXPIRE '套餐到期日（YYYY-MM-DD，0=长期有效）' "${PLAN_EXPIRE:-0}"
export SERVER_ADDRESS PUBLIC_PORT LISTEN_PORT REALITY_DEST REALITY_SERVER_NAME SUB_PUBLIC_PORT SUB_LISTEN_PORT
export PLAN_TOTAL PLAN_RESET_DAY PLAN_EXPIRE
export XRAY_ARCHIVE XRAY_URL XRAY_PROXY OPEN_FIREWALL SKIP_SMOKE NONINTERACTIVE
printf '\n代理 公网 %s:%s -> 内部 TCP %s\n订阅 公网 %s:%s -> 内部 TCP %s\n目标 %s\n' \
  "$SERVER_ADDRESS" "$PUBLIC_PORT" "$LISTEN_PORT" "$SERVER_ADDRESS" "$SUB_PUBLIC_PORT" "$SUB_LISTEN_PORT" "$REALITY_DEST"
printf '套餐 月流量 %s / 重置日 %s / 到期 %s\n' "$PLAN_TOTAL" "$PLAN_RESET_DAY" "$PLAN_EXPIRE"
echo '私有设备规则请留在 FlClash 本地覆写，不会上传到仓库。'
echo '订阅目前使用 HTTP：随机路径只控制访问，不加密传输。'
echo '套餐流量/重置日不会自动从供应商同步；未统计时不显示虚构已用量。'
work=$(mktemp -d /tmp/xray-one-click.XXXXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
'@
$footer = @'
cat > "$work/xray-sub" <<'XRAY_SUB_PAYLOAD'
__SUB__
XRAY_SUB_PAYLOAD
cat > "$work/xray-sub.service" <<'XRAY_SUB_UNIT_PAYLOAD'
__SUBUNIT__
XRAY_SUB_UNIT_PAYLOAD
cat > "$work/rules.template.yaml" <<'XRAY_RULES_PAYLOAD'
__RULES__
XRAY_RULES_PAYLOAD
bash "$work/install-xray.sh" --install
bash /usr/local/sbin/xray-admin --export
if [[ ${SKIP_SMOKE:-0} == 1 ]]; then
  echo '已按 --skip-smoke / SKIP_SMOKE=1 跳过链路自检；请用 FlClash/Shadowrocket 实测。'
elif [[ ${NONINTERACTIVE:-0} != 1 ]]; then
  echo
  echo '正在做链路自检（本机客户端 -> REALITY -> 目标站）…'
  if ! bash "$work/install-xray.sh" --verify; then
    echo '链路自检失败。请把上面的客户端日志/服务端日志发给我；确认要跳过可加 --skip-smoke。' >&2
    exit 1
  fi
fi
echo
echo '安装完成。'
echo '日常维护：xray-admin（含查看订阅地址、编辑规则）'
'@
# Placeholders replaced with literal payload text after the heredoc is built.
$footer = $footer.Replace('__SUB__', $sub).Replace('__SUBUNIT__', $subUnit).Replace('__RULES__', $rules)
# Quoted heredocs: payload dollars and backticks remain literal.
$content = $header.TrimEnd() + "`ncat > `"`$work/install-xray.sh`" <<'XRAY_INSTALL_PAYLOAD'`n" + $installer + "`nXRAY_INSTALL_PAYLOAD`ncat > `"`$work/xray-admin`" <<'XRAY_ADMIN_PAYLOAD'`n" + $admin + "`nXRAY_ADMIN_PAYLOAD`n" + $footer.TrimEnd() + "`n"
$content = $content.Replace("`r`n", "`n")
[IO.File]::WriteAllText((Join-Path $root 'one-click.sh'), $content, (New-Object Text.UTF8Encoding($false)))
Write-Output 'Built one-click.sh (installer + menu, no credentials)'
