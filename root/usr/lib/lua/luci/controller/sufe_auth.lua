module("luci.controller.sufe_auth", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/sufe_auth") then
        return
    end

    local page = entry({"admin", "network", "sufe_auth"}, cbi("sufe_auth"), _("上财校园网认证"), 30)
    page.dependent = true
end
