#!/bin/bash

# ===========================================
# Xray-2go macOS 适配版 (root 环境，无 Homebrew)
# 所有依赖直接下载二进制，不依赖 brew
# 自动选择可用端口，支持导出代理为 txt
# ===========================================

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# 定义颜色
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\033[1;91m$1\033[0m"; }
green() { echo -e "\033[1;32m$1\033[0m"; }
yellow() { echo -e "\033[1;33m$1\033[0m"; }
purple() { echo -e "\033[1;35m$1\033[0m"; }
skyblue() { echo -e "\033[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

# 定义常量
server_name="xray"
work_dir="$HOME/.xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
launchd_dir="$HOME/Library/LaunchAgents"
export_dir="$(pwd)"

# 自动查找可用端口
find_available_port() {
    local start_port=${1:-1000}
    local end_port=${2:-60000}
    local port
    for i in $(seq 1 50); do
        port=$(jot -r 1 "$start_port" "$end_port")
        if ! lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null; then
            echo "$port"
            return 0
        fi
    done
    red "无法找到可用端口"
    exit 1
}

# 自动查找连续可用端口（用于 ARGO_PORT / PORT / GRPC / XHTTP）
assign_ports() {
    yellow "正在自动分配可用端口..."
    export PORT=$(find_available_port 1000 60000)
    export ARGO_PORT=$(find_available_port 8000 9000)
    # 确保 ARGO_PORT 与 PORT 不同
    while [ "$ARGO_PORT" = "$PORT" ]; do
        export ARGO_PORT=$(find_available_port 8000 9000)
    done
    export GRPC_PORT=$(find_available_port 10000 30000)
    while [ "$GRPC_PORT" = "$PORT" ] || [ "$GRPC_PORT" = "$ARGO_PORT" ]; do
        export GRPC_PORT=$(find_available_port 10000 30000)
    done
    export XHTTP_PORT=$(find_available_port 30001 50000)
    while [ "$XHTTP_PORT" = "$PORT" ] || [ "$XHTTP_PORT" = "$ARGO_PORT" ] || [ "$XHTTP_PORT" = "$GRPC_PORT" ]; do
        export XHTTP_PORT=$(find_available_port 30001 50000)
    done
    green "端口分配完成："
    green "  订阅端口 (PORT):       $PORT"
    green "  Argo 端口 (ARGO_PORT): $ARGO_PORT"
    green "  GRPC 端口:             $GRPC_PORT"
    green "  XHTTP 端口:            $XHTTP_PORT"
}

# 定义环境变量
export UUID=${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

# 获取系统架构
get_arch() {
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; ARCH_ARG='64' ;;
        'arm64')  ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac
}

# 获取真实 IP - 多 API 兜底
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

# 检查 xray 是否已安装和运行
check_xray() {
    if [ -f "${work_dir}/${server_name}" ]; then
        if launchctl list 2>/dev/null | grep -q "com.xray.service"; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    else
        red "not installed"
        return 2
    fi
}

# 检查 argo 是否已安装和运行
check_argo() {
    if [ -f "${work_dir}/argo" ]; then
        if launchctl list 2>/dev/null | grep -q "com.cloudflare.tunnel"; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    else
        red "not installed"
        return 2
    fi
}

# 检查 caddy 是否已安装
check_caddy() {
    if command -v caddy &>/dev/null || [ -f /usr/local/bin/caddy ]; then
        if launchctl list 2>/dev/null | grep -q "com.caddy.service"; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    else
        red "not installed"
        return 2
    fi
}

# 安装依赖 - 直接下载二进制
manage_packages() {
    if [ $# -lt 2 ]; then
        red "未指定包名或操作"
        return 1
    fi

    action=$1
    shift

    get_arch

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            case "$package" in
                lsof|openssl|coreutils|iptables|unzip)
                    green "${package} macOS 自带或不需要，跳过"
                    continue
                    ;;
            esac

            if command -v "$package" &>/dev/null; then
                green "${package} already installed"
                continue
            fi

            yellow "正在安装 ${package}..."
            case "$package" in
                jq)
                    curl -sLo /usr/local/bin/jq "https://github.com/jqlang/jq/releases/latest/download/jq-macos-${ARCH}"
                    chmod +x /usr/local/bin/jq
                    xattr -d com.apple.quarantine /usr/local/bin/jq 2>/dev/null
                    if command -v jq &>/dev/null; then
                        green "jq 安装成功"
                    else
                        red "jq 安装失败"
                    fi
                    ;;
                qrencode)
                    cat > "${work_dir}/qrencode" << 'QREOF'
#!/bin/bash
echo ""
echo "========== 订阅二维码 =========="
echo "(macOS root 环境暂不支持终端二维码)"
echo "请复制以下链接到浏览器或手机扫码工具："
echo ""
echo "$1"
echo ""
echo "================================"
QREOF
                    chmod +x "${work_dir}/qrencode"
                    green "qrencode 替代脚本已创建"
                    ;;
                *)
                    yellow "${package} 跳过安装"
                    ;;
            esac

        elif [ "$action" == "uninstall" ]; then
            case "$package" in
                jq)
                    rm -f /usr/local/bin/jq
                    green "jq 已卸载"
                    ;;
                caddy)
                    rm -f /usr/local/bin/caddy
                    green "caddy 已卸载"
                    ;;
                *)
                    yellow "${package} 跳过卸载"
                    ;;
            esac
        fi
    done
    return 0
}

