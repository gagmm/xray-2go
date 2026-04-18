#!/bin/bash
# ============================================================
# Xray-2go Linux 完整脚本
# 支持: systemd / OpenRC / SysVinit
# 支持: root / 非root 用户权限
# 版本: 2.0
# ============================================================

set -euo pipefail

# ============================================================
# 全局变量
# ============================================================
SCRIPT_VERSION="2.0"
INSTALL_DIR=""
LOG_LEVEL="INFO"
CDN_HOST="cdns.doon.eu.org"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# 日志函数
# ============================================================
log() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)  echo -e "${GREEN}[${timestamp}] [INFO]${NC}  $msg" ;;
        WARN)  echo -e "${YELLOW}[${timestamp}] [WARN]${NC}  $msg" ;;
        ERROR) echo -e "${RED}[${timestamp}] [ERROR]${NC} $msg" ;;
        STEP)  echo -e "${CYAN}[${timestamp}] [STEP]${NC}  $msg" ;;
    esac
}

die() {
    log "ERROR" "$1"
    exit 1
}

# ============================================================
# 平台检测
# ============================================================
detect_init_system() {
    if [[ -d /run/systemd/system ]]; then
        echo "systemd"
    elif command -v openrc &>/dev/null || [[ -d /etc/runlevels ]]; then
        echo "openrc"
    elif command -v procd &>/dev/null || [[ -f /etc/openwrt_release ]]; then
        echo "procd"
    else
        local init_name
        init_name=$(ps -p 1 -o comm= 2>/dev/null || echo "unknown")
        case "$init_name" in
            systemd) echo "systemd" ;;
            init)    echo "sysvinit" ;;
            procd)   echo "procd" ;;
            *)       echo "sysvinit" ;;
        esac
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*)        echo "armv7" ;;
        armv6*)        echo "armv6" ;;
        i386|i686)     echo "386" ;;
        *)             die "不支持的架构: $(uname -m)" ;;
    esac
}

is_root() {
    [[ $(id -u) -eq 0 ]]
}

get_install_dir() {
    if is_root; then
        echo "/etc/xray"
    else
        echo "${HOME}/.xray"
    fi
}

# ============================================================
# 依赖检查
# ============================================================
check_deps() {
    local missing=()

    for dep in curl openssl python3 unzip; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done

    # cron 不是必须的，只是 warn
    if ! command -v crontab &>/dev/null; then
        log "WARN" "crontab 不可用，cron 持久化层将跳过"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        if is_root; then
            log "WARN" "缺少依赖: ${missing[*]}，尝试安装..."
            if command -v apt-get &>/dev/null; then
                apt-get update -qq 2>/dev/null
                apt-get install -y -qq "${missing[@]}" 2>/dev/null || true
            elif command -v yum &>/dev/null; then
                yum install -y -q "${missing[@]}" 2>/dev/null || true
            elif command -v apk &>/dev/null; then
                apk add --quiet "${missing[@]}" 2>/dev/null || true
            elif command -v pacman &>/dev/null; then
                pacman -S --noconfirm --quiet "${missing[@]}" 2>/dev/null || true
            fi
        else
            log "WARN" "缺少依赖: ${missing[*]}"
            log "WARN" "非 root 用户无法自动安装，请手动运行:"
            log "WARN" "  sudo apt install ${missing[*]}"
            log "WARN" "或联系管理员安装后重试"
            # 只有真正必需的才报错退出
            for dep in "${missing[@]}"; do
                case "$dep" in
                    curl|unzip) die "必需工具 ${dep} 不存在，无法继续" ;;
                    *) log "WARN" "${dep} 缺失，部分功能可能受限" ;;
                esac
            done
        fi
    fi

    log "INFO" "依赖检查完成"
}


# ============================================================
# 下载函数
# ============================================================
download_file() {
    local url="$1"
    local dest="$2"
    local desc="${3:-文件}"

    log "INFO" "下载 ${desc}..."
    if command -v wget &>/dev/null; then
        wget -qO "$dest" "$url" || die "下载失败: $url"
    else
        curl -fsSL -o "$dest" "$url" || die "下载失败: $url"
    fi
}

download_xray() {
    local arch
    arch=$(get_arch)

    # Xray release 的文件名映射（和 get_arch 返回值不同！）
    local xray_arch
    case "$arch" in
        amd64) xray_arch="64" ;;
        arm64) xray_arch="arm64-v8a" ;;
        armv7) xray_arch="arm32-v7a" ;;
        386)   xray_arch="32" ;;
        *)     die "不支持的架构: $arch" ;;
    esac

    local version
    version=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | \
        grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')

    # fallback 如果 API 被墙
    if [[ -z "$version" ]]; then
        version="v26.3.27"
        log "WARN" "无法获取最新版本，使用 ${version}"
    fi

    log "INFO" "下载 Xray ${version} (${arch} -> ${xray_arch})..."

    local url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${xray_arch}.zip"
    local tmp="/tmp/xray-linux.zip"

    download_file "$url" "$tmp" "Xray-core"

    unzip -qo "$tmp" -d /tmp/xray-extract/ 2>/dev/null
    mv /tmp/xray-extract/xray "${INSTALL_DIR}/xray"
    chmod +x "${INSTALL_DIR}/xray"
    rm -rf "$tmp" /tmp/xray-extract/

    log "INFO" "Xray 已安装: ${INSTALL_DIR}/xray"
}

download_argo() {
    local arch
    arch=$(get_arch)

    local url
    case "$arch" in
        amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
        armv7) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
        386)   url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" ;;
        *)     die "不支持的架构下载 argo: $arch" ;;
    esac

    download_file "$url" "${INSTALL_DIR}/argo" "cloudflared"
    chmod +x "${INSTALL_DIR}/argo"
    log "INFO" "cloudflared 已安装: ${INSTALL_DIR}/argo"
}

# ============================================================
# 端口生成
# ============================================================
gen_random_port() {
    local exclude=("$@")
    local port
    while true; do
        port=$(shuf -i 10000-65000 -n 1)
        local conflict=0
        for ex in "${exclude[@]}"; do
            [[ "$port" == "$ex" ]] && conflict=1 && break
        done
        [[ $conflict -eq 0 ]] && echo "$port" && return
    done
}

generate_ports() {
    SUB_PORT=$(gen_random_port)
    ARGO_PORT=$(gen_random_port "$SUB_PORT")
    GRPC_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT")
    XHTTP_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT")
    VISION_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT" "$XHTTP_PORT")
    SS_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$VISION_PORT")
    XHTTP_H3_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$VISION_PORT" "$SS_PORT")

    log "INFO" "端口分配完成"
    log "INFO" "  订阅: ${SUB_PORT} | Argo: ${ARGO_PORT} | GRPC: ${GRPC_PORT}"
    log "INFO" "  XHTTP: ${XHTTP_PORT} | Vision: ${VISION_PORT} | SS: ${SS_PORT} | H3: ${XHTTP_H3_PORT}"
}

