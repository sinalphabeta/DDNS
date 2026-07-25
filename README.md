# DDNS SHELL SCRIPT

##  Cloudflare DDNS

### 一键安装（配置文件模式）

安装后需手动编辑 `/root/cf-ddns/cf-ddns.conf`：

```shell
bash <(curl -s https://raw.githubusercontent.com/sinalphabeta/DDNS/main/CF-DDNS/install.sh)
```

### 一键安装（参数模式）

安装时直接指定参数，定时任务会带上这些参数运行，无需编辑配置文件：

```shell
bash <(curl -s https://raw.githubusercontent.com/sinalphabeta/DDNS/main/CF-DDNS/install.sh) \
  --token "你的 Cloudflare API Token" \
  --domain example.com \
  --subdomain home \
  --type A
```

可选：加上 Telegram 通知（IP 变化时推送，个人或群组 Chat ID 均可）：

```shell
bash <(curl -s https://raw.githubusercontent.com/sinalphabeta/DDNS/main/CF-DDNS/install.sh) \
  --token "你的 Cloudflare API Token" \
  --domain example.com \
  --subdomain home \
  --type A \
  --tg-token "123456:ABC-xxxx" \
  --tg-chat-id "-1001234567890"
```

### 参数说明

| 参数 | 说明 | 必填 |
|------|------|------|
| `--token` | Cloudflare API Token | 参数模式必填 |
| `--domain` | 主域名，如 `example.com` | 参数模式必填 |
| `--subdomain` | 子域名，如 `home` | 参数模式必填 |
| `--type` | 记录类型 `A` 或 `AAAA`，默认 `A` | 否 |
| `--tg-token` | Telegram Bot Token | 否 |
| `--tg-chat-id` | Telegram Chat ID（个人或群组） | 否 |
