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
    $script:GRPC_PORT = Find-AvailablePort -StartPort 10000 -EndPort 30000
    while (($script:GRPC_PORT -eq $script:PORT) -or ($script:GRPC_PORT -eq $script:ARGO_PORT)) {
        $script:GRPC_PORT = Find-AvailablePort -StartPort 10000 -EndPort 30000
    }
    $script:XHTTP_PORT = Find-AvailablePort -StartPort 30001 -EndPort 50000
    while (($script:XHTTP_PORT -eq $script:PORT) -or ($script:XHTTP_PORT -eq $script:ARGO_PORT) -or ($script:XHTTP_PORT -eq $script:GRPC_PORT)) {
        $script:XHTTP_PORT = Find-AvailablePort -StartPort 30001 -EndPort 50000
    }

    Write-Green '端口分配完成：'
    Write-Green "  订阅端口 (PORT):       $($script:PORT)"
    Write-Green "  Argo 端口 (ARGO_PORT): $($script:ARGO_PORT)"
    Write-Green "  GRPC 端口:             $($script:GRPC_PORT)"
    Write-Green "  XHTTP 端口:            $($script:XHTTP_PORT)"
}

function Save-Ports {
    $content = @(
        "PORT=$($script:PORT)",
        "ARGO_PORT=$($script:ARGO_PORT)",
        "GRPC_PORT=$($script:GRPC_PORT)",
        "XHTTP_PORT=$($script:XHTTP_PORT)",
        "password=$($script:password)",
        "private_key=$($script:privateKey)",
        "public_key=$($script:publicKey)",
        "UUID=$($script:UUID)"
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
    $pattern = 'https://([a-zA-Z0-9][a-zA-Z0-9-]*\.trycloudflare\.com)'
    if ($content -match $pattern) {
        return $matches[1]
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

    $script:UUID = New-UUID
    $script:password = New-Password

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

    Save-Ports

    # 防火墙
    Write-Yellow '配置防火墙规则...'
    [int[]]$ports = @($script:PORT, $script:ARGO_PORT, $script:GRPC_PORT, $script:XHTTP_PORT)
    foreach ($p in $ports) {
        $ruleName = "Xray2go_Port_$p"
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p -ErrorAction SilentlyContinue | Out-Null
    }
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
                        @{ dest = 3001 },
                        @{ path = '/vless-argo'; dest = 3002 },
                        @{ path = '/vmess-argo'; dest = 3003 }
                    )
                }
                streamSettings = @{ network = 'tcp' }
            },
            @{
                port = 3001; listen = '127.0.0.1'; protocol = 'vless'
                settings = @{ clients = @( @{ id = $script:UUID } ); decryption = 'none' }
                streamSettings = @{ network = 'tcp'; security = 'none' }
            },
            @{
                port = 3002; listen = '127.0.0.1'; protocol = 'vless'
                settings = @{ clients = @( @{ id = $script:UUID; level = 0 } ); decryption = 'none' }
                streamSettings = @{ network = 'ws'; security = 'none'; wsSettings = @{ path = '/vless-argo' } }
                sniffing = @{ enabled = $true; destOverride = @('http', 'tls', 'quic'); metadataOnly = $false }
            },
            @{
                port = 3003; listen = '127.0.0.1'; protocol = 'vmess'
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
                        target = 'www.nazhumi.com:443'; xver = 0
                        serverNames = @('www.nazhumi.com')
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
                        dest = 'www.iij.ad.jp:443'
                        serverNames = @('www.iij.ad.jp')
                        privateKey = $script:privateKey; shortIds = @('')
                    }
                    grpcSettings = @{ serviceName = 'grpc' }
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
    $argoArgs = "tunnel --url http://localhost:$($script:ARGO_PORT) --no-autoupdate --edge-ip-version auto --protocol http2"
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

    $caddyConfig = @"
{
    auto_https off
}

