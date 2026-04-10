#!/bin/bash

# ===========================================
# Xray-2go macOS 适配版
# 原脚本适用于 Linux，此版本适配 macOS
# 需要预装 Homebrew (https://brew.sh)
# ===========================================

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

# 定义常量 - macOS 使用用户目录
server_name="xray"
work_dir="$HOME/.xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
launchd_dir="$HOME/Library/LaunchAgents"

# 定义环境变量 - macOS 使用 uuidgen 代替 /proc/sys/kernel/random/uuid
export UUID=${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}
export PORT=${PORT:-$(jot -r 1 1000 60000)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

# macOS 不需要 root，但需要 Homebrew
check_homebrew() {
    if ! command -v brew &>/dev/null; then
        red "请先安装 Homebrew: https://brew.sh"
        red '运行: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        exit 1
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
    if command -v caddy &>/dev/null; then
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

# macOS 包管理 - 使用 Homebrew
manage_packages() {
    if [ $# -lt 2 ]; then
        red "未指定包名或操作"
        return 1
    fi

    action=$1
    shift

    for package in "$@"; do
        # 某些包在 brew 中名称不同
        brew_name="$package"
        case "$package" in
            "lsof") continue ;; # macOS 自带 lsof
            "openssl") brew_name="openssl" ;;
            "coreutils") brew_name="coreutils" ;;
            "iptables") continue ;; # macOS 不用 iptables
        esac

        if [ "$action" == "install" ]; then
            if command -v "$package" &>/dev/null || brew list "$brew_name" &>/dev/null; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${brew_name}..."
            brew install "$brew_name"
        elif [ "$action" == "uninstall" ]; then
            if ! brew list "$brew_name" &>/dev/null; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${brew_name}..."
            brew uninstall "$brew_name"
        else
            red "Unknown action: $action"
            return 1
        fi
    done
    return 0
}

# 获取真实 IP
get_realip() {
    ip=$(curl -s --max-time 2 ipv4.ip.sb)
    if [ -z "$ip" ]; then
        ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
        echo "[$ipv6]"
    else
        if echo "$(curl -s http://ipinfo.io/org)" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
            ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
            echo "[$ipv6]"
        else
            echo "$ip"
        fi
    fi
}

# 下载并安装 xray, cloudflared
install_xray() {
    clear
    purple "正在安装 Xray-2go (macOS) 中，请稍等..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64')
            ARCH='amd64'
            ARCH_ARG='64'
            CF_ARCH='amd64'
            ;;
        'arm64')
            ARCH='arm64'
            ARCH_ARG='arm64-v8a'
            CF_ARCH='arm64'
            ;;
        *)
            red "不支持的架构: ${ARCH_RAW}"
            exit 1
            ;;
    esac

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

    # 下载 cloudflared (macOS 版本)
    yellow "下载 cloudflared..."
    if [ "$ARCH_RAW" = "arm64" ]; then
        # Apple Silicon
        brew install cloudflare/cloudflare/cloudflared 2>/dev/null || \
        curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64"
    else
        curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"
    fi

    # 如果通过 brew 安装了 cloudflared，创建软链接
    if command -v cloudflared &>/dev/null && [ ! -f "${work_dir}/argo" ]; then
        ln -sf "$(which cloudflared)" "${work_dir}/argo"
    fi

    # 下载 qrencode（macOS 通过 brew 安装）
    brew install qrencode 2>/dev/null
    # 创建 qrencode 包装脚本
    cat > "${work_dir}/qrencode" << 'QREOF'
