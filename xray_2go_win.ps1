# ============================================================
# Xray-2go Windows 完整脚本
# 支持: Windows 10/11 (x64 / arm64)
# 权限: 纯用户权限，无需管理员
# 运行: powershell -ExecutionPolicy Bypass -File xray2go.ps1
# 版本: 2.0
# ============================================================

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# 全局变量
# ============================================================
$SCRIPT_VERSION  = "2.0"
$INSTALL_DIR     = Join-Path $env:APPDATA "xray2go"
$LOG_DIR         = Join-Path $INSTALL_DIR "logs"
$CDN_HOST        = "cdns.doon.eu.org"
$PORTS_ENV       = Join-Path $INSTALL_DIR "ports.env"
$DOT_ENV         = Join-Path $INSTALL_DIR ".env"

# 颜色别名
function Write-Info  { param([string]$m) Write-Host "$(Get-Timestamp) [INFO]  $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "$(Get-Timestamp) [WARN]  $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "$(Get-Timestamp) [ERROR] $m" -ForegroundColor Red }
function Write-Step  { param([string]$m) Write-Host "$(Get-Timestamp) [STEP]  ===== $m =====" -ForegroundColor Cyan }
function Get-Timestamp { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }

function Die {
    param([string]$Message)
    Write-Err $Message
    exit 1
}

# ============================================================
# 平台检测
# ============================================================
function Get-Arch {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($arch) {
        "X64"   { return "amd64" }
        "Arm64" { return "arm64" }
        default { Die "不支持的架构: $arch" }
    }
}

function Get-WinVersion {
    $v = [System.Environment]::OSVersion.Version
    return "$($v.Major).$($v.Minor).$($v.Build)"
}

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================
# 工具函数
# ============================================================
function Load-Env {
    $env_table = @{}
    if (Test-Path $PORTS_ENV) {
        Get-Content $PORTS_ENV | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
                $env_table[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }
    }
    return $env_table
}

function Save-Env {
    param([hashtable]$EnvTable)
    $lines = $EnvTable.GetEnumerator() | Sort-Object Key | ForEach-Object {
        "$($_.Key)=$($_.Value)"
    }
    $lines | Set-Content $PORTS_ENV -Encoding UTF8
}

function Update-EnvKey {
    param([string]$Key, [string]$Value)
    $content = Get-Content $PORTS_ENV -Raw -Encoding UTF8
    if ($content -match "(?m)^${Key}=.*$") {
        $content = $content -replace "(?m)^${Key}=.*$", "${Key}=${Value}"
    } else {
        $content += "`n${Key}=${Value}"
    }
    $content | Set-Content $PORTS_ENV -Encoding UTF8 -NoNewline
}

function Get-PublicIP {
    $urls = @(
        "https://api.ipify.org",
        "https://ifconfig.me",
        "https://ip.sb"
    )
    foreach ($url in $urls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing `
                -TimeoutSec 5 -ErrorAction Stop
            return $resp.Content.Trim()
        } catch { continue }
    }
    return "unknown"
}

function Get-ArgoDomain {
    param([hashtable]$Env)
    if ($Env["CF_TUNNEL_DOMAIN"]) { return $Env["CF_TUNNEL_DOMAIN"] }
    if ($Env["ARGO_DOMAIN"])      { return $Env["ARGO_DOMAIN"] }
    if ($Env["CF_TUNNEL_ID"])     { return "$($Env['CF_TUNNEL_ID']).cfargotunnel.com" }

    # 从日志提取
    $logFile = Join-Path $LOG_DIR "argo.log"
    if (Test-Path $logFile) {
        $match = Select-String -Path $logFile `
            -Pattern "([a-z0-9\-]+\.trycloudflare\.com)" |
            Select-Object -Last 1
        if ($match) {
            return $match.Matches[0].Groups[1].Value
        }
    }
    return ""
}

function Write-FileLog {
    param([string]$LogFile, [string]$Message)
    $timestamp = Get-Timestamp
    $line = "[$timestamp] $Message"
    # 日志轮转 2MB
    if (Test-Path $LogFile) {
        $size = (Get-Item $LogFile).Length
        if ($size -gt 2MB) {
            $tail = Get-Content $LogFile -Tail 200
            $tail | Set-Content $LogFile -Encoding UTF8
        }
    }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Wait-Network {
    Write-Info "等待网络就绪..."
    for ($i = 1; $i -le 30; $i++) {
        try {
            $null = Test-Connection -ComputerName "1.1.1.1" -Count 1 -ErrorAction Stop
            Write-Info "网络就绪 (第 ${i} 次)"
            return
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    Write-Warn "网络等待超时，继续执行..."
}

# ============================================================
# 端口生成
# ============================================================
function Get-RandomPort {
    param([int[]]$Exclude = @())
    $rng = [System.Random]::new()
    while ($true) {
        $port = $rng.Next(10000, 65001)
        if ($port -notin $Exclude) { return $port }
    }
}

function Generate-Ports {
    Write-Step "生成随机端口"
    $used = @()

    $script:SUB_PORT    = Get-RandomPort -Exclude $used; $used += $script:SUB_PORT
    $script:ARGO_PORT   = Get-RandomPort -Exclude $used; $used += $script:ARGO_PORT
    $script:GRPC_PORT   = Get-RandomPort -Exclude $used; $used += $script:GRPC_PORT
    $script:XHTTP_PORT  = Get-RandomPort -Exclude $used; $used += $script:XHTTP_PORT
    $script:VISION_PORT = Get-RandomPort -Exclude $used; $used += $script:VISION_PORT
    $script:SS_PORT     = Get-RandomPort -Exclude $used; $used += $script:SS_PORT
    $script:H3_PORT     = Get-RandomPort -Exclude $used; $used += $script:H3_PORT

    Write-Info "订阅:$($script:SUB_PORT) Argo:$($script:ARGO_PORT) GRPC:$($script:GRPC_PORT)"
    Write-Info "XHTTP:$($script:XHTTP_PORT) Vision:$($script:VISION_PORT) SS:$($script:SS_PORT) H3:$($script:H3_PORT)"
}

# ============================================================
# 密钥生成
# ============================================================
function Generate-Keys {
    Write-Step "生成密钥"

    # UUID
    $script:UUID = [System.Guid]::NewGuid().ToString()

    # x25519 密钥对
    $xrayBin = Join-Path $INSTALL_DIR "xray.exe"
    $output  = & $xrayBin x25519 2>&1
    foreach ($line in $output) {
        if ($line -match "Private key:\s*(.+)") {
            $script:PRIVATE_KEY = $Matches[1].Trim()
        }
        if ($line -match "Public key:\s*(.+)") {
            $script:PUBLIC_KEY = $Matches[1].Trim()
        }
    }

    if (-not $script:PRIVATE_KEY) { Die "生成 x25519 密钥失败" }
    if (-not $script:PUBLIC_KEY)  { Die "生成 x25519 公钥失败" }

    # SS 密码 (16 字节 base64)
    $ssBytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($ssBytes)
    $script:SS_PASSWORD = [Convert]::ToBase64String($ssBytes)

    # Trojan 密码
    $tBytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($tBytes)
    $script:TROJAN_PASSWORD = [BitConverter]::ToString($tBytes).Replace("-","").ToLower()

    # 订阅 Token
    $subBytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($subBytes)
    $script:SUB_TOKEN = [BitConverter]::ToString($subBytes).Replace("-","").ToLower()

    Write-Info "UUID: $($script:UUID)"
    Write-Info "PublicKey: $($script:PUBLIC_KEY)"
}

# ============================================================
# 保存 ports.env
# ============================================================
function Save-PortsEnv {
    @"
SUB_PORT=$($script:SUB_PORT)
ARGO_PORT=$($script:ARGO_PORT)
GRPC_PORT=$($script:GRPC_PORT)
XHTTP_PORT=$($script:XHTTP_PORT)
VISION_PORT=$($script:VISION_PORT)
SS_PORT=$($script:SS_PORT)
XHTTP_H3_PORT=$($script:H3_PORT)
UUID=$($script:UUID)
private_key=$($script:PRIVATE_KEY)
public_key=$($script:PUBLIC_KEY)
ss_password=$($script:SS_PASSWORD)
trojan_password=$($script:TROJAN_PASSWORD)
SUB_TOKEN=$($script:SUB_TOKEN)
CF_TUNNEL_TOKEN=
CF_TUNNEL_ID=
CF_TUNNEL_NAME=
CF_TUNNEL_DOMAIN=
ARGO_DOMAIN=
"@ | Set-Content $PORTS_ENV -Encoding UTF8

    # 限制文件权限
    $acl = Get-Acl $PORTS_ENV
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, "FullControl", "Allow"
    )
    $acl.SetAccessRule($rule)
    Set-Acl $PORTS_ENV $acl
}

# ============================================================
# 下载函数
# ============================================================
function Download-File {
    param(
        [string]$Url,
        [string]$Dest,
        [string]$Desc = "文件"
    )
    Write-Info "下载 ${Desc}..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $Dest)
    } catch {
        # 回退到 Invoke-WebRequest
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
        } catch {
            Die "下载失败 ${Desc}: $_"
        }
    }
}

