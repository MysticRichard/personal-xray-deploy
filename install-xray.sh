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
  printf 'Subscription: public %s -> guest TCP port %s\n' "${SUB_PUBLIC_PORT:-$LISTEN_PORT}" "${SUB_LISTEN_PORT:-2096}"
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
  fi
  # Enforce on every run: a pre-existing or restored file may be world-readable.
  chmod 600 /etc/xray-sub/token
  chown root:root /etc/xray-sub/token
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

  # busybox may not be installed (minimal images), and the service user must be
  # able to read the quota file that the CGI prints as a header.
  if ! command -v busybox >/dev/null 2>&1; then
    echo '安装 busybox（订阅服务需要它提供静态 HTTP）'
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends busybox >/dev/null 2>&1 \
      || fail 'busybox 安装失败'
  fi
  local busybox_bin
  busybox_bin=$(command -v busybox) || fail '找不到 busybox'
  if ! id -u xray-sub >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin xray-sub || fail '无法创建 xray-sub 用户'
  fi
  chown root:xray-sub /etc/xray-sub/userinfo 2>/dev/null || true
  chmod 640 /etc/xray-sub/userinfo 2>/dev/null || true

  install -m 755 "$SELF_DIR/xray-sub.service" /tmp/xray-sub.service.tpl
  sed -e "s#__SUB_PORT__#$sub_port#g" \
      -e "s#__BUSYBOX__#$busybox_bin#g" \
      /tmp/xray-sub.service.tpl > /etc/systemd/system/xray-sub.service
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
      cat > /etc/systemd/system/xray-sub.service <<UNIT
[Unit]
Description=Personal Clash subscription (minimal)
After=network.target

[Service]
Type=simple
ExecStart=${busybox_bin} httpd -f -p 127.0.0.1:${sub_port} -h /srv/sub
Restart=always
RestartSec=5
User=xray-sub
Group=xray-sub
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