#!/bin/bash
qrencode -t ANSIUTF8 "$1"
QREOF
    chmod +x "${work_dir}/qrencode"

    # 解压 xray
    unzip -o "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1
    chmod +x ${work_dir}/${server_name} ${work_dir}/argo 2>/dev/null
    rm -rf "${work_dir}/${server_name}.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"

    # 解除 macOS quarantine 属性（否则会被 Gatekeeper 阻止）
    xattr -d com.apple.quarantine "${work_dir}/${server_name}" 2>/dev/null
    xattr -d com.apple.quarantine "${work_dir}/argo" 2>/dev/null

    # 生成随机密码
    password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    GRPC_PORT=$(($PORT + 1))
    XHTTP_PORT=$(($PORT + 2))

    # 生成 x25519 密钥对
    output=$("${work_dir}/xray" x25519)
    private_key=$(echo "${output}" | grep "Private key:" | awk '{print $3}')
    public_key=$(echo "${output}" | grep "Public key:" | awk '{print $3}')
    # 兼容不同版本的输出格式
    if [ -z "$private_key" ]; then
        private_key=$(echo "${output}" | grep "PrivateKey:" | awk '{print $2}')
        public_key=$(echo "${output}" | grep "PublicKey:" | awk '{print $2}')
    fi

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
}

# macOS launchd 守护进程
macos_launchd_services() {
    # Xray 服务
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

    # Cloudflare Tunnel 服务
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

    # 加载服务
    launchctl unload "${launchd_dir}/com.xray.service.plist" 2>/dev/null
    launchctl load -w "${launchd_dir}/com.xray.service.plist"
    launchctl unload "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null
    launchctl load -w "${launchd_dir}/com.cloudflare.tunnel.plist"
}

# Caddy 服务 plist
macos_caddy_launchd() {
    cat > "${launchd_dir}/com.caddy.service.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.caddy.service</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which caddy)</string>
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
    IP=$(get_realip)

    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "vps")

    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..5}; do
            purple "第 $i 次尝试获取 ArgoDomain 中..."
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
            [ -n "$argodomain" ] && break
            sleep 2
        done
    else
        restart_argo
        sleep 6
        argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
    fi

    green "\nArgoDomain：${purple}$argodomain${re}\n"

    # macOS base64 不支持 -w0，使用不换行方式
    cat > ${work_dir}/url.txt <<EOF
vless://${UUID}@${IP}:${GRPC_PORT}??encryption=none&security=reality&sni=www.iij.ad.jp&fp=chrome&pbk=${public_key}&allowInsecure=1&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#${isp}

vless://${UUID}@${IP}:${XHTTP_PORT}?encryption=none&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${public_key}&allowInsecure=1&type=xhttp&mode=auto#${isp}

vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}

vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"chrome\"}" | base64)

EOF
    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt
    # macOS base64 编码（无 -w0 参数）
    base64 -i ${work_dir}/url.txt -o ${work_dir}/sub.txt
    # 去除换行
    tr -d '\n' < ${work_dir}/sub.txt > ${work_dir}/sub_tmp.txt && mv ${work_dir}/sub_tmp.txt ${work_dir}/sub.txt
    yellow "\n温馨提醒：如果是 NAT 机，reality 端口和订阅端口需使用可用端口范围内的端口\n"
    green "节点订阅链接：http://$IP:$PORT/$password\n\n订阅链接适用于 V2rayN, Nekbox, karing, Sterisand, Loon, 小火箭, 圈X 等\n"
    green "订阅二维码"
    qrencode -t ANSIUTF8 "http://$IP:$PORT/$password" 2>/dev/null || yellow "（请安装 qrencode 以显示二维码: brew install qrencode）"
    echo ""
}

# 安装 caddy（macOS 通过 brew）
install_caddy() {
    if command -v caddy &>/dev/null; then
        green "caddy already installed"
    else
        yellow "正在通过 Homebrew 安装 caddy..."
        brew install caddy
    fi
}

