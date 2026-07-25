#!/bin/bash

usage() {
    cat <<EOF
使用方法:
  $0 <配置文件路径>
  $0 --config <配置文件路径>
  $0 --token <API Token> --domain <主域名> --subdomain <子域名> [--type A|AAAA]

参数:
  -c, --config      配置文件路径 (可与命令行参数混用，命令行参数优先)
      --token       Cloudflare API Token
      --domain      主域名，如 example.com
      --subdomain   子域名，如 home
      --type        记录类型 A 或 AAAA (默认 A)
      --tg-token    Telegram Bot Token (可选，配置后 IP 变化时发送通知)
      --tg-chat-id  Telegram Chat ID (可选，个人或群组 ID)
  -h, --help        显示帮助
EOF
}

CONFIG_FILE=""
ARG_TOKEN=""
ARG_DOMAIN=""
ARG_SUBDOMAIN=""
ARG_TYPE=""
ARG_TG_TOKEN=""
ARG_TG_CHAT_ID=""

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
        --token)      ARG_TOKEN="$2"; shift 2 ;;
        --domain)     ARG_DOMAIN="$2"; shift 2 ;;
        --subdomain)  ARG_SUBDOMAIN="$2"; shift 2 ;;
        --type)       ARG_TYPE="$2"; shift 2 ;;
        --tg-token)   ARG_TG_TOKEN="$2"; shift 2 ;;
        --tg-chat-id) ARG_TG_CHAT_ID="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "未知参数: $1"; usage; exit 1 ;;
        *)            CONFIG_FILE="$1"; shift ;;
    esac
done

if [ -n "$CONFIG_FILE" ]; then
    [ ! -f "$CONFIG_FILE" ] && echo "配置文件不存在: $CONFIG_FILE" && exit 1
    source "$CONFIG_FILE"
fi

# 命令行参数优先于配置文件
[ -n "$ARG_TOKEN" ] && CF_API_TOKEN="$ARG_TOKEN"
[ -n "$ARG_DOMAIN" ] && DOMAIN="$ARG_DOMAIN"
[ -n "$ARG_SUBDOMAIN" ] && SUBDOMAIN="$ARG_SUBDOMAIN"
[ -n "$ARG_TYPE" ] && RECORD_TYPE="$ARG_TYPE"
[ -n "$ARG_TG_TOKEN" ] && TG_BOT_TOKEN="$ARG_TG_TOKEN"
[ -n "$ARG_TG_CHAT_ID" ] && TG_CHAT_ID="$ARG_TG_CHAT_ID"
RECORD_TYPE="${RECORD_TYPE:-A}"

# 发送 Telegram 通知: $1=旧IP $2=新IP
send_telegram() {
    [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && return 0
    local old_ip="$1" new_ip="$2"
    local msg="🔔 <b>Cloudflare DDNS 更新通知</b>

🌐 域名: <code>$record_name</code>
📋 类型: <code>$RECORD_TYPE</code>
🔴 旧IP: <code>$old_ip</code>
🟢 新IP: <code>$new_ip</code>
🕐 时间: <code>$(date '+%Y-%m-%d %H:%M:%S')</code>"

    local tg_resp
    tg_resp=$(curl -s --max-time 10 -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=$msg" \
        --data-urlencode "parse_mode=HTML")
    echo "$tg_resp" | grep -q '"ok":true' && echo "Telegram 通知已发送" || echo "Telegram 通知发送失败: $tg_resp"
}

if [ -z "$CONFIG_FILE" ] && [ -z "$CF_API_TOKEN" ]; then
    usage
    exit 1
fi

# 日志自维护: 超过 MAX_LOG_LINES 行时只保留最近的部分 (可通过环境变量覆盖)
LOG_FILE="${LOG_FILE:-/var/log/cf-ddns.log}"
MAX_LOG_LINES="${MAX_LOG_LINES:-1000}"
if [ -w "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# log_info: 过程信息，仅交互终端显示 (cron 运行时静默，避免日志膨胀)
log_info() { [ -t 1 ] && echo "$@"; return 0; }
# log_event: 重要事件，始终输出并带时间戳
log_event() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少命令: $1，尝试安装..."
        install_pkg "$1" || exit 1
    }
}

install_pkg() {
    if [ -f /etc/debian_version ]; then
        apt update -qq && apt install -y -qq "$1"
    elif [ -f /etc/redhat-release ]; then
        yum install -y "$1"
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install "$1"
    else
        return 1
    fi
}

need_cmd curl
need_cmd jq

[ -z "$CF_API_TOKEN" ] && echo "CF_API_TOKEN 未设置" && exit 1
[ -z "$DOMAIN" ] && echo "DOMAIN 未设置" && exit 1
[ -z "$SUBDOMAIN" ] && echo "SUBDOMAIN 未设置" && exit 1
[ -z "$RECORD_TYPE" ] && echo "RECORD_TYPE 未设置" && exit 1

case "$RECORD_TYPE" in
    A)    IP_URL="ip.sb"; CURL_OPTS="-4" ;;
    AAAA) IP_URL="ip.sb"; CURL_OPTS="-6" ;;
    *)    echo "RECORD_TYPE 必须为 A 或 AAAA" && exit 1 ;;