# ============================================================
# 生成密钥和UUID
# ============================================================
generate_keys() {
    log "STEP" "生成密钥..."

    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
           python3 -c "import uuid; print(uuid.uuid4())")

    local output
    output=$("${INSTALL_DIR}/xray" x25519 2>/dev/null)
    private_key=$(echo "$output" | awk '/Private/{print $NF}')
    public_key=$(echo "$output" | awk '/Public/{print $NF}')

    [[ -z "$private_key" ]] && die "生成 x25519 密钥失败"
    [[ -z "$public_key" ]]  && die "生成 x25519 公钥失败"

    ss_password=$(openssl rand -base64 16)
    trojan_password=$(openssl rand -hex 16)
    SUB_TOKEN=$(openssl rand -hex 16)

    log "INFO" "密钥生成完成"
    log "INFO" "  UUID: ${UUID}"
    log "INFO" "  PublicKey: ${public_key}"
}

# ============================================================
# 写入 ports.env
# ============================================================
save_ports_env() {
    cat > "${INSTALL_DIR}/ports.env" << EOF
SUB_PORT=${SUB_PORT}
ARGO_PORT=${ARGO_PORT}
GRPC_PORT=${GRPC_PORT}
XHTTP_PORT=${XHTTP_PORT}
VISION_PORT=${VISION_PORT}
SS_PORT=${SS_PORT}
XHTTP_H3_PORT=${XHTTP_H3_PORT}
UUID=${UUID}
private_key=${private_key}
public_key=${public_key}
ss_password=${ss_password}
trojan_password=${trojan_password}
SUB_TOKEN=${SUB_TOKEN}
CF_TUNNEL_TOKEN=
CF_TUNNEL_ID=
CF_TUNNEL_NAME=
CF_TUNNEL_DOMAIN=
ARGO_DOMAIN=
EOF
    chmod 600 "${INSTALL_DIR}/ports.env"
}

