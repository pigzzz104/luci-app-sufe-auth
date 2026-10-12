#!/bin/sh
# ==============================================================================
# install.sh - luci-app-sufe-auth 安装脚本
# 上海财经大学 (SUFE) 校园网 802.1X 认证插件
# GitHub: https://github.com/pigzzz104/luci-app-sufe-auth
# ==============================================================================

set -e

# 1. 检查运行环境
if [ ! -f /etc/openwrt_release ] && [ ! -f /etc/immortalwrt_release ]; then
    echo "警告: 未检测到 OpenWrt / ImmortalWrt 环境。"
fi

# 2. 检查依赖 (Python3, ip)
echo "检查依赖包..."
NEED_OPKG=0
if ! command -v python3 >/dev/null 2>&1; then
    NEED_OPKG=1
fi

if ! command -v ip >/dev/null 2>&1; then
    NEED_OPKG=1
fi

if [ "$NEED_OPKG" -eq 1 ]; then
    echo "正在安装依赖 (python3, python3-syslog, ip-full)..."
    opkg update || true
    opkg install python3 python3-syslog ip-full || {
        echo "错误: 安装依赖失败，请检查网络连接。"
        exit 1
    }
fi

# 3. 部署插件文件
echo "部署插件文件与服务..."
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -d "$DIR/root" ]; then
    cp -r "$DIR/root/"* /
else
    RAW_BASE="https://raw.githubusercontent.com/pigzzz104/luci-app-sufe-auth/master/root"
    mkdir -p /etc/config /etc/init.d /usr/sbin /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi
    
    [ -f /etc/config/sufe_auth ] || curl -fsSL "$RAW_BASE/etc/config/sufe_auth" -o /etc/config/sufe_auth
    curl -fsSL "$RAW_BASE/etc/init.d/sufe_auth" -o /etc/init.d/sufe_auth
    curl -fsSL "$RAW_BASE/usr/sbin/sufe_auth" -o /usr/sbin/sufe_auth
    curl -fsSL "$RAW_BASE/usr/lib/lua/luci/controller/sufe_auth.lua" -o /usr/lib/lua/luci/controller/sufe_auth.lua
    curl -fsSL "$RAW_BASE/usr/lib/lua/luci/model/cbi/sufe_auth.lua" -o /usr/lib/lua/luci/model/cbi/sufe_auth.lua
fi

chmod +x /etc/init.d/sufe_auth /usr/sbin/sufe_auth

# 4. 配置开机自启并刷新 LuCI 缓存
echo "启用服务并刷新界面缓存..."
/etc/init.d/sufe_auth enable
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

echo "安装完成。请前往 LuCI 后台：【网络】->【上财校园网认证】配置账号。"
