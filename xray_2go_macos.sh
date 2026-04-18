#!/bin/bash
# ============================================================
# Xray-2go macOS 完整脚本
# 支持: macOS 12+ (Monterey / Ventura / Sonoma / Sequoia)
# 支持: Apple Silicon (arm64) / Intel (amd64)
# 权限: 纯用户权限，无需 sudo
# 版本: 2.0
# ============================================================

set -euo pipefail

# ============================================================
# 全局变量
# ============================================================
SCRIPT_VERSION="2.0"
INSTALL_DIR="${HOME}/.xray"
PLIST_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${INSTALL_DIR}/logs"
CDN_HOST="cdns.doon.eu.org"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
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
        STEP)  echo -e "${CYAN}[${timestamp}] [STEP]${NC}  ===== $msg =====" ;;
    esac
}

die() {
    log "ERROR" "$1"
    exit 1
}

# ============================================================
# macOS 平台检测
# ============================================================
get_arch() {
    case "$(uname -m)" in
        arm64)         echo "arm64" ;;
        x86_64)        echo "amd64" ;;
        *)             die "不支持的架构: $(uname -m)" ;;
    esac
}

get_macos_version() {
    sw_vers -productVersion 2>/dev/null || echo "unknown"
}

check_macos_version() {
    local ver
    ver=$(get_macos_version)
    local major
    major=$(echo "$ver" | cut -d. -f1)
    if [[ "$major" -lt 12 ]]; then
        log "WARN" "macOS ${ver} 可能存在兼容性问题，建议 12.0+"
    else
        log "INFO" "macOS ${ver} ✅"
    fi
}

# ============================================================
# 依赖检查
# ============================================================
check_deps() {
    log "STEP" "检查依赖"

    # 检查 Homebrew（可选）
    if ! command -v brew &>/dev/null; then
        log "WARN" "未检测到 Homebrew，部分功能可能受限"
    fi

    # 必需工具检查
    local deps=("curl" "openssl" "python3" "unzip")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            die "缺少必需工具: ${dep}，请先安装 Xcode Command Line Tools: xcode-select --install"
        fi
    done

    # 检查 crontab
    if ! command -v crontab &>/dev/null; then
        log "WARN" "crontab 不可用，将跳过 cron 持久化层"
    fi

    log "INFO" "依赖检查通过"
}

# ============================================================
# 下载函数
# ============================================================
download_file() {
    local url="$1"
    local dest="$2"
    local desc="${3:-文件}"

    # 防止 Text file busy 报错，下载前先尝试停止进程并删除旧文件
    if [[ "$dest" == *"/argo" ]] || [[ "$dest" == *"/xray" ]]; then
        pkill -f "$dest" 2>/dev/null || true
    fi
    rm -f "$dest" 2>/dev/null || true

    log "INFO" "下载 ${desc}..."
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" || die "下载失败: $url"
}

download_xray() {
    local arch
    arch=$(get_arch)
    local xray_arch
    case "$arch" in
        arm64) xray_arch="arm64-v8a" ;;
        amd64) xray_arch="64" ;;
    esac

    local version
    version=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | \
        grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
    [[ -z "$version" ]] && version="v26.3.27"

    log "INFO" "下载 Xray ${version} (${arch} -> ${xray_arch})..."

    local url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-macos-${xray_arch}.zip"
    local tmp="/tmp/xray-macos.zip"
    local extract_dir="/tmp/xray-macos-extract"

    download_file "$url" "$tmp" "Xray-core for macOS"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    unzip -qo "$tmp" -d "$extract_dir"
    mv "${extract_dir}/xray" "${INSTALL_DIR}/xray"
    chmod +x "${INSTALL_DIR}/xray"
    xattr -d com.apple.quarantine "${INSTALL_DIR}/xray" 2>/dev/null || true
    rm -rf "$tmp" "$extract_dir"

    # 下载 GeoIP 和 GeoSite 数据文件
    log "INFO" "下载 GeoIP/GeoSite 数据..."
    curl -fsSL --retry 3 -o "${INSTALL_DIR}/geoip.dat"         "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" ||         curl -fsSL -o "${INSTALL_DIR}/geoip.dat"         "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat" || true

    curl -fsSL --retry 3 -o "${INSTALL_DIR}/geosite.dat"         "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" ||         curl -fsSL -o "${INSTALL_DIR}/geosite.dat"         "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat" || true

    log "INFO" "Xray 已安装: ${INSTALL_DIR}/xray"
}


download_argo() {
    local arch
    arch=$(get_arch)
    local url

    case "$arch" in
        arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64" ;;
        amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64" ;;
    esac

    download_file "$url" "${INSTALL_DIR}/argo" "cloudflared for macOS"
    chmod +x "${INSTALL_DIR}/argo"

    # 移除隔离标志
    xattr -d com.apple.quarantine "${INSTALL_DIR}/argo" 2>/dev/null || true

    log "INFO" "cloudflared 已安装: ${INSTALL_DIR}/argo"
}

# ============================================================
# 端口生成
# ============================================================
gen_random_port() {
    local exclude=("$@")
    local port
    while true; do
        port=$(python3 -c "import random; print(random.randint(10000,65000))")
        local conflict=0
        for ex in "${exclude[@]:-}"; do
            [[ "$port" == "$ex" ]] && conflict=1 && break
        done
        [[ $conflict -eq 0 ]] && echo "$port" && return
    done
}

generate_ports() {
    log "STEP" "生成随机端口"

    SUB_PORT=$(gen_random_port)
    ARGO_PORT=$(gen_random_port "$SUB_PORT")
    GRPC_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT")
    XHTTP_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT")
    VISION_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT" "$XHTTP_PORT")
    SS_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$VISION_PORT")
    XHTTP_H3_PORT=$(gen_random_port "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$VISION_PORT" "$SS_PORT")

    log "INFO" "订阅:${SUB_PORT} Argo:${ARGO_PORT} GRPC:${GRPC_PORT}"
    log "INFO" "XHTTP:${XHTTP_PORT} Vision:${VISION_PORT} SS:${SS_PORT} H3:${XHTTP_H3_PORT}"
}

