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
CRON_JOB="*/1 * * * * $INSTALL_DIR/$SCRIPT_NAME $INSTALL_DIR/$CONF_NAME >> /var/log/ddns.log 2>&1"
CRON_CLEAN="0 0 * * * > /var/log/ddns.log"

(crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME"; echo "$CRON_JOB") | crontab -
(crontab -l 2>/dev/null | grep -v "/var/log/ddns.log"; echo "$CRON_CLEAN") | crontab -

echo -e "${GREEN}Installation Complete!${NC}"
echo -e "Please edit config file: ${YELLOW}$INSTALL_DIR/$CONF_NAME${NC}"
echo -e "Usage: $INSTALL_DIR/$SCRIPT_NAME $INSTALL_DIR/$CONF_NAME"
