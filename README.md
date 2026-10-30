# 个人 Xray 部署脚本

一键安装 VLESS + Vision + REALITY 节点，并自动生成 FlClash 订阅地址。适合 128 MB 低配 Debian VPS。

## 一条命令安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MysticRichard/personal-xray-deploy/main/one-click.sh)
```

安装过程会依次询问十项。第 4、5 项和套餐项有默认值，其余按平台实际填写；重复安装会把已保存值作为默认值显示，但仍会逐项询问：

| # | 项目 | 说明 |
|---|---|---|
| 1 | 公网 IP 或域名 | 平台显示的公网地址 |
| 2 | 代理公网 TCP 端口 | 端口转发表的「外部端口」 |
| 3 | 代理内部 TCP 端口 | 端口转发表的「内部端口」；无 NAT 时与公网端口相同 |
| 4 | REALITY 目标 | 默认 `www.apple.com:443`，仅作起始值；每次安装都会复验 TLS 1.3、h2 和证书，可按需换成自己的目标 |
| 5 | serverName | 默认跟随目标域名，必须与目标 host 一致 |
| 6 | 订阅公网 TCP 端口 | 端口转发表的订阅「外部端口」 |
| 7 | 订阅内部 TCP 端口 | 必须 ≥1024；订阅 HTTP 服务以非 root 用户运行 |
| 8 | 月流量 | 示例 `100GB`、`1TB`、`0`=不限；按 1024 进制换算为字节 |
| 9 | 流量重置日 | `1`～`31`，`0`=无固定重置日；只记录/展示，不是客户端标准字段 |
| 10 | 套餐到期日 | `YYYY-MM-DD`，`0`=长期有效；写入订阅 `expire` |

装完会直接打印订阅地址：

```text
订阅地址（复制到 FlClash 的「订阅」里）：

  http://<公网地址>:<订阅公网端口>/cgi-bin/<令牌>
```

粘进 FlClash 就能用，不需要手动填节点。订阅目前是 **HTTP**：随机令牌只控制访问，不加密传输；不要把这个地址发到公开地方。

## 日常维护

```bash
xray-admin
```

```text
1. 状态、端口与内存
2. 最近日志
3. 检查配置并重启
4. 查看订阅地址
5. 编辑通用规则（rules.yaml）
6. 私有规则迁移说明
7. 重新生成订阅
8. 修改订阅公网端口
9. 设置流量额度（手动快照）
10. 导出订阅信息到文件
11. 备份
  12. 导出客户端节点
  13. 套餐信息（月流量/重置日/到期日）
0. 退出
```

常用命令、重启、日志、订阅自检和备份说明见 [`docs/operations.md`](docs/operations.md)。

## 规则怎么改

VPS 只保存一份公共规则 `/etc/xray-sub/rules.yaml`，随订阅下发：

```bash
xray-admin
# 5 编辑公共规则
```

改完自动重新生成，FlClash 下拉刷新即可。格式不对会拒绝生成，不会破坏已有订阅。

你的 NAS、Tailscale、内网设备规则**只放在客户端**，不要上传 VPS：

1. 在 FlClash 的本地覆写/脚本中，把私有规则放在公共规则和 `MATCH,PROXY` 之前。
2. 可参考仓库里的 `client-private.example.yaml`；它只有示例地址，不含真实设备。
3. 不要直接把订阅里的 `rules:` 整段替换成私有规则，否则会丢失公共分流。

公共规则不包含你的设备域名、私有 IP 或 Tailscale 地址。详见 [docs/subscription.md](docs/subscription.md)。

## 为什么规则不放进 Xray

`PROCESS-NAME`、`GEOIP,CN`、`AND(...)`、`SUB-RULE` 都是客户端专有能力，服务端无法执行。

所以规则以 YAML 形式存在 VPS 上，通过订阅下发；FlClash 负责实际分流。好处是集中管理、一处修改、多设备同步。

## 需要提前知道

- 仅支持 **Debian amd64 + systemd**。
- 不修改端口映射、防火墙、APT 源或内核参数。
- 订阅和代理都需要在云平台做好端口转发。
- 配置能降低被动识别概率，但不保证 IP 永不被封。
- 128 MB 是下限，已针对性做内存优化，但仍建议条件允许时升级。
- 订阅是 HTTP，令牌只控制访问，不加密传输。
- 流量额度是手动显示快照，不自动统计、限流或按月重置；真实套餐以供应商后台为准。
- 部署时会询问月流量、重置日、到期日；月流量/到期日会写入订阅额度头，重置日只在 `xray-admin --plan`/私有记录中展示，客户端没有标准重置日字段。
- 私有设备规则只保存在客户端 FlClash，不进 VPS、不进订阅、不进公开仓库。
- 安装器自动探测 GitHub 官方与加速前缀并选最快源；也可用 [`docs/operations.md`](docs/operations.md) 的 `XRAY_URL`/`XRAY_ARCHIVE` 兜底；仍强制 SHA256 校验。
- 预检会强制 IPv4 并打印目标 TLS 失败原因；目标不通时按 `docs/operations.md` 探测并更换目标，不要绕过证书校验。
- 安装器锁定 Xray **v26.6.27 + tcp + Apple 目标**，这是实测与 FlClash/mihomo 兼容的组合；v26.7.11+ 的 REALITY `minClientVer` 默认值会拒绝 mihomo。

## 文件说明

| 文件 | 用途 |
|---|---|
| `one-click.sh` | 单文件入口：安装 + 订阅 + 菜单 |
| `install-xray.sh` | 安装器本体，供分步执行或诊断 |
| `xray-sub` | 从规则模板生成订阅 |
| `xray-admin` | 中文维护菜单 |
| `rules.template.yaml` | 公共规则模板，安装时复制到 `/etc/xray-sub/rules.yaml` |
| `client-private.example.yaml` | 客户端私有规则示例，不含真实设备 |
| `generate-flclash-profile.ps1` | 备选：把节点直接合并进已有 FlClash 配置 |
| `check-vps.sh` | 只读环境检查 |
| `probe-targets.sh` | 只读目标站检测 |
| `docs/operations.md` | 订阅查询、服务重启、日志、备份、额度等常用命令 |
| `docs/` | 订阅、部署、执行方式说明 |
| `tests/` | 本地与容器测试 |

## 测试

```bash
bash tests/test-validation-behaviour.sh   # 参数/端口校验真实行为
bash tests/test-plan-validation.sh        # 100GB/1TB/日期/重置日格式
bash tests/test-entrypoint-prompts.sh     # 十项交互、套餐示例与默认值
bash tests/test-public-bundle.sh          # 无实例参数或凭据泄露
bash tests/test-preflight-http.sh         # 预检策略回归
```

完整回归和真实 systemd 安装测试需要 review 容器，命令见 [`tests/README.md`](tests/README.md)。Windows 侧生成器测试：

```powershell
powershell -ExecutionPolicy Bypass -File tests/test-generate-flclash-profile.ps1
```