# ============================================================
# 生成密钥和 UUID
# ============================================================
generate_keys() {
    log "STEP" "生成密钥"

    UUID=$(python3 -c "import uuid; print(uuid.uuid4())")

    local output
    output=$("${INSTALL_DIR}/xray" x25519 2>/dev/null)
    private_key=$(echo "$output" | awk '/Private/{print $NF}')
    public_key=$(echo "$output" | awk '/Public/{print $NF}')

    [[ -z "$private_key" ]] && die "生成 x25519 密钥失败"
    [[ -z "$public_key"  ]] && die "生成 x25519 公钥失败"

    ss_password=$(openssl rand -base64 16)
    trojan_password=$(openssl rand -hex 16)
    SUB_TOKEN=$(openssl rand -hex 16)

    log "INFO" "UUID: ${UUID}"
    log "INFO" "PublicKey: ${public_key}"
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
    log "STEP" "生成 Xray 配置"
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
          {"path": "/vless-argo?ed=2560",  "dest": 3001},
          {"path": "/vmess-argo?ed=2560",  "dest": 3002},
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
import os, base64, json, re
import http.server, socketserver

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
    for url in ['https://api.ipify.org', 'https://ifconfig.me', 'https://ip.sb']:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                return r.read().decode().strip()
        except:
            continue
    return "unknown"

def get_argo_domain(env):
    for key in ['CF_TUNNEL_DOMAIN', 'ARGO_DOMAIN']:
        if env.get(key):
            return env[key]
    if env.get('CF_TUNNEL_ID'):
        return f"{env['CF_TUNNEL_ID']}.cfargotunnel.com"
    log_file = os.path.join(INSTALL_DIR, "logs", "argo.log")
    if os.path.exists(log_file):
        with open(log_file) as f:
            for line in f:
                m = re.search(r'https://([a-z0-9\-]+\.trycloudflare\.com)', line)
                if m:
                    return m.group(1)
    return ""

def generate_links(env, ip):
    uuid          = env.get('UUID', '')
    public_key    = env.get('public_key', '')
    ss_password   = env.get('ss_password', '')
    trojan_pw     = env.get('trojan_password', '')
    grpc_port     = env.get('GRPC_PORT', '')
    xhttp_port    = env.get('XHTTP_PORT', '')
    vision_port   = env.get('VISION_PORT', '')
    ss_port       = env.get('SS_PORT', '')
    h3_port       = env.get('XHTTP_H3_PORT', '')
    argo_domain   = get_argo_domain(env)
    cdn           = "cdns.doon.eu.org"
    n             = ip
    links         = []

    # 1. VLESS TCP Vision Reality
    links.append(
        f"vless://{uuid}@{ip}:{vision_port}?"
        f"encryption=none&flow=xtls-rprx-vision&security=reality"
        f"&sni=www.microsoft.com&fp=chrome&pbk={public_key}"
        f"&type=tcp#{n}-Vision-Reality"
    )
    # 2. VLESS XHTTP Reality
    links.append(
        f"vless://{uuid}@{ip}:{xhttp_port}?"
        f"encryption=none&security=reality&sni=www.nazhumi.com"
        f"&fp=chrome&pbk={public_key}&allowInsecure=1"
        f"&type=xhttp&mode=auto#{n}-XHTTP-Reality"
    )
    # 3. VLESS gRPC Reality
    links.append(
        f"vless://{uuid}@{ip}:{grpc_port}?"
        f"encryption=none&security=reality&sni=www.iij.ad.jp"
        f"&fp=chrome&pbk={public_key}&allowInsecure=1"
        f"&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#{n}-gRPC-Reality"
    )
    # 4. VLESS XHTTP H3 Reality
    links.append(
        f"vless://{uuid}@{ip}:{h3_port}?"
        f"encryption=none&security=reality&sni=www.apple.com"
        f"&fp=chrome&pbk={public_key}&allowInsecure=1"
        f"&type=xhttp&mode=auto#{n}-XHTTP-H3-Reality"
    )
    # 5. Shadowsocks 2022
    ss_cred = base64.b64encode(
        f"2022-blake3-aes-128-gcm:{ss_password}".encode()
    ).decode()
    links.append(f"ss://{ss_cred}@{ip}:{ss_port}#{n}-SS2022")

    if argo_domain:
        # 6. VLESS WS Argo
        links.append(
            f"vless://{uuid}@{cdn}:443?"
            f"encryption=none&security=tls&sni={argo_domain}"
            f"&fp=chrome&type=ws&host={argo_domain}"
            f"&path=%2Fvless-argo%3Fed%3D2560#{n}-VLESS-WS-Argo"
        )
        # 7. VMess WS Argo
        vmess_obj = {
            "v":"2","ps":f"{n}-VMess-WS-Argo","add":cdn,
            "port":"443","id":uuid,"aid":"0","scy":"none",
            "net":"ws","type":"none","host":argo_domain,
            "path":"/vmess-argo?ed=2560","tls":"tls",
            "sni":argo_domain,"alpn":"","fp":"chrome"
        }
        vmess_b64 = base64.b64encode(json.dumps(vmess_obj).encode()).decode()
        links.append(f"vmess://{vmess_b64}")
        # 8. Trojan WS Argo
        links.append(
            f"trojan://{trojan_pw}@{cdn}:443?"
            f"security=tls&sni={argo_domain}&fp=chrome"
            f"&type=ws&host={argo_domain}"
            f"&path=%2Ftrojan-argo%3Fed%3D2560#{n}-Trojan-WS-Argo"
        )

    return "\n".join(links)

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_GET(self):
        env   = load_env()
        token = env.get('SUB_TOKEN', '')
        if self.path != f"/{token}":
            self.send_response(404); self.end_headers(); return
        ip      = get_public_ip()
        links   = generate_links(env, ip)
        content = base64.b64encode(links.encode()).decode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content.encode())

