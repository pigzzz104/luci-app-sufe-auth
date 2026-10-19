# sufe_auth 2.0：从“认证成功但断网”到确定性状态机

本文记录 2026-10-19 对 `root/usr/sbin/sufe_auth` 的完整重构，包括现场证据、
根因、设计取舍、验证结果和回滚方法。适用于上财宿舍 H3C S3110 交换机 +
ImmortalWrt 18.06/MT7981 环境。

---

## 1. 现象

路由器重启后经常出现：

```text
EAP Authentication SUCCESS!
... DHCP discover ...
（一直拿不到 IP）
```

或者：

```text
EAP-Success
（约 25~30 秒后）EAP-Failure
```

旧版脚本会在这时执行：

```text
EAPOL-Logoff -> 等 10 秒 -> eth1 down 2 秒 -> up -> 重新认证
```

结果每 5 分钟重复一次，端口始终无法进入稳定数据态。两条 WAN 可能同时中招。
手动执行一次 **15 秒** link down/up，eth1 立刻恢复并拿到 IP；说明账号、密码、
VLAN、DHCP 服务器都没有问题，问题在 **802.1X 会话/端口状态机**。

---

## 2. 现场证据

### 2.1 交换机与端口

LLDP 抓包：

```text
H3C Switch S3110-52TP Software Version 5.20.99
eth1    -> Ethernet1/0/4, PVID 1648, VLAN 1648
eth0.2  -> Ethernet1/0/1, PVID 1648, VLAN 1648
```

交换机 MAC：`58:ae:a8:88:0c:31`。端口数据 VLAN 正常，不是 guest VLAN 配错。

### 2.2 H3C 在 EAP-Success 后约 30 秒才放行数据 VLAN

一次恢复过程的抓包（eth1）：

```text
13:17:41.059  switch -> client  EAP-Success (id 139)
13:18:12.957  client -> switch  DHCP Discover
13:18:12.976  switch -> client  DHCP Offer 10.64.3.199
13:18:13.021  switch -> client  DHCP ACK
```

EAP-Success 到 DHCP Offer 之间约 **31.9 秒**。这 30 秒内 DHCP Discover 一直在发，
但交换机不转发。旧版脚本的“30 秒无 IP 就 Logoff + 2 秒 bounce”正好卡在这个窗口：
它在端口即将放行时把会话踢掉，然后重复，形成永久循环。

### 2.3 重复 EAPOL-Start 会制造重复会话

旧版 `send_start()` 同时发两帧：

```text
unicast -> 58:ae:a8:88:0c:31
multicast -> 01:80:c2:00:00:03
```

抓包显示 H3C 立刻回了 **两个 EAP-Request/Identity**：

```text
13:19:57.220  Request/Identity id 129
13:19:57.220  Request/Identity id 126
13:19:57.224  Request/Type 7 (PAP) id 127
13:19:57.315  Success id 127
```

同一时刻两个 Identity 请求意味着交换机为同一客户端建立了两个认证上下文。
之后交换机会在心跳/清理阶段用 `EAP-Failure` 拆掉其中一个，端口随之短暂或永久失效。
改成 **每轮只发一个 Start** 后，抓包只剩一个 Identity 请求，连续 4 个 15 秒心跳
都是 `Request -> Response -> Success`，没有再出现 Failure。

### 2.4 重启/重启服务会留下旧会话

旧版在 `SIGTERM` 时发送 `EAPOL-Logoff`，但 procd 马上拉起新进程；Logoff 与
新 Start 竞争。新版如果完全不发 Logoff，快速重启又会留下旧会话，新认证在
25 秒左右被旧会话的清理动作打断。最终采用：

```text
新进程第一次认证前：
  EAPOL-Logoff（清旧会话）
  -> 等 3 秒
  -> 只发一个单播 EAPOL-Start
```

这不是旧版“每次恢复都 Logoff”，而是**每个进程生命周期只清一次**。

### 2.5 开机 MAC 竞态

开机瞬间 `eth1` 还是随机 MAC（例如 `1e:8a:6c:94:2c:1d`），netifd 稍后才套用
`00:78:32:26:60:5e`。旧版 `set_mac()` 会主动 `ip link set down/up`，与 netifd
抢链路；如果认证发生在 MAC 切换之前，EAP 会话会绑定到错误 MAC，随后 DHCP
用配置 MAC，交换机直接丢弃。

