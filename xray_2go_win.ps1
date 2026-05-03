# ===========================================
# Xray-2go Windows PowerShell 版
# 自动端口选择、多API获取IP、导出代理为txt
# 需要以管理员身份运行
# ===========================================

#Requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# 定义常量
$ServerName = 'xray'
$WorkDir = "$env:USERPROFILE\.xray"
$ConfigDir = "$WorkDir\config.json"
$ClientDir = "$WorkDir\url.txt"
$ExportDir = (Get-Location).Path
$PortsEnvFile = "$WorkDir\ports.env"
$NssmPath = "$WorkDir\nssm.exe"
$CFIP = 'cdns.doon.eu.org'
$CFPORT = '443'
if ($env:REALITY_GRPC_SNI) { $script:REALITY_GRPC_SNI = $env:REALITY_GRPC_SNI } else { $script:REALITY_GRPC_SNI = 'www.iij.ad.jp' }
if ($env:REALITY_GRPC_TARGET) { $script:REALITY_GRPC_TARGET = $env:REALITY_GRPC_TARGET } else { $script:REALITY_GRPC_TARGET = $script:REALITY_GRPC_SNI }
if ($env:REALITY_XHTTP_SNI) { $script:REALITY_XHTTP_SNI = $env:REALITY_XHTTP_SNI } else { $script:REALITY_XHTTP_SNI = 'www.nazhumi.com' }
if ($env:REALITY_XHTTP_TARGET) { $script:REALITY_XHTTP_TARGET = $env:REALITY_XHTTP_TARGET } else { $script:REALITY_XHTTP_TARGET = $script:REALITY_XHTTP_SNI }

# ==========================================
# 颜色输出
# ==========================================
function Write-Red { param([string]$Text); Write-Host $Text -ForegroundColor Red }
function Write-Green { param([string]$Text); Write-Host $Text -ForegroundColor Green }
function Write-Yellow { param([string]$Text); Write-Host $Text -ForegroundColor Yellow }
function Write-Purple { param([string]$Text); Write-Host $Text -ForegroundColor Magenta }
function Write-SkyBlue { param([string]$Text); Write-Host $Text -ForegroundColor Cyan }

# ==========================================
# 工具函数
# ==========================================
function Set-RealityDefaults {
    if (-not $script:REALITY_GRPC_SNI) {
        if ($env:REALITY_GRPC_SNI) { $script:REALITY_GRPC_SNI = $env:REALITY_GRPC_SNI } else { $script:REALITY_GRPC_SNI = 'www.iij.ad.jp' }
    }
    if (-not $script:REALITY_GRPC_TARGET) {
        if ($env:REALITY_GRPC_TARGET) { $script:REALITY_GRPC_TARGET = $env:REALITY_GRPC_TARGET } else { $script:REALITY_GRPC_TARGET = $script:REALITY_GRPC_SNI }
    }
    if (-not $script:REALITY_XHTTP_SNI) {
        if ($env:REALITY_XHTTP_SNI) { $script:REALITY_XHTTP_SNI = $env:REALITY_XHTTP_SNI } else { $script:REALITY_XHTTP_SNI = 'www.nazhumi.com' }
    }
    if (-not $script:REALITY_XHTTP_TARGET) {
        if ($env:REALITY_XHTTP_TARGET) { $script:REALITY_XHTTP_TARGET = $env:REALITY_XHTTP_TARGET } else { $script:REALITY_XHTTP_TARGET = $script:REALITY_XHTTP_SNI }
    }
}

function Find-AvailablePort {
    param(
        [int]$StartPort = 1000,
        [int]$EndPort = 60000
    )
    for ($i = 0; $i -lt 50; $i++) {
        $port = Get-Random -Minimum $StartPort -Maximum $EndPort
        $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if (-not $listener) {
            return $port
        }
    }
    return (Get-Random -Minimum $StartPort -Maximum $EndPort)
}

function Assign-Ports {
    Write-Yellow '正在自动分配可用端口...'

    $script:PORT = Find-AvailablePort -StartPort 1000 -EndPort 60000
    $script:ARGO_PORT = Find-AvailablePort -StartPort 8000 -EndPort 9000
    while ($script:ARGO_PORT -eq $script:PORT) {
        $script:ARGO_PORT = Find-AvailablePort -StartPort 8000 -EndPort 9000
    }
    $script:FB_TCP_PORT = Find-AvailablePort -StartPort 31001 -EndPort 32000
    $script:FB_VLESS_WS_PORT = Find-AvailablePort -StartPort 32001 -EndPort 33000
    $script:FB_VMESS_WS_PORT = Find-AvailablePort -StartPort 33001 -EndPort 34000
    $script:GRPC_PORT = Find-AvailablePort -StartPort 10000 -EndPort 30000
    while (($script:GRPC_PORT -eq $script:PORT) -or ($script:GRPC_PORT -eq $script:ARGO_PORT) -or ($script:GRPC_PORT -eq $script:FB_TCP_PORT) -or ($script:GRPC_PORT -eq $script:FB_VLESS_WS_PORT) -or ($script:GRPC_PORT -eq $script:FB_VMESS_WS_PORT)) {
        $script:GRPC_PORT = Find-AvailablePort -StartPort 10000 -EndPort 30000
    }
    $script:XHTTP_PORT = Find-AvailablePort -StartPort 30001 -EndPort 50000
    while (($script:XHTTP_PORT -eq $script:PORT) -or ($script:XHTTP_PORT -eq $script:ARGO_PORT) -or ($script:XHTTP_PORT -eq $script:GRPC_PORT)) {
        $script:XHTTP_PORT = Find-AvailablePort -StartPort 30001 -EndPort 50000
    }
    $script:HY2_PORT = Find-AvailablePort -StartPort 35001 -EndPort 40000
    while (($script:HY2_PORT -eq $script:PORT) -or ($script:HY2_PORT -eq $script:ARGO_PORT) -or ($script:HY2_PORT -eq $script:GRPC_PORT) -or ($script:HY2_PORT -eq $script:XHTTP_PORT)) {
        $script:HY2_PORT = Find-AvailablePort -StartPort 35001 -EndPort 40000
    }

    Write-Green '端口分配完成：'
    Write-Green "  订阅端口 (PORT):       $($script:PORT)"
    Write-Green "  Argo 端口 (ARGO_PORT): $($script:ARGO_PORT)"
    Write-Green "  Argo 内部 TCP 回落端口: $($script:FB_TCP_PORT)"
    Write-Green "  Argo 内部 VLESS-WS 端口:$($script:FB_VLESS_WS_PORT)"
    Write-Green "  Argo 内部 VMess-WS 端口:$($script:FB_VMESS_WS_PORT)"
    Write-Green "  GRPC 端口:             $($script:GRPC_PORT)"
    Write-Green "  XHTTP 端口:            $($script:XHTTP_PORT)"
    Write-Green "  Hysteria2 端口 (UDP):  $($script:HY2_PORT)"
}

function Save-Ports {
    $content = @(
        "PORT=$($script:PORT)",
        "ARGO_PORT=$($script:ARGO_PORT)",
        "FB_TCP_PORT=$($script:FB_TCP_PORT)",
        "FB_VLESS_WS_PORT=$($script:FB_VLESS_WS_PORT)",
        "FB_VMESS_WS_PORT=$($script:FB_VMESS_WS_PORT)",
        "GRPC_PORT=$($script:GRPC_PORT)",
        "XHTTP_PORT=$($script:XHTTP_PORT)",
        "HY2_PORT=$($script:HY2_PORT)",
        "password=$($script:password)",
        "hy2_password=$($script:hy2Password)",
        "private_key=$($script:privateKey)",
        "public_key=$($script:publicKey)",
        "UUID=$($script:UUID)",
        "REALITY_GRPC_TARGET=$($script:REALITY_GRPC_TARGET)",
        "REALITY_GRPC_SNI=$($script:REALITY_GRPC_SNI)",
        "REALITY_XHTTP_TARGET=$($script:REALITY_XHTTP_TARGET)",
        "REALITY_XHTTP_SNI=$($script:REALITY_XHTTP_SNI)"
    )
    $content -join "`r`n" | Out-File -FilePath $PortsEnvFile -Encoding UTF8
}

function Load-Ports {
    if (Test-Path $PortsEnvFile) {
        $lines = Get-Content $PortsEnvFile
        foreach ($line in $lines) {
            if ($line -match '^([^=]+)=(.*)$') {
                $varName = $matches[1].Trim()
                $varValue = $matches[2].Trim()
                Set-Variable -Name $varName -Value $varValue -Scope Script
            }
        }
    }
    Set-RealityDefaults
}



function Add-PortEnvLines {
    param([string[]]$Lines)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    Add-Content -Path $PortsEnvFile -Value $Lines -Encoding UTF8
}

function Test-PrivateOrCgnatIPv4 {
    param([string]$Ip)
    if ($Ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $true }
    $parts = $Ip.Split('.') | ForEach-Object { [int]$_ }
    if ($parts[0] -eq 10) { return $true }
    if ($parts[0] -eq 127) { return $true }
    if ($parts[0] -eq 169 -and $parts[1] -eq 254) { return $true }
    if ($parts[0] -eq 172 -and $parts[1] -ge 16 -and $parts[1] -le 31) { return $true }
    if ($parts[0] -eq 192 -and $parts[1] -eq 168) { return $true }
    if ($parts[0] -eq 100 -and $parts[1] -ge 64 -and $parts[1] -le 127) { return $true }
    return $false
}

function Get-DefaultIPv4 {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
        if ($route) {
            $addr = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
            if ($addr) { return $addr.IPAddress }
        }
    }
    catch {}
    return $null
}