# caddy 订阅配置 - macOS 版本路径放在 work_dir 下
add_caddy_conf() {
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
    else
        red "Caddy 配置文件验证失败，订阅功能可能无法使用，但不影响节点使用"
    fi
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
        sleep 1
    else
        yellow "xray 尚未安装!\n"
        sleep 1
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
        rm "${work_dir}/argo.log" 2>/dev/null
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
    if command -v caddy &>/dev/null; then
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
    if command -v caddy &>/dev/null; then
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
            # 停止并卸载 launchd 服务
            launchctl unload "${launchd_dir}/com.xray.service.plist" 2>/dev/null
            launchctl unload "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null
            launchctl unload "${launchd_dir}/com.caddy.service.plist" 2>/dev/null

            rm -f "${launchd_dir}/com.xray.service.plist"
            rm -f "${launchd_dir}/com.cloudflare.tunnel.plist"
            rm -f "${launchd_dir}/com.caddy.service.plist"

            # 删除快捷方式
            rm -f /usr/local/bin/2go 2>/dev/null

            reading "\n是否卸载 caddy？(y/n): " choice
            case "${choice}" in
                y|Y) brew uninstall caddy 2>/dev/null ;;
                *) yellow "取消卸载 caddy\n" ;;
            esac

            # 删除工作目录
            rm -rf "${work_dir}"

            green "\nXray_2go 卸载成功\n"
            ;;
        *)
            purple "已取消卸载操作\n"
            ;;
    esac
}

