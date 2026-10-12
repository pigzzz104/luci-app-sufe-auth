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

# 3. 同步防火墙区域关联
echo "同步防火墙 WAN 区域关联..."
for iface in wan2 wan3; do
    if uci -q get network.$iface >/dev/null; then
        uci -q del_list firewall.@zone[1].network="$iface"
        uci add_list firewall.@zone[1].network="$iface"
    fi
done
uci commit firewall
/etc/init.d/firewall reload 2>/dev/null || true

# 4. 备份原 mwan3 配置并写入精简策略
echo "更新 /etc/config/mwan3 策略配置..."
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

config rule 'https'
	option proto 'tcp'
	option dest_port '443'
	option sticky '0'
	option use_policy 'balanced'

config rule 'quic'
	option proto 'udp'
	option dest_port '443'
	option sticky '0'
	option use_policy 'balanced'

config rule 'default_rule'
	option dest_ip '0.0.0.0/0'
	option sticky '0'
	option use_policy 'balanced'
EOF

# 5. 部署内核 FIB Multipath 动态同步脚本 (/etc/mwan3.user)
echo "部署 /etc/mwan3.user 同步脚本..."
cat << 'EOF' > /etc/mwan3.user
#!/bin/sh
# Multi-WAN Kernel FIB Multipath Sync Script
# Manages Table 50 for deterministic (src_ip, dst_ip) flow hashing

sync_mwan3_multipath() {
    local nexthops=""
    local wan1_st=$(cat /var/run/mwan3/iface_state/wan 2>/dev/null)
    local wan2_st=$(cat /var/run/mwan3/iface_state/wan2 2>/dev/null)
    local wan3_st=$(cat /var/run/mwan3/iface_state/wan3 2>/dev/null)

    # 动态探测各网卡网关
    local gw1=$(ip route show dev eth1 2>/dev/null | awk '/default/ {print $3}')
    [ -z "$gw1" ] && gw1=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    [ -z "$gw1" ] && gw1="10.64.0.1"

    local gw2=$(ip route show dev eth0.2 2>/dev/null | awk '/default/ {print $3}')
    [ -z "$gw2" ] && gw2=$(ubus call network.interface.wan2 status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    [ -z "$gw2" ] && gw2="$gw1"

    local gw3=$(ip route show dev eth0.3 2>/dev/null | awk '/default/ {print $3}')
    [ -z "$gw3" ] && gw3=$(ubus call network.interface.wan3 status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    [ -z "$gw3" ] && gw3="$gw1"

    [ "$wan1_st" = "online" ] && nexthops="$nexthops nexthop via $gw1 dev eth1 weight 1"
    [ "$wan2_st" = "online" ] && nexthops="$nexthops nexthop via $gw2 dev eth0.2 weight 1"
    [ "$wan3_st" = "online" ] && nexthops="$nexthops nexthop via $gw3 dev eth0.3 weight 1"

    if [ -n "$nexthops" ]; then
        ip route replace default table 50 proto static $nexthops
    else
        ip route flush table 50
    fi

    # 确保 fwmark 0x300 指向 Table 50
    ip rule list | grep -q 'lookup 50' || ip rule add pref 2003 fwmark 0x300/0x3f00 lookup 50

    # 确保 mwan3_policy_balanced 链委托给内核 FIB Multipath 路由
    if [ -n "$(iptables -t mangle -S mwan3_policy_balanced 2>/dev/null)" ]; then
        if ! iptables -t mangle -C mwan3_policy_balanced -j MARK --set-xmark 0x300/0x3f00 2>/dev/null; then
            iptables -t mangle -F mwan3_policy_balanced
            iptables -t mangle -A mwan3_policy_balanced -j MARK --set-xmark 0x300/0x3f00
        fi
    fi
}

sync_mwan3_multipath
EOF
chmod +x /etc/mwan3.user

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
ipset destroy mwan3_multistream 2>/dev/null || true

# 6. 重启 mwan3 服务并立即同步
echo "重启 MWAN3 服务..."
/etc/init.d/mwan3 enable
/etc/init.d/mwan3 restart
sleep 1
/etc/mwan3.user

echo "配置完成。可通过 'ip route show table 50' 查看路由状态。"