function Get-LatestXrayVersion {
    try {
        $resp = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/XTLS/Xray-core/releases/latest" `
            -UseBasicParsing -TimeoutSec 10
        return $resp.tag_name
    } catch {
        Write-Warn "无法获取最新版本，使用 v26.3.27"
        return "v26.3.27"
    }
}


function Download-Xray {
    Write-Step "下载 Xray-core"
    $arch    = Get-Arch
    $version = Get-LatestXrayVersion

    $xrayArch = switch ($arch) {
        "amd64" { "64" }
        "arm64" { "arm64-v8a" }
    }

    $url  = "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-windows-${xrayArch}.zip"
    $tmp  = Join-Path $env:TEMP "xray-windows.zip"
    $extr = Join-Path $env:TEMP "xray-windows-extract"

    Download-File -Url $url -Dest $tmp -Desc "Xray-core ${version} (${arch})"

    if (Test-Path $extr) { Remove-Item $extr -Recurse -Force }
    Expand-Archive -Path $tmp -DestinationPath $extr -Force

    Copy-Item (Join-Path $extr "xray.exe") (Join-Path $INSTALL_DIR "xray.exe") -Force
    Remove-Item $tmp, $extr -Recurse -Force -ErrorAction SilentlyContinue

    Write-Info "Xray 已安装: $(Join-Path $INSTALL_DIR 'xray.exe')"
}

function Download-Argo {
    Write-Step "下载 cloudflared"
    $arch = Get-Arch

    $url = switch ($arch) {
        "amd64" { "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" }
        "arm64" { "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-arm64.exe" }
    }

    Download-File -Url $url -Dest (Join-Path $INSTALL_DIR "cloudflared.exe") -Desc "cloudflared (${arch})"
    Write-Info "cloudflared 已安装"
}

