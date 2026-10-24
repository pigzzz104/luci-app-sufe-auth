#!/bin/sh
# ==============================================================================
# configure_mwan3.sh - 多线聚合与策略路由 (MWAN3) 配置脚本
# 架构方案：Linux 内核 FIB Multipath 流哈希 (Table 50) + MWAN3 策略路由协同
# GitHub: https://github.com/pigzzz104/luci-app-sufe-auth
# ==============================================================================

set -e

# 1. 检查 mwan3 依赖
if ! command -v mwan3 >/dev/null 2>&1; then
    echo "未检测到 mwan3，正在安装依赖 (mwan3, luci-app-mwan3)..."
    opkg update || true
    opkg install mwan3 luci-app-mwan3 || {
        echo "错误: 安装 mwan3 失败，请检查网络连接。"
        exit 1
    }
fi

# 2. 配置接口路由跃点 (Metric)
echo "配置 WAN 接口路由跃点 (Metric)..."
[ "$(uci -q get network.wan.metric)" != "10" ] && uci set network.wan.metric='10'
if uci -q get network.wan2 >/dev/null; then
    [ "$(uci -q get network.wan2.metric)" != "20" ] && uci set network.wan2.metric='20'
fi
if uci -q get network.wan3 >/dev/null; then
    [ "$(uci -q get network.wan3.metric)" != "30" ] && uci set network.wan3.metric='30'
fi
uci commit network
/etc/init.d/network reload 2>/dev/null || true

# 3. 同步防火墙区域关联与硬件加速兼容参数
echo "同步防火墙 WAN 区域与内核连接跟踪参数..."
for iface in wan2 wan3; do
    if uci -q get network.$iface >/dev/null; then
        uci -q del_list firewall.@zone[1].network="$iface"
        uci add_list firewall.@zone[1].network="$iface"
    fi
done
uci commit firewall
/etc/init.d/firewall reload 2>/dev/null || true

# 开启 nf_conntrack 宽松窗口模式，使 mtkhnat 硬件加速与多 WAN 并行时不因序列号超前误丢 HTTP/2 长连接包
grep -q "nf_conntrack_tcp_be_liberal" /etc/sysctl.conf 2>/dev/null || echo "net.netfilter.nf_conntrack_tcp_be_liberal=1" >> /etc/sysctl.conf
sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1 || true

# 固化内核三层流哈希模式，确保同一目标 IP 流量严格锁定同一 WAN 出口，彻底根除 IP 漂移与 WAF 拦截
grep -q "fib_multipath_hash_policy" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.fib_multipath_hash_policy=0" >> /etc/sysctl.conf
sysctl -w net.ipv4.fib_multipath_hash_policy=0 >/dev/null 2>&1 || true

# 阻断 UDP 443 (QUIC)，防止 HTTP/3 握手受阻触发 3 秒降级等待，强制 0ms 瞬间回退至稳定 HTTP/2 TCP
if ! uci show firewall | grep -q "Reject-QUIC-UDP443"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name="Reject-QUIC-UDP443"
    uci set firewall.@rule[-1].src="lan"
    uci set firewall.@rule[-1].dest="wan"
    uci set firewall.@rule[-1].proto="udp"
    uci set firewall.@rule[-1].dest_port="443"
    uci set firewall.@rule[-1].target="REJECT"
    uci commit firewall
    /etc/init.d/firewall reload 2>/dev/null || true
fi

# 4. 优化 dnsmasq 上游 DNS 配置 (支持网盘多集群节点并发散列，屏蔽 IPv6 延迟)
echo "优化 dnsmasq 上游 DNS 配置..."
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
uci add_list dhcp.@dnsmasq[0].server="119.29.29.29"
uci set dhcp.@dnsmasq[0].allservers='1'
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci commit dhcp
/etc/init.d/dnsmasq reload 2>/dev/null || true

# 5. 备份原 mwan3 配置并写入精简策略
echo "更新 /etc/config/mwan3 策略配置..."
GAME_PC_IP="${1:-$GAME_PC_IP}"
if [ -z "$GAME_PC_IP" ] && [ -t 0 ]; then
    printf "\n[可选配置] 是否有特定游戏主机需锁定走优质游戏线路 (WAN1)?\n"
    printf "(可彻底根除英雄联盟等游戏的大厅与对局公网 IP 分裂，留空直接回车跳过): "
    read -r input_ip
    GAME_PC_IP="$input_ip"
fi
if [ -f /etc/config/mwan3 ]; then
    cp -p /etc/config/mwan3 "/etc/config/mwan3.bak.$(date +%Y%m%d_%H%M%S)"
fi