新版**绝不修改 MAC**，只做两件事：

1. 认证前等待 `/sys/class/net/<ifname>/address` 等于配置的 `mac`；
2. 每次发帧都重新读取当前 MAC，避免缓存过期。

MAC 不一致时会一直等待，并按 `mac_settle_timeout`（默认 30 秒）周期告警；**绝不降级使用随机 MAC**。

### 2.6 MAC 必须固定成账号绑定的物理 MAC

这台 H3C NX30PRO 的 MTK 驱动**没有可用的永久 MAC**：

```text
ethtool -P eth1  -> Permanent address: 00:00:00:00:00:00
dmesg            -> generated random MAC address 1e:8a:6c:94:2c:1d
```

开机时 eth1 先带随机 MAC，netifd 运行后才套用
`00:78:32:26:60:5e`；eth0.2 套用 `00:78:32:26:60:5c`。WiFi `ra0` 是
`00:78:32:26:60:60`，说明 `...5c/5e/5f/60` 是这台机器的**出厂 MAC 段**，
当前配置用的就是物理标签 MAC，不需要改成别的值。

但 802.1X、DHCP、ARP 必须**全程使用同一个 MAC**。如果守护进程在 netifd
套用 MAC 之前就用随机 MAC 回了交换机心跳，交换机会把会话/端口安全绑定到
随机 MAC；之后内核换成配置 MAC，DHCP 广播还能通，但网关 ARP 单播会被丢弃。
新版做了三层防护：

1. `mac_ready()`：配置 MAC 未生效前不开始认证；
2. `send_frame()`：当前 MAC != 配置 MAC 时**拒绝发送任何 EAPOL**（包括 Logoff）；
3. `pump_frames()`：MAC 未生效时**忽略交换机心跳**，不回应。

因此，若账号是 MAC 绑定的，必须把 `network.wan.macaddr`、
`network.wan_eth1_dev.macaddr`、`sufe_auth.wan.mac` 三处都设成**同一个物理
标签 MAC**；当前配置已满足。

---

## 3. 旧版的结构性问题

| 问题 | 后果 |
| :--- | :--- |
| `trigger_dhcp()` 曾调用 `ifup` | netifd 重套 MAC、link down/up，打断刚建立的 802.1X 会话 |
| 30 秒无 IP 就恢复 | 与 H3C 约 30 秒的数据 VLAN 放行延迟正面冲突 |
| 恢复先发 Logoff，物理口只 down 2 秒 | 端口还没清干净就重新认证；VLAN 口甚至完全不 reset |
| 每 5 分钟固定冷却 | 一次恢复失败要等 5 分钟，期间一直断网 |
| 重启时发 Logoff | 正常工作会话被主动 deauth；快速重启留下半旧会话 |
| 双 Start（单播+组播） | H3C 建立两个会话，后续 EAP-Failure |
| `monitor_loop` 忽略 EAP-Failure | 交换机已经踢掉会话，脚本还以为在线 |
| 恢复中重新认证失败后不检查返回值 | `is_authenticated=False` 后永久停在监控循环，不再重试 |
| `ping -I eth1` 在无 IP 时执行 | BusyBox 会用 LAN 地址 ARP `223.5.5.5`，检测结果无意义 |
| `ip route show default dev eth1` | 看不到 mwan3 的策略路由表，网关检测经常返回 None |
| 密码通过 `-p` 传给 procd | `ps w` 可直接看到密码 |
| 没有 per-interface 锁 | 手动调试 + procd 可能同时跑两个实例 |
| 每 10 秒打印一次无 IP | syslog 被刷屏，真正有用的状态转换被淹没 |

---

## 4. 新版设计

### 4.1 状态机

```text
init
  -> wait_link        等 carrier + 配置 MAC
  -> auth             发 Start，等 EAP-Request
  -> wait_dhcp        EAP-Success 后等 DHCP，最多 90 秒
  -> online           IP + 网关检查
  -> recover          物理口 15 秒 link reset；VLAN 口 Logoff + settle
  -> backoff          认证/恢复失败后的指数退避
```

