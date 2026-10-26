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
cat > "$work/install-xray.sh" <<'XRAY_INSTALL_PAYLOAD'
#!/usr/bin/env bash
# Single-user Debian deployment. Run --preflight before --install.
set -Eeuo pipefail
umask 077
VERSION=v26.10.21
ARCHIVE_SHA256=0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978
CONFIG=/usr/local/etc/xray/config.json
STATE=/usr/local/etc/xray/client.json
BIN=/usr/local/bin/xray
ASSETS=/usr/local/share/xray
UNIT=/etc/systemd/system/xray.service
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)); }
validate() {
  [[ ${SERVER_ADDRESS:-} =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || fail 'Set SERVER_ADDRESS (public host/IP).'
  LISTEN_PORT=${LISTEN_PORT:-443}
  PUBLIC_PORT=${PUBLIC_PORT:-$LISTEN_PORT}
  valid_port "$LISTEN_PORT" && valid_port "$PUBLIC_PORT" || fail 'Invalid public/listen port.'
  [[ ${REALITY_DEST:-} =~ ^([A-Za-z0-9][A-Za-z0-9.-]*):([1-9][0-9]{0,4})$ ]] || fail 'Set REALITY_DEST=host:port.'
  DEST_HOST=${BASH_REMATCH[1]}; DEST_PORT=${BASH_REMATCH[2]}
  valid_port "$DEST_PORT" || fail 'Invalid target port.'
  [[ ${REALITY_SERVER_NAME:-} =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail 'Set REALITY_SERVER_NAME.'
  [[ ${DEST_HOST,,} == "${REALITY_SERVER_NAME,,}" ]] || fail 'Use the same target hostname and serverName for this single-node template.'
  case "${REALITY_SERVER_NAME,,}" in
    apple.com|*.apple.com|icloud.com|*.icloud.com|mzstatic.com|*.mzstatic.com|me.com|*.me.com)
      fail 'Choose a different target; existing Xray logs warn about Apple targets.';;
  esac
}
validate_secrets() {
  [[ ${CLIENT_UUID:-} =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || fail 'Invalid UUID.'
  [[ ${PRIVATE_KEY:-} =~ ^[A-Za-z0-9_-]{43}$ && ${PUBLIC_KEY:-} =~ ^[A-Za-z0-9_-]{43}$ ]] || fail 'Invalid X25519 key format.'
  [[ ${SHORT_ID:-} =~ ^[0-9a-fA-F]{16}$ ]] || fail 'Expected one random 16-hex short ID.'
}
render() {
  validate
  validate_secrets
  # noclobber: never replace an existing file, even through a symlink.
  (set -o noclobber; cat > "$1" <<EOF
{
  "log": {"access": "none", "loglevel": "warning"},
  "inbounds": [{
    "tag": "personal", "listen": "0.0.0.0", "port": $LISTEN_PORT,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$CLIENT_UUID", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "raw", "security": "reality",
      "realitySettings": {"show": false, "target": "$REALITY_DEST", "xver": 0,
        "serverNames": ["$REALITY_SERVER_NAME"], "privateKey": "$PRIVATE_KEY", "shortIds": ["$SHORT_ID"]}
    }
  }],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {"type": "field", "ip": ["geoip:private", "geoip:cn", "0.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4", "::/128", "fc00::/7", "fe80::/10", "ff00::/8"], "outboundTag": "block"},
      {"type": "field", "network": "tcp,udp", "port": "25,465,587,137-139,445", "outboundTag": "block"},
      {"type": "field", "inboundTag": ["personal"], "outboundTag": "direct"}
    ]
  }
}
EOF
  )
}
preflight() {
  [[ $EUID -eq 0 ]] || fail 'Run as root.'
  [[ -f /etc/debian_version && -d /run/systemd/system ]] || fail 'Requires Debian with systemd as PID 1.'
  [[ $(uname -m) == x86_64 ]] || fail 'This reviewed release checksum is for amd64 only.'
  for tool in curl openssl ss getent unzip jq sha256sum timeout free systemctl systemd-detect-virt; do command -v "$tool" >/dev/null || fail "Missing $tool; install dependencies listed in README."; done
  validate
  printf 'Public endpoint: %s:%s -> guest TCP port %s\n' "$SERVER_ADDRESS" "$PUBLIC_PORT" "$LISTEN_PORT"
  printf 'Subscription: public %s -> guest TCP port %s\n' "${SUB_PUBLIC_PORT:-2096}" "${SUB_LISTEN_PORT:-2096}"
  printf 'Virtualization: '; systemd-detect-virt || true
  free -m
  df -h /
  (( $(df -Pk / | awk 'NR==2 {print $4}') > 180000 )) || fail 'Need at least 180 MB free for staging and rollback.'
  systemctl is-active --quiet x-ui && fail 'x-ui is running; stop it only after backup.'
  if ss -lntH "sport = :$LISTEN_PORT" | grep -q .; then
    systemctl is-active --quiet xray || fail 'Listen port is occupied by another service.'
    [[ -f $STATE ]] || fail 'Unknown existing Xray instance; migration required.'
    local old_port
    old_port=$(jq -er .listen_port "$STATE")
    [[ $old_port == "$LISTEN_PORT" ]] || fail 'Requested port is occupied; use the existing instance port or an unused port.'
  fi
  local address
  while read -r address; do
    case "$address" in
      10.*|127.*|0.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) fail 'REALITY target resolved to a local/private IPv4 address.';;
    esac
  done < <(getent ahostsv4 "$DEST_HOST" | awk '{print $1}' | sort -u)
  local probe
  probe=$(timeout 15 openssl s_client -connect "$REALITY_DEST" -servername "$REALITY_SERVER_NAME" -verify_hostname "$REALITY_SERVER_NAME" -verify_return_error -tls1_3 -alpn h2 </dev/null 2>&1) || fail 'Target TLS/certificate check failed.'
  [[ $probe == *TLSv1.3* && $probe == *'ALPN protocol: h2'* ]] || fail 'Target did not negotiate TLS1.3 and h2.'
  # REALITY only needs a valid TLS1.3/h2 target. The HTTP status is informational:
  # some CDNs answer this host inconsistently (timeouts, h2 framing errors) and
  # blocking installation on it produced false failures.
  local code
  if code=$(curl --http1.1 --noproxy '*' --silent --max-time 10 --connect-to "$DEST_HOST:443:$DEST_HOST:$DEST_PORT" -o /dev/null -w '%{http_code}' "https://$REALITY_SERVER_NAME/" 2>/dev/null); then
    echo "  HTTP 状态        : $code（仅供参考，不影响判定）"
  else
    echo '  HTTP 状态        : 未取到（忽略；TLS1.3 与 h2 已通过）'
  fi
  echo 'PASS: preflight. Public NAT mapping and client reachability still need external verification.'
}

# Build the subscription service: editable rules + static HTTP on localhost.
# The public port is separate from the guest listen port, so the caller may
# expose it through its own port-forward table.
setup_subscription() {
  local sub_port token
  sub_port=${SUB_LISTEN_PORT:-2096}
  install -d -m 750 /etc/xray-sub
  install -d -m 755 /srv/sub
  printf '%s\n' "${SUB_PUBLIC_PORT:-$sub_port}" > /etc/xray-sub/public_port

  if [[ ! -s /etc/xray-sub/token ]]; then
    openssl rand -hex 16 > /etc/xray-sub/token
    chmod 600 /etc/xray-sub/token
  fi
  token=$(tr -d '\r\n' < /etc/xray-sub/token)

  # Keep user edits on reinstall; seed from the packaged template otherwise.
  if [[ ! -s /etc/xray-sub/rules.yaml ]]; then
    if [[ -f "$SELF_DIR/rules.template.yaml" ]]; then
      install -m 640 "$SELF_DIR/rules.template.yaml" /etc/xray-sub/rules.yaml
    else
      fail '缺少 rules.template.yaml，无法生成订阅'
    fi
  fi

  printf '%s\n' "$sub_port" > /etc/xray-sub/port
  install -m 755 "$SELF_DIR/xray-sub" /usr/local/sbin/xray-sub
  install -m 755 "$SELF_DIR/xray-sub.service" /tmp/xray-sub.service.tpl
  sed "s/__SUB_PORT__/$sub_port/g" /tmp/xray-sub.service.tpl > /etc/systemd/system/xray-sub.service
  rm -f /tmp/xray-sub.service.tpl
  chmod 644 /etc/systemd/system/xray-sub.service

  /usr/local/sbin/xray-sub || fail '订阅生成失败'

  systemctl daemon-reload
  systemctl enable xray-sub >/dev/null 2>&1 || true

  # Some nested container hosts reject mount-namespace setup for any unit that
  # requests it. Try the hardened unit first, then fall back to a minimal one
  # instead of failing the whole installation.
  systemctl restart xray-sub
  sleep 2
  if ! systemctl is-active --quiet xray-sub; then
    if journalctl -u xray-sub -n 20 --no-pager 2>/dev/null | grep -q 'NAMESPACE\|Operation not supported'; then
      echo '检测到嵌套容器不支持 mount namespace，改用精简服务配置' >&2
      # busybox httpd reads its document root from -h; no namespacing needed.
      cat > /etc/systemd/system/xray-sub.service <<UNIT
[Unit]
Description=Personal Clash subscription (minimal)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/busybox httpd -f -p 127.0.0.1:${sub_port} -h /srv/sub
Restart=always
RestartSec=5
NoNewPrivileges=true
CapabilityBoundingSet=
UMask=0027
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
      chmod 644 /etc/systemd/system/xray-sub.service
      systemctl daemon-reload
      systemctl reset-failed xray-sub 2>/dev/null || true
      systemctl restart xray-sub
      sleep 2
    fi
  fi

  systemctl is-active --quiet xray-sub || {
    journalctl -u xray-sub -n 20 --no-pager >&2 || true
    fail 'xray-sub 未能启动'
  }
  curl -fsS --max-time 5 "http://127.0.0.1:${sub_port}/cgi-bin/${token}" -o /dev/null \
    || fail '订阅本地自检失败'

  cat <<INFO

============================================================
订阅地址（复制到 FlClash 的"订阅"里）：

  http://${SERVER_ADDRESS}:${SUB_PUBLIC_PORT:-$sub_port}/cgi-bin/${token}

说明：
  - 公网 ${SUB_PUBLIC_PORT:-$sub_port} 需在平台映射到实例 ${sub_port}
  - 通用规则：/etc/xray-sub/rules.yaml
  - 私有规则：/etc/xray-sub/rules.local.yaml（不进仓库）
  - 流量额度：/etc/xray-sub/userinfo
  - 改完执行 xray-sub 重新生成
  - 随时查看地址：xray-admin --sub
============================================================

INFO
}

install_node() {  preflight
  [[ -f "$SELF_DIR/xray-admin" ]] || fail 'Copy the full deployment folder, including xray-admin.'
  if [[ -e $CONFIG && ! -f $STATE ]]; then fail 'Existing unmanaged config: refusing to replace it.'; fi
  # EXIT runs after this function returns: rollback state must stay in scope.
  active=0; changed=0
  stage=$(mktemp -d)
  backup="/root/xray-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$backup"
  chmod 700 /root/xray-backups "$backup"
  systemctl is-active --quiet xray && active=1
  cleanup() {
    local rc=$?
    if ((rc != 0 && changed == 1)); then
      echo "Install failed; restoring files from $backup" >&2
      systemctl stop xray 2>/dev/null || true
      for pair in "config:$CONFIG" "state:$STATE" "binary:$BIN" "geoip:$ASSETS/geoip.dat" "unit:$UNIT" "admin:/usr/local/sbin/xray-admin"; do
        local key=${pair%%:*} path=${pair#*:}
        if [[ -f $backup/$key ]]; then cp -p "$backup/$key" "$path"; else rm -f "$path"; fi
      done
      systemctl daemon-reload || true
      if ((active)); then systemctl start xray || true; else systemctl disable xray 2>/dev/null || true; fi
    fi
    rm -rf "$stage"
    return "$rc"
  }
  trap cleanup EXIT
  for pair in "config:$CONFIG" "state:$STATE" "binary:$BIN" "geoip:$ASSETS/geoip.dat" "unit:$UNIT" "admin:/usr/local/sbin/xray-admin"; do
    local key=${pair%%:*} path=${pair#*:}
    [[ ! -f $path ]] || cp -p "$path" "$backup/$key"
  done
  curl --fail --location --retry 2 --max-time 180 "https://github.com/XTLS/Xray-core/releases/download/$VERSION/Xray-linux-64.zip" -o "$stage/core.zip"
  printf '%s  %s\n' "$ARCHIVE_SHA256" "$stage/core.zip" | sha256sum --check --status || fail 'Release checksum mismatch.'
  # Decompress only what is needed, and drop the archive immediately: on a
  # 128 MB cgroup these few tens of MB of page cache matter for the first start.
  unzip -q -j "$stage/core.zip" xray geoip.dat -d "$stage/core"
  rm -f "$stage/core.zip"
  chmod 755 "$stage/core/xray"
  sync
  if [[ -f $STATE ]]; then
    CLIENT_UUID=$(jq -er .uuid "$STATE")
    PRIVATE_KEY=$(jq -er .private_key "$STATE")
    PUBLIC_KEY=$(jq -er .public_key "$STATE")
    SHORT_ID=$(jq -er .short_id "$STATE")
  else
    CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 8)
    local keys
    keys=$("$stage/core/xray" x25519)
    PRIVATE_KEY=$(printf '%s\n' "$keys" | awk -F': *' '/^(PrivateKey|Private key):/ {print $2; exit}')
    PUBLIC_KEY=$(printf '%s\n' "$keys" | awk -F': *' '/^(Password \(PublicKey\)|Password|PublicKey|Public key):/ {print $2; exit}')
  fi
  render "$stage/config.json"
  XRAY_LOCATION_ASSET="$stage/core" "$stage/core/xray" run -test -config "$stage/config.json"
  jq -n --arg uuid "$CLIENT_UUID" --arg private_key "$PRIVATE_KEY" --arg public_key "$PUBLIC_KEY" --arg short_id "$SHORT_ID" --arg server "$SERVER_ADDRESS" --argjson port "$PUBLIC_PORT" --argjson listen_port "$LISTEN_PORT" --arg server_name "$REALITY_SERVER_NAME" '{uuid:$uuid, private_key:$private_key, public_key:$public_key, short_id:$short_id, server:$server, port:$port, listen_port:$listen_port, server_name:$server_name}' > "$stage/client.json"
  getent group xray >/dev/null || groupadd --system xray
  id xray >/dev/null 2>&1 || useradd --system --gid xray --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray
  install -d -m 750 -o root -g xray /usr/local/etc/xray
  install -d -m 755 "$ASSETS"
  cat > "$stage/xray.service" <<'EOF'
[Unit]
Description=Personal Xray node
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=10
[Service]
User=xray
Group=xray
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
# Low-RAM hosts: constrain the Go heap explicitly. The runtime only picks up a
# cgroup limit when the process can see one; nested containers often cannot,
# so without this the heap grows past a 128 MB budget and gets OOM-killed.
Environment=GOMEMLIMIT=48MiB
Environment=GOGC=30
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
RestartSec=5
MemoryHigh=96M
MemoryMax=112M
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
UMask=0077
StandardOutput=journal
StandardError=journal
LogRateLimitIntervalSec=30s
LogRateLimitBurst=20
[Install]
WantedBy=multi-user.target
EOF
  changed=1
  install -m 755 "$stage/core/xray" "$BIN.new"
  mv -f "$BIN.new" "$BIN"
  install -m 644 "$stage/core/geoip.dat" "$ASSETS/geoip.dat"
  install -m 640 -o root -g xray "$stage/config.json" "$CONFIG.new"
  mv -f "$CONFIG.new" "$CONFIG"
  install -m 600 "$stage/client.json" "$STATE"
  install -m 644 "$stage/xray.service" "$UNIT"
  install -m 700 "$SELF_DIR/xray-admin" /usr/local/sbin/xray-admin
  # 128 MB hosts count page cache toward the cgroup limit: a freshly extracted
  # 35 MB binary can push the first start over the edge and get OOM-killed.
  rm -rf "$stage"
  sync
  systemctl daemon-reload
  systemctl enable xray
  local attempt
  for attempt in 1 2 3; do
    systemctl restart xray
    sleep 3
    systemctl is-active --quiet xray && break
    if [[ $attempt -lt 3 ]]; then
      echo "启动失败（第 $attempt 次），回收内存后重试" >&2
      systemctl reset-failed xray 2>/dev/null || true
      sync
      sleep 2
    fi
  done
  if ! systemctl is-active --quiet xray; then
    echo '--- systemctl status ---' >&2
    systemctl status xray --no-pager -l 2>&1 | head -20 >&2 || true
    echo '--- journal ---' >&2
    journalctl -u xray -n 20 --no-pager 2>&1 >&2 || true
    echo '--- free ---' >&2
    free -m >&2 || true
    fail 'Xray did not stay active.'
  fi
  ss -lntH "sport = :$LISTEN_PORT" | grep -q . || fail 'Xray is active but requested port is not listening.'
  setup_subscription
  echo "PASS: local service listening. Backup: $backup"
  echo 'Run xray-admin for status, logs and client export. Test the public endpoint before claiming connectivity.'
}
case ${1:---help} in
  --render) [[ $# == 2 ]] || fail 'Usage: --render OUTPUT'; render "$2";;
  --preflight) preflight;;
  --install) install_node;;
  *) echo 'Usage: install-xray.sh --preflight | --install | --render OUTPUT'
     echo 'Set SERVER_ADDRESS, PUBLIC_PORT, LISTEN_PORT, REALITY_DEST, REALITY_SERVER_NAME.';;