# ============================================================
# 生成 Xray 配置
# ============================================================
generate_config() {
    log "STEP" "生成 Xray 配置..."
    cat > "${INSTALL_DIR}/config.json" << EOF
{
  "log": {"loglevel": "warning"},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"}
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${ARGO_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID}"}],
        "decryption": "none",
        "fallbacks": [
          {"path": "/vless-argo?ed=2560", "dest": 3001},
          {"path": "/vmess-argo?ed=2560", "dest": 3002},
          {"path": "/trojan-argo?ed=2560", "dest": 3003}
        ]
      },
      "streamSettings": {"network": "tcp"},
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "127.0.0.1",
      "port": 3001,
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}"}], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vless-argo?ed=2560"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "127.0.0.1",
      "port": 3002,
      "protocol": "vmess",
      "settings": {"clients": [{"id": "${UUID}", "alterId": 0}]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vmess-argo?ed=2560"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "127.0.0.1",
      "port": 3003,
      "protocol": "trojan",
      "settings": {"clients": [{"password": "${trojan_password}"}]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/trojan-argo?ed=2560"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.nazhumi.com:443",
          "xver": 0,
          "serverNames": ["www.nazhumi.com"],
          "privateKey": "${private_key}",
          "shortIds": [""]
        },
        "xhttpSettings": {"mode": "auto"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0",
      "port": ${GRPC_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}"}], "decryption": "none"},
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.iij.ad.jp:443",
          "xver": 0,
          "serverNames": ["www.iij.ad.jp"],
          "privateKey": "${private_key}",
          "shortIds": [""]
        },
        "grpcSettings": {"serviceName": "grpc"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0",
      "port": ${VISION_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "${private_key}",
          "shortIds": [""]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0",
      "port": ${SS_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${ss_password}",
        "network": "tcp,udp"
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0",
      "port": ${XHTTP_H3_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.apple.com:443",
          "xver": 0,
          "serverNames": ["www.apple.com"],
          "privateKey": "${private_key}",
          "shortIds": [""]
        },
        "xhttpSettings": {"mode": "auto", "noSSEHeader": true}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF
    log "INFO" "配置文件已生成"
}

# ============================================================
# 订阅服务器
# ============================================================
generate_sub_server() {
    cat > "${INSTALL_DIR}/sub_server.py" << 'PYEOF'
#!/usr/bin/env python3
import os
import base64
import http.server
import socketserver
import json
import re

INSTALL_DIR = os.path.dirname(os.path.abspath(__file__))

def load_env():
    env = {}
    env_file = os.path.join(INSTALL_DIR, "ports.env")
    if os.path.exists(env_file):
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    env[k.strip()] = v.strip()
    return env

def get_public_ip():
    import urllib.request
    for url in ['https://api.ipify.org', 'https://ifconfig.me']:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                return r.read().decode().strip()
        except:
            continue
    return "unknown"

def get_argo_domain(env):
    if env.get('CF_TUNNEL_DOMAIN'):
        return env['CF_TUNNEL_DOMAIN']
    if env.get('CF_TUNNEL_ID'):
        return f"{env['CF_TUNNEL_ID']}.cfargotunnel.com"
    if env.get('ARGO_DOMAIN'):
        return env['ARGO_DOMAIN']
    log_file = os.path.join(INSTALL_DIR, "argo.log")
    if os.path.exists(log_file):
        with open(log_file) as f:
            for line in f:
                m = re.search(r'https://([a-z0-9\-]+\.trycloudflare\.com)', line)
                if m:
                    return m.group(1)
    return ""

def generate_links(env, ip):
    uuid = env.get('UUID', '')
    public_key = env.get('public_key', '')
    ss_password = env.get('ss_password', '')
    trojan_password = env.get('trojan_password', '')
    grpc_port = env.get('GRPC_PORT', '')
    xhttp_port = env.get('XHTTP_PORT', '')
    vision_port = env.get('VISION_PORT', '')
    ss_port = env.get('SS_PORT', '')
    xhttp_h3_port = env.get('XHTTP_H3_PORT', '')
    argo_domain = get_argo_domain(env)
    cdn = "cdns.doon.eu.org"
    name = ip

    links = []

    # 1. VLESS TCP Vision Reality
    links.append(
        f"vless://{uuid}@{ip}:{vision_port}?"
        f"encryption=none&flow=xtls-rprx-vision&security=reality"
        f"&sni=www.microsoft.com&fp=chrome&pbk={public_key}"
        f"&type=tcp#{name}-Vision-Reality"
    )

    # 2. VLESS XHTTP Reality
    links.append(
        f"vless://{uuid}@{ip}:{xhttp_port}?"
        f"encryption=none&security=reality&sni=www.nazhumi.com"
        f"&fp=chrome&pbk={public_key}&allowInsecure=1"
        f"&type=xhttp&mode=auto#{name}-XHTTP-Reality"
    )

    # 3. VLESS gRPC Reality
    links.append(
        f"vless://{uuid}@{ip}:{grpc_port}?"
        f"encryption=none&security=reality&sni=www.iij.ad.jp"
        f"&fp=chrome&pbk={public_key}&allowInsecure=1"
        f"&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#{name}-gRPC-Reality"
    )

    # 4. VLESS XHTTP H3 Reality
    links.append(
        f"vless://{uuid}@{ip}:{xhttp_h3_port}?"
        f"encryption=none&security=reality&sni=www.apple.com"
        f"&fp=chrome&pbk={public_key}&allowInsecure=1"
        f"&type=xhttp&mode=auto#{name}-XHTTP-H3-Reality"
    )

    # 5. Shadowsocks 2022
    ss_cred = base64.b64encode(
        f"2022-blake3-aes-128-gcm:{ss_password}".encode()
    ).decode()
    links.append(f"ss://{ss_cred}@{ip}:{ss_port}#{name}-SS2022")

    if argo_domain:
        # 6. VLESS WS Argo
        links.append(
            f"vless://{uuid}@{cdn}:443?"
            f"encryption=none&security=tls&sni={argo_domain}"
            f"&fp=chrome&type=ws&host={argo_domain}"
            f"&path=%2Fvless-argo%3Fed%3D2560#{name}-VLESS-WS-Argo"
        )

        # 7. VMess WS Argo
        vmess_obj = {
            "v":"2","ps":f"{name}-VMess-WS-Argo","add":cdn,
            "port":"443","id":uuid,"aid":"0","scy":"none",
            "net":"ws","type":"none","host":argo_domain,
            "path":"/vmess-argo?ed=2560","tls":"tls",
            "sni":argo_domain,"alpn":"","fp":"chrome"
        }
        vmess_b64 = base64.b64encode(json.dumps(vmess_obj).encode()).decode()
        links.append(f"vmess://{vmess_b64}")

        # 8. Trojan WS Argo
        links.append(
            f"trojan://{trojan_password}@{cdn}:443?"
            f"security=tls&sni={argo_domain}&fp=chrome"
            f"&type=ws&host={argo_domain}"
            f"&path=%2Ftrojan-argo%3Fed%3D2560#{name}-Trojan-WS-Argo"
        )

    return "\n".join(links)

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        env = load_env()
        token = env.get('SUB_TOKEN', '')
        expected_path = f"/{token}"

        if self.path != expected_path:
            self.send_response(404)
            self.end_headers()
            return

        ip = get_public_ip()
        links = generate_links(env, ip)
        content = base64.b64encode(links.encode()).decode()

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content.encode())

if __name__ == "__main__":
    env = load_env()
    port = int(env.get('SUB_PORT', 49023))
    with socketserver.TCPServer(("0.0.0.0", port), SubHandler) as httpd:
        httpd.serve_forever()
PYEOF
    chmod +x "${INSTALL_DIR}/sub_server.py"
}

# ============================================================
# systemd 强化服务
# ============================================================
generate_systemd_services() {
    local TUNNEL_CMD
    source "${INSTALL_DIR}/ports.env"

    if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
        TUNNEL_CMD="${INSTALL_DIR}/argo tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}"
    else
        TUNNEL_CMD="${INSTALL_DIR}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
    fi

    if is_root; then
        local SVC_DIR="/etc/systemd/system"

        # 删除 override
        rm -rf "${SVC_DIR}/xray.service.d" 2>/dev/null
        rm -rf "${SVC_DIR}/tunnel.service.d" 2>/dev/null

        cat > "${SVC_DIR}/xray.service" << EOF
[Unit]
Description=Xray Service (Immortal)
After=network.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${INSTALL_DIR}/xray run -c ${INSTALL_DIR}/config.json
Restart=always
RestartSec=3
OOMScoreAdjust=-1000
OOMPolicy=continue
LimitNOFILE=65535
LimitNPROC=65535
StandardOutput=append:${INSTALL_DIR}/xray.log
StandardError=append:${INSTALL_DIR}/xray.log

[Install]
WantedBy=multi-user.target
EOF

        cat > "${SVC_DIR}/tunnel.service" << EOF
[Unit]
Description=Cloudflare Tunnel (Immortal)
After=network.target xray.service
Wants=xray.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${TUNNEL_CMD}
Restart=always
RestartSec=3
OOMScoreAdjust=-900
OOMPolicy=continue
LimitNOFILE=65535
StandardOutput=append:${INSTALL_DIR}/argo.log
StandardError=append:${INSTALL_DIR}/argo.log

[Install]
WantedBy=multi-user.target
EOF

        cat > "${SVC_DIR}/xray-sub.service" << EOF
[Unit]
Description=Xray Subscription Service (Immortal)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$(command -v python3) ${INSTALL_DIR}/sub_server.py
Restart=always
RestartSec=3
OOMScoreAdjust=-800
StandardOutput=append:${INSTALL_DIR}/sub.log
StandardError=append:${INSTALL_DIR}/sub.log
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable xray tunnel xray-sub 2>/dev/null
        log "INFO" "systemd root 服务已配置"

    else
        # 用户级 systemd
        local USER_SVC_DIR="${HOME}/.config/systemd/user"
        mkdir -p "$USER_SVC_DIR"

        cat > "${USER_SVC_DIR}/xray.service" << EOF
[Unit]
Description=Xray Service (User)
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -c ${INSTALL_DIR}/config.json
Restart=always
RestartSec=3
StandardOutput=append:${INSTALL_DIR}/xray.log
StandardError=append:${INSTALL_DIR}/xray.log

[Install]
WantedBy=default.target
EOF

        cat > "${USER_SVC_DIR}/tunnel.service" << EOF
[Unit]
Description=Cloudflare Tunnel (User)
After=network-online.target xray.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${TUNNEL_CMD}
Restart=always
RestartSec=3
StandardOutput=append:${INSTALL_DIR}/argo.log
StandardError=append:${INSTALL_DIR}/argo.log

[Install]
WantedBy=default.target
EOF

        cat > "${USER_SVC_DIR}/xray-sub.service" << EOF
[Unit]
Description=Xray Subscription (User)
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$(command -v python3) ${INSTALL_DIR}/sub_server.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

        cat > "${USER_SVC_DIR}/xray-watchdog.service" << EOF
[Unit]
Description=Xray Watchdog

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/watchdog.sh
EOF

        cat > "${USER_SVC_DIR}/xray-watchdog.timer" << EOF
[Unit]
Description=Xray Watchdog Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF

        systemctl --user daemon-reload
        systemctl --user enable --now xray tunnel xray-sub xray-watchdog.timer 2>/dev/null
        loginctl enable-linger "$(whoami)" 2>/dev/null && \
            log "INFO" "loginctl linger 已启用" || \
            log "WARN" "建议管理员执行: sudo loginctl enable-linger $(whoami)"

        log "INFO" "systemd 用户级服务已配置"
    fi
}

generate_openrc_services() {
    source "${INSTALL_DIR}/ports.env"

    cat > /etc/init.d/xray << ORCEOF
#!/sbin/openrc-run
description="Xray Service (Immortal)"
command="${INSTALL_DIR}/xray"
command_args="run -c ${INSTALL_DIR}/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="${INSTALL_DIR}/xray.log"
error_log="${INSTALL_DIR}/xray.log"
respawn=true
respawn_delay=3
respawn_max=0
depend() { need net; }
ORCEOF
    chmod +x /etc/init.d/xray

    local TUNNEL_CMD
    if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
        TUNNEL_CMD="tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}"
    else
        TUNNEL_CMD="tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
    fi

    cat > /etc/init.d/tunnel << ORCEOF
#!/sbin/openrc-run
description="Cloudflare Tunnel (Immortal)"
command="${INSTALL_DIR}/argo"
command_args="${TUNNEL_CMD}"
command_background=true
pidfile="/run/tunnel.pid"
output_log="${INSTALL_DIR}/argo.log"
error_log="${INSTALL_DIR}/argo.log"
respawn=true
respawn_delay=3
respawn_max=0
depend() { need net xray; }
ORCEOF
    chmod +x /etc/init.d/tunnel

    rc-update add xray default 2>/dev/null
    rc-update add tunnel default 2>/dev/null
    log "INFO" "OpenRC 服务已配置"
}

generate_sysvinit_services() {
    source "${INSTALL_DIR}/ports.env"

    cat > /etc/init.d/xray << INITEOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          xray
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Xray Service
### END INIT INFO
DAEMON="${INSTALL_DIR}/xray"
DAEMON_ARGS="run -c ${INSTALL_DIR}/config.json"
PIDFILE="/var/run/xray.pid"
case "\$1" in
    start)
        start-stop-daemon --start --background --make-pidfile \
            --pidfile "\$PIDFILE" --exec "\$DAEMON" -- \$DAEMON_ARGS \
            >> "${INSTALL_DIR}/xray.log" 2>&1 ;;
    stop)
        start-stop-daemon --stop --pidfile "\$PIDFILE" --retry 10
        rm -f "\$PIDFILE" ;;
    restart) \$0 stop; sleep 2; \$0 start ;;
    *) echo "Usage: \$0 {start|stop|restart}"; exit 1 ;;