:$($script:PORT) {
    handle /$($script:password) {
        root * $($WorkDir -replace '\\','/')
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

    & $NssmPath stop caddy 2>$null
    & $NssmPath remove caddy confirm 2>$null
    & $NssmPath install caddy "$WorkDir\caddy.exe" "run --config `"$WorkDir\Caddyfile`""
    & $NssmPath set caddy AppDirectory "$WorkDir"
    & $NssmPath set caddy DisplayName 'Caddy Web Server'
    & $NssmPath set caddy Start SERVICE_AUTO_START
    & $NssmPath set caddy AppStdout "$WorkDir\caddy_out.log"
    & $NssmPath set caddy AppStderr "$WorkDir\caddy_error.log"
    & $NssmPath start caddy
    Write-Green 'Caddy 服务已启动'
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
    $argoLog = "$WorkDir\argo.log"
    for ($i = 1; $i -le 10; $i++) {
        Write-Purple "第 $i 次尝试获取 ArgoDomain 中..."
        $argodomain = Get-ArgoDomain -LogFile $argoLog
        if ($argodomain) { break }
        Start-Sleep -Seconds 3
    }

    if (-not $argodomain) {
        Write-Red '获取 Argo 临时域名失败，请稍后重试'
        $argodomain = 'failed.trycloudflare.com'
    }

    Write-Green "`nArgoDomain: $argodomain`n"

    # VMess JSON
    $vmessObj = @{
        v    = '2'; ps = $isp; add = $CFIP; port = $CFPORT
        id   = $script:UUID; aid = '0'; scy = 'none'; net = 'ws'
        type = 'none'; host = $argodomain; path = '/vmess-argo?ed=2560'
        tls  = 'tls'; sni = $argodomain; alpn = ''; fp = 'chrome'
    }
    $vmessJson = $vmessObj | ConvertTo-Json -Compress
    $vmessBase64 = ConvertTo-Base64 -Text $vmessJson

    $urlLines = @(
        "vless://$($script:UUID)@${IP}:$($script:GRPC_PORT)??encryption=none&security=reality&sni=www.iij.ad.jp&fp=chrome&pbk=$($script:publicKey)&allowInsecure=1&type=grpc&authority=www.iij.ad.jp&serviceName=grpc&mode=gun#${isp}",
        '',
        "vless://$($script:UUID)@${IP}:$($script:XHTTP_PORT)?encryption=none&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=$($script:publicKey)&allowInsecure=1&type=xhttp&mode=auto#${isp}",
        '',
        "vless://$($script:UUID)@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}",
        '',
        "vmess://${vmessBase64}",
        ''
    )

    $urlContent = $urlLines -join "`r`n"
    $urlContent | Out-File -FilePath $ClientDir -Encoding UTF8

    Write-Purple $urlContent

    $subBase64 = ConvertTo-Base64 -Text $urlContent
    $subBase64 | Out-File -FilePath "$WorkDir\sub.txt" -Encoding UTF8 -NoNewline

    Write-Yellow "`n温馨提醒：如果是 NAT 机，reality 端口和订阅端口需使用可用端口范围内的端口`n"
    Write-Green "节点订阅链接：http://${IP}:$($script:PORT)/$($script:password)"
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
        Write-Red '节点文件不存在，请先安装 Xray-2go'
        return
    }

    $IP = Get-RealIP
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $exportFile = Join-Path $TargetDir "xray2go_proxy_${timestamp}.txt"
    $exportFileLatest = Join-Path $TargetDir 'xray2go_proxy_latest.txt'

    $argodomain = Get-ArgoDomain -LogFile "$WorkDir\argo.log"

    $subPort = $script:PORT
    $subPath = $script:password
    $caddyFile = "$WorkDir\Caddyfile"
    if (Test-Path $caddyFile) {
        $cc = Get-Content $caddyFile -Raw
        if ($cc -match ':(\d+)\s*\{') { $subPort = $matches[1] }
        if ($cc -match 'handle\s+/(\w+)') { $subPath = $matches[1] }
    }

    $urlContent = Get-Content $ClientDir -ErrorAction SilentlyContinue
    $lineGrpc  = ($urlContent | Where-Object { $_ -match 'grpc' }  | Select-Object -First 1)
    $lineXhttp = ($urlContent | Where-Object { $_ -match 'xhttp' } | Select-Object -First 1)
    $lineWs    = ($urlContent | Where-Object { $_ -match 'vless.*ws' } | Select-Object -First 1)
    $lineVmess = ($urlContent | Where-Object { $_ -match '^vmess://' } | Select-Object -First 1)

    $detailedContent = @"
============================================
  Xray-2go Proxy Info (Windows)
  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Server: ${IP}
============================================

PORT:       ${subPort}
ARGO_PORT:  $($script:ARGO_PORT)
GRPC_PORT:  $($script:GRPC_PORT)
XHTTP_PORT: $($script:XHTTP_PORT)

UUID: $($script:UUID)

Argo Domain: $(if ($argodomain) { $argodomain } else { 'N/A' })

============================================
  Node Links
============================================

--- VLESS GRPC Reality ---
$lineGrpc

--- VLESS XHTTP Reality ---
$lineXhttp

--- VLESS WS (Argo) ---
$lineWs

--- VMess WS (Argo) ---
$lineVmess

============================================
  Subscribe
============================================

http://${IP}:${subPort}/${subPath}

============================================
"@
    $detailedContent | Out-File -FilePath $exportFile -Encoding UTF8
    Copy-Item $exportFile $exportFileLatest -Force

    $linksFile = Join-Path $TargetDir "xray2go_links_${timestamp}.txt"
    $linksFileLatest = Join-Path $TargetDir 'xray2go_links_latest.txt'
    $nonEmpty = $urlContent | Where-Object { $_.Trim() -ne '' }
    $linksOut = ($nonEmpty -join "`r`n") + "`r`n`r`n# Subscribe`r`nhttp://${IP}:${subPort}/${subPath}"
    $linksOut | Out-File -FilePath $linksFile -Encoding UTF8
    Copy-Item $linksFile $linksFileLatest -Force

    if ($Mode -eq 'auto') {
        Write-Green "`n代理信息已自动导出："
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
        $subPort = $script:PORT
        $subPath = $script:password
        $cf = "$WorkDir\Caddyfile"
        if (Test-Path $cf) {
            $cc = Get-Content $cf -Raw
            if ($cc -match ':(\d+)\s*\{') { $subPort = $matches[1] }
            if ($cc -match 'handle\s+/(\w+)') { $subPath = $matches[1] }
        }
        Write-Green "`n订阅链接：http://${serverIp}:${subPort}/${subPath}`n"
    }
    else {
        Write-Yellow 'Xray-2go 尚未安装或未运行'
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
        Write-Yellow 'Xray-2go 尚未安装或未运行'
        return
    }
    Clear-Host
    Write-Host ''
    Write-Green '1. 关闭节点订阅'
    Write-Green '2. 开启节点订阅'
    Write-Green '3. 更换订阅端口'
    Write-Purple '4. 返回主菜单'

    $choice = Read-Host '请输入选择'
    switch ($choice) {
        '1' {
            & $NssmPath stop caddy 2>$null
            Write-Green '已关闭节点订阅'
        }
        '2' {
            $newPw = New-Password -Length 32
            $cc = Get-Content "$WorkDir\Caddyfile" -Raw
            $cc = $cc -replace 'handle\s+/\w+', "handle /$newPw"
            $cc | Out-File "$WorkDir\Caddyfile" -Encoding UTF8
            Restart-CaddySvc
            $serverIp = Get-RealIP
            $sp = $script:PORT
            if ($cc -match ':(\d+)\s*\{') { $sp = $matches[1] }
            Write-Green "新订阅链接：http://${serverIp}:${sp}/${newPw}"
        }
        '3' {
            $newPort = Read-Host '请输入新的订阅端口(1-65535)'
            if (-not $newPort) { $newPort = Find-AvailablePort -StartPort 2000 -EndPort 65000 }
            $cc = Get-Content "$WorkDir\Caddyfile" -Raw
            $cc = $cc -replace ':\d+\s*\{', ":$newPort {"
            $cc | Out-File "$WorkDir\Caddyfile" -Encoding UTF8
            $pe = (Get-Content $PortsEnvFile) -replace 'PORT=.*', "PORT=$newPort"
            $pe | Out-File $PortsEnvFile -Encoding UTF8
            Restart-CaddySvc
            $serverIp = Get-RealIP
            $path = $script:password
            if ($cc -match 'handle\s+/(\w+)') { $path = $matches[1] }
            Write-Green "新订阅链接：http://${serverIp}:${newPort}/${path}"
        }
        '4' { return }
        default { Write-Red '无效选项' }
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
            $tmpArgs = "tunnel --url http://localhost:$($script:ARGO_PORT) --no-autoupdate --edge-ip-version auto --protocol http2"
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
        Write-Yellow 'Xray-2go 尚未安装，无节点可导出'
        return
    }

    Clear-Host
    Write-Host ''
    Write-Green '1. 导出到当前目录'
    Write-Green '2. 导出到自定义路径'
    Write-Green '3. 在终端显示所有节点链接'
    Write-Green '4. 复制订阅链接到剪贴板'
    Write-Purple '5. 返回主菜单'

    $choice = Read-Host '请输入选择'
    switch ($choice) {
        '1' { Export-ProxyTxt -Mode 'manual' }
        '2' {
            $customPath = Read-Host '请输入导出路径'
            if (-not $customPath) { $customPath = $ExportDir }
            if (-not (Test-Path $customPath)) {
                New-Item -ItemType Directory -Path $customPath -Force | Out-Null
            }
            Export-ProxyTxt -Mode 'manual' -TargetDir $customPath
        }
        '3' {
            Load-Ports
            Write-Host ''
            Write-Green '========== 所有节点链接 =========='
            Get-Content $ClientDir | Where-Object { $_.Trim() -ne '' } | ForEach-Object { Write-Purple $_ }
            $serverIp = Get-RealIP
            $subPort = $script:PORT
            $subPath = $script:password
            $cf = "$WorkDir\Caddyfile"
            if (Test-Path $cf) {
                $cc = Get-Content $cf -Raw
                if ($cc -match ':(\d+)\s*\{') { $subPort = $matches[1] }
                if ($cc -match 'handle\s+/(\w+)') { $subPath = $matches[1] }
            }
            Write-Host ''
            Write-Green '========== 订阅链接 =========='
            Write-Green "http://${serverIp}:${subPort}/${subPath}"
            Write-Green '================================'
        }
        '4' {
            Load-Ports
            $serverIp = Get-RealIP
            $subPort = $script:PORT
            $subPath = $script:password
            $cf = "$WorkDir\Caddyfile"
            if (Test-Path $cf) {
                $cc = Get-Content $cf -Raw
                if ($cc -match ':(\d+)\s*\{') { $subPort = $matches[1] }
                if ($cc -match 'handle\s+/(\w+)') { $subPath = $matches[1] }
            }
            $subLink = "http://${serverIp}:${subPort}/${subPath}"
            Set-Clipboard -Value $subLink
            Write-Green "订阅链接已复制到剪贴板：$subLink"
        }
        '5' { return }
        default { Write-Red '无效选项' }
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
        Write-Host   '==============='
        Write-Red    '0. 退出脚本'
        Write-Host   '==========='

        $choice = Read-Host '请输入选择(0-8)'
        Write-Host ''

        switch ($choice) {
            '1' {
                if ($xrayStatus -eq 0) {
                    Write-Yellow 'Xray-2go 已经安装！'
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
            '2' { Uninstall-Xray }
            '3' { Manage-XrayMenu }
            '4' { Manage-ArgoMenu }
            '5' { Show-Nodes }
            '6' { Change-Config }
            '7' { Manage-Subscription }
            '8' { Show-ExportMenu }
            '0' { exit 0 }
            default { Write-Red '无效选项，请输入 0 到 8' }
        }

        Write-Host ''
        Write-Host -NoNewline -ForegroundColor Red '按任意键继续...'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
}

# 入口
Show-Menu