esac
XRAY_INSTALL_PAYLOAD
cat > "$work/xray-admin" <<'XRAY_ADMIN_PAYLOAD'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请用 root 执行'; exit 1; }
state=/usr/local/etc/xray/client.json
sub_token_file=/etc/xray-sub/token
sub_port_file=/etc/xray-sub/port
sub_rules=/etc/xray-sub/rules.yaml
sub_local=/etc/xray-sub/rules.local.yaml

sub_url() {
  [[ -f $state && -s $sub_token_file ]] || { echo '尚未配置订阅'; return 1; }
  local server publicp token sport
  server=$(jq -er .server "$state")
  token=$(tr -d '\r\n' < "$sub_token_file")
  sport=$(tr -d '\r\n' < "$sub_port_file" 2>/dev/null || echo 2096)
  publicp=$(tr -d '\r\n' < /etc/xray-sub/public_port 2>/dev/null || echo "$sport")
  printf 'http://%s:%s/cgi-bin/%s\n' "$server" "${SUB_PUBLIC_PORT:-$publicp}" "$token"
}

show_sub() {
  echo
  echo '订阅地址（复制到 FlClash 订阅栏）：'
  sub_url || return 1
  echo
  echo "规则文件：$sub_rules"
  if [[ -f $sub_rules ]]; then
    printf '通用规则：%s 条\n' "$(grep -c '^- ' "$sub_rules" 2>/dev/null || echo 0)"
  fi
  if [[ -f $sub_local ]]; then
    printf '私有规则：%s 条\n' "$(grep -c '^- ' "$sub_local" 2>/dev/null || echo 0)"
  else
    echo '私有规则：未创建'
  fi
  systemctl is-active --quiet xray-sub && echo '订阅服务：运行中' || echo '订阅服务：未运行'
}