# 安装 caddy - 直接下载二进制
install_caddy() {
    if command -v caddy &>/dev/null; then
        green "caddy already installed"
        return
    fi
    yellow "正在下载安装 caddy..."
    get_arch

    CADDY_VERSION=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$CADDY_VERSION" ]; then
        CADDY_VERSION="2.9.1"
    fi

    curl -sLo /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_mac_${ARCH}.tar.gz"
    if [ $? -ne 0 ]; then
        red "caddy 下载失败"
        return 1
    fi

    [ ! -d /usr/local/bin ] && mkdir -p /usr/local/bin
    tar -xzf /tmp/caddy.tar.gz -C /tmp/ 2>/dev/null
    mv /tmp/caddy /usr/local/bin/caddy 2>/dev/null
    chmod +x /usr/local/bin/caddy
    xattr -d com.apple.quarantine /usr/local/bin/caddy 2>/dev/null
    rm -f /tmp/caddy.tar.gz /tmp/LICENSE /tmp/README.md

    if command -v caddy &>/dev/null; then
        green "caddy v${CADDY_VERSION} 安装成功"
    else
        red "caddy 安装失败"
    fi
}

# 下载并安装 xray, cloudflared
install_xray() {
    clear
    purple "正在安装 Xray-2go (macOS) 中，请稍等..."
    get_arch

    # 自动分配端口
    assign_ports

    # 创建工作目录
    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 755 "${work_dir}"
    [ ! -d "${launchd_dir}" ] && mkdir -p "${launchd_dir}"

    # 下载 xray (macOS 版本)
    yellow "下载 Xray..."
    curl -sLo "${work_dir}/${server_name}.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-macos-${ARCH_ARG}.zip"
    if [ $? -ne 0 ]; then
        red "Xray 下载失败"
        exit 1
    fi

    # 下载 cloudflared
    yellow "下载 cloudflared..."
    curl -sLo "/tmp/cloudflared.tgz" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${ARCH}.tgz"
    if [ $? -eq 0 ]; then
        tar -xzf /tmp/cloudflared.tgz -C "${work_dir}/" 2>/dev/null
        if [ -f "${work_dir}/cloudflared" ]; then
            mv "${work_dir}/cloudflared" "${work_dir}/argo"
        fi
        rm -f /tmp/cloudflared.tgz
    else
        yellow "尝试备用下载方式..."
        curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${ARCH}"
    fi

    # 解压 xray
    unzip -o "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1
    chmod +x "${work_dir}/${server_name}" "${work_dir}/argo" 2>/dev/null

    # 解除 macOS quarantine
    xattr -d com.apple.quarantine "${work_dir}/${server_name}" 2>/dev/null
    xattr -d com.apple.quarantine "${work_dir}/argo" 2>/dev/null

    rm -rf "${work_dir}/${server_name}.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"

    # 验证文件
    if [ ! -f "${work_dir}/${server_name}" ]; then
        red "Xray 二进制文件不存在，安装失败"
        exit 1
    fi
    if [ ! -f "${work_dir}/argo" ]; then
        red "cloudflared 二进制文件不存在，安装失败"
        exit 1
    fi

    green "Xray 和 cloudflared 下载完成"

    # 生成随机密码
    password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)

    # 生成 x25519 密钥对
    output=$("${work_dir}/xray" x25519 2>&1)
    private_key=$(echo "${output}" | grep -i "private" | awk '{print $NF}')
    public_key=$(echo "${output}" | grep -i "public" | awk '{print $NF}')

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        red "x25519 密钥生成失败，输出如下："
        echo "$output"
        exit 1
    fi

    green "密钥对生成成功"

    # 保存端口和密码信息到文件（供后续函数读取）
    cat > "${work_dir}/ports.env" << EOF
PORT=$PORT
ARGO_PORT=$ARGO_PORT
GRPC_PORT=$GRPC_PORT
XHTTP_PORT=$XHTTP_PORT
password=$password
private_key=$private_key
public_key=$public_key
UUID=$UUID
EOF

    # 生成配置文件
    cat > "${config_dir}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none",
        "fallbacks": [
          { "dest": 3001 }, { "path": "/vless-argo", "dest": 3002 },
          { "path": "/vmess-argo", "dest": 3003 }
        ]
      },
      "streamSettings": { "network": "tcp" }
    },
    {
      "port": 3001, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    {
      "port": 3002, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID", "level": 0 }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "port": 3003, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "listen":"::", "port": $XHTTP_PORT, "protocol": "vless",
      "settings": {"clients": [{"id": "$UUID"}], "decryption": "none"},
      "streamSettings": {"network": "xhttp", "security": "reality", "realitySettings": {"target": "www.nazhumi.com:443", "xver": 0, "serverNames":
      ["www.nazhumi.com"], "privateKey": "$private_key", "shortIds": [""]}},
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen":"::", "port":$GRPC_PORT, "protocol":"vless",
      "settings":{"clients":[{"id":"$UUID"}], "decryption":"none"},
      "streamSettings":{"network":"grpc", "security":"reality", "realitySettings":{"dest":"www.iij.ad.jp:443", "serverNames":["www.iij.ad.jp"],
      "privateKey":"$private_key", "shortIds":[""]}, "grpcSettings":{"serviceName":"grpc"}},
      "sniffing":{"enabled":true, "destOverride":["http","tls","quic"]}
    }
  ],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
    green "配置文件已生成"
}

# 加载保存的端口配置
load_ports() {
    if [ -f "${work_dir}/ports.env" ]; then
        source "${work_dir}/ports.env"
    fi
}

