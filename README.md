# 个人 Xray 部署脚本

一键安装 VLESS + Vision + REALITY 节点，并自动生成 FlClash 订阅地址。适合 128 MB 低配 Debian VPS。

## 一条命令安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MysticRichard/personal-xray-deploy/main/one-click.sh)
```

安装过程会问五项，其中只有前三项必须填：

| # | 项目 | 说明 |
|---|---|---|
| 1 | 公网 IP 或域名 | 平台显示的公网地址 |
| 2 | 公网 TCP 端口 | 端口转发表的「外部端口」 |
| 3 | 内部 TCP 端口 | 端口转发表的「内部端口」；无 NAT 时与公网端口相同 |
| 4 | REALITY 目标 | 直接回车用 `www.microsoft.com:443` |
| 5 | serverName | 直接回车用 `www.microsoft.com` |

装完会直接打印订阅地址：

```text
订阅地址（复制到 FlClash 的「订阅」里）：

  http://<公网地址>:<端口>/<令牌>/config.yaml
```

粘进 FlClash 就能用，不需要手动填节点。

## 日常维护

```bash
xray-admin
```

```text
1. 状态、端口与内存
2. 最近日志
3. 检查配置并重启
4. 查看订阅地址
5. 编辑分流规则
6. 重新生成订阅
7. 备份
8. 导出客户端节点
0. 退出
```

## 规则怎么改

两条规则文件：

| 文件 | 用途 |
|---|---|
| `/etc/xray-sub/rules.yaml` | 通用规则，随仓库公开 |
| `/etc/xray-sub/rules.local.yaml` | 你的私有规则，不进仓库 |

私有规则排在通用规则之前，优先匹配。

```bash
xray-admin
# 5 编辑通用规则
# 6 编辑私有规则
```

改完自动重新生成，FlClash 下拉刷新即可。格式不对会拒绝生成，不会破坏已有订阅。

详见 [docs/subscription.md](docs/subscription.md)。

## 为什么规则不放进 Xray

`PROCESS-NAME`、`GEOIP,CN`、`AND(...)`、`SUB-RULE` 都是客户端专有能力，服务端无法执行。

所以规则以 YAML 形式存在 VPS 上，通过订阅下发；FlClash 负责实际分流。好处是集中管理、一处修改、多设备同步。

## 需要提前知道

- 仅支持 **Debian amd64 + systemd**。
- 不修改端口映射、防火墙、APT 源或内核参数。
- 订阅和代理都需要在云平台做好端口转发。
- 配置能降低被动识别概率，但不保证 IP 永不被封。
- 128 MB 是下限，已针对性做内存优化，但仍建议条件允许时升级。

## 文件说明

| 文件 | 用途 |
|---|---|
| `one-click.sh` | 单文件入口：安装 + 订阅 + 菜单 |
| `install-xray.sh` | 安装器本体，供分步执行或诊断 |
| `xray-sub` | 从规则模板生成订阅 |
| `xray-admin` | 中文维护菜单 |
| `rules.template.yaml` | 规则模板，安装时复制到 `/etc/xray-sub/rules.yaml` |
| `generate-flclash-profile.ps1` | 备选：把节点直接合并进已有 FlClash 配置 |
| `check-vps.sh` | 只读环境检查 |
| `probe-targets.sh` | 只读目标站检测 |
| `docs/` | 订阅、部署、执行方式说明 |
| `tests/` | 本地与容器测试 |

## 测试

```bash
bash tests/test-subscription.sh     # 订阅生成与校验
bash tests/test-public-bundle.sh    # 无实例参数或凭据泄露
bash tests/test-preflight-http.sh   # 预检策略回归
```

Windows 侧生成器测试：

```powershell
powershell -ExecutionPolicy Bypass -File tests/test-generate-flclash-profile.ps1
```