esac
INITEOF
    chmod +x /etc/init.d/xray

    if command -v update-rc.d &>/dev/null; then
        update-rc.d xray defaults
    elif command -v chkconfig &>/dev/null; then
        chkconfig --add xray && chkconfig xray on
    fi
    log "INFO" "SysVinit 服务已配置"
}

# ============================================================
# 看门狗脚本
# ============================================================
generate_watchdog() {
    cat > "${INSTALL_DIR}/watchdog.sh" << WDEOF
#!/bin/bash
INSTALL_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
LOG="\${INSTALL_DIR}/watchdog.log"
MAX_LOG=1048576

[[ -f "\$LOG" ]] && [[ \$(stat -c%s "\$LOG" 2>/dev/null || echo 0) -gt \$MAX_LOG ]] && \
    tail -200 "\$LOG" > "\${LOG}.tmp" && mv "\${LOG}.tmp" "\$LOG"

wlog() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG"; }

[[ -f "\${INSTALL_DIR}/ports.env" ]] && source "\${INSTALL_DIR}/ports.env"

IS_SYSTEMD=0
IS_USER=0
[[ -d /run/systemd/system ]] && IS_SYSTEMD=1
[[ \$(id -u) -ne 0 ]] && IS_USER=1

restart_svc() {
    local svc="\$1"
    wlog "RESTART: \${svc}"
    if [[ \$IS_SYSTEMD -eq 1 ]]; then
        if [[ \$IS_USER -eq 1 ]]; then
            systemctl --user reset-failed "\${svc}" 2>/dev/null
            systemctl --user restart "\${svc}" 2>/dev/null
        else
            systemctl reset-failed "\${svc}" 2>/dev/null
            systemctl restart "\${svc}" 2>/dev/null
        fi
    else
        case "\$svc" in
            xray)
                pkill -f "\${INSTALL_DIR}/xray" 2>/dev/null
                sleep 1
                nohup "\${INSTALL_DIR}/xray" run -c "\${INSTALL_DIR}/config.json" >> "\${INSTALL_DIR}/xray.log" 2>&1 &
                ;;
            tunnel)
                pkill -f "\${INSTALL_DIR}/argo" 2>/dev/null
                sleep 1
                if [[ -n "\${CF_TUNNEL_TOKEN:-}" ]]; then
                    nohup "\${INSTALL_DIR}/argo" tunnel --no-autoupdate run --token "\${CF_TUNNEL_TOKEN}" >> "\${INSTALL_DIR}/argo.log" 2>&1 &
                else
                    nohup "\${INSTALL_DIR}/argo" tunnel --url "http://localhost:\${ARGO_PORT}" --no-autoupdate --edge-ip-version auto --protocol http2 >> "\${INSTALL_DIR}/argo.log" 2>&1 &
                fi
                ;;
        esac
    fi
}

# 检查 xray
if ! pgrep -f "\${INSTALL_DIR}/xray" >/dev/null 2>&1; then
    wlog "ALERT: xray 进程不存在"
    restart_svc xray
    sleep 2
fi

# 检查端口
if [[ -n "\${ARGO_PORT:-}" ]]; then
    if ! ss -tlnp 2>/dev/null | grep -q ":\${ARGO_PORT} "; then
        wlog "ALERT: xray 端口 \${ARGO_PORT} 未监听"
        restart_svc xray
        sleep 2
    fi
fi

# 检查 tunnel
if ! pgrep -f "\${INSTALL_DIR}/argo" >/dev/null 2>&1; then
    wlog "ALERT: tunnel 进程不存在"
    restart_svc tunnel
fi

# 服务文件自愈 (root systemd)
if [[ \$IS_SYSTEMD -eq 1 && \$IS_USER -eq 0 ]]; then
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        wlog "ALERT: xray.service 丢失，重建..."
        cat > /etc/systemd/system/xray.service << 'SVCEOF'
[Unit]
Description=Xray Service (Immortal)
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=INSTALL_DIR_PLACEHOLDER/xray run -c INSTALL_DIR_PLACEHOLDER/config.json
Restart=always
RestartSec=3
OOMScoreAdjust=-1000
[Install]
WantedBy=multi-user.target
SVCEOF
        sed -i "s|INSTALL_DIR_PLACEHOLDER|\${INSTALL_DIR}|g" /etc/systemd/system/xray.service
        systemctl daemon-reload && systemctl enable --now xray
        wlog "REPAIR: xray.service 已重建"
    fi
fi

# cron 自愈（仅在 crontab 可用时）
if command -v crontab &>/dev/null; then
    if ! crontab -l 2>/dev/null | grep -q "watchdog.sh"; then
        (crontab -l 2>/dev/null; echo "* * * * * \${INSTALL_DIR}/watchdog.sh >/dev/null 2>&1") | crontab - 2>/dev/null 2>/dev/null || true
    fi
    if ! crontab -l 2>/dev/null | grep -q "xray-boot.sh"; then
        (crontab -l 2>/dev/null; echo "@reboot sleep 10 && \${INSTALL_DIR}/xray-boot.sh >/dev/null 2>&1") | crontab - 2>/dev/null 2>/dev/null || true
    fi
fi

WDEOF
    chmod +x "${INSTALL_DIR}/watchdog.sh"
}

# ============================================================
# 开机启动脚本
# ============================================================
generate_boot_script() {
    local INIT_SYS
    INIT_SYS=$(detect_init_system)

    cat > "${INSTALL_DIR}/xray-boot.sh" << 'BOOTEOF'
#!/bin/bash
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="${INSTALL_DIR}/boot.log"
wlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] BOOT: $1" >> "$LOG"; }
wlog "启动脚本执行"

[[ -f "${INSTALL_DIR}/ports.env" ]] && source "${INSTALL_DIR}/ports.env"

for i in $(seq 1 30); do
    ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && break
    sleep 2
done

IS_ROOT=0
[[ $(id -u) -eq 0 ]] && IS_ROOT=1

