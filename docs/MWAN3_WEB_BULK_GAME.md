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

**网页当前固定 WAN1**。真实 LAN 客户端 `.198` 粘 WAN2 时：

- 百度 HTTPS 小页面 200；
- WeGame 22KB 页面在 12~15KB 后超时；
- 104KB 图片 0 字节超时；
- 同一客户端改粘 WAN1 后，上述三项全部 200，104KB 图片完整返回。

因此 WAN2 的 **forwarded/NAT 大 TLS 响应**确实有问题，WAN2 暂不承载网页；
WAN2 仍保留给 Table 50 下载和非 80/443 流量。游戏 UDP 本身仍由
`game_udp` / `game_high_udp` 固定 WAN1。

注意：路由器本机源 `.1/.250` 的 OUTPUT 测试也会制造假象（本机 mark 后不一定
重新选路），不能单独作为 WAN2 结论；上面的结论来自真实 LAN 转发客户端。

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

## 10. Mac/手机网页卡死排查（2026-10-19）

真实 LAN 客户端测试：

```text
.198 -> WAN2:
  HTTP 百度 200
  HTTPS 百度 200
  WeGame 22KB: 12~15KB 后超时
  104KB 图片: 0 字节超时

.198 -> WAN1:
  HTTP/HTTPS 百度 200
  WeGame 22KB: 22,541 字节 200
  104KB 图片: 104,749 字节 200
```

因此 WAN2 的 forwarded/NAT 大 TLS 路径有问题，WAN1 正常。已把网页固定到
WAN1；WAN2 仍用于 Table 50 下载。

另一个路由器侧问题是 `game_active` 误判：Mac 的普通 UDP（AirPlay/游戏启动器）
被游戏端口规则收录，随后浏览器的新连接全部命中 `WEB_BULK_CHECK` 的
game-active 分支，被强制 mark `0x200` 到 WAN2。日志中 1799 个 bulk 新连接
全部命中该分支。现已：

- 停用 `game_active` 自动切 WAN2；
- 清空 `game_active`；
- 游戏 UDP 仍固定 WAN1；
- 网页固定 WAN1。

手机 `.137` 不在 `game_active` 中，且 WAN1 网关/公网 0% 丢包、路由器 CPU
空闲；如果手机图片仍失败，需要继续从具体失败 URL/CDN 的 conntrack/PCAP 查，
而不是继续改 WAN 策略。

---

## 11. WAN2 forwarded/NAT 大包修复（路由器侧）

WAN2 物理链路正常，但 LAN→WAN2 的 forwarded/NAT 大 TLS 会卡。当前处理：

1. **清理 table 2 的跨线路由**
   `10.64.0.0/21 dev eth1` 不应出现在 WAN2 的 table 2；只保留 eth0.2 的连通路由。
2. **默认路由明确源地址**
   ```text
   default via 10.64.0.1 dev eth0.2 src 10.64.1.48 metric 20 table 2
   ```
3. **绕过 fullcone MASQUERADE**
   WAN2 使用显式 SNAT：
   ```text
   iptables -t nat -A MWAN3_WAN2_SNAT \
       -s 192.168.6.0/24 -o eth0.2 \
       -j SNAT --to-source 10.64.1.48
   ```
   SNAT 链在 POSTROUTING 最前面；WAN2 不再走 `MASQUERADE --mode fullcone`。

路由器侧验证：临时源 `.250` 走 table 2 + SNAT，104KB 图片返回
`104749` 字节；修复前同一路径会超时。网页仍固定 WAN1。

持久化在 `/etc/mwan3.user` 的 `sync_wan2_nat_path()`，由 ifup/hotplug 重建。
回滚备份：

```text
/root/nat.pre_wan2fix.*
/root/table2.pre_wan2fix.*
```

---

## 12. 下载不聚合的根因：mwan3_connected 覆盖回程 mark

夸克下载在 `.198` 上建立 172 条到同一 CDN IP 的连接，但 conntrack 最终
mark 全是 `0x3f00`，不是 bulk 的 `0x300`，所以只走主路由表单条 WAN。

根因在 `/etc/mwan3.user`/mwan3 生成的 `mwan3_hook` 最后一条：

```text
-A mwan3_hook -m mark ! --mark 0x3f00/0x3f00 -j mwan3_connected
```

`mwan3_connected_v4` 包含 `192.168.6.0/24`。WAN 回程到 LAN 的包命中该规则，
被标成 `0x3f00`，随后 `CONNMARK --save-mark` 覆盖了原来的 web/bulk mark。
之后所有包都从主表走，Table 50 聚合失效。

修复：删除这条最终规则，保留前面的 `mwan3_connected`（新建连接仍能识别直连）。
持久化函数 `sync_mwan3_connected_fix()` 会在 ifup/hotplug 后重新删除它。

旧连接仍带 `0x3f00`；需要取消/重新建立下载任务，让新连接重新分类。