# 创建快捷指令 - macOS 使用 /usr/local/bin
create_shortcut() {
    cat > "${work_dir}/2go.sh" << 'EOF'
#!/usr/bin/env bash
bash <(curl -Ls https://github.com/eooce/xray-2go/raw/main/xray_2go.sh) $1
EOF
    chmod +x "${work_dir}/2go.sh"
    # macOS 上 /usr/local/bin 不需要 sudo（如果目录存在）
    if [ -d /usr/local/bin ]; then
        ln -sf "${work_dir}/2go.sh" /usr/local/bin/2go 2>/dev/null || \
        sudo ln -sf "${work_dir}/2go.sh" /usr/local/bin/2go
    else
        sudo mkdir -p /usr/local/bin
        sudo ln -sf "${work_dir}/2go.sh" /usr/local/bin/2go
    fi
    if [ -f /usr/local/bin/2go ]; then
        green "\n快捷指令 2go 创建成功\n"
    else
        red "\n快捷指令创建失败\n"
    fi
}

# 变更配置
change_config() {
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
            # macOS sed -i 需要备份后缀，用 '' 表示不保留备份
            sed -i '' "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" "$config_dir"
            restart_xray
            sed -i '' "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" "$client_dir"
            content=$(cat "$client_dir")
            vmess_urls=$(grep -o 'vmess://[^ ]*' "$client_dir")
            vmess_prefix="vmess://"
            for vmess_url in $vmess_urls; do
                encoded_vmess="${vmess_url#"$vmess_prefix"}"
                decoded_vmess=$(echo "$encoded_vmess" | base64 --decode)
                updated_vmess=$(echo "$decoded_vmess" | jq --arg new_uuid "$new_uuid" '.id = $new_uuid')
                encoded_updated_vmess=$(echo "$updated_vmess" | base64)
                encoded_updated_vmess=$(echo "$encoded_updated_vmess" | tr -d '\n')
                new_vmess_url="$vmess_prefix$encoded_updated_vmess"
                content=$(echo "$content" | sed "s|$vmess_url|$new_vmess_url|")
            done
            echo "$content" > "$client_dir"
            base64 -i "$client_dir" -o "${work_dir}/sub.txt"
            tr -d '\n' < "${work_dir}/sub.txt" > "${work_dir}/sub_tmp.txt" && mv "${work_dir}/sub_tmp.txt" "${work_dir}/sub.txt"
            while IFS= read -r line; do yellow "$line"; done < "$client_dir"
            green "\nUUID已修改为：${purple}${new_uuid}${re} ${green}请更新订阅或手动更改所有节点的UUID${re}\n"
            ;;
        2)
            reading "\n请输入grpc-reality端口 (回车跳过将使用随机端口): " new_port
            [ -z "$new_port" ] && new_port=$(jot -r 1 2000 65000)
            until [[ -z $(lsof -iTCP:$new_port -sTCP:LISTEN 2>/dev/null) ]]; do
                echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                reading "请输入新的端口(1-65535):" new_port
                [[ -z $new_port ]] && new_port=$(jot -r 1 2000 65000)
            done
            sed -i '' "41s/\"port\":[[:space:]]*[0-9]*/\"port\": $new_port/" "${config_dir}"
            restart_xray
            sed -i '' '1s/\(vless:\/\/[^@]*@[^:]*:\)[0-9]*/\1'"$new_port"'/' "$client_dir"
            base64 -i "$client_dir" -o "${work_dir}/sub.txt"
            tr -d '\n' < "${work_dir}/sub.txt" > "${work_dir}/sub_tmp.txt" && mv "${work_dir}/sub_tmp.txt" "${work_dir}/sub.txt"
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nGRPC-reality端口已修改成：${purple}$new_port${re} ${green}请更新订阅或手动更改grpc-reality节点端口${re}\n"
            ;;
        3)
            reading "\n请输入xhttp-reality端口 (回车跳过将使用随机端口): " new_port
            [ -z "$new_port" ] && new_port=$(jot -r 1 2000 65000)
            until [[ -z $(lsof -iTCP:$new_port -sTCP:LISTEN 2>/dev/null) ]]; do
                echo -e "${red}${new_port}端口已经被其他程序占用，请更换端口重试${re}"
                reading "请输入新的端口(1-65535):" new_port
                [[ -z $new_port ]] && new_port=$(jot -r 1 2000 65000)
            done
            sed -i '' "35s/\"port\":[[:space:]]*[0-9]*/\"port\": $new_port/" "${config_dir}"
            restart_xray
            sed -i '' '3s/\(vless:\/\/[^@]*@[^:]*:\)[0-9]*/\1'"$new_port"'/' "$client_dir"
            base64 -i "$client_dir" -o "${work_dir}/sub.txt"
            tr -d '\n' < "${work_dir}/sub.txt" > "${work_dir}/sub_tmp.txt" && mv "${work_dir}/sub_tmp.txt" "${work_dir}/sub.txt"
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
            base64 -i "$client_dir" -o "${work_dir}/sub.txt"
            tr -d '\n' < "${work_dir}/sub.txt" > "${work_dir}/sub_tmp.txt" && mv "${work_dir}/sub_tmp.txt" "${work_dir}/sub.txt"
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
                if command -v caddy &>/dev/null; then
                    launchctl unload "${launchd_dir}/com.caddy.service.plist" 2>/dev/null
                    green "\n已关闭节点订阅\n"
                else
                    yellow "caddy is not installed"
                fi
                ;;
            2)
                green "\n已开启节点订阅\n"
                server_ip=$(get_realip)
                password=$(LC_ALL=C tr -dc A-Za-z < /dev/urandom | head -c 32)
                sed -i '' "s/\/[a-zA-Z0-9]\{1,\}/\/$password/g" "${work_dir}/Caddyfile"
                sub_port=$(grep -oE ':[0-9]+' "${work_dir}/Caddyfile" | head -1 | tr -d ':')
                start_caddy
                if [ "$sub_port" -eq 80 ] 2>/dev/null; then
                    link="http://$server_ip/$password"
                else
                    green "订阅端口：$sub_port"
                    link="http://$server_ip:$sub_port/$password"
                fi
                green "\n新的节点订阅链接：$link\n"
                ;;
            3)
                reading "请输入新的订阅端口(1-65535):" sub_port
                [ -z "$sub_port" ] && sub_port=$(jot -r 1 2000 65000)
                until [[ -z $(lsof -iTCP:$sub_port -sTCP:LISTEN 2>/dev/null) ]]; do
                    echo -e "${red}${sub_port}端口已经被其他程序占用，请更换端口重试${re}"
                    reading "请输入新的订阅端口(1-65535):" sub_port
                    [[ -z $sub_port ]] && sub_port=$(jot -r 1 2000 65000)
                done
                sed -i '' "s/:[0-9]\{1,\}/:$sub_port/g" "${work_dir}/Caddyfile"
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
            yellow "\n固定隧道可为json或token，固定隧道端口为8080，自行在cf后台设置\n\njson在f佬维护的站点里获取，获取地址：${purple}https://fscarmen.cloudflare.now.cc${re}\n"
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
    service: http://localhost:8080
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                # 更新 launchd plist 为固定隧道
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
            macos_launchd_services
            get_quick_tunnel
            change_argo_domain
            ;;
        5)
            # 检查是否为临时隧道
            if grep -q "localhost:${ARGO_PORT}" "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null && ! grep -q "tunnel.yml" "${launchd_dir}/com.cloudflare.tunnel.plist" 2>/dev/null; then
                get_quick_tunnel
                change_argo_domain
            else
                yellow "当前使用固定隧道，无法获取临时隧道"
                sleep 2
            fi
            ;;
        6) menu ;;
        *) red "无效的选项！" ;;
    esac
}