if __name__ == "__main__":
    env  = load_env()
    port = int(env.get('SUB_PORT', 49023))
    with socketserver.TCPServer(("0.0.0.0", port), SubHandler) as httpd:
        httpd.serve_forever()
PYEOF
    chmod +x "${INSTALL_DIR}/sub_server.py"
}

# ============================================================
# LaunchAgent plist 生成
# ============================================================
get_tunnel_args_plist() {
    source "${INSTALL_DIR}/ports.env"
    if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
        cat << EOF
        <string>tunnel</string>
        <string>--no-autoupdate</string>
        <string>run</string>
        <string>--token</string>
        <string>${CF_TUNNEL_TOKEN}</string>
EOF
    else
        cat << EOF
        <string>tunnel</string>
        <string>--url</string>
        <string>http://localhost:${ARGO_PORT}</string>
        <string>--no-autoupdate</string>
        <string>--edge-ip-version</string>
        <string>auto</string>
        <string>--protocol</string>
        <string>http2</string>
EOF
    fi
}

generate_launch_agents() {
    log "STEP" "生成 LaunchAgent plist"
    mkdir -p "$PLIST_DIR" "$LOG_DIR"
    source "${INSTALL_DIR}/ports.env"

    # --- Xray ---
    cat > "${PLIST_DIR}/com.xray2go.xray.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xray2go.xray</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/xray</string>
        <string>run</string>
        <string>-c</string>
        <string>${INSTALL_DIR}/config.json</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>NetworkState</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>3</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/xray.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/xray-error.log</string>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>65535</integer>
    </dict>
    <key>HardResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>65535</integer>
    </dict>
    <key>Nice</key>
    <integer>-10</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF

    # --- Tunnel ---
    local tunnel_args
    tunnel_args=$(get_tunnel_args_plist)

    cat > "${PLIST_DIR}/com.xray2go.tunnel.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xray2go.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/argo</string>
${tunnel_args}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>NetworkState</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/argo.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/argo-error.log</string>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
</dict>
</plist>
EOF

    # --- 订阅服务 ---
    cat > "${PLIST_DIR}/com.xray2go.sub.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xray2go.sub</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(command -v python3)</string>
        <string>${INSTALL_DIR}/sub_server.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>3</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/sub.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/sub-error.log</string>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
</dict>
</plist>
EOF

    # --- 看门狗 ---
    cat > "${PLIST_DIR}/com.xray2go.watchdog.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xray2go.watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/watchdog.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/watchdog.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/watchdog.log</string>
</dict>
</plist>
EOF

    log "INFO" "LaunchAgent plist 已生成"
}

load_launch_agents() {
    log "STEP" "加载 LaunchAgent"
    local plists=(
        "com.xray2go.xray"
        "com.xray2go.tunnel"
        "com.xray2go.sub"
        "com.xray2go.watchdog"
    )
    for label in "${plists[@]}"; do
        launchctl unload "${PLIST_DIR}/${label}.plist" 2>/dev/null || true
        launchctl load -w "${PLIST_DIR}/${label}.plist" 2>/dev/null && \
            log "INFO" "已加载: ${label}" || \
            log "WARN" "加载失败: ${label}"
    done
}

unload_launch_agents() {
    local plists=(
        "com.xray2go.xray"
        "com.xray2go.tunnel"
        "com.xray2go.sub"
        "com.xray2go.watchdog"
    )
    for label in "${plists[@]}"; do
        launchctl unload "${PLIST_DIR}/${label}.plist" 2>/dev/null || true
        rm -f "${PLIST_DIR}/${label}.plist"
    done
    log "INFO" "LaunchAgent 已全部卸载"
}

# ============================================================
# 看门狗脚本（含 plist 自愈）
# ============================================================
generate_watchdog() {
    log "STEP" "生成看门狗脚本"

    cat > "${INSTALL_DIR}/watchdog.sh" << 'WDEOF'
#!/bin/bash
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${INSTALL_DIR}/logs"
LOG="${LOG_DIR}/watchdog.log"

mkdir -p "$LOG_DIR"

# 日志轮转 2MB
if [[ -f "$LOG" ]]; then
    size=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
    if [[ $size -gt 2097152 ]]; then
        tail -200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
fi

wlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

[[ -f "${INSTALL_DIR}/ports.env" ]] && source "${INSTALL_DIR}/ports.env"

rebuild_plist() {
    local label="$1"
    local plist_file="${PLIST_DIR}/${label}.plist"
    wlog "ALERT: ${label}.plist 丢失，正在重建..."

    case "$label" in
        com.xray2go.xray)
            cat > "$plist_file" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/xray</string>
        <string>run</string><string>-c</string>
        <string>${INSTALL_DIR}/config.json</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>3</integer>
    <key>StandardOutPath</key><string>${LOG_DIR}/xray.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/xray-error.log</string>
</dict>
</plist>
PEOF
            ;;
        com.xray2go.tunnel)
            local t_args
            if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
                t_args="<string>tunnel</string><string>--no-autoupdate</string><string>run</string><string>--token</string><string>${CF_TUNNEL_TOKEN}</string>"
            else
                t_args="<string>tunnel</string><string>--url</string><string>http://localhost:${ARGO_PORT}</string><string>--no-autoupdate</string><string>--edge-ip-version</string><string>auto</string><string>--protocol</string><string>http2</string>"
            fi
            cat > "$plist_file" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/argo</string>
        ${t_args}
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>${LOG_DIR}/argo.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/argo-error.log</string>
</dict>
</plist>
PEOF
            ;;
        com.xray2go.watchdog)
            cat > "$plist_file" << PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array><string>${INSTALL_DIR}/watchdog.sh</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>60</integer>
    <key>StandardOutPath</key><string>${LOG_DIR}/watchdog.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/watchdog.log</string>
