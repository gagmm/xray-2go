#!/bin/bash

# ===========================================
# Xray-2go Linux 增强版
# 新增：自动端口选择、多API获取IP、导出代理为txt
# ===========================================

# 定义颜色
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

# 定义常量
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
export_dir="$(pwd)"

# 定义环境变量
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}
export REALITY_GRPC_SNI=${REALITY_GRPC_SNI:-'www.iij.ad.jp'}
export REALITY_GRPC_TARGET=${REALITY_GRPC_TARGET:-$REALITY_GRPC_SNI}
export REALITY_XHTTP_SNI=${REALITY_XHTTP_SNI:-'www.nazhumi.com'}
export REALITY_XHTTP_TARGET=${REALITY_XHTTP_TARGET:-$REALITY_XHTTP_SNI}

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本" && exit 1

# ==========================================
# 自动查找可用端口
# ==========================================
find_available_port() {
    local start_port=${1:-1000}
    local end_port=${2:-60000}
    local port
    for i in $(seq 1 50); do
        port=$(shuf -i "$start_port"-"$end_port" -n 1)
        if ! lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null 2>&1 && ! ss -tlnp 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return 0
        fi
    done
    # fallback
    shuf -i "$start_port"-"$end_port" -n 1
}

# 自动分配所有端口
assign_ports() {
    yellow "正在自动分配可用端口..."
    local assigned=()
    _alloc_port() {
        local lo=$1 hi=$2 name=$3
        local p
        while :; do
            p=$(find_available_port "$lo" "$hi")
            local clash=0
            for x in "${assigned[@]}"; do
                if [ "$x" = "$p" ]; then clash=1; break; fi
            done
            [ $clash -eq 0 ] && break
        done
        assigned+=("$p")
        export $name=$p
    }
    _alloc_port 1000  60000 PORT
    _alloc_port 8000  9000  ARGO_PORT
    _alloc_port 31001 32000 FB_TCP_PORT       # Argo fallback internal tcp
    _alloc_port 32001 33000 FB_VLESS_WS_PORT  # Argo fallback internal vless ws
    _alloc_port 33001 34000 FB_VMESS_WS_PORT  # Argo fallback internal vmess ws
    _alloc_port 10000 15000 GRPC_PORT
    _alloc_port 15001 20000 XHTTP_PORT
    _alloc_port 20001 25000 VISION_PORT       # 新增：vless+vision+reality (tcp)
    _alloc_port 25001 30000 WSREALITY_PORT    # 新增：vless+ws+reality
    _alloc_port 30001 35000 SS_PORT           # 新增：shadowsocks 2022
    _alloc_port 35001 40000 HY2_PORT          # 新增：hysteria2 (udp)
    green "端口分配完成："
    green "  订阅端口 (PORT):            $PORT"
    green "  Argo 端口 (ARGO_PORT):      $ARGO_PORT"
    green "  Argo 内部 TCP 回落端口:    $FB_TCP_PORT"
    green "  Argo 内部 VLESS-WS 端口:   $FB_VLESS_WS_PORT"
    green "  Argo 内部 VMess-WS 端口:   $FB_VMESS_WS_PORT"
    green "  GRPC-Reality 端口:         $GRPC_PORT"
    green "  XHTTP-Reality 端口:        $XHTTP_PORT"
    green "  Vision-Reality 端口:       $VISION_PORT"
    green "  WS-Reality 端口:           $WSREALITY_PORT"
    green "  Shadowsocks-2022 端口:     $SS_PORT"
    green "  Hysteria2 端口 (UDP):      $HY2_PORT"
}

# 加载保存的端口配置
load_ports() {
    if [ -f "${work_dir}/ports.env" ]; then
        source "${work_dir}/ports.env"
    fi
    export REALITY_GRPC_SNI=${REALITY_GRPC_SNI:-'www.iij.ad.jp'}
    export REALITY_GRPC_TARGET=${REALITY_GRPC_TARGET:-$REALITY_GRPC_SNI}
    export REALITY_XHTTP_SNI=${REALITY_XHTTP_SNI:-'www.nazhumi.com'}
    export REALITY_XHTTP_TARGET=${REALITY_XHTTP_TARGET:-$REALITY_XHTTP_SNI}
}


# ==========================================
# Cloudflare 固定 Tunnel 自动配置
# 当存在 CF_API_TOKEN + CF_ACCOUNT_ID + CF_ZONE_ID 时启用。
# 会创建随机名称的 Cloudflare Tunnel、随机子域名 DNS，并把 cloudflared 改为 token 模式运行。
# ==========================================
cf_api() {
    local method="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl -fsSL -X "$method" "https://api.cloudflare.com/client/v4${path}" \
          -H "Authorization: Bearer ${CF_API_TOKEN}" \
          -H "Content-Type: application/json" \
          --data "$body"
    else
        curl -fsSL -X "$method" "https://api.cloudflare.com/client/v4${path}" \
          -H "Authorization: Bearer ${CF_API_TOKEN}" \
          -H "Content-Type: application/json"
    fi
}

cf_json_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

setup_cloudflare_fixed_tunnel() {
    load_ports
    if [ -z "${CF_API_TOKEN:-}" ] || [ -z "${CF_ACCOUNT_ID:-}" ] || [ -z "${CF_ZONE_ID:-}" ]; then
        ARGO_MODE="quick"
        return 0
    fi
    command -v jq >/dev/null 2>&1 || { red "缺少 jq，无法自动创建 Cloudflare 固定 Tunnel"; return 1; }

    yellow "检测到 Cloudflare 环境变量，优先创建/使用固定 Argo Tunnel..."

    local zone_json zone_name rnd tunnel_name tunnel_secret create_json tunnel_id token host config_json dns_json existing_dns_id
    zone_json=$(cf_api GET "/zones/${CF_ZONE_ID}") || { red "读取 Cloudflare Zone 失败，请检查 CF_API_TOKEN/CF_ZONE_ID 权限"; return 1; }
    zone_name=$(printf '%s' "$zone_json" | jq -r '.result.name // empty')
    [ -z "$zone_name" ] && { red "无法解析 Zone 域名"; return 1; }

    rnd=$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)
    tunnel_name="${XRAY2GO_TUNNEL_NAME:-x2go-${rnd}}"
    host="${XRAY2GO_TUNNEL_HOST:-${tunnel_name}.${zone_name}}"
    tunnel_secret=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)

    create_json=$(cf_api POST "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
      "{\"name\":\"$(cf_json_string "$tunnel_name")\",\"config_src\":\"cloudflare\",\"tunnel_secret\":\"$(cf_json_string "$tunnel_secret")\"}") || {
        red "创建 Cloudflare Tunnel 失败；如果名称冲突，请设置 XRAY2GO_TUNNEL_NAME 换一个名字。"
        return 1
    }
    tunnel_id=$(printf '%s' "$create_json" | jq -r '.result.id // empty')
    [ -z "$tunnel_id" ] && { red "Cloudflare Tunnel ID 获取失败"; return 1; }

    config_json=$(cat <<EOF
{"config":{"ingress":[{"hostname":"$(cf_json_string "$host")","service":"http://localhost:${PORT}","originRequest":{}},{"service":"http_status:404"}]}}
EOF
)
    cf_api PUT "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" "$config_json" >/dev/null || {
        red "写入 Cloudflare Tunnel ingress 配置失败"
        return 1
    }

    existing_dns_id=$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${host}" | jq -r '.result[0].id // empty' 2>/dev/null || true)
    dns_json="{\"type\":\"CNAME\",\"name\":\"$(cf_json_string "$host")\",\"content\":\"${tunnel_id}.cfargotunnel.com\",\"proxied\":true}"
    if [ -n "$existing_dns_id" ]; then
        cf_api PUT "/zones/${CF_ZONE_ID}/dns_records/${existing_dns_id}" "$dns_json" >/dev/null || { red "更新 DNS 记录失败"; return 1; }
    else
        cf_api POST "/zones/${CF_ZONE_ID}/dns_records" "$dns_json" >/dev/null || { red "创建 DNS 记录失败"; return 1; }
    fi

    token=$(cf_api GET "/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token" | jq -r '.result // empty') || true
    [ -z "$token" ] && { red "获取 Tunnel token 失败"; return 1; }

    {
        echo "ARGO_MODE=fixed"
        echo "ARGO_DOMAIN=$host"
        echo "ARGO_TUNNEL_NAME=$tunnel_name"
        echo "ARGO_TUNNEL_ID=$tunnel_id"
        echo "ARGO_TUNNEL_TOKEN=$token"
        echo "XRAY2GO_ARGO_ONLY=${XRAY2GO_ARGO_ONLY:-1}"
    } >> "${work_dir}/ports.env"
    chmod 600 "${work_dir}/ports.env" 2>/dev/null || true

    export ARGO_MODE=fixed ARGO_DOMAIN="$host" ARGO_TUNNEL_NAME="$tunnel_name" ARGO_TUNNEL_ID="$tunnel_id" ARGO_TUNNEL_TOKEN="$token" XRAY2GO_ARGO_ONLY="${XRAY2GO_ARGO_ONLY:-1}"
    green "固定 Argo Tunnel 已配置：${host}"
}

cloudflared_exec_args() {
    load_ports
    if [ "${ARGO_MODE:-quick}" = "fixed" ] && [ -n "${ARGO_TUNNEL_TOKEN:-}" ]; then
        printf '%s' "tunnel --no-autoupdate run --token ${ARGO_TUNNEL_TOKEN}"
    else
        printf '%s' "tunnel --url http://localhost:${PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
    fi
}

# 检查 xray 是否已安装
check_xray() {
if [ -f "${work_dir}/${server_name}" ]; then
    if [ -f /etc/alpine-release ]; then
        rc-service xray status | grep -q "started" && green "running" && return 0 || yellow "not running" && return 1
    else
        [ "$(systemctl is-active xray)" = "active" ] && green "running" && return 0 || yellow "not running" && return 1
    fi
else
    red "not installed"
    return 2
fi
}

# 检查 argo 是否已安装
check_argo() {
if [ -f "${work_dir}/argo" ]; then
    if [ -f /etc/alpine-release ]; then
        rc-service tunnel status | grep -q "started" && green "running" && return 0 || yellow "not running" && return 1
    else
        [ "$(systemctl is-active tunnel)" = "active" ] && green "running" && return 0 || yellow "not running" && return 1
    fi
else
    red "not installed"
    return 2
fi
}