# 获取 argo 临时隧道
get_quick_tunnel() {
    restart_argo
    yellow "获取临时 argo 域名中，请稍等...\n"
    sleep 3
    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..5}; do
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
            [ -n "$get_argodomain" ] && break
            sleep 2
        done
    else
        restart_argo
        sleep 6
        get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
    fi
    green "ArgoDomain：${purple}$get_argodomain${re}\n"
    ArgoDomain=$get_argodomain
}

# 更新 Argo 域名到订阅
change_argo_domain() {
    sed -i '' "5s/sni=[^&]*/sni=$ArgoDomain/; 5s/host=[^&]*/host=$ArgoDomain/" "${work_dir}/url.txt"
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
    base64 -i "${work_dir}/url.txt" -o "${work_dir}/sub.txt"
    tr -d '\n' < "${work_dir}/sub.txt" > "${work_dir}/sub_tmp.txt" && mv "${work_dir}/sub_tmp.txt" "${work_dir}/sub.txt"

    while IFS= read -r line; do echo -e "${purple}$line"; done < "$client_dir"

    green "\n节点已更新，更新订阅或手动复制以上节点\n"
}

# 查看节点信息和订阅链接
check_nodes() {
    check_xray &>/dev/null
    local xray_status=$?
    if [ $xray_status -eq 0 ]; then
        while IFS= read -r line; do purple "$line"; done < ${work_dir}/url.txt
        server_ip=$(get_realip)
        sub_port=$(sed -n 's/.*:\([0-9]*\).*/\1/p' "${work_dir}/Caddyfile" | head -1)
        lujing=$(sed -n 's/.*handle \/\([a-zA-Z0-9]*\).*/\1/p' "${work_dir}/Caddyfile")
        green "\n\n节点订阅链接：http://$server_ip:$sub_port/$lujing\n"
    else
        yellow "Xray-2go 尚未安装或未运行，请先安装或启动 Xray-2go"
        sleep 1
    fi
}

# 捕获 Ctrl+C 信号
trap 'red "已取消操作"; exit' INT

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
        red "0. 退出脚本"
        echo "==========="
        reading "请输入选择(0-7): " choice
        echo ""
        case "${choice}" in
            1)
                if [ $check_xray_ret -eq 0 ]; then
                    yellow "Xray-2go 已经安装！"
                else
                    check_homebrew
                    install_caddy
                    manage_packages install jq unzip coreutils qrencode
                    install_xray
                    macos_launchd_services
                    sleep 3
                    get_info
                    add_caddy_conf
                    create_shortcut
                fi
                ;;
            2) uninstall_xray ;;
            3) manage_xray ;;
            4) manage_argo ;;
            5) check_nodes ;;
            6) change_config ;;
            7) disable_open_sub ;;
            0) exit 0 ;;
            *) red "无效的选项，请输入 0 到 7" ;;
        esac
        read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
    done
}

menu