if [[ -d /run/systemd/system ]]; then
    if [[ $IS_ROOT -eq 1 ]]; then
        systemctl reset-failed xray tunnel xray-sub 2>/dev/null
        systemctl start xray tunnel xray-sub 2>/dev/null
    else
        systemctl --user reset-failed xray tunnel 2>/dev/null
        systemctl --user start xray tunnel 2>/dev/null
    fi
else
    pkill -f "${INSTALL_DIR}/xray" 2>/dev/null
    pkill -f "${INSTALL_DIR}/argo" 2>/dev/null
    sleep 1
    nohup "${INSTALL_DIR}/xray" run -c "${INSTALL_DIR}/config.json" >> "${INSTALL_DIR}/xray.log" 2>&1 &
    sleep 2
    if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
        nohup "${INSTALL_DIR}/argo" tunnel --no-autoupdate run --token "${CF_TUNNEL_TOKEN}" >> "${INSTALL_DIR}/argo.log" 2>&1 &
    else
        nohup "${INSTALL_DIR}/argo" tunnel --url "http://localhost:${ARGO_PORT}" --no-autoupdate --edge-ip-version auto --protocol http2 >> "${INSTALL_DIR}/argo.log" 2>&1 &
    fi
fi
wlog "启动完毕"
BOOTEOF
    chmod +x "${INSTALL_DIR}/xray-boot.sh"
    # === crontab 相关（仅在 crontab 可用时配置）===
    if command -v crontab &>/dev/null; then
        local cron_now
        cron_now=$(crontab -l 2>/dev/null || echo "")

        local new_cron="$cron_now"
        if [[ "$new_cron" != *"xray-boot.sh"* ]]; then
            new_cron="${new_cron}"$'\n'"@reboot sleep 10 && ${INSTALL_DIR}/xray-boot.sh >/dev/null 2>&1"
        fi
        if [[ "$new_cron" != *"watchdog.sh"* ]]; then
            new_cron="${new_cron}"$'\n'"* * * * * ${INSTALL_DIR}/watchdog.sh >/dev/null 2>&1"
        fi
        if [[ "$new_cron" != *"log-clean.sh"* ]]; then
            new_cron="${new_cron}"$'\n'"0 */6 * * * ${INSTALL_DIR}/log-clean.sh >/dev/null 2>&1"
        fi

        echo "$new_cron" | grep -v '^[[:space:]]*$' | crontab - 2>/dev/null 2>/dev/null || true
        log "INFO" "crontab 已配置"
    else
        log "WARN" "crontab 不可用，跳过 cron 持久化"
    fi

    # rc.local
    if is_root; then
        if [[ -f /etc/rc.local ]]; then
            grep -q "xray-boot.sh" /etc/rc.local || \
                sed -i "/^exit 0/i ${INSTALL_DIR}/xray-boot.sh &" /etc/rc.local
        else
            cat > /etc/rc.local << EOF
#!/bin/bash
${INSTALL_DIR}/xray-boot.sh &
exit 0
EOF
            chmod +x /etc/rc.local
            [[ "$INIT_SYS" == "systemd" ]] && systemctl enable rc-local 2>/dev/null || true
        fi
    fi

    # profile.d (root) 或 .bashrc/.zshrc (user)
    if is_root; then
        cat > /etc/profile.d/xray-check.sh << EOF
#!/bin/bash
(pgrep -f "${INSTALL_DIR}/xray" >/dev/null 2>&1 || ${INSTALL_DIR}/xray-boot.sh &) >/dev/null 2>&1 &
EOF
        chmod +x /etc/profile.d/xray-check.sh
    else
        for profile in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
            [[ -f "$profile" ]] && ! grep -q "xray2go-check" "$profile" && \
                echo -e "\n# xray2go-check\n(pgrep -f \"${INSTALL_DIR}/xray\" >/dev/null 2>&1 || ${INSTALL_DIR}/xray-boot.sh >/dev/null 2>&1 &) >/dev/null 2>&1" >> "$profile"
        done

        # XDG autostart
        mkdir -p "${HOME}/.config/autostart"
        cat > "${HOME}/.config/autostart/xray2go.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Xray2go
Exec=${INSTALL_DIR}/xray-boot.sh
Hidden=true
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    fi

    log "INFO" "开机启动脚本配置完成"
}

# ============================================================
# 文件保护 (仅 root)
# ============================================================
protect_files() {
    if ! is_root; then
        log "WARN" "非 root 用户，跳过 chattr 保护"
        return
    fi

    for f in "${INSTALL_DIR}/xray" "${INSTALL_DIR}/argo" \
              "${INSTALL_DIR}/config.json" "${INSTALL_DIR}/ports.env" \
              "${INSTALL_DIR}/watchdog.sh" "${INSTALL_DIR}/xray-boot.sh"; do
        chattr -i "$f" 2>/dev/null
        chattr +i "$f" 2>/dev/null && log "INFO" "已保护: $f" || true
    done
}

unprotect_files() {
    for f in "${INSTALL_DIR}/xray" "${INSTALL_DIR}/argo" \
              "${INSTALL_DIR}/config.json" "${INSTALL_DIR}/ports.env" \
              "${INSTALL_DIR}/watchdog.sh" "${INSTALL_DIR}/xray-boot.sh"; do
        chattr -i "$f" 2>/dev/null || true
    done
}

# ============================================================
# 日志轮转
# ============================================================
setup_log_rotation() {
    if is_root && command -v logrotate &>/dev/null; then
        cat > /etc/logrotate.d/xray-2go << EOF
${INSTALL_DIR}/*.log {
    daily
    rotate 3
    size 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0644 root root
}
EOF
    fi

    cat > "${INSTALL_DIR}/log-clean.sh" << 'LCEOF'
#!/bin/bash
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
for logfile in "${INSTALL_DIR}"/*.log; do
    [[ -f "$logfile" ]] || continue
    size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    [[ $size -gt 52428800 ]] && tail -n 1000 "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
done
LCEOF
    chmod +x "${INSTALL_DIR}/log-clean.sh"

    if command -v crontab &>/dev/null; then
        local cron_now
        cron_now=$(crontab -l 2>/dev/null || echo "")
        [[ "$cron_now" != *"log-clean.sh"* ]] && \
            (echo "$cron_now"; echo "0 */6 * * * ${INSTALL_DIR}/log-clean.sh >/dev/null 2>&1") | crontab - 2>/dev/null
    fi
}