cat << 'EOF' > /etc/config/mwan3
config globals 'globals'
	option mmx_mask '0x3F00'
	option rtmon_interval '5'

config interface 'wan'
	option enabled '1'
	option family 'ipv4'
	list track_ip '223.5.5.5'
	list track_ip '119.29.29.29'
	option reliability '1'
	option count '1'
	option timeout '2'
	option interval '5'
	option down '3'
	option up '3'

config interface 'wan2'
	option enabled '1'
	option family 'ipv4'
	list track_ip '223.5.5.5'
	list track_ip '119.29.29.29'
	option reliability '1'
	option count '1'
	option timeout '2'
	option interval '5'
	option down '3'
	option up '3'

config interface 'wan3'
	option enabled '1'
	option family 'ipv4'
	list track_ip '223.5.5.5'
	list track_ip '119.29.29.29'
	option reliability '1'
	option count '1'
	option timeout '2'
	option interval '5'
	option down '3'
	option up '3'

config member 'wan_m1_w1'
	option interface 'wan'
	option metric '1'
	option weight '1'

config member 'wan2_m1_w1'
	option interface 'wan2'
	option metric '1'
	option weight '1'

config member 'wan3_m1_w1'
	option interface 'wan3'
	option metric '3'
	option weight '1'

config member 'wan2_m2_w1'
	option interface 'wan2'
	option metric '2'
	option weight '1'

config member 'wan3_m3_w1'
	option interface 'wan3'
	option metric '3'
	option weight '1'

config policy 'balanced'
	list use_member 'wan_m1_w1'
	list use_member 'wan2_m1_w1'
	list use_member 'wan3_m1_w1'

config policy 'wan_pref'
	list use_member 'wan_m1_w1'
	list use_member 'wan2_m2_w1'
	list use_member 'wan3_m3_w1'

config policy 'wan_only'
	list use_member 'wan_m1_w1'

config policy 'wan2_only'
	list use_member 'wan2_m1_w1'

config policy 'wan3_only'
	list use_member 'wan3_m1_w1'

config rule 'game_udp'
	option proto 'udp'
	option dest_port '3074,5000:5500,7000:9000,27000:27100'
	option sticky '1'
	option timeout '3600'
	option use_policy 'wan_pref'

config rule 'game_high_udp'
	option proto 'udp'
	option dest_port '10000:20000'
	option sticky '1'
	option timeout '3600'
	option use_policy 'wan_pref'

config rule 'game_tcp'
	option proto 'tcp'
	option dest_port '1119,3724,2099,5222,5223,8393:8400'
	option sticky '1'
	option timeout '3600'
	option use_policy 'wan_pref'

config policy 'web_affinity'
	list use_member 'wan_m1_w1'
	list use_member 'wan2_m1_w1'
EOF

if [ -n "$GAME_PC_IP" ]; then
    echo "为游戏主机 $GAME_PC_IP 写入专属 WAN1 策略..."
    cat << EOF >> /etc/config/mwan3

config rule 'game_pc_web'
	option src_ip '$GAME_PC_IP'
	option proto 'tcp'
	option dest_port '80,443'
	option sticky '1'
	option timeout '86400'
	option use_policy 'wan_only'
EOF
fi

cat << 'EOF' >> /etc/config/mwan3

config rule 'web_sticky'
	option src_ip '192.168.6.0/24'
	option proto 'tcp'
	option dest_port '80,443'
	option sticky '1'
	option timeout '86400'
	option use_policy 'web_affinity'

config rule 'https'
	option proto 'tcp'
	option dest_port '443'
	option sticky '0'
	option use_policy 'balanced'

config rule 'default_rule'
	option dest_ip '0.0.0.0/0'
	option sticky '0'
	option use_policy 'balanced'
EOF

# 6. 部署内核 FIB Multipath 动态同步脚本 (/etc/mwan3.user)
echo "部署 /etc/mwan3.user 同步脚本..."
cat << 'EOF' > /etc/mwan3.user
#!/bin/sh
# Three-class multi-WAN policy for luci-app-sufe-auth.
#
#   game   : UDP game ports & TCP control ports (1119, 3724, 2099, etc.) -> WAN1
#   web    : TCP 443 -> per-client sticky WAN (mwan3 web_affinity)
#   bulk   : TCP 80, Netdisk domains (ipset), & single-IP (>4 conns) -> CLASSIFY_BULK (50/50 dual-line)
#   campus : 10.0.0.0/8 intranet -> single-line sticky
#   other  : Table 50 FIB hash
#
# Web traffic (443) stays on the client's sticky WAN to prevent WAF /
# credential drops on multi-asset page loads and prevent video player buffer
# stalls. Downloads (Steam on 80, netdisks via ipset) route to CLASSIFY_BULK.
#
# This file is sourced by /etc/firewall.user and by the iface hotplug hook.
# It must stay idempotent: it runs on firewall reload and on every ifup/ifdown.