# macOS launchd 守护进程
macos_launchd_services() {
    load_ports
    cat > "${launchd_dir}/com.xray.service.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xray.service</string>
    <key>ProgramArguments</key>
    <array>
        <string>${work_dir}/xray</string>
        <string>run</string>
        <string>-c</string>
        <string>${config_dir}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${work_dir}/xray_error.log</string>
    <key>StandardOutPath</key>
    <string>${work_dir}/xray_out.log</string>
</dict>
</plist>
EOF

    cat > "${launchd_dir}/com.cloudflare.tunnel.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>${work_dir}/argo</string>
        <string>tunnel</string>
        <string>--url</string>
        <string>http://localhost:${ARGO_PORT}</string>
        <string>--no-autoupdate</string>
        <string>--edge-ip-version</string>
        <string>auto</string>
        <string>--protocol</string>
        <string>http2</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${work_dir}/argo.log</string>
    <key>StandardOutPath</key>
    <string>${work_dir}/argo.log</string>
</dict>
</plist>
EOF

    launchctl unload "${launchd_dir}/com.xray.service.plist" 2>/dev/null
    launchctl load -w "${launchd_dir}/com.xray.service.plist"
    launchctl unload "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null
    launchctl load -w "${launchd_dir}/com.cloudflare.tunnel.plist"
    green "launchd 服务已加载"
}

# Caddy launchd 服务
macos_caddy_launchd() {
    local caddy_path
    caddy_path=$(which caddy 2>/dev/null || echo "/usr/local/bin/caddy")

    cat > "${launchd_dir}/com.caddy.service.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.caddy.service</string>
    <key>ProgramArguments</key>
    <array>
        <string>${caddy_path}</string>
        <string>run</string>
        <string>--config</string>
        <string>${work_dir}/Caddyfile</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${work_dir}/caddy_error.log</string>
    <key>StandardOutPath</key>
    <string>${work_dir}/caddy_out.log</string>
</dict>
</plist>
EOF
}

get_info() {
    clear
    load_ports
    IP=$(get_realip)

    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "vps")

    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..10}; do
            purple "第 $i 次尝试获取 ArgoDomain 中..."
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            [ -n "$argodomain" ] && break
            sleep 3
        done
    else
        restart_argo
        sleep 8
        for i in {1..5}; do
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            [ -n "$argodomain" ] && break
            sleep 3
        done
    fi

    if [ -z "$argodomain" ]; then
        red "获取 Argo 临时域名失败，请稍后重试（菜单4 -> 5重新获取）"
        argodomain="获取失败请重试"
    fi

    green "\nArgoDomain：${purple}$argodomain${re}\n"

    cat > ${work_dir}/url.txt <<EOF
vless://${UUID}@${IP}:${GRPC_PORT}??encryption=none&security=reality&sni=www.iij.ad.jp&fp=chrome&pbk=${public_key}&allowInsecure=1&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#${isp}

vless://${UUID}@${IP}:${XHTTP_PORT}?encryption=none&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${public_key}&allowInsecure=1&type=xhttp&mode=auto#${isp}

vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}

vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"chrome\"}" | base64)

EOF
    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt

    base64 -i ${work_dir}/url.txt -o ${work_dir}/sub_tmp.txt
    tr -d '\n' < ${work_dir}/sub_tmp.txt > ${work_dir}/sub.txt
    rm -f ${work_dir}/sub_tmp.txt

    yellow "\n温馨提醒：如果是 NAT 机，reality 端口和订阅端口需使用可用端口范围内的端口\n"
    green "节点订阅链接：http://$IP:$PORT/$password\n\n订阅链接适用于 V2rayN, Nekbox, karing, Sterisand, Loon, 小火箭, 圈X 等\n"
    green "订阅二维码"
    ${work_dir}/qrencode "http://$IP:$PORT/$password"
    echo ""

    # 安装完成后自动导出一份到桌面
    export_proxy_txt "auto"
    xray2go_upload_links_latest_to_postgres || true
}

# caddy 订阅配置
add_caddy_conf() {
    load_ports
    cat > "${work_dir}/Caddyfile" << EOF
{
    auto_https off
    log {
        output file ${work_dir}/caddy.log {
            roll_size 10MB
            roll_keep 10
            roll_keep_for 720h
        }
    }
}

:$PORT {
    handle /$password {
        root * ${work_dir}
        try_files /sub.txt
        file_server browse
        header Content-Type "text/plain; charset=utf-8"
    }

    handle {
        respond "404 Not Found" 404
    }
}
EOF

    caddy validate --config "${work_dir}/Caddyfile" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        macos_caddy_launchd
        launchctl unload "${launchd_dir}/com.caddy.service.plist" 2>/dev/null
        launchctl load -w "${launchd_dir}/com.caddy.service.plist"
        green "Caddy 服务已启动"
    else
        red "Caddy 配置文件验证失败，订阅功能可能无法使用，但不影响节点使用"
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
    if [ -f "${work_dir}/Caddyfile" ]; then
        sub_port=$(sed -n 's/.*:\([0-9]*\).*/\1/p' "${work_dir}/Caddyfile" 2>/dev/null | head -1)
        sub_path=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' "${work_dir}/Caddyfile" 2>/dev/null)
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

--- VLESS WS (Argo) ---
$(sed -n '5p' "${work_dir}/url.txt")

--- VMess WS (Argo) ---
$(sed -n '7p' "${work_dir}/url.txt")

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

    # 同时生成一份 latest 版本（覆盖）
    cp "$export_file" "$export_file_latest"

    # 同时导出一份纯链接版本（方便复制）
    local links_file="${export_dir}/xray2go_links_${timestamp}.txt"
    local links_file_latest="${export_dir}/xray2go_links_latest.txt"

    grep -v '^$' "${work_dir}/url.txt" > "$links_file"
    echo "" >> "$links_file"
    echo "# 订阅链接" >> "$links_file"
    echo "http://${IP}:${sub_port}/${sub_path}" >> "$links_file"

    cp "$links_file" "$links_file_latest"

    if [ "$mode" = "auto" ]; then
        green "\n代理信息已自动导出到桌面："
    else
        green "\n代理信息已导出到桌面："
    fi
    green "  详细版: ${export_file}"
    green "  详细版(latest): ${export_file_latest}"
    green "  纯链接: ${links_file}"
    green "  纯链接(latest): ${links_file_latest}\n"
}

