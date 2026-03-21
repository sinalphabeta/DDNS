#!/bin/bash

CONFIG_FILE="$1"
[ -z "$CONFIG_FILE" ] && echo "使用方法: $0 <配置文件路径>" && exit 1
[ ! -f "$CONFIG_FILE" ] && echo "配置文件不存在: $CONFIG_FILE" && exit 1
source "$CONFIG_FILE"

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

echo "正在获取当前出口IP..."
CURRENT_IP=$(curl -s --max-time 10 $CURL_OPTS "$IP_URL")
[[ ! "$CURRENT_IP" =~ ^[0-9a-fA-F\.:]+$ ]] && echo "获取出口 IP 失败: $CURRENT_IP" && exit 1
echo "当前出口IP: $CURRENT_IP"

record_name="$SUBDOMAIN.$DOMAIN"

# ===== 第一步：先查询 Cloudflare API 获取 Zone ID =====
echo "正在获取Cloudflare Zone ID..."
zone_json=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
ZONE_ID=$(echo "$zone_json" | jq -r '.result[0].id')
[ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ] && echo "无法获取 Zone ID" && exit 1
echo "Zone ID: $ZONE_ID"

# ===== 第二步：查询 Cloudflare 上该域名的所有同类型 DNS 记录 =====
echo "正在查询Cloudflare上的DNS记录..."
record_json=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$record_name&type=$RECORD_TYPE" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")

# 检查 API 调用是否成功
api_success=$(echo "$record_json" | jq -r '.success')
if [ "$api_success" != "true" ]; then
    echo "Cloudflare API 查询失败，跳过本次更新以避免创建重复记录"
    echo "API 响应: $record_json"
    exit 1
fi

# 获取记录数量
record_count=$(echo "$record_json" | jq '.result | length')
echo "找到 $record_count 条现有记录"

# ===== 第三步：如果有多条重复记录，清理多余的，只保留第一条 =====
if [ "$record_count" -gt 1 ]; then
    echo "检测到 $record_count 条重复记录，正在清理多余记录..."
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
    echo "记录不存在，创建中..."
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$record_name\",\"content\":\"$CURRENT_IP\",\"ttl\":60,\"proxied\":false}")
else
    # 记录已存在，检查 IP 是否一致
    if [ "$CURRENT_IP" == "$RECORD_IP" ]; then
        echo "出口 IP 与 Cloudflare 记录一致，无需更新 ($CURRENT_IP)"
        exit 0
    fi
    echo "IP不一致 (Cloudflare=$RECORD_IP, 当前=$CURRENT_IP)，更新中... Record ID: $RECORD_ID"
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$record_name\",\"content\":\"$CURRENT_IP\",\"ttl\":60,\"proxied\":false}")
fi

echo "$response" | grep -q '"success":true' && echo "更新成功: $record_name -> $CURRENT_IP" || {
    echo "更新失败"
    echo "$response"
    exit 1
}