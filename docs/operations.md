# 日常运维命令

以下命令均在 VPS 的 root shell 执行。`<...>` 替换为你的实际公网地址/端口；不要把订阅 token、UUID、私钥或完整订阅 URL 贴到公开地方。

## 一键安装 / 重装

公共入口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MysticRichard/personal-xray-deploy/main/one-click.sh)
```

交互会依次询问十项：

1. 公网 IP 或域名
2. 代理公网 TCP 端口
3. 代理内部 TCP 端口
4. REALITY 目标（默认 `www.apple.com:443`）
5. REALITY serverName（默认跟随目标）
6. 订阅公网 TCP 端口
7. 订阅内部 TCP 端口（须 ≥1024）
8. 月流量（`100GB` / `1TB` / `0`=不限，按 1024 进制）
9. 流量重置日（`1`～`31`，`0`=无固定重置日）
10. 套餐到期日（`YYYY-MM-DD`，`0`=长期有效）

明确无人值守时可以用环境变量：

```bash
NONINTERACTIVE=1 \
SERVER_ADDRESS=<公网IP或域名> \
PUBLIC_PORT=<代理公网端口> \
LISTEN_PORT=<代理内部端口> \
REALITY_DEST=www.apple.com:443 \
REALITY_SERVER_NAME=www.apple.com \
SUB_PUBLIC_PORT=<订阅公网端口> \
SUB_LISTEN_PORT=<订阅内部端口≥1024> \
PLAN_TOTAL=100GB \
PLAN_RESET_DAY=1 \
PLAN_EXPIRE=2027-10-26 \
bash <(curl -fsSL https://raw.githubusercontent.com/MysticRichard/personal-xray-deploy/main/one-click.sh)
```

重装会保留已有 UUID、密钥和订阅 token，但仍应先备份。已有 `/etc/xray-sub/rules.yaml` 默认不会被覆盖；不会自动把线上规则换成 8,633 条模板。

## 套餐信息

```bash
xray-admin --plan
# 或菜单 13
```

显示月流量、重置日和到期日。月流量/到期日首次安装会写入订阅额度头；`upload=0; download=0` 是占位，不是真实已用量。重置日没有标准客户端字段，只在 `xray-admin --plan` 展示。

## 查询订阅地址

```bash
xray-admin --sub
```

或：

```bash
xray-admin
# 选择 4 查看订阅地址
```

修改了 REALITY 目标或 `client.json.server_name` 后：

```bash
/usr/local/sbin/xray-sub
xray-admin --sub
```

然后在 FlClash/Shadowrocket 中**删除旧 VPS 订阅并重新导入**，不要只下拉刷新；旧 URL 可能已经 404。

## 服务状态、重启与日志

```bash
systemctl status xray xray-sub --no-pager -l
systemctl restart xray
systemctl restart xray-sub
systemctl restart xray xray-sub
systemctl daemon-reload
```

只有修改 systemd unit 时才需要 `daemon-reload`；只改 Xray 配置时重启 `xray` 即可。

```bash
journalctl -u xray -n 50 --no-pager
journalctl -u xray-sub -n 50 --no-pager
journalctl -u xray -f
```

检查监听端口（从状态/订阅文件读取内部端口，不猜）：

```bash
proxy_internal=$(jq -r '.listen_port // .port' /usr/local/etc/xray/client.json)
sub_internal=$(tr -d '\r\n' </etc/xray-sub/port)
echo "proxy=$proxy_internal subscription=$sub_internal"
ss -lntp | grep -E ":($proxy_internal|$sub_internal)\b"
```

## 配置检查与版本

```bash
/usr/local/bin/xray -version
# 当前兼容基线应为 Xray v26.6.27

XRAY_LOCATION_ASSET=/usr/local/share/xray \
  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

或：

```bash
xray-admin
# 选择 3 检查配置并重启
```

v26.7.11+ 的 REALITY `minClientVer` 默认值会拒绝 mihomo/FlClash。**不要只跑 `xray -test` 就升级**；升级必须用 FlClash/Shadowrocket 实测。

## 订阅本地自检

```bash
tok=$(tr -d '\r\n' </etc/xray-sub/token)
port=$(tr -d '\r\n' </etc/xray-sub/port)
curl -fsS -D - "http://127.0.0.1:${port}/cgi-bin/${tok}" -o /dev/null | head
```

应看到 HTTP 200、`Content-Type: text/yaml`；设置额度时还会看到 `Subscription-Userinfo`。不要打印 `$tok`。

## 公网端口检查

在本地 Windows PowerShell：

```powershell
Test-NetConnection <公网IP> -Port <代理公网端口> -InformationLevel Quiet
Test-NetConnection <公网IP> -Port <订阅公网端口> -InformationLevel Quiet
```

两个都 False 时先查平台端口映射/防火墙，不要重装节点。

## 备份

```bash
xray-admin
# 选择 11 备份
```

手动备份：

```bash
stamp=$(date -u +%Y%m%dT%H%M%SZ)
tar -czf "/root/xray-backup-${stamp}.tar.gz" \
  -C / usr/local/etc/xray etc/xray-sub etc/systemd/system/xray.service \
  etc/systemd/system/xray-sub.service usr/local/bin/xray usr/local/share/xray/geoip.dat srv/sub
chmod 600 "/root/xray-backup-${stamp}.tar.gz"
```

备份含 token/密钥，下载到电脑后不要公开。

## 规则

查看当前公共规则条数：

```bash
grep -c '^- ' /etc/xray-sub/rules.yaml
```

编辑与重新生成：

```bash
xray-admin
# 选择 5 编辑通用规则
# 选择 7 重新生成订阅
```

格式错误时生成器会拒绝并保留旧订阅。仓库的公共模板是 8,633 条；重装默认保留已有规则文件，不会自动覆盖。若要把线上订阅换成完整公共模板，先备份：

```bash
cp -p /etc/xray-sub/rules.yaml /root/rules-before-reset.yaml
cp /path/to/rules.template.yaml /etc/xray-sub/rules.yaml
/usr/local/sbin/xray-sub
```

私有设备规则（NAS、Tailscale、内网）只放在客户端本地覆写，不放进 VPS 订阅。

## 流量额度

```bash
xray-admin
# 选择 9 设置流量额度
```

`Subscription-Userinfo` 只支持 `upload/download/total/expire`，没有标准的重置日字段，也不会自动按月归零。这里填写的是**手动显示快照**，不是供应商真实统计。供应商月流量、重置日和到期日请以供应商后台为准；不要写死在公开脚本里。

## FlClash / Shadowrocket

1. 用 `xray-admin --sub` 取当前订阅地址。
2. 删除旧 VPS 订阅，重新导入。
3. 选中新配置，`PROXY` 组明确选 `Personal-VPS`。
4. 测试 `https://api.ipify.org`，出口应为 VPS 公网 IP。
5. 不要只切“全局模式”而不选 GLOBAL 里的节点。

## 兼容性基线

- Xray **v26.6.27**
- 传输 **tcp**
- REALITY 目标/SNI **`www.apple.com`**
- 已知问题：v26.7.11+ 默认 `minClientVer=26.3.27`，会拒绝 mihomo/FlClash 上报的 `1.8.2`；v26.6.27 + Microsoft 目标会 EOF。

升级 Xray 前先用 FlClash/Shadowrocket 实测，失败时保留 `/root/xray-26.10.21-backup` 和配置备份回滚。