# One self-contained file a user can keep and reuse on any new computer.
export_sub_info() {
  local out=/root/xray-subscription.txt
  {
    echo '# 个人 Xray 订阅信息'
    echo "# 生成时间：$(date -u '+%Y-%m-%d %H:%M UTC')"
    echo
    echo '## 订阅地址（粘到 FlClash 的订阅栏）'
    sub_url
    echo
    echo '## 端口'
    echo "代理公网端口：$(jq -er .port "$state" 2>/dev/null || echo 未知)"
    echo "订阅公网端口：$(tr -d '\r\n' </etc/xray-sub/public_port 2>/dev/null || echo 2096)"
    echo
    echo '## 私有规则（rules.local.yaml）'
    if [[ -s $sub_local ]]; then
      grep -v '^[[:space:]]*$' "$sub_local"
    else
      echo '（未创建）'
    fi
    echo
    echo '## 说明'
    echo '这个文件含订阅地址，等同凭据。只存在自己的电脑上，不要公开。'
    echo '换电脑后：新电脑导入上面的订阅地址即可，规则会随订阅下发。'
    echo '换服务器后：在新服务器上重建，规则可从本文件的私有规则段复制回去。'
  } > "$out"
  chmod 600 "$out"
  echo "已生成：$out"
  echo '请下载到自己电脑保存，重装系统会删除。'
}