LOG="logger -t mwan3-user"

# Ensure multistream ipset exists for dnsmasq and iptables
ipset create mwan3_multistream hash:ip hashsize 1024 maxelem 65536 2>/dev/null || true

sync_mwan3_multipath() {
    sysctl -w net.ipv4.fib_multipath_hash_policy=0 >/dev/null 2>&1

    local wan1_st=$(cat /var/run/mwan3/iface_state/wan 2>/dev/null)
    local wan2_st=$(cat /var/run/mwan3/iface_state/wan2 2>/dev/null)
    local wan3_st=$(cat /var/run/mwan3/iface_state/wan3 2>/dev/null)

    local gw1=$(ip route show dev eth1 2>/dev/null | awk '$1 == "default" {print $3; exit}')
    [ -z "$gw1" ] && gw1="10.64.0.1"
    local gw2=$(ip route show dev eth0.2 2>/dev/null | awk '$1 == "default" {print $3; exit}')
    [ -z "$gw2" ] && gw2="$gw1"
    local gw3=$(ip route show dev eth0.3 2>/dev/null | awk '$1 == "default" {print $3; exit}')
    [ -z "$gw3" ] && gw3="$gw1"

    local nexthops=""
    [ "$wan1_st" = "online" ] && nexthops="$nexthops nexthop via $gw1 dev eth1 weight 1"
    [ "$wan2_st" = "online" ] && nexthops="$nexthops nexthop via $gw2 dev eth0.2 weight 1"
    [ "$wan3_st" = "online" ] && nexthops="$nexthops nexthop via $gw3 dev eth0.3 weight 1"

    if [ -n "$nexthops" ]; then
        ip route replace default table 50 proto static $nexthops
    else
        ip route flush table 50 2>/dev/null
    fi

    ip rule list | grep -q 'lookup 50' || \
        ip rule add pref 2003 fwmark 0x300/0x3f00 lookup 50

    if [ -n "$(iptables -t mangle -S mwan3_policy_balanced 2>/dev/null)" ]; then
        if ! iptables -t mangle -C mwan3_policy_balanced \
                -j MARK --set-xmark 0x300/0x3f00 2>/dev/null; then
            iptables -t mangle -F mwan3_policy_balanced
            iptables -t mangle -A mwan3_policy_balanced \
                -j MARK --set-xmark 0x300/0x3f00
        fi
    fi
}

sync_web_affinity_policy() {
    # mwan3 generates this chain from the policy at boot.  Rebuild it after
    # both WANs are up: new clients are split 50/50, then mwan3's sticky set
    # keeps each source IP on the selected WAN.
    iptables -t mangle -N mwan3_policy_web_affinity 2>/dev/null
    iptables -t mangle -F mwan3_policy_web_affinity 2>/dev/null

    local wan1_st=$(cat /var/run/mwan3/iface_state/wan 2>/dev/null)
    local wan2_st=$(cat /var/run/mwan3/iface_state/wan2 2>/dev/null)

    if [ "$wan1_st" = "online" ] && [ "$wan2_st" = "online" ]; then
        iptables -t mangle -A mwan3_policy_web_affinity \
            -m mark --mark 0x0/0x3f00 \
            -m statistic --mode random --probability 0.5 \
            -j MARK --set-xmark 0x200/0x3f00
        iptables -t mangle -A mwan3_policy_web_affinity \
            -m mark --mark 0x0/0x3f00 \
            -j MARK --set-xmark 0x100/0x3f00
    elif [ "$wan1_st" = "online" ]; then
        iptables -t mangle -A mwan3_policy_web_affinity \
            -m mark --mark 0x0/0x3f00 \
            -j MARK --set-xmark 0x100/0x3f00
    elif [ "$wan2_st" = "online" ]; then
        iptables -t mangle -A mwan3_policy_web_affinity \
            -m mark --mark 0x0/0x3f00 \
            -j MARK --set-xmark 0x200/0x3f00
    fi
}

