# 订阅与规则

安装完成后脚本会打印订阅地址。粘进 FlClash 的「订阅」即可使用，不用手动填节点。

## 地址形式

```text
http://<公网地址>:<订阅公网端口>/<随机令牌>/config.yaml
```

令牌是安装时随机生成的 32 位十六进制串，等于订阅密码，不要公开。

## 两个端口，别混

| 用途 | 公网 | 实例内部 |
|---|---|---|
| 代理节点 | 平台分配 | Xray 监听端口 |
| 订阅 | 平台分配 | 2096（固定） |

订阅**不能**共用代理端口。共用只有两种做法：改 REALITY fallback（会让探测者直接看到你的订阅页，伪装失效），或前置 nginx 做 SNI 分流（128 MB 机器上不值得）。所以订阅独立一个端口，内部固定 2096，公网端口由你在平台映射。

脚本会问一次「订阅公网端口」，填平台映射到 2096 的那个即可。之后用 `xray-admin` 选 8 可以随时改，不需要动平台。

## 两份规则文件

| 文件 | 内容 | 是否进仓库 |
|---|---|---|
| `/etc/xray-sub/rules.yaml` | 通用规则（公共域名/IP） | 是，公开 |
| `/etc/xray-sub/rules.local.yaml` | 你的私有规则 | **否，永不公开** |

合并顺序：

```text
rules.local.yaml  →  rules.yaml  →  结束
```

私有规则排在前面，所以一定优先于通用规则和 `MATCH`。

## 怎么写私有规则

```bash
xray-admin   # 选 6，自动创建并打开编辑器
```

或者手动：

```bash
nano /etc/xray-sub/rules.local.yaml
xray-sub
```

格式：每行一条，`- ` 开头，`#` 是注释。

示例（以下只是格式说明，不是真实配置）：

```yaml
- DOMAIN,your-nas.example.net,DIRECT
- IP-CIDR,198.51.100.10/32,DIRECT,no-resolve
- IP-CIDR6,2001:db8::/32,DIRECT,no-resolve
```

## 校验行为

`xray-sub` 会拒绝生成并**保留旧文件不覆盖**，当出现：

- 任一文件里出现非注释、非 `- ` 开头的行
- 通用规则为空
- 生成的订阅缺少节点或规则

私有规则写错不会把你已有的订阅弄坏。

## 顺序原则

从上到下匹配，第一条命中生效：

1. 私有规则
2. 内网、局域网 CIDR → DIRECT
3. 路由器管理页 → DIRECT
4. AI 服务 → PROXY
5. 开发与内容站 → PROXY
6. 国内常用服务 → DIRECT
7. `GEOIP,CN` → DIRECT
8. `MATCH,PROXY`

## 关于把规则放进 Xray

做不到。这些是客户端专有能力：

| 规则 | 服务端为什么不行 |
|---|---|
| `PROCESS-NAME` | 看不到你电脑上的进程 |
| `GEOIP,CN` | 依赖客户端 GeoIP 库 |
| `AND,((DST-PORT,443),(NETWORK,UDP))` | Clash 专有语法 |
| `SUB-RULE` | 需要客户端规则集 |

所以规则存在 VPS 上统一管理，通过订阅下发，FlClash 执行。

## 私密性

订阅文件只含节点参数和规则，**不含服务端私钥**（测试有断言检查）。

但 UUID 和公钥足以连上你的节点，所以订阅地址等同凭据。

## 卸载订阅

```bash
systemctl disable --now xray-sub
rm -rf /srv/sub /etc/xray-sub /etc/systemd/system/xray-sub.service
```

不影响 Xray 节点本身。
