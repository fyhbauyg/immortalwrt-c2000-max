local uci = require "luci.model.uci".cursor()

-- config
m = Map("accelerator")
m.title = "雷神加速器"
m.description = "雷神加速器已适配当前固件的 fw4/nft 防火墙，使用官方 OpenWrt 引擎 1.2.2.52、iptables 兼容后端和 TUN 模式。设备绑定与加速状态请在雷神 APP 中管理。雷神运行时暂停硬件 NAT，关闭服务后恢复原设置。服务默认关闭；启用前请先停用其他透明代理服务，避免路由冲突。"

s = m:section(TypedSection, "system")
s.addremove = false
s.anonymous = true

enable = s:option(Flag, "enabled", "启用雷神加速器")
enable.rmempty = false
enable.default = 0

mode = s:option(DummyValue, "_mode", "运行模式")
mode.rawhtml = true
mode.cfgvalue = function()
    return "<strong>TUN（独立隧道）</strong>"
end

m:section(SimpleSection).template = "leigod/service"

return m