export_node() {
  [[ -f $state ]] || { echo '找不到安装状态文件'; return 1; }
  install -d -m 700 /root/xray-client
  jq '{proxies:[{name:"Personal-VPS",type:"vless",server:.server,port:.port,uuid:.uuid,network:"tcp",tls:true,udp:true,flow:"xtls-rprx-vision","client-fingerprint":"chrome",servername:.server_name,"reality-opts":{"public-key":.public_key,"short-id":.short_id}}]}' "$state" > /root/xray-client/node.json
  chmod 600 /root/xray-client/node.json
  echo '已导出 /root/xray-client/node.json'
}

edit_rules() {
  local target="${1:-$sub_rules}"
  local backup="/root/xray-sub-rules-$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$target")"
  [[ -f $target ]] || {
    echo "文件不存在：$target"
    return 1
  }
  cp -p "$target" "$backup"
  chmod 600 "$backup"
  echo "已备份到 $backup"
  "${EDITOR:-nano}" "$target" || { echo '编辑器退出异常'; return 1; }
  if /usr/local/sbin/xray-sub; then
    echo '已重新生成订阅，FlClash 里下拉刷新即可'
  else
    echo '生成失败，正在回滚'
    cp -p "$backup" "$target"
    return 1
  fi
}

init_local_rules() {
  [[ -f $sub_rules ]] || { echo '通用规则文件不存在，请先安装'; return 1; }
  local target=/etc/xray-sub/rules.local.yaml
  if [[ -f $target ]]; then
    echo "私有规则文件已存在：$target"
  else
    cat > "$target" <<'EOF'
# 私有分流规则（不会进入公开仓库）
# 每行一条，"- " 开头；这些规则会排在通用规则之前，优先生效。
# 示例：
# - DOMAIN,your-device.example.net,DIRECT
# - IP-CIDR,203.0.113.10/32,DIRECT,no-resolve
EOF
    chmod 640 "$target"
    echo "已创建：$target"
  fi
  echo '编辑后执行 xray-sub 重新生成订阅'
}

