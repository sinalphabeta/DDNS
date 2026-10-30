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

##  Aliyun DDNS

使用阿里云 AccessKey 调用云解析 API。建议用只授予云解析权限的 RAM 子账号，不要用主账号密钥。同一主机记录、类型、线路下若有多条，只保留第一条。重复安装会替换已有的 ali-ddns 定时任务，不会改动 cf-ddns 的任务。

### 一键安装（配置文件模式）

安装后需手动编辑 `/root/ali-ddns/ali-ddns.conf`：

```shell
bash <(curl -s https://raw.githubusercontent.com/sinalphabeta/DDNS/main/ALI-DDNS/install.sh)
```

### 一键安装（参数模式）

安装时直接指定参数，定时任务会带上这些参数运行，无需编辑配置文件：

```shell
bash <(curl -s https://raw.githubusercontent.com/sinalphabeta/DDNS/main/ALI-DDNS/install.sh) \
  --access-key-id "你的 AccessKey ID" \
  --access-key-secret "你的 AccessKey Secret" \
  --domain example.com \
  --subdomain home \
  --type A
```

根域名的主机记录填 `@`。免费版云解析 TTL 最小 600 秒，脚本默认就是 600。

可选：加上 Telegram 通知（IP 变化时推送，个人或群组 Chat ID 均可）：

```shell
bash <(curl -s https://raw.githubusercontent.com/sinalphabeta/DDNS/main/ALI-DDNS/install.sh) \
  --access-key-id "你的 AccessKey ID" \
  --access-key-secret "你的 AccessKey Secret" \
  --domain example.com \
  --subdomain home \
  --type A \
  --tg-token "123456:ABC-xxxx" \
  --tg-chat-id "-1001234567890"
```

### 参数说明

| 参数 | 说明 | 必填 |
|------|------|------|
| `--access-key-id` | 阿里云 AccessKey ID | 参数模式必填 |
| `--access-key-secret` | 阿里云 AccessKey Secret | 参数模式必填 |
| `--domain` | 主域名，如 `example.com` | 参数模式必填 |
| `--subdomain` | 主机记录，如 `home`；根域名填 `@` | 参数模式必填 |
| `--type` | 记录类型 `A` 或 `AAAA`，默认 `A` | 否 |
| `--ttl` | TTL 秒数，默认 `600` | 否 |
| `--line` | 解析线路，默认 `default` | 否 |
| `--endpoint` | API 接入点，默认 `alidns.aliyuncs.com` | 否 |
| `--tg-token` | Telegram Bot Token | 否 |
| `--tg-chat-id` | Telegram Chat ID（个人或群组） | 否 |
