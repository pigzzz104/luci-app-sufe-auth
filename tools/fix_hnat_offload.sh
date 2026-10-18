#!/bin/sh
# ==============================================================================
# fix_hnat_offload.sh - 多 WAN 场景下关闭 MTK HNAT/WARP 硬件加速
#
# 背景：
#   联发科 MT798x 的 HNAT/WARP 会绕过 netfilter/mwan3 直接缓存 NAPT 流。
#   当两条 WAN 处于同一 /21 子网、又使用 FIB Multipath + mwan3 时，HNAT
#   可能把流固定到错误的 WAN，或在 TCP 20KB 窗口处卡死，表现为：
#     - 部分网页/图片一直空白，刷新多次也不出来；
#     - 部分图片/页面等待一段时间后又能加载；
#     - 路由器本机 curl 正常，但局域网 WiFi 设备复现。
#
# 用法：
#   sh tools/fix_hnat_offload.sh install          # 精简模式：开机一次性关闭 + ifup 钩子（默认，零常驻）
#   sh tools/fix_hnat_offload.sh install-watchdog # 保险模式：额外常驻巡检，每 10 秒检查一次（可选）
#   sh tools/fix_hnat_offload.sh status           # 查看当前状态
#   sh tools/fix_hnat_offload.sh rollback         # 回滚，恢复 HNAT/TurboACC
#
# 说明：
#   - 仅对存在 /sys/kernel/debug/hnat/hook_toggle 的 MTK 平台生效；
#   - 关闭 HNAT 不会关闭路由/NAT，只是让流量回到内核 netfilter；
#   - 保留 BBR，实测双线聚合仍可跑满（约 20.9 MiB/s）。
# ==============================================================================

set -u

ACTION="${1:-install}"
HNAT_HOOK="/sys/kernel/debug/hnat/hook_toggle"
HNAT_ENTRY="/sys/kernel/debug/hnat/hnat_entry"
SERVICE="/etc/init.d/hnat-off"
DAEMON="/usr/sbin/hnat-off"
HOTPLUG="/etc/hotplug.d/iface/99-hnat-off"
STAMP="$(date +%Y%m%d_%H%M%S)"

need_root() {
    [ "$(id -u)" = "0" ] || {
        echo "错误: 请以 root 运行。" >&2
        exit 1
    }
}

need_mtk() {
    if [ ! -e "$HNAT_HOOK" ]; then
        echo "未检测到 MTK HNAT ($HNAT_HOOK)，无需处理。"
        exit 0
    fi
}

backup_once() {
    src="$1"
    [ -f "$src" ] || return 0
    dst="/root/$(basename "$src").bak.$STAMP"
    [ -f "$dst" ] || cp -p "$src" "$dst" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 公共配置：关 TurboACC、关防火墙 offload、保留 BBR、备份
# ---------------------------------------------------------------------------
prepare() {
    backup_once /etc/config/firewall
    backup_once /etc/config/turboacc
    backup_once /etc/sysctl.conf

    if [ -x /etc/init.d/turboacc ]; then
        /etc/init.d/turboacc disable 2>/dev/null || true
    fi
    if command -v uci >/dev/null 2>&1; then
        uci set turboacc.config.hw_flow='0' 2>/dev/null || true
        uci set turboacc.config.sw_flow='0' 2>/dev/null || true
        uci commit turboacc 2>/dev/null || true

        uci set firewall.@defaults[0].flow_offloading='0' 2>/dev/null || true
        uci set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null || true
        uci commit firewall 2>/dev/null || true
    fi

    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null || \
            echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    fi
}

stop_old() {
    if [ -x "$SERVICE" ]; then
        "$SERVICE" stop 2>/dev/null || true
        "$SERVICE" disable 2>/dev/null || true
    fi
    killall hnat-off 2>/dev/null || true
    rm -f /etc/rc.d/S99hnat-off /etc/rc.d/K10hnat-off "$DAEMON" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 精简模式：开机一次性写 0，ifup 时再写 0；无常驻进程
# ---------------------------------------------------------------------------
write_oneshot_service() {
    cat > "$SERVICE" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    i=0
    while [ "$i" -lt 10 ]; do
        if [ -e /sys/kernel/debug/hnat/hook_toggle ]; then
            echo 0 > /sys/kernel/debug/hnat/hook_toggle
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 0
}
EOF
    chmod +x "$SERVICE"
}

write_hotplug() {
    mkdir -p /etc/hotplug.d/iface
    cat > "$HOTPLUG" <<'EOF'
#!/bin/sh
# Re-apply HNAT-off after a WAN/WiFi interface comes up.
[ "$ACTION" = "ifup" ] || exit 0
case "$INTERFACE" in
    wan|wan2|wan3|ra0|rai0|ra1|rai1) ;;
    *) exit 0 ;;
esac
[ -e /sys/kernel/debug/hnat/hook_toggle ] && echo 0 > /sys/kernel/debug/hnat/hook_toggle
exit 0
EOF
    chmod +x "$HOTPLUG"
}