backup_all() {
  local file=/root/xray-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
  local paths=(usr/local/etc/xray usr/local/sbin/xray-admin usr/local/sbin/xray-sub etc/xray-sub etc/systemd/system/xray.service etc/systemd/system/xray-sub.service usr/local/bin/xray usr/local/share/xray/geoip.dat srv/sub)
  local existing=()
  for p in "${paths[@]}"; do [[ -e /$p ]] && existing+=("$p"); done
  tar -czf "$file" -C / "${existing[@]}"
  chmod 600 "$file"
  echo "备份：$file"
  echo '请下载到自己电脑，重装会删除服务器内备份'
}

set_quota() {
  local f=/etc/xray-sub/userinfo
  echo '设置订阅里显示的流量额度。Clash 会读取这些值显示用量。'
  echo '留空表示不显示该项。total 为 0 表示不限制。'
  local up down total expire
  read -r -p '已上传字节数 [0]: ' up; up=${up:-0}
  read -r -p '已下载字节数 [0]: ' down; down=${down:-0}
  read -r -p '总流量字节数（0=不限，100GB=107374182400） [0]: ' total; total=${total:-0}
  read -r -p '到期时间（Unix 时间戳，0=长期有效） [0]: ' expire; expire=${expire:-0}
  for v in "$up" "$down" "$total" "$expire"; do
    [[ $v =~ ^[0-9]+$ ]] || { echo '只接受非负整数'; return 1; }
  done
  printf 'upload=%s; download=%s; total=%s; expire=%s\n' "$up" "$down" "$total" "$expire" > "$f"
  chmod 640 "$f"
  /usr/local/sbin/xray-sub >/dev/null || { echo '重新生成失败'; return 1; }
  echo '已保存。Clash 下拉刷新订阅即可看到额度。'
}