关键点：

- 所有等待都是 `select` + 单调时钟，没有嵌套 `sleep`/递归调用。
- 每一轮认证只发 **一个** EAPOL-Start。
- 每轮只发一个**单播** EAPOL-Start 到交换机 MAC；学校文档明确要求“单播报文”。只有没有交换机 MAC 时才用 PAE 组播兜底。
- EAP-Request 统一处理 Identity / H3C PAP (Type 7) / MD5 / Notification。
- `wait_dhcp` 收到 EAP-Failure 立即重认证，不等 90 秒。
- 物理恢复：`link down 15s -> up -> 等 carrier -> 重新认证`。
- VLAN 恢复：`Logoff -> 等 10s -> 重新认证`，不碰父接口 eth0，不影响 LAN/WiFi。
- 恢复退避：30s / 60s / 120s / 240s / 300s，稳定在线 10 分钟后重置。
- 默认 `logoff_on_stop=0`：procd 重启/停止不再主动 deauth；下次启动用一次
  startup Logoff 清旧会话。
- DHCP 只通过 `SIGUSR1` 通知 udhcpc，绝不 `ifup`。
- 网关检查只在有真实 IPv4 源地址时执行，并从 netifd status 读取网关。
- 每接口 `flock`，防止重复实例。
- 凭据只从 UCI 读取，procd 命令行只有 `-n <section>`。
- 运行状态写到 `/var/run/sufe_auth.<ifname>.json`，可用
  `sufe_auth --status -n wan` 查看。

### 4.2 默认时间参数

| 参数 | 默认 | 说明 |
| :--- | ---: | :--- |
| `dhcp_grace` | 90s | EAP-Success 后等 DHCP；必须大于 H3C 的 ~30s 放行延迟 |
| `auth_timeout` | 6s | 单次 Start 等响应 |
| `auth_attempts` | 5 | 一轮最多 Start 次数 |
| `recovery_settle` | 10s | Logoff 后等待 |
| `recovery_link_down` | 15s | 物理口 link down 时长（实测 15s 可靠） |
| `recovery_link_up_wait` | 25s | 等 carrier |
| `recovery_backoff_max` | 300s | 最大恢复间隔 |
| `mac_settle_timeout` | 30s | MAC 不一致时的告警间隔（一直等待，不降级） |
| `startup_logoff` | 1 | 每个进程第一次认证前清旧会话 |
| `startup_logoff_wait` | 3s | Logoff 后等待 |
| `logoff_on_stop` | 0 | 停止/重启时不主动 deauth |
| `vlan_logoff_on_recovery` | 1 | VLAN 口恢复用 Logoff |

所有参数都可以在 `/etc/config/sufe_auth` 的 `config account` 里覆盖。

---

## 5. 验证结果

### 5.1 冷启动

```text
13:28:31  eth1/eth0.2  startup Logoff
13:28:34  eth1/eth0.2  single multicast Start
13:28:34  eth1         EAP-Success
13:28:35  eth1         DHCP 10.64.3.171
13:29:10  eth0.2       EAP-Success (第二次 Start，第一次交换机未响应)
13:29:10  eth0.2       DHCP 10.64.7.223
```

两条 WAN 均 online，`mwan3` 状态 online，Table 50 双 nexthop，
路由器 `wget http://www.baidu.com/` 返回 0。

### 5.2 心跳

单 Start 版本连续抓包：

```text
13:22:57  Start (单播) -> Identity -> PAP -> Success
13:23:11  Request -> Response -> Success
13:23:26  Request -> Response -> Success
13:23:41  Request -> Response -> Success
13:23:56  Request -> Response -> Success
```

没有重复 Identity，没有 EAP-Failure。

### 5.3 恢复

- eth1 手动 `down 15s -> up` 后重新认证并拿回 IP；
- VLAN 口走 Logoff + settle + 重新认证，不触碰 eth0；
- 恢复完成后 DHCP 1~2 秒内拿到租约。

---

## 6. 代码与测试

