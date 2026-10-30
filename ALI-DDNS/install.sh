#!/bin/bash

INSTALL_DIR="/root/ali-ddns"
REPO_URL="https://raw.githubusercontent.com/sinalphabeta/DDNS/main/ALI-DDNS"
SCRIPT_NAME="ali-ddns.sh"
CONF_NAME="ali-ddns.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage:
  $0                                          # 使用配置文件模式 (需手动编辑 conf)
  $0 --access-key-id <ID> --access-key-secret <Secret> --domain <主域名> --subdomain <主机记录> [选项]

Options:
      --access-key-id      阿里云 AccessKey ID
      --access-key-secret  阿里云 AccessKey Secret
      --domain             主域名，如 example.com
      --subdomain          主机记录，如 home；根域名填 @
      --type               记录类型 A 或 AAAA (默认 A)
      --ttl                TTL 秒数 (默认 600，免费版最小 600)
      --line               解析线路 (默认 default)
      --endpoint           API 接入点 (默认 alidns.aliyuncs.com)
      --tg-token           Telegram Bot Token (可选)
      --tg-chat-id         Telegram Chat ID (可选，个人或群组 ID)
  -h, --help               显示帮助

带参数安装时，定时任务将直接使用这些参数运行，无需编辑配置文件。
EOF
}

shell_quote() {
    local s="$1"
    s=${s//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

# Parse arguments (passed through to the cron job)
DDNS_ARGS=""
SEEN_ID=0
SEEN_SECRET=0
SEEN_DOMAIN=0
SEEN_SUB=0
while [ $# -gt 0 ]; do
    case "$1" in
        --access-key-id|--access-key-secret|--domain|--subdomain|--type|--ttl|--line|--endpoint|--tg-token|--tg-chat-id)
            [ -z "$2" ] && echo -e "${RED}参数 $1 缺少值${NC}" && exit 1
            case "$1" in
                --access-key-id) SEEN_ID=1 ;;
                --access-key-secret) SEEN_SECRET=1 ;;
                --domain) SEEN_DOMAIN=1 ;;
                --subdomain) SEEN_SUB=1 ;;
            esac
            DDNS_ARGS="$DDNS_ARGS $1 $(shell_quote "$2")"
            shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"; usage; exit 1 ;;
    esac
done

if [ -n "$DDNS_ARGS" ]; then
    if [ "$SEEN_ID" -ne 1 ] || [ "$SEEN_SECRET" -ne 1 ] || [ "$SEEN_DOMAIN" -ne 1 ] || [ "$SEEN_SUB" -ne 1 ]; then
        echo -e "${RED}参数模式需要 --access-key-id --access-key-secret --domain --subdomain${NC}"
        usage
        exit 1
    fi
fi

echo -e "${GREEN}Start installing Aliyun DDNS...${NC}"

# Check for root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# Create directory
if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "Creating directory: ${YELLOW}$INSTALL_DIR${NC}"
    mkdir -p "$INSTALL_DIR"
fi

cd "$INSTALL_DIR" || exit 1

# Download files
echo -e "Downloading files..."
if command -v wget >/dev/null 2>&1; then
    wget -N "$REPO_URL/$SCRIPT_NAME"
    wget -N "$REPO_URL/$CONF_NAME"
elif command -v curl >/dev/null 2>&1; then
    curl -O "$REPO_URL/$SCRIPT_NAME"
    curl -O "$REPO_URL/$CONF_NAME"
else
    echo -e "${RED}Error: wget or curl not found.${NC}"
    exit 1
fi

chmod +x "$SCRIPT_NAME"

# Ensure crontab exists (minimal images often ship without cron)
if ! command -v crontab >/dev/null 2>&1; then
    echo -e "${YELLOW}crontab not found, installing...${NC}"
    if [ -f /etc/debian_version ]; then
        apt update -qq && apt install -y -qq cron
    elif [ -f /etc/redhat-release ]; then
        yum install -y cronie
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache cronie
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install cron
    fi
    if ! command -v crontab >/dev/null 2>&1; then
        echo -e "${RED}Error: failed to install cron, please install it manually.${NC}"
        exit 1
    fi
fi

# Make sure the cron daemon is enabled and running (fresh installs may not start it)
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || systemctl enable --now cronie 2>/dev/null
elif command -v rc-service >/dev/null 2>&1; then
    rc-update add crond default 2>/dev/null
    rc-service crond start 2>/dev/null
elif command -v service >/dev/null 2>&1; then
    service cron start 2>/dev/null || service crond start 2>/dev/null
fi

# Configure Cron
echo -e "Configuring Crontab..."
if [ -n "$DDNS_ARGS" ]; then
    CRON_JOB="*/1 * * * * $INSTALL_DIR/$SCRIPT_NAME$DDNS_ARGS >> /var/log/ali-ddns.log 2>&1"
else
    CRON_JOB="*/1 * * * * $INSTALL_DIR/$SCRIPT_NAME $INSTALL_DIR/$CONF_NAME >> /var/log/ali-ddns.log 2>&1"
fi

# Backup current crontab
crontab -l > /tmp/cron.bak 2>/dev/null

# Remove existing managed lines to prevent duplicates
grep -v "$SCRIPT_NAME" /tmp/cron.bak | grep -v "> /var/log/ali-ddns.log" > /tmp/cron.new

# Append new job (log rotation is handled by ali-ddns.sh itself)
echo "$CRON_JOB" >> /tmp/cron.new

# Install new crontab
crontab /tmp/cron.new
rm -f /tmp/cron.bak /tmp/cron.new

echo -e "${GREEN}Installation Complete!${NC}"
if [ -n "$DDNS_ARGS" ]; then
    echo -e "Cron job: ${YELLOW}$INSTALL_DIR/$SCRIPT_NAME$DDNS_ARGS${NC}"
else
    echo -e "Please edit config file: ${YELLOW}$INSTALL_DIR/$CONF_NAME${NC}"
    echo -e "Usage: $INSTALL_DIR/$SCRIPT_NAME $INSTALL_DIR/$CONF_NAME"
fi
