#!/bin/bash

usage() {
    cat <<EOF
使用方法:
  $0 <配置文件路径>
  $0 --config <配置文件路径>
  $0 --access-key-id <ID> --access-key-secret <Secret> --domain <主域名> --subdomain <主机记录> [--type A|AAAA]

参数:
  -c, --config           配置文件路径 (可与命令行参数混用，命令行参数优先)
      --access-key-id    阿里云 AccessKey ID
      --access-key-secret 阿里云 AccessKey Secret
      --domain           主域名，如 example.com
      --subdomain        主机记录，如 home；根域名填 @
      --type             记录类型 A 或 AAAA (默认 A)
      --ttl              TTL 秒数 (默认 600，免费版最小 600)
      --line             解析线路 (默认 default)
      --endpoint         API 接入点 (默认 alidns.aliyuncs.com)
      --tg-token         Telegram Bot Token (可选，配置后 IP 变化时发送通知)
      --tg-chat-id       Telegram Chat ID (可选，个人或群组 ID)
  -h, --help             显示帮助
EOF
}

CONFIG_FILE=""
ARG_ID=""
ARG_SECRET=""
ARG_DOMAIN=""
ARG_SUBDOMAIN=""
ARG_TYPE=""
ARG_TTL=""
ARG_LINE=""
ARG_ENDPOINT=""
ARG_TG_TOKEN=""
ARG_TG_CHAT_ID=""

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)         CONFIG_FILE="$2"; shift 2 ;;
        --access-key-id)     ARG_ID="$2"; shift 2 ;;
        --access-key-secret) ARG_SECRET="$2"; shift 2 ;;
        --domain)            ARG_DOMAIN="$2"; shift 2 ;;
        --subdomain)         ARG_SUBDOMAIN="$2"; shift 2 ;;
        --type)              ARG_TYPE="$2"; shift 2 ;;
        --ttl)               ARG_TTL="$2"; shift 2 ;;
        --line)              ARG_LINE="$2"; shift 2 ;;
        --endpoint)          ARG_ENDPOINT="$2"; shift 2 ;;
        --tg-token)          ARG_TG_TOKEN="$2"; shift 2 ;;
        --tg-chat-id)        ARG_TG_CHAT_ID="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        -*)                  echo "未知参数: $1"; usage; exit 1 ;;
        *)                   CONFIG_FILE="$1"; shift ;;
    esac
done

if [ -n "$CONFIG_FILE" ]; then
    [ ! -f "$CONFIG_FILE" ] && echo "配置文件不存在: $CONFIG_FILE" && exit 1
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# 命令行参数优先于配置文件
[ -n "$ARG_ID" ] && ALI_ACCESS_KEY_ID="$ARG_ID"
[ -n "$ARG_SECRET" ] && ALI_ACCESS_KEY_SECRET="$ARG_SECRET"
[ -n "$ARG_DOMAIN" ] && DOMAIN="$ARG_DOMAIN"
[ -n "$ARG_SUBDOMAIN" ] && SUBDOMAIN="$ARG_SUBDOMAIN"
[ -n "$ARG_TYPE" ] && RECORD_TYPE="$ARG_TYPE"
[ -n "$ARG_TTL" ] && TTL="$ARG_TTL"
[ -n "$ARG_LINE" ] && LINE="$ARG_LINE"
[ -n "$ARG_ENDPOINT" ] && ALI_ENDPOINT="$ARG_ENDPOINT"
[ -n "$ARG_TG_TOKEN" ] && TG_BOT_TOKEN="$ARG_TG_TOKEN"
[ -n "$ARG_TG_CHAT_ID" ] && TG_CHAT_ID="$ARG_TG_CHAT_ID"
RECORD_TYPE="${RECORD_TYPE:-A}"
TTL="${TTL:-600}"
LINE="${LINE:-default}"
ALI_ENDPOINT="${ALI_ENDPOINT:-alidns.aliyuncs.com}"
ALI_ENDPOINT="${ALI_ENDPOINT#https://}"
ALI_ENDPOINT="${ALI_ENDPOINT#http://}"
ALI_ENDPOINT="${ALI_ENDPOINT%%/*}"