# 检查 caddy 是否已安装
check_caddy() {
if command -v caddy &>/dev/null; then
    if [ -f /etc/alpine-release ]; then
        rc-service caddy status | grep -q "started" && green "running" && return 0 || yellow "not running" && return 1
    else
        [ "$(systemctl is-active caddy)" = "active" ] && green "running" && return 0 || yellow "not running" && return 1
    fi
else
    red "not installed"
    return 2
fi
}

# 根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command -v "$package" &>/dev/null; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command -v apt &>/dev/null; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command -v dnf &>/dev/null; then
                dnf install -y "$package"
            elif command -v yum &>/dev/null; then
                yum install -y "$package"
            elif command -v apk &>/dev/null; then
                apk update
                apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command -v "$package" &>/dev/null; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command -v apt &>/dev/null; then
                apt remove -y "$package" && apt autoremove -y
            elif command -v dnf &>/dev/null; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command -v yum &>/dev/null; then
                yum remove -y "$package" && yum autoremove -y
            elif command -v apk &>/dev/null; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 判断本机是否处在 NAT/CGNAT 后面：
# - 默认出口 IPv4 是 RFC1918 / CGNAT / 链路本地 / 回环地址 => 没有直接公网入口
# - 默认出口 IPv4 与公网出口 IPv4 不一致 => 多数情况下也是 NAT
is_private_or_cgnat_ipv4() {
    local ip="$1" a b
    IFS=. read -r a b _ _ <<< "$ip"
    [[ "$a" = "10" ]] && return 0
    [[ "$a" = "127" ]] && return 0
    [[ "$a" = "169" && "$b" = "254" ]] && return 0
    [[ "$a" = "172" && "$b" -ge 16 && "$b" -le 31 ]] && return 0
    [[ "$a" = "192" && "$b" = "168" ]] && return 0
    [[ "$a" = "100" && "$b" -ge 64 && "$b" -le 127 ]] && return 0
    return 1
}

get_default_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

detect_nat_machine() {
    local local_ip public_ip
    local_ip=$(get_default_ipv4)
    public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')

    if [[ -z "$local_ip" || ! "$local_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        yellow "未检测到默认 IPv4 出口，按 NAT/无公网入口处理。"
        return 0
    fi
    if is_private_or_cgnat_ipv4 "$local_ip"; then
        yellow "检测到本机出口地址为内网/CGNAT：${local_ip}，按 NAT 机处理。"
        return 0
    fi
    if [[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$public_ip" != "$local_ip" ]]; then
        yellow "检测到公网出口 IP(${public_ip}) 与本机出口 IP(${local_ip}) 不一致，按 NAT 机处理。"
        return 0
    fi
    return 1
}

apply_nat_argo_policy() {
    load_ports
    if [ "${XRAY2GO_FORCE_DIRECT:-0}" = "1" ]; then
        yellow "已设置 XRAY2GO_FORCE_DIRECT=1，跳过 NAT 自动 Argo-only 策略。"
        return 0
    fi
    if detect_nat_machine; then
        {
            echo "ARGO_MODE=${ARGO_MODE:-quick}"
            echo "XRAY2GO_ARGO_ONLY=1"
        } >> "${work_dir}/ports.env"
        export ARGO_MODE="${ARGO_MODE:-quick}" XRAY2GO_ARGO_ONLY=1
        green "NAT/无公网入口机器：已自动启用 Argo-only 节点输出。"
    else
        green "检测到本机可能具备公网 IPv4 入口：保留直连节点输出。"
    fi
}

get_current_argo_domain() {
    load_ports
    if [ "${ARGO_MODE:-quick}" = "fixed" ] && [ -n "${ARGO_DOMAIN:-}" ]; then
        echo "$ARGO_DOMAIN"
        return 0
    fi
    if [ -f "${work_dir}/argo.log" ]; then
        sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1
    fi
}

build_subscription_url() {
    local ip="$1" port="$2" path="$3" argo_domain="${4:-}"
    load_ports
    if [ "${XRAY2GO_ARGO_ONLY:-0}" = "1" ]; then
        [ -z "$argo_domain" ] && argo_domain=$(get_current_argo_domain)
        if [ -n "$argo_domain" ] && [ "$argo_domain" != "获取失败请重试" ]; then
            printf 'https://%s/%s' "$argo_domain" "$path"
            return 0
        fi
    fi
    printf 'http://%s:%s/%s' "$ip" "$port" "$path"
}


# 获取ip - 多API兜底
get_realip() {
    local apis=(
        "ifconfig.me"
        "api.ipify.org"
        "icanhazip.com"
        "ipecho.net/plain"
        "checkip.amazonaws.com"
        "ipv4.ip.sb"
    )

    local ip=""
    for api in "${apis[@]}"; do
        ip=$(curl -s --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # 检测是否为 Cloudflare 等需要 IPv6 的情况
            if [ "$api" = "ipv4.ip.sb" ] || [ "$api" = "ifconfig.me" ]; then
                if echo "$(curl -s --max-time 3 http://ipinfo.io/org 2>/dev/null)" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                    continue
                fi
            fi
            echo "$ip"
            return
        fi
    done

    # IPv4 全部失败，尝试 IPv6
    local ipv6_apis=(
        "api64.ipify.org"
        "ipv6.ip.sb"
    )
    for api in "${ipv6_apis[@]}"; do
        ip=$(curl -s --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$ip" ]; then
            echo "[$ip]"
            return
        fi
    done

    # 全部失败，手动输入
    red "无法自动获取公网 IP"
    reading "请手动输入你的服务器公网 IP: " manual_ip
    if [ -n "$manual_ip" ]; then
        echo "$manual_ip"
    else
        echo "127.0.0.1"
    fi
}

# 使用 RealiTLScanner 自动选择 REALITY 伪装域名；失败时保留默认回退域名。
# 官方工具建议优先在本地运行，避免云端扫描导致 VPS 被标记，所以这里仅在显式设置
# REALITY_SCAN=1 或 REALITY_SCAN_ADDR/URL/IN 时启用。
reality_apply_scanner_result() {
    local arch_arg="$1"
    export REALITY_GRPC_SNI=${REALITY_GRPC_SNI:-'www.iij.ad.jp'}
    export REALITY_GRPC_TARGET=${REALITY_GRPC_TARGET:-$REALITY_GRPC_SNI}
    export REALITY_XHTTP_SNI=${REALITY_XHTTP_SNI:-'www.nazhumi.com'}
    export REALITY_XHTTP_TARGET=${REALITY_XHTTP_TARGET:-$REALITY_XHTTP_SNI}

    if [[ "${REALITY_SCAN:-0}" != "1" && -z "${REALITY_SCAN_ADDR:-}" && -z "${REALITY_SCAN_URL:-}" && -z "${REALITY_SCAN_IN:-}" ]]; then
        return 0
    fi

    if [[ "$arch_arg" != "64" ]]; then
        yellow "RealiTLScanner 当前脚本仅自动下载 linux-64 版本，当前架构 $arch_arg 不支持，保留默认 REALITY 域名。"
        return 0
    fi

    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}"
    local scanner="${work_dir}/RealiTLScanner"
    if [[ ! -x "$scanner" ]]; then
        yellow "正在下载 RealiTLScanner..."
        curl -fsSL -o "$scanner" "https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.1/RealiTLScanner-linux-64" || {
            yellow "RealiTLScanner 下载失败，保留默认 REALITY 域名。"
            return 0
        }
        chmod +x "$scanner"
    fi

    local out="${REALITY_SCAN_OUT:-/tmp/realitlscanner-out.csv}"
    local args=()
    if [[ -n "${REALITY_SCAN_IN:-}" ]]; then
        args=(-in "$REALITY_SCAN_IN")
    elif [[ -n "${REALITY_SCAN_URL:-}" ]]; then
        args=(-url "$REALITY_SCAN_URL")
    elif [[ -n "${REALITY_SCAN_ADDR:-}" ]]; then
        args=(-addr "$REALITY_SCAN_ADDR")
    else
        yellow "已启用 REALITY_SCAN，但未设置 REALITY_SCAN_ADDR / REALITY_SCAN_URL / REALITY_SCAN_IN，保留默认 REALITY 域名。"
        return 0
    fi

    yellow "正在用 RealiTLScanner 扫描 REALITY 伪装目标..."
    if ! timeout "${REALITY_SCAN_MAX_SECONDS:-180}" "$scanner" "${args[@]}" \
        -port "${REALITY_SCAN_PORT:-443}" \
        -thread "${REALITY_SCAN_THREAD:-5}" \
        -timeout "${REALITY_SCAN_TIMEOUT:-5}" \
        -out "$out" >/tmp/realitlscanner.log 2>&1; then
        yellow "RealiTLScanner 扫描失败或超时，保留默认 REALITY 域名。日志：/tmp/realitlscanner.log"
        return 0
    fi

    local line ip origin cert sni
    line=$(awk -F',' 'NR>1 && $1 != "" && $2 != "" {print; exit}' "$out" 2>/dev/null || true)
    if [[ -z "$line" ]]; then
        yellow "RealiTLScanner 没有可用结果，保留默认 REALITY 域名。"
        return 0
    fi
    ip=$(echo "$line" | awk -F',' '{print $1}' | tr -d ' "\r')
    origin=$(echo "$line" | awk -F',' '{print $2}' | tr -d ' "\r')
    cert=$(echo "$line" | awk -F',' '{print $3}' | tr -d ' "\r')
    sni="$cert"
    if [[ -z "$sni" || "$sni" == \*.* ]]; then
        sni="$origin"
    fi
    if [[ -z "$ip" || -z "$sni" || "$sni" == *'*'* ]]; then
        yellow "RealiTLScanner 结果不可用，保留默认 REALITY 域名。"
        return 0
    fi

    export REALITY_GRPC_TARGET="$ip"
    export REALITY_GRPC_SNI="$sni"
    export REALITY_XHTTP_TARGET="$ip"
    export REALITY_XHTTP_SNI="$sni"
    green "REALITY 伪装目标已切换为：target=${ip}:443, sni=${sni}（默认域名仍作为失败回退）"
}


# 启用 Linux BBR + fq 队列优化（幂等、最小侵入）
optimize_bbr() {
    if [ "${XRAY2GO_ENABLE_BBR:-1}" = "0" ]; then
        yellow "已通过 XRAY2GO_ENABLE_BBR=0 跳过 BBR 优化"
        return 0
    fi

    if [ -f /proc/user_beancounters ]; then
        yellow "检测到 OpenVZ/受限容器，可能无法修改内核拥塞控制，跳过 BBR 优化"
        return 0
    fi

    if ! command -v sysctl >/dev/null 2>&1; then
        yellow "系统缺少 sysctl，跳过 BBR 优化"
        return 0
    fi

    modprobe tcp_bbr >/dev/null 2>&1 || true

    local available_cc
    available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! echo " ${available_cc} " | grep -qw bbr; then
        yellow "当前内核暂未提供 BBR：${available_cc:-unknown}，未强行安装第三方内核"
        yellow "如需更激进的 BBRplus/自定义内核，请先人工审计并单独执行内核脚本。"
        return 0
    fi

    local conf_dir="/etc/sysctl.d"
    local conf_file="${conf_dir}/99-xray2go-bbr.conf"
    mkdir -p "$conf_dir"

    # 清理旧位置里的同名键，避免 /etc/sysctl.conf 或其它 sysctl.d 文件覆盖本配置。
    local f
    for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
        [ -f "$f" ] || continue
        [ "$f" = "$conf_file" ] && continue
        if grep -Eq '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*=' "$f"; then
            cp -a "$f" "${f}.xray2go-bbr.bak" 2>/dev/null || true
            sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d; /^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' "$f" 2>/dev/null || true
        fi
    done

    cat > "$conf_file" <<'EOF'
# Managed by xray-2go. Safe baseline for high-latency/high-bandwidth proxy links.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    chmod 644 "$conf_file" 2>/dev/null || true

    local ok=1
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || ok=0
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || ok=0
    sysctl -p "$conf_file" >/dev/null 2>&1 || ok=0

    local current_cc current_qdisc loaded
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    loaded=$(lsmod 2>/dev/null | grep -w '^tcp_bbr' || true)

    if [ "$current_cc" = "bbr" ] && [ "$current_qdisc" = "fq" ]; then
        green "BBR 优化已启用：tcp_congestion_control=${current_cc}, default_qdisc=${current_qdisc}"
        [ -n "$loaded" ] && green "tcp_bbr 模块已加载"
        return 0
    fi

    yellow "BBR 优化已写入 ${conf_file}，但当前生效状态异常：tcp_congestion_control=${current_cc}, default_qdisc=${current_qdisc}"
    [ "$ok" -eq 0 ] && yellow "部分 sysctl 参数应用失败，可能是内核/容器限制。"
    return 0
}

# 下载并安装 xray,cloudflared
install_xray() {
    clear
    purple "正在安装Xray-2go中，请稍等..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; ARCH_ARG='64' ;;
        'x86' | 'i686' | 'i386') ARCH='386'; ARCH_ARG='32' ;;
        'aarch64' | 'arm64') ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        'armv7l') ARCH='armv7'; ARCH_ARG='arm32-v7a' ;;
        's390x') ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    # 自动分配端口
    assign_ports

    # REALITY 伪装域名：默认使用内置回退，可通过 RealiTLScanner 显式扫描替换
    reality_apply_scanner_result "$ARCH_ARG"

    # 下载xray,cloudflared
    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}"
    # 使用 gagmm/Xray-core fork（包含 pgstats 观测插件）。要回退到上游，请把下一行改成 XTLS/Xray-core/releases/latest。
    XRAY_RELEASE_REPO="${XRAY_RELEASE_REPO:-gagmm/Xray-core}"
    XRAY_RELEASE_TAG="${XRAY_RELEASE_TAG:-v26.4.25-pgstats4}"
    curl -sLo "${work_dir}/${server_name}.zip" "https://github.com/${XRAY_RELEASE_REPO}/releases/download/${XRAY_RELEASE_TAG}/Xray-linux-${ARCH_ARG}.zip"
    curl -sLo "${work_dir}/qrencode" "https://github.com/eooce/test/releases/download/${ARCH}/qrencode-linux-${ARCH}"
    curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    unzip "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1 && chmod +x ${work_dir}/${server_name} ${work_dir}/argo ${work_dir}/qrencode
    rm -rf "${work_dir}/${server_name}.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"

    # 生成随机密码
    password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 24)
    # Shadowsocks 2022 (blake3-aes-128-gcm) 需要 16 字节 base64 密钥
    ss_key=$(openssl rand -base64 16 2>/dev/null || head -c 16 /dev/urandom | base64)
    # Hysteria2 认证密码。Xray 官方配置里 hysteria inbound 的 clients.auth 是任意字符串。
    hy2_password=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

    # Hysteria2 基于 QUIC/TLS，需要服务端证书；这里生成自签证书，客户端链接使用 insecure=1。
    if [ ! -s "${work_dir}/hy2.crt" ] || [ ! -s "${work_dir}/hy2.key" ]; then
        "${work_dir}/${server_name}" tls cert -domain=xray2go.local -name=xray2go.local -org=xray2go -expire=87600h -file="${work_dir}/hy2" >/dev/null 2>&1 || \
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "${work_dir}/hy2.key" \
            -out "${work_dir}/hy2.crt" \
            -days 3650 \
            -subj "/CN=xray2go.local" \
            -addext "subjectAltName=DNS:xray2go.local" >/dev/null 2>&1 || \
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "${work_dir}/hy2.key" \
            -out "${work_dir}/hy2.crt" \
            -days 3650 \
            -subj "/CN=xray2go.local" >/dev/null 2>&1
        chmod 600 "${work_dir}/hy2.key" 2>/dev/null || true
        chmod 644 "${work_dir}/hy2.crt" 2>/dev/null || true
    fi

    # 关闭防火墙
    iptables -F > /dev/null 2>&1 && iptables -P INPUT ACCEPT > /dev/null 2>&1 && iptables -P FORWARD ACCEPT > /dev/null 2>&1 && iptables -P OUTPUT ACCEPT > /dev/null 2>&1
    command -v ip6tables &> /dev/null && ip6tables -F > /dev/null 2>&1 && ip6tables -P INPUT ACCEPT > /dev/null 2>&1 && ip6tables -P FORWARD ACCEPT > /dev/null 2>&1 && ip6tables -P OUTPUT ACCEPT > /dev/null 2>&1

    output=$(/etc/xray/xray x25519)
    private_key=$(echo "${output}" | grep "PrivateKey:" | awk '{print $2}')
    public_key=$(echo "${output}" | grep 'Password (PublicKey):' | awk '{print $3}')

    # 保存端口和密码信息到文件
    cat > "${work_dir}/ports.env" << EOF
