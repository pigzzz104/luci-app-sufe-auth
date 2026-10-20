# mwan3 三类流量：网页单线、下载聚合、游戏保护

本文记录在现有 FIB Multipath / Table 50 架构上增加的固定三类流量策略。
它不按域名、端口列表或逐设备写规则，只识别三种行为。

---

## 1. 三类流量

| 类别 | 识别 | 出口 |
| :--- | :--- | :--- |
| 网页/会话 | LAN 源**所有 TCP**（80/443 + 2099/5222-5223/8393-8400 等） | mwan3 `web_sticky`：每个源 IP 粘死一条 WAN |
| 下载 | 同一源 TCP 80/443 总并发 >10，且同一目标 >8 | mark `0x300` → Table 50 FIB Hash |
| 游戏 | UDP 3074 / 5000-5500 / 7000-9000 / 27000-27100 | 现有 `game_udp` / `game_high_udp` → WAN1 |
| 游戏中的下载 | 自动检测 | 暂不启用（游戏 UDP 仍 WAN1） |
| 其他 | 非 TCP（UDP） | Table 50 / FIB Hash |

标记：

```text
0x100  WAN1
0x200  WAN2
0x300  Table 50 / FIB multipath
0x3f00 mwan3 connected / bypass
mask   0x3f00
```

---

## 2. 网页/会话 sticky

`/etc/config/mwan3`：

```uci
config policy 'web_affinity'
    list use_member 'wan_m1_w1'
    list use_member 'wan2_m1_w1'

config rule 'web_sticky'
    option src_ip '192.168.6.0/24'
    option proto 'tcp'
    option sticky '1'
    option timeout '86400'
    option use_policy 'web_affinity'
```

规则必须放在 `https` 和 `default_rule` 之前。

**所有 LAN TCP 按客户端 50/50 分配 WAN1/WAN2**，每个客户端只粘一条 WAN，页面内部和客户端的多个会话端口（2099/5222-5223/8393-8400）不会跨线。

只匹配 80/443 是不够的：LoL 客户端用 TCP 2099（PVP.net）、5222-5223（聊天）、8393-8400（Riot 服务）维持登录态；这些端口落到 Table 50 后会按目的 IP 哈希到另一条 WAN，导致“对战记录/活动页”加载失败。详见第 12 节。

`timeout 86400`（24h）避免客户端休眠 1 小时后 sticky 条目过期、重新 50/50 掷到另一条线。

WAN2 网页路径已用真实手机 `.137` 验证：临时规则下 112 条新 443 连接为
`mark=0x200`，WAN2 回程 `10.64.3.61` 218 条，最大响应 644,060 字节，页面/
图片正常。验证后已恢复 50/50。

注意：路由器本机源 `.1/.250` 的 OUTPUT 测试会被本机 mark/选路干扰，不能单独
作为 WAN2 结论；上面的结论来自真实 LAN 客户端。

---

## 3. 下载分类

在 mangle `PREROUTING` 中，**mwan3_hook 之后**执行 `WEB_CLASSIFY`：

```text
TCP 80/443 NEW，源 192.168.6.0/24
  ├─ 源总并发 >10 -> WEB_BULK_CHECK
  │    └─ 同一目标 >8 -> mark 0x300 (Table 50)，返回
  └─ 否则保持 mwan3 的 web sticky 标记
```

为什么必须在 `mwan3_hook` 之后：

- `mwan3_hook` 开头有 `CONNMARK --restore-mark`，会覆盖之前打的 mark；
- 因此先让 mwan3 完成 web sticky / connected 逻辑；
- 再由 `WEB_CLASSIFY` 覆盖 bulk 的标记；
- 链尾执行 `CONNMARK --save-mark`，保证后续包保持新类别。

`xt_connlimit` 在这台固件上不能把 `--connlimit-saddr` 和 `--connlimit-daddr`
放在同一个 match 里；实现改为两段式：

```text
WEB_CLASSIFY:  -m connlimit --connlimit-above 10 --connlimit-saddr -j WEB_BULK_CHECK
WEB_BULK_CHECK: -m connlimit --connlimit-above 8 --connlimit-daddr -j MARK 0x300
```

---

## 4. 游戏检测

游戏 UDP 本身仍由 mwan3 的 `game_udp` / `game_high_udp` 处理并固定 WAN1。