function Test-NatMachine {
    if ($env:XRAY2GO_FORCE_DIRECT -eq '1') {
        Write-Yellow '已设置 XRAY2GO_FORCE_DIRECT=1，跳过 NAT 自动 Argo-only 策略。'
        return $false
    }
    $localIp = Get-DefaultIPv4
    $publicIp = $null
    try { $publicIp = (Invoke-WebRequest -Uri 'https://api.ipify.org' -TimeoutSec 5 -UseBasicParsing).Content.Trim() } catch {}
    if (-not $localIp) {
        Write-Yellow '未检测到默认 IPv4 出口，按 NAT/家宽机器处理。'
        return $true
    }
    if (Test-PrivateOrCgnatIPv4 $localIp) {
        Write-Yellow "检测到本机出口地址为内网/CGNAT：$localIp，按 NAT/家宽机器处理。"
        return $true
    }
    if ($publicIp -match '^\d+\.\d+\.\d+\.\d+$' -and $publicIp -ne $localIp) {
        Write-Yellow "检测到公网出口 IP($publicIp) 与本机出口 IP($localIp) 不一致，按 NAT/家宽机器处理。"
        return $true
    }
    return $false
}

function Apply-NatArgoPolicy {
    Load-Ports
    if (Test-NatMachine) {
        $mode = 'quick'
        if ($script:ARGO_MODE) { $mode = $script:ARGO_MODE }
        Add-PortEnvLines @("ARGO_MODE=$mode", 'XRAY2GO_ARGO_ONLY=1')
        $script:ARGO_MODE = $mode
        $script:XRAY2GO_ARGO_ONLY = '1'
        Write-Green 'NAT/家宽机器：已自动启用 Argo-only 节点输出。'
    }
    else {
        Write-Green '检测到本机可能具备公网 IPv4 入口：保留直连节点输出。'
    }
}


function Get-CurrentArgoDomain {
    Load-Ports
    if ($script:ARGO_MODE -eq 'fixed' -and $script:ARGO_DOMAIN) { return $script:ARGO_DOMAIN }
    $argoLog = Join-Path $WorkDir 'argo.log'
    if (Test-Path $argoLog) { return Get-ArgoDomain -LogFile $argoLog }
    return $null
}

function Get-SubscriptionUrl {
    param(
        [string]$IP,
        [string]$Port,
        [string]$Path,
        [string]$ArgoDomain = $null
    )
    Load-Ports
    if ($script:XRAY2GO_ARGO_ONLY -eq '1') {
        if (-not $ArgoDomain) { $ArgoDomain = Get-CurrentArgoDomain }
        if ($ArgoDomain -and $ArgoDomain -ne 'failed.trycloudflare.com') {
            return "https://$ArgoDomain/$Path"
        }
    }
    return "http://${IP}:${Port}/${Path}"
}

function Invoke-CFApi {
    param([string]$Method, [string]$Path, [object]$Body = $null)
    $headers = @{ Authorization = "Bearer $($env:CF_API_TOKEN)"; 'Content-Type' = 'application/json' }
    $uri = "https://api.cloudflare.com/client/v4$Path"
    if ($null -ne $Body) {
        if ($Body -is [string]) { $json = $Body } else { $json = $Body | ConvertTo-Json -Depth 20 -Compress }
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -Body $json -ContentType 'application/json' -TimeoutSec 30
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -TimeoutSec 30
}

function Setup-CloudflareFixedTunnel {
    Load-Ports
    if (-not $env:CF_API_TOKEN -or -not $env:CF_ACCOUNT_ID -or -not $env:CF_ZONE_ID) {
        $script:ARGO_MODE = 'quick'
        return
    }
    Write-Yellow '检测到 Cloudflare 环境变量，优先创建/使用固定 Argo Tunnel...'
    try {
        $zone = Invoke-CFApi -Method GET -Path "/zones/$($env:CF_ZONE_ID)"
        $zoneName = $zone.result.name
        if (-not $zoneName) { throw '无法解析 Zone 域名' }
        $rnd = -join ((48..57 + 97..122) | Get-Random -Count 10 | ForEach-Object { [char]$_ })
        $tunnelName = "x2go-$rnd"
        if ($env:XRAY2GO_TUNNEL_NAME) { $tunnelName = $env:XRAY2GO_TUNNEL_NAME }
        $hostName = "$tunnelName.$zoneName"
        if ($env:XRAY2GO_TUNNEL_HOST) { $hostName = $env:XRAY2GO_TUNNEL_HOST }
        $bytes = New-Object byte[] 32
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $secret = [Convert]::ToBase64String($bytes)
        $created = Invoke-CFApi -Method POST -Path "/accounts/$($env:CF_ACCOUNT_ID)/cfd_tunnel" -Body @{ name = $tunnelName; config_src = 'cloudflare'; tunnel_secret = $secret }
        $tunnelId = $created.result.id
        if (-not $tunnelId) { throw 'Cloudflare Tunnel ID 获取失败' }
        $ingress = @{ config = @{ ingress = @(@{ hostname = $hostName; service = "http://localhost:$($script:PORT)"; originRequest = @{} }, @{ service = 'http_status:404' }) } }
        Invoke-CFApi -Method PUT -Path "/accounts/$($env:CF_ACCOUNT_ID)/cfd_tunnel/$tunnelId/configurations" -Body $ingress | Out-Null
        $encodedHost = [uri]::EscapeDataString($hostName)
        $existing = Invoke-CFApi -Method GET -Path "/zones/$($env:CF_ZONE_ID)/dns_records?type=CNAME&name=$encodedHost"
        $dnsBody = @{ type = 'CNAME'; name = $hostName; content = "$tunnelId.cfargotunnel.com"; proxied = $true }
        if ($existing.result -and $existing.result.Count -gt 0) {
            Invoke-CFApi -Method PUT -Path "/zones/$($env:CF_ZONE_ID)/dns_records/$($existing.result[0].id)" -Body $dnsBody | Out-Null
        } else {
            Invoke-CFApi -Method POST -Path "/zones/$($env:CF_ZONE_ID)/dns_records" -Body $dnsBody | Out-Null
        }
        $tokenResp = Invoke-CFApi -Method GET -Path "/accounts/$($env:CF_ACCOUNT_ID)/cfd_tunnel/$tunnelId/token"
        $token = $tokenResp.result
        if (-not $token) { throw '获取 Tunnel token 失败' }
        $argoOnly = '1'
        if ($env:XRAY2GO_ARGO_ONLY) { $argoOnly = $env:XRAY2GO_ARGO_ONLY }
        Add-PortEnvLines @('ARGO_MODE=fixed', "ARGO_DOMAIN=$hostName", "ARGO_TUNNEL_NAME=$tunnelName", "ARGO_TUNNEL_ID=$tunnelId", "ARGO_TUNNEL_TOKEN=$token", "XRAY2GO_ARGO_ONLY=$argoOnly")
        $script:ARGO_MODE = 'fixed'
        $script:ARGO_DOMAIN = $hostName
        $script:ARGO_TUNNEL_NAME = $tunnelName
        $script:ARGO_TUNNEL_ID = $tunnelId
        $script:ARGO_TUNNEL_TOKEN = $token
        $script:XRAY2GO_ARGO_ONLY = $argoOnly
        Write-Green "固定 Argo Tunnel 已配置：$hostName"
    }
    catch {
        Write-Red "固定 Tunnel 配置失败：$($_.Exception.Message)；回退到临时 Argo Tunnel"
        $script:ARGO_MODE = 'quick'
    }
}

function Get-RealIP {
    [string[]]$apis = @(
        'https://ifconfig.me',
        'https://api.ipify.org',
        'https://icanhazip.com',
        'https://ipecho.net/plain',
        'https://checkip.amazonaws.com',
        'https://ipv4.ip.sb'
    )

    foreach ($api in $apis) {
        try {
            $response = Invoke-WebRequest -Uri $api -TimeoutSec 5 -UseBasicParsing
            $ip = $response.Content.Trim()
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
                return $ip
            }
        }
        catch {
            continue
        }
    }

    [string[]]$ipv6apis = @(
        'https://api64.ipify.org',
        'https://ipv6.ip.sb'
    )
    foreach ($api in $ipv6apis) {
        try {
            $response = Invoke-WebRequest -Uri $api -TimeoutSec 5 -UseBasicParsing
            $ip = $response.Content.Trim()
            if ($ip) { return "[$ip]" }
        }
        catch {
            continue
        }
    }

    Write-Red '无法自动获取公网 IP'
    $manual = Read-Host '请手动输入你的服务器公网 IP'
    if ($manual) { return $manual } else { return '127.0.0.1' }
}

function Get-Arch {
    if ([Environment]::Is64BitOperatingSystem) {
        $cpuArch = $env:PROCESSOR_ARCHITECTURE
        if ($cpuArch -eq 'ARM64') {
            return @{ ARCH = 'arm64'; ARCH_ARG = 'arm64-v8a' }
        }
        else {
            return @{ ARCH = 'amd64'; ARCH_ARG = '64' }
        }
    }
    else {
        return @{ ARCH = '386'; ARCH_ARG = '32' }
    }
}

function New-UUID {
    return [guid]::NewGuid().ToString()
}

function New-Password {
    param([int]$Length = 24)
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $result = ''
    for ($i = 0; $i -lt $Length; $i++) {
        $result += $chars[(Get-Random -Maximum $chars.Length)]
    }
    return $result
}

function ConvertTo-Base64 {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToBase64String($bytes)
}

function ConvertFrom-Base64 {
    param([string]$Text)
    $bytes = [Convert]::FromBase64String($Text)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Ensure-Hy2Certificate {
    $certPrefix = Join-Path $WorkDir 'hy2'
    $certFile = Join-Path $WorkDir 'hy2.crt'
    $keyFile = Join-Path $WorkDir 'hy2.key'
    if ((Test-Path $certFile) -and (Test-Path $keyFile)) { return }

    Write-Yellow '生成 Hysteria2 自签 TLS 证书...'
    & "$WorkDir\xray.exe" tls cert '-domain=xray2go.local' '-name=xray2go.local' '-org=xray2go' '-expire=87600h' "-file=$certPrefix" | Out-Null
    if (-not ((Test-Path $certFile) -and (Test-Path $keyFile))) {
        Write-Red 'Hysteria2 证书生成失败'
        throw 'HY2 certificate generation failed'
    }
}

# ==========================================
# 检查状态
# ==========================================
function Check-Xray {
    if (Test-Path "$WorkDir\xray.exe") {
        $svc = Get-Service -Name 'xray' -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -eq 'Running')) {
            return 0
        }
        else {
            return 1
        }
    }
    return 2
}