- `root/usr/sbin/sufe_auth`：单文件 Python 3 守护进程，约 1000 行。
- `root/etc/init.d/sufe_auth`：procd 只传 `-n <section>`，密码不再进 `ps`。
- `tests/test_sufe_auth.py`：22 个单元测试，覆盖：
  - EAPOL/EAP 编解码、VLAN tag、MD5/PAP；
  - 配置解析、MAC 校验、布尔/浮点边界；
  - 物理/VLAN 恢复序列（确保物理口不 Logoff、VLAN 口不 reset link）；
  - startup MAC gate、恢复退避上限。

运行：

```bash
python3 -m unittest discover -s tests -v
python3 -m py_compile root/usr/sbin/sufe_auth
```

---

## 7. 回滚

路由器上保留了部署前备份：

```text
/root/sufe_auth.bak.20261019_131212
/root/sufe_auth.init.bak.20261019_131212
/root/sufe_auth.config.bak.20261019_131212
```

回滚：

```bash
cp /root/sufe_auth.bak.20261019_131212 /usr/sbin/sufe_auth
cp /root/sufe_auth.init.bak.20261019_131212 /etc/init.d/sufe_auth
chmod +x /usr/sbin/sufe_auth /etc/init.d/sufe_auth
/etc/init.d/sufe_auth restart
```

回滚版会恢复旧的 Logoff/2 秒 bounce 行为，不建议长期使用。

---

## 8. 仍然存在的边界

- 交换机侧如果做**周期性强制重认证**，偶发 EAP-Failure 仍可能出现；新版会在
  3 秒内重新认证并保留 DHCP，不会永久断网。
- 如果校园网 DHCP/BRAS 本身故障，任何客户端脚本都无法变出 IP；此时状态机会
  按 30/60/120/240/300 秒退避，不会把端口踢成循环。
- VLAN 口（eth0.2/eth0.3）无法在不影响 LAN 的前提下做物理 link reset；恢复
  依赖 Logoff + 重新认证。实测该方式可以恢复；若某次交换机完全无响应，重启
  路由器或拔插对应网线仍是最直接的手段。

---

## 9. 2026-10-19 13:40 追加：网关 ARP 不可达（非认证问题）

在认证状态机修复、两条 WAN 都能拿到 DHCP 租约后，仍然出现：

```text
eth1   10.64.0.16/21      DHCP OK, EAP OK
eth0.2 10.64.7.223/21     DHCP OK, EAP OK
ping 10.64.0.1            100% packet loss
ip neigh                  10.64.0.1 FAILED / INCOMPLETE
```

验证：

- 手动 `eth1 down 60s -> up`，重新认证并拿到新租约，网关仍然不可达；
- 用 raw ARP 分别以**配置 MAC**和**开机随机 MAC**、以及新/旧多个源 IP
  向 `10.64.0.1` 发 ARP 请求，**一个回复都没有**；
- 但 DHCP Discover/Offer/ACK 正常，说明二层和 DHCP 中继是通的；
- Mac 的校园 WiFi（网关 `10.64.64.1`）正常上网，但同样 ping 不通
  `10.64.0.1`。

结论：这不是 `sufe_auth` 的认证问题，而是**有线校园网的网关/端口 ACL/
portal 认证/上游故障**。EAP-Success 只代表 RADIUS 认证通过，不代表交换机
一定把端口放进可访问网关的数据 VLAN。建议：

1. 用另一台笔记本直接插同一墙面端口，看能否 ping 通 `10.64.0.1`；
2. 确认有线网是否需要额外的 **portal/客户端登录**（802.1X 之外的认证）；
3. 联系校园网管理员检查该端口的 802.1X 授权 VLAN、端口安全 sticky MAC、
   DHCP snooping/ARP 防护绑定；
4. 若管理员确认端口绑定的是另一个 MAC，把上述三处 MAC 统一改成标签 MAC
   或管理员指定的 MAC。

在网关恢复之前，`sufe_auth` 会保持 EAP 在线并保留租约；它无法替代校园网
网关/portal。

---

## 10. 2026-10-19 13:47 追加：回查 Antigravity 开发历史后发现的关键遗漏

回查 `ai_migration_export/conversations_markdown/02_OpenWrt_校园网认证配置.md`，
原始逆向记录里有两条硬要求：

