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
$script:REALITY_GRPC_SNI = if ($env:REALITY_GRPC_SNI) { $env:REALITY_GRPC_SNI } else { 'www.iij.ad.jp' }
$script:REALITY_GRPC_TARGET = if ($env:REALITY_GRPC_TARGET) { $env:REALITY_GRPC_TARGET } else { $script:REALITY_GRPC_SNI }
$script:REALITY_XHTTP_SNI = if ($env:REALITY_XHTTP_SNI) { $env:REALITY_XHTTP_SNI } else { 'www.nazhumi.com' }
$script:REALITY_XHTTP_TARGET = if ($env:REALITY_XHTTP_TARGET) { $env:REALITY_XHTTP_TARGET } else { $script:REALITY_XHTTP_SNI }

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
        $script:REALITY_GRPC_SNI = if ($env:REALITY_GRPC_SNI) { $env:REALITY_GRPC_SNI } else { 'www.iij.ad.jp' }
    }
    if (-not $script:REALITY_GRPC_TARGET) {
        $script:REALITY_GRPC_TARGET = if ($env:REALITY_GRPC_TARGET) { $env:REALITY_GRPC_TARGET } else { $script:REALITY_GRPC_SNI }
    }
    if (-not $script:REALITY_XHTTP_SNI) {
        $script:REALITY_XHTTP_SNI = if ($env:REALITY_XHTTP_SNI) { $env:REALITY_XHTTP_SNI } else { 'www.nazhumi.com' }
    }
    if (-not $script:REALITY_XHTTP_TARGET) {
        $script:REALITY_XHTTP_TARGET = if ($env:REALITY_XHTTP_TARGET) { $env:REALITY_XHTTP_TARGET } else { $script:REALITY_XHTTP_SNI }
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

    $scanner = if ($env:REALITY_SCAN_BIN) { $env:REALITY_SCAN_BIN } else { Join-Path $WorkDir 'RealiTLScanner.exe' }
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

    $out = if ($env:REALITY_SCAN_OUT) { $env:REALITY_SCAN_OUT } else { Join-Path $env:TEMP 'realitlscanner-out.csv' }
    $log = if ($env:REALITY_SCAN_LOG) { $env:REALITY_SCAN_LOG } else { Join-Path $env:TEMP 'realitlscanner.log' }
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

    $scanArgs += @(
        '-port', (if ($env:REALITY_SCAN_PORT) { $env:REALITY_SCAN_PORT } else { '443' }),
        '-thread', (if ($env:REALITY_SCAN_THREAD) { $env:REALITY_SCAN_THREAD } else { '5' }),
        '-timeout', (if ($env:REALITY_SCAN_TIMEOUT) { $env:REALITY_SCAN_TIMEOUT } else { '5' }),
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
    $cert = if ($cols.Count -gt 2) { $cols[2].Trim(' ', '"', "`r") } else { '' }
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
        "vless://$($script:UUID)@${IP}:$($script:GRPC_PORT)?encryption=none&security=reality&sni=$($script:REALITY_GRPC_SNI)&fp=chrome&pbk=$($script:publicKey)&allowInsecure=1&type=grpc&authority=$($script:REALITY_GRPC_SNI)&serviceName=grpc&mode=gun#${isp}-grpc-reality",
        '',
        "vless://$($script:UUID)@${IP}:$($script:XHTTP_PORT)?encryption=none&security=reality&sni=$($script:REALITY_XHTTP_SNI)&fp=chrome&pbk=$($script:publicKey)&allowInsecure=1&type=xhttp&mode=auto#${isp}-xhttp-reality",
        '',
        "hysteria2://$($script:hy2Password)@${IP}:$($script:HY2_PORT)?insecure=1&sni=xray2go.local#${isp}-hy2",
        '',
        "vless://$($script:UUID)@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${isp}-vless-argo",
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

    $adStr = if ($argodomain) { $argodomain } else { 'N/A' }
    $subLink = "http://${IP}:${subPort}/${subPath}"

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
        $env:PGPASSWORD = if ($env:POSTGRES_PASSWORD) { $env:POSTGRES_PASSWORD } else { $env:PGPASSWORD }
        & psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -q -f $SqlFile
    }
    elseif ($env:PGSTATS_DSN) {
        & psql $env:PGSTATS_DSN -v ON_ERROR_STOP=1 -q -f $SqlFile
    }
    else {
        $env:PGHOST = if ($env:POSTGRES_HOST) { $env:POSTGRES_HOST } elseif ($env:PGHOST) { $env:PGHOST } else { '127.0.0.1' }
        $env:PGPORT = if ($env:POSTGRES_PORT) { $env:POSTGRES_PORT } elseif ($env:PGPORT) { $env:PGPORT } else { '5432' }
        $env:PGUSER = if ($env:POSTGRES_USER) { $env:POSTGRES_USER } elseif ($env:PGUSER) { $env:PGUSER } else { 'postgres' }
        $env:PGPASSWORD = if ($env:POSTGRES_PASSWORD) { $env:POSTGRES_PASSWORD } else { $env:PGPASSWORD }
        $env:PGDATABASE = if ($env:POSTGRES_DB) { $env:POSTGRES_DB } elseif ($env:PGDATABASE) { $env:PGDATABASE } else { 'xray' }
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
    $publicIpSql = if ($publicIp -and $publicIp -ne '127.0.0.1' -and $publicIp -notmatch ':') { (Quote-SqlText $publicIp) + '::inet' } else { 'NULL' }
    $subUrl = if ($publicIp -and $script:PORT -and $script:password) { "http://${publicIp}:$($script:PORT)/$($script:password)" } else { '' }
    $cdnHost = if ($meta.Contains('host')) { $meta['host'] } else { $CFIP }

    $payload = [ordered]@{
        node_id = $nodeId
        hostname = $hostname
        public_ip = if ($publicIp -and $publicIp -ne '127.0.0.1' -and $publicIp -notmatch ':') { $publicIp } else { '' }
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
        $sql = @"
CREATE TABLE IF NOT EXISTS public.xray_node_configs (
 node_id text PRIMARY KEY, hostname text NOT NULL DEFAULT '', public_ip inet, install_dir text NOT NULL DEFAULT '', cdn_host text NOT NULL DEFAULT '', argo_domain text NOT NULL DEFAULT '', sub_url text NOT NULL DEFAULT '', uuid text NOT NULL DEFAULT '', public_key text NOT NULL DEFAULT '', ports jsonb NOT NULL DEFAULT '{}'::jsonb, links jsonb NOT NULL DEFAULT '{}'::jsonb, config_json jsonb NOT NULL DEFAULT '{}'::jsonb, raw_ports_env jsonb NOT NULL DEFAULT '{}'::jsonb, script_version text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.xray_node_configs (node_id, hostname, public_ip, install_dir, cdn_host, argo_domain, sub_url, uuid, public_key, ports, links, config_json, raw_ports_env, script_version, created_at, updated_at)
VALUES ($(Quote-SqlText $nodeId), $(Quote-SqlText $hostname), $publicIpSql, $(Quote-SqlText $WorkDir), $(Quote-SqlText $cdnHost), '', $(Quote-SqlText $subUrl), $(Quote-SqlText $script:UUID), $(Quote-SqlText $script:publicKey), $(ConvertTo-SqlJsonb $ports), $(ConvertTo-SqlJsonb $links), '{}'::jsonb, $(ConvertTo-SqlJsonb $meta), 'links_latest_windows', now(), now())
ON CONFLICT (node_id) DO UPDATE SET hostname=EXCLUDED.hostname, public_ip=EXCLUDED.public_ip, install_dir=EXCLUDED.install_dir, cdn_host=EXCLUDED.cdn_host, sub_url=EXCLUDED.sub_url, uuid=EXCLUDED.uuid, public_key=EXCLUDED.public_key, ports=EXCLUDED.ports, links=EXCLUDED.links, raw_ports_env=EXCLUDED.raw_ports_env, script_version=EXCLUDED.script_version, updated_at=now();
"@
    }
    $tmpRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
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
        $subLink = "http://${serverIp}:$($info.Port)/$($info.Path)"
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
            $subLink = "http://${serverIp}:$($info.Port)/$newPw"
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
            $subLink = "http://${serverIp}:${newPort}/$($info.Path)"
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
            $subLink = "http://${serverIp}:$($info.Port)/$($info.Path)"
            Write-Host ''
            Write-Green '========== Subscribe =========='
            Write-Green $subLink
            Write-Green '================================'
        }
        '4' {
            Load-Ports
            $serverIp = Get-RealIP
            $info = Get-CaddyInfo
            $subLink = "http://${serverIp}:$($info.Port)/$($info.Path)"
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

# 入口
switch ($args[0]) {
    'install' {
        if ((Check-Xray) -eq 0) {
            Write-Yellow 'Xray-2go 已经安装！'
            Upload-LinksLatestToPostgres
        }
        else {
            Install-NSSM; Install-Caddy; Install-Jq; Install-Xray; Install-Services; Start-Sleep -Seconds 3; Get-Info; Install-CaddyService
        }
    }
    { $_ -in @('upload-db', 'upload-links') } { Upload-LinksLatestToPostgres }
    default { Show-Menu }
}