function Check-Argo {
    if (Test-Path "$WorkDir\argo.exe") {
        $svc = Get-Service -Name 'cloudflared-tunnel' -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -eq 'Running')) {
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
        $svc = Get-Service -Name 'caddy' -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -eq 'Running')) {
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
        0 { return 'running' }
        1 { return 'not running' }
        2 { return 'not installed' }
    }
}

# ==========================================
# 提取 Argo 域名
# ==========================================
function Get-ArgoDomain {
    param([string]$LogFile)
    if (-not (Test-Path $LogFile)) { return $null }
    $content = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $null }
    # Keep this regex parser-safe for Windows PowerShell 5.1: avoid single-quoted backslash-heavy literals.
    $pattern = "https://([A-Za-z0-9][A-Za-z0-9-]*[.]trycloudflare[.]com)"
    $match = [regex]::Match($content, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

# ==========================================
# 安装 NSSM
# ==========================================
function Install-NSSM {
    if (Test-Path $NssmPath) {
        Write-Green 'nssm already installed'
        return
    }
    Write-Yellow '正在下载 NSSM...'
    $nssmUrl = 'https://nssm.cc/release/nssm-2.24.zip'
    $nssmZip = "$WorkDir\nssm.zip"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing
        Expand-Archive -Path $nssmZip -DestinationPath "$WorkDir\nssm_tmp" -Force
        $nssmExe = Get-ChildItem -Path "$WorkDir\nssm_tmp" -Recurse -Filter 'nssm.exe' |
            Where-Object { $_.DirectoryName -like '*win64*' } |
            Select-Object -First 1
        if (-not $nssmExe) {
            $nssmExe = Get-ChildItem -Path "$WorkDir\nssm_tmp" -Recurse -Filter 'nssm.exe' |
                Select-Object -First 1
        }
        Copy-Item $nssmExe.FullName $NssmPath -Force
        Remove-Item "$WorkDir\nssm_tmp" -Recurse -Force
        Remove-Item $nssmZip -Force
        Write-Green 'NSSM 安装成功'
    }
    catch {
        Write-Red "NSSM 下载失败: $($_.Exception.Message)"
    }
}

# ==========================================
# 安装 Caddy
# ==========================================
function Install-Caddy {
    if (Test-Path "$WorkDir\caddy.exe") {
        Write-Green 'caddy already installed'
        return
    }
    Write-Yellow '正在下载 caddy...'
    $archInfo = Get-Arch
    $caddyVersion = '2.9.1'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/caddyserver/caddy/releases/latest' -UseBasicParsing
        $caddyVersion = $release.tag_name -replace '^v', ''
    }
    catch {
        Write-Yellow "无法获取最新版本，使用默认 $caddyVersion"
    }

    $caddyUrl = "https://github.com/caddyserver/caddy/releases/download/v$caddyVersion/caddy_${caddyVersion}_windows_$($archInfo.ARCH).zip"
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
        Write-Red "caddy 下载失败: $($_.Exception.Message)"
    }
}

# ==========================================
# 安装 jq
# ==========================================
function Install-Jq {
    if (Test-Path "$WorkDir\jq.exe") {
        Write-Green 'jq already installed'
        return
    }
    Write-Yellow '正在下载 jq...'
    $archInfo = Get-Arch
    $jqArch = 'amd64'
    if ($archInfo.ARCH -eq 'arm64') { $jqArch = 'arm64' }
    $jqUrl = "https://github.com/jqlang/jq/releases/latest/download/jq-windows-$jqArch.exe"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $jqUrl -OutFile "$WorkDir\jq.exe" -UseBasicParsing
        Write-Green 'jq 安装成功'
    }
    catch {
        Write-Red "jq 下载失败: $($_.Exception.Message)"
    }
}

# ==========================================
# REALITY/RealiTLScanner
# ==========================================
function Apply-RealityScannerResult {
    param($ArchInfo)

    Set-RealityDefaults

    if (($env:REALITY_SCAN -ne '1') -and -not $env:REALITY_SCAN_ADDR -and -not $env:REALITY_SCAN_URL -and -not $env:REALITY_SCAN_IN) {
        return
    }

    if (-not (Test-Path $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }

    $scanner = Join-Path $WorkDir 'RealiTLScanner.exe'
    if ($env:REALITY_SCAN_BIN) { $scanner = $env:REALITY_SCAN_BIN }
    if (-not (Test-Path $scanner)) {
        if ($ArchInfo.ARCH_ARG -ne '64') {
            Write-Yellow "RealiTLScanner 当前脚本仅自动下载 windows-64 版本，当前架构 $($ArchInfo.ARCH_ARG) 不支持，保留默认 REALITY 域名。"
            return
        }
        Write-Yellow '正在下载 RealiTLScanner...'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.1/RealiTLScanner-windows-64.exe' -OutFile $scanner -UseBasicParsing
        }
        catch {
            Write-Yellow "RealiTLScanner 下载失败，保留默认 REALITY 域名: $($_.Exception.Message)"
            return
        }
    }

    $out = Join-Path $env:TEMP 'realitlscanner-out.csv'
    if ($env:REALITY_SCAN_OUT) { $out = $env:REALITY_SCAN_OUT }
    $log = Join-Path $env:TEMP 'realitlscanner.log'
    if ($env:REALITY_SCAN_LOG) { $log = $env:REALITY_SCAN_LOG }
    $errLog = "$log.err"
    $scanArgs = @()
    if ($env:REALITY_SCAN_IN) {
        $scanArgs += @('-in', $env:REALITY_SCAN_IN)
    }
    elseif ($env:REALITY_SCAN_URL) {
        $scanArgs += @('-url', $env:REALITY_SCAN_URL)
    }
    elseif ($env:REALITY_SCAN_ADDR) {
        $scanArgs += @('-addr', $env:REALITY_SCAN_ADDR)
    }
    else {
        Write-Yellow '已启用 REALITY_SCAN，但未设置 REALITY_SCAN_ADDR / REALITY_SCAN_URL / REALITY_SCAN_IN，保留默认 REALITY 域名。'
        return
    }

    $scanPort = '443'
    if ($env:REALITY_SCAN_PORT) { $scanPort = $env:REALITY_SCAN_PORT }
    $scanThread = '5'
    if ($env:REALITY_SCAN_THREAD) { $scanThread = $env:REALITY_SCAN_THREAD }
    $scanTimeout = '5'
    if ($env:REALITY_SCAN_TIMEOUT) { $scanTimeout = $env:REALITY_SCAN_TIMEOUT }
    $scanArgs += @(
        '-port', $scanPort,
        '-thread', $scanThread,
        '-timeout', $scanTimeout,
        '-out', $out
    )

    $maxSeconds = 180
    if ($env:REALITY_SCAN_MAX_SECONDS) { [void][int]::TryParse($env:REALITY_SCAN_MAX_SECONDS, [ref]$maxSeconds) }

    Write-Yellow '正在用 RealiTLScanner 扫描 REALITY 伪装目标...'
    try {
        $proc = Start-Process -FilePath $scanner -ArgumentList $scanArgs -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError $errLog
        try {
            Wait-Process -Id $proc.Id -Timeout $maxSeconds -ErrorAction Stop
        }
        catch {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Write-Yellow "RealiTLScanner 扫描超时，保留默认 REALITY 域名。日志：$log"
            return
        }
        if ($proc.ExitCode -ne 0) {
            Write-Yellow "RealiTLScanner 扫描失败，保留默认 REALITY 域名。日志：$log"
            return
        }
    }
    catch {
        Write-Yellow "RealiTLScanner 扫描失败，保留默认 REALITY 域名: $($_.Exception.Message)"
        return
    }

    if (-not (Test-Path $out)) {
        Write-Yellow 'RealiTLScanner 没有输出结果，保留默认 REALITY 域名。'
        return
    }
    $line = Get-Content $out -ErrorAction SilentlyContinue | Select-Object -Skip 1 | Where-Object { $_ -and (($_ -split ',').Count -ge 2) } | Select-Object -First 1
    if (-not $line) {
        Write-Yellow 'RealiTLScanner 没有可用结果，保留默认 REALITY 域名。'
        return
    }

    $cols = $line -split ','
    $ip = $cols[0].Trim(' ', '"', "`r")
    $origin = $cols[1].Trim(' ', '"', "`r")
    $cert = ''
    if ($cols.Count -gt 2) { $cert = $cols[2].Trim(' ', '"', "`r") }
    $sni = $cert
    if (-not $sni -or $sni.StartsWith('*.')) { $sni = $origin }
    if (-not $ip -or -not $sni -or $sni.Contains('*')) {
        Write-Yellow 'RealiTLScanner 结果不可用，保留默认 REALITY 域名。'
        return
    }

    $script:REALITY_GRPC_TARGET = $ip
    $script:REALITY_GRPC_SNI = $sni
    $script:REALITY_XHTTP_TARGET = $ip
    $script:REALITY_XHTTP_SNI = $sni
    Write-Green "REALITY 伪装目标已切换为：target=${ip}:443, sni=${sni}（默认域名仍作为失败回退）"
}