</dict>
</plist>
PEOF
            ;;
    esac

    launchctl load -w "$plist_file" 2>/dev/null && \
        wlog "REPAIR: ${label} 已重建并加载" || \
        wlog "ERROR: ${label} 加载失败"
}

# === 检查 1: Xray 进程 ===
if ! pgrep -f "${INSTALL_DIR}/xray" >/dev/null 2>&1; then
    wlog "ALERT: Xray 进程不存在"
    if [[ -f "${PLIST_DIR}/com.xray2go.xray.plist" ]]; then
        launchctl unload "${PLIST_DIR}/com.xray2go.xray.plist" 2>/dev/null
        launchctl load -w "${PLIST_DIR}/com.xray2go.xray.plist" 2>/dev/null
        wlog "REPAIR: 重新加载 xray LaunchAgent"
    else
        nohup "${INSTALL_DIR}/xray" run -c "${INSTALL_DIR}/config.json" \
            >> "${LOG_DIR}/xray.log" 2>&1 &
        wlog "REPAIR: 直接启动 xray PID=$!"
    fi
    sleep 2
fi

# === 检查 2: Xray 端口 ===
if [[ -n "${ARGO_PORT:-}" ]]; then
    if ! lsof -iTCP:${ARGO_PORT} -sTCP:LISTEN >/dev/null 2>&1; then
        wlog "ALERT: Xray 端口 ${ARGO_PORT} 未监听，强制重启"
        pkill -f "${INSTALL_DIR}/xray" 2>/dev/null || true
        sleep 3
    fi
fi

# === 检查 3: Tunnel 进程 ===
if ! pgrep -f "${INSTALL_DIR}/argo" >/dev/null 2>&1; then
    wlog "ALERT: Tunnel 进程不存在"
    if [[ -f "${PLIST_DIR}/com.xray2go.tunnel.plist" ]]; then
        launchctl unload "${PLIST_DIR}/com.xray2go.tunnel.plist" 2>/dev/null
        launchctl load -w "${PLIST_DIR}/com.xray2go.tunnel.plist" 2>/dev/null
        wlog "REPAIR: 重新加载 tunnel LaunchAgent"
    else
        if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
            nohup "${INSTALL_DIR}/argo" tunnel --no-autoupdate run \
                --token "${CF_TUNNEL_TOKEN}" \
                >> "${LOG_DIR}/argo.log" 2>&1 &
        else
            nohup "${INSTALL_DIR}/argo" tunnel \
                --url "http://localhost:${ARGO_PORT}" \
                --no-autoupdate --edge-ip-version auto --protocol http2 \
                >> "${LOG_DIR}/argo.log" 2>&1 &
        fi
        wlog "REPAIR: 直接启动 tunnel PID=$!"
    fi
fi

# === 检查 4: plist 自愈 ===
for label in com.xray2go.xray com.xray2go.tunnel com.xray2go.watchdog; do
    [[ ! -f "${PLIST_DIR}/${label}.plist" ]] && rebuild_plist "$label"
done

# === 检查 5: cron 自愈 ===
if command -v crontab &>/dev/null; then
    if ! crontab -l 2>/dev/null | grep -q "watchdog.sh"; then
        (crontab -l 2>/dev/null; \
         echo "* * * * * ${INSTALL_DIR}/watchdog.sh >/dev/null 2>&1") | crontab -
        wlog "REPAIR: cron 看门狗已恢复"
    fi
    if ! crontab -l 2>/dev/null | grep -q "xray-boot.sh"; then
        (crontab -l 2>/dev/null; \
         echo "@reboot sleep 15 && ${INSTALL_DIR}/xray-boot.sh >/dev/null 2>&1") | crontab -
        wlog "REPAIR: cron @reboot 已恢复"
    fi
fi
WDEOF

    chmod +x "${INSTALL_DIR}/watchdog.sh"
    log "INFO" "看门狗脚本已生成"
}

# ============================================================
# 开机启动脚本（多路径冗余）
# ============================================================
generate_boot_script() {
    log "STEP" "配置多路径开机自启"

    # --- 通用启动脚本 ---
    cat > "${INSTALL_DIR}/xray-boot.sh" << 'BOOTEOF'
#!/bin/bash
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${INSTALL_DIR}/logs"
LOG="${LOG_DIR}/boot.log"

mkdir -p "$LOG_DIR"
wlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] BOOT: $1" >> "$LOG"; }
wlog "启动脚本执行"

[[ -f "${INSTALL_DIR}/ports.env" ]] && source "${INSTALL_DIR}/ports.env"

# 等待网络
for i in $(seq 1 30); do
    if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        wlog "网络就绪 (${i}次)"
        break
    fi
    sleep 2
done

# 优先通过 launchctl
for label in com.xray2go.xray com.xray2go.tunnel com.xray2go.sub com.xray2go.watchdog; do
    if [[ -f "${PLIST_DIR}/${label}.plist" ]]; then
        launchctl load -w "${PLIST_DIR}/${label}.plist" 2>/dev/null
        wlog "launchctl 加载: ${label}"
    fi
done

# 等待启动
sleep 3

# 兜底：进程不存在则直接启动
if ! pgrep -f "${INSTALL_DIR}/xray" >/dev/null 2>&1; then
    nohup "${INSTALL_DIR}/xray" run -c "${INSTALL_DIR}/config.json" \
        >> "${LOG_DIR}/xray.log" 2>&1 &
    wlog "兜底启动 xray PID=$!"
fi

if ! pgrep -f "${INSTALL_DIR}/argo" >/dev/null 2>&1; then
    if [[ -n "${CF_TUNNEL_TOKEN:-}" ]]; then
        nohup "${INSTALL_DIR}/argo" tunnel --no-autoupdate run \
            --token "${CF_TUNNEL_TOKEN}" \
            >> "${LOG_DIR}/argo.log" 2>&1 &
    else
        nohup "${INSTALL_DIR}/argo" tunnel \
            --url "http://localhost:${ARGO_PORT}" \
            --no-autoupdate --edge-ip-version auto --protocol http2 \
            >> "${LOG_DIR}/argo.log" 2>&1 &
    fi
    wlog "兜底启动 tunnel PID=$!"