# ==========================================
# PostgreSQL 上传 xray2go_links_latest.txt (xray2go+)
# ==========================================
xray2go_postgres_enabled() {
    [[ -n "${DATABASE_URL:-}" || -n "${POSTGRES_HOST:-}" || -n "${POSTGRES_USER:-}" || -n "${POSTGRES_DB:-}" || -n "${PGHOST:-}" || -n "${PGUSER:-}" || -n "${PGDATABASE:-}" || -n "${PGSTATS_DSN:-}" ]]
}

xray2go_psql_exec() {
    local sql_file="$1"
    if ! command -v psql &>/dev/null; then
        yellow "psql 不可用，跳过 PostgreSQL 上传"
        return 1
    fi
    if [[ -n "${DATABASE_URL:-}" ]]; then
        PGPASSWORD="${POSTGRES_PASSWORD:-${PGPASSWORD:-}}" psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q -f "$sql_file"
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

    local links_file="${XRAY2GO_LINKS_FILE:-}"
    if [[ -z "$links_file" ]]; then
        for candidate in "${export_dir}/xray2go_links_latest.txt" "$(pwd)/xray2go_links_latest.txt" "${HOME}/xray2go_links_latest.txt" "${work_dir}/xray2go_links_latest.txt" "${work_dir}/url.txt"; do
            [[ -f "$candidate" ]] && { links_file="$candidate"; break; }
        done
    fi
    [[ -f "$links_file" ]] || { yellow "未找到 xray2go_links_latest.txt，跳过 PostgreSQL 上传"; return 0; }

    local IP argodomain tmp_sql
    IP=$(get_realip)
    argodomain=""
    [[ -f "${work_dir}/argo.log" ]] && argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
    tmp_sql=$(mktemp)

    XRAY2GO_WORK_DIR="${work_dir}" XRAY2GO_CONFIG_DIR="${config_dir}" XRAY2GO_LINKS_FILE="$links_file" XRAY2GO_PUBLIC_IP="$IP" XRAY2GO_ARGO_DOMAIN="$argodomain" XRAY2GO_CFIP="$CFIP" python3 - <<'PYEOF' > "$tmp_sql"
import hashlib, json, os, socket
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
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1); data[k.strip()] = v.strip()
    return data
def q(v): return "NULL" if v is None else "'" + str(v).replace("'", "''") + "'"
def qjson(v): return q(json.dumps(v, ensure_ascii=False, sort_keys=True)) + "::jsonb"
p = read_env(ports_env)
links, meta = {}, {"source_file": str(links_file), "platform": "macos"}
for i, line in enumerate([x.strip() for x in links_file.read_text(errors="ignore").splitlines() if x.strip() and not x.strip().startswith("#")], 1):
    if "=" in line and not line.startswith(("vless://", "vmess://", "ss://", "trojan://", "hysteria2://")):
        k, v = line.split("=", 1); k, v = k.strip(), v.strip()
        (links if "://" in v else meta)[k or f"link_{i}"] = v
    else:
        links[f"link_{i}"] = line
hostname = socket.gethostname()
public_ip = os.environ.get("XRAY2GO_PUBLIC_IP", "").strip().strip("[]")
public_ip_sql = "NULL" if not public_ip or public_ip == "127.0.0.1" else q(public_ip) + "::inet"
ports = {k: int(v) for k, v in p.items() if k.endswith("PORT") and str(v).isdigit()}
sub_url = f"http://{public_ip}:{p.get('PORT','')}/{p.get('password','')}" if public_ip and p.get("PORT") and p.get("password") else ""
try: config_json = json.loads(config_file.read_text()) if config_file.exists() else {}
except Exception: config_json = {"_raw": config_file.read_text(errors="ignore")[:200000]} if config_file.exists() else {}
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
    "script_version": "links_latest_macos",
}
if os.environ.get("XRAY2GO_DB_WRITE_ONLY", "").lower() in ("1", "true", "yes", "on"):
    print(f"SELECT public.xray2go_ingest_links({qjson(payload)});")
    raise SystemExit
