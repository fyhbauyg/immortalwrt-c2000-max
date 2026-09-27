include $(TOPDIR)/rules.mk

LUCI_TITLE:=C2000MAX Theme (daisyUI)
LUCI_DEPENDS:=+luci-base +luci-theme-bootstrap
LUCI_MINIFY_CSS:=0
PKG_LICENSE:=Apache-2.0 MIT
PKG_VERSION:=1.2.0

define Package/luci-theme-c2000max/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ "$$(uci -q get luci.main.mediaurlbase)" = '/luci-static/c2000max' ]; then
		uci -q set luci.main.mediaurlbase='/luci-static/bootstrap'
	fi
	uci -q delete luci.themes.C2000MAX
	uci commit luci
}
endef

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