1. 学校有线网要求 **“报文类型为单播报文”**；
2. 学校存在 **MAC 地址绑定机制**，必须使用当初认证/注册的 MAC。

本次重构为了避免“单播+组播双 Start 建立两个会话”，把首次 Start 改成了
**组播优先**，这与原始记录冲突。组播 Start 可能让交换机产生一个能过
EAP-Success、但数据 VLAN 未正确授权的半成品会话，表现就是 DHCP 正常、
网关 ARP 不通。已在 2.0 中修正为：

```text
每轮只发一个 EAPOL-Start
  -> 有 switch_mac：单播到 58:ae:a8:88:0c:31
  -> 无 switch_mac：才用 01:80:c2:00:00:03 组播兜底
```

同时确认原始记录中的 Type 7 PAP 负载格式就是：

```text
len(password) + password + username
```

当前实现与之一致；EAP-MD5 兜底、EAPOL v1、交换机 MAC
`58:ae:a8:88:0c:31` 也都一致，没有遗漏其他 802.1X 步骤。

原始记录还确认了当初抓包成功的物理 WAN MAC 是 `00:78:32:26:60:5e`，
与当前 `network.wan.macaddr`、`network.wan_eth1_dev.macaddr`、
`sufe_auth.wan.mac` 一致。**如果学校系统登记的是另一台设备的 MAC，必须把
这三处统一改成那个已登记 MAC；否则 EAP 可能过，但端口数据面仍会被 MAC
绑定/端口安全丢弃。**

当前剩余的数据面问题（EAP/DHCP 正常、`10.64.0.1` ARP 不通）仍按第 9 节
处理：优先用另一台设备直插同一墙面端口对比，并联系管理员检查端口
802.1X 授权 VLAN、MAC 绑定、port-security sticky MAC 和 DHCP snooping。

### 9.1 后续 A/B 对照（2026-10-19 13:56）

在用户确认 WAN1 绑定 MAC 就是 `00:78:32:26:60:5e` 后，继续做了四组对照：

1. 关闭 `startup_logoff`，重启 + 15 秒 link reset：网关仍不可达；
2. EAP-Success 后手动 `ifup wan`（旧版无 IP 时的动作）：仍不可达；
3. 恢复旧版“单播+组播双 Start”：eth1 反而拿不到 DHCP，更差；
4. 停止认证 90 秒让交换机会话老化，再干净启动：eth1/eth0.2 都拿到新 IP，
   EAP 正常，但 `10.64.0.1` 仍然 ARP 不通。

因此可以排除“少发某个 EAPOL 报文”“少一次 ifup”“少一次 Logoff”这些
认证侧原因。当前失败点在交换机端口数据面/上游网关，而不是 `sufe_auth`。
MAC 本身是正确的，不需要改成别的值。

---

## 11. 2026-10-19 19:12 现场恢复：物理拔插 60 秒

用户对 WAN 网线做了一次物理拔插 60 秒后，交换机端口状态被清除，网络立即恢复：

```text
eth1   10.64.4.95/21    gateway 10.64.0.1 0% loss, curl baidu 200
eth0.2 10.64.7.223/21   gateway 10.64.0.1 0% loss, curl baidu 200
Table 50: nexthop eth1 + eth0.2
```

这进一步确认：

- `sufe_auth` 的 EAP/DHCP 没有问题；
- 之前 `ip link set down/up` 无法清除 H3C 端口的 port-security/err-disable 状态，
  物理拔插（或管理员 `shutdown/no shutdown`）才可以；
- 旧版在端口被卡住时同样失败，不是重构代码引入的故障。

恢复后 `mwan3` 的 WAN2 tracker 状态文件仍停留在 `offline`（物理拔插后
mwan3 没有收到 ifup 事件），手动把 `iface_state/wan2` 置为 `online` 并执行
`/etc/mwan3.user` 后，Table 50 恢复双线，两条线分别 `curl` 均返回 200。
若以后再次出现“单线能上网但 Table 50 只有一条”，优先检查
`/var/run/mwan3/iface_state/wan2` 和 `mwan3track`，而不是先怀疑 802.1X。
