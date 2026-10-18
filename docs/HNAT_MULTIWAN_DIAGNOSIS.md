# 多 WAN 下部分图片/网页无法加载：诊断与修复报告

- 日期：2026-10-18
- 环境：ImmortalWrt 18.06 / Linux 5.4.224 / MediaTek MT7981（MT798x HNAT/WARP）
- 拓扑：`wan(eth1)` + `wan2(eth0.2)` 双线 802.1X，均从校园网获得 `10.64.0.0/21` 地址，网关同为 `10.64.0.1`
- 负载均衡：mwan3 + 内核 FIB Multipath（Table 50，L3 `src+dst` 哈希，`fib_multipath_hash_policy=0`）
- 管理网段：`192.168.6.0/24`，路由器 `192.168.6.1`

---

## 1. 现象

用户反馈使用路由器上网时：

- 部分图片/网页**一直空白**，多次刷新仍不显示；
- 部分图片/网页**等待一段时间后又能加载**；
- 路由器本机测速、下载、`curl` 大多正常；
- 局域网多台设备（Mac / Windows / iPhone / iPad 等）均有类似现象。

这与“单条 WAN 故障”或“DNS 解析失败”的表象不同，更像是**转发路径上的连接被中途卡死**。

---

## 2. 分层诊断过程

### 2.1 物理层 / 链路层

- `eth1` 协商 100Mb/s full-duplex；`eth0.2` 所在交换口 100baseT full-duplex。
- 交换口 MIB：`RxCRC=0`、`RxDrop=0`、`TxDrop=0`；`eth0` FCS/overflow 均为 0。
- WiFi 5G（`rai0`）无异常；2.4G（`ra0`）累计 RX errors 约 2M（环境干扰，后续可优化，但不是本次 20KB 卡死的主因）。

### 2.2 802.1X / DHCP

- 两个 `sufe_auth` 进程持续心跳，无认证失败/掉线。
- `wan`、`wan2` 均 online，IP 分别为 `10.64.5.110`、`10.64.1.56`，默认网关 `10.64.0.1`。
- `wan3(eth0.3)` 无链路，mwan3 标记 offline（不影响本次问题）。

### 2.3 DNS

- dnsmasq `all-servers` + `filter-aaaa`，上游 `223.5.5.5` / `119.29.29.29`。
- 连续 100 次 DNS 查询无失败；`i0.hdslb.com`、`wx.qlogo.cn`、`sns-webpic-qc.xhscdn.com` 等返回的每个 IP 在两条 WAN 上均可完成 TLS 握手。
- 因此 DNS/IP 可达性不是本次“20KB 卡死”的直接原因。

### 2.4 MTU / PMTU

- WAN MTU 1500；对 `223.5.5.5`、`119.29.29.29`、Akamai/Bing/Tencent CDN IP 做 1472 字节大包 ping，双 WAN 均通过。
- TCP MSS clamp 规则存在且计数正常。
- 排除典型 PMTU 黑洞。

### 2.5 逐 WAN 与应用层

- 对 `img-s-msn-com.akamaized.net`、`i0.hdslb.com`、`th.bing.com`、`wx.qlogo.cn`、`mmbiz.qpic.cn`、`sns-webpic-qc.xhscdn.com` 的所有当前 DNS IP，逐条 WAN 做 TLS/HTTP 请求，全部成功。
- 真实 MSN 图片 URL 双 WAN 均返回 200，文件完整（612×328，65536 字节）。
- 说明单条 WAN 的“可达性”本身没有问题。

### 2.6 NAT / 路由一致性

- 用 conntrack 逐条比对“实际源 IP + 目的 IP 的 Table 50 路由”和“reply tuple 的 SNAT 地址”，`mark=0x300` 的转发流**0 条不匹配**。
- 曾怀疑 fullcone NAT 导致跨 WAN SNAT；A/B 关闭 fullcone 后，WAN2 目的地址仍正确 SNAT 到 `10.64.1.56`，**fullcone 不是根因**，已恢复原状。
- 关键点：Table 50 的哈希包含源 IP，不能用“仅按目的 IP 的 `ip route get`”判断某客户端会走哪条 WAN。

### 2.7 硬件加速（根因所在）