# 发送 Telegram 通知: $1=旧IP $2=新IP
send_telegram() {
    [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && return 0
    local old_ip="$1" new_ip="$2"
    local msg="🔔 <b>Aliyun DDNS 更新通知</b>

🌐 域名: <code>$record_name</code>
📋 类型: <code>$RECORD_TYPE</code>
🔴 旧IP: <code>$old_ip</code>
🟢 新IP: <code>$new_ip</code>
🕐 时间: <code>$(date '+%Y-%m-%d %H:%M:%S')</code>"

    local tg_resp
    tg_resp=$(curl -s --max-time 10 "${DOH_OPTS[@]}" -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=$msg" \
        --data-urlencode "parse_mode=HTML")
    echo "$tg_resp" | grep -q '"ok":true' && echo "Telegram 通知已发送" || echo "Telegram 通知发送失败: $tg_resp"
}

if [ -z "$CONFIG_FILE" ] && [ -z "$ALI_ACCESS_KEY_ID" ]; then
    usage
    exit 1
fi

# 日志自维护: 超过 MAX_LOG_LINES 行时只保留最近的部分 (可通过环境变量覆盖)
LOG_FILE="${LOG_FILE:-/var/log/ali-ddns.log}"
MAX_LOG_LINES="${MAX_LOG_LINES:-1000}"
if [ -w "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# log_info: 过程信息，仅交互终端显示 (cron 运行时静默，避免日志膨胀)
log_info() { [ -t 2 ] && echo "$@" >&2; return 0; }
# log_event: 重要事件，始终输出并带时间戳。写到 stderr，避免被 API 函数的命令替换吞掉
log_event() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

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
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$1"
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install "$1"
    else
        return 1
    fi
}

need_cmd curl
need_cmd jq
need_cmd openssl

[ -z "$ALI_ACCESS_KEY_ID" ] && echo "ALI_ACCESS_KEY_ID 未设置" && exit 1
[ -z "$ALI_ACCESS_KEY_SECRET" ] && echo "ALI_ACCESS_KEY_SECRET 未设置" && exit 1
[ -z "$DOMAIN" ] && echo "DOMAIN 未设置" && exit 1
[ -z "$SUBDOMAIN" ] && echo "SUBDOMAIN 未设置" && exit 1
[ -z "$RECORD_TYPE" ] && echo "RECORD_TYPE 未设置" && exit 1
[ -z "$LINE" ] && echo "LINE 未设置" && exit 1
case "$TTL" in
    ''|*[!0-9]*) echo "TTL 必须为正整数" && exit 1 ;;
esac
RECORD_TYPE=$(printf '%s' "$RECORD_TYPE" | tr '[:lower:]' '[:upper:]')

case "$RECORD_TYPE" in
    A)    CURL_OPTS="-4" ;;
    AAAA) CURL_OPTS="-6" ;;
    *)    echo "RECORD_TYPE 必须为 A 或 AAAA" && exit 1 ;;
esac

# IP 查询站点列表，按顺序尝试，任一返回有效 IP 即成功
if [ "$RECORD_TYPE" = "A" ]; then
    IP_SITES=(
        "https://ipinfo.io/ip"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
        "https://ip.sb"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ident.me"
    )
else
    IP_SITES=(
        "https://api64.ipify.org"
        "https://ip.sb"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ident.me"
    )
fi

# DoH 服务器: 直连全部失败时用其绕过运营商 DNS 劫持
# 1.1.1.1/8.8.8.8 用 IP 直连，DoH 服务器域名本身被劫持时也能工作
DOH_URLS=(
    "https://1.1.1.1/dns-query"
    "https://8.8.8.8/dns-query"
    "https://cloudflare-dns.com/dns-query"
)

