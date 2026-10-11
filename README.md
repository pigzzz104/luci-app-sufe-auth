# luci-app-sufe-auth

上海财经大学 (SUFE) 校园网 802.1X 认证插件 (含 LuCI Web 前端)

---

### 重要说明

本插件的核心功能是**针对各物理/虚拟网口实现多账号 802.1X 并发认证与进程守护**。

**本插件并非原生自带多拨或带宽叠加功能**。如需在宿舍实现多网线聚合或单线多拨叠加网速，路由器需自行划分物理网口/VLAN，并**必须安装并配置 `mwan3` (`luci-app-mwan3`) 策略路由插件**负责流量分流与负载均衡。

---

## 功能特性

- **纯原生实现**：基于 Python 3 原生 Socket 封装 IEEE 802.1X EAPOL 协议栈，无第三方扩展库依赖，运行内存占用小（单实例约 10MB）。
- **协议兼容优化**：适配上财有线网 802.1X (EAP-MD5) 交互流程；针对交换机中途周期性发起的 EAP-Request 心跳重认证进行平滑应答，避免重复握手导致连接波动。
- **多实例架构**：支持在不同网卡或 VLAN 接口（如 `wan`、`wan2`、`wan3`）上独立运行认证进程，互不影响。
- **LuCI 前端管理**：
  - 卡片式账号管理，支持动态增删线路与账号。
  - 实时显示网线连通性、DHCP IP 获取状态、守护进程 PID 及认证状态。
  - 支持一键平滑重启认证服务。
- **系统服务守护**：基于 OpenWrt `procd` 进程管理器，支持开机自启、崩溃自动重启与网线插拔重连。

---

## 环境要求

- **操作系统**：OpenWrt / ImmortalWrt (21.02 及以上版本)
- **运行依赖**：`python3`, `python3-syslog`, `ip-full`
- **多线聚合依赖（可选）**：`mwan3`, `luci-app-mwan3`, `kmod-macvlan` (若单线多拨)

---

## 项目结构

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
│           └── sufe_auth                  # 802.1X 认证核心程序
├── tools/
│   ├── configure_mwan3.sh                 # 实用工具：MWAN3 策略路由一键优化配置脚本
│   └── restore_ipv6.sh                    # 实用工具：一键还原 IPv6 配置
├── install.sh                             # 路由器一键安装脚本
├── uninstall.sh                           # 卸载脚本
├── LICENSE                                # MIT 许可证
└── README.md                              # 说明文档
```

---

## 安装方法

### 方式一：路由器一键在线安装

登录路由器 SSH 终端，执行以下命令安装：

```bash
curl -fsSL https://raw.githubusercontent.com/pigzzz104/luci-app-sufe-auth/master/install.sh | sh
```

### 方式二：手动上传安装

1. 克隆代码：
   ```bash
   git clone https://github.com/pigzzz104/luci-app-sufe-auth.git
   ```
2. 上传至路由器并安装：
   ```bash
   scp -r luci-app-sufe-auth root@192.168.x.x:/tmp/
   ssh root@192.168.x.x
   cd /tmp/luci-app-sufe-auth && chmod +x install.sh && ./install.sh
   ```

### 方式三：源码编译打包

将本仓库置于 OpenWrt 源码目录下的 `package/` 或 feeds 中：
```bash
git clone https://github.com/pigzzz104/luci-app-sufe-auth.git package/luci-app-sufe-auth
make menuconfig
# 在 LuCI -> Applications 中选中 luci-app-sufe-auth
make package/luci-app-sufe-auth/compile V=s
```

---

## 配置指南

1. 进入路由器管理后台：**【网络】 -> 【上财校园网认证】**。
2. 配置参数说明：
   - **启用**：勾选后生效。
   - **线路标识**：便于区分的名称（如 `主校园网`、`室友A`）。
   - **物理网卡接口**：填入对应的网卡名（主 WAN 通常为 `eth1`；多路 VLAN 通常为 `eth0.2` 等）。
   - **关联网络接口**：对应的逻辑网络（如 `wan`、`wan2`），认证通过后会自动触发该接口刷新 DHCP。
   - **上网账号**：学号/卡号及运营商后缀，例如：
     - 中国移动：`2023xxxxxx@cmcc`
     - 中国电信：`2023xxxxxx@tel`
     - 中国联通：`2023xxxxxx@cnc`
     - 校园内网：`2023xxxxxx`
   - **上网密码**：校园网认证密码。
   - **物理 MAC 地址**：可选。留空则直接使用网卡自带 MAC；若账号绑定过设备 MAC，填入后将自动完成修改。
   - **交换机 MAC**：已内置宿舍交换机常用单播地址（`58:ae:a8:88:0c:31`），一般保持默认即可。
3. 点击页面右下角 **【保存并应用】**。

---

## 配合 MWAN3 开展多线聚合说明

若需进行多线并发聚合，请参考以下网络拓扑与配置逻辑：

1. **接口准备**：
   - 保留一个网口（如 LAN3）作为路由器后台管理口。
   - 其余物理网口通过 Switch VLAN（`swconfig` 或 DSA 交换架构）划分为独立的外部网络接口（如 `eth1` 为 WAN1，`eth0.2` 为 WAN2）。
2. **多账号认证**：
   - 在本插件内为各接口分别添加配置并启动认证。各接口握手成功后通过 DHCP 获取到各自的内网 IP。
3. **策略路由配置（提供一键脚本）**：
   为降低多线分流配置门槛，仓库在 `tools/` 目录下提供了基于实战调优的配置脚本 `tools/configure_mwan3.sh`：
   - 自动为 `wan`、`wan2`、`wan3` 写入互不冲突的路由跃点 Metric (10/20/30)。
   - 自动关联防火墙 WAN 区域。
   - 写入阿里/腾讯双公共 DNS (223.5.5.5, 119.29.29.29) 链路健康检测。
   - 游戏与语音常见 UDP 端口启用 IP 粘性（Sticky）并优先走主 WAN，杜绝游戏掉线。
   - 常规流量与多线程下载采用平衡策略（Balanced），实现带宽并发叠加。

   在路由器终端执行以下命令即可一键应用该策略：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/pigzzz104/luci-app-sufe-auth/master/tools/configure_mwan3.sh | sh
   ```
   或在克隆仓库后执行：
   ```bash
   sh tools/configure_mwan3.sh
   ```

---

## 调试与日志

- **查看实时认证日志**：
  ```bash
  logread -e sufe_auth
  ```
- **查看正在运行的认证进程**：
  ```bash
  ps | grep sufe_auth
  ```
- **命令行单步调试**：
  ```bash
  python3 /usr/sbin/sufe_auth -i eth1 -u 账号@cmcc -p 密码 -v
  ```

---

## 许可证

本项目基于 [MIT License](LICENSE) 开源发布。
