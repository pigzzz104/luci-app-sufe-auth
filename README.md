# luci-app-sufe-auth

上海财经大学 (SUFE) 校园网 802.1X 认证插件 (含 LuCI Web 前端)

---

### 重要说明

本插件的核心功能是**针对各物理/虚拟网口实现多账号 802.1X 并发认证与进程守护**。

**本插件并非原生自带多拨或带宽叠加功能**。如需在宿舍实现多网线聚合或单线多拨叠加网速，路由器需自行划分物理网口/VLAN，并**必须安装并配置 `mwan3` (`luci-app-mwan3`) 策略路由插件**负责流量分流与负载均衡。

---

### ⚠️ 多 WAN 稳定性必读：关闭 MTK HNAT 硬件加速

在 MT7981/MT798x 等联发科平台上，**HNAT/WARP 硬件加速会绕过 netfilter/mwan3 直接缓存 NAPT 流**。当多条 WAN 处于同一子网（例如校园网 `10.64.0.0/21`）并使用 FIB Multipath + mwan3 时，HNAT 可能把流固定到错误的 WAN，或在 **TCP 20KB 窗口处卡死**。

典型症状（与设备无关，局域网多台设备均可复现）：

- 部分网页/图片一直空白，刷新多次也不出来；
- 部分图片/网页等待一段时间后又能加载；
- 路由器本机 `curl` 正常，但 WiFi 客户端容易复现；
- 客户端（curl）可见传输停在 `20480 / ~47xxx` 字节（20KB）不再前进。

**一键修复（路由器上执行）：**

```bash
sh tools/fix_hnat_offload.sh install
```

脚本会：关闭 TurboACC 自启及其硬件 offload，安装**开机一次性关闭脚本**（`S99hnat-off`，无常驻进程）和**网口 ifup 事件钩子**（WAN/WiFi 重新拉起时再写 0），保留 BBR。

> 默认是“零常驻”精简模式。如果你希望即使手动重开 TurboACC 也能在 10 秒内自动再关掉，可额外执行：
> `sh tools/fix_hnat_offload.sh install-watchdog`（会常驻约 1 MB 内存、0% CPU，每 10 秒检查一次）。

**验证：**

```bash
# 应为 0
grep -c NAPT /sys/kernel/debug/hnat/hnat_entry

# 应显示 one-shot mode、enabled、ifup hook installed
sh tools/fix_hnat_offload.sh status

# 确认没有常驻进程（精简模式）
ps w | grep '[h]nat-off' || echo "no daemon"

# 双线聚合不受影响（实测约 20.9 MiB/s）
```

详细诊断过程、A/B 对照数据与聚合测试见 [docs/HNAT_MULTIWAN_DIAGNOSIS.md](docs/HNAT_MULTIWAN_DIAGNOSIS.md)。

**回滚：**

```bash
sh tools/fix_hnat_offload.sh rollback
# 路由器本地旧备份已清理，请使用仓库脚本执行回滚
```

> 关闭 HNAT 只影响硬件 NAT 卸载，不影响路由、NAT、mwan3 或双线聚合；MT7981 的 CPU 足以处理 2×100Mbps。若你的设备没有 `/sys/kernel/debug/hnat/hook_toggle`，脚本会自动跳过。

---

## 功能特性

- **纯原生实现**：基于 Python 3 原生 Socket 封装 IEEE 802.1X EAPOL 协议栈，无第三方扩展库依赖，运行内存占用小（单实例约 10MB）。
- **协议兼容优化**：适配上财有线网 802.1X（H3C EAP-PAP Type 7 / EAP-MD5）交互流程；每轮认证只发 **一个单播** EAPOL-Start 到交换机 MAC（学校明确要求“单播报文”），避免 H3C 因单播+组播双 Start 建立重复会话并在稍后回 `EAP-Failure`。
- **确定性状态机**：`wait_link → auth → wait_dhcp → online → recover` 显式状态机，EAP-Success 后等待 90 秒 DHCP（大于 H3C 约 30 秒的数据 VLAN 放行延迟），不再在 30 秒时误发 Logoff。
- **安全的恢复策略**：物理口做 15 秒 link reset；VLAN 口只做 Logoff + 重新认证，不触碰 `eth0`，不影响 LAN/WiFi；失败按 30/60/120/240/300 秒退避。
- **启动会话清理**：每个进程第一次认证前发一次 Logoff 清掉旧会话，等 3 秒再发一个单播 Start；停止/重启默认不发 Logoff，避免把正常端口踢下线。
- **MAC 竞态防护**：不主动改 MAC，认证前等待 netifd 套用配置 MAC；每次发帧重新读取当前 MAC，避免绑定到开机随机 MAC。
- **多实例架构**：支持在不同网卡或 VLAN 接口（如 `wan`、`wan2`、`wan3`）上独立运行认证进程，互不影响；每接口文件锁防止重复实例。
- **凭据不进 `ps`**：procd 只传 `-n <section>`，账号密码由守护进程从 UCI 读取。
- **可观测**：运行状态写入 `/var/run/sufe_auth.<ifname>.json`，可用 `sufe_auth --status -n wan` 查看；日志只记录状态转换和异常，不再每 10 秒刷屏。
- **LuCI 前端管理**：
  - 卡片式账号管理，支持动态增删线路与账号。
  - 实时显示网线连通性、DHCP IP 获取状态、守护进程 PID 及认证状态。
  - 支持一键平滑重启认证服务。
