#!/bin/bash

# ===========================================
# Xray-2go macOS 适配版 (root 环境，无 Homebrew)
# 所有依赖直接下载二进制，不依赖 brew
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

# 定义环境变量 - macOS 使用 uuidgen
export UUID=${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}
export PORT=${PORT:-$(jot -r 1 1000 60000)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
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

# 安装依赖 - 直接下载二进制，不使用 brew
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

# 获取真实 IP
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


# 安装 caddy - 直接下载二进制
install_caddy() {
    if command -v caddy &>/dev/null; then
        green "caddy already installed"
        return
    fi
    yellow "正在下载安装 caddy..."
    get_arch

    # 获取最新版本号
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

    # 下载 cloudflared (macOS 版本) - 直接下载二进制
    yellow "下载 cloudflared..."
    curl -sLo "/tmp/cloudflared.tgz" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${ARCH}.tgz"
    if [ $? -eq 0 ]; then
        tar -xzf /tmp/cloudflared.tgz -C "${work_dir}/" 2>/dev/null
        if [ -f "${work_dir}/cloudflared" ]; then
            mv "${work_dir}/cloudflared" "${work_dir}/argo"
        fi
        rm -f /tmp/cloudflared.tgz
    else
        # 备用：直接下载非压缩版
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
    GRPC_PORT=$(($PORT + 1))
    XHTTP_PORT=$(($PORT + 2))

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
    IP=$(get_realip)

    isp=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | tr -d '\n' | awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | sed 's/ /_/g' || echo "vps")

    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..8}; do
            purple "第 $i 次尝试获取 ArgoDomain 中..."
            argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
            [ -n "$argodomain" ] && break
            sleep 3
        done
    else
        restart_argo
        sleep 8
        argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
    fi

    if [ -z "$argodomain" ]; then
        red "获取 Argo 临时域名失败，请稍后重试（选择菜单4 -> 5重新获取）"
        argodomain="获取失败请重试"
    fi

    green "\nArgoDomain：${purple}$argodomain${re}\n"

    # macOS base64 不支持 -w0
    cat > ${work_dir}/url.txt <<EOF
vless://${UUID}@${IP}:${GRPC_PORT}??encryption=none&security=reality&sni=www.iij.ad.jp&fp=chrome&pbk=${public_key}&allowInsecure=1&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#${isp}

vless://${UUID}@${IP}:${XHTTP_PORT}?encryption=none&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${public_key}&allowInsecure=1&type=xhttp&mode=auto#${isp}

vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}

vmess://$(echo "{ \"v\": \"2\", \"ps\": \"${isp}\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${UUID}\", \"aid\": \"0\", \"scy\": \"none\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"chrome\"}" | base64)

EOF
    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt

    # macOS base64 编码并去除换行
    base64 -i ${work_dir}/url.txt -o ${work_dir}/sub_tmp.txt
    tr -d '\n' < ${work_dir}/sub_tmp.txt > ${work_dir}/sub.txt
    rm -f ${work_dir}/sub_tmp.txt

    yellow "\n温馨提醒：如果是 NAT 机，reality 端口和订阅端口需使用可用端口范围内的端口\n"
    green "节点订阅链接：http://$IP:$PORT/$password\n\n订阅链接适用于 V2rayN, Nekbox, karing, Sterisand, Loon, 小火箭, 圈X 等\n"
    green "订阅二维码"
    ${work_dir}/qrencode "http://$IP:$PORT/$password"
    echo ""
}

# caddy 订阅配置
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
        green "Caddy 服务已启动"
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
                y|Y) rm -f /usr/local/bin/caddy; green "caddy 已卸载" ;;
                *) yellow "取消卸载 caddy\n" ;;
            esac

            reading "\n是否卸载 jq？(y/n): " choice
            case "${choice}" in
                y|Y) rm -f /usr/local/bin/jq; green "jq 已卸载" ;;
                *) yellow "取消卸载 jq\n" ;;
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
            base64 -i "$client_dir" -o "${work_dir}/sub_tmp.txt"
            tr -d '\n' < "${work_dir}/sub_tmp.txt" > "${work_dir}/sub.txt"
            rm -f "${work_dir}/sub_tmp.txt"
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
                password=$(LC_ALL=C tr -dc A-Za-z < /dev/urandom | head -c 32)
                sed -i '' "s/\/[a-zA-Z0-9]\{1,\}/\/$password/g" "${work_dir}/Caddyfile"
                sub_port=$(grep -oE ':[0-9]+' "${work_dir}/Caddyfile" | head -1 | tr -d ':')
                start_caddy
                if [ "$sub_port" = "80" ]; then
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

# 获取 argo 临时隧道
get_quick_tunnel() {
    restart_argo
    yellow "获取临时 argo 域名中，请稍等...\n"
    sleep 5
    if [ -f "${work_dir}/argo.log" ]; then
        for i in {1..8}; do
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
            [ -n "$get_argodomain" ] && break
            sleep 3
        done
    else
        restart_argo
        sleep 8
        get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
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
                    install_caddy
                    manage_packages install jq qrencode
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
