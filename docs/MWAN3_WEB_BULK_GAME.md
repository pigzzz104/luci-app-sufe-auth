# mwan3 三类流量：网页单线、下载聚合、游戏保护

本文记录在现有 FIB Multipath / Table 50 架构上增加的固定三类流量策略。
它不按域名、端口列表或逐设备写规则，只识别三种行为。

---

## 1. 三类流量

| 类别 | 识别 | 出口 |
| :--- | :--- | :--- |
| 网页 | LAN 源 TCP 80/443，低并发 | mwan3 `web_sticky`：每个源 IP 粘死一条 WAN |
| 下载 | 同一源 TCP 80/443 总并发 >10，且同一目标 >8 | mark `0x300` → Table 50 FIB Hash |
| 游戏 | UDP 3074 / 5000-5500 / 7000-9000 / 27000-27100 | 现有 `game_udp` / `game_high_udp` → WAN1 |
| 游戏中的下载 | 最近 120 秒出现过游戏 UDP 的源 IP | 新下载 mark `0x200` → WAN2 |
| 其他 | 非上述 | Table 50 / FIB Hash |

标记：

```text
0x100  WAN1
0x200  WAN2
0x300  Table 50 / FIB multipath
0x3f00 mwan3 connected / bypass
mask   0x3f00
```

---

## 2. 网页 sticky

`/etc/config/mwan3`：

```uci
config policy 'web_affinity'
    list use_member 'wan_m1_w1'

config rule 'web_sticky'
    option src_ip '192.168.6.0/24'
    option proto 'tcp'
    option dest_port '80,443'
    option sticky '1'
    option timeout '3600'
    option use_policy 'web_affinity'
```

规则必须放在 `https` 和 `default_rule` 之前。

**当前固定 WAN1**：WAN2 在 `mark 0x200` 下的大 TCP 存在缺陷（同一 104KB 图片：
table 2 不带 mark 可成功，mark 0x200 会卡在 0 字节；WAN1 正常）。因此网页统一
走 WAN1，避免浏览器/缩略图再次卡死。WAN2 仍参与 Table 50 下载聚合和非 80/443
流量；只有 WAN1 离线时才回退 WAN2。

`mwan3_sticky_v4_web_sticky` 以 `(源 IP, mark)` 记住每个客户端的选择，保证同一
客户端后续 80/443 连接不再跳 WAN。

---

## 3. 下载分类

在 mangle `PREROUTING` 中，**mwan3_hook 之后**执行 `WEB_CLASSIFY`：

```text
TCP 80/443 NEW，源 192.168.6.0/24
  ├─ 源总并发 >10 -> WEB_BULK_CHECK
  │    ├─ 源在 game_active -> mark 0x200 (WAN2)，返回
  │    └─ 同一目标 >8     -> mark 0x300 (Table 50)，返回
  └─ 否则保持 mwan3 的 web sticky 标记
```

为什么必须在 `mwan3_hook` 之后：

- `mwan3_hook` 开头有 `CONNMARK --restore-mark`，会覆盖之前打的 mark；
- 因此先让 mwan3 完成 web sticky / connected 逻辑；
- 再由 `WEB_CLASSIFY` 覆盖 bulk/game 的标记；
- 链尾执行 `CONNMARK --save-mark`，保证后续包保持新类别。

`xt_connlimit` 在这台固件上不能把 `--connlimit-saddr` 和 `--connlimit-daddr`
放在同一个 match 里；实现改为两段式：

```text
WEB_CLASSIFY:  -m connlimit --connlimit-above 10 --connlimit-saddr -j WEB_BULK_CHECK
WEB_BULK_CHECK: -m connlimit --connlimit-above 8 --connlimit-daddr -j MARK 0x300
```

---

## 4. 游戏检测

`game_active` 是 `hash:ip`，timeout 120 秒。`WEB_CLASSIFY` 最前面：

