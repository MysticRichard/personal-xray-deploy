# Alpine 版一键部署（1C / 128MB / 1GB / Podman）

`one-click-alpine.sh` 是 [`personal-xray-deploy`](https://github.com/MysticRichard/personal-xray-deploy) 的 Alpine 移植版，
针对 **Alpine + Podman 的 128MB 小鸡**重写，协议仍是 **VLESS + XTLS-Vision + REALITY**。

---

## 1. 为什么原版脚本在这台机器上跑不起来

原 `one-click.sh` 第 9 行就是硬门禁：

```bash
[[ -f /etc/debian_version && -d /run/systemd/system ]] || { echo '需要 Debian + systemd'; exit 1; }
```

| 原脚本依赖 | Alpine 上的现实 |
|---|---|
| `/etc/debian_version` + systemd PID 1 | 只有 `/etc/alpine-release`，OpenRC，容器里连 init 都没有 |
| 44 处 `systemctl`、两个 `.service` unit | 没有 systemd，`daemon-reload` 必然失败，`set -e` 直接中止 |
| `apt-get install` 装依赖 | 包管理器是 `apk` |
| `install(1)`、`free`、`journalctl` | busybox 的 `install` 语义不全，日志没有 journal |

所以不是"改两行就能跑"，是整套服务托管模型要换。

## 2. 这一版做了什么

| 维度 | Debian 版 | Alpine 版（本脚本） |
|---|---|---|
| 依赖 | apt-get | `apk add curl openssl unzip jq ca-certificates iproute2 procps openrc` |
| 守护进程 | systemd unit | OpenRC `supervise-daemon`（崩溃 5 秒后自动拉起） |
| 容器内启动 | 依赖 systemd 存在 | 自动识别容器，`/etc/local.d/` + `rc-update` 双兜底 |
| 日志 | journald | `/var/log/xray/xray.log`（由启动器重定向） |
| 二进制 | Xray 静态 Go 版 | 同一个包，校验和一致（musl 下同样能跑，已验证无 `.interp`） |
| geoip.dat | 必装（18.5MB） | **默认不装**，用内置 `geoip:private` + 显式私网 CIDR；`--with-geo` 才启用 `geoip:cn` 阻断 |
| 内存 | GOMEMLIMIT=48MiB | 同上，128MB 机器实测够用 |
| 订阅服务 | busybox httpd + systemd | busybox httpd + OpenRC，同一套 CGI/令牌/额度头 |
| 订阅规则 | 298KB 的 `rules.template.yaml` | 内置 7 条精简规则；需要时 `/etc/xray-sub/rules.yaml` 覆盖 |

保留的能力：REALITY 密钥复用、订阅令牌、`Subscription-Userinfo` 额度头、备份/回滚、管理菜单、`--verify` 回环真跑。

## 3. 协议选型：为什么只留这一种

| 协议 | 抗主动探测 | 要域名/证书 | 128MB 机器 | 判断 |
|---|---|---|---|---|
| **VLESS + REALITY + Vision** | **强**（复用真实站点握手，无自签证书特征） | **不需要** | 低（~30MB） | ✅ 本脚本 |
| Hysteria2 / TUIC | 强（QUIC） | 需要（可自签） | 中 | 速度好，但 UDP 易被 QoS，可作二节点 |
| Trojan | 中 | 需要域名+真证书 | 低 | 有 TLS 指纹与流量特征 |
| VMess + WS + TLS | 弱（TLS in TLS） | 需要 | 低 | ❌ |
| Shadowsocks | 弱（无 TLS，可被主动探测） | 不需要 | 低 | ❌ |
| WireGuard | 弱（握手指纹固定、纯 UDP） | 不需要 | 低 | ❌ |

REALITY 的关键优势：**不需要买域名、不需要证书**，客户端 SNI 指向真实大站（如 `www.apple.com`），
中间人探测只会看到一次正常 TLS 握手，无法用"证书自签/域名不匹配"来判定。

## 4. 安装

```bash
# Alpine 默认没有 bash，先装
apk add --no-cache bash curl

# 交互式
bash one-click-alpine.sh

# 无人值守
bash one-click-alpine.sh install --yes \
  --server 104.223.38.32 \
  --port 443 \
  --sub-port 2096 \
  --target www.apple.com:443 \
  --plan-total 200GB --plan-reset-day 1
```

装完会打印订阅地址，形如：

```
http://104.223.38.32:2096/cgi-bin/<32位令牌>
```

**必须在平台面板里放行/映射**：代理端口（默认 443）和订阅端口（默认 2096）两条 TCP。

### 128MB 机器强烈建议先加 128MB swap

```bash
dd if=/dev/zero of=/swapfile bs=1M count=128
chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

## 5. 常用命令

```bash
bash one-click-alpine.sh status     # 进程/端口/内存（= xray-admin --status）
bash one-click-alpine.sh restart    # 先 -test 校验配置再重启
bash one-click-alpine.sh sub        # 打印订阅地址
bash one-click-alpine.sh verify     # 起临时 socks，回环真实跑一次代理请求
bash one-click-alpine.sh manage     # 管理菜单
bash one-click-alpine.sh uninstall  # 卸载（保留 /etc/xray-sub 与备份）
xray-admin --sub                    # 装好后也可直接用
```

`verify` 通过说明 **UUID / flow / REALITY 目标 / 密钥** 全对；不通过就去看
`/var/log/xray/xray.log`，不要再怀疑客户端。

## 6. 订阅与额度

- 令牌：`/etc/xray-sub/token`（600，root）
- 订阅端口：`/etc/xray-sub/{port,public_port}`
- 额度头：`/etc/xray-sub/userinfo`
  → `upload=字节; download=字节; total=字节; expire=时间戳`
- 规则：`/etc/xray-sub/rules.yaml`（不存在则用内置规则，最后一行必须是 `MATCH,PROXY`）

改完规则执行 `xray-admin` 菜单 6（或直接跑 `/usr/local/sbin/xray-sub`）重新生成，
FlClash 里下拉刷新即可。

> 额度是**手动快照**，只用于客户端显示，不做真实统计和限速 —— 与原版一致。
> 需要真实限速请上 3x-ui 那类面板（但它要 200MB+ 内存，128MB 跑不动）。

## 7. 排错

| 现象 | 检查 |
|---|---|
| `apk add` 失败 | `cat /etc/apk/repositories`，换国内源 `sed -i 's#dl-cdn.alpinelinux.org#mirrors.aliyun.com#' /etc/apk/repositories` |
| 下载 Xray 失败 | 脚本已内置 4 个 GitHub 镜像自动测速；仍失败就设 `XRAY_ARCHIVE=/root/Xray-linux-64.zip` |
| 启动失败 | `tail -50 /var/log/xray/xray.log`；`df -h /` 看是不是磁盘满了 |
| 进程在跑但客户端连不上 | 先 `verify`；再确认平台安全组放行了公网端口 → 实例端口 |
| 订阅 404 | 令牌换了：重跑 `xray-admin` 菜单 4 看新地址 |
| 订阅能打开但节点不通 | 平台只映射了订阅端口，代理端口没映射 |

## 8. GitHub 上"成熟脚本"的对比（为什么还是自己这份）

| 项目 | Star | 能不能直接用在 Alpine |
|---|---|---|
| `MHSanaei/3x-ui` | ~49k | ❌ 面板要 200MB+ 内存，且 systemd 托管 |
| `XTLS/Xray-core` | ~42k | ✅ 但只是内核，没有部署逻辑 |
| `SagerNet/sing-box` | ~39k | ✅ 同上，纯内核 |
| `mack-a/v2ray-agent` | ~22k | ❌ 脚本写死 apt/yum + systemd |
| `yonggekkk/sing-box-yg` | ~10k | ❌ 同上 |
| `XTLS/REALITY` | ~5.6k | ✅ 协议说明，不是脚本 |
| `233boy/sing-box` / `233boy/Xray` | ~5.2k / ~2.8k | ❌ systemd 一键脚本 |
| `zhangweixy666/suoha-plus` | <10 | 声称支持 OpenRC，但项目太新、无人验证 |

结论：**成熟脚本 = Debian/Ubuntu + systemd**，你的镜像是 Alpine + Podman，
最省事的路是用这份脚本把内核直接跑在 Alpine 上（不套 podman，省 60MB+ 内存）。

## 9. 安全提示

- 订阅走的是 **HTTP 明文**（令牌即凭据），不要发到群里/截图里。
- `/root/xray-backups/` 和 `/root/xray-subscription.txt` 含密钥与令牌，别上传公开仓库。
- 单用户模板：UUID 泄露 = 节点泄露，重装时脚本会**复用**已有 UUID，想换人用就删掉
  `/usr/local/etc/xray/client.json` 再装一次。
