# ACME Manager

ACME Manager 是一个 Bash 数字菜单和 CLI 管理层，复用 [acme.sh](https://github.com/acmesh-official/acme.sh) 完成 ACME 协议、DNS-01 验证、账户存储、证书续期和部署。它不建立独立数据库，不覆盖已有的 acme.sh 证书和账户。

## 已实现

- Let's Encrypt、ZeroSSL；Cloudflare、腾讯云 DNSPod、阿里云 AliDNS
- 单域名、泛域名、多 SAN；ECC P-256 和 RSA 2048/3072/4096
- 证书列表、详情、签发、续期、部署、删除、可选撤销和过期检查
- `--install-cert` 自定义路径以及受控 Reload Hook
- DNS 凭据隐藏输入并写入 acme.sh 原生 `account.conf`，文件权限为 `0600`
- SMTP 配置复用 acme.sh notify hook；配置和测试命令不会把密码写入管理器配置或日志
- acme.sh 原生 Cron 安装/检查/移除，不创建第二套调度器
- 白名单配置解析、`doctor`、日志、非交互命令和安装/卸载脚本
- 纯 Bash 彩色终端界面：状态条、分组菜单、统一提示色、子菜单返回和 `NO_COLOR` 无色模式
- 单个裸域名默认同时申请根域名和通配符；使用 `--no-wildcard` 可关闭此行为
- 交互式签发成功后自动进入部署流程，沿用本次选择的域名和密钥类型

## 安装

```bash
sudo ./install.sh
sudo acme-manager doctor
sudo acme-manager menu
```

也支持从 GitHub 直接安装：

```bash
curl -fsSL https://raw.githubusercontent.com/leeechsh/acme-manager/main/install.sh | sh
```

已安装版本可以直接更新管理器代码：

```bash
sudo acme-manager update
# 或
curl -fsSL https://raw.githubusercontent.com/leeechsh/acme-manager/main/install.sh | sudo sh
```

程序文件统一安装到 `/usr/local/acme-manager/`，并创建以下软链接：

```text
/usr/local/bin/acme-manager -> /usr/local/acme-manager/acme-manager.sh
/usr/local/lib/acme-manager -> /usr/local/acme-manager/
```

更新只替换 `/usr/local/acme-manager/` 中的程序文件，并保留 `/etc/acme-manager/config.conf`、acme.sh 原生账户、证书和 Cron。也可以通过 `REPO_SLUG`、`REPO_REF`、`PREFIX` 和 `CONFIG_DIR` 覆盖默认仓库与安装位置。

用户目录安装示例：

```bash
PREFIX="$HOME/.local" CONFIG_DIR="$HOME/.config/acme-manager" ./install.sh
export PATH="$HOME/.local/bin:$PATH"
```

已有 acme.sh 时，设置 `ACME_SH_BIN` 或 `ACME_HOME` 即可复用；没有 acme.sh 时工具会明确报错，不会自动覆盖现有安装。

## 常用命令

```bash
acme-manager issue --domain example.com --domain '*.example.com' \
  --dns cloudflare --ca letsencrypt --key-type ec-256
acme-manager list
acme-manager renew --domain example.com
acme-manager renew --all
acme-manager deploy --domain example.com \
  --target-dir /var/cert/example.com \
  --reloadcmd 'nginx -t && systemctl reload nginx'
acme-manager dns status cloudflare
acme-manager notify configure
acme-manager cron install
acme-manager doctor
```

root 用户的默认部署目录为 `/var/cert/<domain>/`，每次部署会生成：

```text
/var/cert/example.com/cert.pem
/var/cert/example.com/privkey.pem
/var/cert/example.com/fullchain.pem
/var/cert/example.com/ca.pem
/var/cert/example.com/example.com.key
/var/cert/example.com/example.com.pem
```

其中 `.key` 和域名 `.pem` 文件会通过 acme.sh 的部署 Reload Hook 在自动续期后同步更新。

升级时，管理器会把旧版本自动生成的 `CERT_DIR="/etc/ssl/acme"` 迁移为 `/var/cert`；用户自定义的其它 `CERT_DIR` 不会被覆盖。

`revoke`、`remove`、删除 DNS 凭据和移除 Cron 都会要求二次确认。命令参数和配置文件不会接收 API 密钥或 SMTP 密码；凭据交给 acme.sh 原生账户配置保存。

交互菜单会根据终端自动启用配色；在日志重定向、自动化任务或不支持 ANSI 的终端中设置 `NO_COLOR=1` 可关闭颜色，不影响命令行为。

续期事件由 acme.sh 原生 notify hook 处理；签发、部署和手动续期的补充通知使用本机 `curl` 的 SMTP 支持发送。未配置 SMTP 或缺少 `curl` 时，操作本身仍会完成，但日志会记录通知失败。

DNS 凭据使用 acme.sh 插件原生变量：Cloudflare 为 `CF_Token`，腾讯云 DNSPod 为 `Tencent_SecretId` / `Tencent_SecretKey`，阿里云为 `Ali_Key` / `Ali_Secret`。可选的临时令牌和区域参数也会写入同一个 `account.conf`。

## 配置

默认配置为 `/etc/acme-manager/config.conf`；非 root 用户默认使用 `$XDG_CONFIG_HOME/acme-manager/config.conf`。也可以通过 `ACME_MANAGER_CONFIG` 指定路径。配置解析只接受白名单键，不执行 `source`，并且会写入 `0600`。

完整示例见 `config.conf.example`。`ACME_HOME` 只决定 acme.sh 原生目录，`CERT_DIR` 只决定管理器默认部署目录。

## 测试

```bash
./tests/test.sh
```

测试使用假的 acme.sh 和临时目录，只验证参数编排、配置白名单、敏感值权限和危险操作确认，不会向真实 CA、DNS 或 SMTP 服务发起请求。