PORT=$PORT
ARGO_PORT=$ARGO_PORT
FB_TCP_PORT=$FB_TCP_PORT
FB_VLESS_WS_PORT=$FB_VLESS_WS_PORT
FB_VMESS_WS_PORT=$FB_VMESS_WS_PORT
GRPC_PORT=$GRPC_PORT
XHTTP_PORT=$XHTTP_PORT
VISION_PORT=$VISION_PORT
WSREALITY_PORT=$WSREALITY_PORT
SS_PORT=$SS_PORT
HY2_PORT=$HY2_PORT
password=$password
ss_key=$ss_key
hy2_password=$hy2_password
private_key=$private_key
public_key=$public_key
UUID=$UUID
REALITY_GRPC_TARGET=$REALITY_GRPC_TARGET
REALITY_GRPC_SNI=$REALITY_GRPC_SNI
REALITY_XHTTP_TARGET=$REALITY_XHTTP_TARGET
REALITY_XHTTP_SNI=$REALITY_XHTTP_SNI
EOF

    # 生成配置文件
cat > "${config_dir}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "tag": "in-argo-vision",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none",
        "fallbacks": [
          { "dest": $FB_TCP_PORT }, { "path": "/vless-argo", "dest": $FB_VLESS_WS_PORT },
          { "path": "/vmess-argo", "dest": $FB_VMESS_WS_PORT }
        ]
      },
      "streamSettings": { "network": "tcp" }
    },
    {
      "port": $FB_TCP_PORT, "listen": "127.0.0.1", "tag": "in-argo-fb-tcp", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    {
      "port": $FB_VLESS_WS_PORT, "listen": "127.0.0.1", "tag": "in-argo-vless-ws", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID", "level": 0 }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "port": $FB_VMESS_WS_PORT, "listen": "127.0.0.1", "tag": "in-argo-vmess-ws", "protocol": "vmess",
      "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "listen":"::","port": $XHTTP_PORT, "tag": "in-xhttp-reality", "protocol": "vless","settings": {"clients": [{"id": "$UUID"}],"decryption": "none"},
      "streamSettings": {"network": "xhttp","security": "reality","realitySettings": {"target": "${REALITY_XHTTP_TARGET}:443","xver": 0,"serverNames":
      ["${REALITY_XHTTP_SNI}"],"privateKey": "$private_key","shortIds": [""]}},"sniffing": {"enabled": true,"destOverride": ["http","tls","quic"]}
    },
    {
      "listen":"::","port":$GRPC_PORT,"tag":"in-grpc-reality","protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},
      "streamSettings":{"network":"grpc","security":"reality","realitySettings":{"dest":"${REALITY_GRPC_TARGET}:443","serverNames":["${REALITY_GRPC_SNI}"],
      "privateKey":"$private_key","shortIds":[""]},"grpcSettings":{"serviceName":"grpc"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
    },
    {
      "listen":"::","port":$VISION_PORT,"tag":"in-vision-reality","protocol":"vless",
      "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
      "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"${REALITY_XHTTP_TARGET}:443","xver":0,"serverNames":["${REALITY_XHTTP_SNI}"],
      "privateKey":"$private_key","shortIds":[""]}},
      "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
    },
    {
      "listen":"::","port":$SS_PORT,"tag":"in-ss2022","protocol":"shadowsocks",
      "settings":{"method":"2022-blake3-aes-128-gcm","password":"$ss_key","network":"tcp,udp"},
      "streamSettings":{"network":"tcp"},
      "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
    },
    {
      "listen":"::","port":$HY2_PORT,"tag":"in-hysteria2","protocol":"hysteria",
      "settings":{"version":2,"clients":[{"auth":"$hy2_password","level":0,"email":"xray2go@hy2"}]},
      "streamSettings":{
        "network":"hysteria",
        "security":"tls",
        "tlsSettings":{"serverName":"xray2go.local","alpn":["h3"],"certificates":[{"certificateFile":"${work_dir}/hy2.crt","keyFile":"${work_dir}/hy2.key"}]},
        "hysteriaSettings":{"version":2,"auth":"$hy2_password","udpIdleTimeout":60,"masquerade":{"type":"string","content":"not found","statusCode":404}}
      },
      "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
    }
  ],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]$( [ -n "$PGSTATS_DSN" ] && cat <<PGSECTION
,
  "pgstats": {
    "enabled": true,
    "dsn": "${PGSTATS_DSN//\"/\\\"}",
    "snapshotIntervalSeconds": ${PGSTATS_SNAPSHOT_INTERVAL:-10},
    "maxHttpCaptureBytes": ${PGSTATS_MAX_HTTP_BYTES:-102400},
    "captureHttp": ${PGSTATS_CAPTURE_HTTP:-true},
    "captureConnections": ${PGSTATS_CAPTURE_CONN:-true},
    "captureIpStats": ${PGSTATS_CAPTURE_IP:-true},
    "captureOnline": ${PGSTATS_CAPTURE_ONLINE:-true},
    "queueBuffer": ${PGSTATS_QUEUE:-4096}
  }
PGSECTION
)
}
EOF
}