print("""
CREATE TABLE IF NOT EXISTS public.xray_node_configs (
 node_id text PRIMARY KEY, hostname text NOT NULL DEFAULT '', public_ip inet, install_dir text NOT NULL DEFAULT '', cdn_host text NOT NULL DEFAULT '', argo_domain text NOT NULL DEFAULT '', sub_url text NOT NULL DEFAULT '', uuid text NOT NULL DEFAULT '', public_key text NOT NULL DEFAULT '', ports jsonb NOT NULL DEFAULT '{}'::jsonb, links jsonb NOT NULL DEFAULT '{}'::jsonb, config_json jsonb NOT NULL DEFAULT '{}'::jsonb, raw_ports_env jsonb NOT NULL DEFAULT '{}'::jsonb, script_version text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
""")
print(f"""
INSERT INTO public.xray_node_configs (node_id, hostname, public_ip, install_dir, cdn_host, argo_domain, sub_url, uuid, public_key, ports, links, config_json, raw_ports_env, script_version, created_at, updated_at)
VALUES ({q(node_id)}, {q(hostname)}, {public_ip_sql}, {q(str(work_dir))}, {q(meta.get('host') or os.environ.get('XRAY2GO_CFIP',''))}, {q(os.environ.get('XRAY2GO_ARGO_DOMAIN',''))}, {q(sub_url)}, {q(p.get('UUID',''))}, {q(p.get('public_key',''))}, {qjson(ports)}, {qjson(links)}, {qjson(config_json)}, {qjson({**p, **meta})}, 'links_latest_macos', now(), now())
ON CONFLICT (node_id) DO UPDATE SET hostname=EXCLUDED.hostname, public_ip=EXCLUDED.public_ip, install_dir=EXCLUDED.install_dir, cdn_host=EXCLUDED.cdn_host, argo_domain=EXCLUDED.argo_domain, sub_url=EXCLUDED.sub_url, uuid=EXCLUDED.uuid, public_key=EXCLUDED.public_key, ports=EXCLUDED.ports, links=EXCLUDED.links, config_json=EXCLUDED.config_json, raw_ports_env=EXCLUDED.raw_ports_env, script_version=EXCLUDED.script_version, updated_at=now();
""")
PYEOF
    if xray2go_psql_exec "$tmp_sql"; then
        green "xray2go_links_latest.txt 已上传到 PostgreSQL 表 public.xray_node_configs"
    else
        yellow "PostgreSQL 上传失败，安装流程继续"
    fi
    rm -f "$tmp_sql"
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
    green "1. 导出到桌面 (详细版 + 纯链接版)"
    skyblue "-----------------------------------"
    green "2. 导出到自定义路径"
    skyblue "-----------------------------------"
    green "3. 在终端显示所有节点链接"
    skyblue "-----------------------------------"
    green "4. 复制订阅链接到剪贴板"
    skyblue "-----------------------------------"
    purple "5. 返回主菜单"
    skyblue "-----------------------------------"
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
            echo ""
            green "========== 所有节点链接 =========="
            echo ""
            while IFS= read -r line; do
                [ -n "$line" ] && echo -e "${purple}$line${re}"
            done < ${work_dir}/url.txt

            load_ports
            local server_ip=$(get_realip)
            local s_port=$(sed -n 's/.*:\([0-9]*\).*/\1/p' "${work_dir}/Caddyfile" 2>/dev/null | head -1)
            local s_path=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' "${work_dir}/Caddyfile" 2>/dev/null)
            echo ""
            green "========== 订阅链接 =========="
            green "http://$server_ip:$s_port/$s_path"
            echo ""
            green "================================"
            ;;
        4)
            load_ports
            local server_ip=$(get_realip)
            local s_port=$(sed -n 's/.*:\([0-9]*\).*/\1/p' "${work_dir}/Caddyfile" 2>/dev/null | head -1)
            local s_path=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' "${work_dir}/Caddyfile" 2>/dev/null)
            local sub_link="http://$server_ip:$s_port/$s_path"
            echo -n "$sub_link" | pbcopy 2>/dev/null
            if [ $? -eq 0 ]; then
                green "\n订阅链接已复制到剪贴板：$sub_link\n"
            else
                yellow "\n剪贴板复制失败，请手动复制：\n$sub_link\n"
            fi
            ;;
        5) return ;;
        *) red "无效的选项！" ;;
    esac
}

# 启动 xray
start_xray() {
    check_xray &>/dev/null
    local status=$?
    if [ $status -eq 1 ]; then
        yellow "\n正在启动 ${server_name} 服务\n"
        launchctl load -w "${launchd_dir}/com.xray.service.plist" 2>/dev/null
        sleep 1
        if launchctl list 2>/dev/null | grep -q "com.xray.service"; then
            green "${server_name} 服务已成功启动\n"
        else
            red "${server_name} 服务启动失败\n"
        fi
    elif [ $status -eq 0 ]; then
        yellow "xray 正在运行\n"
    else
        yellow "xray 尚未安装!\n"
    fi
}

# 停止 xray
stop_xray() {
    check_xray &>/dev/null
    local status=$?
    if [ $status -eq 0 ]; then
        yellow "\n正在停止 ${server_name} 服务\n"
        launchctl unload "${launchd_dir}/com.xray.service.plist" 2>/dev/null
        sleep 1
        green "${server_name} 服务已停止\n"
    elif [ $status -eq 1 ]; then
        yellow "xray 未运行\n"
    else
        yellow "xray 尚未安装！\n"
    fi
}

# 重启 xray
restart_xray() {
    check_xray &>/dev/null
    local status=$?
    if [ $status -eq 0 ] || [ $status -eq 1 ]; then
        yellow "\n正在重启 ${server_name} 服务\n"
        launchctl unload "${launchd_dir}/com.xray.service.plist" 2>/dev/null
        sleep 1
        launchctl load -w "${launchd_dir}/com.xray.service.plist"
        sleep 1
        if launchctl list 2>/dev/null | grep -q "com.xray.service"; then
            green "${server_name} 服务已成功重启\n"
        else
            red "${server_name} 服务重启失败\n"
        fi
    else
        yellow "xray 尚未安装！\n"
    fi
}

# 启动 argo
start_argo() {
    check_argo &>/dev/null
    local status=$?
    if [ $status -eq 1 ]; then
        yellow "\n正在启动 Argo 服务\n"
        launchctl load -w "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null
        sleep 1
        green "Argo 服务已启动\n"
    elif [ $status -eq 0 ]; then
        green "Argo 服务正在运行\n"
    else
        yellow "Argo 尚未安装！\n"
    fi
}

# 停止 argo
stop_argo() {
    check_argo &>/dev/null
    local status=$?
    if [ $status -eq 0 ]; then
        yellow "\n正在停止 Argo 服务\n"
        launchctl unload "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null
        sleep 1
        green "Argo 服务已成功停止\n"
    elif [ $status -eq 1 ]; then
        yellow "Argo 服务未运行\n"
    else
        yellow "Argo 尚未安装！\n"
    fi
}

# 重启 argo
restart_argo() {
    check_argo &>/dev/null
    local status=$?
    if [ $status -eq 0 ] || [ $status -eq 1 ]; then
        yellow "\n正在重启 Argo 服务\n"
        rm -f "${work_dir}/argo.log" 2>/dev/null
        launchctl unload "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null
        sleep 1
        launchctl load -w "${launchd_dir}/com.cloudflare.tunnel.plist"
        sleep 1
        green "Argo 服务已成功重启\n"
    else
        yellow "Argo 尚未安装！\n"
    fi
}

