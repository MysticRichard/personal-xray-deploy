# 订阅与规则

安装完成后脚本会打印订阅地址。粘进 FlClash 的「订阅」即可使用。

## 随时查看订阅地址

```bash
xray-admin --sub
```

输出订阅地址。订阅地址含随机令牌，等同凭据，不要公开。

## 换电脑 / 换 VPS

### 只换电脑

VPS 不变时，新电脑只需把 `xray-admin --sub` 输出的地址粘到 FlClash。服务器下发公共规则，客户端继续使用你自己的本地私有覆写。

### 换 VPS

VPS 换掉后，订阅地址和节点凭据会变。新服务器安装完成后，用新地址导入 FlClash；把你电脑上私有覆写文件中的规则复制到新电脑的 FlClash 本地 override/script 中。私有规则不存 VPS、不进订阅、不进仓库。

## 流量额度与套餐

一键部署会询问：

```text
月流量：100GB / 1TB / 0=不限（按 1024 进制）
流量重置日：1-31，0=无固定重置日
套餐到期日：YYYY-MM-DD，0=长期有效
```

这些值写入 `/etc/xray-sub/provider-plan`（root 600）；`xray-admin --plan` 或菜单 13 可查看。月流量和到期日会作为 `Subscription-Userinfo` 的 `total`/`expire` 首次写入 `/etc/xray-sub/userinfo`，其中 `upload=0; download=0` 只是占位，不是真实已用量。

`Subscription-Userinfo` 标准字段只有：

```text
upload
download
total
expire
```

**没有重置日字段**，客户端不会显示“每月几号重置”。重置日只作为私有元数据展示。

`xray-admin` 的额度设置是手动快照，不是供应商真实统计、不是限流，也没有自动月度重置。供应商真实套餐、月度流量和重置日请以供应商后台为准；脚本无法自动读取它们。

## 规则归属

| 规则 | 所在位置 |
|---|---|
| 公共通用规则 | VPS `/etc/xray-sub/rules.yaml`，随订阅下发 |
| 你的 NAS、Tailscale、内网等私有规则 | FlClash 本地 override/script，仅在客户端保存 |

公共规则不包含你的设备域名、私有 IP 或 Tailscale 地址。客户端本地私有规则应放在公共规则和 `MATCH,PROXY` 之前，避免被兜底规则抢先命中。

示例（只放在 FlClash 本地覆写/脚本，不要上传）：

```yaml
rules:
  - DOMAIN,my-device.example.invalid,DIRECT
  - IP-CIDR,192.0.2.10/32,DIRECT,no-resolve
```

规则不能全部放进 Xray：`PROCESS-NAME`、客户端 `GEOIP`、Clash `AND` 和 `SUB-RULE` 都依赖客户端。

## 订阅端口

订阅和代理不能共用端口。代理 REALITY 使用一个端口，订阅 HTTP 使用另一个端口；两项公网/内部端口都在安装时填写。平台端口映射由用户自己配置。

订阅内部端口必须 **≥1024**，因为 HTTP 服务以非 root 用户运行；订阅公网端口可以是 80/443 等低端口，由平台转发到内部端口即可。

## 订阅传输

当前订阅是 **HTTP**，随机令牌只控制访问，不加密传输。不要在公共场合粘贴带令牌的地址；如果网络环境不可信，应先加一层 HTTPS 反向代理或改用受控的传输方式。