**自动“游戏期间下载切 WAN2”当前关闭。** 原实现用宽 UDP 端口收录
`game_active`，Mac 的普通 UDP（AirPlay/启动器）被误判，随后浏览器 bulk 连接
被强制到 WAN2；日志中 1799 个 bulk 新连接全部命中该分支。因此自动切换已停用，
游戏 UDP 仍走 WAN1；如果以后需要，建议改成手动游戏模式或带速率阈值的检测。

---

## 5. 持久化

仓库文件：

```text
root/etc/mwan3.user
root/etc/hotplug.d/iface/99-mwan3-user
root/etc/rc.local
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

标准化只读回归测试（不改配置、不重启）：

```bash
sh tools/test_network.sh
sh tools/test_network.sh --quick
sh tools/test_network.sh --client 192.168.6.216
```

退出码为 FAIL 数量，可直接用于脚本化回归。覆盖 WAN 健康、Table 50/SNAT/connected、
DNS、常用站点/CDN、WAN1/WAN2 吞吐、B 站封面与 256KB 视频分片、知乎/微博(新浪)/
淘宝/Steam 封面、LoL 17KB/104KB 图片、微信公众号文章 (3.9MB) 与 mmbiz 图片、
Quark 首页、游戏 UDP 规则、每客户端 mark 一致性、日志异常。

媒体 URL 在运行时从各站 API/HTML 动态提取（B 站热门、知乎日报、新浪滚动、淘宝首页、
微信文章），不依赖会过期的硬编码图片链接。

手动检查：

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

# WAN2 SNAT / connected 修复
iptables -t nat -S MWAN3_WAN2_SNAT
iptables -t mangle -S mwan3_hook | tail -3
iptables -t mangle -S mwan3_rule_web_sticky

# Table 50
ip route show table 50
```

本次实测：

- 手机 `.137` 强制 WAN2：112 条新 443 连接 `mark=0x200`，WAN2 回程 218 条，
  最大响应 644,060 字节，页面/图片正常；
- 20 条同目标慢连接：`WEB_BULK_CHECK` 的 `dst >8` 命中，conntrack 出现
  `mark=0x300`；
- 两条 WAN 网关均 0% 丢包，百度 HTTP 200。

---

## 7. 代价与边界

- 所有 TCP 按客户端 sticky 单 WAN；单个客户端网页/非 80/443 TCP 下载不聚合，80/443 高并发下载通过 bulk 旁路恢复。
- 阈值 10/8 是行为阈值；浏览器极端多标签可能被误判为 bulk。可按需调整。
- 现有连接不会迁移；规则只影响新连接。游戏客户端要完全退出重开，2099/5222 长连接才会切到新的 sticky WAN。
- 游戏 UDP 固定 WAN1；自动“游戏期间下载切 WAN2”当前关闭。
- 没有 CAKE/HTB/IFB/tc，无法做精确 12MB/s 限速。
- mwan3 运行时 restart 在这台固件可能卡 hotplug 锁；配置变更后用重启加载。

---

## 8. 回滚

路由器本地测试备份已清理。回滚以 Git 历史为准：

```text
4d537a8  ...  6074ff7 / 最新提交
```

也可以重新运行 `tools/configure_mwan3.sh` 生成配置。当前生效文件：

```text
/etc/config/mwan3
/etc/mwan3.user
/etc/hotplug.d/iface/99-mwan3-user
/etc/rc.local
```

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

真实 LAN 客户端测试曾显示 WAN2 大 TLS 卡住，但根因不是 WAN2 物理链路，而是
`mwan3_hook` 末尾的 `mwan3_connected` 覆盖了 web/bulk 的 connmark。该规则已
删除并持久化。

用手机 `.137` 做最终 WAN2 网页验证（临时只对新 80/443 连接强制 WAN2）：

```text
mark=0x200 的连接: 112 条
WAN2 回程 10.64.3.61: 218 条
最大响应: 644,060 字节
WeGame/Baidu/图片页面: 正常
```

验证后临时规则已删除，手机恢复 WAN1；随后恢复网页 50/50。

另一个问题是 `game_active` 误判：Mac 普通 UDP 被游戏端口规则收录，浏览器 bulk
连接被强制 WAN2。现已停用自动切换，清空 `game_active`，游戏 UDP 仍固定 WAN1。


