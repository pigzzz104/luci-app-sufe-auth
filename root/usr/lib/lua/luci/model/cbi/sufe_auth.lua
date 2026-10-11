local sys = require "luci.sys"
local uci = require "luci.model.uci".cursor()

local style_css = [[
<style>
/* 独立卡片化每一个账号节点容器 */
#cbi-sufe_auth-account .cbi-section-node {
    background: #ffffff !important;
    border: 1px solid #e2e8f0 !important;
    border-radius: 10px !important;
    padding: 16px 22px 8px 22px !important;
    margin-bottom: 24px !important;
    box-shadow: 0 2px 10px rgba(0, 0, 0, 0.04) !important;
    position: relative !important;
    transition: all 0.2s ease !important;
}

#cbi-sufe_auth-account .cbi-section-node:hover {
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.07) !important;
    border-color: #cbd5e1 !important;
}

/* 删除按钮右上角规范化 */
#cbi-sufe_auth-account .cbi-section-remove {
    float: right !important;
    margin-top: 12px !important;
    margin-right: 14px !important;
    margin-bottom: -36px !important;
    position: relative !important;
    z-index: 10 !important;
}

#cbi-sufe_auth-account .cbi-section-remove input {
    background-color: #ef4444 !important;
    color: #ffffff !important;
    border: none !important;
    border-radius: 6px !important;
    padding: 4px 12px !important;
    font-size: 12px !important;
    font-weight: bold !important;
    cursor: pointer !important;
    box-shadow: 0 2px 6px rgba(239, 68, 68, 0.2) !important;
}

#cbi-sufe_auth-account .cbi-section-remove input:hover {
    background-color: #dc2626 !important;
}

/* 账号卡片顶栏全宽展示 */
#cbi-sufe_auth-account div[id$="-_card_head"] {
    border-bottom: 1px solid #f1f5f9 !important;
    margin-bottom: 12px !important;
    padding-bottom: 8px !important;
}

#cbi-sufe_auth-account div[id$="-_card_head"] .cbi-value-title {
    display: none !important;
}

#cbi-sufe_auth-account div[id$="-_card_head"] .cbi-value-field {
    width: 100% !important;
    float: none !important;
    margin: 0 !important;
    padding: 0 !important;
}

/* 表单行间距 */
#cbi-sufe_auth-account .cbi-value {
    padding: 10px 0 !important;
}
</style>
]]

local m = Map("sufe_auth", translate("上海财经大学 校园网认证"), style_css)

-- 标准化状态渲染函数：保证全界面提示语风格、色彩与布局严格统一
local function render_status(state_code, extra_info)
    local configs = {
        running_online = {
            color = "#52c41a",
            border = "#52c41a",
            badge = "● 正在运行",
            desc = "已完成认证"
        },
        running_connecting = {
            color = "#1890ff",
            border = "#1890ff",
            badge = "● 正在连接",
            desc = "已启动握手，等待获取 IP (DHCP)..."
        },
        stopped = {
            color = "#ff4d4f",
            border = "#ff4d4f",
            badge = "● 未运行",
            desc = "认证服务未启动"
        },
        unconfigured = {
            color = "#fa8c16",
            border = "#fa8c16",
            badge = "● 待配置",
            desc = "尚未填写上网账号与密码"
        },
        disabled = {
            color = "#8c8c8c",
            border = "#8c8c8c",
            badge = "● 已禁用",
            desc = "该线路已在设置中关闭"
        }
    }
    local cfg = configs[state_code] or configs.stopped
    local text = string.format("<span style='color:%s; font-weight:bold;'>%s</span>", cfg.color, cfg.badge)
    local detail = extra_info or cfg.desc
    if detail and #detail > 0 then
        text = text .. " &nbsp;|&nbsp; " .. detail
    end
    return text, cfg.border
end

-- 获取特定账号实例的实时运行状态
local function get_instance_status(section_name, ifname, username, password, enable)
    if enable == "0" or enable == 0 then
        if not username or #username == 0 or not password or #password == 0 then
            return render_status("disabled", "未填写账号（已停用）")
        else
            return render_status("disabled", "该线路已在设置中关闭")
        end
    end

    if not username or #username == 0 or not password or #password == 0 then
        return render_status("unconfigured", "尚未填写上网账号与密码")
    end

    local is_running = false
    pcall(function()
        local ubus = require("ubus").connect()
        if ubus then
            local res = ubus:call("service", "list", { name = "sufe_auth" })
            if res and res.sufe_auth and res.sufe_auth.instances then
                local inst = res.sufe_auth.instances["sufe_auth_" .. section_name]
                if inst and inst.running then
                    is_running = true
                end
            end
            ubus:close()
        end
    end)

    if is_running then
        local ip = ""
        if ifname and #ifname > 0 then
            ip = sys.exec(string.format("ip -4 addr show %s 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2", ifname)):gsub("\n", "")
        end
        if ip and #ip > 0 then
            local detail = "已完成认证 &nbsp;|&nbsp; 内网 IP: <span style='font-weight:bold; color:#1890ff;'>" .. ip .. "</span>"
            return render_status("running_online", detail)
        else
            return render_status("running_connecting")
        end
    else
        return render_status("stopped")
    end
end

-- 顶部：多线路运行状态总览
local s_status = m:section(SimpleSection, translate("运行状态总览"))
local status_html = s_status:option(DummyValue, "_overview")
status_html.rawhtml = true

