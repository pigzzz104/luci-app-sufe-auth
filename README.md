# luci-app-sufe-auth

<p align="center">
  <b>上海财经大学 (SUFE) 校园网 802.1X 多账号认证 OpenWrt / ImmortalWrt 插件与 LuCI Web 控制台</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/OpenWrt-21.02%20|%2022.03%20|%2023.05-blue?logo=openwrt" alt="OpenWrt">
  <img src="https://img.shields.io/badge/ImmortalWrt-Compatible-brightgreen?logo=openwrt" alt="ImmortalWrt">
  <img src="https://img.shields.io/badge/Python-3.x-yellow?logo=python" alt="Python3">
  <img src="https://img.shields.io/badge/LuCI-CBI%20UI-orange" alt="LuCI">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License">
</p>

---

## 📖 项目简介

`luci-app-sufe-auth` 是专为**上海财经大学（SUFE）校园网**量身打造的开源 OpenWrt / ImmortalWrt 认证客户端及 LuCI 前端管理面板。

由于市面上已有的校园网客户端（如 sysuh3c、mentohust）在上财特定的 802.1X 交换机握手协议（MD5-Challenge 计算、心跳保活帧格式、单播/组播混合机制）下存在不兼容、频繁掉线或无法认证的问题，本项目从底层重新实现了轻量、高效的纯 Python 协议引擎，并提供了现代化的 LuCI Web 操作界面。

同时，针对宿舍宽带场景，本插件原生深度支持**多实例并发架构**，可轻松实现**宿舍多人账号汇聚、单线多拨、多网线物理叠加（Multi-WAN 负载均衡）**，突破单账号带宽限制。

---

## ✨ 核心特性

- ⚡ **纯原生轻量实现**：基于原生 Python 3 底层 `AF_PACKET` Raw Socket 实现完整的 IEEE 802.1X EAPOL 协议栈，无任何重型第三方库依赖，内存占用低（单进程约 10MB）。
- 🔄 **协议适配完整**：
  - 完美支持标准 `EAPOL-Start`、`EAP-MD5-Challenge`、`EAPOL-Logoff`。
  - 深度适配上财宿舍 H3C 交换机的中途心跳重认证（Periodic Keep-Alive），智能维持会话，杜绝日志泛滥与频繁断流。
- 🌐 **多实例多账号架构**：
  - 支持配置任意数量的物理 WAN、VLAN 子接口或虚拟网卡（例如 `wan`, `wan2`, `wan3`）。
  - 每个接口拥有独立的认证进程与状态机，互不干扰，支持宿舍合租宽带多账号叠加。
- 🖥️ **现代化 LuCI Web 前端**：
  - **可视化卡片式管理**：动态添加、修改、启用或删除任意线路账号。
  - **实时状态感知**：实时感知物理网卡连接（Link UP/DOWN）、DHCP 获取 IP 状态、认证守护进程 PID 及 802.1X 认证结果。
  - **一键快捷重连**：界面提供一键平滑重启认证服务按钮。
- 🛡️ **高可靠守护 (procd)**：深度接入 OpenWrt 原生 `procd` 服务看门狗，开机自动拉起，进程异常自愈，网线插拔自动触发重新握手。
- 🚀 **聚合生态友好**：完美协同 `mwan3`（多线负载均衡与粘性分流）及 `TurboACC` 网络加速。

---

## 📂 项目结构

```text
luci-app-sufe-auth/
├── Makefile                               # OpenWrt SDK / Feed 编译规则文件
├── root/                                  # 路由器系统部署根目录
│   ├── etc/
│   │   ├── config/
│   │   │   └── sufe_auth                  # UCI 配置文件模板
│   │   └── init.d/
│   │       └── sufe_auth                  # OpenWrt procd 守护服务脚本
│   └── usr/
│       ├── lib/
│       │   └── lua/
│       │       └── luci/
│       │           ├── controller/
│       │           │   └── sufe_auth.lua  # LuCI 路由注册控制器
│       │           └── model/
│       │               └── cbi/
│       │                   └── sufe_auth.lua # LuCI 前端 Web 配置页面
│       └── sbin/
│           └── sufe_auth                  # 核心 802.1X 认证 Python 引擎
├── tools/
│   └── restore_ipv6.sh                    # 实用网络工具：一键还原 IPv6 配置脚本
├── install.sh                             # 路由器一键自动化安装脚本
├── uninstall.sh                           # 一键干净卸载脚本
├── LICENSE                                # 开源许可证 (MIT)
└── README.md                              # 项目使用说明文档
```

---

## 🚀 安装部署

### 方式一：路由器一键在线安装（推荐）

如果你的路由器已连接至网络（例如手机热点中继或临时网络），通过 SSH 登录路由器后台后，执行以下命令即可全自动安装：

```bash
curl -fsSL https://raw.githubusercontent.com/pigzzz104/luci-app-sufe-auth/master/install.sh | sh
```

### 方式二：手动上传安装