check_config() { XRAY_LOCATION_ASSET=/usr/local/share/xray /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json; }

change_sub_port() {
  local current
  current=$(tr -d '\r\n' </etc/xray-sub/public_port 2>/dev/null || echo 2096)
  echo "当前订阅公网端口：$current"
  echo '只改对外显示的端口，实例内部仍监听 2096，不会动平台映射。'
  local new
  read -r -p '新的订阅公网端口（回车保持不变）: ' new
  if [[ -z $new ]]; then echo '未修改'; return 0; fi
  [[ $new =~ ^[1-9][0-9]{0,4}$ ]] || { echo '端口格式不正确'; return 1; }
  ((10#$new <= 65535)) || { echo '端口超出范围'; return 1; }
  printf '%s\n' "$new" > /etc/xray-sub/public_port
  echo "已保存。新的订阅地址："
  sub_url
}

case ${1:-} in
  --export) export_node; exit;;
  --sub) show_sub; exit;;
esac

while true; do
  cat <<'MENU'

个人 Xray 管理
  1. 状态、端口与内存
  2. 最近日志
  3. 检查配置并重启
  4. 查看订阅地址
  5. 编辑通用规则（rules.yaml）
  6. 编辑私有规则（rules.local.yaml）
  7. 重新生成订阅
  8. 修改订阅公网端口
  9. 设置流量额度（客户端显示）
 10. 导出订阅信息到文件（换电脑用）
 11. 备份
 12. 导出客户端节点
  0. 退出
MENU
  read -r -p '选择: ' option || exit 0
  case $option in
    1) systemctl --no-pager --full status xray || true
       ss -lntp | grep -E ':2082|:2096' || ss -lntp
       systemctl show xray -p MemoryCurrent -p MemoryMax 2>/dev/null || true
       free -m;;
    2) journalctl -u xray -n 40 --no-pager;;
    3) if check_config; then systemctl restart xray; sleep 2; systemctl is-active xray; fi;;
    4) show_sub;;
    5) edit_rules "$sub_rules";;
    6) init_local_rules; edit_rules "$sub_local";;
    7) /usr/local/sbin/xray-sub && echo '已重新生成，FlClash 下拉刷新即可';;
    8) change_sub_port;;
    9) set_quota;;
    10) export_sub_info;;
    11) backup_all;;
    12) export_node;;
    0) exit 0;;
    *) echo '无效选项';;
  esac
done
XRAY_ADMIN_PAYLOAD
cat > "$work/xray-sub" <<'XRAY_SUB_PAYLOAD'
#!/usr/bin/env bash
# Rebuild the Clash/FlClash subscription from the editable rules template.
# Files:
#   /etc/xray-sub/token       random URL path segment
#   /etc/xray-sub/rules.yaml  rule entries, one per line, each starting with "- "
#   /srv/sub/<token>/config.yaml  generated (served over HTTP)
set -Eeuo pipefail
umask 027

STATE=/usr/local/etc/xray/client.json
RULES=/etc/xray-sub/rules.yaml
RULES_LOCAL=/etc/xray-sub/rules.local.yaml
TOKEN_FILE=/etc/xray-sub/token
SUB_PORT_FILE=/etc/xray-sub/port
USERINFO=/etc/xray-sub/userinfo
WEBROOT=/srv/sub

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f $STATE ]] || die "缺少 $STATE，请先安装 Xray"
[[ -f $RULES ]] || die "缺少 $RULES"
[[ -s $TOKEN_FILE ]] || die "缺少 $TOKEN_FILE"

TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
[[ $TOKEN =~ ^[A-Za-z0-9_-]{16,64}$ ]] || die '订阅令牌格式不正确'

# Validate every meaningful line is a rule entry. Fail closed: a malformed
# template must not silently produce a config that routes everything direct.
validate_rules() {
  local file="$1" label="$2" line_no=0 bad=0 line
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line_no=$((line_no + 1))
    case $line in
      ''|\#*) continue ;;
      '- '*) ;;
      *) printf '%s 第 %d 行不是规则条目（应以 "- " 开头）：%s\n' "$label" "$line_no" "$line" >&2; bad=1 ;;
    esac
  done < "$file"
  ((bad == 0)) || die '规则校验失败，未生成订阅'
  return 0
}
validate_rules "$RULES" '通用规则'
# Optional private rules; never shipped with the repo.
[[ -f $RULES_LOCAL ]] && validate_rules "$RULES_LOCAL" '私有规则'

