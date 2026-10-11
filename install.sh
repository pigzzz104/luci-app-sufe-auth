#!/bin/sh
# ==============================================================================
# install.sh - luci-app-sufe-auth 一键安装脚本
# 上海财经大学 (SUFE) 校园网 802.1X 认证插件
# GitHub: https://github.com/pigzzz104/luci-app-sufe-auth
# ==============================================================================

set -e

echo "=========================================================="
echo "  上海财经大学校园网 802.1X 认证插件 (luci-app-sufe-auth)  "
echo "  开始自动化安装与部署...                                  "
echo "=========================================================="

# 1. 检查运行环境
if [ ! -f /etc/openwrt_release ] && [ ! -f /etc/immortalwrt_release ]; then
    echo "[!] 警告: 未检测到 OpenWrt / ImmortalWrt 系统环境，继续安装可能会发生未知错误。"
fi

# 2. 检查依赖 (Python3, ip)
echo "[1/4] 检查依赖包..."
NEED_OPKG=0
if ! command -v python3 >/dev/null 2>&1; then
    echo "[-] 未检测到 python3，准备安装..."
    NEED_OPKG=1
fi

if ! command -v ip >/dev/null 2>&1; then
    echo "[-] 未检测到 ip 命令 (ip-full)，准备安装..."
    NEED_OPKG=1
fi

if [ "$NEED_OPKG" -eq 1 ]; then
    echo "[*] 正在更新软件源并安装依赖 (opkg update && opkg install python3 python3-syslog ip-full)..."
    opkg update || true
    opkg install python3 python3-syslog ip-full || {
        echo "[!] 安装依赖失败，请检查路由器网络连接是否正常。"
        exit 1
    }
else
    echo "[+] 基础依赖 (Python3, ip) 检查通过！"
fi

# 3. 部署插件文件
echo "[2/4] 部署插件文件与服务..."
DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -d "$DIR/root" ]; then
    # 本地或仓库目录安装
    cp -r "$DIR/root/"* /
else
    # 远程一键安装 fallback：从 GitHub 仓库拉取最新文件
    echo "[*] 从 GitHub 远程拉取最新文件..."
    TMP_DIR="/tmp/sufe_auth_install_$$"
    mkdir -p "$TMP_DIR"
    RAW_BASE="https://raw.githubusercontent.com/pigzzz104/luci-app-sufe-auth/master/root"
    
    mkdir -p /etc/config /etc/init.d /usr/sbin /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi
    
    [ -f /etc/config/sufe_auth ] || curl -fsSL "$RAW_BASE/etc/config/sufe_auth" -o /etc/config/sufe_auth
    curl -fsSL "$RAW_BASE/etc/init.d/sufe_auth" -o /etc/init.d/sufe_auth
    curl -fsSL "$RAW_BASE/usr/sbin/sufe_auth" -o /usr/sbin/sufe_auth
    curl -fsSL "$RAW_BASE/usr/lib/lua/luci/controller/sufe_auth.lua" -o /usr/lib/lua/luci/controller/sufe_auth.lua
    curl -fsSL "$RAW_BASE/usr/lib/lua/luci/model/cbi/sufe_auth.lua" -o /usr/lib/lua/luci/model/cbi/sufe_auth.lua
    rm -rf "$TMP_DIR"
fi

# 赋予执行权限
chmod +x /etc/init.d/sufe_auth /usr/sbin/sufe_auth

# 4. 配置开机自启并刷新 LuCI 缓存
echo "[3/4] 启用服务并刷新 LuCI 界面缓存..."
/etc/init.d/sufe_auth enable
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

# 5. 提示完成
echo "[4/4] 安装完成！"
echo "=========================================================="
echo "  安装成功！"
echo "  1. 请登录路由器后台管理页面 (如 http://192.168.x.x)"
echo "  2. 进入菜单：【网络】 -> 【上财校园网认证】"
echo "  3. 填写您的卡号（例如 2023xxxxxx@cmcc）与密码，点击保存并应用即可！"
echo "=========================================================="