# debian/ubuntu/centos 守护进程
main_systemd_services() {
    load_ports
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=$work_dir/xray run -c $config_dir
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c '/etc/xray/argo $(. /etc/xray/ports.env 2>/dev/null; if [ "${ARGO_MODE:-quick}" = "fixed" ] && [ -n "${ARGO_TUNNEL_TOKEN:-}" ]; then echo "tunnel --no-autoupdate run --token ${ARGO_TUNNEL_TOKEN}"; else echo "tunnel --url http://localhost:${PORT} --no-autoupdate --edge-ip-version auto --protocol http2"; fi)'
StandardOutput=append:/etc/xray/argo.log
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target

EOF
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    systemctl daemon-reload
    systemctl enable xray
    systemctl is-active --quiet xray || systemctl start xray
    systemctl enable tunnel
    systemctl start tunnel
    systemctl is-active --quiet tunnel || systemctl start xray
}

# 适配alpine 守护进程
alpine_openrc_services() {
    load_ports
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run

description="Xray service"
command="/etc/xray/xray"
command_args="run -c /etc/xray/config.json"
command_background=true
pidfile="/var/run/xray.pid"
EOF

    cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run

description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '. /etc/xray/ports.env 2>/dev/null; if [ \"${ARGO_MODE:-quick}\" = \"fixed\" ] && [ -n \"${ARGO_TUNNEL_TOKEN:-}\" ]; then /etc/xray/argo tunnel --no-autoupdate run --token \"${ARGO_TUNNEL_TOKEN}\" > /etc/xray/argo.log 2>&1; else /etc/xray/argo tunnel --url http://localhost:${PORT} --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/xray/argo.log 2>&1; fi'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF

    chmod +x /etc/init.d/xray
    chmod +x /etc/init.d/tunnel

    rc-update add xray default
    rc-update add tunnel default
}


get_info() {
    clear
    load_ports
    IP=$(get_realip)

    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" | tr -d '\n' | awk -F\" '{c="";o="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="org")o=$(x+2)};if(c&&o)print c"-"o}' | sed 's/ /_/g' || echo "vps")

    if [ "${ARGO_MODE:-quick}" = "fixed" ] && [ -n "${ARGO_DOMAIN:-}" ]; then
        argodomain="$ARGO_DOMAIN"
    elif [ -f "${work_dir}/argo.log" ]; then
        for i in {1..10}; do
            purple "第 $i 次尝试获取ArgoDoamin中..."
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            [ -n "$argodomain" ] && break
            sleep 2
        done
    else
        restart_argo
        sleep 6
        for i in {1..5}; do
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            [ -n "$argodomain" ] && break
            sleep 2
        done
    fi

    if [ -z "$argodomain" ]; then
        red "获取 Argo 域名失败，请稍后重试（菜单4 -> 5重新获取）"
        argodomain="获取失败请重试"
    fi

    green "\nArgoDomain：${purple}$argodomain${re}\n"

    argo_add="${XRAY2GO_ARGO_ADD:-$argodomain}"
    if [ "${XRAY2GO_ARGO_ONLY:-0}" = "1" ]; then
        cat > ${work_dir}/url.txt <<EOF
vless://${UUID}@${argo_add}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}-vless-argo-fixed

vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${isp}-vmess-argo-fixed\", \"add\": \"${argo_add}\", \"port\": \"${CFPORT}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"chrome\"}" | base64 -w0)

EOF
    else
        cat > ${work_dir}/url.txt <<EOF
vless://${UUID}@${IP}:${GRPC_PORT}?encryption=none&security=reality&sni=${REALITY_GRPC_SNI}&fp=chrome&pbk=${public_key}&allowInsecure=1&type=grpc&authority=${REALITY_GRPC_SNI}&serviceName=grpc&mode=gun#${isp}-grpc-reality

vless://${UUID}@${IP}:${XHTTP_PORT}?encryption=none&security=reality&sni=${REALITY_XHTTP_SNI}&fp=chrome&pbk=${public_key}&allowInsecure=1&type=xhttp&mode=auto#${isp}-xhttp-reality

vless://${UUID}@${IP}:${VISION_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_XHTTP_SNI}&fp=chrome&pbk=${public_key}&allowInsecure=1&type=tcp#${isp}-vision-reality

ss://$(echo -n "2022-blake3-aes-128-gcm:${ss_key}" | base64 -w0)@${IP}:${SS_PORT}#${isp}-ss2022

hysteria2://${hy2_password}@${IP}:${HY2_PORT}?insecure=1&sni=xray2go.local#${isp}-hy2

vless://${UUID}@${argo_add}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}-vless-argo

vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${isp}-vmess-argo\", \"add\": \"${argo_add}\", \"port\": \"${CFPORT}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"chrome\"}" | base64 -w0)

EOF
    fi
    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt
    base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt
    sub_link=$(build_subscription_url "$IP" "$PORT" "$password" "$argodomain")
    yellow "\n温馨提醒：NAT/家宽机器会自动使用 Argo 订阅链接，直连 Caddy 订阅链接不可用。\n"
    green "节点订阅链接：$sub_link\n\n订阅链接适用于V2rayN,Nekbox,karing,Sterisand,Loon,小火箭,圈X等\n"
    green "订阅二维码"
    $work_dir/qrencode "$sub_link"
    echo ""

    # 安装完成后自动导出一份
    export_proxy_txt "auto"
    xray2go_upload_links_latest_to_postgres || true
}

# ==========================================
# PostgreSQL 上传 xray2go_links_latest.txt (xray2go+)
# ==========================================
xray2go_postgres_enabled() {
    [[ -n "${DATABASE_URL:-}" || -n "${POSTGRES_HOST:-}" || -n "${POSTGRES_USER:-}" || -n "${POSTGRES_DB:-}" || -n "${PGHOST:-}" || -n "${PGUSER:-}" || -n "${PGDATABASE:-}" || -n "${PGSTATS_DSN:-}" || -n "${XRAY2GO_PG_PEER_USER:-}" ]]
}

xray2go_ensure_psql() {
    if command -v psql &>/dev/null; then
        return 0
    fi
    yellow "检测到 PostgreSQL 环境变量，但缺少 psql，尝试安装 postgresql-client..."
    if command -v apt &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt install -y postgresql-client >/dev/null 2>&1 || true
    elif command -v yum &>/dev/null; then
        yum install -y postgresql >/dev/null 2>&1 || true
    elif command -v apk &>/dev/null; then
        apk add postgresql-client >/dev/null 2>&1 || true
    fi
    command -v psql &>/dev/null || { yellow "psql 不可用，跳过 PostgreSQL 上传"; return 1; }
}

xray2go_psql_exec() {
    local sql_file="$1"
    if [[ -n "${XRAY2GO_PG_PEER_USER:-}" ]]; then
        sudo -u "${XRAY2GO_PG_PEER_USER}" \
            PGDATABASE="${POSTGRES_DB:-${PGDATABASE:-xray}}" \
            psql -v ON_ERROR_STOP=1 -q < "$sql_file"
    elif [[ -n "${DATABASE_URL:-}" ]]; then
        PGPASSWORD="${POSTGRES_PASSWORD:-${PGPASSWORD:-}}" \
            psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -f "$sql_file"
    elif [[ -n "${PGSTATS_DSN:-}" ]]; then
        psql "${PGSTATS_DSN}" -v ON_ERROR_STOP=1 -q -f "$sql_file"
    else
        PGHOST="${POSTGRES_HOST:-${PGHOST:-127.0.0.1}}" \
        PGPORT="${POSTGRES_PORT:-${PGPORT:-5432}}" \
        PGUSER="${POSTGRES_USER:-${PGUSER:-postgres}}" \
        PGPASSWORD="${POSTGRES_PASSWORD:-${PGPASSWORD:-}}" \
        PGDATABASE="${POSTGRES_DB:-${PGDATABASE:-xray}}" \
            psql -v ON_ERROR_STOP=1 -q -f "$sql_file"
    fi
}