# 校验取回的内容确实是一个可用的公网 IP (劫持/错误页会返回 0.0.0.0 或 HTML)
valid_ip() {
    local ip="$1"
    if [ "$RECORD_TYPE" = "A" ]; then
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
        case "$ip" in 0.0.0.0|127.*) return 1 ;; esac
        local octet
        for octet in ${ip//./ }; do [ "$octet" -le 255 ] || return 1; done
    else
        [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]] || return 1
        [ "$ip" = "::" ] && return 1
    fi
    return 0
}

# 获取出口 IP: 先直连轮询所有站点；全部失败再用 DoH 兜底
# 成功后设置 CURRENT_IP；若靠 DoH 成功，后续阿里云 API 请求也走同一 DoH
DOH_OPTS=()
get_ip() {
    local ip site doh
    for site in "${IP_SITES[@]}"; do
        ip=$(curl -s --max-time 8 $CURL_OPTS "$site" | tr -d '[:space:]')
        valid_ip "$ip" && { CURRENT_IP="$ip"; return 0; }
        log_info "获取失败: $site"
    done
    if ! curl --help all 2>/dev/null | grep -q -- --doh-url; then
        log_event "警告: 当前 curl 不支持 --doh-url (需 7.62+)，无法使用 DoH 兜底"
        return 1
    fi
    log_info "直连全部失败，尝试 DoH 绕过 DNS 劫持..."
    for doh in "${DOH_URLS[@]}"; do
        for site in "${IP_SITES[@]}"; do
            ip=$(curl -s --max-time 8 $CURL_OPTS --doh-url "$doh" "$site" 2>/dev/null | tr -d '[:space:]')
            valid_ip "$ip" && {
                CURRENT_IP="$ip"
                DOH_OPTS=(--doh-url "$doh")
                log_event "系统 DNS 疑似被劫持，已切换 DoH ($doh) 获取到 IP"
                return 0
            }
        done
    done
    return 1
}

# RFC 3986 百分号编码。按字节处理，避免中文域名和高位字节被 bash 字符索引弄错
ali_urlencode() {
    local LC_ALL=C
    local ord hex out=""
    while IFS= read -r ord; do
        [ -z "$ord" ] && continue
        case "$ord" in
            45|46|48|49|50|51|52|53|54|55|56|57|65|66|67|68|69|70|71|72|73|74|75|76|77|78|79|80|81|82|83|84|85|86|87|88|89|90|95|97|98|99|100|101|102|103|104|105|106|107|108|109|110|111|112|113|114|115|116|117|118|119|120|121|122|126)
                printf -v hex '%b' "\\$(printf '%03o' "$ord")"
                out+="$hex"
                ;;
            *)
                printf -v hex '%%%02X' "$ord"
                out+="$hex"
                ;;
        esac
    done < <(printf '%s' "$1" | od -An -tu1 -v | tr -s '[:space:]' '\n')
    printf '%s' "$out"
}