```text
LAN 源 UDP 3074 / 5000:5500 / 7000:9000 / 27000:27100
  -> ipset add game_active <src> --exist
```

游戏 UDP 本身仍由 mwan3 的 `game_udp` / `game_high_udp` 处理并固定 WAN1。
只有该源的 **新 bulk 连接** 会在 120 秒内切到 WAN2；游戏停止 120 秒后集合
自动过期，新下载自动回到 Table 50。

注意：`10000:20000` 已从 **检测** 中移除，因为它会把普通应用 UDP 误判为游戏；
mwan3 原有的 `game_high_udp` WAN1 路由仍保留。

---

## 5. 持久化

仓库文件：

```text
root/etc/mwan3.user
root/etc/hotplug.d/iface/99-mwan3-user
tools/configure_mwan3.sh
```

`/etc/firewall.user` 已包含：

```sh
/etc/mwan3.user
```

`99-mwan3-user` 在 mwan3 的 `15-mwan3` 之后运行，确保 WAN2 上线后重建 Table 50、
web 策略和分类链。

安装/重装：

```bash
sh tools/configure_mwan3.sh
# 该固件 mwan3 运行时 restart 可能死锁；脚本会写配置并提示重启
reboot
```

---

## 6. 验证命令

```bash
# web 规则必须在 https 之前
iptables -t mangle -S mwan3_rules

# web 策略应为 0x200/0x100 两条
iptables -t mangle -S mwan3_policy_web_affinity

# 每个客户端的 sticky 分配
ipset list mwan3_sticky_v4_web_sticky

# 分类链必须在 mwan3_hook 之后
iptables -t mangle -S PREROUTING
iptables -t mangle -S WEB_CLASSIFY
iptables -t mangle -S WEB_BULK_CHECK

# game_active 与 Table 50
ipset list game_active
ip route show table 50
```

本次实测：

- `.186 -> 0x100 (WAN1)`，`.198 -> 0x200 (WAN2)`，两个客户端已分散；
- 20 条同目标慢连接：`WEB_BULK_CHECK` 的 `dst >8` 命中，conntrack 出现
  `mark=0x300`；
- 手动写入 `game_active 192.168.6.1` 后，新 bulk 的 `WEB_BULK_CHECK` game 规则
  命中 `0x200`，generic 0x300 计数为 0；
- 两条 WAN 网关均 0% 丢包，百度 HTTP 200。

---

## 7. 代价与边界

- 网页固定单 WAN 后，普通网页下载不再聚合；高并发下载通过 bulk 旁路恢复。
- 阈值 10/8 是行为阈值；浏览器极端多标签可能被误判为 bulk。可按需调整。
- 现有连接不会迁移；规则只影响新连接。
- 游戏检测依赖端口列表；未列出的游戏不会触发自动切 WAN2，但游戏本身仍走 WAN1。
- 没有 CAKE/HTB/IFB/tc，无法做精确 12MB/s 限速；游戏时是路径隔离到 WAN2。
- mwan3 运行时 restart 在这台固件可能卡 hotplug 锁；配置变更后用重启加载。

---

## 8. 回滚

路由器本地只保留了本次改动前的两个小备份：

```text
/root/mwan3.pre_webclass.20261019_193205
/root/mwan3.user.pre_webclass.20261019_193205
```

需要回滚时：

```bash
cp /root/mwan3.pre_webclass.20261019_193205 /etc/config/mwan3
cp /root/mwan3.user.pre_webclass.20261019_193205 /etc/mwan3.user
chmod +x /etc/mwan3.user
reboot
```

`iptables`/`ipset` 的临时快照已清理；新规则由 `/etc/mwan3.user` 和
`/etc/hotplug.d/iface/99-mwan3-user` 在启动/ifup 时重建。

---

## 9. 历史问题站点回归（2026-10-19 19:50）

按迁移对话里实际出现过的 URL / 域名，从 WAN1、WAN2 强制源地址各测一次：