平台加载了：

```
mtkhnat       102400  2  mt_wifi,mtk_warp
mtk_warp      368640  1  mtk_warp_proxy
mtk_warp_proxy 16384  0
```

- `/sys/kernel/debug/hnat/whnat_interface` 明确列出 `ra0`、`rai0`，即 **WiFi 流量也在走 HNAT/WARP 硬件卸载**。
- `/sys/kernel/debug/hnat/hnat_entry` 中存在活动 NAPT 流，其中一条明显异常/跨 WAN：

```
NAPT(11464): 219.235.64.7:4483->10.64.1.56:60398 => 112.15.33.33:443->192.168.6.195:56718
```

- TurboACC 配置 `hw_flow=1`，其 init 脚本会**强制** `hw_flow=1`（只要 `mtkhnat.ko` 存在），因此即使防火墙 UCI 里 `flow_offloading_hw=0`，HNAT 仍可能被重新打开。
- HNAT 绕过 netfilter/mwan3 直接缓存 NAPT；在多 WAN、同网段、策略路由场景下，缓存的出口/窗口状态可能与内核路由不一致，导致 TCP 流在固定窗口处停住。

---

## 3. 可复现的对照实验

在路由器上临时重新打开 HNAT（`echo 1 > /sys/kernel/debug/hnat/hook_toggle`），用 Mac 连续请求 `https://www.msn.cn/zh-cn`，每次超时 8 秒：

| 轮次 | HNAT | 请求数 | 失败数 | 失败特征 |
| :--- | :--- | ---: | ---: | :--- |
| 1 | ON | 20 | 1 | 停在 `20480 / 47583` 字节，8s 超时 |
| 2 | ON | 20 | 1 | 停在 `20480 / 44100` 字节，8s 超时 |
| 3 | ON | 20 | 1 | 停在 `20480 / 47547` 字节，8s 超时 |
| 关 HNAT 后 | OFF | 100 | 0 | — |
| 关 HNAT 后并发 | OFF | 60（20 并发） | 0 | 全部 200 |

失败**稳定停在 20480 字节（5×4096）**，是典型的硬件 NAT/窗口状态卡死，而不是随机丢包或 DNS 失败。

关闭 HNAT 后：

- `grep -c NAPT /sys/kernel/debug/hnat/hnat_entry` = `0`；
- 双线并行下载（清华 WAN2 + 中科大 WAN1）合计 **20.89 MiB/s（约 175 Mbps）**，聚合未被破坏；
- 下载时 CPU `sirq` 约 23%，仍有充足余量。

---

## 4. 根因结论

**MTK HNAT/WARP 硬件 NAT 卸载与 mwan3 + FIB Multipath 多 WAN 策略路由不兼容。**

HNAT 在 WiFi 路径上缓存 NAPT 流，部分 TCP 流在 20KB 窗口处被卡死；表现为部分图片/网页永久空白，部分连接超时重试后换一条路径又能加载。路由器本机流量与部分未命中 HNAT 的流不受影响，因此“路由器 curl 正常、局域网设备异常”。

---

## 5. 已实施的修复

### 5.1 路由器运行态

1. 关闭 HNAT hook：
   ```bash
   echo 0 > /sys/kernel/debug/hnat/hook_toggle
   ```
2. 禁用 TurboACC 自启（避免开机强制 `hw_flow=1`）并保持防火墙 offload 关闭：
   ```bash
   /etc/init.d/turboacc disable
   uci set turboacc.config.hw_flow='0'
   uci set turboacc.config.sw_flow='0'
   uci commit turboacc
   uci set firewall.@defaults[0].flow_offloading='0'
   uci set firewall.@defaults[0].flow_offloading_hw='0'
   uci commit firewall
   ```
3. 保留 BBR（TurboACC 不再负责）：
   ```bash
   sysctl -w net.ipv4.tcp_congestion_control=bbr
   ```
4. 新增“精简模式”开机脚本（默认，零常驻）：
   - `/etc/init.d/hnat-off`：`START=99`，开机后写 0 并退出；`enable` 后生成 `S99hnat-off`。
   - `/etc/hotplug.d/iface/99-hnat-off`：WAN/WiFi 接口 `ifup` 时再写 0，覆盖网络重载/重启场景。
   - 可选 `install-watchdog`：额外安装常驻巡检（约 1 MB 内存、0% CPU、每 10 秒检查一次），用于防止手动重开 TurboACC 后无人值守。
