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

get_dns_ip() {
    local name="$1"
    local type="$2"
    
    echo "正在查询DNS记录: $name ($type)" >&2
    
    # 1. 尝试使用 dig
    if command -v dig >/dev/null 2>&1; then
        local ip=$(dig +short "$name" "$type" | head -1)
        if [[ "$ip" =~ ^[0-9a-fA-F\.:]+$ ]]; then
            echo "通过dig获取到DNS IP: $ip" >&2
            echo "$ip"
            return
        fi
    fi
    
    # 2. 尝试使用 nslookup
    if command -v nslookup >/dev/null 2>&1; then
        local ip
        if [ "$type" = "A" ]; then
            ip=$(nslookup "$name" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
        else
            ip=$(nslookup -type=AAAA "$name" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
        fi
        if [[ "$ip" =~ ^[0-9a-fA-F\.:]+$ ]]; then
            echo "通过nslookup获取到DNS IP: $ip" >&2
            echo "$ip"
            return
        fi
    fi

    # 3. 尝试使用 getent（glibc 自带，比 ping 更可靠）
    if command -v getent >/dev/null 2>&1; then
        local ip
        if [ "$type" = "A" ]; then
            # getent ahostsv4 只返回 IPv4
            ip=$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1; exit}')
        else
            # getent ahostsv6 只返回 IPv6
            ip=$(getent ahostsv6 "$name" 2>/dev/null | awk '{print $1; exit}')
        fi
        if [[ "$ip" =~ ^[0-9a-fA-F\.:]+$ ]]; then
            echo "通过getent获取到DNS IP: $ip" >&2
            echo "$ip"
            return
        fi
    fi

    # 4. 尝试使用 ping（作为最后的备选）
    local ping_cmd="ping"
    [ "$type" = "AAAA" ] && ping_cmd="ping6"
    
    if command -v "$ping_cmd" >/dev/null 2>&1; then
        # ping 输出格式: PING example.com (93.184.216.34) 56(84) bytes of data.
        # 使用 awk 按括号分割，取第一个括号内的内容（即 IP 地址）
        local ip=$($ping_cmd -c 1 -W 1 "$name" 2>/dev/null | head -1 | awk -F'[()]' '{print $2}')
        
        if [[ "$ip" =~ ^[0-9a-fA-F\.:]+$ ]]; then
            echo "通过$ping_cmd获取到DNS IP: $ip" >&2
            echo "$ip"
            return
        fi
    fi
    
    echo "本地DNS查询失败（缺少工具或记录未生效），将直接检查Cloudflare API" >&2
    echo ""
}

need_cmd curl
need_cmd jq

[ -z "$CF_API_TOKEN" ] && echo "CF_API_TOKEN 未设置" && exit 1
[ -z "$DOMAIN" ] && echo "DOMAIN 未设置" && exit 1
[ -z "$SUBDOMAIN" ] && echo "SUBDOMAIN 未设置" && exit 1
[ -z "$RECORD_TYPE" ] && echo "RECORD_TYPE 未设置" && exit 1

case "$RECORD_TYPE" in
    A)    IP_URL="ip.sb"; CURL_OPTS="-4"; DNS_TYPE="A" ;;
    AAAA) IP_URL="ip.sb"; CURL_OPTS="-6"; DNS_TYPE="AAAA" ;;
    *)    echo "RECORD_TYPE 必须为 A 或 AAAA" && exit 1 ;;
esac

echo "正在获取当前出口IP..."
CURRENT_IP=$(curl -s --max-time 10 $CURL_OPTS "$IP_URL")
[[ ! "$CURRENT_IP" =~ ^[0-9a-fA-F\.:]+$ ]] && echo "获取出口 IP 失败: $CURRENT_IP" && exit 1
echo "当前出口IP: $CURRENT_IP"

record_name="$SUBDOMAIN.$DOMAIN"

DNS_IP=$(get_dns_ip "$record_name" "$DNS_TYPE")

if [ -n "$DNS_IP" ]; then
    if [ "$CURRENT_IP" == "$DNS_IP" ]; then
        echo "出口 IP 与 DNS 一致，无需更新 ($CURRENT_IP)"
        exit 0
    else
        echo "IP不一致，需要更新: DNS=$DNS_IP, 当前=$CURRENT_IP"
    fi
else
    echo "DNS记录不存在或查询失败，将创建新记录"
fi

echo "正在获取Cloudflare Zone ID..."
zone_json=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
ZONE_ID=$(echo "$zone_json" | jq -r '.result[0].id')
[ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ] && echo "无法获取 Zone ID" && exit 1
echo "Zone ID: $ZONE_ID"

echo "正在查询现有DNS记录..."
record_json=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$record_name&type=$RECORD_TYPE" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
RECORD_ID=$(echo "$record_json" | jq -r '.result[0].id')

if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
    echo "记录不存在，创建中..."
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$record_name\",\"content\":\"$CURRENT_IP\",\"ttl\":60,\"proxied\":false}")
else
    echo "记录存在，Record ID: $RECORD_ID，更新中..."
    response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$record_name\",\"content\":\"$CURRENT_IP\",\"ttl\":60,\"proxied\":false}")
fi

echo "$response" | grep -q '"success":true' && echo "更新成功: $record_name -> $CURRENT_IP" || {
    echo "更新失败"
    echo "$response"
    exit 1
}