| 对象 | WAN1 | WAN2 | 说明 |
| :--- | :--- | :--- | :--- |
| LoL 英雄图 `game.gtimg.cn/.../Aatrox.png` | 200 / 17,022 B | 200 / 17,022 B | 正常 |
| LoL 皮肤图 `ossweb-img.qq.com/.../big1000.jpg` | 200 / 104,749 B | 200 / 104,749 B | 10/10 次成功 |
| WeGame 首页 `www.wegame.com.cn` | 200 / 22,541 B | 200 / 22,541 B | 正常 |
| B 站 API `api.bilibili.com/x/web-interface/popular` | 200 / 2,181 B | 200 / 2,181 B | 正常 |
| B 站旧封面 `i0.hdslb.com/...` | 404 | 404 | URL 已过期 |
| 微博旧头像 `tvax1.sinaimg.cn/...` | 403 | 403 | 防盗链/URL 过期 |
| 知乎旧图 `picx.zhimg.com/...` | 404 | 404 | URL 已过期 |
| 百度 | 200 | 200 | 对照 |

多 A 记录：

```text
www.wegame.com.cn -> 117.144.242.171 / 117.135.175.100
两个 A 都返回 302（正常跳转）；
同一测试源在 mwan3_sticky_v4_web_sticky 中只有一个 0x200 条目。
```

其他：

- `grep -c NAPT /sys/kernel/debug/hnat/hnat_entry` = 0；
- `Reject-QUIC-UDP443` 仍在；
- 游戏 UDP `36.155.166.81:8081` 的 conntrack mark=0x100（WAN1）；
- 真实 LAN 客户端 sticky：`.198 -> 0x200`，`.186/.229 -> 0x100`。

注意：路由器本机源 `.1/.250` 的大响应测试会被 **OUTPUT 没有 FORWARD 的 TCPMSS clamp** 干扰，出现“小 API 正常、大图片 1KB 后超时”。这不是 LAN 客户端结论；上表使用强制 WAN1/WAN2 源地址验证站点本身，真实 LAN 转发路径有 `FORWARD TCPMSS --clamp-mss-to-pmtu`。

游戏平台补充：

| 域名 | 结果 |
| :--- | :--- |
| `arena.5eplay.com` | 200 |
| `store.steampowered.com` | 200 |
| `battlenet.com.cn` | 403（站点/区域策略） |
| `5eplay.com` | 两 WAN 均超时（站点侧） |
| `cn.actual.battle.net` | 快速连接失败（域名/站点侧） |

---

## 10. Mac 关闭 Wi‑Fi 后经 LAN 无法上网（2026-10-19）

现象：Mac 的 `en8` 已接路由器 LAN，但关闭 Wi‑Fi 后无法上网。

根因不是路由器 LAN/NAT 全局故障，而是：

- Mac `192.168.6.198` 被 web sticky 分到了 **WAN2**；
- WAN2 在 **mark 0x200** 下的大 TCP 会卡住：
  - 同一张 104KB 图片，WAN1 返回 104749 字节；
  - WAN2 + mark 0x200 返回 HTTP 200 头后 0 字节超时；
  - 同一 WAN2 改用干净 table（不带 mark 0x200）可完整返回 104749 字节；
  - 因此不是 WAN2 物理链路，而是 mwan3 的 WAN2 marked path。
- 把 `.198` 固定到 WAN1 后，自动关闭 Wi‑Fi 的实测：

```text
默认路由: 192.168.6.1 dev en8
ping 192.168.6.1: 0% loss
ping 223.5.5.5:   0% loss
nslookup 192.168.6.1: 正常
curl http://www.baidu.com/: HTTP 200
```

修复：

- web policy 改为 **WAN1-only**；
- WAN2 保留给 Table 50 下载/聚合和非 80/443 流量；
- 只有 WAN1 离线时才回退 WAN2。

这也意味着所有网页客户端共用 WAN1；优先保证页面/缩略图稳定，不再让客户端随机落到有 marked-TCP 缺陷的 WAN2。
