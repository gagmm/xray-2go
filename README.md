# Xray-2go 多平台增强版

> 基于 [eooce/xray-2go](https://github.com/eooce/xray-2go) 的多平台增强 Fork，新增 macOS 和 Windows 支持，以及多项实用功能改进。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://docs.microsoft.com/powershell/)

---

## 📋 目录

- [简介](#简介)
- [与上游的区别](#与上游的区别)
- [支持协议](#支持协议)
- [支持平台](#支持平台)
- [快速开始](#快速开始)
  - [Linux](#linux)
  - [macOS](#macos)
  - [Windows](#windows)
- [环境变量](#环境变量)
- [功能特性](#功能特性)
- [菜单说明](#菜单说明)
- [客户端推荐](#客户端推荐)
- [常见问题](#常见问题)
- [致谢](#致谢)
- [免责声明](#免责声明)

---

## 简介

一键部署 Xray + Cloudflare Argo 隧道的四协议代理脚本，无交互安装，自动生成节点订阅链接。本 Fork 在原版基础上扩展了 **macOS** 和 **Windows** 平台支持，并新增了多项实用功能。

## 与上游的区别

| 特性 | 上游 [eooce/xray-2go](https://github.com/eooce/xray-2go) | 本仓库 |
|---|:---:|:---:|
| Linux 支持 | ✅ | ✅（增强版） |
| macOS 支持 | ❌ | ✅ |
| Windows 支持 | ❌ | ✅ |
| 自动端口分配 | ❌（硬编码 8080） | ✅（自动检测可用端口） |
| 多 API 获取公网 IP | ❌（仅 ip.sb） | ✅（6+ API 兜底） |
| 导出代理为 txt | ❌ | ✅（详细版 + 纯链接版） |
| 端口配置持久化 | ❌ | ✅（ports.env） |
| 手动输入 IP 兜底 | ❌ | ✅ |

## 支持协议

| 协议 | 传输方式 | 安全 | 说明 |
|---|---|---|---|
| VLESS | gRPC | Reality | 直连，高性能 |
| VLESS | XHTTP | Reality | 直连，新协议 |
| VLESS | WebSocket | TLS (Argo) | CF CDN 中转 |
| VMess | WebSocket | TLS (Argo) | CF CDN 中转 |

## 支持平台

### Linux
> Debian · Ubuntu · CentOS · Alpine · Fedora · Alma Linux · Rocky Linux · Amazon Linux

- 支持 x86_64 / aarch64 / armv7 / i386 / s390x 架构
- systemd / OpenRC 服务管理

### macOS
> macOS 12+ (Monterey 及以上)

- 支持 Intel (x86_64) 和 Apple Silicon (arm64)
- 使用 launchd 管理服务，不依赖 Homebrew
- 所有依赖通过直接下载二进制安装

### Windows
> Windows 10/11 · Windows Server 2016+

- 支持 x64 和 ARM64 架构
- 使用 NSSM 创建 Windows 服务，开机自启
- PowerShell 5.1+ 运行，需管理员权限

---

## 快速开始

### Linux

**一键安装：**
```bash
bash <(curl -Ls https://github.com/gagmm/xray-2go/raw/main/xray_2go_linux.sh)
```

**带变量安装（可选）：**
```bash
PORT=8888 CFIP=www.visa.com.tw CFPORT=8443 bash <(curl -Ls https://github.com/gagmm/xray-2go/raw/main/xray_2go_linux.sh)
```

### macOS

```bash
curl -Ls https://github.com/gagmm/xray-2go/raw/main/xray_2go_macos.sh -o xray_2go_macos.sh
chmod +x xray_2go_macos.sh
sudo bash xray_2go_macos.sh
```

### Windows

以 **管理员身份** 打开 PowerShell，执行：
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
irm https://github.com/gagmm/xray-2go/raw/main/xray_2go_win.ps1 -OutFile xray_2go_win.ps1
.\xray_2go_win.ps1
```

---

## 环境变量

安装时可通过环境变量自定义参数（均为可选）：

| 变量 | 说明 | 默认值 |
|---|---|---|
| `UUID` | 节点 UUID | 自动生成 |
| `PORT` | 订阅服务端口 | 自动分配可用端口 |
| `CFIP` | Cloudflare 优选 IP/域名 | `cdns.doon.eu.org` |
| `CFPORT` | Cloudflare 优选端口 | `443` |
| `DATABASE_URL` | 上传 `xray2go_links_latest.txt` 的 PostgreSQL 连接串 | 空 |
| `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | PostgreSQL 分项连接参数 | 空 |
| `PGSTATS_DSN` | 兼容 pgstats 的 PostgreSQL DSN；设置后 Linux 会切到 pgstats 定制核心 | 空 |
| `XRAY2GO_PG_PEER_USER` | 本机 PostgreSQL peer 鉴权用户，如 `postgres` | 空 |
| `XRAY_RELEASE_REPO` | Linux 手动指定 Xray release 仓库 | 默认 `XTLS/Xray-core`；设置 `PGSTATS_DSN` 时默认 `gagmm/Xray-core` |
| `XRAY_RELEASE_TAG` | Linux 手动指定 Xray release tag，`latest` 表示官方最新 | 默认 `latest`；设置 `PGSTATS_DSN` 时默认 `v26.4.25-pgstats3` |
| `XRAY2GO_LINKS_FILE` | 指定要上传的 links 文件路径 | 自动查找 `xray2go_links_latest.txt` |
| `REALITY_GRPC_SNI` / `REALITY_GRPC_TARGET` | 手动指定 GRPC Reality 的 SNI / 回落目标 | `www.iij.ad.jp` |
| `REALITY_XHTTP_SNI` / `REALITY_XHTTP_TARGET` | 手动指定 XHTTP/Vision Reality 的 SNI / 回落目标 | `www.nazhumi.com` |
| `REALITY_SCAN` | Linux/Windows: 设为 `1` 后启用 RealiTLScanner 自动扫描 REALITY 伪装目标；macOS 可配合 `REALITY_SCAN_BIN` 使用 | `0` |
| `REALITY_SCAN_ADDR` / `REALITY_SCAN_URL` / `REALITY_SCAN_IN` | RealiTLScanner 的扫描目标（IP/CIDR/域名、抓取 URL、目标列表文件三选一） | 空 |
| `REALITY_SCAN_BIN` | 手动指定 RealiTLScanner 可执行文件路径（macOS 必需；Linux/Windows 可选） | 自动下载/空 |
| `REALITY_SCAN_PORT` / `REALITY_SCAN_THREAD` / `REALITY_SCAN_TIMEOUT` / `REALITY_SCAN_MAX_SECONDS` | RealiTLScanner 端口、线程、单目标超时、整体超时 | `443` / `5` / `5` / `180` |

> 💡 **NAT 小鸡**需带 `PORT` 变量运行，并确保 PORT 之后的 2 个端口可用（GRPC/XHTTP），或安装后通过菜单更改端口。

### PostgreSQL 上传 xray2go_links_latest.txt（xray2go+）

安装/导出节点后，若检测到 PostgreSQL 环境变量，脚本会自动把 `xray2go_links_latest.txt` 写入 `public.xray_node_configs.links`。上传失败不会中断安装。

Linux 默认下载上游 `XTLS/Xray-core` 官方核心，以保证直连性能。只有设置 `PGSTATS_DSN` 时，脚本才会自动切到 `gagmm/Xray-core` 的 pgstats 版核心并启用 `xray_http_captures`；该模式会记录明文 HTTP 的 method/host/path/header 以及请求 body 预览字段：`body`、`body_size`、`body_truncated`、`body_base64`。同一 keep-alive 连接里的多个 HTTP/1.x 请求也会记录；HTTPS 内容不会被解密。若需要手动选择核心，可设置 `XRAY_RELEASE_REPO` / `XRAY_RELEASE_TAG`。

Linux/Windows 可选启用 RealiTLScanner 自动扫描 REALITY 伪装目标；macOS 因官方暂无发布二进制，需通过 `REALITY_SCAN_BIN` 指向自备可执行文件才会扫描。扫描成功后会把扫描到的 `IP:443` 用作 REALITY 回落目标，把可用域名用作 SNI；扫描失败、超时或未启用时，会自动回退到内置域名 `www.iij.ad.jp` / `www.nazhumi.com`。RealiTLScanner 官方说明建议优先在本地运行，云服务器上大范围扫描可能让 VPS 被标记，因此脚本默认不自动扫描。

Linux 手动上传：

```bash
POSTGRES_HOST=127.0.0.1 \
POSTGRES_PORT=5432 \
POSTGRES_USER=xray \
POSTGRES_PASSWORD='your_password' \
POSTGRES_DB=xray \
XRAY2GO_LINKS_FILE=/root/xray2go_links_latest.txt \
bash xray_2go_linux.sh upload-db
```

macOS 手动上传：

```bash
POSTGRES_HOST=127.0.0.1 \
POSTGRES_PORT=5432 \
POSTGRES_USER=xray \
POSTGRES_PASSWORD='your_password' \
POSTGRES_DB=xray \
XRAY2GO_LINKS_FILE=$HOME/xray2go_links_latest.txt \
bash xray_2go_macos.sh upload-db
```

Windows 手动上传：

```powershell
$env:POSTGRES_HOST = '127.0.0.1'
$env:POSTGRES_PORT = '5432'
$env:POSTGRES_USER = 'xray'
$env:POSTGRES_PASSWORD = 'your_password'
$env:POSTGRES_DB = 'xray'
$env:XRAY2GO_LINKS_FILE = "$env:USERPROFILE\xray2go_links_latest.txt"
.\xray_2go_win.ps1 upload-db
```

Linux 本机 PostgreSQL 使用 peer 鉴权时：

```bash
XRAY2GO_PG_PEER_USER=postgres POSTGRES_DB=xray \
XRAY2GO_LINKS_FILE=/root/xray2go_links_latest.txt \
bash xray_2go_linux.sh upload-db
```

#### 写入专用账号（推荐）

如果担心节点数据库密码泄露，先用数据库管理员/owner 初始化一个只写入口：

```bash
psql -h 127.0.0.1 -U xray -d xray \
  -v writer_password='请换成强密码' \
  -f postgres_write_only_setup.sql
```

然后脚本使用写入专用账号上传：

```bash
POSTGRES_HOST=127.0.0.1 \
POSTGRES_PORT=5432 \
POSTGRES_USER=xray2go_writer \
POSTGRES_PASSWORD='上面设置的强密码' \
POSTGRES_DB=xray \
XRAY2GO_DB_WRITE_ONLY=1 \
XRAY2GO_LINKS_FILE=/root/xray2go_links_latest.txt \
bash xray_2go_linux.sh upload-db
```

`xray2go_writer` 只能执行 `public.xray2go_ingest_links(jsonb)`，没有 `SELECT/UPDATE/DELETE/TRUNCATE` 节点表权限。

---

## 功能特性

### 🔌 自动端口分配
脚本自动检测端口占用情况，分配 4 个互不冲突的可用端口：
- 订阅端口 (PORT)
- Argo 隧道端口 (ARGO_PORT)
- GRPC Reality 端口
- XHTTP Reality 端口

### 🌐 多 API 获取公网 IP
依次尝试以下 API，确保 IP 获取成功：
1. `ifconfig.me`
2. `api.ipify.org`
3. `icanhazip.com`
4. `ipecho.net/plain`
5. `checkip.amazonaws.com`
6. `ipv4.ip.sb`
7. IPv6 备用 API
8. 全部失败时支持手动输入

### 📄 导出代理为 txt
- **详细版**：包含端口信息、UUID、Argo 域名、所有节点链接、订阅链接、使用说明
- **纯链接版**：仅含节点链接 + 订阅链接，方便直接导入
- 每次导出生成带时间戳版本和 `latest` 版本
- 支持导出到自定义路径
- 安装完成后自动导出一份

### 💾 配置持久化
所有端口、密码、密钥信息保存到 `ports.env` 文件，重启后自动加载，确保配置不丢失。

---

## 菜单说明

```
=== Xray-2go 一键安装脚本 ===

 Xray 状态: running
 Argo 状态: running
Caddy 状态: running

1. 安装 Xray-2go
2. 卸载 Xray-2go
===============
3. Xray-2go 管理 (启动/停止/重启)
4. Argo 隧道管理 (临时/固定隧道切换)
===============
5. 查看节点信息
6. 修改节点配置 (UUID/端口/伪装域名)
7. 管理节点订阅 (开启/关闭/换端口)
===============
8. 导出代理为 txt
===============
0. 退出脚本
```

---

## 客户端推荐

| 平台 | 推荐客户端 |
|---|---|
| **iOS** | Shadowrocket · Quantumult X · Loon · Stash |
| **Android** | V2rayNG · NekoBox · Karing |
| **Windows** | V2rayN · Clash Verge · Hiddify |
| **macOS** | V2rayU · ClashX Pro · Hiddify |
| **Linux** | V2rayA · Clash Verge |

> ⚠️ **xhttp 协议**目前客户端支持较少，需要 V2rayN 或 Shadowrocket 更新到支持 xhttp 的新版内核。

---

## 常见问题

<details>
<summary><b>Q: IP 获取不到怎么办？</b></summary>

脚本已内置 6 个 IPv4 API + 2 个 IPv6 API 轮询机制。如果全部失败，会提示手动输入。你也可以在运行前手动测试：
```bash
curl -s ifconfig.me
```
</details>

<details>
<summary><b>Q: Argo 域名获取失败？</b></summary>

临时隧道域名需要几秒钟才能生成。可以通过菜单 `4 → 5` 重新获取。如果反复失败，检查服务器是否能访问 Cloudflare。
</details>

<details>
<summary><b>Q: 8080 端口被占用导致 Argo 转发错误？</b></summary>

本 Fork 已解决此问题。脚本自动分配可用端口，不再硬编码 8080。如果使用旧版本安装的，请先卸载再用新版重装。
</details>

<details>
<summary><b>Q: macOS 提示 "无法打开，因为无法验证开发者"？</b></summary>

运行以下命令移除文件隔离标记：
```bash
xattr -d com.apple.quarantine ~/.xray/xray
xattr -d com.apple.quarantine ~/.xray/argo
```
</details>

<details>
<summary><b>Q: Windows 提示脚本执行策略限制？</b></summary>

以管理员身份运行 PowerShell 并执行：
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```
</details>

<details>
<summary><b>Q: Reality 节点连不上？</b></summary>

Reality 协议需要直连服务器 IP。如果服务器 IP 被墙，请使用 Argo 节点 (VLESS-WS / VMess-WS)。
</details>

---

## 致谢

- 原始脚本：[eooce/xray-2go](https://github.com/eooce/xray-2go)
- Xray 核心：[XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- Cloudflare Tunnel：[cloudflare/cloudflared](https://github.com/cloudflare/cloudflared)
- Web 服务器：[caddyserver/caddy](https://github.com/caddyserver/caddy)
- Windows 服务管理：[NSSM](https://nssm.cc/)

---

## 免责声明

- 本程序仅供学习了解，非盈利目的，请于下载后 24 小时内删除，不得用作任何商业用途，文字、数据及图片均有所属版权，如转载须注明来源。
- 使用本程序必须遵守部署服务器所在地、所在国家和用户所在国家的法律法规，程序作者不对使用者任何不当行为负责。

---

## 📜 开源许可

本项目基于 [MIT License](LICENSE) 开源。
