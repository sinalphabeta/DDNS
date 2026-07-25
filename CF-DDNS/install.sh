#!/bin/bash

INSTALL_DIR="/root/cf-ddns"
REPO_URL="https://raw.githubusercontent.com/sinalphabeta/DDNS/main/CF-DDNS"
SCRIPT_NAME="cf-ddns.sh"
CONF_NAME="cf-ddns.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage:
  $0                                          # 使用配置文件模式 (需手动编辑 conf)
  $0 --token <API Token> --domain <主域名> --subdomain <子域名> [选项]

Options:
      --token       Cloudflare API Token
      --domain      主域名，如 example.com
      --subdomain   子域名，如 home
      --type        记录类型 A 或 AAAA (默认 A)
      --tg-token    Telegram Bot Token (可选)
      --tg-chat-id  Telegram Chat ID (可选，个人或群组 ID)
  -h, --help        显示帮助

带参数安装时，定时任务将直接使用这些参数运行，无需编辑配置文件。
EOF
}

# Parse arguments (passed through to the cron job)
DDNS_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --token|--domain|--subdomain|--type|--tg-token|--tg-chat-id)
            [ -z "$2" ] && echo -e "${RED}参数 $1 缺少值${NC}" && exit 1
            DDNS_ARGS="$DDNS_ARGS $1 '$2'"
            shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"; usage; exit 1 ;;
    esac
done

echo -e "${GREEN}Start installing Cloudflare DDNS...${NC}"

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

# Configure Cron
echo -e "Configuring Crontab..."
if [ -n "$DDNS_ARGS" ]; then
    CRON_JOB="*/1 * * * * $INSTALL_DIR/$SCRIPT_NAME$DDNS_ARGS >> /var/log/cf-ddns.log 2>&1"
else
    CRON_JOB="*/1 * * * * $INSTALL_DIR/$SCRIPT_NAME $INSTALL_DIR/$CONF_NAME >> /var/log/cf-ddns.log 2>&1"
fi
CRON_CLEAN="*/30 * * * * > /var/log/cf-ddns.log"

# Backup current crontab
crontab -l > /tmp/cron.bak 2>/dev/null

# Remove existing managed lines to prevent duplicates
grep -v "$SCRIPT_NAME" /tmp/cron.bak | grep -v "> /var/log/cf-ddns.log" | grep -v "> /var/log/ddns.log" > /tmp/cron.new

# Append new jobs
echo "$CRON_JOB" >> /tmp/cron.new
echo "$CRON_CLEAN" >> /tmp/cron.new

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