sync_wan2_nat_path() {
    # WAN2 is a VLAN on eth0.2 and shares the campus gateway with WAN1.
    # Bypass the fullcone MASQUERADE with explicit SNAT. The table-2 route is
    # managed by mwan3 itself; do not fight its route updates here.
    local ip2
    ip2=$(ip -4 addr show eth0.2 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    [ -n "$ip2" ] || return 0

    iptables -t nat -N MWAN3_WAN2_SNAT 2>/dev/null
    iptables -t nat -F MWAN3_WAN2_SNAT 2>/dev/null
    iptables -t nat -A MWAN3_WAN2_SNAT \
        -s 192.168.6.0/24 -o eth0.2 \
        -j SNAT --to-source "$ip2"
    iptables -t nat -C POSTROUTING -j MWAN3_WAN2_SNAT 2>/dev/null || \
        iptables -t nat -I POSTROUTING 1 -j MWAN3_WAN2_SNAT
}

sync_mwan3_connected_fix() {
    # mwan3_connected contains 192.168.6.0/24. The final mwan3_hook rule
    # re-marks WAN->LAN reply packets as 0x3f00 and saves that into conntrack,
    # overwriting the web/bulk class mark. Remove that final rule; new
    # connections are still handled by the earlier mwan3_connected jump.
    iptables -t mangle -D mwan3_hook \
        -m mark ! --mark 0x3f00/0x3f00 -j mwan3_connected 2>/dev/null
}

sync_traffic_classification() {
    iptables -t mangle -N WEB_CLASSIFY 2>/dev/null
    iptables -t mangle -F WEB_CLASSIFY 2>/dev/null
    iptables -t mangle -F WEB_BULK_CHECK 2>/dev/null
    iptables -t mangle -X WEB_BULK_CHECK 2>/dev/null

    # Helper chain: 50/50 per-connection load balancing across WAN1 and WAN2
    # Bypasses Table 50 L3 hash so even multiple connections to the same host IP
    # are evenly split across both WAN interfaces.
    iptables -t mangle -N CLASSIFY_BULK 2>/dev/null
    iptables -t mangle -F CLASSIFY_BULK 2>/dev/null
    iptables -t mangle -A CLASSIFY_BULK -j MARK --set-xmark 0x0/0x3f00
    iptables -t mangle -A CLASSIFY_BULK \
        -m statistic --mode random --probability 0.5 \
        -j MARK --set-xmark 0x200/0x3f00
    iptables -t mangle -A CLASSIFY_BULK \
        -m mark --mark 0x0/0x3f00 \
        -j MARK --set-xmark 0x100/0x3f00
    iptables -t mangle -A CLASSIFY_BULK \
        -j CONNMARK --save-mark --nfmask 0x3f00 --ctmask 0x3f00
    iptables -t mangle -A CLASSIFY_BULK -j RETURN

    # 1) Campus intranet exemption: keep 10.0.0.0/8 on sticky/single line
    iptables -t mangle -A WEB_CLASSIFY -d 10.0.0.0/8 -j RETURN

    # 2) Dedicated game PC exemption: respect mwan3's game_pc_web rule if configured
    local game_pc_ip
    game_pc_ip=$(uci -q get mwan3.game_pc_web.src_ip)
    [ -n "$game_pc_ip" ] && iptables -t mangle -A WEB_CLASSIFY -s "$game_pc_ip" -j RETURN

    # 3) Bulk HTTP port 80 download (SteamPipe, Windows Update, CDN chunks).
    #    Normal web browsing is 100% HTTPS (443). Port 80 is used for unencrypted
    #    bulk chunk downloads and brief 301/302 redirects.
    iptables -t mangle -A WEB_CLASSIFY \
        -s 192.168.6.0/24 -p tcp --dport 80 \
        -m conntrack --ctstate NEW \
        -j CLASSIFY_BULK

    # 4) Multistream download acceleration (Quark, Baidu Wangpan, Speedtest via ipset).
    #    Populated cleanly by dnsmasq without guessing connection thresholds or breaking Bilibili.
    if ipset list mwan3_multistream >/dev/null 2>&1; then
        iptables -t mangle -A WEB_CLASSIFY \
            -s 192.168.6.0/24 -p tcp \
            -m set --match-set mwan3_multistream dst \
            -m conntrack --ctstate NEW \
            -j CLASSIFY_BULK
    fi

    # 5) Multi-threaded HTTPS downloads to same single IP (>4 connections to exact same IP):
    #    Single-host download acceleration (IDM, Thunder, Aria2).
    iptables -t mangle -A WEB_CLASSIFY \
        -s 192.168.6.0/24 -p tcp --dport 443 \
        -m conntrack --ctstate NEW \
        -m connlimit --connlimit-above 4 --connlimit-mask 32 --connlimit-daddr \
        -j CLASSIFY_BULK

    iptables -t mangle -A WEB_CLASSIFY -j RETURN

    # Must run AFTER mwan3_hook: mwan3 restores the conntrack mark first, then
    # our chain overrides the class for bulk NEW connections.
    iptables -t mangle -D PREROUTING -j WEB_CLASSIFY 2>/dev/null
    iptables -t mangle -A PREROUTING -j WEB_CLASSIFY
}

sync_mwan3_multipath
sync_wan2_nat_path
sync_mwan3_connected_fix
sync_web_affinity_policy
sync_traffic_classification
EOF
chmod +x /etc/mwan3.user

# mwan3 的 ifup 事件之后重建 Table 50 / web / bulk / game 分类
mkdir -p /etc/hotplug.d/iface
cat << 'EOF' > /etc/hotplug.d/iface/99-mwan3-user
#!/bin/sh
case "$ACTION" in
    ifup|ifdown) ;;
    *) exit 0 ;;