esac

log_info "正在获取当前出口IP..."
CURRENT_IP=$(curl -s --max-time 10 $CURL_OPTS "$IP_URL")
[[ ! "$CURRENT_IP" =~ ^[0-9a-fA-F\.:]+$ ]] && log_event "获取出口 IP 失败: $CURRENT_IP" && exit 1
log_info "当前出口IP: $CURRENT_IP"

record_name="$SUBDOMAIN.$DOMAIN"

# ===== 第一步：先查询 Cloudflare API 获取 Zone ID =====
log_info "正在获取Cloudflare Zone ID..."
zone_json=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
ZONE_ID=$(echo "$zone_json" | jq -r '.result[0].id')
[ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ] && log_event "无法获取 Zone ID" && exit 1
log_info "Zone ID: $ZONE_ID"

# ===== 第二步：查询 Cloudflare 上该域名的所有同类型 DNS 记录 =====
log_info "正在查询Cloudflare上的DNS记录..."
record_json=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$record_name&type=$RECORD_TYPE" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")

# 检查 API 调用是否成功
api_success=$(echo "$record_json" | jq -r '.success')
if [ "$api_success" != "true" ]; then
    log_event "Cloudflare API 查询失败，跳过本次更新以避免创建重复记录"
    echo "API 响应: $record_json"
    exit 1
fi

# 获取记录数量
record_count=$(echo "$record_json" | jq '.result | length')
log_info "找到 $record_count 条现有记录"

# ===== 第三步：如果有多条重复记录，清理多余的，只保留第一条 =====
if [ "$record_count" -gt 1 ]; then
    log_event "检测到 $record_count 条重复记录，正在清理多余记录..."
    # 保留第一条，删除其余的
    for i in $(seq 1 $((record_count - 1))); do
        dup_id=$(echo "$record_json" | jq -r ".result[$i].id")
        dup_ip=$(echo "$record_json" | jq -r ".result[$i].content")
        echo "  删除重复记录: ID=$dup_id, IP=$dup_ip"
        del_resp=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$dup_id" \
            -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
        echo "$del_resp" | grep -q '"success":true' && echo "  删除成功" || echo "  删除失败: $del_resp"
    done
fi

# ===== 第四步：创建或更新记录 =====
RECORD_ID=$(echo "$record_json" | jq -r '.result[0].id')
RECORD_IP=$(echo "$record_json" | jq -r '.result[0].content')

if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
    # 确实没有记录，创建新的
    OLD_IP="无 (新建记录)"
    log_event "记录不存在，创建中..."
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$record_name\",\"content\":\"$CURRENT_IP\",\"ttl\":60,\"proxied\":false}")
else
    # 记录已存在，检查 IP 是否一致
    if [ "$CURRENT_IP" == "$RECORD_IP" ]; then
        log_info "出口 IP 与 Cloudflare 记录一致，无需更新 ($CURRENT_IP)"
        exit 0
    fi
    OLD_IP="$RECORD_IP"
    log_event "IP不一致 (Cloudflare=$RECORD_IP, 当前=$CURRENT_IP)，更新中... Record ID: $RECORD_ID"
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$record_name\",\"content\":\"$CURRENT_IP\",\"ttl\":60,\"proxied\":false}")
fi

echo "$response" | grep -q '"success":true' && {
    log_event "更新成功: $record_name -> $CURRENT_IP"
    send_telegram "$OLD_IP" "$CURRENT_IP"
} || {
    log_event "更新失败"
    echo "$response"
    exit 1
}