# ---------------------------------------------------------------------------
# 保险模式（可选）：常驻巡检，每 10 秒检查 NAPT，发现被重开就再关
# ---------------------------------------------------------------------------
write_daemon() {
    cat > "$DAEMON" <<'EOF'
#!/bin/sh
# Keep MediaTek HNAT hardware offload disabled.
# HNAT caches NAPT entries and bypasses netfilter/mwan3; with multiple WANs
# sharing the same /21 it can stall TCP flows (observed at the 20 KB mark).
i=0
while [ "$i" -lt 30 ]; do
    if [ -e /sys/kernel/debug/hnat/hook_toggle ]; then
        echo 0 > /sys/kernel/debug/hnat/hook_toggle 2>/dev/null
        break
    fi
    i=$((i + 1))
    sleep 1
done
while true; do
    sleep 10
    if grep -q "NAPT" /sys/kernel/debug/hnat/hnat_entry 2>/dev/null; then
        echo 0 > /sys/kernel/debug/hnat/hook_toggle 2>/dev/null
        logger -t hnat-off "HNAT re-enabled by system; disabled again"
    fi
done
EOF
    chmod +x "$DAEMON"
}

write_procd_service() {
    cat > "$SERVICE" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/sbin/hnat-off
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
EOF
    chmod +x "$SERVICE"
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
install_fix() {
    need_root
    need_mtk
    prepare
    stop_old
    write_oneshot_service
    write_hotplug
    "$SERVICE" enable 2>/dev/null || true
    "$SERVICE" start 2>/dev/null || true
    echo 0 > "$HNAT_HOOK" 2>/dev/null || true

    echo "HNAT 硬件加速已关闭（精简模式，无常驻进程）。"
    echo "  - TurboACC 自启: 已禁用"
    echo "  - firewall flow_offloading / flow_offloading_hw: 0 / 0"
    echo "  - 开机一次性关闭: $SERVICE (S99)"
    echo "  - 网口 up 事件钩子: $HOTPLUG"
    echo "  - 如需额外巡检: sh $0 install-watchdog"
    echo "  - 回滚: sh $0 rollback  或  /root/rollback_hnat_off.sh"
}

install_watchdog() {
    need_root
    need_mtk
    prepare
    stop_old
    write_daemon
    write_procd_service
    "$SERVICE" enable 2>/dev/null || true
    "$SERVICE" restart 2>/dev/null || "$SERVICE" start 2>/dev/null || true
    echo 0 > "$HNAT_HOOK" 2>/dev/null || true

    echo "HNAT 硬件加速已关闭（保险模式，常驻巡检）。"
    echo "  - TurboACC 自启: 已禁用"
    echo "  - firewall flow_offloading / flow_offloading_hw: 0 / 0"
    echo "  - 巡检服务: $SERVICE (S99, 每 10 秒检查)"
    echo "  - 回滚: sh $0 rollback  或  /root/rollback_hnat_off.sh"
}

# ---------------------------------------------------------------------------
# 回滚
# ---------------------------------------------------------------------------
rollback() {
    need_root

    [ -x "$SERVICE" ] && "$SERVICE" stop 2>/dev/null || true
    [ -x "$SERVICE" ] && "$SERVICE" disable 2>/dev/null || true
    killall hnat-off 2>/dev/null || true
    rm -f "$SERVICE" "$DAEMON" "$HOTPLUG" \
        /etc/rc.d/S99hnat-off /etc/rc.d/K10hnat-off 2>/dev/null || true

    [ -e "$HNAT_HOOK" ] && echo 1 > "$HNAT_HOOK" 2>/dev/null || true

    if command -v uci >/dev/null 2>&1; then
        uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
        uci commit firewall 2>/dev/null || true
    fi

    [ -x /etc/init.d/turboacc ] && /etc/init.d/turboacc enable 2>/dev/null || true
    /etc/init.d/firewall reload 2>/dev/null || true

    echo "已回滚：HNAT/TurboACC 硬件加速恢复。"
    echo "注意：回滚会重新引入多 WAN 下部分网页/图片卡死的风险。"
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
status() {
    echo "=== HNAT ==="
    if [ -e "$HNAT_ENTRY" ]; then
        n=$(grep -c 'NAPT' "$HNAT_ENTRY" 2>/dev/null || true)
        [ -n "$n" ] || n=0
        echo "active NAPT entries: $n"
    else
        echo "debugfs not present (not MTK HNAT?)"
    fi

    echo "=== service ==="
    if [ -x "$SERVICE" ]; then
        "$SERVICE" enabled >/dev/null 2>&1 && echo "hnat-off: enabled" || echo "hnat-off: disabled"
        pid=$(ubus call service list '{"name":"hnat-off"}' 2>/dev/null | jsonfilter -e '@["hnat-off"].instances.*.pid' 2>/dev/null)
        if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
            echo "hnat-off: daemon running (pid $pid)"
        else
            echo "hnat-off: one-shot mode (no daemon)"
        fi
    else
        echo "hnat-off: not installed"
    fi
    [ -x "$HOTPLUG" ] && echo "ifup hook: installed" || echo "ifup hook: not installed"

    echo "=== firewall/turboacc ==="
    command -v uci >/dev/null 2>&1 && {
        echo "flow_offloading=$(uci -q get firewall.@defaults[0].flow_offloading)"
        echo "flow_offloading_hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)"
    }
    if [ -x /etc/init.d/turboacc ]; then
        /etc/init.d/turboacc enabled >/dev/null 2>&1 && echo "turboacc: enabled" || echo "turboacc: disabled"
    fi

    echo "=== sysctl ==="
    echo "fib_multipath_hash_policy=$(sysctl -n net.ipv4.fib_multipath_hash_policy 2>/dev/null)"
    echo "tcp_congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
}

case "$ACTION" in
    install)          install_fix ;;
    install-watchdog) install_watchdog ;;
    rollback)         rollback ;;
    status)           status ;;
    *)
        echo "用法: sh $0 {install|install-watchdog|status|rollback}" >&2
        exit 1
        ;;
esac
