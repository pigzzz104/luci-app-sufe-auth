#!/bin/sh
# ==============================================================================
# restore_ipv6.sh - 一键恢复路由器 IPv6 完整功能脚本
# ==============================================================================

echo '=== 开始一键恢复 IPv6 配置 ==='

# 1. 恢复 /etc/config/network 中的 wan6 与全局 IPv6 参数
uci -q delete network.wan6
uci set network.wan6=interface
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.ifname='eth1'
uci set network.lan.ip6assign='60'
uci set network.globals.ula_prefix='fd08:125a:0e04::/48'
uci commit network

# 2. 恢复防火墙 WAN 区域的 wan6 关联
uci -q del_list firewall.@zone[1].network='wan6'
uci add_list firewall.@zone[1].network='wan6'
uci commit firewall

# 3. 恢复 DHCP 与 DNS 的 IPv6 设置 (解除 filter_aaaa 过滤，开启 RA/DHCPv6)
uci set dhcp.@dnsmasq[0].filter_aaaa='0'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ndp='hybrid'
uci commit dhcp

# 4. 重新启用并启动 odhcpd 服务
/etc/init.d/odhcpd enable 2>/dev/null || true
/etc/init.d/odhcpd restart 2>/dev/null || true

# 5. 重启 dnsmasq 与防火墙，平滑重载 netifd
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/firewall reload 2>/dev/null || true
ubus call network reload 2>/dev/null || true

rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

echo '=== IPv6 完整配置已恢复成功！==='