function status_html.cfgvalue()
    local cur = require("luci.model.uci").cursor()
    local accounts = {}
    cur:foreach("sufe_auth", "account", function(s)
        table.insert(accounts, s)
    end)
    -- 兼容旧版单个 config 节点
    if #accounts == 0 then
        cur:foreach("sufe_auth", "sufe_auth", function(s)
            table.insert(accounts, s)
        end)
    end

    if #accounts == 0 then
        return "<span style='color:#8c8c8c; font-style:italic;'>暂未配置任何认证账号，请在下方点击添加。</span>"
    end

    local html = "<div style='display:flex; flex-direction:column; gap:8px; padding:4px 0;'>"
    for _, acc in ipairs(accounts) do
        local sec_name = acc[".name"] or ""
        local label = acc.label or sec_name
        local ifname = acc.ifname or "eth1"
        local network = acc.network or "wan"
        local username = acc.username or ""
        local password = acc.password or ""
        local enable = acc.enable or "1"

        local status_text, border_color = get_instance_status(sec_name, ifname, username, password, enable)

        html = html .. string.format([[
            <div style='background:rgba(0,0,0,0.02); border-left:4px solid %s; padding:10px 14px; border-radius:4px; display:flex; justify-content:space-between; align-items:center; flex-wrap:wrap; gap:8px;'>
                <div>
                    <strong style='font-size:14px;'>%s</strong> &nbsp;
                    <code style='font-size:12px; color:#555; background:rgba(0,0,0,0.06); padding:2px 6px; border-radius:3px;'>%s / %s</code>
                </div>
                <div style='font-size:13px;'>
                    %s
                </div>
            </div>
        ]], border_color, label, ifname, network, status_text)
    end
    html = html .. "</div>"
    return html
end

-- 账号管理列表
local s = m:section(TypedSection, "account", translate("账号线路配置"))
s.anonymous = true
s.addremove = true

-- 卡片头部横梁 (无 emoji 图标)
local card_head = s:option(DummyValue, "_card_head", "")
card_head.rawhtml = true
function card_head.cfgvalue(self, section)
    local label = m:get(section, "label") or ""
    if not label or #label == 0 then
        label = (section == "wan") and "主校园网 (WAN1)" or "校园网副线路"
    end
    return string.format("<div style='font-size:15px; font-weight:600; color:#1e293b; padding:2px 0;'>%s</div>", label)
end

-- 运行状态 (卡片内)
local cur_status = s:option(DummyValue, "_status", translate("当前状态"))
cur_status.rawhtml = true
function cur_status.cfgvalue(self, section)
    local ifname = m:get(section, "ifname") or "eth1"
    local username = m:get(section, "username") or ""
    local password = m:get(section, "password") or ""
    local enable = m:get(section, "enable")

    local status_text, _ = get_instance_status(section, ifname, username, password, enable)
    return status_text
end

-- 备注名称
local label = s:option(Value, "label", translate("账号备注"), translate("自定义标签，如：我的移动、室友电信"))
label.rmempty = true
label.default = "校园网账号"

-- 启用开关
local enable = s:option(Flag, "enable", translate("启用"))
enable.rmempty = false
enable.default = 1

-- 物理网卡
local ifname = s:option(Value, "ifname", translate("物理网卡"), translate("该线路对应的物理网卡设备（主 WAN 口为 eth1，LAN 划分后为 eth0.2 / eth0.3）"))
ifname.default = "eth1"
ifname.rmempty = false
ifname:value("eth1", "eth1 (WAN口)")
ifname:value("eth0.2", "eth0.2 (LAN1口)")
ifname:value("eth0.3", "eth0.3 (LAN2口)")
ifname:value("eth0.4", "eth0.4 (LAN3口)")
ifname:value("macvlan0", "macvlan0 (虚拟口)")

-- 逻辑网络接口
local network = s:option(Value, "network", translate("网络接口"), translate("对应的 OpenWrt 接口名称（认证成功后触发该接口 DHCP 获取 IP）"))
network.default = "wan"
network.rmempty = false
network:value("wan", "wan (主WAN)")
network:value("wan2", "wan2 (第二WAN)")
network:value("wan3", "wan3 (第三WAN)")
network:value("wan4", "wan4 (第四WAN)")

-- 用户名
local username = s:option(Value, "username", translate("上网账号"), translate("校园网账号带运营商后缀，如 卡号@cmcc, 卡号@tel, 卡号@cnc"))
username.placeholder = "例如 2023xxxxxx@cmcc"
username.rmempty = true

-- 密码
local password = s:option(Value, "password", translate("上网密码"))
password.password = true
password.rmempty = true

-- MAC 地址
local mac = s:option(Value, "mac", translate("物理 MAC"), translate("学校绑定的物理 MAC 地址。留空则直接使用网卡自带 MAC"))
mac.placeholder = "例如 00:11:22:33:44:55 (可选)"
mac.rmempty = true

-- 交换机 MAC
local switch_mac = s:option(Value, "switch_mac", translate("交换机 MAC"), translate("上级交换机单播认证 MAC 地址，留空默认 58:ae:a8:88:0c:31"))
switch_mac.default = "58:ae:a8:88:0c:31"
switch_mac.rmempty = true

local function restart_auth(self)
    sys.call("/etc/init.d/sufe_auth restart >/dev/null 2>&1")
end

m.on_after_save = restart_auth
m.on_after_commit = restart_auth

return m
