$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$installer = [IO.File]::ReadAllText((Join-Path $root 'install-xray.sh')).Replace("`r`n", "`n").TrimEnd()
$admin = [IO.File]::ReadAllText((Join-Path $root 'xray-admin')).Replace("`r`n", "`n").TrimEnd()
$sub = [IO.File]::ReadAllText((Join-Path $root 'xray-sub')).Replace("`r`n", "`n").TrimEnd()
$subUnit = [IO.File]::ReadAllText((Join-Path $root 'xray-sub.service')).Replace("`r`n", "`n").TrimEnd()
$rules = [IO.File]::ReadAllText((Join-Path $root 'rules.template.yaml')).Replace("`r`n", "`n").TrimEnd()
$header = @'
#!/usr/bin/env bash
# Generated from reviewed installer and menu. Debian amd64, single personal node.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请使用 root 运行'; exit 1; }
# Prevent credentials leaking when the caller invokes bash -x.
set +x
[[ -f /etc/debian_version && -d /run/systemd/system ]] || { echo '需要 Debian + systemd'; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo '当前脚本仅支持 amd64'; exit 1; }
export REALITY_DEST=${REALITY_DEST:-}
export REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-}
# Reuse saved endpoint on repeat installs; never guess the public IP through NAT.
if [[ -f /usr/local/etc/xray/client.json ]] && command -v jq >/dev/null; then
  SERVER_ADDRESS=${SERVER_ADDRESS:-$(jq -er .server /usr/local/etc/xray/client.json)}
  PUBLIC_PORT=${PUBLIC_PORT:-$(jq -er .port /usr/local/etc/xray/client.json)}
  LISTEN_PORT=${LISTEN_PORT:-$(jq -er .listen_port /usr/local/etc/xray/client.json)}
fi
if [[ -z ${SERVER_ADDRESS:-} || $SERVER_ADDRESS == REPLACE_* ]]; then
  read -r -p '输入平台显示的 VPS 公网 IP 或域名: ' SERVER_ADDRESS
fi
if [[ -z ${PUBLIC_PORT:-} ]]; then
  read -r -p '公网节点 TCP 端口（在平台端口转发里查看）: ' PUBLIC_PORT
fi
if [[ -z ${LISTEN_PORT:-} ]]; then
  read -r -p '对应内部 TCP 端口（无 NAT 时与公网端口相同）: ' LISTEN_PORT
fi
if [[ -z ${REALITY_DEST:-} ]]; then
  read -r -p 'REALITY 伪装目标 host:port [www.microsoft.com:443]: ' REALITY_DEST
  REALITY_DEST=${REALITY_DEST:-www.microsoft.com:443}
fi
if [[ -z ${REALITY_SERVER_NAME:-} ]]; then
  read -r -p 'REALITY serverName [www.microsoft.com]: ' REALITY_SERVER_NAME
  REALITY_SERVER_NAME=${REALITY_SERVER_NAME:-www.microsoft.com}
fi
# Subscription needs its own port: it cannot share the REALITY listener without
# breaking the camouflage fallback.
if [[ -z ${SUB_PUBLIC_PORT:-} ]]; then
  read -r -p '订阅公网端口（平台转发到实例 2096 的那个）: ' SUB_PUBLIC_PORT
fi
export SERVER_ADDRESS PUBLIC_PORT LISTEN_PORT REALITY_DEST REALITY_SERVER_NAME SUB_PUBLIC_PORT
printf '\n个人 Xray 一键安装\n代理  公网 %s:%s -> 内部 TCP %s\n订阅  公网 %s:%s -> 内部 TCP 2096\n目标  %s\n' \
  "$SERVER_ADDRESS" "$PUBLIC_PORT" "$LISTEN_PORT" \
  "$SERVER_ADDRESS" "$SUB_PUBLIC_PORT" "$REALITY_DEST"
echo '依次执行：依赖检查、目标检测、下载校验、配置检查、服务启动、订阅生成。'
echo '不修改端口映射、系统源、宿主内核或防火墙。'
missing=0
for tool in curl openssl unzip jq ss free sha256sum timeout; do
  command -v "$tool" >/dev/null || missing=1
done
if ((missing)); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl openssl unzip jq iproute2 procps
fi
work=$(mktemp -d /tmp/xray-one-click.XXXXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
trap 'echo "安装未完成，请保留最后的错误输出；不要重置服务器。" >&2' ERR
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