xray2go_upload_links_latest_to_postgres() {
    xray2go_postgres_enabled || return 0
    xray2go_ensure_psql || return 0

    local links_file="${XRAY2GO_LINKS_FILE:-}"
    if [[ -z "$links_file" ]]; then
        for candidate in \
            "${export_dir}/xray2go_links_latest.txt" \
            "$(pwd)/xray2go_links_latest.txt" \
            "${HOME}/xray2go_links_latest.txt" \
            "${work_dir}/xray2go_links_latest.txt" \
            "${work_dir}/url.txt"; do
            if [[ -f "$candidate" ]]; then
                links_file="$candidate"
                break
            fi
        done
    fi
    [[ -f "$links_file" ]] || { yellow "未找到 xray2go_links_latest.txt，跳过 PostgreSQL 上传"; return 0; }

    local IP argodomain tmp_sql
    IP=$(get_realip)
    argodomain=""
    if [[ -f "${work_dir}/argo.log" ]]; then
        argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
    fi
    tmp_sql=$(mktemp)

    XRAY2GO_WORK_DIR="${work_dir}" \
    XRAY2GO_CONFIG_DIR="${config_dir}" \
    XRAY2GO_LINKS_FILE="$links_file" \
    XRAY2GO_PUBLIC_IP="$IP" \
    XRAY2GO_ARGO_DOMAIN="$argodomain" \
    XRAY2GO_CFIP="$CFIP" \
    python3 - <<'PYEOF' > "$tmp_sql"
import hashlib
import json
import os
import socket
from pathlib import Path

work_dir = Path(os.environ["XRAY2GO_WORK_DIR"])
ports_env = work_dir / "ports.env"
config_file = Path(os.environ.get("XRAY2GO_CONFIG_DIR", str(work_dir / "config.json")))
links_file = Path(os.environ["XRAY2GO_LINKS_FILE"])

def read_env(path):
    data = {}
    if path.exists():
        for line in path.read_text(errors="ignore").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip()
    return data

def q(value):
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"

def qjson(value):
    return q(json.dumps(value, ensure_ascii=False, sort_keys=True)) + "::jsonb"

p = read_env(ports_env)
links = {}
meta = {"source_file": str(links_file)}
for i, line in enumerate([x.strip() for x in links_file.read_text(errors="ignore").splitlines() if x.strip() and not x.strip().startswith("#")], 1):
    if "=" in line and not line.startswith(("vless://", "vmess://", "ss://", "trojan://", "hysteria2://")):
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if "://" in v:
            links[k or f"link_{i}"] = v
        else:
            meta[k or f"meta_{i}"] = v
    else:
        links[f"link_{i}"] = line

hostname = socket.gethostname()
public_ip = os.environ.get("XRAY2GO_PUBLIC_IP", "").strip().strip("[]")
public_ip_sql = "NULL" if not public_ip or public_ip == "127.0.0.1" else q(public_ip) + "::inet"
ports = {k: int(v) for k, v in p.items() if k.endswith("PORT") and str(v).isdigit()}
sub_url = f"http://{public_ip}:{p.get('PORT','')}/{p.get('password','')}" if public_ip and p.get("PORT") and p.get("password") else ""
try:
    config_json = json.loads(config_file.read_text()) if config_file.exists() else {}
except Exception:
    config_json = {"_raw": config_file.read_text(errors="ignore")[:200000]} if config_file.exists() else {}
node_id = os.environ.get("XRAY2GO_NODE_ID") or hashlib.sha256(f"{hostname}|{work_dir}".encode()).hexdigest()[:24]
payload = {
    "node_id": node_id,
    "hostname": hostname,
    "public_ip": public_ip if public_ip and public_ip != "127.0.0.1" else "",
    "install_dir": str(work_dir),
    "cdn_host": meta.get("host") or os.environ.get("XRAY2GO_CFIP", ""),
    "argo_domain": os.environ.get("XRAY2GO_ARGO_DOMAIN", ""),
    "sub_url": sub_url,
    "uuid": p.get("UUID", ""),
    "public_key": p.get("public_key", ""),
    "ports": ports,
    "links": links,
    "config_json": config_json,
    "raw_ports_env": {**p, **meta},
    "script_version": "links_latest",
}
if os.environ.get("XRAY2GO_DB_WRITE_ONLY", "").lower() in ("1", "true", "yes", "on"):
    print(f"SELECT public.xray2go_ingest_links({qjson(payload)});")
    raise SystemExit
print("""
CREATE TABLE IF NOT EXISTS public.xray_node_configs (
    node_id text PRIMARY KEY,
    hostname text NOT NULL DEFAULT '',
    public_ip inet,
    install_dir text NOT NULL DEFAULT '',
    cdn_host text NOT NULL DEFAULT '',
    argo_domain text NOT NULL DEFAULT '',
    sub_url text NOT NULL DEFAULT '',
    uuid text NOT NULL DEFAULT '',
    public_key text NOT NULL DEFAULT '',
    ports jsonb NOT NULL DEFAULT '{}'::jsonb,
    links jsonb NOT NULL DEFAULT '{}'::jsonb,
    config_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    raw_ports_env jsonb NOT NULL DEFAULT '{}'::jsonb,
    script_version text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
""")
print(f"""
INSERT INTO public.xray_node_configs (
    node_id, hostname, public_ip, install_dir, cdn_host, argo_domain, sub_url,
    uuid, public_key, ports, links, config_json, raw_ports_env, script_version,
    created_at, updated_at
) VALUES (
    {q(node_id)}, {q(hostname)}, {public_ip_sql}, {q(str(work_dir))}, {q(meta.get('host') or os.environ.get('XRAY2GO_CFIP',''))}, {q(os.environ.get('XRAY2GO_ARGO_DOMAIN',''))}, {q(sub_url)},
    {q(p.get('UUID',''))}, {q(p.get('public_key',''))}, {qjson(ports)}, {qjson(links)}, {qjson(config_json)}, {qjson({**p, **meta})}, {q('links_latest')},
    now(), now()
)
ON CONFLICT (node_id) DO UPDATE SET
    hostname = EXCLUDED.hostname,
    public_ip = EXCLUDED.public_ip,
    install_dir = EXCLUDED.install_dir,
    cdn_host = EXCLUDED.cdn_host,
    argo_domain = EXCLUDED.argo_domain,
    sub_url = EXCLUDED.sub_url,
    uuid = EXCLUDED.uuid,
    public_key = EXCLUDED.public_key,
    ports = EXCLUDED.ports,
    links = EXCLUDED.links,
    config_json = EXCLUDED.config_json,
    raw_ports_env = EXCLUDED.raw_ports_env,
    script_version = EXCLUDED.script_version,
    updated_at = now();
""")
PYEOF

    if xray2go_psql_exec "$tmp_sql"; then
        green "xray2go_links_latest.txt 已上传到 PostgreSQL 表 public.xray_node_configs"
    else
        yellow "PostgreSQL 上传失败，安装流程继续"
    fi
    rm -f "$tmp_sql"
}

# 处理ubuntu系统中没有caddy源的问题
install_caddy () {
if [ -f /etc/os-release ] && (grep -q "Ubuntu" /etc/os-release || grep -q "Debian GNU/Linux 11" /etc/os-release); then
    purple "安装依赖中...\n"
    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | tee /etc/apt/trusted.gpg.d/caddy-stable.asc
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    rm /etc/apt/trusted.gpg.d/caddy-stable.asc /usr/share/keyrings/caddy-archive-keyring.gpg 2>/dev/null
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/caddy-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" | tee /etc/apt/sources.list.d/caddy-stable.list
    DEBIAN_FRONTEND=noninteractive apt update -y && manage_packages install caddy
else
    manage_packages install caddy
fi
}

# caddy订阅配置
add_caddy_conf() {
    load_ports
    [ -f /etc/caddy/Caddyfile ] && cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak > /dev/null 2>&1
    rm -rf /etc/caddy/Caddyfile
    cat > /etc/caddy/Caddyfile << EOF
{
    auto_https off
    log {
        output file /var/log/caddy/caddy.log {
            roll_size 10MB
            roll_keep 10
            roll_keep_for 720h
        }
    }
}

:$PORT {
    handle /$password {
        root * /etc/xray
        try_files /sub.txt
        file_server browse
        header Content-Type "text/plain; charset=utf-8"
    }

    handle /vless-argo* {
        reverse_proxy 127.0.0.1:$ARGO_PORT
    }

    handle /vmess-argo* {
        reverse_proxy 127.0.0.1:$ARGO_PORT
    }

    handle {
        respond "404 Not Found" 404
    }
}
EOF

    /usr/bin/caddy validate --config /etc/caddy/Caddyfile > /dev/null 2>&1
    chown caddy:caddy /var/log/caddy/caddy.log > /dev/null 2>&1
    chmod 644 /var/log/caddy/caddy.log > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        if [ -f /etc/alpine-release ]; then
            rc-service caddy restart
        else
            systemctl daemon-reload
            systemctl restart caddy
        fi
    else
        [ -f /etc/alpine-release ] && rc-service caddy restart > /dev/null 2>&1 || red "Caddy 配置文件验证失败，订阅功能可能无法使用，但不影响节点使用\nissues 反馈：https://github.com/eooce/xray-argo/issues\n"
    fi
}