fi

wlog "启动脚本完毕"
BOOTEOF

    chmod +x "${INSTALL_DIR}/xray-boot.sh"

    # === 路径 2: crontab ===
    if command -v crontab &>/dev/null; then
        local cron_now
        cron_now=$(crontab -l 2>/dev/null || echo "")

        local new_cron="$cron_now"
        [[ "$new_cron" != *"xray-boot.sh"* ]] && \
            new_cron="${new_cron}"$'\n'"@reboot sleep 15 && ${INSTALL_DIR}/xray-boot.sh >/dev/null 2>&1"
        [[ "$new_cron" != *"watchdog.sh"* ]] && \
            new_cron="${new_cron}"$'\n'"* * * * * ${INSTALL_DIR}/watchdog.sh >/dev/null 2>&1"
        [[ "$new_cron" != *"log-clean.sh"* ]] && \
            new_cron="${new_cron}"$'\n'"0 */6 * * * ${INSTALL_DIR}/log-clean.sh >/dev/null 2>&1"

        echo "$new_cron" | grep -v '^[[:space:]]*$' | crontab -
        log "INFO" "crontab 已配置 (层2)"
    fi

    # === 路径 3: zsh/bash profile ===
    for profile in "${HOME}/.zprofile" "${HOME}/.zshrc" \
                   "${HOME}/.bash_profile" "${HOME}/.bashrc"; do
        if [[ -f "$profile" ]] || [[ "$profile" == "${HOME}/.zprofile" ]]; then
            if ! grep -q "xray2go-check" "$profile" 2>/dev/null; then
                cat >> "$profile" << PROF

# xray2go-check
(pgrep -f "${INSTALL_DIR}/xray" >/dev/null 2>&1 || \
    "${INSTALL_DIR}/xray-boot.sh" &) >/dev/null 2>&1 &
PROF
                log "INFO" "已写入 ${profile} (层3)"
            fi
        fi
    done

    # === 路径 4: Login Item (osascript) ===
    cat > "${INSTALL_DIR}/xray-login.command" << EOF
#!/bin/bash
"${INSTALL_DIR}/xray-boot.sh"
EOF
    chmod +x "${INSTALL_DIR}/xray-login.command"

    osascript -e "
        tell application \"System Events\"
            try
                delete login item \"xray2go\"
            end try
            try
                make login item at end with properties ¬
                    {path:\"${INSTALL_DIR}/xray-login.command\", ¬
                     hidden:true, name:\"xray2go\"}
            end try
        end tell
    " 2>/dev/null && log "INFO" "Login Item 已添加 (层4)" || \
        log "WARN" "Login Item 需要用户手动授权（系统设置 > 通用 > 登录项）"

    log "INFO" "多路径开机自启配置完成"
}