# 把 key=value 参数按名称排序并编码，供 V3 签名和实际请求共用
build_query() {
    local -a pairs=()
    local kv key val sorted line first=1 out=""
    for kv in "$@"; do
        key=${kv%%=*}
        val=${kv#*=}
        pairs+=("$(ali_urlencode "$key")=$(ali_urlencode "$val")")
    done
    [ ${#pairs[@]} -eq 0 ] && return 0
    sorted=$(printf '%s\n' "${pairs[@]}" | LC_ALL=C sort)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$first" -eq 1 ]; then
            out="$line"
            first=0
        else
            out="${out}&${line}"
        fi
    done <<< "$sorted"
    printf '%s' "$out"
}

# 阿里云 OpenAPI V3 签名 (ACS3-HMAC-SHA256)。
# RPC 参数放在 query，body 为空。成功时把 JSON 打到 stdout，失败信息打到 stderr。
ALI_API_VERSION="2015-01-09"
EMPTY_BODY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
ali_api() {
    local action="$1"
    shift
    local host date nonce query signed_headers canonical_headers canonical_request
    local hashed string_to_sign signature authorization url resp
    host="$ALI_ENDPOINT"
    date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    nonce=$(openssl rand -hex 16)
    query=$(build_query "$@")
    signed_headers="host;x-acs-action;x-acs-content-sha256;x-acs-date;x-acs-signature-nonce;x-acs-version"
    canonical_headers="host:${host}"$'\n'
    canonical_headers+="x-acs-action:${action}"$'\n'
    canonical_headers+="x-acs-content-sha256:${EMPTY_BODY_SHA256}"$'\n'
    canonical_headers+="x-acs-date:${date}"$'\n'
    canonical_headers+="x-acs-signature-nonce:${nonce}"$'\n'
    canonical_headers+="x-acs-version:${ALI_API_VERSION}"$'\n'
    canonical_request="POST"$'\n'"/"$'\n'"${query}"$'\n'"${canonical_headers}"$'\n'"${signed_headers}"$'\n'"${EMPTY_BODY_SHA256}"
    hashed=$(printf '%s' "$canonical_request" | openssl dgst -sha256 | sed 's/^.* //')
    string_to_sign="ACS3-HMAC-SHA256"$'\n'"${hashed}"
    signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -hmac "$ALI_ACCESS_KEY_SECRET" | sed 's/^.* //')
    authorization="ACS3-HMAC-SHA256 Credential=${ALI_ACCESS_KEY_ID},SignedHeaders=${signed_headers},Signature=${signature}"

    url="https://${host}/"
    [ -n "$query" ] && url="${url}?${query}"

    resp=$(curl -sS --max-time 20 "${DOH_OPTS[@]}" -X POST "$url" \
        -H "Host: ${host}" \
        -H "x-acs-action: ${action}" \
        -H "x-acs-version: ${ALI_API_VERSION}" \
        -H "x-acs-date: ${date}" \
        -H "x-acs-signature-nonce: ${nonce}" \
        -H "x-acs-content-sha256: ${EMPTY_BODY_SHA256}" \
        -H "Authorization: ${authorization}" \
        -H "Accept: application/json") || {
        log_event "阿里云 API 请求失败 ($action)"
        return 1
    }
    if [ -z "$resp" ] || ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
        log_event "阿里云 API 返回异常 ($action)"
        printf '%s\n' "$resp" >&2
        return 1
    fi
    if printf '%s' "$resp" | jq -e '.Code' >/dev/null 2>&1; then
        log_event "阿里云 API 失败 ($action): $(printf '%s' "$resp" | jq -r '"\(.Code): \(.Message)"')"
        printf '%s\n' "$resp" >&2
        return 1
    fi
    printf '%s' "$resp"
}

log_info "正在获取当前出口IP..."
get_ip || { log_event "获取出口 IP 失败: 所有站点(含 DoH)均不可用"; exit 1; }
log_info "当前出口IP: $CURRENT_IP"

if [ "$SUBDOMAIN" = "@" ]; then
    record_name="$DOMAIN"
else
    record_name="$SUBDOMAIN.$DOMAIN"
fi

# ===== 第一步：查询该主机记录、类型、线路下的现有记录 =====
log_info "正在查询阿里云 DNS 记录..."
record_json=$(ali_api DescribeDomainRecords \
    "DomainName=$DOMAIN" \
    "RRKeyWord=$SUBDOMAIN" \
    "Type=$RECORD_TYPE" \
    "Line=$LINE" \
    "PageSize=500" \
    "PageNumber=1") || {
    log_event "跳过本次更新以避免创建重复记录"
    exit 1
}

# RRKeyWord 是模糊匹配，这里再按主机记录、类型、线路精确过滤
matched=$(printf '%s' "$record_json" | jq -c \
    --arg rr "$SUBDOMAIN" \
    --arg type "$RECORD_TYPE" \
    --arg line "$LINE" '
    (.DomainRecords.Record // [])
    | if type == "array" then . else [.] end
    | map(select(.RR == $rr and (.Type | ascii_upcase) == $type and .Line == $line))
') || {
    log_event "解析阿里云记录失败"
    exit 1
}

record_count=$(printf '%s' "$matched" | jq 'length')
log_info "找到 $record_count 条现有记录"
total_count=$(printf '%s' "$record_json" | jq '.TotalCount // 0')
page_count=$(printf '%s' "$record_json" | jq '(.DomainRecords.Record // []) | if type == "array" then length else 1 end')
# 关键字是模糊匹配。结果被截断又没找到精确记录时，不能创建，避免漏看已有记录后又加一条
if [ "$record_count" -eq 0 ] && [ "$total_count" -gt "$page_count" ]; then
    log_event "查询结果超过一页 (${page_count}/${total_count})，未找到精确匹配，跳过本次更新"
    exit 1
fi

# ===== 第二步：同一主机记录 + 类型 + 线路有多条时，只保留第一条 =====
if [ "$record_count" -gt 1 ]; then
    log_event "检测到 $record_count 条重复记录，正在清理多余记录..."
    for ((i=1; i<record_count; i++)); do
        dup_id=$(printf '%s' "$matched" | jq -r ".[$i].RecordId")
        dup_ip=$(printf '%s' "$matched" | jq -r ".[$i].Value")
        echo "  删除重复记录: ID=$dup_id, IP=$dup_ip"
        if ali_api DeleteDomainRecord "RecordId=$dup_id" >/dev/null; then
            echo "  删除成功"
        else
            echo "  删除失败"
        fi
    done
fi

# ===== 第三步：创建或更新记录 =====
RECORD_ID=$(printf '%s' "$matched" | jq -r '.[0].RecordId // empty')
RECORD_IP=$(printf '%s' "$matched" | jq -r '.[0].Value // empty')
RECORD_STATUS=$(printf '%s' "$matched" | jq -r '.[0].Status // empty')

if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" = "null" ]; then
    OLD_IP="无 (新建记录)"
    log_event "记录不存在，创建中..."
    response=$(ali_api AddDomainRecord \
        "DomainName=$DOMAIN" \
        "RR=$SUBDOMAIN" \
        "Type=$RECORD_TYPE" \
        "Value=$CURRENT_IP" \
        "TTL=$TTL" \
        "Line=$LINE") || {
        log_event "更新失败"
        exit 1
    }
else
    if [ -n "$RECORD_STATUS" ] && [ "$RECORD_STATUS" != "Enable" ] && [ "$RECORD_STATUS" != "ENABLE" ]; then
        log_event "警告: 记录当前状态为 ${RECORD_STATUS}，更新 IP 后仍可能无法解析，请在阿里云控制台启用"
    fi
    current_cmp=$(printf '%s' "$CURRENT_IP" | tr '[:upper:]' '[:lower:]')
    record_cmp=$(printf '%s' "$RECORD_IP" | tr '[:upper:]' '[:lower:]')
    if [ "$current_cmp" = "$record_cmp" ]; then
        log_info "出口 IP 与阿里云记录一致，无需更新 ($CURRENT_IP)"
        exit 0
    fi
    OLD_IP="$RECORD_IP"
    log_event "IP不一致 (阿里云=$RECORD_IP, 当前=$CURRENT_IP)，更新中... Record ID: $RECORD_ID"
    response=$(ali_api UpdateDomainRecord \
        "RecordId=$RECORD_ID" \
        "RR=$SUBDOMAIN" \
        "Type=$RECORD_TYPE" \
        "Value=$CURRENT_IP" \
        "TTL=$TTL" \
        "Line=$LINE") || {
        log_event "更新失败"
        exit 1
    }
fi

new_id=$(printf '%s' "$response" | jq -r '.RecordId // empty')
if [ -n "$new_id" ] && [ "$new_id" != "null" ]; then
    log_event "更新成功: $record_name -> $CURRENT_IP"
    send_telegram "$OLD_IP" "$CURRENT_IP"
else
    log_event "更新失败"
    printf '%s\n' "$response"
    exit 1
fi
