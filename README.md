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
3. **策略路由配置（内核级 FIB Multipath 流哈希）**：
   传统的 MWAN3 连接级随机分流往往存在两难困境：要么因为连接跳 IP 导致网页登录态失效，要么因为粗暴开启端口粘性导致多线程下载被死锁在单条链路上（如 100M 单线仅能跑 11 MB/s）。同时，由于现代客户端（如网盘、流媒体）广泛使用 HTTPDNS 绕过路由器 DNS，基于域名/IPSET 的穷举分流方案极易失效且异常臃肿。

   本项目在 `tools/configure_mwan3.sh` 中实装了经过实战检验的 **Linux 内核 FIB Multipath 确定性流哈希分流方案**：
   - **底层机制**：通过 `/etc/mwan3.user` 在内核路由表（Table 50）中动态维护多路径 `nexthop`，按 `(源IP, 目的IP)` 计算确定性流哈希。
   - **根治跳 IP**：同一目标服务器 IP 的所有流量必定锁定在同一条出口线路上，银行、教务系统、网页登录态 100% 稳定，免去维护域名白名单的繁琐开销。
   - **多线并发叠加**：网盘大文件下载（如夸克、百度）、游戏分片更新天然并发请求多个 CDN 节点 IP，不同目标 IP 均匀散列到各 WAN 口，实测稳定突破单线瓶颈、跑满聚合带宽（如双线达 20+ MB/s）。
   - **自动故障转移**：配合热插拔钩子，当任一线路上/下线时，自动无缝重算 Table 50 路由。
   - *(注：若使用单节点测速工具测速，因仅连接单一测速服务器 IP，测试结果按哈希规律必然呈现单线速率，属正常数学特性)*。

   在路由器终端执行以下命令即可一键部署该优化策略：
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
