# 测试说明

这些测试只使用合成地址和一次性容器，不会访问你的 VPS，也不会替你验证公网端口映射。

## 主回归（一次性 Debian 容器）

```bash
docker build -t personal-xray-review:local -f tests/Dockerfile .
docker run --rm \
  --mount type=bind,source="$PWD",target=/work,readonly \
  personal-xray-review:local bash /work/tests/run-all.sh
```

`run-all.sh` 覆盖参数校验、订阅生成/CGI/额度头、交互默认值、安装事务和失败回滚。真实 systemd 测试需要单独启动带 systemd PID 1 的容器；`run-all.sh` 在普通 review 容器里会明确跳过它。

## 真实 systemd 安装测试

需要一次性 systemd 容器、`/release.zip` 夹具和 root 权限，详见 `tests/test-real-systemd.sh` 顶部注释。它会清理该容器内的 Xray 状态，**不要在生产 VPS 上直接运行**。

```bash
docker exec xray-review-systemd bash /work/tests/test-real-systemd.sh
```

## 主机侧测试

```bash
bash tests/test-public-bundle.sh
powershell -ExecutionPolicy Bypass -File tests/test-json-render.ps1
powershell -ExecutionPolicy Bypass -File tests/test-generate-flclash-profile.ps1
```

## 未覆盖

- 公网 IP、云平台端口映射、防火墙和运营商封锁。
- 真实客户端的 TUN、DNS、规则命中和长期稳定性。
- 供应商套餐的真实流量/重置日。