# ==========================================
# 导出代理为 txt 功能
# ==========================================
export_proxy_txt() {
    local mode="${1:-manual}"
    load_ports

    if [ ! -f "${work_dir}/url.txt" ]; then
        red "节点文件不存在，请先安装 Xray-2go"
        return 1
    fi

    local IP=$(get_realip)
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local export_file="${export_dir}/xray2go_proxy_${timestamp}.txt"
    local export_file_latest="${export_dir}/xray2go_proxy_latest.txt"

    # 读取 argo 域名
    local argodomain=""
    if [ -f "${work_dir}/argo.log" ]; then
        argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
    fi

    # 读取订阅链接信息
    local sub_port="$PORT"
    local sub_path="$password"
    if [ -f /etc/caddy/Caddyfile ]; then
        sub_port=$(grep -oP ':\K[0-9]+' /etc/caddy/Caddyfile 2>/dev/null | head -1)
        sub_path=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' /etc/caddy/Caddyfile 2>/dev/null)
    fi

    cat > "$export_file" << EXPORTEOF
============================================
  Xray-2go 代理节点信息
  导出时间: $(date '+%Y-%m-%d %H:%M:%S')
  服务器IP: ${IP}
============================================

【端口信息】
  订阅端口:  ${sub_port}
  Argo端口:  ${ARGO_PORT}
  GRPC端口:  ${GRPC_PORT}
  XHTTP端口: ${XHTTP_PORT}
  Vision端口:${VISION_PORT}
  SS端口:    ${SS_PORT}
  HY2端口:   ${HY2_PORT}/udp

【UUID】
  ${UUID}

【Argo 域名】
  ${argodomain:-未获取到}

============================================
  节点链接（可直接导入客户端）
============================================

--- VLESS GRPC Reality ---
$(sed -n '1p' "${work_dir}/url.txt")

--- VLESS XHTTP Reality ---
$(sed -n '3p' "${work_dir}/url.txt")

--- VLESS Vision Reality ---
$(sed -n '5p' "${work_dir}/url.txt")

--- Shadowsocks 2022 ---
$(sed -n '7p' "${work_dir}/url.txt")

--- Hysteria2 ---
$(sed -n '9p' "${work_dir}/url.txt")

--- VLESS WS (Argo) ---
$(sed -n '11p' "${work_dir}/url.txt")

--- VMess WS (Argo) ---
$(sed -n '13p' "${work_dir}/url.txt")

============================================
  订阅链接
============================================

http://${IP}:${sub_port}/${sub_path}

============================================
  使用说明
============================================

1. Reality 节点 (GRPC/XHTTP):
   - 直连服务器 IP，无需域名
   - 适合 IP 未被墙的情况

2. Argo 节点 (VLESS-WS/VMess-WS):
   - 通过 Cloudflare CDN 中转
   - 适合 IP 被墙的情况
   - 临时隧道域名每次重启会变化

3. 订阅链接:
   - 可导入 V2rayN, NekoBox, Karing,
     Shadowrocket, Quantumult X, Loon 等
   - 更新订阅即可获取最新节点

4. 客户端推荐:
   - iOS: Shadowrocket / Quantumult X / Loon
   - Android: V2rayNG / NekoBox / Karing
   - Windows: V2rayN / Clash Verge
   - macOS: V2rayU / ClashX Pro

============================================
EXPORTEOF

    cp "$export_file" "$export_file_latest"

    # 纯链接版本
    local links_file="${export_dir}/xray2go_links_${timestamp}.txt"
    local links_file_latest="${export_dir}/xray2go_links_latest.txt"

    grep -v '^$' "${work_dir}/url.txt" > "$links_file"
    echo "" >> "$links_file"
    echo "# 订阅链接" >> "$links_file"
    argo_domain=$(get_current_argo_domain)
    echo "$(build_subscription_url "$IP" "$sub_port" "$sub_path" "$argo_domain")" >> "$links_file"

    cp "$links_file" "$links_file_latest"

    if [ "$mode" = "auto" ]; then
        green "\n代理信息已自动导出到当前目录："
    else
        green "\n代理信息已导出："
    fi
    green "  详细版: ${export_file}"
    green "  详细版(latest): ${export_file_latest}"
    green "  纯链接: ${links_file}"
    green "  纯链接(latest): ${links_file_latest}\n"
}

# 导出菜单
export_menu() {
    check_xray &>/dev/null
    local xray_status=$?
    if [ $xray_status -ne 0 ] && [ ! -f "${work_dir}/url.txt" ]; then
        yellow "Xray-2go 尚未安装，无节点可导出"
        sleep 1
        return
    fi

    clear
    echo ""
    green "1. 导出到当前目录 (详细版 + 纯链接版)"
    skyblue "--------------------------------------"
    green "2. 导出到自定义路径"
    skyblue "--------------------------------------"
    green "3. 在终端显示所有节点链接"
    skyblue "--------------------------------------"
    green "4. 复制订阅链接到剪贴板"
    skyblue "--------------------------------------"
    purple "5. 返回主菜单"
    skyblue "--------------------------------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            export_proxy_txt "manual"
            ;;
        2)
            reading "请输入导出路径 (如 /tmp): " custom_path
            if [ -z "$custom_path" ]; then
                custom_path="$export_dir"
            fi
            if [ ! -d "$custom_path" ]; then
                mkdir -p "$custom_path" 2>/dev/null
                if [ $? -ne 0 ]; then
                    red "路径创建失败: $custom_path"
                    return
                fi
            fi
            local old_export_dir="$export_dir"
            export_dir="$custom_path"
            export_proxy_txt "manual"
            export_dir="$old_export_dir"
            ;;
        3)
            load_ports
            echo ""
            green "========== 所有节点链接 =========="
            echo ""
            while IFS= read -r line; do
                [ -n "$line" ] && echo -e "${purple}$line${re}"
            done < ${work_dir}/url.txt

            local server_ip=$(get_realip)
            local s_port=$(grep -oP ':\K[0-9]+' /etc/caddy/Caddyfile 2>/dev/null | head -1)
            local s_path=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' /etc/caddy/Caddyfile 2>/dev/null)
            echo ""
            green "========== 订阅链接 =========="
            argo_domain=$(get_current_argo_domain)
            green "$(build_subscription_url "$server_ip" "$s_port" "$s_path" "$argo_domain")"
            echo ""
            green "================================"
            ;;
        4)
            load_ports
            local server_ip=$(get_realip)
            local s_port=$(grep -oP ':\K[0-9]+' /etc/caddy/Caddyfile 2>/dev/null | head -1)
            local s_path=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' /etc/caddy/Caddyfile 2>/dev/null)
            local argo_domain=$(get_current_argo_domain)
            local sub_link=$(build_subscription_url "$server_ip" "$s_port" "$s_path" "$argo_domain")
            # Linux 环境尝试多种剪贴板工具
            if command -v xclip &>/dev/null; then
                echo -n "$sub_link" | xclip -selection clipboard
                green "\n订阅链接已复制到剪贴板：$sub_link\n"
            elif command -v xsel &>/dev/null; then
                echo -n "$sub_link" | xsel --clipboard --input
                green "\n订阅链接已复制到剪贴板：$sub_link\n"
            else
                yellow "\n未找到剪贴板工具，请手动复制以下链接：\n"
                green "$sub_link\n"
            fi
            ;;
        5) return ;;
        *) red "无效的选项！" ;;
    esac
}

# 启动 xray
start_xray() {
if [ ${check_xray} -eq 1 ]; then
    yellow "\n正在启动 ${server_name} 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service xray start
    else
        systemctl daemon-reload
        systemctl start "${server_name}"
    fi
   if [ $? -eq 0 ]; then
       green "${server_name} 服务已成功启动\n"
   else
       red "${server_name} 服务启动失败\n"
   fi
elif [ ${check_xray} -eq 0 ]; then
    yellow "xray 正在运行\n"
    sleep 1
    menu
else
    yellow "xray 尚未安装!\n"
    sleep 1
    menu
fi
}

# 停止 xray
stop_xray() {
if [ ${check_xray} -eq 0 ]; then
   yellow "\n正在停止 ${server_name} 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service xray stop
    else
        systemctl stop "${server_name}"
    fi
   if [ $? -eq 0 ]; then
       green "${server_name} 服务已成功停止\n"
   else
       red "${server_name} 服务停止失败\n"
   fi

elif [ ${check_xray} -eq 1 ]; then
    yellow "xray 未运行\n"
    sleep 1
    menu
else
    yellow "xray 尚未安装！\n"
    sleep 1
    menu
fi
}

# 重启 xray
restart_xray() {
if [ ${check_xray} -eq 0 ]; then
   yellow "\n正在重启 ${server_name} 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service ${server_name} restart
    else
        systemctl daemon-reload
        systemctl restart "${server_name}"
    fi
    if [ $? -eq 0 ]; then
        green "${server_name} 服务已成功重启\n"
    else
        red "${server_name} 服务重启失败\n"
    fi
elif [ ${check_xray} -eq 1 ]; then
    yellow "xray 未运行\n"
    sleep 1
    menu
else
    yellow "xray 尚未安装！\n"
    sleep 1
    menu
fi
}

# 启动 argo
start_argo() {
if [ ${check_argo} -eq 1 ]; then
    yellow "\n正在启动 Argo 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service tunnel start
    else
        systemctl daemon-reload
        systemctl start tunnel
    fi
    if [ $? -eq 0 ]; then
        green "Argo 服务已成功启动\n"
    else
        red "Argo 服务启动失败\n"
    fi
elif [ ${check_argo} -eq 0 ]; then
    green "Argo 服务正在运行\n"
    sleep 1
    menu
else
    yellow "Argo 尚未安装！\n"
    sleep 1
    menu
fi
}

# 停止 argo
stop_argo() {
if [ ${check_argo} -eq 0 ]; then
    yellow "\n正在停止 Argo 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service tunnel stop
    else
        systemctl daemon-reload
        systemctl stop tunnel
    fi
    if [ $? -eq 0 ]; then
        green "Argo 服务已成功停止\n"
    else
        red "Argo 服务停止失败\n"
    fi
elif [ ${check_argo} -eq 1 ]; then
    yellow "Argo 服务未运行\n"
    sleep 1
    menu
else
    yellow "Argo 尚未安装！\n"
    sleep 1
    menu
fi
}

# 重启 argo
restart_argo() {
if [ ${check_argo} -eq 0 ]; then
    yellow "\n正在重启 Argo 服务\n"
    rm /etc/xray/argo.log 2>/dev/null
    if [ -f /etc/alpine-release ]; then
        rc-service tunnel restart
    else
        systemctl daemon-reload
        systemctl restart tunnel
    fi
    if [ $? -eq 0 ]; then
        green "Argo 服务已成功重启\n"
    else
        red "Argo 服务重启失败\n"
    fi
elif [ ${check_argo} -eq 1 ]; then
    yellow "Argo 服务未运行\n"
    sleep 1
    menu
else
    yellow "Argo 尚未安装！\n"
    sleep 1
    menu
fi
}

# 启动 caddy
start_caddy() {
if command -v caddy &>/dev/null; then
    yellow "\n正在启动 caddy 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service caddy start
    else
        systemctl daemon-reload
        systemctl start caddy
    fi
    if [ $? -eq 0 ]; then
        green "caddy 服务已成功启动\n"
    else
        red "caddy 启动失败\n"
    fi
else
    yellow "caddy 尚未安装！\n"
    sleep 1
    menu
fi
}

# 重启 caddy
restart_caddy() {
if command -v caddy &>/dev/null; then
    yellow "\n正在重启 caddy 服务\n"
    if [ -f /etc/alpine-release ]; then
        rc-service caddy restart
    else
        systemctl restart caddy
    fi
    if [ $? -eq 0 ]; then
        green "caddy 服务已成功重启\n"
    else
        red "caddy 重启失败\n"
    fi
else
    yellow "caddy 尚未安装！\n"
    sleep 1
    menu
fi
}