uuid=$(jq -er .uuid "$STATE")
pub=$(jq -er .public_key "$STATE")
sid=$(jq -er .short_id "$STATE")
server=$(jq -er .server "$STATE")
port=$(jq -er .port "$STATE")
sni=$(jq -er .server_name "$STATE")

out_dir="$WEBROOT/$TOKEN"
install -d -m 755 "$WEBROOT" "$out_dir"
tmp=$(mktemp "$out_dir/.config.XXXXXX")
trap 'rm -f "$tmp"' EXIT

{
  cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
find-process-mode: "off"
global-client-fingerprint: chrome

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.1.1.1/dns-query
  fallback:
    - https://8.8.8.8/dns-query

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
  # Private rules first: they must win over the generic template and MATCH.
  if [[ -f $RULES_LOCAL ]]; then
    grep -v '^[[:space:]]*#' "$RULES_LOCAL" | grep -v '^[[:space:]]*$' || true
  fi
  cat "$RULES"
} > "$tmp"

# Sanity: generated file must contain the node and at least one rule.
grep -q 'Personal-VPS' "$tmp" || die '生成的订阅缺少节点'
grep -q '^  - \|^- ' "$tmp" || die '生成的订阅缺少规则'
[[ $(wc -c < "$tmp") -gt 200 ]] || die '生成的订阅过小'

chmod 644 "$tmp"
mv -f "$tmp" "$out_dir/config.yaml"
chmod 644 "$out_dir/config.yaml"

# Clash-family clients read the traffic quota from a response header, and
# busybox httpd only executes CGI under a "cgi-bin" directory. So the token
# lives in the CGI filename, not in the directory name.
install -d -m 755 "$WEBROOT/cgi-bin"
cat > "$WEBROOT/cgi-bin/$TOKEN" <<CGI
#!/bin/sh
# Subscription for token $TOKEN: quota headers + config body.
set -eu
printf 'Content-Type: text/yaml; charset=utf-8\r\n'
if [ -s "$USERINFO" ]; then
  printf 'Subscription-Userinfo: %s\r\n' "\$(cat "$USERINFO")"
fi
printf 'Profile-Update-Interval: 24\r\n\r\n'
exec cat "$out_dir/config.yaml"
CGI
chmod 755 "$WEBROOT/cgi-bin/$TOKEN"

sub_port=$(tr -d '\r\n' < "$SUB_PORT_FILE" 2>/dev/null || echo "")
sub_port=${sub_port:-2096}
echo "订阅文件已生成：$out_dir/config.yaml"
rules_count=$(grep -c '^- ' "$out_dir/config.yaml" 2>/dev/null || echo 0)
echo "规则条数：${rules_count}"
[[ -f $RULES_LOCAL ]] && echo "已合并私有规则：$RULES_LOCAL"
echo "本地地址：http://127.0.0.1:${sub_port}/cgi-bin/${TOKEN}"
XRAY_SUB_PAYLOAD
cat > "$work/xray-sub.service" <<'XRAY_SUB_UNIT_PAYLOAD'
[Unit]
Description=Personal Clash subscription (static)
After=network.target
StartLimitIntervalSec=120
StartLimitBurst=10

[Service]
Type=simple
ExecStart=/usr/bin/busybox httpd -f -p 127.0.0.1:__SUB_PORT__ -h /srv/sub
Restart=always
RestartSec=5
# Nested containers (Podman/LXC) reject mount namespaces, so the hardening
# options that need them are intentionally omitted here. The service only
# serves a static directory read-only and runs as a dedicated unprivileged user.
User=nobody
Group=nogroup
NoNewPrivileges=true
CapabilityBoundingSet=
UMask=0027
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
XRAY_SUB_UNIT_PAYLOAD
cat > "$work/rules.template.yaml" <<'XRAY_RULES_PAYLOAD'
# 通用分流模板（会随仓库公开）
#
# 这里只放通用的公共域名/IP 段，不要写自己的设备、内网或 VPS 地址。
# 你需要私有的规则，写到 /etc/xray-sub/rules.local.yaml，那份文件不会进仓库。
#
# 用法：
#   - 每行一条规则，必须以 "- " 开头
#   - 以 # 开头的行是注释
#   - 改完执行 xray-sub 重新生成订阅
#
# 顺序很重要：私有规则最先匹配，然后是这份模板，从上到下，第一条命中即生效。

# ---------- 内网通用网段：直连 ----------
- IP-CIDR,0.0.0.0/8,DIRECT,no-resolve
- IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
- IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
- IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
- IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
- IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
- IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
- IP-CIDR,198.18.0.0/16,DIRECT,no-resolve
- IP-CIDR,224.0.0.0/4,DIRECT,no-resolve
- IP-CIDR6,::1/128,DIRECT,no-resolve
- IP-CIDR6,fc00::/7,DIRECT,no-resolve
- IP-CIDR6,fe80::/10,DIRECT,no-resolve
- DOMAIN-SUFFIX,local,DIRECT
- DOMAIN-SUFFIX,localhost,DIRECT
- DOMAIN-SUFFIX,home.arpa,DIRECT