5. 备份：
   - `/root/firewall.bak.20261018_160306`
   - `/root/firewall.bak2.20261018_160611`
   - `/root/rc.local.bak.20261018_160611`
   - `/root/sysctl.conf.bak.20261018_160611`
   - `/root/turboacc.bak.20261018_160611`
   - `/root/turboacc.symlink.20261018_160611`

### 5.2 项目内可复现脚本

- `tools/fix_hnat_offload.sh`：`install`（精简、零常驻）/ `install-watchdog`（可选巡检）/ `status` / `rollback`。
- `tools/configure_mwan3.sh`：在配置完 mwan3 后自动调用上述脚本。
- `README.md`：新增“多 WAN 稳定性必读”章节。
- 本报告：`docs/HNAT_MULTIWAN_DIAGNOSIS.md`。

### 5.3 回滚

路由器本地已放置：

```bash
/root/rollback_hnat_off.sh
```

或：

```bash
sh tools/fix_hnat_offload.sh rollback
```

回滚会恢复 HNAT hook、`flow_offloading_hw=1` 和 TurboACC 自启。**回滚会重新引入 20KB 卡死风险。**

---

## 6. 验收标准

```bash
# 1) HNAT 不再缓存任何流
grep -c NAPT /sys/kernel/debug/hnat/hnat_entry      # 期望 0

# 2) 开机脚本已启用，且精简模式没有常驻进程
ls -l /etc/rc.d/S99hnat-off                    # 应为软链接
ps w | grep '[h]nat-off' || echo "no daemon"   # 精简模式应为 no daemon
sh tools/fix_hnat_offload.sh status            # one-shot mode / ifup hook installed

# 3) offload 关闭
uci get firewall.@defaults[0].flow_offloading        # 0
uci get firewall.@defaults[0].flow_offloading_hw     # 0
/etc/init.d/turboacc enabled; echo $?                # 非 0（disabled）

# 4) 路由/聚合未受影响
ip route show table 50
mwan3 status
```

实测：100/100 页面请求成功，60/60 并发请求成功，双线聚合 20.89 MiB/s。

---

## 7. 后续建议

1. **先清浏览器失败缓存**：Edge/Chrome 按 `Cmd+Shift+R` 强制刷新，或清除“缓存的图片和文件”。此前的失败资源可能被浏览器缓存，修复网络后仍显示空白。
2. **不要重新开启 TurboACC 的“硬件加速/FullCone”开关**；默认精简模式只在开机和网口 `ifup` 时关闭 HNAT，手动重开需要重新执行 `install` 或重启。若希望自动兜底，可执行 `install-watchdog`（每 10 秒检查一次）。
3. 若仍偶发失败，下一层排查顺序：
   - QUIC（当前 `Reject-QUIC-UDP443` 仍在，属于已知折衷）；
   - dnsmasq `all-servers` 导致 CDN IP 抖动；
   - 2.4G WiFi 干扰（`ra0` 累计 RX errors 约 2M）；
   - 校园网上游 QoS / 国际出口（GitHub、Google 等本身不可达，不属于路由器问题）。
4. 该修复不影响 `wan3` 的后续接入；`wan3` 上线后 Table 50 会自动增加 nexthop。
5. 重启路由器后，`S99hnat-off` 会自动关闭 HNAT；WAN/WiFi `ifup` 事件也会再次写 0。若手动重开 TurboACC，需重新执行脚本或使用可选的 `install-watchdog` 模式。

---

## 8. 最小侵入性说明

- 未修改 `/etc/config/network`、VLAN、WAN 口、防火墙转发策略、mwan3 表 50、fullcone、DNS 或 QUIC 规则；
- 仅关闭 HNAT/TurboACC 硬件 offload，并保留 BBR；
- 所有改动可一键回滚，且备份文件在 `/root/`；
- LAN 管理口 `br-lan` / `192.168.6.1` 全程未触碰，修改期间 SSH 未中断。