# 启动 caddy
start_caddy() {
    if command -v caddy &>/dev/null || [ -f /usr/local/bin/caddy ]; then
        yellow "\n正在启动 caddy 服务\n"
        launchctl unload "${launchd_dir}/com.caddy.service.plist" 2>/dev/null
        launchctl load -w "${launchd_dir}/com.caddy.service.plist"
        sleep 1
        green "caddy 服务已启动\n"
    else
        yellow "caddy 尚未安装！\n"
    fi
}

# 重启 caddy
restart_caddy() {
    if command -v caddy &>/dev/null || [ -f /usr/local/bin/caddy ]; then
        yellow "\n正在重启 caddy 服务\n"
        launchctl unload "${launchd_dir}/com.caddy.service.plist" 2>/dev/null
        sleep 1
        launchctl load -w "${launchd_dir}/com.caddy.service.plist"
        sleep 1
        green "caddy 服务已成功重启\n"
    else
        yellow "caddy 尚未安装！\n"
    fi
}

# 卸载 xray
uninstall_xray() {
    reading "确定要卸载 xray-2go 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 xray"
            launchctl unload "${launchd_dir}/com.xray.service.plist" 2>/dev/null
            launchctl unload "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null
            launchctl unload "${launchd_dir}/com.caddy.service.plist" 2>/dev/null

            rm -f "${launchd_dir}/com.xray.service.plist"
            rm -f "${launchd_dir}/com.cloudflare.tunnel.plist"
            rm -f "${launchd_dir}/com.caddy.service.plist"

            rm -f /usr/local/bin/2go 2>/dev/null

            reading "\n是否卸载 caddy？(y/n): " choice
            case "${choice}" in
                y|Y) rm -f /usr/local/bin/caddy; green "caddy 已卸载" ;;
                *) yellow "取消卸载 caddy\n" ;;
            esac

            reading "\n是否卸载 jq？(y/n): " choice
            case "${choice}" in
                y|Y) rm -f /usr/local/bin/jq; green "jq 已卸载" ;;
                *) yellow "取消卸载 jq\n" ;;
            esac

            rm -rf "${work_dir}"

            green "\nXray_2go 卸载成功\n"
            ;;
        *)
            purple "已取消卸载操作\n"
            ;;
    esac
}

# 创建快捷指令
create_shortcut() {
    cat > "${work_dir}/2go.sh" << 'EOF'
#!/usr/bin/env bash
bash <(curl -Ls https://github.com/eooce/xray-2go/raw/main/xray_2go.sh) $1
EOF
    chmod +x "${work_dir}/2go.sh"
    [ ! -d /usr/local/bin ] && mkdir -p /usr/local/bin
    ln -sf "${work_dir}/2go.sh" /usr/local/bin/2go
    if [ -f /usr/local/bin/2go ]; then
        green "\n快捷指令 2go 创建成功\n"
    else
        red "\n快捷指令创建失败\n"
    fi
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
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            reading "\n请输入新的UUID: " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]') && green "\n生成的UUID为：$new_uuid"
            sed -i '' "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" "$config_dir"
            restart_xray
            sed -i '' "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" "$client_dir"
            # 更新 ports.env 中的 UUID
            sed -i '' "s/^UUID=.*/UUID=$new_uuid/" "${work_dir}/ports.env"
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
            base64 -i "$client_dir" -o "${work_dir}/sub_tmp.txt"
            tr -d '\n' < "${work_dir}/sub_tmp.txt" > "${work_dir}/sub.txt"
            rm -f "${work_dir}/sub_tmp.txt"
            while IFS= read -r line; do yellow "$line"; done < "$client_dir"
            green "\nUUID已修改为：${purple}${new_uuid}${re} ${green}请更新订阅或手动更改所有节点的UUID${re}\n"
            ;;
        2)
            reading "\n请输入grpc-reality端口 (回车跳过将自动分配): " new_port
            [ -z "$new_port" ] && new_port=$(find_available_port 2000 65000)
            until [[ -z $(lsof -iTCP:$new_port -sTCP:LISTEN 2>/dev/null) ]]; do
                echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                reading "请输入新的端口(1-65535):" new_port
                [[ -z $new_port ]] && new_port=$(find_available_port 2000 65000)
            done
            sed -i '' "41s/\"port\":[[:space:]]*[0-9]*/\"port\": $new_port/" "${config_dir}"
            sed -i '' "s/^GRPC_PORT=.*/GRPC_PORT=$new_port/" "${work_dir}/ports.env"
            restart_xray
            sed -i '' '1s/\(vless:\/\/[^@]*@[^:]*:\)[0-9]*/\1'"$new_port"'/' "$client_dir"
            base64 -i "$client_dir" -o "${work_dir}/sub_tmp.txt"
            tr -d '\n' < "${work_dir}/sub_tmp.txt" > "${work_dir}/sub.txt"
            rm -f "${work_dir}/sub_tmp.txt"
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nGRPC-reality端口已修改成：${purple}$new_port${re} ${green}请更新订阅或手动更改grpc-reality节点端口${re}\n"
            ;;
        3)
            reading "\n请输入xhttp-reality端口 (回车跳过将自动分配): " new_port
            [ -z "$new_port" ] && new_port=$(find_available_port 2000 65000)
            until [[ -z $(lsof -iTCP:$new_port -sTCP:LISTEN 2>/dev/null) ]]; do
                echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                reading "请输入新的端口(1-65535):" new_port
                [[ -z $new_port ]] && new_port=$(find_available_port 2000 65000)
            done
            sed -i '' "35s/\"port\":[[:space:]]*[0-9]*/\"port\": $new_port/" "${config_dir}"
            sed -i '' "s/^XHTTP_PORT=.*/XHTTP_PORT=$new_port/" "${work_dir}/ports.env"
            restart_xray
            sed -i '' '3s/\(vless:\/\/[^@]*@[^:]*:\)[0-9]*/\1'"$new_port"'/' "$client_dir"
            base64 -i "$client_dir" -o "${work_dir}/sub_tmp.txt"
            tr -d '\n' < "${work_dir}/sub_tmp.txt" > "${work_dir}/sub.txt"
            rm -f "${work_dir}/sub_tmp.txt"
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
                new_sni="www.joom.com"
            elif [[ "$new_sni" == "3" ]]; then
                new_sni="www.stengg.com"
            elif [[ "$new_sni" == "4" ]]; then
                new_sni="www.nazhumi.com"
            fi
            jq --arg new_sni "$new_sni" '.inbounds[5].streamSettings.realitySettings.dest = ($new_sni + ":443") | .inbounds[5].streamSettings.realitySettings.serverNames = [$new_sni]' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            restart_xray
            sed -i '' "1s/\(vless:\/\/[^\?]*\?\([^\&]*\&\)*sni=\)[^&]*/\1$new_sni/" "$client_dir"
            sed -i '' "1s/\(vless:\/\/[^\?]*\?\([^\&]*\&\)*authority=\)[^&]*/\1$new_sni/" "$client_dir"
            base64 -i "$client_dir" -o "${work_dir}/sub_tmp.txt"
            tr -d '\n' < "${work_dir}/sub_tmp.txt" > "${work_dir}/sub.txt"
            rm -f "${work_dir}/sub_tmp.txt"
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            echo ""
            green "\nReality sni已修改为：${purple}${new_sni}${re} ${green}请更新订阅或手动更改reality节点的sni域名${re}\n"
            ;;
        0) menu ;;
        *) red "无效的选项！" ;;
    esac
}