# 卸载 xray
uninstall_xray() {
   reading "确定要卸载 xray-2go 吗? (y/n): " choice
   case "${choice}" in
       y|Y)
           yellow "正在卸载 xray"
           if [ -f /etc/alpine-release ]; then
                rc-service xray stop
                rc-service tunnel stop
                rm /etc/init.d/xray /etc/init.d/tunnel
                rc-update del xray default
                rc-update del tunnel default
           else
                systemctl stop "${server_name}"
                systemctl stop tunnel
                systemctl disable "${server_name}"
                systemctl disable tunnel
                systemctl daemon-reload || true
            fi
           rm -rf "${work_dir}" || true
           rm -rf /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service 2>/dev/null

           reading "\n是否卸载 caddy？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载caddy) (y/n): ${re}" choice
            case "${choice}" in
                y|Y)
                    manage_packages uninstall caddy
                    ;;
                 *)
                    yellow "取消卸载caddy\n"
                    ;;
            esac

            green "\nXray_2go 卸载成功\n"
           ;;
       *)
           purple "已取消卸载操作\n"
           ;;
   esac
}

# 创建快捷指令
create_shortcut() {
  cat > "$work_dir/2go.sh" << EOF
#!/usr/bin/env bash

bash <(curl -Ls https://github.com/eooce/xray-2go/raw/main/xray_2go.sh) \$1
EOF
  chmod +x "$work_dir/2go.sh"
  ln -sf "$work_dir/2go.sh" /usr/bin/2go
  if [ -s /usr/bin/2go ]; then
    green "\n快捷指令 2go 创建成功\n"
  else
    red "\n快捷指令创建失败\n"
  fi
}

# 适配alpine运行argo报错用户组和dns的问题
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 变更配置
change_config() {
load_ports
clear
echo ""
green "1. 修改UUID"
skyblue "------------"
green "2. 修改grpc-reality端口"
skyblue "------------"
green "3. 修改xhttp-reality端口"
skyblue "------------"
green "4. 修改reality节点伪装域名"
skyblue "------------"
purple "${purple}0. 返回主菜单"
skyblue "------------"
reading "请输入选择: " choice
case "${choice}" in
    1)
        reading "\n请输入新的UUID: " new_uuid
        [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid) && green "\n生成的UUID为：$new_uuid"
        sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" $config_dir
        restart_xray
        sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" $client_dir
        # 更新 ports.env 中的 UUID
        sed -i "s/^UUID=.*/UUID=$new_uuid/" "${work_dir}/ports.env"
        content=$(cat "$client_dir")
        vmess_urls=$(grep -o 'vmess://[^ ]*' "$client_dir")
        vmess_prefix="vmess://"
        for vmess_url in $vmess_urls; do
            encoded_vmess="${vmess_url#"$vmess_prefix"}"
            decoded_vmess=$(echo "$encoded_vmess" | base64 --decode)
            updated_vmess=$(echo "$decoded_vmess" | jq --arg new_uuid "$new_uuid" '.id = $new_uuid')
            encoded_updated_vmess=$(echo "$updated_vmess" | base64 | tr -d '\n')
            new_vmess_url="$vmess_prefix$encoded_updated_vmess"
            content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
        done
        echo "$content" > "$client_dir"
        base64 -w0 $client_dir > /etc/xray/sub.txt
        while IFS= read -r line; do yellow "$line"; done < $client_dir
        green "\nUUID已修改为：${purple}${new_uuid}${re} ${green}请更新订阅或手动更改所有节点的UUID${re}\n"
        ;;
    2)
        reading "\n请输入grpc-reality端口 (回车跳过将自动分配): " new_port
        [ -z "$new_port" ] && new_port=$(find_available_port 2000 65000)
        until [[ -z $(lsof -iTCP:$new_port -sTCP:LISTEN 2>/dev/null) ]]; do
            if [[ -n $(lsof -iTCP:$new_port -sTCP:LISTEN 2>/dev/null) ]]; then
                echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                reading "请输入新的端口(1-65535):" new_port
                [[ -z $new_port ]] && new_port=$(find_available_port 2000 65000)
            fi
        done
        sed -i "41s/\"port\":\s*[0-9]\+/\"port\": $new_port/" /etc/xray/config.json
        sed -i "s/^GRPC_PORT=.*/GRPC_PORT=$new_port/" "${work_dir}/ports.env"
        restart_xray
        sed -i '1s/\(vless:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
        base64 -w0 $client_dir > /etc/xray/sub.txt
        while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
        green "\nGRPC-reality端口已修改成：${purple}$new_port${re} ${green}请更新订阅或手动更改grpc-reality节点端口${re}\n"
        ;;
    3)
        reading "\n请输入xhttp-reality端口 (回车跳过将自动分配): " new_port
        [ -z "$new_port" ] && new_port=$(find_available_port 2000 65000)
        until [[ -z $(lsof -iTCP:$new_port -sTCP:LISTEN 2>/dev/null) ]]; do
            if [[ -n $(lsof -iTCP:$new_port -sTCP:LISTEN 2>/dev/null) ]]; then
                echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                reading "请输入新的端口(1-65535):" new_port
                [[ -z $new_port ]] && new_port=$(find_available_port 2000 65000)
            fi
        done
        sed -i "35s/\"port\":\s*[0-9]\+/\"port\": $new_port/" /etc/xray/config.json
        sed -i "s/^XHTTP_PORT=.*/XHTTP_PORT=$new_port/" "${work_dir}/ports.env"
        restart_xray
        sed -i '3s/\(vless:\/\/[^@]*@[^:]*:\)[0-9]\{1,\}/\1'"$new_port"'/' $client_dir
        base64 -w0 $client_dir > /etc/xray/sub.txt
        while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
        green "\nxhttp-reality端口已修改成：${purple}$new_port${re} ${green}请更新订阅或手动更改xhttp-reality节点端口${re}\n"
        ;;
    4)
        clear
        green "\n1. bgk.jp\n\n2. www.joom.com\n\n3. www.stengg.com\n\n4. www.nazhumi.com\n"
        reading "\n请输入新的Reality伪装域名(可自定义输入,回车留空将使用默认1): " new_sni
            if [ -z "$new_sni" ]; then
                new_sni="bgk.jp"
            elif [[ "$new_sni" == "1" ]]; then
                new_sni="bgk.jp"
            elif [[ "$new_sni" == "2" ]]; then
                new_sni="www.iij.ad.jp"
            elif [[ "$new_sni" == "3" ]]; then
                new_sni="www.stengg.com"
            elif [[ "$new_sni" == "4" ]]; then
                new_sni="www.nazhumi.com"
            else
                new_sni="$new_sni"
            fi
            jq --arg new_sni "$new_sni" '.inbounds[5].streamSettings.realitySettings.dest = ($new_sni + ":443") | .inbounds[5].streamSettings.realitySettings.serverNames = [$new_sni]' /etc/xray/config.json > /etc/xray/config.json.tmp && mv /etc/xray/config.json.tmp /etc/xray/config.json
            restart_xray
            sed -i "1s/\(vless:\/\/[^\?]*\?\([^\&]*\&\)*sni=\)[^&]*/\1$new_sni/" $client_dir
            sed -i "1s/\(vless:\/\/[^\?]*\?\([^\&]*\&\)*authority=\)[^&]*/\1$new_sni/" $client_dir
            base64 -w0 $client_dir > /etc/xray/sub.txt
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            echo ""
            green "\nReality sni已修改为：${purple}${new_sni}${re} ${green}请更新订阅或手动更改reality节点的sni域名${re}\n"
        ;;
    0)  menu ;;
    *)  red "无效的选项！" ;;
esac
}

disable_open_sub() {
if [ ${check_xray} -eq 0 ]; then
    clear
    echo ""
    green "1. 关闭节点订阅"
    skyblue "------------"
    green "2. 开启节点订阅"
    skyblue "------------"
    green "3. 更换订阅端口"
    skyblue "------------"
    purple "4. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            if command -v caddy &>/dev/null; then
                if [ -f /etc/alpine-release ]; then
                    rc-service caddy status | grep -q "started" && rc-service caddy stop || red "caddy not running"
                else
                    [ "$(systemctl is-active caddy)" = "active" ] && systemctl stop caddy || red "caddy not running"
                fi
            else
                yellow "caddy is not installed"
            fi

            green "\n已关闭节点订阅\n"
            ;;
        2)
            green "\n已开启节点订阅\n"
            server_ip=$(get_realip)
            password=$(tr -dc A-Za-z < /dev/urandom | head -c 32)
            sed -i "s/\/[a-zA-Z0-9]\+/\/$password/g" /etc/caddy/Caddyfile
            sub_port=$(port=$(grep -oP ':\K[0-9]+' /etc/caddy/Caddyfile); if [ "$port" -eq 80 ]; then echo ""; else echo "$port"; fi)
            start_caddy
            (port=$(grep -oP ':\K[0-9]+' /etc/caddy/Caddyfile); if [ "$port" -eq 80 ]; then echo ""; else green "订阅端口：$port"; fi); link=$(if [ -z "$sub_port" ]; then echo "http://$server_ip/$password"; else echo "http://$server_ip:$sub_port/$password"; fi); green "\n新的节点订阅链接：$link\n"
            ;;

        3)
            reading "请输入新的订阅端口(1-65535):" sub_port
            [ -z "$sub_port" ] && sub_port=$(find_available_port 2000 65000)
            until [[ -z $(lsof -iTCP:$sub_port -sTCP:LISTEN 2>/dev/null) ]]; do
                if [[ -n $(lsof -iTCP:$sub_port -sTCP:LISTEN 2>/dev/null) ]]; then
                    echo -e "${red}${sub_port}端口已经被其他程序占用，请更换端口重试${re}"
                    reading "请输入新的订阅端口(1-65535):" sub_port
                    [[ -z $sub_port ]] && sub_port=$(find_available_port 2000 65000)
                fi
            done
            sed -i "s/:[0-9]\+/:$sub_port/g" /etc/caddy/Caddyfile
            # 更新 ports.env
            sed -i "s/^PORT=.*/PORT=$sub_port/" "${work_dir}/ports.env"
            path=$(sed -n 's/.*handle \/\([^ ]*\).*/\1/p' /etc/caddy/Caddyfile)
            server_ip=$(get_realip)
            restart_caddy
            green "\n订阅端口更换成功\n"
            green "新的订阅链接为：http://$server_ip:$sub_port/$path\n"
            ;;
        4)  menu ;;
        *)  red "无效的选项！" ;;
    esac
