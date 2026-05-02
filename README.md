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
| `PGSTATS_DSN` | Xray pgstats 运行统计 PostgreSQL DSN | 空 |
| `DATABASE_URL` | 节点配置上传 PostgreSQL 连接串 | 空 |
| `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | 节点配置上传 PostgreSQL 分项连接参数 | 空 |
| `XRAY2GO_PG_PEER_USER` | 本机 PostgreSQL peer 鉴权用户，如 `postgres` | 空 |

> 💡 **NAT 小鸡**需带 `PORT` 变量运行，并确保 PORT 之后的 2 个端口可用（GRPC/XHTTP），或安装后通过菜单更改端口。

### PostgreSQL 节点配置上传（xray2go+）

安装完成后，若检测到 PostgreSQL 环境变量，脚本会自动把节点配置写入 `public.xray_node_configs`。上传失败不会中断安装。

```bash
POSTGRES_HOST=127.0.0.1 \
POSTGRES_PORT=5432 \
POSTGRES_USER=xray \
POSTGRES_PASSWORD='your_password' \
POSTGRES_DB=xray \
bash <(curl -Ls https://github.com/gagmm/xray-2go/raw/main/xray_2go_linux.sh) install
```

本机 PostgreSQL 使用 peer 鉴权时：

```bash
XRAY2GO_PG_PEER_USER=postgres POSTGRES_DB=xray \
bash <(curl -Ls https://github.com/gagmm/xray-2go/raw/main/xray_2go_linux.sh) install
```

手动重传当前节点配置：

```bash
XRAY2GO_PG_PEER_USER=postgres POSTGRES_DB=xray ./xray_2go_linux.sh upload-db
```

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