disable_open_sub() {
    check_xray &>/dev/null
    local xray_status=$?
    if [ $xray_status -eq 0 ]; then
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
                if command -v caddy &>/dev/null || [ -f /usr/local/bin/caddy ]; then
                    launchctl unload "${launchd_dir}/com.caddy.service.plist" 2>/dev/null
                    green "\n已关闭节点订阅\n"
                else
                    yellow "caddy is not installed"
                fi
                ;;
            2)
                green "\n已开启节点订阅\n"
                server_ip=$(get_realip)
                new_password=$(LC_ALL=C tr -dc A-Za-z < /dev/urandom | head -c 32)
                sed -i '' "s/\/[a-zA-Z0-9]\{1,\}/\/$new_password/g" "${work_dir}/Caddyfile"
                sub_port=$(grep -oE ':[0-9]+' "${work_dir}/Caddyfile" | head -1 | tr -d ':')
                start_caddy
                if [ "$sub_port" = "80" ]; then
                    link="http://$server_ip/$new_password"
                else
                    green "订阅端口：$sub_port"
                    link="http://$server_ip:$sub_port/$new_password"
                fi
                green "\n新的节点订阅链接：$link\n"
                ;;
            3)
                reading "请输入新的订阅端口(1-65535):" sub_port
                [ -z "$sub_port" ] && sub_port=$(find_available_port 2000 65000)
                until [[ -z $(lsof -iTCP:$sub_port -sTCP:LISTEN 2>/dev/null) ]]; do
                    echo -e "${red}${sub_port}端口已经被其他程序占用，请更换端口重试${re}"
                    reading "请输入新的订阅端口(1-65535):" sub_port
                    [[ -z $sub_port ]] && sub_port=$(find_available_port 2000 65000)
                done
                sed -i '' "s/:[0-9]\{1,\}/:$sub_port/g" "${work_dir}/Caddyfile"
                # 更新 ports.env
                sed -i '' "s/^PORT=.*/PORT=$sub_port/" "${work_dir}/ports.env"
                path=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' "${work_dir}/Caddyfile")
                server_ip=$(get_realip)
                restart_caddy
                green "\n订阅端口更换成功\n"
                green "新的订阅链接为：http://$server_ip:$sub_port/$path\n"
                ;;
            4) menu ;;
            *) red "无效的选项！" ;;
        esac
    else
        yellow "Xray-2go 尚未安装或未运行！"
        sleep 1
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

# 获取 argo 临时隧道
get_quick_tunnel() {
    restart_argo
    yellow "获取临时 argo 域名中，请稍等...\n"
    sleep 5
    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..10}; do
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            [ -n "$get_argodomain" ] && break
            sleep 3
        done
    else
        restart_argo
        sleep 8
        for i in {1..5}; do
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | tail -1)
            [ -n "$get_argodomain" ] && break
            sleep 3
        done
    fi
    if [ -n "$get_argodomain" ]; then
        green "ArgoDomain：${purple}$get_argodomain${re}\n"
    else
        red "获取 Argo 域名失败，请检查网络后重试\n"
    fi
    ArgoDomain=$get_argodomain
}

# 更新 Argo 域名到订阅
change_argo_domain() {
    if [ -z "$ArgoDomain" ]; then
        red "Argo 域名为空，无法更新"
        return
    fi
    sed -i '' "5s/sni=[^&]*/sni=$ArgoDomain/" "${work_dir}/url.txt"
    sed -i '' "5s/host=[^&]*/host=$ArgoDomain/" "${work_dir}/url.txt"
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
    base64 -i "${work_dir}/url.txt" -o "${work_dir}/sub_tmp.txt"
    tr -d '\n' < "${work_dir}/sub_tmp.txt" > "${work_dir}/sub.txt"
    rm -f "${work_dir}/sub_tmp.txt"

    while IFS= read -r line; do echo -e "${purple}$line"; done < "$client_dir"

    green "\n节点已更新，更新订阅或手动复制以上节点\n"
}