# ============================================================
# systemd timer 看门狗 (仅 root systemd)
# ============================================================
generate_systemd_timer() {
    if ! is_root || [[ $(detect_init_system) != "systemd" ]]; then return; fi

    cat > /etc/systemd/system/xray-watchdog.service << EOF
[Unit]
Description=Xray Watchdog Check
[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/watchdog.sh
EOF

    cat > /etc/systemd/system/xray-watchdog.timer << EOF
[Unit]
Description=Xray Watchdog Timer
[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now xray-watchdog.timer 2>/dev/null
    log "INFO" "systemd timer 已配置"
}

# ============================================================
# 防火墙
# ============================================================
setup_firewall() {
    if ! is_root; then return; fi

    local ports=("$SUB_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$VISION_PORT" "$SS_PORT" "$XHTTP_H3_PORT")

    if command -v ufw &>/dev/null; then
        for p in "${ports[@]}"; do
            ufw allow "${p}/tcp" >/dev/null 2>&1 || true
        done
        ufw allow "${SS_PORT}/udp" >/dev/null 2>&1 || true
        ufw allow "${XHTTP_H3_PORT}/udp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd &>/dev/null; then
        for p in "${ports[@]}"; do
            firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
        done
        firewall-cmd --permanent --add-port="${SS_PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${XHTTP_H3_PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v iptables &>/dev/null; then
        for p in "${ports[@]}"; do
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        done
        iptables -I INPUT -p udp --dport "${SS_PORT}" -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --dport "${XHTTP_H3_PORT}" -j ACCEPT 2>/dev/null || true
    fi
    log "INFO" "防火墙规则已配置"
}

# ============================================================
# Cloudflare 固定隧道
# ============================================================
setup_fixed_tunnel() {
    log "STEP" "配置 Cloudflare 固定隧道..."

    [[ -f "${INSTALL_DIR}/.env" ]] && source "${INSTALL_DIR}/.env"

    if [[ -z "${CF_API_TOKEN:-}" ]]; then
        read -rp "CF_API_TOKEN: " CF_API_TOKEN
        [[ -z "$CF_API_TOKEN" ]] && die "CF_API_TOKEN 不能为空"
    fi
    if [[ -z "${CF_ACCOUNT_ID:-}" ]]; then
        read -rp "CF_ACCOUNT_ID: " CF_ACCOUNT_ID
        [[ -z "$CF_ACCOUNT_ID" ]] && die "CF_ACCOUNT_ID 不能为空"
    fi

    CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-xray-$(hostname)-$(date +%s)}"
    local API_BASE="https://api.cloudflare.com/client/v4"
    local AUTH="-H \"Authorization: Bearer ${CF_API_TOKEN}\""
    local CT="-H \"Content-Type: application/json\""
    local tunnel_secret
    tunnel_secret=$(openssl rand -base64 32)

    local create_resp
    create_resp=$(curl -s -X POST "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${CF_TUNNEL_NAME}\",\"tunnel_secret\":\"${tunnel_secret}\"}")

    local success
    success=$(echo "$create_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)
    [[ "$success" != "True" ]] && die "创建隧道失败: $(echo "$create_resp" | head -c 200)"

    local TUNNEL_ID
    TUNNEL_ID=$(echo "$create_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['id'])")
    log "INFO" "隧道创建成功 ID: ${TUNNEL_ID}"

    source "${INSTALL_DIR}/ports.env"
    local config_payload="{\"config\":{\"originRequest\":{},\"warp-routing\":{\"enabled\":false},\"ingress\":[{\"service\":\"http://localhost:${ARGO_PORT}\"}]}}"
    if [[ -n "${CF_TUNNEL_DOMAIN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
        config_payload="{\"config\":{\"originRequest\":{},\"warp-routing\":{\"enabled\":false},\"ingress\":[{\"hostname\":\"${CF_TUNNEL_DOMAIN}\",\"service\":\"http://localhost:${ARGO_PORT}\",\"originRequest\":{}},{\"service\":\"http_status:404\"}]}}"
    fi

    curl -s -X PUT "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${config_payload}" >/dev/null

    local token_resp tunnel_token
    token_resp=$(curl -s "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
        -H "Authorization: Bearer ${CF_API_TOKEN}")
    tunnel_token=$(echo "$token_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'])" 2>/dev/null)
    [[ -z "$tunnel_token" || "$tunnel_token" == "None" ]] && die "获取 Token 失败"

    if [[ -n "${CF_TUNNEL_DOMAIN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
        curl -s -X POST "${API_BASE}/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"CNAME\",\"name\":\"${CF_TUNNEL_DOMAIN}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" >/dev/null
    fi

    unprotect_files
    sed -i "s|^CF_TUNNEL_TOKEN=.*|CF_TUNNEL_TOKEN=${tunnel_token}|" "${INSTALL_DIR}/ports.env"
    sed -i "s|^CF_TUNNEL_ID=.*|CF_TUNNEL_ID=${TUNNEL_ID}|" "${INSTALL_DIR}/ports.env"
    sed -i "s|^CF_TUNNEL_NAME=.*|CF_TUNNEL_NAME=${CF_TUNNEL_NAME}|" "${INSTALL_DIR}/ports.env"

    local argo_domain="${CF_TUNNEL_DOMAIN:-${TUNNEL_ID}.cfargotunnel.com}"
    sed -i "s|^ARGO_DOMAIN=.*|ARGO_DOMAIN=${argo_domain}|" "${INSTALL_DIR}/ports.env"

    cat > "${INSTALL_DIR}/.env" << ENVEOF
CF_API_TOKEN=${CF_API_TOKEN}
CF_ACCOUNT_ID=${CF_ACCOUNT_ID}
CF_ZONE_ID=${CF_ZONE_ID:-}
CF_TUNNEL_NAME=${CF_TUNNEL_NAME}
ENVEOF
    chmod 600 "${INSTALL_DIR}/.env"

    # 更新 tunnel 服务
    generate_systemd_services
    if [[ $(detect_init_system) == "systemd" ]]; then
        systemctl restart tunnel 2>/dev/null || systemctl --user restart tunnel 2>/dev/null
    fi

    protect_files
    log "INFO" "固定隧道配置完成: ${argo_domain}"
}

delete_fixed_tunnel() {
    [[ -f "${INSTALL_DIR}/.env" ]] && source "${INSTALL_DIR}/.env"
    source "${INSTALL_DIR}/ports.env"

    [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ACCOUNT_ID:-}" || -z "${CF_TUNNEL_ID:-}" ]] && \
        die "缺少 CF_API_TOKEN / CF_ACCOUNT_ID / CF_TUNNEL_ID"

    local API_BASE="https://api.cloudflare.com/client/v4"
    systemctl stop tunnel 2>/dev/null || systemctl --user stop tunnel 2>/dev/null || true

    curl -s -X DELETE "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/connections" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" >/dev/null
    sleep 2

    local resp
    resp=$(curl -s -X DELETE "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")

    local success
    success=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)
    if [[ "$success" == "True" ]]; then
        unprotect_files
        sed -i 's|^CF_TUNNEL_TOKEN=.*|CF_TUNNEL_TOKEN=|' "${INSTALL_DIR}/ports.env"
        sed -i 's|^CF_TUNNEL_ID=.*|CF_TUNNEL_ID=|' "${INSTALL_DIR}/ports.env"
        sed -i 's|^ARGO_DOMAIN=.*|ARGO_DOMAIN=|' "${INSTALL_DIR}/ports.env"
        protect_files
        log "INFO" "固定隧道已删除"
    else
        log "ERROR" "删除失败: $(echo "$resp" | head -c 200)"
    fi
}

# ============================================================
# 节点信息显示
# ============================================================
get_argo_domain() {
    source "${INSTALL_DIR}/ports.env"
    if [[ -n "${CF_TUNNEL_DOMAIN:-}" ]]; then
        echo "${CF_TUNNEL_DOMAIN}"
    elif [[ -n "${CF_TUNNEL_ID:-}" ]]; then
        echo "${CF_TUNNEL_ID}.cfargotunnel.com"
    elif [[ -n "${ARGO_DOMAIN:-}" ]]; then
        echo "${ARGO_DOMAIN}"
    else
        grep "trycloudflare" "${INSTALL_DIR}/argo.log" 2>/dev/null | \
            grep -oP 'https://\K[^\s|]+' | tail -1
    fi
}

print_node_info() {
    source "${INSTALL_DIR}/ports.env"
    local IP
    IP=$(curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 ip.sb || echo "unknown")
    local ARGO_DOMAIN
    ARGO_DOMAIN=$(get_argo_domain)
    local N="$IP"

    echo ""
    echo "============================================"
    echo "  Xray-2go 节点信息"
    echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  服务器: ${IP}"
    echo "  权限: $(is_root && echo 'root' || echo 'user')"
    echo "============================================"
    echo ""
    echo "【端口】"
    echo "  订阅: ${SUB_PORT}  Argo: ${ARGO_PORT}  GRPC: ${GRPC_PORT}"
    echo "  XHTTP: ${XHTTP_PORT}  Vision: ${VISION_PORT}  SS: ${SS_PORT}  H3: ${XHTTP_H3_PORT}"
    echo ""
    echo "【UUID】 ${UUID}"
    echo "【PublicKey】 ${public_key}"
    echo "【Argo域名】 ${ARGO_DOMAIN:-未获取}"
    echo ""
    echo "============================================"
    echo "  节点链接"
    echo "============================================"
    echo ""

    echo "--- 1. VLESS TCP Vision Reality ---"
    echo "vless://${UUID}@${IP}:${VISION_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${public_key}&type=tcp#${N}-Vision-Reality"
    echo ""

    echo "--- 2. VLESS XHTTP Reality ---"
    echo "vless://${UUID}@${IP}:${XHTTP_PORT}?encryption=none&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${public_key}&allowInsecure=1&type=xhttp&mode=auto#${N}-XHTTP-Reality"
    echo ""

    echo "--- 3. VLESS gRPC Reality ---"
    echo "vless://${UUID}@${IP}:${GRPC_PORT}?encryption=none&security=reality&sni=www.iij.ad.jp&fp=chrome&pbk=${public_key}&allowInsecure=1&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#${N}-gRPC-Reality"
    echo ""

    echo "--- 4. VLESS XHTTP H3 Reality ---"
    echo "vless://${UUID}@${IP}:${XHTTP_H3_PORT}?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=${public_key}&allowInsecure=1&type=xhttp&mode=auto#${N}-XHTTP-H3-Reality"
    echo ""

    echo "--- 5. Shadowsocks 2022 ---"
    local ss_b64
    ss_b64=$(echo -n "2022-blake3-aes-128-gcm:${ss_password}" | base64 -w 0)
    echo "ss://${ss_b64}@${IP}:${SS_PORT}#${N}-SS2022"
    echo ""

    if [[ -n "$ARGO_DOMAIN" ]]; then
        echo "--- 6. VLESS WS Argo ---"
        echo "vless://${UUID}@${CDN_HOST}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#${N}-VLESS-WS-Argo"
        echo ""

        echo "--- 7. VMess WS Argo ---"
        local vmess_json="{\"v\":\"2\",\"ps\":\"${N}-VMess-WS-Argo\",\"add\":\"${CDN_HOST}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"none\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_DOMAIN}\",\"path\":\"/vmess-argo?ed=2560\",\"tls\":\"tls\",\"sni\":\"${ARGO_DOMAIN}\",\"alpn\":\"\",\"fp\":\"chrome\"}"
        echo "vmess://$(echo -n "$vmess_json" | base64 -w 0)"
        echo ""

        echo "--- 8. Trojan WS Argo ---"
        echo "trojan://${trojan_password}@${CDN_HOST}:443?security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=%2Ftrojan-argo%3Fed%3D2560#${N}-Trojan-WS-Argo"
        echo ""
    fi

    echo "============================================"
    echo "  订阅链接"
    echo "============================================"
    echo "http://${IP}:${SUB_PORT}/${SUB_TOKEN}"
    echo ""
}

# ============================================================
# 不死鸟主安装
# ============================================================
setup_immortal() {
    local INIT_SYS
    INIT_SYS=$(detect_init_system)
    log "STEP" "安装不死鸟持久化... (init: ${INIT_SYS}, root: $(is_root && echo yes || echo no))"

    generate_watchdog

    if [[ "$INIT_SYS" == "systemd" ]]; then
        generate_systemd_services
        generate_systemd_timer
    elif [[ "$INIT_SYS" == "openrc" ]]; then
        is_root && generate_openrc_services
    elif [[ "$INIT_SYS" == "sysvinit" ]]; then
        is_root && generate_sysvinit_services
    fi

    generate_boot_script
    setup_log_rotation
    protect_files

    echo ""
    echo "  🐦‍🔥 不死鸟持久化已激活！"
    echo ""
    echo "  防护层:"
    [[ "$INIT_SYS" == "systemd" ]] && echo "  ✅ systemd 服务 (Restart=always + OOM保护)"
    [[ "$INIT_SYS" == "systemd" ]] && echo "  ✅ systemd timer 看门狗 (60s)"
    echo "  ✅ cron 看门狗 (每分钟)"
    echo "  ✅ 服务文件自愈"
    echo "  ✅ 多路径开机自启 (cron + rc.local + profile)"
    is_root && echo "  ✅ chattr +i 文件保护"
    echo ""
        # 兜底：无 systemd 也无 cron 的容器环境，直接后台启动看门狗循环
    if [[ $(detect_init_system) != "systemd" ]] && ! command -v crontab &>/dev/null; then
        log "WARN" "无 systemd 和 cron，启动内置看门狗循环..."
        cat > "${INSTALL_DIR}/watchdog-loop.sh" << 'LOOPEOF'
#!/bin/bash
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
while true; do
    "${INSTALL_DIR}/watchdog.sh" 2>/dev/null
    sleep 60
done
LOOPEOF
        chmod +x "${INSTALL_DIR}/watchdog-loop.sh"
        nohup "${INSTALL_DIR}/watchdog-loop.sh" >> "${INSTALL_DIR}/watchdog-loop.log" 2>&1 &
        log "INFO" "内置看门狗循环已启动 (PID: $!)"
    fi

}

# ============================================================
# 完整安装
# ============================================================
do_install() {
    INSTALL_DIR=$(get_install_dir)
    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"

    log "STEP" "==== Xray-2go Linux 安装开始 ===="
    log "INFO" "安装目录: ${INSTALL_DIR}"

    check_deps
    generate_ports
    download_xray
    download_argo
    generate_keys
    save_ports_env
    generate_config
    generate_sub_server
    setup_firewall
    setup_immortal

    # 启动服务
    local INIT_SYS
    INIT_SYS=$(detect_init_system)
    if [[ "$INIT_SYS" == "systemd" ]]; then
        if is_root; then
            systemctl restart xray tunnel xray-sub 2>/dev/null
            sleep 3
        else
            systemctl --user restart xray tunnel xray-sub 2>/dev/null
            sleep 3
        fi
    else
        "${INSTALL_DIR}/xray-boot.sh" &
        sleep 5
    fi

    # 等待 Argo 域名
    log "INFO" "等待 Argo 域名..."
    local domain=""
    for i in $(seq 1 20); do
        domain=$(grep "trycloudflare" "${INSTALL_DIR}/argo.log" 2>/dev/null | \
            grep -oP 'https://\K[^\s|]+' | tail -1)
        [[ -n "$domain" ]] && break
        sleep 2
    done

    if [[ -n "$domain" ]]; then
        unprotect_files
        sed -i "s|^ARGO_DOMAIN=.*|ARGO_DOMAIN=${domain}|" "${INSTALL_DIR}/ports.env"
        protect_files
    fi

    print_node_info
    log "INFO" "==== 安装完成 ===="
}

# ============================================================
# 卸载
# ============================================================
do_uninstall() {
    INSTALL_DIR=$(get_install_dir)
    log "STEP" "开始卸载..."

    unprotect_files

    if [[ $(detect_init_system) == "systemd" ]]; then
        if is_root; then
            systemctl stop xray-watchdog.timer xray tunnel xray-sub 2>/dev/null
            systemctl disable xray-watchdog.timer xray tunnel xray-sub 2>/dev/null
            rm -f /etc/systemd/system/xray.service \
                  /etc/systemd/system/tunnel.service \
                  /etc/systemd/system/xray-sub.service \
                  /etc/systemd/system/xray-watchdog.service \
                  /etc/systemd/system/xray-watchdog.timer
            rm -rf /etc/systemd/system/xray.service.d
            rm -rf /etc/systemd/system/tunnel.service.d
        else
            systemctl --user stop xray tunnel xray-sub xray-watchdog.timer 2>/dev/null
            systemctl --user disable xray tunnel xray-sub xray-watchdog.timer 2>/dev/null
            rm -f "${HOME}/.config/systemd/user/xray.service" \
                  "${HOME}/.config/systemd/user/tunnel.service" \
                  "${HOME}/.config/systemd/user/xray-sub.service" \
                  "${HOME}/.config/systemd/user/xray-watchdog.service" \
                  "${HOME}/.config/systemd/user/xray-watchdog.timer"
        fi
        systemctl daemon-reload 2>/dev/null
        systemctl --user daemon-reload 2>/dev/null
    fi

    if command -v rc-service &>/dev/null; then
        rc-service xray stop 2>/dev/null; rc-update del xray default 2>/dev/null
        rc-service tunnel stop 2>/dev/null; rc-update del tunnel default 2>/dev/null
        rm -f /etc/init.d/xray /etc/init.d/tunnel
    fi

    pkill -f "${INSTALL_DIR}/xray" 2>/dev/null || true
    pkill -f "${INSTALL_DIR}/argo" 2>/dev/null || true

    crontab -l 2>/dev/null | grep -v "xray" | grep -v "watchdog" | grep -v "log-clean" | crontab - 2>/dev/null 2>/dev/null

    is_root && sed -i "/xray-boot.sh/d" /etc/rc.local 2>/dev/null || true
    rm -f /etc/profile.d/xray-check.sh 2>/dev/null
    rm -f /etc/logrotate.d/xray-2go 2>/dev/null
    rm -f "${HOME}/.config/autostart/xray2go.desktop" 2>/dev/null

    for profile in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
        [[ -f "$profile" ]] && sed -i '/xray2go-check/,/^$/d' "$profile" 2>/dev/null || true
    done

    rm -rf "$INSTALL_DIR"
    echo "  🧹 卸载完成"
}

# ============================================================
# 菜单
# ============================================================
show_menu() {
    clear
    echo ""
    echo "  ╔════════════════════════════╗"
    echo "  ║   Xray-2go Linux v${SCRIPT_VERSION}    ║"
    echo "  ╚════════════════════════════╝"
    echo ""
    echo "  1) 安装"
    echo "  2) 卸载"
    echo "  3) 显示节点信息"
    echo "  4) 重启服务"
    echo "  5) 查看状态"
    echo "  6) 配置 CF 固定隧道"
    echo "  7) 删除 CF 固定隧道"
    echo "  8) 切换回临时隧道"
    echo "  9) 更新 Xray"
    echo "  0) 退出"
    echo ""
    read -rp "  请选择: " choice

    INSTALL_DIR=$(get_install_dir)

    case "$choice" in
        1) do_install ;;
        2) do_uninstall ;;
        3)
            [[ -f "${INSTALL_DIR}/ports.env" ]] && print_node_info || echo "未安装"
            ;;
        4)
            if [[ $(detect_init_system) == "systemd" ]]; then
                is_root && systemctl restart xray tunnel xray-sub || \
                    systemctl --user restart xray tunnel xray-sub
            else
                "${INSTALL_DIR}/xray-boot.sh"
            fi
            log "INFO" "服务已重启"
            ;;
        5)
            echo ""
            if [[ $(detect_init_system) == "systemd" ]]; then
                is_root && systemctl status xray tunnel --no-pager || \
                    systemctl --user status xray tunnel --no-pager
            else
                pgrep -f "${INSTALL_DIR}/xray" && echo "Xray: 运行中" || echo "Xray: 未运行"
                pgrep -f "${INSTALL_DIR}/argo" && echo "Tunnel: 运行中" || echo "Tunnel: 未运行"
            fi
            ;;
        6) setup_fixed_tunnel ;;
        7) delete_fixed_tunnel ;;
        8)
            unprotect_files
            sed -i 's|^CF_TUNNEL_TOKEN=.*|CF_TUNNEL_TOKEN=|' "${INSTALL_DIR}/ports.env"
            sed -i 's|^CF_TUNNEL_ID=.*|CF_TUNNEL_ID=|' "${INSTALL_DIR}/ports.env"
            sed -i 's|^ARGO_DOMAIN=.*|ARGO_DOMAIN=|' "${INSTALL_DIR}/ports.env"
            generate_systemd_services
            rm -f "${INSTALL_DIR}/argo.log"
            if [[ $(detect_init_system) == "systemd" ]]; then
                is_root && systemctl restart tunnel || systemctl --user restart tunnel
            fi
            protect_files
            log "INFO" "已切换回临时隧道，等待新域名..."
            sleep 8
            domain=$(grep "trycloudflare" "${INSTALL_DIR}/argo.log" 2>/dev/null | \
                grep -oP 'https://\K[^\s|]+' | tail -1)
            [[ -n "$domain" ]] && log "INFO" "新域名: ${domain}"
            ;;
        9)
            unprotect_files
            download_xray
            protect_files
            if [[ $(detect_init_system) == "systemd" ]]; then
                is_root && systemctl restart xray || systemctl --user restart xray
            fi
            log "INFO" "Xray 已更新并重启"
            ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac

    echo ""
    read -rp "  按 Enter 返回菜单..." _
    show_menu
}

# ============================================================
# 入口
# ============================================================
main() {
    case "${1:-menu}" in
        install)   INSTALL_DIR=$(get_install_dir); do_install ;;
        uninstall) INSTALL_DIR=$(get_install_dir); do_uninstall ;;
        info)      INSTALL_DIR=$(get_install_dir); print_node_info ;;
        menu)      show_menu ;;
        *)         show_menu ;;
    esac
}

main "$@"
