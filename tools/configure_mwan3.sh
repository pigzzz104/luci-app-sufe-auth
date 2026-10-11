#!/bin/sh
# ==============================================================================
# configure_mwan3.sh - 多线聚合与策略路由 (MWAN3) 一键优化配置脚本
# 基于上财宿舍实战验证方案（支持双线/三线负载均衡、游戏低延迟防跳变、多线程下载翻倍）
# GitHub: https://github.com/pigzzz104/luci-app-sufe-auth
# ==============================================================================

set -e

echo "=========================================================="
echo "  MWAN3 多线聚合与分流策略一键配置脚本                   "
echo "=========================================================="

# 1. 检查 mwan3 是否安装
if ! command -v mwan3 >/dev/null 2>&1; then
    echo "[!] 未检测到 mwan3 命令，准备尝试安装 mwan3 与 luci-app-mwan3..."
    opkg update || true
    opkg install mwan3 luci-app-mwan3 || {
        echo "[!] 安装 mwan3 失败，请检查网络连接后手动运行: opkg install mwan3 luci-app-mwan3"
        exit 1
    }
fi

# 2. 检查并设置网络接口跃点 (Metric)
echo "[1/4] 配置各 WAN 接口路由跃点 (Metric)..."
# mwan3 要求每个参与多拨的接口必须有独立的 metric
[ "$(uci -q get network.wan.metric)" != "10" ] && uci set network.wan.metric='10'
if uci -q get network.wan2 >/dev/null; then
    [ "$(uci -q get network.wan2.metric)" != "20" ] && uci set network.wan2.metric='20'
fi
if uci -q get network.wan3 >/dev/null; then
    [ "$(uci -q get network.wan3.metric)" != "30" ] && uci set network.wan3.metric='30'
fi
uci commit network
/etc/init.d/network reload 2>/dev/null || true

# 3. 检查并确保防火墙 WAN 区域包含各接口
echo "[2/4] 同步防火墙 WAN 区域关联..."
for iface in wan2 wan3; do
    if uci -q get network.$iface >/dev/null; then
        uci -q del_list firewall.@zone[1].network="$iface"
        uci add_list firewall.@zone[1].network="$iface"
    fi
done
uci commit firewall
/etc/init.d/firewall reload 2>/dev/null || true

# 4. 备份原 mwan3 配置
echo "[3/4] 备份并写入优化后的 MWAN3 策略配置..."
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
	option metric '1'
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
	option sticky '1'
	option timeout '600'
	option use_policy 'balanced'

config rule 'default_rule'
	option dest_ip '0.0.0.0/0'
	option sticky '0'
	option use_policy 'balanced'
EOF

# 5. 重启 mwan3 服务
echo "[4/4] 启动并启用 MWAN3 服务..."
/etc/init.d/mwan3 enable
/etc/init.d/mwan3 restart

echo "=========================================================="
echo "  MWAN3 配置完成！"
echo "  - 已配置双公共 DNS (阿里/腾讯) 实时链路探测 (心跳 5s)"
echo "  - 游戏与语音常见端口已配置 IP 粘性固定首选主 WAN 线路"
echo "  - 通用流量与多线程下载已启用 balanced 多线均衡叠加"
echo "  - 可执行 'mwan3 status' 查看当前多路链路状态"
echo "=========================================================="