# ==========================================
# 安装 Xray + Cloudflared
# ==========================================
function Install-Xray {
    Clear-Host
    Write-Purple '正在安装 Xray-2go (Windows) 中，请稍等...'
    $archInfo = Get-Arch

    Assign-Ports

    if (-not (Test-Path $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }

    # REALITY 伪装域名：默认使用内置回退，可通过 RealiTLScanner 显式扫描替换
    Apply-RealityScannerResult -ArchInfo $archInfo

    $script:UUID = New-UUID
    $script:password = New-Password
    $script:hy2Password = New-Password -Length 32

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # 下载 Xray
    Write-Yellow '下载 Xray...'
    $xrayUrl = "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-windows-$($archInfo.ARCH_ARG).zip"
    $xrayZip = "$WorkDir\xray.zip"
    try {
        Invoke-WebRequest -Uri $xrayUrl -OutFile $xrayZip -UseBasicParsing
        Expand-Archive -Path $xrayZip -DestinationPath "$WorkDir\xray_tmp" -Force
        Copy-Item "$WorkDir\xray_tmp\xray.exe" "$WorkDir\xray.exe" -Force
        Remove-Item "$WorkDir\xray_tmp" -Recurse -Force
        Remove-Item $xrayZip -Force
        Write-Green 'Xray 下载完成'
    }
    catch {
        Write-Red "Xray 下载失败: $($_.Exception.Message)"
        return
    }

    # 下载 Cloudflared
    Write-Yellow '下载 cloudflared...'
    $cfArch = 'amd64'
    if ($archInfo.ARCH -eq 'arm64') { $cfArch = 'arm64' }
    $cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$cfArch.exe"
    try {
        Invoke-WebRequest -Uri $cfUrl -OutFile "$WorkDir\argo.exe" -UseBasicParsing
        Write-Green 'cloudflared 下载完成'
    }
    catch {
        Write-Red "cloudflared 下载失败: $($_.Exception.Message)"
        return
    }

    # 生成密钥对
    Write-Yellow '生成密钥对...'
    $output = & "$WorkDir\xray.exe" x25519 2>&1 | Out-String
    $lines = $output -split "`n"
    foreach ($ln in $lines) {
        if ($ln -match 'Private.*:\s*(\S+)') {
            $script:privateKey = $matches[1]
        }
        if ($ln -match 'Public.*:\s*(\S+)') {
            $script:publicKey = $matches[1]
        }
    }

    if (-not $script:privateKey -or -not $script:publicKey) {
        Write-Red 'x25519 密钥生成失败'
        Write-Yellow "输出: $output"
        return
    }
    Write-Green '密钥对生成成功'

    Ensure-Hy2Certificate
    Save-Ports

    # 防火墙
    Write-Yellow '配置防火墙规则...'
    [int[]]$ports = @($script:PORT, $script:ARGO_PORT, $script:GRPC_PORT, $script:XHTTP_PORT)
    foreach ($p in $ports) {
        $ruleName = "Xray2go_Port_$p"
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p -ErrorAction SilentlyContinue | Out-Null
    }
    $hy2RuleName = "Xray2go_HY2_$($script:HY2_PORT)"
    Remove-NetFirewallRule -DisplayName $hy2RuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $hy2RuleName -Direction Inbound -Action Allow -Protocol UDP -LocalPort $script:HY2_PORT -ErrorAction SilentlyContinue | Out-Null
    # 内部端口
    foreach ($p in @(3001, 3002, 3003)) {
        $ruleName = "Xray2go_Internal_$p"
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Green '防火墙规则已添加'

    # 生成配置
    $configJson = @{
        log = @{ access = 'none'; error = 'none'; loglevel = 'none' }
        inbounds = @(
            @{
                port = [int]$script:ARGO_PORT
                protocol = 'vless'
                settings = @{
                    clients = @( @{ id = $script:UUID; flow = 'xtls-rprx-vision' } )
                    decryption = 'none'
                    fallbacks = @(
                        @{ dest = [int]$script:FB_TCP_PORT },
                        @{ path = '/vless-argo'; dest = [int]$script:FB_VLESS_WS_PORT },
                        @{ path = '/vmess-argo'; dest = [int]$script:FB_VMESS_WS_PORT }
                    )
                }
                streamSettings = @{ network = 'tcp' }
            },
            @{
                port = [int]$script:FB_TCP_PORT; listen = '127.0.0.1'; protocol = 'vless'
                settings = @{ clients = @( @{ id = $script:UUID } ); decryption = 'none' }
                streamSettings = @{ network = 'tcp'; security = 'none' }
            },
            @{
                port = [int]$script:FB_VLESS_WS_PORT; listen = '127.0.0.1'; protocol = 'vless'
                settings = @{ clients = @( @{ id = $script:UUID; level = 0 } ); decryption = 'none' }
                streamSettings = @{ network = 'ws'; security = 'none'; wsSettings = @{ path = '/vless-argo' } }
                sniffing = @{ enabled = $true; destOverride = @('http', 'tls', 'quic'); metadataOnly = $false }
            },
            @{
                port = [int]$script:FB_VMESS_WS_PORT; listen = '127.0.0.1'; protocol = 'vmess'
                settings = @{ clients = @( @{ id = $script:UUID; alterId = 0 } ) }
                streamSettings = @{ network = 'ws'; wsSettings = @{ path = '/vmess-argo' } }
                sniffing = @{ enabled = $true; destOverride = @('http', 'tls', 'quic'); metadataOnly = $false }
            },
            @{
                listen = '::'; port = [int]$script:XHTTP_PORT; protocol = 'vless'
                settings = @{ clients = @( @{ id = $script:UUID } ); decryption = 'none' }
                streamSettings = @{
                    network = 'xhttp'; security = 'reality'
                    realitySettings = @{
                        target = "$($script:REALITY_XHTTP_TARGET):443"; xver = 0
                        serverNames = @($script:REALITY_XHTTP_SNI)
                        privateKey = $script:privateKey; shortIds = @('')
                    }
                }
                sniffing = @{ enabled = $true; destOverride = @('http', 'tls', 'quic') }
            },
            @{
                listen = '::'; port = [int]$script:GRPC_PORT; protocol = 'vless'
                settings = @{ clients = @( @{ id = $script:UUID } ); decryption = 'none' }
                streamSettings = @{
                    network = 'grpc'; security = 'reality'
                    realitySettings = @{
                        dest = "$($script:REALITY_GRPC_TARGET):443"
                        serverNames = @($script:REALITY_GRPC_SNI)
                        privateKey = $script:privateKey; shortIds = @('')
                    }
                    grpcSettings = @{ serviceName = 'grpc' }
                }
                sniffing = @{ enabled = $true; destOverride = @('http', 'tls', 'quic') }
            },
            @{
                listen = '::'; port = [int]$script:HY2_PORT; tag = 'in-hysteria2'; protocol = 'hysteria'
                settings = @{ version = 2; clients = @( @{ auth = $script:hy2Password; level = 0; email = 'xray2go@hy2' } ) }
                streamSettings = @{
                    network = 'hysteria'; security = 'tls'
                    tlsSettings = @{ serverName = 'xray2go.local'; alpn = @('h3'); certificates = @( @{ certificateFile = (Join-Path $WorkDir 'hy2.crt'); keyFile = (Join-Path $WorkDir 'hy2.key') } ) }
                    hysteriaSettings = @{ version = 2; auth = $script:hy2Password; udpIdleTimeout = 60; masquerade = @{ type = 'string'; content = 'not found'; statusCode = 404 } }
                }
                sniffing = @{ enabled = $true; destOverride = @('http', 'tls', 'quic') }
            }
        )
        dns = @{ servers = @('https+local://8.8.8.8/dns-query') }
        outbounds = @(
            @{ protocol = 'freedom'; tag = 'direct' },
            @{ protocol = 'blackhole'; tag = 'block' }
        )
    }

    $configJson | ConvertTo-Json -Depth 20 | Out-File -FilePath $ConfigDir -Encoding UTF8
    Write-Green '配置文件已生成'
}

# ==========================================
# 服务安装
# ==========================================
function Install-Services {
    Load-Ports

    Write-Yellow '正在创建 Xray 服务...'
    & $NssmPath stop xray 2>$null
    & $NssmPath remove xray confirm 2>$null
    & $NssmPath install xray "$WorkDir\xray.exe" "run -c `"$ConfigDir`""
    & $NssmPath set xray AppDirectory "$WorkDir"
    & $NssmPath set xray DisplayName 'Xray Service'
    & $NssmPath set xray Start SERVICE_AUTO_START
    & $NssmPath set xray AppStdout "$WorkDir\xray_out.log"
    & $NssmPath set xray AppStderr "$WorkDir\xray_error.log"
    & $NssmPath start xray
    Write-Green 'Xray 服务已创建并启动'

    Write-Yellow '正在创建 Argo Tunnel 服务...'
    & $NssmPath stop cloudflared-tunnel 2>$null
    & $NssmPath remove cloudflared-tunnel confirm 2>$null
    if ($script:ARGO_MODE -eq 'fixed' -and $script:ARGO_TUNNEL_TOKEN) {
        $argoArgs = "tunnel --no-autoupdate run --token $($script:ARGO_TUNNEL_TOKEN)"
    }
    else {
        $argoArgs = "tunnel --url http://localhost:$($script:PORT) --no-autoupdate --edge-ip-version auto --protocol http2"
    }
    & $NssmPath install cloudflared-tunnel "$WorkDir\argo.exe" $argoArgs
    & $NssmPath set cloudflared-tunnel AppDirectory "$WorkDir"
    & $NssmPath set cloudflared-tunnel DisplayName 'Cloudflare Tunnel'
    & $NssmPath set cloudflared-tunnel Start SERVICE_AUTO_START
    & $NssmPath set cloudflared-tunnel AppStdout "$WorkDir\argo.log"
    & $NssmPath set cloudflared-tunnel AppStderr "$WorkDir\argo.log"
    & $NssmPath start cloudflared-tunnel
    Write-Green 'Argo Tunnel 服务已创建并启动'
}

function Install-CaddyService {
    Load-Ports

    $caddyFilePath = Join-Path $WorkDir 'Caddyfile'
    $workDirForward = $WorkDir -replace '\\','/'

    $caddyLines = @()
    $caddyLines += '{'
    $caddyLines += '    auto_https off'
    $caddyLines += '}'
    $caddyLines += ''
    $caddyLines += ":$($script:PORT) {"
    $caddyLines += "    handle /$($script:password) {"
    $caddyLines += "        root * $workDirForward"
    $caddyLines += '        try_files /sub.txt'
    $caddyLines += '        file_server browse'
    $caddyLines += '        header Content-Type "text/plain; charset=utf-8"'
    $caddyLines += '    }'
    $caddyLines += ''
    $caddyLines += '    handle /vless-argo* {'
    $caddyLines += "        reverse_proxy 127.0.0.1:$($script:ARGO_PORT)"
    $caddyLines += '    }'
    $caddyLines += ''
    $caddyLines += '    handle /vmess-argo* {'
    $caddyLines += "        reverse_proxy 127.0.0.1:$($script:ARGO_PORT)"
    $caddyLines += '    }'
    $caddyLines += ''
    $caddyLines += '    handle {'
    $caddyLines += '        respond "404 Not Found" 404'
    $caddyLines += '    }'
    $caddyLines += '}'

    $caddyLines -join "`r`n" | Out-File -FilePath $caddyFilePath -Encoding UTF8

    & $NssmPath stop caddy 2>$null
    & $NssmPath remove caddy confirm 2>$null
    $caddyArgs = "run --config `"$caddyFilePath`""
    $caddyExe = Join-Path $WorkDir 'caddy.exe'
    & $NssmPath install caddy $caddyExe $caddyArgs
    & $NssmPath set caddy AppDirectory $WorkDir
    & $NssmPath set caddy DisplayName 'Caddy Web Server'
    & $NssmPath set caddy Start SERVICE_AUTO_START
    $caddyOut = Join-Path $WorkDir 'caddy_out.log'
    $caddyErr = Join-Path $WorkDir 'caddy_error.log'
    & $NssmPath set caddy AppStdout $caddyOut
    & $NssmPath set caddy AppStderr $caddyErr
    & $NssmPath start caddy
    Write-Green 'Caddy started'
}

function Get-CaddyInfo {
    $caddyFilePath = Join-Path $WorkDir 'Caddyfile'
    $result = @{ Port = $script:PORT; Path = $script:password }
    if (Test-Path $caddyFilePath) {
        $cc = Get-Content $caddyFilePath -Raw
        $portPattern = ':(\d+)\s*\{'
        $pathPattern = 'handle /(\w+)'
        if ($cc -match $portPattern) { $result.Port = $matches[1] }
        if ($cc -match $pathPattern) { $result.Path = $matches[1] }
    }
    return $result
}


# ==========================================
# 获取信息并生成节点
# ==========================================
function Get-Info {
    Clear-Host
    Load-Ports

    $IP = Get-RealIP

    $isp = 'vps'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $geoData = Invoke-RestMethod -Uri 'https://api.ip.sb/geoip' -TimeoutSec 3 -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -UseBasicParsing
        $isp = "$($geoData.country_code)-$($geoData.isp)" -replace ' ', '_'
    }
    catch {
        $isp = 'vps'
    }

    # 获取 Argo 域名
    $argodomain = $null
    if ($script:ARGO_MODE -eq 'fixed' -and $script:ARGO_DOMAIN) {
        $argodomain = $script:ARGO_DOMAIN
    }
    else {
        $argoLog = "$WorkDir\argo.log"
        for ($i = 1; $i -le 10; $i++) {
            Write-Purple "第 $i 次尝试获取 ArgoDomain 中..."
            $argodomain = Get-ArgoDomain -LogFile $argoLog
            if ($argodomain) { break }
            Start-Sleep -Seconds 3
        }
    }

    if (-not $argodomain) {
        Write-Red '获取 Argo 域名失败，请稍后重试'
        $argodomain = 'failed.trycloudflare.com'
    }

    Write-Green "`nArgoDomain: $argodomain`n"

    $argoAdd = $argodomain
    if ($env:XRAY2GO_ARGO_ADD) { $argoAdd = $env:XRAY2GO_ARGO_ADD }

    # VMess JSON
    $vmessPs = $isp
    if ($script:XRAY2GO_ARGO_ONLY -eq '1') { $vmessPs = "${isp}-vmess-argo-fixed" }
    $vmessObj = @{
        v    = '2'; ps = $vmessPs; add = $argoAdd; port = $CFPORT
        id   = $script:UUID; aid = '0'; scy = 'none'; net = 'ws'
        type = 'none'; host = $argodomain; path = '/vmess-argo?ed=2560'
        tls  = 'tls'; sni = $argodomain; alpn = ''; fp = 'chrome'
    }
    $vmessJson = $vmessObj | ConvertTo-Json -Compress
    $vmessBase64 = ConvertTo-Base64 -Text $vmessJson

    if ($script:XRAY2GO_ARGO_ONLY -eq '1') {
        $urlLines = @(
            "vless://$($script:UUID)@${argoAdd}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}-vless-argo-fixed",
            '',
            "vmess://${vmessBase64}",
            ''
        )
    }
    else {
        $urlLines = @(
            "vless://$($script:UUID)@${IP}:$($script:GRPC_PORT)?encryption=none&security=reality&sni=$($script:REALITY_GRPC_SNI)&fp=chrome&pbk=$($script:publicKey)&allowInsecure=1&type=grpc&authority=$($script:REALITY_GRPC_SNI)&serviceName=grpc&mode=gun#${isp}-grpc-reality",
            '',
            "vless://$($script:UUID)@${IP}:$($script:XHTTP_PORT)?encryption=none&security=reality&sni=$($script:REALITY_XHTTP_SNI)&fp=chrome&pbk=$($script:publicKey)&allowInsecure=1&type=xhttp&mode=auto#${isp}-xhttp-reality",
            '',
            "hysteria2://$($script:hy2Password)@${IP}:$($script:HY2_PORT)?insecure=1&sni=xray2go.local#${isp}-hy2",
            '',
            "vless://$($script:UUID)@${argoAdd}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}-vless-argo",
            '',
            "vmess://${vmessBase64}",
            ''
        )
    }

    $urlContent = $urlLines -join "`r`n"
    $urlContent | Out-File -FilePath $ClientDir -Encoding UTF8

    Write-Purple $urlContent

    $subBase64 = ConvertTo-Base64 -Text $urlContent
    $subBase64 | Out-File -FilePath "$WorkDir\sub.txt" -Encoding UTF8 -NoNewline

    $subLink = Get-SubscriptionUrl -IP $IP -Port $script:PORT -Path $script:password -ArgoDomain $argodomain
    Write-Yellow "`n温馨提醒：NAT/家宽机器会自动使用 Argo 订阅链接，直连 Caddy 订阅链接不可用。`n"
    Write-Green "节点订阅链接：$subLink"
    Write-Green "`n订阅链接适用于 V2rayN, NekoBox, Karing, Shadowrocket, Loon, 圈X 等`n"

    Export-ProxyTxt -Mode 'auto'
}

# ==========================================
# 导出代理为 txt
# ==========================================
function Export-ProxyTxt {
    param(
        [string]$Mode = 'manual',
        [string]$TargetDir = $ExportDir
    )

    Load-Ports

    if (-not (Test-Path $ClientDir)) {
        Write-Red 'No node file found'
        return
    }

    $IP = Get-RealIP
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $exportFile = Join-Path $TargetDir "xray2go_proxy_${timestamp}.txt"
    $exportFileLatest = Join-Path $TargetDir 'xray2go_proxy_latest.txt'

    $argoLog = Join-Path $WorkDir 'argo.log'
    $argodomain = Get-ArgoDomain -LogFile $argoLog

    $info = Get-CaddyInfo
    $subPort = $info.Port
    $subPath = $info.Path

    $urlContent = Get-Content $ClientDir -ErrorAction SilentlyContinue
    $lineGrpc  = $urlContent | Where-Object { $_ -match 'grpc' }  | Select-Object -First 1
    $lineXhttp = $urlContent | Where-Object { $_ -match 'xhttp' } | Select-Object -First 1
    $lineHy2   = $urlContent | Where-Object { $_ -match '^hysteria2://' } | Select-Object -First 1
    $lineWs    = $urlContent | Where-Object { ($_ -match 'vless') -and ($_ -match 'ws') } | Select-Object -First 1
    $lineVmess = $urlContent | Where-Object { $_ -match '^vmess://' } | Select-Object -First 1

    $adStr = 'N/A'
    if ($argodomain) { $adStr = $argodomain }
    $argoDomain = Get-CurrentArgoDomain
    $subLink = Get-SubscriptionUrl -IP $IP -Port $subPort -Path $subPath -ArgoDomain $argoDomain

    $lines = @()
    $lines += '============================================'
    $lines += '  Xray-2go Proxy Info (Windows)'
    $lines += "  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "  Server: ${IP}"
    $lines += '============================================'
    $lines += ''
    $lines += "PORT:       ${subPort}"
    $lines += "ARGO_PORT:  $($script:ARGO_PORT)"
    $lines += "GRPC_PORT:  $($script:GRPC_PORT)"
    $lines += "XHTTP_PORT: $($script:XHTTP_PORT)"
    $lines += "HY2_PORT:   $($script:HY2_PORT)/udp"
    $lines += ''
    $lines += "UUID: $($script:UUID)"
    $lines += "Argo Domain: $adStr"
    $lines += ''
    $lines += '============================================'
    $lines += '  Node Links'
    $lines += '============================================'
    $lines += ''
    $lines += '--- VLESS GRPC Reality ---'
    $lines += $lineGrpc
    $lines += ''
    $lines += '--- VLESS XHTTP Reality ---'
    $lines += $lineXhttp
    $lines += ''
    $lines += '--- Hysteria2 ---'
    $lines += $lineHy2
    $lines += ''
    $lines += '--- VLESS WS (Argo) ---'
    $lines += $lineWs
    $lines += ''
    $lines += '--- VMess WS (Argo) ---'
    $lines += $lineVmess
    $lines += ''
    $lines += '============================================'
    $lines += '  Subscribe'
    $lines += '============================================'
    $lines += ''
    $lines += $subLink
    $lines += ''
    $lines += '============================================'

    $lines -join "`r`n" | Out-File -FilePath $exportFile -Encoding UTF8
    Copy-Item $exportFile $exportFileLatest -Force

    $linksFile = Join-Path $TargetDir "xray2go_links_${timestamp}.txt"
    $linksFileLatest = Join-Path $TargetDir 'xray2go_links_latest.txt'
    $nonEmpty = $urlContent | Where-Object { $_.Trim() -ne '' }
    $linksLines = @()
    $linksLines += $nonEmpty
    $linksLines += ''
    $linksLines += '# Subscribe'
    $linksLines += $subLink
    $linksLines -join "`r`n" | Out-File -FilePath $linksFile -Encoding UTF8
    Copy-Item $linksFile $linksFileLatest -Force

    if ($Mode -eq 'auto') {
        Write-Green 'Proxy info exported (auto):'
    }
    else {
        Write-Green 'Proxy info exported:'
    }
    Write-Green "  Detail: $exportFile"
    Write-Green "  Detail(latest): $exportFileLatest"
    Write-Green "  Links: $linksFile"
    Write-Green "  Links(latest): $linksFileLatest"
}


# ==========================================
# PostgreSQL 上传 xray2go_links_latest.txt (xray2go+)
# ==========================================
function Test-PostgresEnabled {
    return [bool]($env:DATABASE_URL -or $env:POSTGRES_HOST -or $env:POSTGRES_USER -or $env:POSTGRES_DB -or $env:PGHOST -or $env:PGUSER -or $env:PGDATABASE -or $env:PGSTATS_DSN)
}

function Quote-SqlText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return 'NULL' }
    return "'" + ($Text -replace "'", "''") + "'"
}