- **系统服务守护**：基于 OpenWrt `procd` 进程管理器，支持开机自启、崩溃自动重启与网线插拔重连。

> **2.0 重构详情**：见 [docs/SUFE_AUTH_REFACTOR.md](docs/SUFE_AUTH_REFACTOR.md)。其中记录了 H3C S3110 的 30 秒数据 VLAN 延迟、重复 EAPOL-Start 导致双会话、旧版 30 秒 Logoff 循环的完整抓包证据与验证数据。

- **三类多 WAN 流量**：网页 TCP 80/443 每客户端 sticky 50/50 分配 WAN1/WAN2；高并发下载回 Table 50 聚合；游戏 UDP 固定 WAN1；自动“游戏期间下载切 WAN2”暂时关闭。详见 [docs/MWAN3_WEB_BULK_GAME.md](docs/MWAN3_WEB_BULK_GAME.md)。

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
│   │   ├── init.d/
│   │   │   └── sufe_auth                  # OpenWrt procd 守护服务脚本
│   │   ├── mwan3.user                     # Table 50 + web/bulk/game 分类
│   │   └── hotplug.d/
│   │       └── iface/
│   │           └── 99-mwan3-user          # ifup/ifdown 后重建分类链
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
│           └── sufe_auth                  # 802.1X 认证核心程序（2.0 状态机）
├── tests/
│   └── test_sufe_auth.py                  # 协议/配置/恢复序列单元测试
├── docs/
│   ├── HNAT_MULTIWAN_DIAGNOSIS.md         # MTK HNAT 多 WAN 卡死诊断
│   ├── SUFE_AUTH_REFACTOR.md              # 本次认证重构的根因与验证报告
│   └── MWAN3_WEB_BULK_GAME.md             # 网页单线/下载聚合/游戏保护说明
├── tools/
│   ├── configure_mwan3.sh                 # 实用工具：MWAN3 策略路由一键优化配置脚本
│   ├── fix_hnat_offload.sh                # 实用工具：关闭 MTK HNAT，修复多 WAN 图片/网页卡死
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
   - **关联网络接口**：对应的逻辑网络（如 `wan`、`wan2`），认证成功后由守护进程通过 `SIGUSR1` 通知 udhcpc 重新发 Discover，不会 `ifup` 或重置链路。
   - **上网账号**：学号/卡号及运营商后缀，例如：
     - 中国移动：`2023xxxxxx@cmcc`
     - 中国电信：`2023xxxxxx@tel`
     - 中国联通：`2023xxxxxx@cnc`
     - 校园内网：`2023xxxxxx`
   - **上网密码**：校园网认证密码。
   - **物理 MAC 地址**：**必须填写**，且要与 `/etc/config/network` 的 `config device` / `config interface` 中的 `macaddr` 完全一致。MTK 驱动没有永久 MAC，开机会先生成随机 MAC；守护进程只校验和等待，**MAC 不一致时绝不发任何 EAPOL**，也不会自己改 MAC。netifd 负责套用配置 MAC。
   - **交换机 MAC**：已内置宿舍交换机常用单播地址（`58:ae:a8:88:0c:31`），一般保持默认即可。Start 始终单播到该 MAC；只有未配置/未学到交换机 MAC 时才用标准组播地址兜底。
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
   - **兼容硬件加速防丢包**：自动开启 `nf_conntrack_tcp_be_liberal=1`，解决联发科硬件加速（`mtkhnat` / Flow Offloading）与多 WAN 并行时 HTTP/2 复用长连接老化退回 CPU 被误判 `INVALID` 丢包的问题（消除社交媒体缩略图偶发卡顿）。
   - **本网 DNS 收敛**：移除 `dnsmasq` 并发抢答（`allservers`），收敛为上海移动本网 DNS + 223.5.5.5 保底，防止图片/视频 CDN 被异网 DNS 抢答解析至跨网或海外高延迟节点。
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

## 三类流量策略（网页单线 / 下载聚合 / 游戏保护）

在 FIB Multipath Table 50 之上增加固定三类：

