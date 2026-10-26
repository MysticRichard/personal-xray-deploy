# 执行方式对比

仓库是公开的，所以可以直接一条命令运行，不需要任何 GitHub 登录。

## 推荐：管道直接执行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/MysticRichard/personal-xray-deploy/main/one-click.sh)
```

`bash <(...)` 让脚本从管道读入，不落盘、不依赖其他文件。已测试这种执行方式可以完整安装。

## 备选：先下载再执行

想先检查内容再运行：

```bash
curl -fsSL https://raw.githubusercontent.com/MysticRichard/personal-xray-deploy/main/one-click.sh -o /root/one-click.sh
less /root/one-click.sh
bash /root/one-click.sh
```

## 为什么不用 curl | bash

`curl ... | bash` 也可以运行，但脚本里有交互提问，管道方式下 stdin 被 curl 占用，`read` 会读不到你的输入。`bash <(...)` 把脚本作为文件描述符传入，stdin 仍然留给终端，交互正常。

如果必须用管道，可以显式接回终端：

```bash
curl -fsSL https://raw.githubusercontent.com/MysticRichard/personal-xray-deploy/main/one-click.sh | bash -s < /dev/tty
```

## 换 VPS 后

同一个命令可以重复使用，参数每次都重新询问，不写死在脚本里。

如果新机器已经装过本脚本，想完全重新开始，先删除状态：

```bash
rm -f /usr/local/etc/xray/client.json
```

否则会沿用旧的 UUID、密钥和地址端口。