# ---------- 路由器管理页：直连 ----------
- DOMAIN,instant.arubanetworks.com,DIRECT
- DOMAIN,setmeup.arubanetworks.com,DIRECT
- DOMAIN,router.asus.com,DIRECT
- DOMAIN-SUFFIX,hiwifi.com,DIRECT
- DOMAIN-SUFFIX,miwifi.com,DIRECT
- DOMAIN-SUFFIX,tplogin.cn,DIRECT
- DOMAIN-SUFFIX,tendawifi.com,DIRECT
- DOMAIN-SUFFIX,wifi.cmcc,DIRECT

# ---------- AI 服务：走代理 ----------
- DOMAIN-KEYWORD,anthropic,PROXY
- DOMAIN-KEYWORD,claude,PROXY
- DOMAIN-KEYWORD,openai,PROXY
- DOMAIN-SUFFIX,anthropic.com,PROXY
- DOMAIN-SUFFIX,chatgpt.com,PROXY
- DOMAIN-SUFFIX,claude.ai,PROXY
- DOMAIN-SUFFIX,claude.com,PROXY
- DOMAIN-SUFFIX,cursor.com,PROXY
- DOMAIN-SUFFIX,gemini.google.com,PROXY
- DOMAIN-SUFFIX,generativelanguage.googleapis.com,PROXY
- DOMAIN-SUFFIX,githubcopilot.com,PROXY
- DOMAIN-SUFFIX,openai.com,PROXY
- DOMAIN-SUFFIX,perplexity.ai,PROXY
- DOMAIN-SUFFIX,x.ai,PROXY

# ---------- 常用开发与内容站：走代理 ----------
- DOMAIN-SUFFIX,github.com,PROXY
- DOMAIN-SUFFIX,githubusercontent.com,PROXY
- DOMAIN-SUFFIX,githubassets.com,PROXY
- DOMAIN-SUFFIX,gitlab.com,PROXY
- DOMAIN-SUFFIX,google.com,PROXY
- DOMAIN-SUFFIX,googleapis.com,PROXY
- DOMAIN-SUFFIX,gstatic.com,PROXY
- DOMAIN-SUFFIX,youtube.com,PROXY
- DOMAIN-SUFFIX,youtu.be,PROXY
- DOMAIN-SUFFIX,googlevideo.com,PROXY
- DOMAIN-SUFFIX,ytimg.com,PROXY
- DOMAIN-SUFFIX,twitter.com,PROXY
- DOMAIN-SUFFIX,x.com,PROXY
- DOMAIN-SUFFIX,reddit.com,PROXY
- DOMAIN-SUFFIX,telegram.org,PROXY
- DOMAIN-SUFFIX,t.me,PROXY
- DOMAIN-SUFFIX,wikipedia.org,PROXY
- DOMAIN-SUFFIX,notion.so,PROXY
- DOMAIN-SUFFIX,linkedin.com,PROXY
- DOMAIN-SUFFIX,medium.com,PROXY
- DOMAIN-SUFFIX,stackoverflow.com,PROXY
- DOMAIN-SUFFIX,npmjs.org,PROXY
- DOMAIN-SUFFIX,pypi.org,PROXY
- DOMAIN-SUFFIX,docker.io,PROXY
- DOMAIN-SUFFIX,huggingface.co,PROXY

# ---------- 国内常用服务：直连 ----------
- DOMAIN-SUFFIX,qq.com,DIRECT
- DOMAIN-SUFFIX,weixin.com,DIRECT
- DOMAIN-SUFFIX,taobao.com,DIRECT
- DOMAIN-SUFFIX,tmall.com,DIRECT
- DOMAIN-SUFFIX,jd.com,DIRECT
- DOMAIN-SUFFIX,aliyun.com,DIRECT
- DOMAIN-SUFFIX,aliyuncs.com,DIRECT
- DOMAIN-SUFFIX,baidu.com,DIRECT
- DOMAIN-SUFFIX,bilibili.com,DIRECT
- DOMAIN-SUFFIX,hdslb.com,DIRECT
- DOMAIN-SUFFIX,douyin.com,DIRECT
- DOMAIN-SUFFIX,zhihu.com,DIRECT
- DOMAIN-SUFFIX,xiaohongshu.com,DIRECT
- DOMAIN-SUFFIX,163.com,DIRECT
- DOMAIN-SUFFIX,126.net,DIRECT

# ---------- 兜底 ----------
- GEOIP,CN,DIRECT,no-resolve
- MATCH,PROXY
XRAY_RULES_PAYLOAD
bash "$work/install-xray.sh" --install
bash /usr/local/sbin/xray-admin --export
echo
echo '安装完成。'
echo '日常维护：xray-admin（含查看订阅地址、编辑规则）'