1. 下载或克隆本仓库到本地电脑：
   ```bash
   git clone https://github.com/pigzzz104/luci-app-sufe-auth.git
   ```
2. 将项目目录复制到路由器并运行安装脚本：
   ```bash
   scp -r luci-app-sufe-auth root@192.168.x.x:/tmp/
   ssh root@192.168.x.x
   cd /tmp/luci-app-sufe-auth && chmod +x install.sh && ./install.sh
   ```

### 方式三：OpenWrt SDK 源码编译

将本仓库放置于 OpenWrt 源码目录下的 `package/` 或 feeds 中：
```bash
git clone https://github.com/pigzzz104/luci-app-sufe-auth.git package/luci-app-sufe-auth
make menuconfig
# 在 LuCI -> Applications 中选中 luci-app-sufe-auth
make package/luci-app-sufe-auth/compile V=s
```

---

## ⚙️ 使用与配置说明

1. 登录路由器 LuCI Web 管理界面（如 `http://192.168.6.1`）。
2. 在导航栏进入：**【网络 (Network)】 -> 【上财校园网认证 (SUFE Auth)】**。
3. 在页面中根据需要配置你的上网账号：
   * **启用**：勾选以启用该实例。
   * **线路标识**：为该线路起一个直观的名称（如 `主校园网 (WAN1)` 或 `室友A (WAN2)`）。
   * **物理网卡接口**：绑定对应的物理网卡或 VLAN 接口（如主 WAN 为 `eth1`，第二路为 `eth0.2` 等）。
   * **关联网络接口**：对应的逻辑网络（如 `wan`、`wan2`），认证通过后会自动触发 DHCP 刷新。
   * **上网账号**：输入你的学号/卡号并附带运营商后缀，例如：
     * 中国移动：`2023xxxxxx@cmcc`
     * 中国电信：`2023xxxxxx@tel`
     * 中国联通：`2023xxxxxx@cnc`
     * 校园内网：`2023xxxxxx`
   * **上网密码**：校园网认证密码。
   * **物理 MAC 地址**：可选。留空则直接使用网卡自带物理 MAC；如果账号绑定了特定电脑 MAC，在此填入可自动完成硬件伪装。
   * **交换机 MAC**：已内置宿舍上级交换机默认单播地址（`58:ae:a8:88:0c:31`），一般保持默认即可。
4. 点击页面底部的 **【保存并应用 (Save & Apply)】**。
5. 顶部状态栏会实时显示各线路的连接阶段：
   * `● 正在运行 (已认证)`：握手成功，正常上网中。
   * `● 正在连接 (等待 DHCP/响应)`：正在握手或已通过 802.1X 握手正等待分配 IP。
   * `● 网线未连接`：物理端口未插网线。

---

## 🖧 进阶应用：宿舍多网线带宽聚合 (Multi-WAN 实战)

以常见的 **4 口 Wi-Fi 6 路由器（如 H3C NX30 Pro / 红米 AX6000）** 为例，改造方案如下：

### 1. 物理端口规划
* **机身 WAN 口 (`eth1`)**：插入第一根校园网网线，配置为主 WAN (`wan`)。
* **机身 LAN1 口 (划分为 VLAN `eth0.2`)**：插入室友 A 的校园网网线，配置为 WAN2 (`wan2`)。
* **机身 LAN2 口 (划分为 VLAN `eth0.3`)**：插入室友 B 的校园网网线，配置为 WAN3 (`wan3`)。
* **机身 LAN3 口 (`br-lan`)**：保留为局域网有线口，供电脑直连或接入交换机，用于管理后台和本地低延迟通信。

### 2. 负载均衡与游戏防掉线优化 (MWAN3)
在多路聚合环境下，如果随意轮询分流，可能导致游戏平台（Steam、CSGO、战网、完美对战平台等）或网银由于 IP 瞬时跳变而被踢下线。建议配置以下 MWAN3 策略：
1. **游戏 / 语音专用分流**：针对 UDP 协议或游戏常见端口（如 27015 等），配置强制走固定的 `WAN1` 优先跃点。
2. **HTTPS / SSL 粘性 IP (Sticky Sessions)**：为 443 端口启用会话保持（Sticky），同一目标服务器在会话存活期间固定走同一 WAN 节点。
3. **大文件下载 / 网盘并发**：针对通用 HTTP 大流量下载启用多链路权重平衡（Balanced Policy），实现下载速率翻倍。

---

## 🛠️ 故障排查与调试

如遇认证问题，可通过命令行快速定位：

1. **查看认证服务实时系统日志**：
   ```bash
   logread -e sufe_auth
   ```
2. **查看当前运行的认证守护进程**：
   ```bash
   ps | grep sufe_auth
   ```
3. **前台运行详细调试模式**：
   如需观察底层 802.1X 数据帧交互细节，可单次前台运行并加上 `-v` 参数：
   ```bash
   python3 /usr/sbin/sufe_auth -i eth1 -u 你的账号@cmcc -p 你的密码 -v
   ```

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 开源发布。欢迎提 Issue 与 Pull Request 共同完善！