function ConvertTo-SqlJsonb {
    param($Value)
    $json = ($Value | ConvertTo-Json -Depth 20 -Compress)
    return (Quote-SqlText $json) + '::jsonb'
}

function Invoke-Xray2GoPsql {
    param([string]$SqlFile)
    $psql = Get-Command psql -ErrorAction SilentlyContinue
    if (-not $psql) {
        Write-Yellow 'psql 不可用，跳过 PostgreSQL 上传'
        return $false
    }

    if ($env:DATABASE_URL) {
        if ($env:POSTGRES_PASSWORD) { $env:PGPASSWORD = $env:POSTGRES_PASSWORD }
        & psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -q -f $SqlFile
    }
    elseif ($env:PGSTATS_DSN) {
        & psql $env:PGSTATS_DSN -v ON_ERROR_STOP=1 -q -f $SqlFile
    }
    else {
        if ($env:POSTGRES_HOST) { $env:PGHOST = $env:POSTGRES_HOST } elseif (-not $env:PGHOST) { $env:PGHOST = '127.0.0.1' }
        if ($env:POSTGRES_PORT) { $env:PGPORT = $env:POSTGRES_PORT } elseif (-not $env:PGPORT) { $env:PGPORT = '5432' }
        if ($env:POSTGRES_USER) { $env:PGUSER = $env:POSTGRES_USER } elseif (-not $env:PGUSER) { $env:PGUSER = 'postgres' }
        if ($env:POSTGRES_PASSWORD) { $env:PGPASSWORD = $env:POSTGRES_PASSWORD }
        if ($env:POSTGRES_DB) { $env:PGDATABASE = $env:POSTGRES_DB } elseif (-not $env:PGDATABASE) { $env:PGDATABASE = 'xray' }
        & psql -v ON_ERROR_STOP=1 -q -f $SqlFile
    }
    return ($LASTEXITCODE -eq 0)
}