# ============================================================
# 日志管理
# ============================================================
generate_log_cleaner() {
    cat > "${INSTALL_DIR}/log-clean.sh" << 'LCEOF'
#!/bin/bash
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${INSTALL_DIR}/logs"
MAX_SIZE=52428800  # 50MB

for logfile in "${LOG_DIR}"/*.log; do
    [[ -f "$logfile" ]] || continue
    size=$(stat -f%z "$logfile" 2>/dev/null || echo 0)
    if [[ $size -gt $MAX_SIZE ]]; then
        tail -1000 "$logfile" > "${logfile}.tmp"
        mv "${logfile}.tmp" "$logfile"
    fi
done
LCEOF
    chmod +x "${INSTALL_DIR}/log-clean.sh"
}

# ============================================================
# Cloudflare 固定隧道
# ============================================================
setup_fixed_tunnel() {
    log "STEP" "配置 Cloudflare 固定隧道"

    [[ -f "${INSTALL_DIR}/.env" ]] && source "${INSTALL_DIR}/.env"

    if [[ -z "${CF_API_TOKEN:-}" ]]; then
        read -rp "CF_API_TOKEN: " CF_API_TOKEN
        [[ -z "$CF_API_TOKEN" ]] && die "CF_API_TOKEN 不能为空"
    fi
    if [[ -z "${CF_ACCOUNT_ID:-}" ]]; then
        read -rp "CF_ACCOUNT_ID: " CF_ACCOUNT_ID
        [[ -z "$CF_ACCOUNT_ID" ]] && die "CF_ACCOUNT_ID 不能为空"
    fi

    CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-xray-$(hostname -s)-$(date +%s)}"
    local API_BASE="https://api.cloudflare.com/client/v4"
    local tunnel_secret
    tunnel_secret=$(openssl rand -base64 32)

    local create_resp
    create_resp=$(curl -s -X POST "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${CF_TUNNEL_NAME}\",\"tunnel_secret\":\"${tunnel_secret}\"}")

    local success
    success=$(echo "$create_resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)
    [[ "$success" != "True" ]] && die "创建隧道失败: $(echo "$create_resp" | head -c 200)"

    local TUNNEL_ID
    TUNNEL_ID=$(echo "$create_resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['result']['id'])")
    log "INFO" "隧道创建成功 ID: ${TUNNEL_ID}"

    source "${INSTALL_DIR}/ports.env"
    local cfg
    if [[ -n "${CF_TUNNEL_DOMAIN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
        cfg="{\"config\":{\"originRequest\":{},\"warp-routing\":{\"enabled\":false},\"ingress\":[{\"hostname\":\"${CF_TUNNEL_DOMAIN}\",\"service\":\"http://localhost:${ARGO_PORT}\",\"originRequest\":{}},{\"service\":\"http_status:404\"}]}}"
    else
        cfg="{\"config\":{\"originRequest\":{},\"warp-routing\":{\"enabled\":false},\"ingress\":[{\"service\":\"http://localhost:${ARGO_PORT}\"}]}}"
    fi

    curl -s -X PUT "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$cfg" >/dev/null

    local token_resp tunnel_token
    token_resp=$(curl -s "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
        -H "Authorization: Bearer ${CF_API_TOKEN}")
    tunnel_token=$(echo "$token_resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['result'])" 2>/dev/null)
    [[ -z "$tunnel_token" || "$tunnel_token" == "None" ]] && die "获取 Token 失败"

    if [[ -n "${CF_TUNNEL_DOMAIN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
        curl -s -X POST "${API_BASE}/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"CNAME\",\"name\":\"${CF_TUNNEL_DOMAIN}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}" \
            >/dev/null && log "INFO" "DNS CNAME 已创建"
    fi

    # 更新配置
    local argo_domain="${CF_TUNNEL_DOMAIN:-${TUNNEL_ID}.cfargotunnel.com}"
    sed -i '' "s|^CF_TUNNEL_TOKEN=.*|CF_TUNNEL_TOKEN=${tunnel_token}|" "${INSTALL_DIR}/ports.env"
    sed -i '' "s|^CF_TUNNEL_ID=.*|CF_TUNNEL_ID=${TUNNEL_ID}|" "${INSTALL_DIR}/ports.env"
    sed -i '' "s|^CF_TUNNEL_NAME=.*|CF_TUNNEL_NAME=${CF_TUNNEL_NAME}|" "${INSTALL_DIR}/ports.env"
    sed -i '' "s|^ARGO_DOMAIN=.*|ARGO_DOMAIN=${argo_domain}|" "${INSTALL_DIR}/ports.env"

    cat > "${INSTALL_DIR}/.env" << ENVEOF
CF_API_TOKEN=${CF_API_TOKEN}
CF_ACCOUNT_ID=${CF_ACCOUNT_ID}
CF_ZONE_ID=${CF_ZONE_ID:-}
CF_TUNNEL_NAME=${CF_TUNNEL_NAME}
ENVEOF
    chmod 600 "${INSTALL_DIR}/.env"

    # 重新生成并加载 tunnel plist
    generate_launch_agents
    launchctl unload "${PLIST_DIR}/com.xray2go.tunnel.plist" 2>/dev/null || true
    launchctl load -w "${PLIST_DIR}/com.xray2go.tunnel.plist" 2>/dev/null

    log "INFO" "固定隧道配置完成: ${argo_domain}"
}

delete_fixed_tunnel() {
    log "STEP" "删除固定隧道"
    [[ -f "${INSTALL_DIR}/.env" ]] && source "${INSTALL_DIR}/.env"
    source "${INSTALL_DIR}/ports.env"

    [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ACCOUNT_ID:-}" || -z "${CF_TUNNEL_ID:-}" ]] && \
        die "缺少 CF_API_TOKEN / CF_ACCOUNT_ID / CF_TUNNEL_ID"

    local API_BASE="https://api.cloudflare.com/client/v4"
    launchctl unload "${PLIST_DIR}/com.xray2go.tunnel.plist" 2>/dev/null || true

    curl -s -X DELETE "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/connections" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" >/dev/null
    sleep 2

    local resp
    resp=$(curl -s -X DELETE \
        "${API_BASE}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    local success
    success=$(echo "$resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)

    if [[ "$success" == "True" ]]; then
        sed -i '' 's|^CF_TUNNEL_TOKEN=.*|CF_TUNNEL_TOKEN=|' "${INSTALL_DIR}/ports.env"
        sed -i '' 's|^CF_TUNNEL_ID=.*|CF_TUNNEL_ID=|' "${INSTALL_DIR}/ports.env"
        sed -i '' 's|^ARGO_DOMAIN=.*|ARGO_DOMAIN=|' "${INSTALL_DIR}/ports.env"
        log "INFO" "固定隧道已删除"
    else
        log "ERROR" "删除失败: $(echo "$resp" | head -c 200)"
    fi
}

# ============================================================
# 节点信息
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
        grep -h "trycloudflare" "${LOG_DIR}/argo.log" "${LOG_DIR}/argo-error.log" 2>/dev/null | \
            grep -oE '[a-z0-9\-]+\.trycloudflare\.com' | tail -1
    fi
}

print_node_info() {
    source "${INSTALL_DIR}/ports.env"
    local IP
    IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
         curl -s4 --max-time 5 ip.sb 2>/dev/null || echo "unknown")
    local ARGO_DOMAIN
    ARGO_DOMAIN=$(get_argo_domain)
    local N="$IP"

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║       Xray-2go macOS 节点信息            ║"
    echo "╠══════════════════════════════════════════╣"
    printf "║  时间:    %-32s║\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "║  系统:    %-32s║\n" "macOS $(get_macos_version) ($(get_arch))"
    printf "║  服务器:  %-32s║\n" "${IP}"
    echo "╠══════════════════════════════════════════╣"
    echo "║  端口信息                                ║"
    printf "║  订阅:%-6s  Argo:%-6s  GRPC:%-6s  ║\n" "$SUB_PORT" "$ARGO_PORT" "$GRPC_PORT"
    printf "║  XHTTP:%-5s  Vision:%-4s  SS:%-7s  ║\n" "$XHTTP_PORT" "$VISION_PORT" "$SS_PORT"
    printf "║  XHTTP-H3: %-31s║\n" "$XHTTP_H3_PORT"
    echo "╠══════════════════════════════════════════╣"
    printf "║  UUID: %-34s║\n" "${UUID:0:34}"
    printf "║        %-34s║\n" "${UUID:34}"
    printf "║  PubKey: %-32s║\n" "${public_key:0:32}"
    printf "║  Argo: %-34s║\n" "${ARGO_DOMAIN:-未获取}"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "=========================================="
    echo "  节点链接"
    echo "=========================================="
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
    ss_b64=$(python3 -c \
        "import base64; print(base64.b64encode(b'2022-blake3-aes-128-gcm:${ss_password}').decode())")
    echo "ss://${ss_b64}@${IP}:${SS_PORT}#${N}-SS2022"
    echo ""

    if [[ -n "${ARGO_DOMAIN:-}" ]]; then
        echo "--- 6. VLESS WS Argo ---"
        echo "vless://${UUID}@${CDN_HOST}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#${N}-VLESS-WS-Argo"
        echo ""

        echo "--- 7. VMess WS Argo ---"
        local vmess_json="{\"v\":\"2\",\"ps\":\"${N}-VMess-WS-Argo\",\"add\":\"${CDN_HOST}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"none\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_DOMAIN}\",\"path\":\"/vmess-argo?ed=2560\",\"tls\":\"tls\",\"sni\":\"${ARGO_DOMAIN}\",\"alpn\":\"\",\"fp\":\"chrome\"}"
        echo "vmess://$(python3 -c "import base64,sys; print(base64.b64encode('''${vmess_json}'''.encode()).decode())")"
        echo ""

        echo "--- 8. Trojan WS Argo ---"
        echo "trojan://${trojan_password}@${CDN_HOST}:443?security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=%2Ftrojan-argo%3Fed%3D2560#${N}-Trojan-WS-Argo"
        echo ""
    fi

    echo "=========================================="
    echo "  订阅链接"
    echo "=========================================="
    echo "http://${IP}:${SUB_PORT}/${SUB_TOKEN}"
    echo ""
}

# ============================================================
# 不死鸟持久化主函数
# ============================================================
setup_immortal() {
    log "STEP" "安装 macOS 不死鸟持久化"

    generate_watchdog
    generate_log_cleaner
    generate_launch_agents
    load_launch_agents
    generate_boot_script

    echo ""
    echo "  🐦‍🔥 macOS 不死鸟持久化已激活！"
    echo ""
    echo "  防护层:"
    echo "  ✅ 层1: LaunchAgent (KeepAlive + RunAtLoad + NetworkState)"
    echo "  ✅ 层2: cron 看门狗 (每分钟)"
    echo "  ✅ 层3: shell profile 登录检查 (.zprofile)"
    echo "  ✅ 层4: Login Item (系统登录项)"
    echo "  ✅ 层5: plist 自愈 (被删自动重建)"
    echo "  ✅ 层6: cron 条目自愈"
    echo "  ✅ 日志自动清理 (每6小时)"
    echo ""
    echo "  管理命令:"
    echo "  查看状态:  launchctl list | grep xray2go"
    echo "  查看日志:  tail -f ${LOG_DIR}/xray.log"
    echo "  手动停止:  launchctl unload ~/Library/LaunchAgents/com.xray2go.*.plist"
    echo ""
}

# ============================================================
# 状态查看
# ============================================================
show_status() {
    echo ""
    echo "=== LaunchAgent 状态 ==="
    launchctl list | grep "xray2go" || echo "  未发现 LaunchAgent"

    echo ""
    echo "=== 进程状态 ==="
    pgrep -fl "xray" | grep "${INSTALL_DIR}" || echo "  Xray: 未运行"
    pgrep -fl "argo" | grep "${INSTALL_DIR}" || echo "  Tunnel: 未运行"
    pgrep -fl "sub_server" | grep "${INSTALL_DIR}" || echo "  Sub: 未运行"

    echo ""
    echo "=== 端口监听 ==="
    source "${INSTALL_DIR}/ports.env" 2>/dev/null
    for port in "${ARGO_PORT:-}" "${VISION_PORT:-}" "${SS_PORT:-}" "${SUB_PORT:-}"; do
        [[ -z "$port" ]] && continue
        if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            echo "  :${port} ✅ 监听中"
        else
            echo "  :${port} ❌ 未监听"
        fi
    done

    echo ""
    echo "=== cron 条目 ==="
    crontab -l 2>/dev/null | grep -E "xray|watchdog|argo" || echo "  无相关 cron 条目"
    echo ""
}

# ============================================================
# 完整安装
# ============================================================
do_install() {
    log "STEP" "==== Xray-2go macOS 安装开始 ===="
    log "INFO" "安装目录: ${INSTALL_DIR}"
    log "INFO" "macOS $(get_macos_version) $(get_arch)"

    # 在执行下载和覆盖前，强制停止相关进程并删除旧文件
    if [[ -d "${INSTALL_DIR}" ]]; then
        # 卸载服务，防止看门狗立即重启进程
        unload_launch_agents 2>/dev/null || true
        pkill -f "${INSTALL_DIR}/xray" 2>/dev/null || true
        pkill -f "${INSTALL_DIR}/argo" 2>/dev/null || true
        rm -f "${INSTALL_DIR}/xray" "${INSTALL_DIR}/argo" 2>/dev/null || true
    fi

    check_macos_version
    check_deps

    mkdir -p "$INSTALL_DIR" "$LOG_DIR"
    chmod 700 "$INSTALL_DIR"

    generate_ports
    download_xray
    download_argo
    generate_keys
    save_ports_env
    generate_config
    generate_sub_server
    setup_immortal

    # 等待 Argo 域名
    log "INFO" "等待 Argo 域名 (最多 40 秒)..."
    local domain=""
    for i in $(seq 1 20); do
        domain=$(grep -h "trycloudflare" \
            "${LOG_DIR}/argo.log" "${LOG_DIR}/argo-error.log" 2>/dev/null | \
            grep -oE '[a-z0-9\-]+\.trycloudflare\.com' | tail -1)
        [[ -n "$domain" ]] && break
        sleep 2
    done

    if [[ -n "$domain" ]]; then
        sed -i '' "s|^ARGO_DOMAIN=.*|ARGO_DOMAIN=${domain}|" "${INSTALL_DIR}/ports.env"
        log "INFO" "Argo 域名: ${domain}"
    else
        log "WARN" "未获取到 Argo 域名，稍后可通过菜单选项 3 查看"
    fi

    print_node_info
    log "INFO" "==== macOS 安装完成 ===="
}

# ============================================================
# 完整卸载
# ============================================================
do_uninstall() {
    log "STEP" "开始卸载..."

    # 停止进程
    pkill -f "${INSTALL_DIR}/xray" 2>/dev/null || true
    pkill -f "${INSTALL_DIR}/argo" 2>/dev/null || true

    # 卸载 LaunchAgents
    unload_launch_agents

    # 清理 crontab
    if command -v crontab &>/dev/null; then
        crontab -l 2>/dev/null | \
            grep -v "xray" | grep -v "watchdog" | grep -v "log-clean" | \
            crontab - 2>/dev/null || true
    fi

    # 清理 shell profile
    for profile in "${HOME}/.zprofile" "${HOME}/.zshrc" \
                   "${HOME}/.bash_profile" "${HOME}/.bashrc"; do
        if [[ -f "$profile" ]]; then
            local tmp
            tmp=$(mktemp)
            # 删除 xray2go-check 块（注释行 + 后续 2 行）
            awk '/# xray2go-check/{skip=3} skip>0{skip--; next} 1' "$profile" > "$tmp"
            mv "$tmp" "$profile"
        fi
    done

    # 移除 Login Item
    osascript -e '
        tell application "System Events"
            try
                delete login item "xray2go"
            end try
        end tell
    ' 2>/dev/null || true

    # 删除安装目录
    rm -rf "$INSTALL_DIR"

    echo ""
    echo "  🧹 macOS 卸载完成"
    echo "  所有 LaunchAgent / cron / profile / Login Item 已清除"
    echo ""
}

# ============================================================
# 菜单
# ============================================================
show_menu() {
    clear
    echo ""
    echo "  ╔════════════════════════════════╗"
    echo "  ║   Xray-2go macOS v${SCRIPT_VERSION}        ║"
    echo "  ║   $(get_macos_version) $(get_arch)          ║"
    echo "  ╚════════════════════════════════╝"
    echo ""
    echo "  1) 安装"
    echo "  2) 卸载"
    echo "  3) 显示节点信息"
    echo "  4) 重启所有服务"
    echo "  5) 查看状态"
    echo "  6) 配置 CF 固定隧道"
    echo "  7) 删除 CF 固定隧道"
    echo "  8) 切换回临时隧道"
    echo "  9) 更新 Xray"
    echo "  0) 退出"
    echo ""
    read -rp "  请选择: " choice

    case "$choice" in
        1) do_install ;;
        2)
            read -rp "  确认卸载? [y/N]: " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && do_uninstall || echo "已取消"
            ;;
        3)
            [[ -f "${INSTALL_DIR}/ports.env" ]] && print_node_info || echo "  未安装"
            ;;
        4)
            log "INFO" "重启所有服务..."
            for label in com.xray2go.xray com.xray2go.tunnel com.xray2go.sub; do
                launchctl unload "${PLIST_DIR}/${label}.plist" 2>/dev/null || true
                launchctl load -w "${PLIST_DIR}/${label}.plist" 2>/dev/null
            done
            log "INFO" "重启完成"
            ;;
        5) show_status ;;
        6) setup_fixed_tunnel ;;
        7) delete_fixed_tunnel ;;
        8)
            log "INFO" "切换回临时隧道..."
            sed -i '' 's|^CF_TUNNEL_TOKEN=.*|CF_TUNNEL_TOKEN=|' "${INSTALL_DIR}/ports.env"
            sed -i '' 's|^CF_TUNNEL_ID=.*|CF_TUNNEL_ID=|' "${INSTALL_DIR}/ports.env"
            sed -i '' 's|^ARGO_DOMAIN=.*|ARGO_DOMAIN=|' "${INSTALL_DIR}/ports.env"
            rm -f "${LOG_DIR}/argo.log" "${LOG_DIR}/argo-error.log"
            generate_launch_agents
            launchctl unload "${PLIST_DIR}/com.xray2go.tunnel.plist" 2>/dev/null || true
            launchctl load -w "${PLIST_DIR}/com.xray2go.tunnel.plist" 2>/dev/null
            log "INFO" "等待临时域名..."
            sleep 10
            local domain
            domain=$(grep -h "trycloudflare" \
                "${LOG_DIR}/argo.log" "${LOG_DIR}/argo-error.log" 2>/dev/null | \
                grep -oE '[a-z0-9\-]+\.trycloudflare\.com' | tail -1)
            [[ -n "$domain" ]] && {
                sed -i '' "s|^ARGO_DOMAIN=.*|ARGO_DOMAIN=${domain}|" "${INSTALL_DIR}/ports.env"
                log "INFO" "新域名: ${domain}"
            }
            ;;
        9)
            log "INFO" "更新 Xray..."
            launchctl unload "${PLIST_DIR}/com.xray2go.xray.plist" 2>/dev/null || true
            pkill -f "${INSTALL_DIR}/xray" 2>/dev/null || true
            sleep 1
            download_xray
            launchctl load -w "${PLIST_DIR}/com.xray2go.xray.plist" 2>/dev/null
            log "INFO" "Xray 已更新"
            ;;
        0) exit 0 ;;
        *) echo "  无效选择" ;;
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
        install)   do_install ;;
        uninstall) do_uninstall ;;
        info)      [[ -f "${INSTALL_DIR}/ports.env" ]] && print_node_info || echo "未安装" ;;
        status)    show_status ;;
        restart)
            for label in com.xray2go.xray com.xray2go.tunnel com.xray2go.sub; do
                launchctl unload "${PLIST_DIR}/${label}.plist" 2>/dev/null || true
                launchctl load -w "${PLIST_DIR}/${label}.plist" 2>/dev/null
            done
            ;;
        menu|*)    show_menu ;;
    esac
}

main "$@"