---

## 11. WAN2 SNAT 与 connected 修复

WAN2 是 `eth0.2` VLAN，和 WAN1 共用校园网关。当前使用：
```text
-A MWAN3_WAN2_SNAT -s 192.168.6.0/24 -o eth0.2 -j SNAT --to-source <WAN2 IP>
```
并在 POSTROUTING 最前面跳转该链，绕过 fullcone MASQUERADE。

同时删除 `mwan3_hook` 末尾的：
```text
-A mwan3_hook -m mark ! --mark 0x3f00/0x3f00 -j mwan3_connected
```
否则 WAN→LAN 回程会被重新标成 `0x3f00` 并覆盖 web/bulk 的 connmark。

table 2 的连通路由由 mwan3 自己维护，`mwan3.user` 不再和它争抢；
WAN2 网页已用真实手机验证。`/etc/rc.local` 在 WAN2 online 后补跑一次
`mwan3.user`，避免 firewall 刷新掉 SNAT；iface hotplug 也延迟 5 秒。

---

## 12. 2026-10-20 LoL 对战记录/活动页加载失败

### 现象

50/50 网页分流后，LoL 客户端“对战记录”和部分活动页无法加载；游戏对局本身正常。

### 根因

`web_sticky` 当时只匹配 TCP 80/443。LoL 客户端使用：

```text
TCP 80, 443, 2099 (PVP.net), 5222-5223 (XMPP), 8393-8400 (Riot Client)
UDP 5000-5500 (game)
```

2099/5222/8393 不在 sticky 内，走 `mwan3_policy_balanced` → Table 50 →
按目的 IP 哈希，可能落在另一条 WAN。于是同一客户端的 HTTPS 登录在 sticky
WAN，PVP.net/聊天在哈希 WAN；服务端看到同一会话两个出口 IP，对战记录/活动页
校验失败。游戏 UDP 固定 WAN1，所以对局正常。

现场证据（手机 `.118`）：

```text
443    -> mark 0x200 (WAN2)
8080   -> mark 0x300 (WAN1)
993    -> mark 0x300 (WAN1)
同一目标 49.4.37.98:443 同时存在 0x100 和 0x200
```

`3600` 的 sticky timeout 只在新建连接时续期；客户端休眠超过 1 小时会重新
50/50，造成同一会话新旧连接分列两条 WAN。

### 修复

`web_sticky` 从“TCP 80/443”扩为“所有 TCP”，`timeout` 3600 → 86400：

```text
-A mwan3_rules -s 192.168.6.0/24 -p tcp -m mark --mark 0x0/0x3f00 -j mwan3_rule_web_sticky
```

游戏 UDP 规则不变，仍固定 WAN1；bulk 规则不变，80/443 高并发下载仍回 Table 50。

### 验证

Mac `.216`（sticky WAN2）新建 TCP 8080：

```text
mark=512 (0x200), 回程 10.64.4.30, HTTP 200
```

修复前该连接是 `mark=0x300` → Table 50。

### 注意

已有连接不会迁移；LoL 客户端需要完全退出重开，2099/5222 的长连接才会使用
新的 sticky WAN。`timeout 86400` 在下次重启（mwan3 重建 ipset）后生效。

---

## 13. 2026-10-20 标准化回归基线

`tools/test_network.sh` 全量结果：**75 PASS / 1 WARN / 0 FAIL**。

```text
WAN1 9.6 MB/s, WAN2 10.2 MB/s   (10MB range, mirrors.aliyun.com)
B 站封面 430KB / 视频分片 256KB: 两 WAN 均 PASS
知乎封面 8KB / 微博(新浪)图 170KB / 淘宝 banner 77KB / Steam 封面 34KB: 两 WAN 均 PASS
LoL 17KB + 104KB: 两 WAN 均 PASS
微信公众号文章 3.92MB + mmbiz 图片 131KB: 两 WAN 均 PASS
Quark 首页 42KB: 两 WAN 均 PASS
Table 50 双 nexthop / SNAT / connected 修复 / HNAT=0 全部 PASS
```

1 个 WARN：

- 日志缓冲区内有 1 次 `mwan3track` ping 失败（12:20，未导致接口 offline）。

后续回归直接对比这个基线；出现新的 FAIL 再排查。