function Upload-LinksLatestToPostgres {
    if (-not (Test-PostgresEnabled)) { return }

    $linksFile = $env:XRAY2GO_LINKS_FILE
    if (-not $linksFile) {
        $candidates = @(
            (Join-Path $ExportDir 'xray2go_links_latest.txt'),
            (Join-Path (Get-Location).Path 'xray2go_links_latest.txt'),
            (Join-Path $env:USERPROFILE 'xray2go_links_latest.txt'),
            (Join-Path $WorkDir 'xray2go_links_latest.txt'),
            $ClientDir
        )
        foreach ($candidate in $candidates) {
            if ($candidate -and (Test-Path $candidate)) { $linksFile = $candidate; break }
        }
    }
    if (-not $linksFile -or -not (Test-Path $linksFile)) {
        Write-Yellow '未找到 xray2go_links_latest.txt，跳过 PostgreSQL 上传'
        return
    }

    Load-Ports
    $links = [ordered]@{}
    $meta = [ordered]@{ source_file = $linksFile; platform = 'windows' }
    $i = 0
    foreach ($raw in (Get-Content $linksFile -ErrorAction SilentlyContinue)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $i++
        if (($line -match '=') -and ($line -notmatch '^(vless|vmess|ss|trojan|hysteria2)://')) {
            $parts = $line.Split('=', 2)
            $key = $parts[0].Trim()
            $value = $parts[1].Trim()
            if ($value -match '://') { $links[$key] = $value } else { $meta[$key] = $value }
        }
        else {
            $links["link_$i"] = $line
        }
    }

    $ports = [ordered]@{}
    foreach ($name in @('PORT','ARGO_PORT','GRPC_PORT','XHTTP_PORT')) {
        $value = Get-Variable -Name $name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($value -match '^\d+$') { $ports[$name] = [int]$value }
    }

    $hostname = $env:COMPUTERNAME
    if (-not $hostname) { $hostname = [System.Net.Dns]::GetHostName() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $nodeBytes = [Text.Encoding]::UTF8.GetBytes("$hostname|$WorkDir")
    $nodeHash = [BitConverter]::ToString($sha.ComputeHash($nodeBytes)).Replace('-', '').ToLower()
    $nodeId = $nodeHash.Substring(0, 24)
    $publicIp = Get-RealIP
    $publicIpSql = 'NULL'
    if ($publicIp -and $publicIp -ne '127.0.0.1' -and $publicIp -notmatch ':') { $publicIpSql = (Quote-SqlText $publicIp) + '::inet' }
    $subUrl = ''
    if ($publicIp -and $script:PORT -and $script:password) { $subUrl = "http://${publicIp}:$($script:PORT)/$($script:password)" }
    $cdnHost = $CFIP
    if ($meta.Contains('host')) { $cdnHost = $meta['host'] }
    $publicIpForPayload = ''
    if ($publicIp -and $publicIp -ne '127.0.0.1' -and $publicIp -notmatch ':') { $publicIpForPayload = $publicIp }

    $payload = [ordered]@{
        node_id = $nodeId
        hostname = $hostname
        public_ip = $publicIpForPayload
        install_dir = $WorkDir
        cdn_host = $cdnHost
        argo_domain = ''
        sub_url = $subUrl
        uuid = $script:UUID
        public_key = $script:publicKey
        ports = $ports
        links = $links
        config_json = @{}
        raw_ports_env = $meta
        script_version = 'links_latest_windows'
    }
    if ($env:XRAY2GO_DB_WRITE_ONLY -match '^(1|true|yes|on)$') {
        $sql = "SELECT public.xray2go_ingest_links($(ConvertTo-SqlJsonb $payload));"
    }
    else {
        $sqlLines = @()
        $sqlLines += 'CREATE TABLE IF NOT EXISTS public.xray_node_configs ('
        $sqlLines += " node_id text PRIMARY KEY, hostname text NOT NULL DEFAULT '', public_ip inet, install_dir text NOT NULL DEFAULT '', cdn_host text NOT NULL DEFAULT '', argo_domain text NOT NULL DEFAULT '', sub_url text NOT NULL DEFAULT '', uuid text NOT NULL DEFAULT '', public_key text NOT NULL DEFAULT '', ports jsonb NOT NULL DEFAULT '{}'::jsonb, links jsonb NOT NULL DEFAULT '{}'::jsonb, config_json jsonb NOT NULL DEFAULT '{}'::jsonb, raw_ports_env jsonb NOT NULL DEFAULT '{}'::jsonb, script_version text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());"
        $sqlLines += 'INSERT INTO public.xray_node_configs (node_id, hostname, public_ip, install_dir, cdn_host, argo_domain, sub_url, uuid, public_key, ports, links, config_json, raw_ports_env, script_version, created_at, updated_at)'
        $sqlLines += "VALUES ($(Quote-SqlText $nodeId), $(Quote-SqlText $hostname), $publicIpSql, $(Quote-SqlText $WorkDir), $(Quote-SqlText $cdnHost), '', $(Quote-SqlText $subUrl), $(Quote-SqlText $script:UUID), $(Quote-SqlText $script:publicKey), $(ConvertTo-SqlJsonb $ports), $(ConvertTo-SqlJsonb $links), '{}'::jsonb, $(ConvertTo-SqlJsonb $meta), 'links_latest_windows', now(), now())"
        $sqlLines += 'ON CONFLICT (node_id) DO UPDATE SET hostname=EXCLUDED.hostname, public_ip=EXCLUDED.public_ip, install_dir=EXCLUDED.install_dir, cdn_host=EXCLUDED.cdn_host, sub_url=EXCLUDED.sub_url, uuid=EXCLUDED.uuid, public_key=EXCLUDED.public_key, ports=EXCLUDED.ports, links=EXCLUDED.links, raw_ports_env=EXCLUDED.raw_ports_env, script_version=EXCLUDED.script_version, updated_at=now();'
        $sql = $sqlLines -join "`r`n"
    }
    $tmpRoot = [IO.Path]::GetTempPath()
    if ($env:TEMP) { $tmpRoot = $env:TEMP }
    $tmp = Join-Path $tmpRoot "xray2go_links_pg_$([guid]::NewGuid().ToString('N')).sql"
    $sql | Out-File -FilePath $tmp -Encoding UTF8
    if (Invoke-Xray2GoPsql -SqlFile $tmp) {
        Write-Green 'xray2go_links_latest.txt 已上传到 PostgreSQL 表 public.xray_node_configs'
    }
    else {
        Write-Yellow 'PostgreSQL 上传失败，安装流程继续'
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}


# ==========================================
# 服务管理
# ==========================================
function Start-XraySvc {
    $s = Check-Xray
    if ($s -eq 1) {
        Write-Yellow '正在启动 Xray 服务...'
        & $NssmPath start xray 2>$null
        Start-Sleep -Seconds 2
        if ((Check-Xray) -eq 0) { Write-Green 'Xray 服务已启动' } else { Write-Red 'Xray 启动失败' }
    }
    elseif ($s -eq 0) { Write-Yellow 'Xray 正在运行' }
    else { Write-Yellow 'Xray 尚未安装' }
}

function Stop-XraySvc {
    $s = Check-Xray
    if ($s -eq 0) {
        Write-Yellow '正在停止 Xray 服务...'
        & $NssmPath stop xray 2>$null
        Write-Green 'Xray 服务已停止'
    }
    elseif ($s -eq 1) { Write-Yellow 'Xray 未运行' }
    else { Write-Yellow 'Xray 尚未安装' }
}

function Restart-XraySvc {
    $s = Check-Xray
    if ($s -eq 0 -or $s -eq 1) {
        Write-Yellow '正在重启 Xray 服务...'
        & $NssmPath restart xray 2>$null
        Start-Sleep -Seconds 2
        if ((Check-Xray) -eq 0) { Write-Green 'Xray 已重启' } else { Write-Red 'Xray 重启失败' }
    }
    else { Write-Yellow 'Xray 尚未安装' }
}

function Start-ArgoSvc {
    $s = Check-Argo
    if ($s -eq 1) {
        Write-Yellow '正在启动 Argo 服务...'
        & $NssmPath start cloudflared-tunnel 2>$null
        Write-Green 'Argo 已启动'
    }
    elseif ($s -eq 0) { Write-Green 'Argo 正在运行' }
    else { Write-Yellow 'Argo 尚未安装' }
}

function Stop-ArgoSvc {
    $s = Check-Argo
    if ($s -eq 0) {
        Write-Yellow '正在停止 Argo 服务...'
        & $NssmPath stop cloudflared-tunnel 2>$null
        Write-Green 'Argo 已停止'
    }
    elseif ($s -eq 1) { Write-Yellow 'Argo 未运行' }
    else { Write-Yellow 'Argo 尚未安装' }
}

function Restart-ArgoSvc {
    $s = Check-Argo
    if ($s -eq 0 -or $s -eq 1) {
        Write-Yellow '正在重启 Argo 服务...'
        Remove-Item "$WorkDir\argo.log" -Force -ErrorAction SilentlyContinue
        & $NssmPath restart cloudflared-tunnel 2>$null
        Write-Green 'Argo 已重启'
    }
    else { Write-Yellow 'Argo 尚未安装' }
}

function Restart-CaddySvc {
    if (Test-Path "$WorkDir\caddy.exe") {
        Write-Yellow '正在重启 Caddy 服务...'
        & $NssmPath restart caddy 2>$null
        Write-Green 'Caddy 已重启'
    }
    else { Write-Yellow 'Caddy 尚未安装' }
}

# ==========================================
# 卸载
# ==========================================
function Uninstall-Xray {
    $choice = Read-Host '确定要卸载 xray-2go 吗? (y/n)'
    if ($choice -eq 'y' -or $choice -eq 'Y') {
        Write-Yellow '正在卸载...'
        & $NssmPath stop xray 2>$null
        & $NssmPath remove xray confirm 2>$null
        & $NssmPath stop cloudflared-tunnel 2>$null
        & $NssmPath remove cloudflared-tunnel confirm 2>$null
        & $NssmPath stop caddy 2>$null
        & $NssmPath remove caddy confirm 2>$null

        Get-NetFirewallRule -DisplayName 'Xray2go_*' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue

        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Green 'Xray-2go 卸载成功'
    }
    else {
        Write-Purple '已取消卸载'
    }
}

# ==========================================
# Argo 临时隧道
# ==========================================
function Get-QuickTunnel {
    Restart-ArgoSvc
    Write-Yellow '获取临时 Argo 域名中...'
    Start-Sleep -Seconds 5

    $argodomain = $null
    for ($i = 1; $i -le 10; $i++) {
        $argodomain = Get-ArgoDomain -LogFile "$WorkDir\argo.log"
        if ($argodomain) { break }
        Start-Sleep -Seconds 3
    }

    if ($argodomain) {
        Write-Green "ArgoDomain: $argodomain"
    }
    else {
        Write-Red 'Argo 域名获取失败'
    }
    $script:ArgoDomain = $argodomain
}

function Update-ArgoDomain {
    if (-not $script:ArgoDomain) {
        Write-Red 'Argo 域名为空'
        return
    }
    Load-Ports

    if (-not (Test-Path $ClientDir)) { return }

    $content = Get-Content $ClientDir -Raw

    # 替换 vless ws sni 和 host
    $content = $content -replace 'sni=[a-zA-Z0-9-]*\.trycloudflare\.com', "sni=$($script:ArgoDomain)"
    $content = $content -replace 'host=[a-zA-Z0-9-]*\.trycloudflare\.com', "host=$($script:ArgoDomain)"

    # 替换 vmess
    if ($content -match 'vmess://([A-Za-z0-9+/=]+)') {
        try {
            $decoded = ConvertFrom-Base64 -Text $matches[1]
            $vmessObj = $decoded | ConvertFrom-Json
            $vmessObj.host = $script:ArgoDomain
            $vmessObj.sni = $script:ArgoDomain
            $newJson = $vmessObj | ConvertTo-Json -Compress
            $newB64 = ConvertTo-Base64 -Text $newJson
            $content = $content -replace 'vmess://[A-Za-z0-9+/=]+', "vmess://$newB64"
        }
        catch {
            Write-Yellow "VMess 更新失败: $($_.Exception.Message)"
        }
    }

    $content | Out-File -FilePath $ClientDir -Encoding UTF8
    $subB64 = ConvertTo-Base64 -Text $content
    $subB64 | Out-File -FilePath "$WorkDir\sub.txt" -Encoding UTF8 -NoNewline

    Write-Purple $content
    Write-Green "`n节点已更新`n"
}

# ==========================================
# 查看节点
# ==========================================
function Show-Nodes {
    $s = Check-Xray
    if ($s -eq 0) {
        Load-Ports
        Write-Host ''
        Get-Content $ClientDir | ForEach-Object { Write-Purple $_ }
        $serverIp = Get-RealIP
        $info = Get-CaddyInfo
        $argoDomain = Get-CurrentArgoDomain
        $subLink = Get-SubscriptionUrl -IP $serverIp -Port $info.Port -Path $info.Path -ArgoDomain $argoDomain
        Write-Host ''
        Write-Green "Subscribe: $subLink"
        Write-Host ''
    }
    else {
        Write-Yellow 'Xray-2go not installed or not running'
    }
}

# ==========================================
# 修改配置
# ==========================================
function Change-Config {
    Load-Ports
    Clear-Host
    Write-Host ''
    Write-Green '1. 修改UUID'
    Write-SkyBlue '------------'
    Write-Green '2. 修改grpc-reality端口'
    Write-SkyBlue '------------'
    Write-Green '3. 修改xhttp-reality端口'
    Write-SkyBlue '------------'
    Write-Purple '0. 返回主菜单'
    Write-SkyBlue '------------'

    $choice = Read-Host '请输入选择'
    switch ($choice) {
        '1' {
            $newUuid = Read-Host '请输入新的UUID (回车自动生成)'
            if (-not $newUuid) {
                $newUuid = New-UUID
                Write-Green "生成的UUID：$newUuid"
            }
            $cfg = Get-Content $ConfigDir -Raw
            $cfg = $cfg -replace '[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}', $newUuid
            $cfg | Out-File -FilePath $ConfigDir -Encoding UTF8
            $pe = Get-Content $PortsEnvFile -Raw
            $pe = $pe -replace 'UUID=.*', "UUID=$newUuid"
            $pe | Out-File -FilePath $PortsEnvFile -Encoding UTF8
            Restart-XraySvc
            Write-Green "UUID已修改为：$newUuid"
        }
        '2' {
            $newPort = Read-Host '请输入grpc-reality端口 (回车自动分配)'
            if (-not $newPort) { $newPort = Find-AvailablePort -StartPort 2000 -EndPort 65000 }
            $cfg = Get-Content $ConfigDir -Raw | ConvertFrom-Json
            $cfg.inbounds[5].port = [int]$newPort
            $cfg | ConvertTo-Json -Depth 20 | Out-File -FilePath $ConfigDir -Encoding UTF8
            $pe = (Get-Content $PortsEnvFile) -replace 'GRPC_PORT=.*', "GRPC_PORT=$newPort"
            $pe | Out-File $PortsEnvFile -Encoding UTF8
            Restart-XraySvc
            Write-Green "GRPC端口已修改为：$newPort"
        }
        '3' {
            $newPort = Read-Host '请输入xhttp-reality端口 (回车自动分配)'
            if (-not $newPort) { $newPort = Find-AvailablePort -StartPort 2000 -EndPort 65000 }
            $cfg = Get-Content $ConfigDir -Raw | ConvertFrom-Json
            $cfg.inbounds[4].port = [int]$newPort
            $cfg | ConvertTo-Json -Depth 20 | Out-File -FilePath $ConfigDir -Encoding UTF8
            $pe = (Get-Content $PortsEnvFile) -replace 'XHTTP_PORT=.*', "XHTTP_PORT=$newPort"
            $pe | Out-File $PortsEnvFile -Encoding UTF8
            Restart-XraySvc
            Write-Green "XHTTP端口已修改为：$newPort"
        }
        '0' { return }
        default { Write-Red '无效选项' }
    }
}

# ==========================================
# 管理订阅
# ==========================================
function Manage-Subscription {
    $s = Check-Xray
    if ($s -ne 0) {
        Write-Yellow 'Xray-2go not installed or not running'
        return
    }
    $caddyFilePath = Join-Path $WorkDir 'Caddyfile'
    Clear-Host
    Write-Host ''
    Write-Green '1. Stop subscription'
    Write-Green '2. Start subscription (new password)'
    Write-Green '3. Change subscription port'
    Write-Purple '4. Back'

    $choice = Read-Host 'Select'
    switch ($choice) {
        '1' {
            & $NssmPath stop caddy 2>$null
            Write-Green 'Subscription stopped'
        }
        '2' {
            $newPw = New-Password -Length 32
            if (Test-Path $caddyFilePath) {
                $cc = Get-Content $caddyFilePath -Raw
                $cc = $cc -replace 'handle /\w+', "handle /$newPw"
                $cc | Out-File -FilePath $caddyFilePath -Encoding UTF8
            }
            Restart-CaddySvc
            $serverIp = Get-RealIP
            $info = Get-CaddyInfo
            $argoDomain = Get-CurrentArgoDomain
            $subLink = Get-SubscriptionUrl -IP $serverIp -Port $info.Port -Path $newPw -ArgoDomain $argoDomain
            Write-Green "New subscribe link: $subLink"
        }
        '3' {
            $newPort = Read-Host 'New port (1-65535, Enter=auto)'
            if (-not $newPort) { $newPort = Find-AvailablePort -StartPort 2000 -EndPort 65000 }
            if (Test-Path $caddyFilePath) {
                $cc = Get-Content $caddyFilePath -Raw
                $cc = $cc -replace ':\d+\s*\{', ":$newPort {"
                $cc | Out-File -FilePath $caddyFilePath -Encoding UTF8
            }
            if (Test-Path $PortsEnvFile) {
                $pe = (Get-Content $PortsEnvFile) -replace 'PORT=.*', "PORT=$newPort"
                $pe | Out-File -FilePath $PortsEnvFile -Encoding UTF8
            }
            Restart-CaddySvc
            $serverIp = Get-RealIP
            $info = Get-CaddyInfo
            $argoDomain = Get-CurrentArgoDomain
            $subLink = Get-SubscriptionUrl -IP $serverIp -Port $newPort -Path $info.Path -ArgoDomain $argoDomain
            Write-Green "New subscribe link: $subLink"
        }
        '4' { return }
        default { Write-Red 'Invalid' }
    }
}
# ==========================================
# Xray 管理菜单
# ==========================================
function Manage-XrayMenu {
    Write-Green '1. 启动xray服务'
    Write-Green '2. 停止xray服务'
    Write-Green '3. 重启xray服务'
    Write-Purple '4. 返回主菜单'

    $choice = Read-Host '请输入选择'
    switch ($choice) {
        '1' { Start-XraySvc }
        '2' { Stop-XraySvc }
        '3' { Restart-XraySvc }
        '4' { return }
        default { Write-Red '无效选项' }
    }
}

# ==========================================
# Argo 管理菜单
# ==========================================
function Manage-ArgoMenu {
    $s = Check-Argo
    if ($s -eq 2) {
        Write-Yellow 'Argo 尚未安装'
        return
    }
    Load-Ports
    Clear-Host
    Write-Host ''
    Write-Green '1. 启动Argo服务'
    Write-Green '2. 停止Argo服务'
    Write-Green '3. 添加Argo固定隧道'
    Write-Green '4. 切换回Argo临时隧道'
    Write-Green '5. 重新获取Argo临时域名'
    Write-Purple '6. 返回主菜单'

    $choice = Read-Host '请输入选择'
    switch ($choice) {
        '1' { Start-ArgoSvc }
        '2' { Stop-ArgoSvc }
        '3' {
            Clear-Host
            Write-Yellow "固定隧道端口为 $($script:ARGO_PORT)"
            $argoDomain = Read-Host '请输入你的argo域名'
            $script:ArgoDomain = $argoDomain
            $argoAuth = Read-Host '请输入你的argo密钥(token)'
            if ($argoAuth -match '^[A-Z0-9a-z=]{120,250}$') {
                & $NssmPath stop cloudflared-tunnel 2>$null
                & $NssmPath remove cloudflared-tunnel confirm 2>$null
                $tokenArgs = "tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argoAuth"
                & $NssmPath install cloudflared-tunnel "$WorkDir\argo.exe" $tokenArgs
                & $NssmPath set cloudflared-tunnel AppDirectory "$WorkDir"
                & $NssmPath set cloudflared-tunnel AppStdout "$WorkDir\argo.log"
                & $NssmPath set cloudflared-tunnel AppStderr "$WorkDir\argo.log"
                & $NssmPath start cloudflared-tunnel
                Update-ArgoDomain
            }
            else {
                Write-Yellow 'token 格式不匹配'
            }
        }
        '4' {
            & $NssmPath stop cloudflared-tunnel 2>$null
            & $NssmPath remove cloudflared-tunnel confirm 2>$null
            $tmpArgs = "tunnel --url http://localhost:$($script:PORT) --no-autoupdate --edge-ip-version auto --protocol http2"
            & $NssmPath install cloudflared-tunnel "$WorkDir\argo.exe" $tmpArgs
            & $NssmPath set cloudflared-tunnel AppDirectory "$WorkDir"
            & $NssmPath set cloudflared-tunnel AppStdout "$WorkDir\argo.log"
            & $NssmPath set cloudflared-tunnel AppStderr "$WorkDir\argo.log"
            & $NssmPath start cloudflared-tunnel
            Get-QuickTunnel
            Update-ArgoDomain
        }
        '5' {
            Get-QuickTunnel
            Update-ArgoDomain
        }
        '6' { return }
        default { Write-Red '无效选项' }
    }
}

# ==========================================
# 导出菜单
# ==========================================
function Show-ExportMenu {
    $s = Check-Xray
    if (($s -ne 0) -and (-not (Test-Path $ClientDir))) {
        Write-Yellow 'Xray-2go not installed'
        return
    }

    Clear-Host
    Write-Host ''
    Write-Green '1. Export to current directory'
    Write-Green '2. Export to custom path'
    Write-Green '3. Show all node links'
    Write-Green '4. Copy subscribe link to clipboard'
    Write-Purple '5. Back'

    $choice = Read-Host 'Select'
    switch ($choice) {
        '1' { Export-ProxyTxt -Mode 'manual' }
        '2' {
            $customPath = Read-Host 'Export path'
            if (-not $customPath) { $customPath = $ExportDir }
            if (-not (Test-Path $customPath)) {
                New-Item -ItemType Directory -Path $customPath -Force | Out-Null
            }
            Export-ProxyTxt -Mode 'manual' -TargetDir $customPath
        }
        '3' {
            Load-Ports
            Write-Host ''
            Write-Green '========== Node Links =========='
            Get-Content $ClientDir | Where-Object { $_.Trim() -ne '' } | ForEach-Object { Write-Purple $_ }
            $serverIp = Get-RealIP
            $info = Get-CaddyInfo
            $argoDomain = Get-CurrentArgoDomain
        $subLink = Get-SubscriptionUrl -IP $serverIp -Port $info.Port -Path $info.Path -ArgoDomain $argoDomain
            Write-Host ''
            Write-Green '========== Subscribe =========='
            Write-Green $subLink
            Write-Green '================================'
        }
        '4' {
            Load-Ports
            $serverIp = Get-RealIP
            $info = Get-CaddyInfo
            $argoDomain = Get-CurrentArgoDomain
        $subLink = Get-SubscriptionUrl -IP $serverIp -Port $info.Port -Path $info.Path -ArgoDomain $argoDomain
            Set-Clipboard -Value $subLink
            Write-Green "Copied: $subLink"
        }
        '5' { return }
        default { Write-Red 'Invalid' }
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
        Write-Host ''
        Write-Purple "=== Xray-2go (Windows) ===`n"
        Write-Purple " Xray:  $(Get-StatusText $xrayStatus)"
        Write-Purple " Argo:  $(Get-StatusText $argoStatus)"
        Write-Purple " Caddy: $(Get-StatusText $caddyStatus)`n"
        Write-Green  '1. 安装Xray-2go'
        Write-Red    '2. 卸载Xray-2go'
        Write-Host   '==============='
        Write-Green  '3. Xray-2go管理'
        Write-Green  '4. Argo隧道管理'
        Write-Host   '==============='
        Write-Green  '5. 查看节点信息'
        Write-Green  '6. 修改节点配置'
        Write-Green  '7. 管理节点订阅'
        Write-Host   '==============='
        Write-SkyBlue '8. 导出代理为txt'
        Write-SkyBlue '9. 上传 xray2go_links_latest.txt 到 PostgreSQL'
        Write-Host   '==============='
        Write-Red    '0. 退出脚本'
        Write-Host   '==========='

        $choice = Read-Host '请输入选择(0-9)'
        Write-Host ''

        switch ($choice) {
            '1' {
                if ($xrayStatus -eq 0) {
                    Write-Yellow 'Xray-2go 已经安装！'
                    Upload-LinksLatestToPostgres
                }
                else {
                    Install-NSSM
                    Install-Caddy
                    Install-Jq
                    Install-Xray
                    Setup-CloudflareFixedTunnel
                    Apply-NatArgoPolicy
                    Install-Services
                    Start-Sleep -Seconds 3
                    Get-Info
                    Install-CaddyService
                }
            }
            '2' { Uninstall-Xray }
            '3' { Manage-XrayMenu }
            '4' { Manage-ArgoMenu }
            '5' { Show-Nodes }
            '6' { Change-Config }
            '7' { Manage-Subscription }
            '8' { Show-ExportMenu }
            '9' { Upload-LinksLatestToPostgres }
            '0' { exit 0 }
            default { Write-Red '无效选项，请输入 0 到 9' }
        }

        Write-Host ''
        Write-Host -NoNewline -ForegroundColor Red '按任意键继续...'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}


function Refresh-ExistingInstall {
    if ((Check-Xray) -ne 0) {
        Write-Red '未检测到已安装的 Xray-2go，无法使用 --skip-install。请先运行 install。'
        return
    }

    Write-Yellow '检测到已安装 Xray-2go，跳过二进制/依赖安装，仅刷新服务、Argo、订阅和导出。'
    Load-Ports
    Setup-CloudflareFixedTunnel
    Apply-NatArgoPolicy
    Install-Services
    Start-Sleep -Seconds 3
    Get-Info
    Install-CaddyService
    Upload-LinksLatestToPostgres
}

# 入口
switch ($args[0]) {
    'install' {
        if ((Check-Xray) -eq 0) {
            Write-Yellow 'Xray-2go 已经安装！'
            Upload-LinksLatestToPostgres
        }
        else {
            Install-NSSM; Install-Caddy; Install-Jq; Install-Xray; Setup-CloudflareFixedTunnel; Apply-NatArgoPolicy; Install-Services; Start-Sleep -Seconds 3; Get-Info; Install-CaddyService
        }
    }
    { $_ -in @('--skip-install', 'skip-install', 'refresh-existing', 'apply-existing') } { Refresh-ExistingInstall }
    { $_ -in @('upload-db', 'upload-links') } { Upload-LinksLatestToPostgres }
    default { Show-Menu }
}