# Argo 管理
manage_argo() {
    check_argo &>/dev/null
    local argo_status=$?
    if [ $argo_status -eq 2 ]; then
        yellow "Argo 尚未安装！"
        sleep 1
        return
    fi
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
        1) start_argo ;;
        2) stop_argo ;;
        3)
            clear
            load_ports
            yellow "\n固定隧道可为json或token，固定隧道端口为${ARGO_PORT}，自行在cf后台设置\n\njson在f佬维护的站点里获取，获取地址：${purple}https://fscarmen.cloudflare.now.cc${re}\n"
            reading "\n请输入你的argo域名: " argo_domain
            green "你的Argo域名为：$argo_domain"
            ArgoDomain=$argo_domain
            reading "\n请输入你的argo密钥(token或json): " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                echo $argo_auth > ${work_dir}/tunnel.json
                cat > ${work_dir}/tunnel.yml << EOF
tunnel: $(echo "$argo_auth" | cut -d\" -f12)
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: $ArgoDomain
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                cat > "${launchd_dir}/com.cloudflare.tunnel.plist" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>${work_dir}/argo</string>
        <string>tunnel</string>
        <string>--edge-ip-version</string>
        <string>auto</string>
        <string>--config</string>
        <string>${work_dir}/tunnel.yml</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${work_dir}/argo.log</string>
    <key>StandardOutPath</key>
    <string>${work_dir}/argo.log</string>
</dict>
</plist>
PEOF
                restart_argo
                change_argo_domain
            elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                cat > "${launchd_dir}/com.cloudflare.tunnel.plist" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>${work_dir}/argo</string>
        <string>tunnel</string>
        <string>--edge-ip-version</string>
        <string>auto</string>
        <string>--no-autoupdate</string>
        <string>--protocol</string>
        <string>http2</string>
        <string>run</string>
        <string>--token</string>
        <string>${argo_auth}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${work_dir}/argo.log</string>
    <key>StandardOutPath</key>
    <string>${work_dir}/argo.log</string>
</dict>
</plist>
PEOF
                restart_argo
                change_argo_domain
            else
                yellow "你输入的argo域名或token不匹配，请重新输入"
                manage_argo
            fi
            ;;
        4)
            clear
            load_ports
            macos_launchd_services
            get_quick_tunnel
            change_argo_domain
            ;;
        5)
            if grep -q "tunnel.yml" "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null || grep -q "\-\-token" "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null; then
                yellow "当前使用固定隧道，无法获取临时隧道"
                sleep 2
            else
                get_quick_tunnel
                change_argo_domain
            fi
            ;;
        6) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# 查看节点信息和订阅链接
check_nodes() {
    check_xray &>/dev/null
    local xray_status=$?
    if [ $xray_status -eq 0 ]; then
        load_ports
        while IFS= read -r line; do purple "$line"; done < ${work_dir}/url.txt
        server_ip=$(get_realip)
        sub_port=$(sed -n 's/.*:\([0-9]*\).*/\1/p' "${work_dir}/Caddyfile" 2>/dev/null | head -1)
        lujing=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' "${work_dir}/Caddyfile" 2>/dev/null)
        if [ -n "$sub_port" ] && [ -n "$lujing" ]; then
            green "\n\n节点订阅链接：http://$server_ip:$sub_port/$lujing\n"
        else
            yellow "\n\n订阅信息获取失败，请检查 Caddy 配置\n"
        fi
    else
        yellow "Xray-2go 尚未安装或未运行，请先安装或启动 Xray-2go"
        sleep 1
    fi
}

# 捕获 Ctrl+C 信号
trap 'red "已取消操作"; exit' INT

install_xray2go_all() {
    check_xray &>/dev/null; local check_xray_ret=$?
    if [ $check_xray_ret -eq 0 ]; then
        yellow "Xray-2go 已经安装！"
        xray2go_upload_links_latest_to_postgres || true
        return 0
    fi
    install_caddy
    manage_packages install jq qrencode
    install_xray
    macos_launchd_services
    sleep 3
    get_info
    add_caddy_conf
    create_shortcut
}

# 主菜单
menu() {
    while true; do
        check_xray &>/dev/null; local check_xray_ret=$?
        check_caddy &>/dev/null; local check_caddy_ret=$?
        check_argo &>/dev/null; local check_argo_ret=$?
        check_xray_status=$(check_xray 2>/dev/null)
        check_caddy_status=$(check_caddy 2>/dev/null)
        check_argo_status=$(check_argo 2>/dev/null)
        clear
        echo ""
        purple "=== 老王Xray-2go一键安装脚本 (macOS版) ===\n"
        purple " Xray 状态: ${check_xray_status}\n"
        purple " Argo 状态: ${check_argo_status}\n"
        purple "Caddy 状态: ${check_caddy_status}\n"
        green "1. 安装Xray-2go"
        red "2. 卸载Xray-2go"
        echo "==============="
        green "3. Xray-2go管理"
        green "4. Argo隧道管理"
        echo "==============="
        green "5. 查看节点信息"
        green "6. 修改节点配置"
        green "7. 管理节点订阅"
        echo "==============="
        skyblue "8. 导出代理为txt"
        skyblue "9. 上传 xray2go_links_latest.txt 到 PostgreSQL"
        echo "==============="
        red "0. 退出脚本"
        echo "==========="
        reading "请输入选择(0-9): " choice
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
            9) xray2go_upload_links_latest_to_postgres ;;
            0) exit 0 ;;
            *) red "无效的选项，请输入 0 到 9" ;;
        esac
        read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
    done
}

case "${1:-menu}" in
    install) install_xray2go_all ;;
    upload-db|upload-links) xray2go_upload_links_latest_to_postgres ;;
    menu|*) menu ;;
esac