esac
sleep 5
[ -x /etc/mwan3.user ] && /etc/mwan3.user >/dev/null 2>&1
exit 0
EOF
chmod +x /etc/hotplug.d/iface/99-mwan3-user

# 开机后置修复：firewall 可能在 iface hotplug 之后刷新 NAT，导致 WAN2 SNAT 丢失。
# 直接使用仓库里的 root/etc/rc.local；找不到时给出明确警告。
RC_SRC="$(dirname "$0")/../root/etc/rc.local"
if [ -f "$RC_SRC" ]; then
    cp "$RC_SRC" /etc/rc.local
    chmod +x /etc/rc.local
else
    echo "警告: 未找到 $RC_SRC，WAN2 SNAT 开机后置修复未安装。"
fi

# 确保防火墙启动/重载时自动调用 /etc/mwan3.user
if [ -f /etc/firewall.user ]; then
    grep -q "/etc/mwan3.user" /etc/firewall.user || echo "/etc/mwan3.user" >> /etc/firewall.user
else
    echo "/etc/mwan3.user" > /etc/firewall.user
fi

# 清理遗留历史组件
rm -f /usr/sbin/update-mwan-rules.sh 2>/dev/null || true
if [ -f /etc/crontabs/root ]; then
    sed -i '/update-mwan-rules/d' /etc/crontabs/root 2>/dev/null || true
fi

# 部署网盘与测速多流加速域名集合 (dnsmasq -> mwan3_multistream)
mkdir -p /etc/dnsmasq.d
cat << 'EOF' > /etc/dnsmasq.d/multistream.conf
# Cloud drives and download acceleration
ipset=/quark.cn/myquark.cn/quarkfile.com/uc.cn/ucdrive.com/alicloudccp.com/aliyuncs.com/mwan3_multistream
ipset=/alipan.com/aliyundrive.com/mwan3_multistream
ipset=/baidupcs.com/baidupcs.net/pcs.baidu.com/mwan3_multistream
ipset=/123pan.com/123pan.cn/mwan3_multistream
ipset=/xunlei.com/sandai.net/mwan3_multistream
ipset=/steamcontent.com/steamserver.net/mwan3_multistream
# Speedtest services
ipset=/speedtest.net/speedtest.cn/fast.com/netspeedtest.com/speed.cloudflare.com/speed.neu6.edu.cn/test.ustc.edu.cn/mwan3_multistream
EOF
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

# 7. 重启 mwan3 服务并立即同步
echo "重启 MWAN3 服务..."
/etc/init.d/mwan3 enable
# 该固件的 mwan3 运行时 restart 可能卡在 hotplug 锁；配置在下次重启加载。
# 同时先手工运行一次 mwan3.user，保证当前会话的 Table 50 不中断。
/etc/mwan3.user 2>/dev/null || true
echo "mwan3 配置已写入；请重启路由器以加载 web/bulk/game 规则。"

# 8. 关闭 MTK HNAT/WARP 硬件加速
# HNAT 会绕过 netfilter/mwan3 缓存 NAPT；双 WAN 同网段时可能在 TCP 20KB
# 处卡死，表现为部分图片/网页永远空白、部分过段时间又能加载。
# 详见 tools/fix_hnat_offload.sh 与 README 的“多 WAN 稳定性”章节。
FIX_HNAT="$(dirname "$0")/fix_hnat_offload.sh"
if [ -x "$FIX_HNAT" ]; then
    echo "关闭 MTK HNAT 硬件加速..."
    "$FIX_HNAT" install || echo "警告: 关闭 HNAT 失败，请手动运行 $FIX_HNAT install"
else
    echo "提示: 未找到 $FIX_HNAT；若为 MTK 平台，请手动关闭 HNAT，否则可能出现图片/网页卡死。"
fi

echo "配置完成。可通过 'ip route show table 50' 查看路由状态。"
