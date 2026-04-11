# ===========================================
# Xray-2go Windows PowerShell 版
# 自动端口选择、多API获取IP、导出代理为txt
# 需要以管理员身份运行
# ===========================================

#Requires -RunAsAdministrator

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

# 定义常量
$ServerName = "xray"
$WorkDir = "$env:USERPROFILE\.xray"
$ConfigDir = "$WorkDir\config.json"
$ClientDir = "$WorkDir\url.txt"
$ExportDir = (Get-Location).Path
$PortsEnvFile = "$WorkDir\ports.env"

# NSSM 用于创建 Windows 服务
$NssmPath = "$WorkDir\nssm.exe"

# ==========================================
# 颜色输出函数
# ==========================================
function Write-Red { param([string]$Text) Write-Host $Text -ForegroundColor Red }
function Write-Green { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-Yellow { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-Purple { param([string]$Text) Write-Host $Text -ForegroundColor Magenta }
function Write-SkyBlue { param([string]$Text) Write-Host $Text -ForegroundColor Cyan }

# ==========================================
# 工具函数
# ==========================================

# 查找可用端口
function Find-AvailablePort {
    param(
        [int]$StartPort = 1000,
        [int]$EndPort = 60000
    )
    for ($i = 0; $i -lt 50; $i++) {
        $port = Get-Random -Minimum $StartPort -Maximum $EndPort
        $listener = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
        if (-not $listener) {
            return $port
        }
    }
    return (Get-Random -Minimum $StartPort -Maximum $EndPort)
}

# 分配所有端口
function Assign-Ports {
    Write-Yellow "正在自动分配可用端口..."

    $script:PORT = Find-AvailablePort -StartPort 1000 -EndPort 60000
    $script:ARGO_PORT = Find-AvailablePort -StartPort 8000 -EndPort 9000
    while ($script:ARGO_PORT -eq $script:PORT) {
        $script:ARGO_PORT = Find-AvailablePort -StartPort 8000 -EndPort 9000
    }
    $script:GRPC_PORT = Find-AvailablePort -StartPort 10000 -EndPort 30000
    while ($script:GRPC_PORT -eq $script:PORT -or $script:GRPC_PORT -eq $script:ARGO_PORT) {
        $script:GRPC_PORT = Find-AvailablePort -StartPort 10000 -EndPort 30000
    }
    $script:XHTTP_PORT = Find-AvailablePort -StartPort 30001 -EndPort 50000
    while ($script:XHTTP_PORT -eq $script:PORT -or $script:XHTTP_PORT -eq $script:ARGO_PORT -or $script:XHTTP_PORT -eq $script:GRPC_PORT) {
        $script:XHTTP_PORT = Find-AvailablePort -StartPort 30001 -EndPort 50000
    }

    Write-Green "端口分配完成："
    Write-Green "  订阅端口 (PORT):       $script:PORT"
    Write-Green "  Argo 端口 (ARGO_PORT): $script:ARGO_PORT"
    Write-Green "  GRPC 端口:             $script:GRPC_PORT"
    Write-Green "  XHTTP 端口:            $script:XHTTP_PORT"
}

# 保存端口配置
function Save-Ports {
    @"
PORT=$script:PORT
ARGO_PORT=$script:ARGO_PORT
GRPC_PORT=$script:GRPC_PORT
XHTTP_PORT=$script:XHTTP_PORT
password=$script:password
private_key=$script:privateKey
public_key=$script:publicKey
UUID=$script:UUID
"@ | Out-File -FilePath $PortsEnvFile -Encoding UTF8
}

# 加载端口配置
function Load-Ports {
    if (Test-Path $PortsEnvFile) {
        Get-Content $PortsEnvFile | ForEach-Object {
            if ($_ -match '^(\w+)=(.*)$') {
                Set-Variable -Name $matches[1] -Value $matches[2] -Scope Script
            }
        }
    }
}

# 获取公网 IP - 多 API 兜底
function Get-RealIP {
    $apis = @(
        "https://ifconfig.me"
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ipecho.net/plain"
        "https://checkip.amazonaws.com"
        "https://ipv4.ip.sb"
    )

    foreach ($api in $apis) {
        try {
            $ip = (Invoke-WebRequest -Uri $api -TimeoutSec 5 -UseBasicParsing).Content.Trim()
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
                return $ip
            }
        }
        catch { continue }
    }

    # IPv6 备用
    $ipv6apis = @(
        "https://api64.ipify.org"
        "https://ipv6.ip.sb"
    )
    foreach ($api in $ipv6apis) {
        try {
            $ip = (Invoke-WebRequest -Uri $api -TimeoutSec 5 -UseBasicParsing).Content.Trim()
            if ($ip) { return "[$ip]" }
        }
        catch { continue }
    }

    # 全部失败，手动输入
    Write-Red "无法自动获取公网 IP"
    $manual = Read-Host "请手动输入你的服务器公网 IP"
    if ($manual) { return $manual } else { return "127.0.0.1" }
}

# 获取系统架构
function Get-Arch {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($arch) {
        "X64"   { return @{ ARCH = "amd64"; ARCH_ARG = "64" } }
        "Arm64" { return @{ ARCH = "arm64"; ARCH_ARG = "arm64-v8a" } }
        default {
            # fallback
            if ([Environment]::Is64BitOperatingSystem) {
                return @{ ARCH = "amd64"; ARCH_ARG = "64" }
            }
            else {
                return @{ ARCH = "386"; ARCH_ARG = "32" }
            }
        }
    }
}

# 生成 UUID
function New-UUID {
    return [guid]::NewGuid().ToString()
}

# 生成随机密码
function New-Password {
    param([int]$Length = 24)
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    return -join (1..$Length | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

# Base64 编码
function ConvertTo-Base64 {
    param([string]$Text)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

# Base64 解码
function ConvertFrom-Base64 {
    param([string]$Text)
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

# ==========================================
# 检查状态
# ==========================================
function Check-Xray {
    if (Test-Path "$WorkDir\$ServerName.exe") {
        $svc = Get-Service -Name "xray" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            return 0  # running
        }
        else {
            return 1  # not running
        }
    }
    return 2  # not installed
}

function Check-Argo {
    if (Test-Path "$WorkDir\argo.exe") {
        $svc = Get-Service -Name "cloudflared-tunnel" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            return 0
        }
        else {
            return 1
        }
    }
    return 2
}

function Check-Caddy {
    if (Test-Path "$WorkDir\caddy.exe") {
        $svc = Get-Service -Name "caddy" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            return 0
        }
        else {
            return 1
        }
    }
    return 2
}

function Get-StatusText {
    param([int]$Status)
    switch ($Status) {
        0 { return "running" }
        1 { return "not running" }
        2 { return "not installed" }
    }
}

# ==========================================
# 下载 NSSM（用于创建 Windows 服务）
# ==========================================
function Install-NSSM {
    if (Test-Path $NssmPath) {
        Write-Green "nssm already installed"
        return
    }
    Write-Yellow "正在下载 NSSM (Windows 服务管理工具)..."
    $nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
    $nssmZip = "$WorkDir\nssm.zip"
    try {
        Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing
        Expand-Archive -Path $nssmZip -DestinationPath "$WorkDir\nssm_tmp" -Force
        $nssmExe = Get-ChildItem -Path "$WorkDir\nssm_tmp" -Recurse -Filter "nssm.exe" | Where-Object { $_.DirectoryName -like "*win64*" } | Select-Object -First 1
        if (-not $nssmExe) {
            $nssmExe = Get-ChildItem -Path "$WorkDir\nssm_tmp" -Recurse -Filter "nssm.exe" | Select-Object -First 1
        }
        Copy-Item $nssmExe.FullName $NssmPath -Force
        Remove-Item "$WorkDir\nssm_tmp" -Recurse -Force
        Remove-Item $nssmZip -Force
        Write-Green "NSSM 安装成功"
    }
    catch {
        Write-Red "NSSM 下载失败: $_"
        Write-Yellow "请手动下载 nssm 到 $NssmPath"
    }
}

# ==========================================
# 安装 Caddy
# ==========================================
function Install-Caddy {
    if (Test-Path "$WorkDir\caddy.exe") {
        Write-Green "caddy already installed"
        return
    }
    Write-Yellow "正在下载 caddy..."
    $archInfo = Get-Arch

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/caddyserver/caddy/releases/latest" -UseBasicParsing
        $caddyVersion = $release.tag_name -replace '^v', ''
    }
    catch {
        $caddyVersion = "2.9.1"
    }

    $caddyUrl = "https://github.com/caddyserver/caddy/releases/download/v${caddyVersion}/caddy_${caddyVersion}_windows_$($archInfo.ARCH).zip"
    $caddyZip = "$WorkDir\caddy.zip"

    try {
        Invoke-WebRequest -Uri $caddyUrl -OutFile $caddyZip -UseBasicParsing
        Expand-Archive -Path $caddyZip -DestinationPath "$WorkDir\caddy_tmp" -Force
        Copy-Item "$WorkDir\caddy_tmp\caddy.exe" "$WorkDir\caddy.exe" -Force
        Remove-Item "$WorkDir\caddy_tmp" -Recurse -Force
        Remove-Item $caddyZip -Force
        Write-Green "caddy v$caddyVersion 安装成功"
    }
    catch {
        Write-Red "caddy 下载失败: $_"
    }
}

# ==========================================
# 安装 jq
# ==========================================
function Install-Jq {
    if (Test-Path "$WorkDir\jq.exe") {
        Write-Green "jq already installed"
        return
    }
    Write-Yellow "正在下载 jq..."
    $archInfo = Get-Arch
    $jqArch = if ($archInfo.ARCH -eq "arm64") { "arm64" } else { "amd64" }
    $jqUrl = "https://github.com/jqlang/jq/releases/latest/download/jq-windows-$jqArch.exe"

    try {
        Invoke-WebRequest -Uri $jqUrl -OutFile "$WorkDir\jq.exe" -UseBasicParsing
        Write-Green "jq 安装成功"
    }
    catch {
        Write-Red "jq 下载失败: $_"
    }
}

# ==========================================
# 安装 Xray + Cloudflared
# ==========================================
function Install-Xray {
    Clear-Host
    Write-Purple "正在安装 Xray-2go (Windows) 中，请稍等..."
    $archInfo = Get-Arch

    # 自动分配端口
    Assign-Ports

    # 创建工作目录
    if (-not (Test-Path $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }

    # 生成 UUID 和密码
    $script:UUID = New-UUID
    $script:password = New-Password

    # 下载 Xray
    Write-Yellow "下载 Xray..."
    $xrayUrl = "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-windows-$($archInfo.ARCH_ARG).zip"
    $xrayZip = "$WorkDir\xray.zip"
    try {
        Invoke-WebRequest -Uri $xrayUrl -OutFile $xrayZip -UseBasicParsing
        Expand-Archive -Path $xrayZip -DestinationPath "$WorkDir\xray_tmp" -Force
        Copy-Item "$WorkDir\xray_tmp\xray.exe" "$WorkDir\xray.exe" -Force
        Remove-Item "$WorkDir\xray_tmp" -Recurse -Force
        Remove-Item $xrayZip -Force
        Write-Green "Xray 下载完成"
    }
    catch {
        Write-Red "Xray 下载失败: $_"
        return
    }

    # 下载 Cloudflared
    Write-Yellow "下载 cloudflared..."
    $cfArch = if ($archInfo.ARCH -eq "arm64") { "arm64" } else { "amd64" }
    $cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$cfArch.exe"
    try {
        Invoke-WebRequest -Uri $cfUrl -OutFile "$WorkDir\argo.exe" -UseBasicParsing
        Write-Green "cloudflared 下载完成"
    }
    catch {
        Write-Red "cloudflared 下载失败: $_"
        return
    }

    # 生成 x25519 密钥对
    Write-Yellow "生成密钥对..."
    $output = & "$WorkDir\xray.exe" x25519 2>&1
    $script:privateKey = ($output | Select-String "Private" | ForEach-Object { ($_ -split '\s+')[-1] })
    $script:publicKey = ($output | Select-String "Public" | ForEach-Object { ($_ -split '\s+')[-1] })

    if (-not $script:privateKey -or -not $script:publicKey) {
        Write-Red "x25519 密钥生成失败"
        Write-Yellow "输出: $output"
        return
    }
    Write-Green "密钥对生成成功"

    # 保存端口配置
    Save-Ports

    # 添加防火墙规则
    Write-Yellow "配置防火墙规则..."
    $ports = @($script:PORT, $script:ARGO_PORT, $script:GRPC_PORT, $script:XHTTP_PORT)
    foreach ($p in $ports) {
        $ruleName = "Xray2go_Port_$p"
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Green "防火墙规则已添加"

    # 生成配置文件
    $config = @"
{
  "log": { "access": "none", "error": "none", "loglevel": "none" },
  "inbounds": [
    {
      "port": $($script:ARGO_PORT),
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$($script:UUID)", "flow": "xtls-rprx-vision" }],
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
      "settings": { "clients": [{ "id": "$($script:UUID)" }], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    {
      "port": 3002, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$($script:UUID)", "level": 0 }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "port": 3003, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{ "id": "$($script:UUID)", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
    },
    {
      "listen": "::", "port": $($script:XHTTP_PORT), "protocol": "vless",
      "settings": { "clients": [{ "id": "$($script:UUID)" }], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "security": "reality", "realitySettings": { "target": "www.nazhumi.com:443", "xver": 0, "serverNames": ["www.nazhumi.com"], "privateKey": "$($script:privateKey)", "shortIds": [""] } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "listen": "::", "port": $($script:GRPC_PORT), "protocol": "vless",
      "settings": { "clients": [{ "id": "$($script:UUID)" }], "decryption": "none" },
      "streamSettings": { "network": "grpc", "security": "reality", "realitySettings": { "dest": "www.iij.ad.jp:443", "serverNames": ["www.iij.ad.jp"], "privateKey": "$($script:privateKey)", "shortIds": [""] }, "grpcSettings": { "serviceName": "grpc" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
"@
    $config | Out-File -FilePath $ConfigDir -Encoding UTF8
    Write-Green "配置文件已生成"
}

# ==========================================
# Windows 服务管理（使用 NSSM）
# ==========================================
function Install-Services {
    Load-Ports

    # 安装 Xray 服务
    Write-Yellow "正在创建 Xray 服务..."
    & $NssmPath stop xray 2>$null
    & $NssmPath remove xray confirm 2>$null
    & $NssmPath install xray "$WorkDir\xray.exe" "run -c `"$ConfigDir`""
    & $NssmPath set xray AppDirectory "$WorkDir"
    & $NssmPath set xray DisplayName "Xray Service"
    & $NssmPath set xray Start SERVICE_AUTO_START
    & $NssmPath set xray AppStdout "$WorkDir\xray_out.log"
    & $NssmPath set xray AppStderr "$WorkDir\xray_error.log"
    & $NssmPath start xray
    Write-Green "Xray 服务已创建并启动"

    # 安装 Cloudflared Tunnel 服务
    Write-Yellow "正在创建 Argo Tunnel 服务..."
    & $NssmPath stop cloudflared-tunnel 2>$null
    & $NssmPath remove cloudflared-tunnel confirm 2>$null
    & $NssmPath install cloudflared-tunnel "$WorkDir\argo.exe" "tunnel --url http://localhost:$($script:ARGO_PORT) --no-autoupdate --edge-ip-version auto --protocol http2"
    & $NssmPath set cloudflared-tunnel AppDirectory "$WorkDir"
    & $NssmPath set cloudflared-tunnel DisplayName "Cloudflare Tunnel"
    & $NssmPath set cloudflared-tunnel Start SERVICE_AUTO_START
    & $NssmPath set cloudflared-tunnel AppStdout "$WorkDir\argo.log"
    & $NssmPath set cloudflared-tunnel AppStderr "$WorkDir\argo.log"
    & $NssmPath start cloudflared-tunnel
    Write-Green "Argo Tunnel 服务已创建并启动"
}

# Caddy 服务
function Install-CaddyService {
    Load-Ports

    # 生成 Caddyfile
    $caddyConfig = @"
{
    auto_https off
    log {
        output file $WorkDir\caddy.log {
            roll_size 10MB
            roll_keep 10
            roll_keep_for 720h
        }
    }
}

:$($script:PORT) {
    handle /$($script:password) {
        root * $WorkDir
        try_files /sub.txt
        file_server browse
        header Content-Type "text/plain; charset=utf-8"
    }

    handle {
        respond "404 Not Found" 404
    }
}
"@
    $caddyConfig | Out-File -FilePath "$WorkDir\Caddyfile" -Encoding UTF8

    # 验证配置
    $validateResult = & "$WorkDir\caddy.exe" validate --config "$WorkDir\Caddyfile" 2>&1
    if ($LASTEXITCODE -eq 0) {
        & $NssmPath stop caddy 2>$null
        & $NssmPath remove caddy confirm 2>$null
        & $NssmPath install caddy "$WorkDir\caddy.exe" "run --config `"$WorkDir\Caddyfile`""
        & $NssmPath set caddy AppDirectory "$WorkDir"
        & $NssmPath set caddy DisplayName "Caddy Web Server"
        & $NssmPath set caddy Start SERVICE_AUTO_START
        & $NssmPath set caddy AppStdout "$WorkDir\caddy_out.log"
        & $NssmPath set caddy AppStderr "$WorkDir\caddy_error.log"
        & $NssmPath start caddy
        Write-Green "Caddy 服务已启动"
    }
    else {
        Write-Red "Caddy 配置验证失败，订阅功能可能无法使用"
    }
}

# ==========================================
# 获取信息并生成节点
# ==========================================
function Get-Info {
    Clear-Host
    Load-Ports

    $IP = Get-RealIP

    # 获取 ISP 信息
    try {
        $geoData = Invoke-RestMethod -Uri "https://api.ip.sb/geoip" -TimeoutSec 3 -Headers @{ "User-Agent" = "Mozilla/5.0" } -UseBasicParsing
        $isp = "$($geoData.country_code)-$($geoData.isp)" -replace ' ', '_'
    }
    catch {
        $isp = "vps"
    }

    # 获取 Argo 域名
    $argodomain = $null
    $argoLog = "$WorkDir\argo.log"
    if (Test-Path $argoLog) {
        for ($i = 1; $i -le 10; $i++) {
            Write-Purple "第 $i 次尝试获取 ArgoDomain 中..."
            $logContent = Get-Content $argoLog -Raw -ErrorAction SilentlyContinue
            if ($logContent -match 'https://([a-zA-Z0-9\-]+\.trycloudflare\.com)') {
                $argodomain = $matches[1]
                break
            }
            Start-Sleep -Seconds 3
        }
    }

    if (-not $argodomain) {
        Write-Red "获取 Argo 临时域名失败，请稍后重试（菜单4 -> 5重新获取）"
        $argodomain = "获取失败请重试"
    }

    Write-Green "`nArgoDomain：$argodomain`n"

    # 生成 VMess JSON
    $vmessJson = @{
        v    = "2"
        ps   = $isp
        add  = $script:CFIP
        port = $script:CFPORT
        id   = $script:UUID
        aid  = "0"
        scy  = "none"
        net  = "ws"
        type = "none"
        host = $argodomain
        path = "/vmess-argo?ed=2560"
        tls  = "tls"
        sni  = $argodomain
        alpn = ""
        fp   = "chrome"
    } | ConvertTo-Json -Compress
    $vmessBase64 = ConvertTo-Base64 $vmessJson

    # CFIP/CFPORT 默认值
    if (-not $script:CFIP) { $script:CFIP = "cdns.doon.eu.org" }
    if (-not $script:CFPORT) { $script:CFPORT = "443" }

    # 生成节点链接
    $urls = @"
vless://$($script:UUID)@${IP}:$($script:GRPC_PORT)??encryption=none&security=reality&sni=www.iij.ad.jp&fp=chrome&pbk=$($script:publicKey)&allowInsecure=1&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#${isp}

vless://$($script:UUID)@${IP}:$($script:XHTTP_PORT)?encryption=none&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=$($script:publicKey)&allowInsecure=1&type=xhttp&mode=auto#${isp}

vless://$($script:UUID)@$($script:CFIP):$($script:CFPORT)?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}

vmess://${vmessBase64}

"@
    $urls | Out-File -FilePath $ClientDir -Encoding UTF8

    Write-Purple $urls

    # 生成 sub.txt
    $subContent = ConvertTo-Base64 $urls
    $subContent | Out-File -FilePath "$WorkDir\sub.txt" -Encoding UTF8 -NoNewline

    Write-Yellow "`n温馨提醒：如果是 NAT 机，reality 端口和订阅端口需使用可用端口范围内的端口`n"
    Write-Green "节点订阅链接：http://${IP}:$($script:PORT)/$($script:password)"
    Write-Green "`n订阅链接适用于 V2rayN, NekoBox, Karing, Sterisand, Loon, 小火箭, 圈X 等`n"

    # 自动导出
    Export-ProxyTxt -Mode "auto"
}

# ==========================================
# 导出代理为 txt
# ==========================================
function Export-ProxyTxt {
    param([string]$Mode = "manual", [string]$TargetDir = $ExportDir)

    Load-Ports

    if (-not (Test-Path $ClientDir)) {
        Write-Red "节点文件不存在，请先安装 Xray-2go"
        return
    }

    $IP = Get-RealIP
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $exportFile = Join-Path $TargetDir "xray2go_proxy_${timestamp}.txt"
    $exportFileLatest = Join-Path $TargetDir "xray2go_proxy_latest.txt"

    # 读取 Argo 域名
    $argodomain = ""
    $argoLog = "$WorkDir\argo.log"
    if (Test-Path $argoLog) {
        $logContent = Get-Content $argoLog -Raw -ErrorAction SilentlyContinue
        if ($logContent -match 'https://([a-zA-Z0-9\-]+\.trycloudflare\.com)') {
            $argodomain = $matches[1]
        }
    }

    # 读取订阅信息
    $subPort = $script:PORT
    $subPath = $script:password
    if (Test-Path "$WorkDir\Caddyfile") {
        $caddyContent = Get-Content "$WorkDir\Caddyfile" -Raw
        if ($caddyContent -match ':(\d+)') { $subPort = $matches[1] }
        if ($caddyContent -match 'handle /(\w+)') { $subPath = $matches[1] }
    }

    # 读取节点链接
    $urlContent = Get-Content $ClientDir -ErrorAction SilentlyContinue
    $line1 = ($urlContent | Where-Object { $_ -match 'grpc' } | Select-Object -First 1)
    $line2 = ($urlContent | Where-Object { $_ -match 'xhttp' } | Select-Object -First 1)
    $line3 = ($urlContent | Where-Object { $_ -match 'vless.*ws' } | Select-Object -First 1)
    $line4 = ($urlContent | Where-Object { $_ -match '^vmess://' } | Select-Object -First 1)

    $detailedContent = @"
============================================
  Xray-2go 代理节点信息 (Windows)
  导出时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  服务器IP: ${IP}
============================================

【端口信息】
  订阅端口:  ${subPort}
  Argo端口:  $($script:ARGO_PORT)
  GRPC端口:  $($script:GRPC_PORT)
  XHTTP端口: $($script:XHTTP_PORT)

【UUID】
  $($script:UUID)

【Argo 域名】
  $(if ($argodomain) { $argodomain } else { "未获取到" })

============================================
  节点链接（可直接导入客户端）
============================================

--- VLESS GRPC Reality ---
$line1

--- VLESS XHTTP Reality ---
$line2

--- VLESS WS (Argo) ---
$line3

--- VMess WS (Argo) ---
$line4

============================================
  订阅链接
============================================

http://${IP}:${subPort}/${subPath}

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
"@
    $detailedContent | Out-File -FilePath $exportFile -Encoding UTF8
    Copy-Item $exportFile $exportFileLatest -Force

    # 纯链接版
    $linksFile = Join-Path $TargetDir "xray2go_links_${timestamp}.txt"
    $linksFileLatest = Join-Path $TargetDir "xray2go_links_latest.txt"

    $linksContent = ($urlContent | Where-Object { $_.Trim() -ne "" }) -join "`n"
    $linksContent += "`n`n# 订阅链接`nhttp://${IP}:${subPort}/${subPath}"
    $linksContent | Out-File -FilePath $linksFile -Encoding UTF8
    Copy-Item $linksFile $linksFileLatest -Force

    if ($Mode -eq "auto") {
        Write-Green "`n代理信息已自动导出到当前目录："
    }
    else {
        Write-Green "`n代理信息已导出："
    }
    Write-Green "  详细版: $exportFile"
    Write-Green "  详细版(latest): $exportFileLatest"
    Write-Green "  纯链接: $linksFile"
    Write-Green "  纯链接(latest): $linksFileLatest`n"
}

# ==========================================
# 服务管理函数
# ==========================================
function Start-Xray {
    $status = Check-Xray
    if ($status -eq 1) {
        Write-Yellow "`n正在启动 Xray 服务..."
        & $NssmPath start xray 2>$null
        Start-Sleep -Seconds 1
        if ((Check-Xray) -eq 0) { Write-Green "Xray 服务已成功启动`n" }
        else { Write-Red "Xray 服务启动失败`n" }
    }
    elseif ($status -eq 0) { Write-Yellow "Xray 正在运行`n" }
    else { Write-Yellow "Xray 尚未安装!`n" }
}

function Stop-Xray {
    $status = Check-Xray
    if ($status -eq 0) {
        Write-Yellow "`n正在停止 Xray 服务..."
        & $NssmPath stop xray 2>$null
        Start-Sleep -Seconds 1
        Write-Green "Xray 服务已停止`n"
    }
    elseif ($status -eq 1) { Write-Yellow "Xray 未运行`n" }
    else { Write-Yellow "Xray 尚未安装!`n" }
}

function Restart-Xray {
    $status = Check-Xray
    if ($status -eq 0 -or $status -eq 1) {
        Write-Yellow "`n正在重启 Xray 服务..."
        & $NssmPath restart xray 2>$null
        Start-Sleep -Seconds 1
        if ((Check-Xray) -eq 0) { Write-Green "Xray 服务已成功重启`n" }
        else { Write-Red "Xray 服务重启失败`n" }
    }
    else { Write-Yellow "Xray 尚未安装!`n" }
}

function Start-Argo {
    $status = Check-Argo
    if ($status -eq 1) {
        Write-Yellow "`n正在启动 Argo 服务..."
        & $NssmPath start cloudflared-tunnel 2>$null
        Start-Sleep -Seconds 1
        Write-Green "Argo 服务已启动`n"
    }
    elseif ($status -eq 0) { Write-Green "Argo 服务正在运行`n" }
    else { Write-Yellow "Argo 尚未安装!`n" }
}

function Stop-Argo {
    $status = Check-Argo
    if ($status -eq 0) {
        Write-Yellow "`n正在停止 Argo 服务..."
        & $NssmPath stop cloudflared-tunnel 2>$null
        Start-Sleep -Seconds 1
        Write-Green "Argo 服务已停止`n"
    }
    elseif ($status -eq 1) { Write-Yellow "Argo 服务未运行`n" }
    else { Write-Yellow "Argo 尚未安装!`n" }
}

function Restart-Argo {
    $status = Check-Argo
    if ($status -eq 0 -or $status -eq 1) {
        Write-Yellow "`n正在重启 Argo 服务..."
        Remove-Item "$WorkDir\argo.log" -Force -ErrorAction SilentlyContinue
        & $NssmPath restart cloudflared-tunnel 2>$null
        Start-Sleep -Seconds 1
        Write-Green "Argo 服务已重启`n"
    }
    else { Write-Yellow "Argo 尚未安装!`n" }
}

function Start-CaddySvc {
    if (Test-Path "$WorkDir\caddy.exe") {
        Write-Yellow "`n正在启动 Caddy 服务..."
        & $NssmPath start caddy 2>$null
        Start-Sleep -Seconds 1
        Write-Green "Caddy 服务已启动`n"
    }
    else { Write-Yellow "Caddy 尚未安装!`n" }
}

function Restart-CaddySvc {
    if (Test-Path "$WorkDir\caddy.exe") {
        Write-Yellow "`n正在重启 Caddy 服务..."
        & $NssmPath restart caddy 2>$null
        Start-Sleep -Seconds 1
        Write-Green "Caddy 服务已重启`n"
    }
    else { Write-Yellow "Caddy 尚未安装!`n" }
}

# ==========================================
# 卸载
# ==========================================
function Uninstall-Xray {
    $choice = Read-Host "确定要卸载 xray-2go 吗? (y/n)"
    if ($choice -eq 'y' -or $choice -eq 'Y') {
        Write-Yellow "正在卸载 xray-2go..."

        # 停止并删除服务
        & $NssmPath stop xray 2>$null
        & $NssmPath remove xray confirm 2>$null
        & $NssmPath stop cloudflared-tunnel 2>$null
        & $NssmPath remove cloudflared-tunnel confirm 2>$null
        & $NssmPath stop caddy 2>$null
        & $NssmPath remove caddy confirm 2>$null

        # 删除防火墙规则
        Get-NetFirewallRule -DisplayName "Xray2go_Port_*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

        # 删除工作目录
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-Green "`nXray-2go 卸载成功`n"
    }
    else {
        Write-Purple "已取消卸载操作`n"
    }
}

# ==========================================
# 获取 Argo 临时隧道
# ==========================================
function Get-QuickTunnel {
    Restart-Argo
    Write-Yellow "获取临时 Argo 域名中，请稍等...`n"
    Start-Sleep -Seconds 5

    $argodomain = $null
    $argoLog = "$WorkDir\argo.log"
    if (Test-Path $argoLog) {
        for ($i = 1; $i -le 10; $i++) {
            $logContent = Get-Content $argoLog -Raw -ErrorAction SilentlyContinue
            if ($logContent -match 'https://([a-zA-Z0-9\-]+\.trycloudflare\.com)') {
                $argodomain = $matches[1]
                break
            }
            Start-Sleep -Seconds 3
        }
    }

    if ($argodomain) {
        Write-Green "ArgoDomain: $argodomain`n"
    }
    else {
        Write-Red "获取 Argo 域名失败，请检查网络后重试`n"
    }

    $script:ArgoDomain = $argodomain
}

# 更新 Argo 域名到订阅
function Update-ArgoDomain {
    if (-not $script:ArgoDomain) {
        Write-Red "Argo 域名为空，无法更新"
        return
    }

    Load-Ports

    if (Test-Path $ClientDir) {
        $content = Get-Content $ClientDir -Raw

        # 替换 vless-ws 的 sni 和 host
        $content = $content -replace 'sni=[^&]*trycloudflare\.com', "sni=$($script:ArgoDomain)"
        $content = $content -replace 'host=[^&]*trycloudflare\.com', "host=$($script:ArgoDomain)"

        # 替换 vmess 中的域名
        $vmessPattern = 'vmess://([A-Za-z0-9+/=]+)'
        if ($content -match $vmessPattern) {
            try {
                $decoded = ConvertFrom-Base64 $matches[1]
                $vmessObj = $decoded | ConvertFrom-Json
                $vmessObj.host = $script:ArgoDomain
                $vmessObj.sni = $script:ArgoDomain
                $newVmessJson = $vmessObj | ConvertTo-Json -Compress
                $newVmessB64 = ConvertTo-Base64 $newVmessJson
                $content = $content -replace $vmessPattern, "vmess://$newVmessB64"
            }
            catch {
                Write-Yellow "VMess 节点更新失败: $_"
            }
        }

        $content | Out-File -FilePath $ClientDir -Encoding UTF8

        # 更新 sub.txt
        $subContent = ConvertTo-Base64 $content
        $subContent | Out-File -FilePath "$WorkDir\sub.txt" -Encoding UTF8 -NoNewline

        Write-Purple $content
        Write-Green "`n节点已更新，更新订阅或手动复制以上节点`n"
    }
}

# ==========================================
# 变更配置
# ==========================================
function Change-Config {
    Load-Ports
    Clear-Host
    Write-Host ""
    Write-Green "1. 修改UUID"
    Write-SkyBlue "------------"
    Write-Green "2. 修改grpc-reality端口"
    Write-SkyBlue "------------"
    Write-Green "3. 修改xhttp-reality端口"
    Write-SkyBlue "------------"
    Write-Green "4. 修改reality节点伪装域名"
    Write-SkyBlue "------------"
    Write-Purple "0. 返回主菜单"
    Write-SkyBlue "------------"

    $choice = Read-Host "请输入选择"
    switch ($choice) {
        "1" {
            $newUuid = Read-Host "`n请输入新的UUID (回车自动生成)"
            if (-not $newUuid) {
                $newUuid = New-UUID
                Write-Green "`n生成的UUID为：$newUuid"
            }

            # 更新配置文件
            $configContent = Get-Content $ConfigDir -Raw
            $configContent = $configContent -replace '[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}', $newUuid
            $configContent | Out-File -FilePath $ConfigDir -Encoding UTF8

            # 更新 ports.env
            $portsContent = Get-Content $PortsEnvFile -Raw
            $portsContent = $portsContent -replace 'UUID=.*', "UUID=$newUuid"
            $portsContent | Out-File -FilePath $PortsEnvFile -Encoding UTF8

            Restart-Xray

            # 更新节点文件
            if (Test-Path $ClientDir) {
                $urlContent = Get-Content $ClientDir -Raw
                $urlContent = $urlContent -replace '[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}', $newUuid
                $urlContent | Out-File -FilePath $ClientDir -Encoding UTF8

                $subContent = ConvertTo-Base64 $urlContent
                $subContent | Out-File -FilePath "$WorkDir\sub.txt" -Encoding UTF8 -NoNewline
            }

            Write-Green "`nUUID已修改为：$newUuid 请更新订阅或手动更改所有节点的UUID`n"
        }
        "2" {
            $newPort = Read-Host "`n请输入grpc-reality端口 (回车自动分配)"
            if (-not $newPort) { $newPort = Find-AvailablePort -StartPort 2000 -EndPort 65000 }

            $configContent = Get-Content $ConfigDir -Raw
            $configObj = $configContent | ConvertFrom-Json
            $configObj.inbounds[5].port = [int]$newPort
            $configObj | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigDir -Encoding UTF8

            # 更新 ports.env
            (Get-Content $PortsEnvFile) -replace 'GRPC_PORT=.*', "GRPC_PORT=$newPort" | Out-File $PortsEnvFile -Encoding UTF8

            Restart-Xray
            Write-Green "`nGRPC-reality端口已修改成：$newPort 请更新订阅或手动更改grpc-reality节点端口`n"
        }
        "3" {
            $newPort = Read-Host "`n请输入xhttp-reality端口 (回车自动分配)"
            if (-not $newPort) { $newPort = Find-AvailablePort -StartPort 2000 -EndPort 65000 }

            $configContent = Get-Content $ConfigDir -Raw
            $configObj = $configContent | ConvertFrom-Json
            $configObj.inbounds[4].port = [int]$newPort
            $configObj | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigDir -Encoding UTF8

            (Get-Content $PortsEnvFile) -replace 'XHTTP_PORT=.*', "XHTTP_PORT=$newPort" | Out-File $PortsEnvFile -Encoding UTF8

            Restart-Xray
            Write-Green "`nxhttp-reality端口已修改成：$newPort 请更新订阅或手动更改xhttp-reality节点端口`n"
        }
        "4" {
            Clear-Host
            Write-Green "`n1. bgk.jp`n2. www.joom.com`n3. www.stengg.com`n4. www.nazhumi.com`n"
            $sniChoice = Read-Host "`n请输入新的Reality伪装域名(可自定义输入,回车使用默认1)"
            switch ($sniChoice) {
                "" { $newSni = "bgk.jp" }
                "1" { $newSni = "bgk.jp" }
                "2" { $newSni = "www.joom.com" }
                "3" { $newSni = "www.stengg.com" }
                "4" { $newSni = "www.nazhumi.com" }
                default { $newSni = $sniChoice }
            }

            $configObj = Get-Content $ConfigDir -Raw | ConvertFrom-Json
            $configObj.inbounds[5].streamSettings.realitySettings.dest = "${newSni}:443"
            $configObj.inbounds[5].streamSettings.realitySettings.serverNames = @($newSni)
            $configObj | ConvertTo-Json -Depth 10 | Out-File -FilePath $ConfigDir -Encoding UTF8

            Restart-Xray
            Write-Green "`nReality sni已修改为：$newSni 请更新订阅或手动更改reality节点的sni域名`n"
        }
        "0" { return }
        default { Write-Red "无效的选项！" }
    }
}

# ==========================================
# 管理节点订阅
# ==========================================
function Manage-Subscription {
    $xrayStatus = Check-Xray
    if ($xrayStatus -ne 0) {
        Write-Yellow "Xray-2go 尚未安装或未运行！"
        Start-Sleep -Seconds 1
        return
    }

    Clear-Host
    Write-Host ""
    Write-Green "1. 关闭节点订阅"
    Write-SkyBlue "------------"
    Write-Green "2. 开启节点订阅"
    Write-SkyBlue "------------"
    Write-Green "3. 更换订阅端口"
    Write-SkyBlue "------------"
    Write-Purple "4. 返回主菜单"
    Write-SkyBlue "------------"

    $choice = Read-Host "请输入选择"
    switch ($choice) {
        "1" {
            & $NssmPath stop caddy 2>$null
            Write-Green "`n已关闭节点订阅`n"
        }
        "2" {
            $newPassword = New-Password -Length 32
            $caddyContent = Get-Content "$WorkDir\Caddyfile" -Raw
            $caddyContent = $caddyContent -replace 'handle /\w+', "handle /$newPassword"
            $caddyContent | Out-File "$WorkDir\Caddyfile" -Encoding UTF8
            Restart-CaddySvc
            $serverIp = Get-RealIP
            $subPort = if ($caddyContent -match ':(\d+)') { $matches[1] } else { $script:PORT }
            Write-Green "`n新的节点订阅链接：http://${serverIp}:${subPort}/${newPassword}`n"
        }
        "3" {
            $newPort = Read-Host "请输入新的订阅端口(1-65535)"
            if (-not $newPort) { $newPort = Find-AvailablePort -StartPort 2000 -EndPort 65000 }
            $caddyContent = Get-Content "$WorkDir\Caddyfile" -Raw
            $caddyContent = $caddyContent -replace ':\d+\s*\{', ":$newPort {"
            $caddyContent | Out-File "$WorkDir\Caddyfile" -Encoding UTF8
            (Get-Content $PortsEnvFile) -replace 'PORT=.*', "PORT=$newPort" | Out-File $PortsEnvFile -Encoding UTF8
            Restart-CaddySvc
            $serverIp = Get-RealIP
            $path = if ($caddyContent -match 'handle /(\w+)') { $matches[1] } else { $script:password }
            Write-Green "`n订阅端口更换成功`n新的订阅链接为：http://${serverIp}:${newPort}/${path}`n"
        }
        "4" { return }
        default { Write-Red "无效的选项！" }
    }
}

# ==========================================
# Xray 管理子菜单
# ==========================================
function Manage-XrayMenu {
    Write-Green "1. 启动xray服务"
    Write-SkyBlue "-------------------"
    Write-Green "2. 停止xray服务"
    Write-SkyBlue "-------------------"
    Write-Green "3. 重启xray服务"
    Write-SkyBlue "-------------------"
    Write-Purple "4. 返回主菜单"
    Write-SkyBlue "-------------------"

    $choice = Read-Host "`n请输入选择"
    switch ($choice) {
        "1" { Start-Xray }
        "2" { Stop-Xray }
        "3" { Restart-Xray }
        "4" { return }
        default { Write-Red "无效的选项！" }
    }
}

# ==========================================
# Argo 管理子菜单
# ==========================================
function Manage-ArgoMenu {
    $argoStatus = Check-Argo
    if ($argoStatus -eq 2) {
        Write-Yellow "Argo 尚未安装！"
        Start-Sleep -Seconds 1
        return
    }

    Load-Ports
    Clear-Host
    Write-Host ""
    Write-Green "1. 启动Argo服务"
    Write-SkyBlue "------------"
    Write-Green "2. 停止Argo服务"
    Write-SkyBlue "------------"
    Write-Green "3. 添加Argo固定隧道"
    Write-SkyBlue "----------------"
    Write-Green "4. 切换回Argo临时隧道"
    Write-SkyBlue "------------------"
    Write-Green "5. 重新获取Argo临时域名"
    Write-SkyBlue "-------------------"
    Write-Purple "6. 返回主菜单"
    Write-SkyBlue "-----------"

    $choice = Read-Host "`n请输入选择"
    switch ($choice) {
        "1" { Start-Argo }
        "2" { Stop-Argo }
        "3" {
            Clear-Host
            Write-Yellow "`n固定隧道可为json或token，固定隧道端口为$($script:ARGO_PORT)，自行在cf后台设置`n"
            $argoDomain = Read-Host "`n请输入你的argo域名"
            $script:ArgoDomain = $argoDomain
            $argoAuth = Read-Host "`n请输入你的argo密钥(token)"

            if ($argoAuth -match '^[A-Z0-9a-z=]{120,250}$') {
                & $NssmPath stop cloudflared-tunnel 2>$null
                & $NssmPath remove cloudflared-tunnel confirm 2>$null
                & $NssmPath install cloudflared-tunnel "$WorkDir\argo.exe" "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argoAuth"
                & $NssmPath set cloudflared-tunnel AppDirectory "$WorkDir"
                & $NssmPath set cloudflared-tunnel AppStdout "$WorkDir\argo.log"
                & $NssmPath set cloudflared-tunnel AppStderr "$WorkDir\argo.log"
                & $NssmPath start cloudflared-tunnel
                Update-ArgoDomain
            }
            else {
                Write-Yellow "token 格式不匹配，请重新输入"
            }
        }
        "4" {
            & $NssmPath stop cloudflared-tunnel 2>$null
            & $NssmPath remove cloudflared-tunnel confirm 2>$null
            & $NssmPath install cloudflared-tunnel "$WorkDir\argo.exe" "tunnel --url http://localhost:$($script:ARGO_PORT) --no-autoupdate --edge-ip-version auto --protocol http2"
            & $NssmPath set cloudflared-tunnel AppDirectory "$WorkDir"
            & $NssmPath set cloudflared-tunnel AppStdout "$WorkDir\argo.log"
            & $NssmPath set cloudflared-tunnel AppStderr "$WorkDir\argo.log"
            & $NssmPath start cloudflared-tunnel
            Get-QuickTunnel
            Update-ArgoDomain
        }
        "5" {
            Get-QuickTunnel
            Update-ArgoDomain
        }
        "6" { return }
        default { Write-Red "无效的选项！" }
    }
}

# ==========================================
# 查看节点信息
# ==========================================
function Show-Nodes {
    $xrayStatus = Check-Xray
    if ($xrayStatus -eq 0) {
        Load-Ports
        Write-Host ""
        Get-Content $ClientDir | ForEach-Object { Write-Purple $_ }

        $serverIp = Get-RealIP
        $subPort = $script:PORT
        $subPath = $script:password
        if (Test-Path "$WorkDir\Caddyfile") {
            $caddyContent = Get-Content "$WorkDir\Caddyfile" -Raw
            if ($caddyContent -match ':(\d+)') { $subPort = $matches[1] }
            if ($caddyContent -match 'handle /(\w+)') { $subPath = $matches[1] }
        }
        Write-Green "`n`n节点订阅链接：http://${serverIp}:${subPort}/${subPath}`n"
    }
    else {
        Write-Yellow "Xray-2go 尚未安装或未运行，请先安装或启动 Xray-2go"
        Start-Sleep -Seconds 1
    }
}

# ==========================================
# 导出菜单
# ==========================================
function Show-ExportMenu {
    $xrayStatus = Check-Xray
    if ($xrayStatus -ne 0 -and -not (Test-Path $ClientDir)) {
        Write-Yellow "Xray-2go 尚未安装，无节点可导出"
        Start-Sleep -Seconds 1
        return
    }

    Clear-Host
    Write-Host ""
    Write-Green "1. 导出到当前目录 (详细版 + 纯链接版)"
    Write-SkyBlue "--------------------------------------"
    Write-Green "2. 导出到自定义路径"
    Write-SkyBlue "--------------------------------------"
    Write-Green "3. 在终端显示所有节点链接"
    Write-SkyBlue "--------------------------------------"
    Write-Green "4. 复制订阅链接到剪贴板"
    Write-SkyBlue "--------------------------------------"
    Write-Purple "5. 返回主菜单"
    Write-SkyBlue "--------------------------------------"

    $choice = Read-Host "请输入选择"
    switch ($choice) {
        "1" { Export-ProxyTxt -Mode "manual" }
        "2" {
            $customPath = Read-Host "请输入导出路径 (如 C:\Users\Downloads)"
            if (-not $customPath) { $customPath = $ExportDir }
            if (-not (Test-Path $customPath)) {
                New-Item -ItemType Directory -Path $customPath -Force | Out-Null
            }
            Export-ProxyTxt -Mode "manual" -TargetDir $customPath
        }
        "3" {
            Load-Ports
            Write-Host ""
            Write-Green "========== 所有节点链接 =========="
            Write-Host ""
            Get-Content $ClientDir | Where-Object { $_.Trim() -ne "" } | ForEach-Object { Write-Purple $_ }
            $serverIp = Get-RealIP
            $subPort = $script:PORT
            $subPath = $script:password
            if (Test-Path "$WorkDir\Caddyfile") {
                $cc = Get-Content "$WorkDir\Caddyfile" -Raw
                if ($cc -match ':(\d+)') { $subPort = $matches[1] }
                if ($cc -match 'handle /(\w+)') { $subPath = $matches[1] }
            }
            Write-Host ""
            Write-Green "========== 订阅链接 =========="
            Write-Green "http://${serverIp}:${subPort}/${subPath}"
            Write-Host ""
            Write-Green "================================"
        }
        "4" {
            Load-Ports
            $serverIp = Get-RealIP
            $subPort = $script:PORT
            $subPath = $script:password
            if (Test-Path "$WorkDir\Caddyfile") {
                $cc = Get-Content "$WorkDir\Caddyfile" -Raw
                if ($cc -match ':(\d+)') { $subPort = $matches[1] }
                if ($cc -match 'handle /(\w+)') { $subPath = $matches[1] }
            }
            $subLink = "http://${serverIp}:${subPort}/${subPath}"
            Set-Clipboard -Value $subLink
            Write-Green "`n订阅链接已复制到剪贴板：$subLink`n"
        }
        "5" { return }
        default { Write-Red "无效的选项！" }
    }
}

# ==========================================
# 主菜单
# ==========================================
function Show-Menu {
    while ($true) {
        $xrayStatus = Check-Xray
        $argoStatus = Check-Argo
        $caddyStatus = Check-Caddy

        Clear-Host
        Write-Host ""
        Write-Purple "=== 老王Xray-2go一键安装脚本 (Windows版) ===`n"
        Write-Purple " Xray 状态: $(Get-StatusText $xrayStatus)"
        Write-Purple " Argo 状态: $(Get-StatusText $argoStatus)"
        Write-Purple "Caddy 状态: $(Get-StatusText $caddyStatus)`n"
        Write-Green  "1. 安装Xray-2go"
        Write-Red    "2. 卸载Xray-2go"
        Write-Host   "==============="
        Write-Green  "3. Xray-2go管理"
        Write-Green  "4. Argo隧道管理"
        Write-Host   "==============="
        Write-Green  "5. 查看节点信息"
        Write-Green  "6. 修改节点配置"
        Write-Green  "7. 管理节点订阅"
        Write-Host   "==============="
        Write-SkyBlue "8. 导出代理为txt"
        Write-Host   "==============="
        Write-Red    "0. 退出脚本"
        Write-Host   "==========="

        $choice = Read-Host "请输入选择(0-8)"
        Write-Host ""

        switch ($choice) {
            "1" {
                if ($xrayStatus -eq 0) {
                    Write-Yellow "Xray-2go 已经安装！"
                }
                else {
                    Install-NSSM
                    Install-Caddy
                    Install-Jq
                    Install-Xray
                    Install-Services
                    Start-Sleep -Seconds 3
                    Get-Info
                    Install-CaddyService
                }
            }
            "2" { Uninstall-Xray }
            "3" { Manage-XrayMenu }
            "4" { Manage-ArgoMenu }
            "5" { Show-Nodes }
            "6" { Change-Config }
            "7" { Manage-Subscription }
            "8" { Show-ExportMenu }
            "0" { exit 0 }
            default { Write-Red "无效的选项，请输入 0 到 8" }
        }

        Write-Host ""
        Write-Host -NoNewline -ForegroundColor Red "按任意键继续..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}

# 启动
Show-Menu