else
    yellow "xray—2go 尚未安装！"
    sleep 1
    menu
fi
}

# xray 管理
manage_xray() {
    green "1. 启动xray服务"
    skyblue "-------------------"
    green "2. 停止xray服务"
    skyblue "-------------------"
    green "3. 重启xray服务"
    skyblue "-------------------"
    purple "4. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_xray ;;
        2) stop_xray ;;
        3) restart_xray ;;
        4) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# Argo 管理
manage_argo() {
if [ ${check_argo} -eq 2 ]; then
    yellow "Argo 尚未安装！"
    sleep 1
    menu
else
    load_ports
    clear
    echo ""
    green "1. 启动Argo服务"
    skyblue "------------"
    green "2. 停止Argo服务"
    skyblue "------------"
    green "3. 添加Argo固定隧道"
    skyblue "----------------"
    green "4. 切换回Argo临时隧道"
    skyblue "------------------"
    green "5. 重新获取Argo临时域名"
    skyblue "-------------------"
    purple "6. 返回主菜单"
    skyblue "-----------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1)  start_argo ;;
        2)  stop_argo ;;
        3)
            clear
            yellow "\n固定隧道可为json或token，固定隧道端口为${ARGO_PORT}，自行在cf后台设置\n\njson在f佬维护的站点里获取，获取地址：${purple}https://fscarmen.cloudflare.now.cc${re}\n"
            reading "\n请输入你的argo域名: " argo_domain
            green "你的Argo域名为：$argo_domain"
            ArgoDomain=$argo_domain
            reading "\n请输入你的argo密钥(token或json): " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                echo $argo_auth > ${work_dir}/tunnel.json
                cat > ${work_dir}/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ArgoDomain
    service: http://localhost:${PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                if [ -f /etc/alpine-release ]; then
                    sed -i '/^command_args=/c\command_args="-c '\''/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run 2>&1'\''"' /etc/init.d/tunnel
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run 2>&1"' /etc/systemd/system/tunnel.service
                fi
                restart_argo
                change_argo_domain
            elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                if [ -f /etc/alpine-release ]; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth 2>&1'\"" /etc/init.d/tunnel
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '$argo_auth' 2>&1"' /etc/systemd/system/tunnel.service
                fi
                restart_argo
                change_argo_domain
            else
                yellow "你输入的argo域名或token不匹配，请重新输入"
                manage_argo
            fi
            ;;
        4)
            clear
            if [ -f /etc/alpine-release ]; then
                alpine_openrc_services
            else
                main_systemd_services
            fi
            get_quick_tunnel
            change_argo_domain
            ;;

        5)
            if [ -f /etc/alpine-release ]; then
                if grep -Fq -- "--url http://localhost:${PORT}" /etc/init.d/tunnel; then
                    get_quick_tunnel
                    change_argo_domain
                else
                    yellow "当前使用固定隧道，无法获取临时隧道"
                    sleep 2
                    menu
                fi
            else
                if grep -q "ExecStart=.*--url http://localhost:${PORT}" /etc/systemd/system/tunnel.service; then
                    get_quick_tunnel
                    change_argo_domain
                else
                    yellow "当前使用固定隧道，无法获取临时隧道"
                    sleep 2
                    menu
                fi
            fi
            ;;
        6)  menu ;;
        *)  red "无效的选项！" ;;
    esac
fi
}

# 获取argo临时隧道
get_quick_tunnel() {
restart_argo
yellow "获取临时argo域名中，请稍等...\n"
sleep 3
if [ -f /etc/xray/argo.log ]; then
  for i in {1..8}; do
      get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' /etc/xray/argo.log | tail -1)
      [ -n "$get_argodomain" ] && break
      sleep 2
  done
else
  restart_argo
  sleep 6
  for i in {1..5}; do
      get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' /etc/xray/argo.log | tail -1)
      [ -n "$get_argodomain" ] && break
      sleep 2
  done
fi
if [ -n "$get_argodomain" ]; then
    green "ArgoDomain：${purple}$get_argodomain${re}\n"
else
    red "获取 Argo 域名失败，请检查网络后重试\n"
fi
ArgoDomain=$get_argodomain
}

# 更新Argo域名到订阅
change_argo_domain() {
    if [ -z "$ArgoDomain" ]; then
        red "Argo 域名为空，无法更新"
        return
    fi
    sed -i "5s/sni=[^&]*/sni=$ArgoDomain/; 5s/host=[^&]*/host=$ArgoDomain/" /etc/xray/url.txt
    content=$(cat "$client_dir")
    vmess_urls=$(grep -o 'vmess://[^ ]*' "$client_dir")
    vmess_prefix="vmess://"
    for vmess_url in $vmess_urls; do
        encoded_vmess="${vmess_url#"$vmess_prefix"}"
        decoded_vmess=$(echo "$encoded_vmess" | base64 --decode)
        updated_vmess=$(echo "$decoded_vmess" | jq --arg new_domain "$ArgoDomain" '.host = $new_domain | .sni = $new_domain')
        encoded_updated_vmess=$(echo "$updated_vmess" | base64 | tr -d '\n')
        new_vmess_url="$vmess_prefix$encoded_updated_vmess"
        content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
    done
    echo "$content" > "$client_dir"
    base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt

    while IFS= read -r line; do echo -e "${purple}$line"; done < "$client_dir"

    green "\n节点已更新,更新订阅或手动复制以上节点\n"
}

# 查看节点信息和订阅链接
check_nodes() {
if [ ${check_xray} -eq 0 ]; then
    load_ports
    while IFS= read -r line; do purple "${purple}$line"; done < ${work_dir}/url.txt
    server_ip=$(get_realip)
    sub_port=$(grep -oP ':\K[0-9]+' /etc/caddy/Caddyfile 2>/dev/null | head -1)
    lujing=$(sed -n 's/.*handle \/\([a-zA-Z0-9]\+\).*/\1/p' /etc/caddy/Caddyfile 2>/dev/null)
    if [ -n "$sub_port" ] && [ -n "$lujing" ]; then
        argo_domain=$(get_current_argo_domain)
        sub_link=$(build_subscription_url "$server_ip" "$sub_port" "$lujing" "$argo_domain")
        green "\n\n节点订阅链接：$sub_link\n"
    else
        yellow "\n\n订阅信息获取失败，请检查 Caddy 配置\n"
    fi
else
    yellow "Xray-2go 尚未安装或未运行,请先安装或启动Xray-2go"
    sleep 1
    menu
fi
}

# 捕获 Ctrl+C 信号
trap 'red "已取消操作"; exit' INT

install_xray2go_all() {
    check_xray &>/dev/null; local xray_state=$?
    optimize_bbr || true
    if [ ${xray_state} -eq 0 ]; then
        yellow "Xray-2go 已经安装！"
        xray2go_upload_links_latest_to_postgres || true
        return 0
    fi

    install_caddy
    manage_packages install jq unzip iptables openssl coreutils lsof
    install_xray
    setup_cloudflare_fixed_tunnel || yellow "固定 Tunnel 配置失败，回退到临时 Argo Tunnel"
    apply_nat_argo_policy

    if [ -x "$(command -v systemctl)" ]; then
        main_systemd_services
    elif [ -x "$(command -v rc-update)" ]; then
        alpine_openrc_services
        change_hosts
        rc-service xray restart
        rc-service tunnel restart
    else
        echo "Unsupported init system"
        exit 1
    fi

    sleep 3
    get_info
    add_caddy_conf
    create_shortcut
}

# 主菜单
menu() {
while true; do
   check_xray &>/dev/null; check_xray=$?
   check_caddy &>/dev/null; check_caddy=$?
   check_argo &>/dev/null; check_argo=$?
   check_xray_status=$(check_xray) > /dev/null 2>&1
   check_caddy_status=$(check_caddy) > /dev/null 2>&1
   check_argo_status=$(check_argo) > /dev/null 2>&1
   clear
   echo ""
   purple "=== 老王Xray-2go一键安装脚本 (增强版) ===\n"
   purple " Xray 状态: ${check_xray_status}\n"
   purple " Argo 状态: ${check_argo_status}\n"
   purple "Caddy 状态: ${check_caddy_status}\n"
   green  "1. 安装Xray-2go"
   red    "2. 卸载Xray-2go"
   echo   "==============="
   green  "3. Xray-2go管理"
   green  "4. Argo隧道管理"
   echo   "==============="
   green  "5. 查看节点信息"
   green  "6. 修改节点配置"
   green  "7. 管理节点订阅"
   echo   "==============="
   skyblue "8. 导出代理为txt"
   echo   "==============="
   purple "9. ssh综合工具箱"
   purple "10. 安装singbox四合一"
   skyblue "11. 上传 xray2go_links_latest.txt 到 PostgreSQL"
   skyblue "12. 启用/检查 BBR + fq 优化"
   echo   "==============="
   red    "0. 退出脚本"
   echo   "==========="
   reading "请输入选择(0-12): " choice
   echo ""
   case "${choice}" in
        1) install_xray2go_all ;;
        2) uninstall_xray ;;
        3) manage_xray ;;
        4) manage_argo ;;
        5) check_nodes ;;
        6) change_config ;;
        7) disable_open_sub ;;
        8) export_menu ;;
        9) clear && curl -fsSL https://raw.githubusercontent.com/eooce/ssh_tool/main/ssh_tool.sh -o ssh_tool.sh && chmod +x ssh_tool.sh && ./ssh_tool.sh ;;
        10) clear && bash <(curl -Ls https://raw.githubusercontent.com/eooce/sing-box/main/sing-box.sh) ;;
        11) xray2go_upload_links_latest_to_postgres ;;
        12) optimize_bbr ;;
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 12" ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
done
}
case "${1:-menu}" in
    install) install_xray2go_all ;;
    bbr|optimize-bbr) optimize_bbr ;;
    upload-db|upload-links) xray2go_upload_links_latest_to_postgres ;;
    menu|*) menu ;;
esac