# ============================================================
# 生成 Xray 配置
# ============================================================
function Generate-Config {
    Write-Step "生成 Xray 配置"

    $cfg = @"
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
      "port": $($script:ARGO_PORT),
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$($script:UUID)"}],
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
      "listen": "127.0.0.1", "port": 3001,
      "protocol": "vless",
      "settings": {"clients": [{"id": "$($script:UUID)"}], "decryption": "none"},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/vless-argo?ed=2560"}},
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "127.0.0.1", "port": 3002,
      "protocol": "vmess",
      "settings": {"clients": [{"id": "$($script:UUID)", "alterId": 0}]},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/vmess-argo?ed=2560"}},
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "127.0.0.1", "port": 3003,
      "protocol": "trojan",
      "settings": {"clients": [{"password": "$($script:TROJAN_PASSWORD)"}]},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/trojan-argo?ed=2560"}},
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0", "port": $($script:XHTTP_PORT),
      "protocol": "vless",
      "settings": {"clients": [{"id": "$($script:UUID)"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "www.nazhumi.com:443", "xver": 0,
          "serverNames": ["www.nazhumi.com"],
          "privateKey": "$($script:PRIVATE_KEY)", "shortIds": [""]
        },
        "xhttpSettings": {"mode": "auto"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0", "port": $($script:GRPC_PORT),
      "protocol": "vless",
      "settings": {"clients": [{"id": "$($script:UUID)"}], "decryption": "none"},
      "streamSettings": {
        "network": "grpc", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "www.iij.ad.jp:443", "xver": 0,
          "serverNames": ["www.iij.ad.jp"],
          "privateKey": "$($script:PRIVATE_KEY)", "shortIds": [""]
        },
        "grpcSettings": {"serviceName": "grpc"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0", "port": $($script:VISION_PORT),
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$($script:UUID)", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "www.microsoft.com:443", "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "$($script:PRIVATE_KEY)", "shortIds": [""]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0", "port": $($script:SS_PORT),
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "$($script:SS_PASSWORD)",
        "network": "tcp,udp"
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls","quic"]}
    },
    {
      "listen": "0.0.0.0", "port": $($script:H3_PORT),
      "protocol": "vless",
      "settings": {"clients": [{"id": "$($script:UUID)"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "www.apple.com:443", "xver": 0,
          "serverNames": ["www.apple.com"],
          "privateKey": "$($script:PRIVATE_KEY)", "shortIds": [""]
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
"@
    $cfg | Set-Content (Join-Path $INSTALL_DIR "config.json") -Encoding UTF8
    Write-Info "配置文件已生成"
}

# ============================================================
# 订阅服务器 (Python)
# ============================================================
function Generate-SubServer {
    $py = @'
#!/usr/bin/env python3
import os, base64, json, re
import http.server, socketserver

INSTALL_DIR = os.path.dirname(os.path.abspath(__file__))

def load_env():
    env = {}
    f = os.path.join(INSTALL_DIR, "ports.env")
    if os.path.exists(f):
        for line in open(f, encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip()
    return env

def get_ip():
    import urllib.request
    for u in ['https://api.ipify.org','https://ifconfig.me']:
        try:
            with urllib.request.urlopen(u, timeout=5) as r:
                return r.read().decode().strip()
        except: pass
    return "unknown"

def get_domain(env):
    for k in ['CF_TUNNEL_DOMAIN','ARGO_DOMAIN']:
        if env.get(k): return env[k]
    if env.get('CF_TUNNEL_ID'):
        return f"{env['CF_TUNNEL_ID']}.cfargotunnel.com"
    lf = os.path.join(INSTALL_DIR, "logs", "argo.log")
    if os.path.exists(lf):
        for line in open(lf):
            m = re.search(r'([a-z0-9\-]+\.trycloudflare\.com)', line)
            if m: return m.group(1)
    return ""

def links(env, ip):
    u   = env.get('UUID','')
    pk  = env.get('public_key','')
    ssp = env.get('ss_password','')
    tp  = env.get('trojan_password','')
    cdn = "cdns.doon.eu.org"
    n   = ip
    dom = get_domain(env)
    out = []

    out.append(f"vless://{u}@{ip}:{env.get('VISION_PORT','')}?"
               f"encryption=none&flow=xtls-rprx-vision&security=reality"
               f"&sni=www.microsoft.com&fp=chrome&pbk={pk}"
               f"&type=tcp#{n}-Vision-Reality")

    out.append(f"vless://{u}@{ip}:{env.get('XHTTP_PORT','')}?"
               f"encryption=none&security=reality&sni=www.nazhumi.com"
               f"&fp=chrome&pbk={pk}&allowInsecure=1"
               f"&type=xhttp&mode=auto#{n}-XHTTP-Reality")

    out.append(f"vless://{u}@{ip}:{env.get('GRPC_PORT','')}?"
               f"encryption=none&security=reality&sni=www.iij.ad.jp"
               f"&fp=chrome&pbk={pk}&allowInsecure=1"
               f"&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#{n}-gRPC-Reality")

    out.append(f"vless://{u}@{ip}:{env.get('XHTTP_H3_PORT','')}?"
               f"encryption=none&security=reality&sni=www.apple.com"
               f"&fp=chrome&pbk={pk}&allowInsecure=1"
               f"&type=xhttp&mode=auto#{n}-XHTTP-H3-Reality")

    ss = base64.b64encode(f"2022-blake3-aes-128-gcm:{ssp}".encode()).decode()
    out.append(f"ss://{ss}@{ip}:{env.get('SS_PORT','')}#{n}-SS2022")

    if dom:
        out.append(f"vless://{u}@{cdn}:443?"
                   f"encryption=none&security=tls&sni={dom}"
                   f"&fp=chrome&type=ws&host={dom}"
                   f"&path=%2Fvless-argo%3Fed%3D2560#{n}-VLESS-WS-Argo")

        vmess = {"v":"2","ps":f"{n}-VMess-WS-Argo","add":cdn,
                 "port":"443","id":u,"aid":"0","scy":"none",
                 "net":"ws","type":"none","host":dom,
                 "path":"/vmess-argo?ed=2560","tls":"tls",
                 "sni":dom,"alpn":"","fp":"chrome"}
        out.append(f"vmess://{base64.b64encode(json.dumps(vmess).encode()).decode()}")

        out.append(f"trojan://{tp}@{cdn}:443?"
                   f"security=tls&sni={dom}&fp=chrome"
                   f"&type=ws&host={dom}"
                   f"&path=%2Ftrojan-argo%3Fed%3D2560#{n}-Trojan-WS-Argo")

    return "\n".join(out)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        env = load_env()
        if self.path != f"/{env.get('SUB_TOKEN','')}":
            self.send_response(404); self.end_headers(); return
        ip   = get_ip()
        body = base64.b64encode(links(env, ip).encode()).decode()
        self.send_response(200)
        self.send_header("Content-Type","text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body.encode())

if __name__ == "__main__":
    env  = load_env()
    port = int(env.get('SUB_PORT', 49023))
    with socketserver.TCPServer(("0.0.0.0", port), Handler) as s:
        s.serve_forever()
'@
    $py | Set-Content (Join-Path $INSTALL_DIR "sub_server.py") -Encoding UTF8
}

# ============================================================
# 进程管理
# ============================================================
function Start-XrayProcess {
    param([hashtable]$Env)
    $xray   = Join-Path $INSTALL_DIR "xray.exe"
    $config = Join-Path $INSTALL_DIR "config.json"
    $log    = Join-Path $LOG_DIR "xray.log"

    # 轮转日志
    Rotate-Log $log

    $proc = Start-Process -FilePath $xray `
        -ArgumentList "run -c `"$config`"" `
        -WindowStyle Hidden `
        -RedirectStandardOutput $log `
        -RedirectStandardError (Join-Path $LOG_DIR "xray-error.log") `
        -PassThru
    Write-Info "Xray 已启动 PID: $($proc.Id)"
    return $proc
}

function Start-TunnelProcess {
    param([hashtable]$Env)
    $argo = Join-Path $INSTALL_DIR "cloudflared.exe"
    $log  = Join-Path $LOG_DIR "argo.log"

    Rotate-Log $log

    $token    = $Env["CF_TUNNEL_TOKEN"]
    $argoPort = $Env["ARGO_PORT"]

    if ($token) {
        $args = "tunnel --no-autoupdate run --token $token"
    } else {
        $args = "tunnel --url http://localhost:$argoPort --no-autoupdate --edge-ip-version auto --protocol http2"
    }

    $proc = Start-Process -FilePath $argo `
        -ArgumentList $args `
        -WindowStyle Hidden `
        -RedirectStandardOutput $log `
        -RedirectStandardError (Join-Path $LOG_DIR "argo-error.log") `
        -PassThru
    Write-Info "Tunnel 已启动 PID: $($proc.Id)"
    return $proc
}

function Start-SubProcess {
    param([hashtable]$Env)
    $py  = Get-PythonPath
    $log = Join-Path $LOG_DIR "sub.log"
    if (-not $py) { Write-Warn "未找到 Python3，跳过订阅服务"; return }

    Rotate-Log $log

    $proc = Start-Process -FilePath $py `
        -ArgumentList "`"$(Join-Path $INSTALL_DIR 'sub_server.py')`"" `
        -WindowStyle Hidden `
        -RedirectStandardOutput $log `
        -RedirectStandardError (Join-Path $LOG_DIR "sub-error.log") `
        -PassThru
    Write-Info "订阅服务已启动 PID: $($proc.Id)"
}

function Get-PythonPath {
    foreach ($py in @("python3", "python", "py")) {
        $p = Get-Command $py -ErrorAction SilentlyContinue
        if ($p) { return $p.Source }
    }
    # 查找常见安装路径
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\python3.exe",
        "C:\Python3*\python.exe"
    )
    foreach ($c in $candidates) {
        $found = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Stop-AllProcesses {
    Write-Info "停止所有进程..."
    @("xray", "cloudflared") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | ForEach-Object {
            # 只停止来自安装目录的进程
            if ($_.Path -like "*$INSTALL_DIR*") {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                Write-Info "已停止: $($_.Name) PID=$($_.Id)"
            }
        }
    }
    # 订阅服务
    Get-Process -Name "python*" -ErrorAction SilentlyContinue | ForEach-Object {
        $cmdline = (Get-WmiObject Win32_Process -Filter "ProcessId=$($_.Id)" `
            -ErrorAction SilentlyContinue).CommandLine
        if ($cmdline -like "*sub_server.py*") {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Rotate-Log {
    param([string]$LogFile)
    if (Test-Path $LogFile) {
        $size = (Get-Item $LogFile).Length
        if ($size -gt 50MB) {
            $tail = Get-Content $LogFile -Tail 1000
            $tail | Set-Content $LogFile -Encoding UTF8
        }
    }
}

# ============================================================
# 不死鸟持久化
# ============================================================

# --- 看门狗脚本 ---
function Generate-WatchdogScript {
    $wd = @'
# Xray-2go Windows 看门狗
$INSTALL_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$LOG_DIR     = Join-Path $INSTALL_DIR "logs"
$LOG         = Join-Path $LOG_DIR "watchdog.log"

New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null

function wlog {
    param([string]$m)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $m"
    # 轮转 2MB
    if ((Test-Path $LOG) -and (Get-Item $LOG).Length -gt 2MB) {
        Get-Content $LOG -Tail 200 | Set-Content $LOG -Encoding UTF8
    }
    Add-Content -Path $LOG -Value $line -Encoding UTF8
}

function Load-Env {
    $t = @{}
    $f = Join-Path $INSTALL_DIR "ports.env"
    if (Test-Path $f) {
        Get-Content $f | ForEach-Object {
            if ($_ -match '^([^#=]+)=(.*)$') { $t[$Matches[1].Trim()]=$Matches[2].Trim() }
        }
    }
    return $t
}

function Rebuild-Persist {
    wlog "ALERT: 持久化条目丢失，正在重建..."
    & (Join-Path $INSTALL_DIR "setup-persist.ps1") 2>&1 | Out-Null
    wlog "REPAIR: 持久化已重建"
}

$env = Load-Env
$xrayExe  = Join-Path $INSTALL_DIR "xray.exe"
$argoExe  = Join-Path $INSTALL_DIR "cloudflared.exe"
$bootPs1  = Join-Path $INSTALL_DIR "xray-boot.ps1"

# === 检查 1: Xray 进程 ===
$xrayRunning = Get-Process -Name "xray" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "*$INSTALL_DIR*" }
if (-not $xrayRunning) {
    wlog "ALERT: Xray 未运行"
    $log = Join-Path $INSTALL_DIR "logs\xray.log"
    Start-Process -FilePath $xrayExe `
        -ArgumentList "run -c `"$(Join-Path $INSTALL_DIR 'config.json')`"" `
        -WindowStyle Hidden -PassThru | Out-Null
    wlog "REPAIR: Xray 已重启"
    Start-Sleep -Seconds 2
}

# === 检查 2: Tunnel 进程 ===
$argoRunning = Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "*$INSTALL_DIR*" }
if (-not $argoRunning) {
    wlog "ALERT: Tunnel 未运行"
    $token    = $env["CF_TUNNEL_TOKEN"]
    $argoPort = $env["ARGO_PORT"]
    if ($token) {
        $argoArgs = "tunnel --no-autoupdate run --token $token"
    } else {
        $argoArgs = "tunnel --url http://localhost:$argoPort --no-autoupdate --edge-ip-version auto --protocol http2"
    }
    Start-Process -FilePath $argoExe `
        -ArgumentList $argoArgs `
        -WindowStyle Hidden -PassThru | Out-Null
    wlog "REPAIR: Tunnel 已重启"
}

# === 检查 3: 计划任务自愈 ===
$bootTask = Get-ScheduledTask -TaskName "Xray2goBoot" -ErrorAction SilentlyContinue
$wdTask   = Get-ScheduledTask -TaskName "Xray2goWatchdog" -ErrorAction SilentlyContinue
if (-not $bootTask -or -not $wdTask) {
    wlog "ALERT: 计划任务丢失"
    Rebuild-Persist
}

# === 检查 4: 注册表自愈 ===
$regVal = Get-ItemProperty `
    -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
    -Name "Xray2go" -ErrorAction SilentlyContinue
if (-not $regVal) {
    wlog "ALERT: 注册表启动项丢失"
    Set-ItemProperty `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
        -Name "Xray2go" `
        -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootPs1`""
    wlog "REPAIR: 注册表启动项已恢复"
}

# === 检查 5: Startup 快捷方式自愈 ===
$startupDir = [IO.Path]::Combine($env:APPDATA,
    "Microsoft\Windows\Start Menu\Programs\Startup")
$lnk = Join-Path $startupDir "Xray2go.lnk"
if (-not (Test-Path $lnk)) {
    wlog "ALERT: Startup 快捷方式丢失"
    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath  = "powershell.exe"
    $shortcut.Arguments   = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootPs1`""
    $shortcut.WindowStyle = 7
    $shortcut.Save()
    wlog "REPAIR: Startup 快捷方式已恢复"
}
'@
    $wd | Set-Content (Join-Path $INSTALL_DIR "watchdog.ps1") -Encoding UTF8
}

# --- 启动脚本 ---
function Generate-BootScript {
    $boot = @"
# Xray-2go Windows 启动脚本
`$INSTALL_DIR = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$LOG_DIR     = Join-Path `$INSTALL_DIR "logs"
`$LOG         = Join-Path `$LOG_DIR "boot.log"

New-Item -ItemType Directory -Force -Path `$LOG_DIR | Out-Null

function wlog {
    param([string]`$m)
    Add-Content -Path `$LOG -Value "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] BOOT: `$m" -Encoding UTF8
}

wlog "启动脚本执行"

function Load-Env {
    `$t = @{}
    `$f = Join-Path `$INSTALL_DIR "ports.env"
    if (Test-Path `$f) {
        Get-Content `$f | ForEach-Object {
            if (`$_ -match '^([^#=]+)=(.*)$') { `$t[`$Matches[1].Trim()]=`$Matches[2].Trim() }
        }
    }
    return `$t
}

# 等待网络
for (`$i = 1; `$i -le 30; `$i++) {
    try {
        `$null = Test-Connection -ComputerName "1.1.1.1" -Count 1 -ErrorAction Stop
        wlog "网络就绪 (第 `${i} 次)"
        break
    } catch { Start-Sleep -Seconds 2 }
}

`$env     = Load-Env
`$xrayExe = Join-Path `$INSTALL_DIR "xray.exe"
`$argoExe = Join-Path `$INSTALL_DIR "cloudflared.exe"
`$pyPath  = "$( (Get-PythonPath) ?? 'python' )"
`$subPy   = Join-Path `$INSTALL_DIR "sub_server.py"

# 启动 Xray
`$xrayRunning = Get-Process -Name "xray" -ErrorAction SilentlyContinue |
    Where-Object { `$_.Path -like "*`$INSTALL_DIR*" }
if (-not `$xrayRunning) {
    Start-Process -FilePath `$xrayExe ``
        -ArgumentList "run -c ```"`$(Join-Path `$INSTALL_DIR 'config.json')```"" ``
        -WindowStyle Hidden -PassThru | Out-Null
    wlog "Xray 已启动"
    Start-Sleep -Seconds 2
}

# 启动 Tunnel
`$argoRunning = Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue |
    Where-Object { `$_.Path -like "*`$INSTALL_DIR*" }
if (-not `$argoRunning) {
    `$token    = `$env["CF_TUNNEL_TOKEN"]
    `$argoPort = `$env["ARGO_PORT"]
    if (`$token) {
        `$argoArgs = "tunnel --no-autoupdate run --token `$token"
    } else {
        `$argoArgs = "tunnel --url http://localhost:`$argoPort --no-autoupdate --edge-ip-version auto --protocol http2"
    }
    Start-Process -FilePath `$argoExe ``
        -ArgumentList `$argoArgs ``
        -WindowStyle Hidden -PassThru | Out-Null
    wlog "Tunnel 已启动"
}

# 启动订阅服务
`$subRunning = Get-Process -Name "python*" -ErrorAction SilentlyContinue | Where-Object {
    `$cmdline = (Get-WmiObject Win32_Process -Filter "ProcessId=`$(`$_.Id)" -EA SilentlyContinue).CommandLine
    `$cmdline -like "*sub_server.py*"
}
if (-not `$subRunning -and (Test-Path `$subPy)) {
    Start-Process -FilePath `$pyPath ``
        -ArgumentList "`"`$subPy`"" ``
        -WindowStyle Hidden -PassThru | Out-Null
    wlog "订阅服务已启动"
}

wlog "启动完毕"
"@
    $boot | Set-Content (Join-Path $INSTALL_DIR "xray-boot.ps1") -Encoding UTF8
}

# --- 持久化安装 ---
function Setup-Persist {
    Write-Step "安装不死鸟持久化"

    $bootPs1 = Join-Path $INSTALL_DIR "xray-boot.ps1"
    $wdPs1   = Join-Path $INSTALL_DIR "watchdog.ps1"

    # === 层 1: Task Scheduler ===
    Write-Info "[层1] 创建计划任务..."

    # 启动任务
    $bootAction   = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootPs1`""
    $bootTrigger  = New-ScheduledTaskTrigger -AtLogOn
    $bootSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Seconds 10) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0)

    Register-ScheduledTask `
        -TaskName "Xray2goBoot" `
        -Action $bootAction `
        -Trigger $bootTrigger `
        -Settings $bootSettings `
        -Force | Out-Null
    Write-Info "  ✅ 登录启动任务已创建"

    # 看门狗任务（每 60 秒）
    $wdAction   = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wdPs1`""
    $wdTrigger  = New-ScheduledTaskTrigger -Once `
        -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 36500)
    $wdSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    Register-ScheduledTask `
        -TaskName "Xray2goWatchdog" `
        -Action $wdAction `
        -Trigger $wdTrigger `
        -Settings $wdSettings `
        -Force | Out-Null
    Write-Info "  ✅ 看门狗任务已创建 (每60秒)"

    # === 层 2: Startup 文件夹 ===
    Write-Info "[层2] 创建 Startup 快捷方式..."
    $startupDir = [IO.Path]::Combine(
        $env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
    New-Item -ItemType Directory -Force -Path $startupDir | Out-Null

    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $startupDir "Xray2go.lnk"))
    $shortcut.TargetPath  = "powershell.exe"
    $shortcut.Arguments   = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootPs1`""
    $shortcut.WindowStyle = 7
    $shortcut.Description = "Xray2go Auto Start"
    $shortcut.Save()
    Write-Info "  ✅ Startup 快捷方式已创建"

    # === 层 3: 注册表 HKCU\Run ===
    Write-Info "[层3] 添加注册表启动项..."
    Set-ItemProperty `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
        -Name "Xray2go" `
        -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootPs1`""
    Write-Info "  ✅ 注册表 HKCU\Run 已添加"

    # === 层 4: 隐藏目录 ===
    Write-Info "[层4] 隐藏安装目录..."
    $dirInfo = Get-Item $INSTALL_DIR -Force
    $dirInfo.Attributes = $dirInfo.Attributes -bor [IO.FileAttributes]::Hidden
    Write-Info "  ✅ 目录已隐藏"

    Write-Info ""
    Write-Info "🐦‍🔥 Windows 不死鸟持久化已激活！"
    Write-Info ""
    Write-Info "  防护层:"
    Write-Info "  ✅ 层1: 计划任务 (登录启动 + 每60s看门狗)"
    Write-Info "  ✅ 层2: Startup 文件夹快捷方式"
    Write-Info "  ✅ 层3: 注册表 HKCU\Run"
    Write-Info "  ✅ 层4: 安装目录隐藏"
    Write-Info "  ✅ 看门狗自愈 (任务/注册表/快捷方式被删自动重建)"
}

# ============================================================
# Cloudflare 固定隧道
# ============================================================
function Setup-FixedTunnel {
    Write-Step "配置 Cloudflare 固定隧道"

    # 读取 .env
    if (Test-Path $DOT_ENV) {
        Get-Content $DOT_ENV | ForEach-Object {
            if ($_ -match '^([^#=]+)=(.+)$') {
                Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script
            }
        }
    }

    if (-not (Get-Variable -Name "CF_API_TOKEN" -Scope Script -ErrorAction SilentlyContinue).Value) {
        $script:CF_API_TOKEN = Read-Host "CF_API_TOKEN"
        if (-not $script:CF_API_TOKEN) { Die "CF_API_TOKEN 不能为空" }
    }
    if (-not (Get-Variable -Name "CF_ACCOUNT_ID" -Scope Script -ErrorAction SilentlyContinue).Value) {
        $script:CF_ACCOUNT_ID = Read-Host "CF_ACCOUNT_ID"
        if (-not $script:CF_ACCOUNT_ID) { Die "CF_ACCOUNT_ID 不能为空" }
    }

    $tunnelName   = "xray-$(hostname)-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $API_BASE     = "https://api.cloudflare.com/client/v4"
    $headers      = @{
        "Authorization" = "Bearer $($script:CF_API_TOKEN)"
        "Content-Type"  = "application/json"
    }

    # 生成 tunnel_secret
    $secretBytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($secretBytes)
    $tunnelSecret = [Convert]::ToBase64String($secretBytes)

    # 创建隧道
    Write-Info "创建隧道: $tunnelName"
    $body = @{name=$tunnelName; tunnel_secret=$tunnelSecret} | ConvertTo-Json
    $resp = Invoke-RestMethod -Uri "$API_BASE/accounts/$($script:CF_ACCOUNT_ID)/cfd_tunnel" `
        -Method POST -Headers $headers -Body $body -ErrorAction Stop

    if (-not $resp.success) { Die "创建隧道失败: $($resp.errors | ConvertTo-Json)" }

    $tunnelId = $resp.result.id
    Write-Info "隧道 ID: $tunnelId"

    # 读取环境变量
    $envData  = Load-Env
    $argoPort = $envData["ARGO_PORT"]

    # 配置入站
    $ingress = if ($envData["CF_TUNNEL_DOMAIN"]) {
        @(
            @{hostname=$envData["CF_TUNNEL_DOMAIN"]; service="http://localhost:$argoPort"; originRequest=@{}},
            @{service="http_status:404"}
        )
    } else {
        @(@{service="http://localhost:$argoPort"})
    }
    $cfgBody = @{config=@{originRequest=@{}; "warp-routing"=@{enabled=$false}; ingress=$ingress}} |
        ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$API_BASE/accounts/$($script:CF_ACCOUNT_ID)/cfd_tunnel/$tunnelId/configurations" `
        -Method PUT -Headers $headers -Body $cfgBody -ErrorAction Stop | Out-Null

    # 获取 token
    $tokenResp = Invoke-RestMethod `
        -Uri "$API_BASE/accounts/$($script:CF_ACCOUNT_ID)/cfd_tunnel/$tunnelId/token" `
        -Method GET -Headers $headers -ErrorAction Stop

    $tunnelToken = $tokenResp.result
    if (-not $tunnelToken) { Die "获取 Token 失败" }

    # DNS CNAME（可选）
    $cfDomain = $envData["CF_TUNNEL_DOMAIN"]
    $cfZone   = if (Test-Path $DOT_ENV) {
        (Get-Content $DOT_ENV | Where-Object { $_ -match "^CF_ZONE_ID=(.+)$" } |
         Select-Object -First 1) -replace "^CF_ZONE_ID=", ""
    } else { "" }

    if ($cfDomain -and $cfZone) {
        $dnsBody = @{
            type="CNAME"; name=$cfDomain
            content="$tunnelId.cfargotunnel.com"; proxied=$true
        } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "$API_BASE/zones/$cfZone/dns_records" `
                -Method POST -Headers $headers -Body $dnsBody | Out-Null
            Write-Info "DNS CNAME 已创建"
        } catch {
            Write-Warn "DNS CNAME 创建失败（可能已存在）"
        }
    }

    # 保存
    $argoDomain = if ($cfDomain) { $cfDomain } else { "$tunnelId.cfargotunnel.com" }
    Update-EnvKey "CF_TUNNEL_TOKEN" $tunnelToken
    Update-EnvKey "CF_TUNNEL_ID"    $tunnelId
    Update-EnvKey "CF_TUNNEL_NAME"  $tunnelName
    Update-EnvKey "ARGO_DOMAIN"     $argoDomain

    @"
CF_API_TOKEN=$($script:CF_API_TOKEN)
CF_ACCOUNT_ID=$($script:CF_ACCOUNT_ID)
CF_ZONE_ID=$cfZone
CF_TUNNEL_NAME=$tunnelName
"@ | Set-Content $DOT_ENV -Encoding UTF8

    # 重启 tunnel 进程
    Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "*$INSTALL_DIR*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $envData = Load-Env
    Start-TunnelProcess -Env $envData | Out-Null

    # 重新生成启动脚本（含新 token）
    Generate-BootScript
    Generate-WatchdogScript

    Write-Info "固定隧道配置完成: $argoDomain"
}

function Delete-FixedTunnel {
    Write-Step "删除固定隧道"

    if (Test-Path $DOT_ENV) {
        Get-Content $DOT_ENV | ForEach-Object {
            if ($_ -match '^([^#=]+)=(.+)$') {
                Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script
            }
        }
    }

    $envData   = Load-Env
    $tunnelId  = $envData["CF_TUNNEL_ID"]
    $apiToken  = (Get-Variable "CF_API_TOKEN" -Scope Script -EA SilentlyContinue).Value
    $accountId = (Get-Variable "CF_ACCOUNT_ID" -Scope Script -EA SilentlyContinue).Value

    if (-not $tunnelId -or -not $apiToken -or -not $accountId) {
        Die "缺少 CF_TUNNEL_ID / CF_API_TOKEN / CF_ACCOUNT_ID"
    }

    $API_BASE = "https://api.cloudflare.com/client/v4"
    $headers  = @{
        "Authorization" = "Bearer $apiToken"
        "Content-Type"  = "application/json"
    }

    # 停止进程
    Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "*$INSTALL_DIR*" } |
        Stop-Process -Force -ErrorAction SilentlyContinue

    # 清理连接
    try {
        Invoke-RestMethod `
            -Uri "$API_BASE/accounts/$accountId/cfd_tunnel/$tunnelId/connections" `
            -Method DELETE -Headers $headers | Out-Null
        Start-Sleep -Seconds 2
    } catch {}

    # 删除隧道
    $resp = Invoke-RestMethod `
        -Uri "$API_BASE/accounts/$accountId/cfd_tunnel/$tunnelId" `
        -Method DELETE -Headers $headers

    if ($resp.success) {
        Update-EnvKey "CF_TUNNEL_TOKEN" ""
        Update-EnvKey "CF_TUNNEL_ID"    ""
        Update-EnvKey "ARGO_DOMAIN"     ""
        Write-Info "固定隧道已删除"
    } else {
        Write-Err "删除失败: $($resp.errors | ConvertTo-Json)"
    }
}

# ============================================================
# 节点信息
# ============================================================
function Print-NodeInfo {
    $envData    = Load-Env
    $IP         = Get-PublicIP
    $argoDomain = Get-ArgoDomain -Env $envData
    $N          = $IP

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║      Xray-2go Windows 节点信息           ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  时间:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')           ║" -ForegroundColor White
    Write-Host "║  系统:   Windows $(Get-WinVersion) ($(Get-Arch))         ║" -ForegroundColor White
    Write-Host "║  服务器: $IP" -ForegroundColor White
    Write-Host "╠══════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  端口: 订阅=$($envData['SUB_PORT'])  Argo=$($envData['ARGO_PORT'])  GRPC=$($envData['GRPC_PORT'])" -ForegroundColor White
    Write-Host "║        XHTTP=$($envData['XHTTP_PORT'])  Vision=$($envData['VISION_PORT'])  SS=$($envData['SS_PORT'])  H3=$($envData['XHTTP_H3_PORT'])" -ForegroundColor White
    Write-Host "╠══════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  UUID: $($envData['UUID'])" -ForegroundColor White
    Write-Host "║  PubKey: $($envData['public_key'])" -ForegroundColor White
    Write-Host "║  Argo: $(if($argoDomain){$argoDomain}else{'未获取'})" -ForegroundColor White
    Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Yellow
    Write-Host "  节点链接" -ForegroundColor Yellow
    Write-Host "===========================================" -ForegroundColor Yellow
    Write-Host ""

    $uuid    = $envData['UUID']
    $pk      = $envData['public_key']
    $ssp     = $envData['ss_password']
    $tp      = $envData['trojan_password']
    $cdn     = $CDN_HOST

    Write-Host "--- 1. VLESS TCP Vision Reality ---" -ForegroundColor Green
    Write-Host "vless://${uuid}@${IP}:$($envData['VISION_PORT'])?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${pk}&type=tcp#${N}-Vision-Reality"
    Write-Host ""

    Write-Host "--- 2. VLESS XHTTP Reality ---" -ForegroundColor Green
    Write-Host "vless://${uuid}@${IP}:$($envData['XHTTP_PORT'])?encryption=none&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${pk}&allowInsecure=1&type=xhttp&mode=auto#${N}-XHTTP-Reality"
    Write-Host ""

    Write-Host "--- 3. VLESS gRPC Reality ---" -ForegroundColor Green
    Write-Host "vless://${uuid}@${IP}:$($envData['GRPC_PORT'])?encryption=none&security=reality&sni=www.iij.ad.jp&fp=chrome&pbk=${pk}&allowInsecure=1&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#${N}-gRPC-Reality"
    Write-Host ""

    Write-Host "--- 4. VLESS XHTTP H3 Reality ---" -ForegroundColor Green
    Write-Host "vless://${uuid}@${IP}:$($envData['XHTTP_H3_PORT'])?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=${pk}&allowInsecure=1&type=xhttp&mode=auto#${N}-XHTTP-H3-Reality"
    Write-Host ""

    Write-Host "--- 5. Shadowsocks 2022 ---" -ForegroundColor Green
    $ssBytes = [Text.Encoding]::UTF8.GetBytes("2022-blake3-aes-128-gcm:$ssp")
    $ssB64   = [Convert]::ToBase64String($ssBytes)
    Write-Host "ss://${ssB64}@${IP}:$($envData['SS_PORT'])#${N}-SS2022"
    Write-Host ""

    if ($argoDomain) {
        Write-Host "--- 6. VLESS WS Argo ---" -ForegroundColor Green
        Write-Host "vless://${uuid}@${cdn}:443?encryption=none&security=tls&sni=${argoDomain}&fp=chrome&type=ws&host=${argoDomain}&path=%2Fvless-argo%3Fed%3D2560#${N}-VLESS-WS-Argo"
        Write-Host ""

        Write-Host "--- 7. VMess WS Argo ---" -ForegroundColor Green
        $vmessObj = @{
            v="2"; ps="${N}-VMess-WS-Argo"; add=$cdn
            port="443"; id=$uuid; aid="0"; scy="none"
            net="ws"; type="none"; host=$argoDomain
            path="/vmess-argo?ed=2560"; tls="tls"
            sni=$argoDomain; alpn=""; fp="chrome"
        }
        $vmessJson = $vmessObj | ConvertTo-Json -Compress
        $vmessB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($vmessJson))
        Write-Host "vmess://$vmessB64"
        Write-Host ""

        Write-Host "--- 8. Trojan WS Argo ---" -ForegroundColor Green
        Write-Host "trojan://${tp}@${cdn}:443?security=tls&sni=${argoDomain}&fp=chrome&type=ws&host=${argoDomain}&path=%2Ftrojan-argo%3Fed%3D2560#${N}-Trojan-WS-Argo"
        Write-Host ""
    }

    Write-Host "===========================================" -ForegroundColor Yellow
    Write-Host "  订阅链接" -ForegroundColor Yellow
    Write-Host "===========================================" -ForegroundColor Yellow
    Write-Host "http://${IP}:$($envData['SUB_PORT'])/$($envData['SUB_TOKEN'])"
    Write-Host ""
}

# ============================================================
# 状态查看
# ============================================================
function Show-Status {
    Write-Host "`n=== 进程状态 ===" -ForegroundColor Cyan
    @("xray", "cloudflared") | ForEach-Object {
        $proc = Get-Process -Name $_ -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like "*$INSTALL_DIR*" }
        if ($proc) {
            Write-Host "  $_ : ✅ 运行中 (PID=$($proc.Id))" -ForegroundColor Green
        } else {
            Write-Host "  $_ : ❌ 未运行" -ForegroundColor Red
        }
    }

    Write-Host "`n=== 计划任务 ===" -ForegroundColor Cyan
    @("Xray2goBoot", "Xray2goWatchdog") | ForEach-Object {
        $task = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
        if ($task) {
            Write-Host "  $_ : ✅ $($task.State)" -ForegroundColor Green
        } else {
            Write-Host "  $_ : ❌ 不存在" -ForegroundColor Red
        }
    }

    Write-Host "`n=== 注册表启动项 ===" -ForegroundColor Cyan
    $reg = Get-ItemProperty `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
        -Name "Xray2go" -ErrorAction SilentlyContinue
    if ($reg) {
        Write-Host "  Xray2go : ✅ 存在" -ForegroundColor Green
    } else {
        Write-Host "  Xray2go : ❌ 不存在" -ForegroundColor Red
    }

    Write-Host "`n=== 端口监听 ===" -ForegroundColor Cyan
    $envData = Load-Env
    @("ARGO_PORT","VISION_PORT","SS_PORT","SUB_PORT") | ForEach-Object {
        $port = $envData[$_]
        if ($port) {
            $conn = Get-NetTCPConnection -LocalPort $port -State Listen `
                -ErrorAction SilentlyContinue
            if ($conn) {
                Write-Host "  :$port ($_ ) : ✅ 监听中" -ForegroundColor Green
            } else {
                Write-Host "  :$port ($_ ) : ❌ 未监听" -ForegroundColor Red
            }
        }
    }
    Write-Host ""
}

# ============================================================
# 完整安装
# ============================================================
function Do-Install {
    Write-Step "==== Xray-2go Windows 安装开始 ===="
    Write-Info "安装目录: $INSTALL_DIR"
    Write-Info "Windows $(Get-WinVersion) | 架构: $(Get-Arch)"
    Write-Info "管理员: $(Test-IsAdmin)"

    # 安装前强制停止相关进程并清理旧文件
    if (Test-Path $INSTALL_DIR) {
        Unregister-ScheduledTask -TaskName "Xray2goBoot" -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName "Xray2goWatchdog" -Confirm:$false -ErrorAction SilentlyContinue
        Get-Process -Name "xray" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*$INSTALL_DIR*" } | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*$INSTALL_DIR*" } | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $INSTALL_DIR "xray.exe") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $INSTALL_DIR "cloudflared.exe") -Force -ErrorAction SilentlyContinue
    }

    # 创建目录
    New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
    New-Item -ItemType Directory -Force -Path $LOG_DIR     | Out-Null

    Generate-Ports
    Download-Xray
    Download-Argo
    Generate-Keys
    Save-PortsEnv
    Generate-Config
    Generate-SubServer
    Generate-WatchdogScript
    Generate-BootScript
    Setup-Persist

    # 启动服务
    Write-Step "启动服务"
    Wait-Network
    $envData = Load-Env
    Start-XrayProcess  -Env $envData | Out-Null
    Start-Sleep -Seconds 2
    Start-TunnelProcess -Env $envData | Out-Null
    Start-SubProcess    -Env $envData

    # 等待 Argo 域名
    Write-Info "等待 Argo 域名 (最多 40 秒)..."
    $domain = ""
    for ($i = 1; $i -le 20; $i++) {
        $logFile = Join-Path $LOG_DIR "argo.log"
        if (Test-Path $logFile) {
            $match = Select-String -Path $logFile `
                -Pattern "([a-z0-9\-]+\.trycloudflare\.com)" |
                Select-Object -Last 1
            if ($match) {
                $domain = $match.Matches[0].Groups[1].Value
                break
            }
        }
        Start-Sleep -Seconds 2
    }

    if ($domain) {
        Update-EnvKey "ARGO_DOMAIN" $domain
        Write-Info "Argo 域名: $domain"
    } else {
        Write-Warn "未获取到域名，可稍后通过菜单选项3查看"
    }

    Print-NodeInfo
    Write-Step "==== 安装完成 ===="
}

# ============================================================
# 完整卸载
# ============================================================
function Do-Uninstall {
    Write-Step "开始卸载..."

    # 停止进程
    Stop-AllProcesses

    # 删除计划任务
    @("Xray2goBoot", "Xray2goWatchdog") | ForEach-Object {
        Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue
        Write-Info "已删除计划任务: $_"
    }

    # 删除 Startup 快捷方式
    $startupDir = [IO.Path]::Combine(
        $env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
    $lnk = Join-Path $startupDir "Xray2go.lnk"
    if (Test-Path $lnk) { Remove-Item $lnk -Force }

    # 删除注册表
    Remove-ItemProperty `
        -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
        -Name "Xray2go" -ErrorAction SilentlyContinue

    # 取消隐藏
    if (Test-Path $INSTALL_DIR -ErrorAction SilentlyContinue) {
        $dirInfo = Get-Item $INSTALL_DIR -Force -ErrorAction SilentlyContinue
        if ($dirInfo) {
            $dirInfo.Attributes = $dirInfo.Attributes -band (
                -bnot [IO.FileAttributes]::Hidden)
        }
        Remove-Item $INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "  🧹 Windows 卸载完成" -ForegroundColor Green
    Write-Host "  所有计划任务 / 注册表 / Startup / 安装目录 已清除" -ForegroundColor Green
    Write-Host ""
}

# ============================================================
# 菜单
# ============================================================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   Xray-2go Windows v$SCRIPT_VERSION         ║" -ForegroundColor Cyan
    Write-Host "  ║   $(Get-WinVersion) | $(Get-Arch)               ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) 安装" -ForegroundColor White
    Write-Host "  2) 卸载" -ForegroundColor White
    Write-Host "  3) 显示节点信息" -ForegroundColor White
    Write-Host "  4) 重启所有服务" -ForegroundColor White
    Write-Host "  5) 查看状态" -ForegroundColor White
    Write-Host "  6) 配置 CF 固定隧道" -ForegroundColor White
    Write-Host "  7) 删除 CF 固定隧道" -ForegroundColor White
    Write-Host "  8) 切换回临时隧道" -ForegroundColor White
    Write-Host "  9) 更新 Xray" -ForegroundColor White
    Write-Host "  0) 退出" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  请选择"

    switch ($choice) {
        "1" { Do-Install }
        "2" {
            $confirm = Read-Host "  确认卸载? [y/N]"
            if ($confirm -match "^[Yy]$") { Do-Uninstall } else { Write-Info "已取消" }
        }
        "3" {
            if (Test-Path $PORTS_ENV) { Print-NodeInfo } else { Write-Warn "未安装" }
        }
        "4" {
            Write-Info "重启所有服务..."
            Stop-AllProcesses
            Start-Sleep -Seconds 1
            $envData = Load-Env
            Start-XrayProcess   -Env $envData | Out-Null
            Start-Sleep -Seconds 2
            Start-TunnelProcess -Env $envData | Out-Null
            Start-SubProcess    -Env $envData
            Write-Info "重启完成"
        }
        "5" { Show-Status }
        "6" { Setup-FixedTunnel }
        "7" { Delete-FixedTunnel }
        "8" {
            Write-Info "切换回临时隧道..."
            Update-EnvKey "CF_TUNNEL_TOKEN" ""
            Update-EnvKey "CF_TUNNEL_ID"    ""
            Update-EnvKey "ARGO_DOMAIN"     ""
            # 重启 tunnel
            Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -like "*$INSTALL_DIR*" } |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Remove-Item (Join-Path $LOG_DIR "argo.log") -ErrorAction SilentlyContinue
            Generate-BootScript
            $envData = Load-Env
            Start-TunnelProcess -Env $envData | Out-Null
            Write-Info "等待临时域名..."
            Start-Sleep -Seconds 10
            $envData  = Load-Env
            $logFile  = Join-Path $LOG_DIR "argo.log"
            if (Test-Path $logFile) {
                $match = Select-String -Path $logFile `
                    -Pattern "([a-z0-9\-]+\.trycloudflare\.com)" |
                    Select-Object -Last 1
                if ($match) {
                    $domain = $match.Matches[0].Groups[1].Value
                    Update-EnvKey "ARGO_DOMAIN" $domain
                    Write-Info "新域名: $domain"
                }
            }
        }
        "9" {
            Write-Info "更新 Xray..."
            Get-Process -Name "xray" -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -like "*$INSTALL_DIR*" } |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Download-Xray
            $envData = Load-Env
            Start-XrayProcess -Env $envData | Out-Null
            Write-Info "Xray 已更新并重启"
        }
        "0" { exit 0 }
        default { Write-Warn "无效选择" }
    }

    Write-Host ""
    Read-Host "  按 Enter 返回菜单"
    Show-Menu
}

# ============================================================
# 入口
# ============================================================
switch ($args[0]) {
    "install"   { Do-Install }
    "uninstall" { Do-Uninstall }
    "info"      { if (Test-Path $PORTS_ENV) { Print-NodeInfo } else { Write-Warn "未安装" } }
    "status"    { Show-Status }
    "restart"   {
        Stop-AllProcesses
        Start-Sleep -Seconds 1
        $envData = Load-Env
        Start-XrayProcess   -Env $envData | Out-Null
        Start-Sleep -Seconds 2
        Start-TunnelProcess -Env $envData | Out-Null
        Start-SubProcess    -Env $envData
    }
    default     { Show-Menu }
}
