#!/bin/sh
# ==============================================================================
# uninstall.sh - luci-app-sufe-auth 卸载脚本
# 上海财经大学 (SUFE) 校园网 802.1X 认证插件
# ==============================================================================

echo "=== 正在卸载 luci-app-sufe-auth ==="

# 停止并禁用服务
/etc/init.d/sufe_auth stop 2>/dev/null || true
/etc/init.d/sufe_auth disable 2>/dev/null || true
killall -9 sufe_auth python3 2>/dev/null || true

# 删除二进制与配置
rm -f /usr/sbin/sufe_auth
rm -f /etc/init.d/sufe_auth
rm -f /usr/lib/lua/luci/controller/sufe_auth.lua
rm -f /usr/lib/lua/luci/model/cbi/sufe_auth.lua

# 是否保留配置
read -p "是否同时删除配置文件 /etc/config/sufe_auth? (y/N): " choice
case "$choice" in
    y|Y )
        rm -f /etc/config/sufe_auth
        echo "[+] 配置文件已删除。"
        ;;
    * )
        echo "[*] 配置文件 /etc/config/sufe_auth 已保留。"
        ;;
esac

# 清理 LuCI 缓存
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

echo "=== 卸载完成！==="