| 类别 | 识别 | 出口 |
| :--- | :--- | :--- |
| 网页 | LAN TCP 80/443，低并发 | 每客户端 sticky 50/50 WAN1/WAN2 |
| 下载 | 同源总并发 >10 且同目标 >8 | mark `0x300` -> Table 50 |
| 游戏 | UDP 指定游戏端口 | WAN1 |
| 游戏中的下载 | 自动检测 | 暂不启用；游戏 UDP 仍 WAN1 |
| 其他 | 非 80/443 | Table 50 |

部署：

```bash
sh tools/configure_mwan3.sh
# 该固件 mwan3 运行时 restart 可能死锁，脚本会提示重启
reboot
```

验证：

```bash
iptables -t mangle -S mwan3_rules
iptables -t mangle -S mwan3_policy_web_affinity
iptables -t mangle -S PREROUTING
ipset list mwan3_sticky_v4_web_sticky
iptables -t nat -S MWAN3_WAN2_SNAT
ip route show table 50
```

完整说明、阈值、实测结果与边界见 [docs/MWAN3_WEB_BULK_GAME.md](docs/MWAN3_WEB_BULK_GAME.md)。

---

## 调试与日志

- **查看实时认证日志**：
  ```bash
  logread -e sufe_auth
  ```
- **查看正在运行的认证进程**：
  ```bash
  ps w | grep '[s]ufe_auth'
  # 2.0 起只显示 -n wan / -n wan2，不再把密码放进命令行
  ```
- **查看运行状态**：
  ```bash
  /usr/sbin/sufe_auth --status -n wan
  cat /var/run/sufe_auth.eth1.json
  ```
- **命令行单步调试**（会覆盖 UCI 中的账号密码，仅临时使用）：
  ```bash
  python3 /usr/sbin/sufe_auth -i eth1 -u 账号@cmcc -p 密码 -v
  ```

### 重启后认证成功但 DHCP 拿不到地址（2.0 已重构）

旧版日志：

```text
EAP Authentication SUCCESS!
Authentication successful! Triggering DHCP...
netifd: Interface 'wan' is disabled
netifd: wan: Command failed: Permission denied
```

旧版根因有三层，详见 [docs/SUFE_AUTH_REFACTOR.md](docs/SUFE_AUTH_REFACTOR.md)：

1. `trigger_dhcp()` 曾调用 `ifup`，netifd 重套 MAC、link down/up，打断 802.1X；
2. H3C S3110 在 EAP-Success 后约 **30 秒**才放行数据 VLAN，旧版正好在 30 秒时
   执行 `EAPOL-Logoff + eth1 down 2 秒`，把即将放行的会话踢掉，形成 5 分钟循环；
3. 每轮同时发单播+组播两个 EAPOL-Start，H3C 会建立两个认证会话，稍后回
   `EAP-Failure`；旧版又忽略 `wait_dhcp` 中的 Failure，无法及时重认证。

2.0 的行为：

- EAP-Success 后等待 **90 秒** DHCP，期间用 `SIGUSR1` 让 udhcpc 重发 Discover；
- 每轮只发 **一个单播** EAPOL-Start 到交换机 MAC；没有交换机 MAC 时才用组播兜底；
- 每个进程首次认证前发一次 Logoff 清旧会话，等 3 秒再 Start；
- 物理口恢复做 **15 秒** link reset；VLAN 口只 Logoff + 重认证，不碰 `eth0`；
- `wait_dhcp` / `online` 收到 EAP-Failure 会立即重认证；
- 停止/重启默认不发 Logoff；恢复按 30/60/120/240/300 秒退避。

如果上游交换机彻底无响应，仍可手动恢复物理口：

```bash
ip link set eth1 down; sleep 15; ip link set eth1 up
```

VLAN 口（eth0.2/eth0.3）不要 down 父接口 `eth0`，否则会影响 LAN/WiFi；优先
`/etc/init.d/sufe_auth restart`，或拔插对应网线。

> **如果 EAP/DHCP 都成功，但 `ping 10.64.0.1` 仍 100% 丢包、ARP 显示 FAILED**：先对 WAN 网线做一次**物理拔插 60 秒**（`ip link set down/up` 往往清不掉 H3C 的 port-security/err-disable）。恢复后若 Table 50 只有一条线，检查 `mwan3track`/`iface_state`。这属于有线校园网端口/网关问题，不是认证脚本能单独解决的。用另一台设备直插同一墙面端口对比，并联系校园网管理员检查该端口的 802.1X 授权 VLAN、端口安全 sticky MAC 和 DHCP snooping 绑定。详见 [docs/SUFE_AUTH_REFACTOR.md](docs/SUFE_AUTH_REFACTOR.md) 第 9 节。

---

## 许可证

本项目基于 [MIT License](LICENSE) 开源发布。
