include $(TOPDIR)/rules.mk

LUCI_TITLE:=CPE 37 theme for C2000MAX
LUCI_DEPENDS:=+luci-base +luci-theme-bootstrap
LUCI_MINIFY_CSS:=0
PKG_LICENSE:=Apache-2.0
PKG_VERSION:=1.0.1

define Package/luci-theme-cpe37/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ "$$(uci -q get luci.main.mediaurlbase)" = '/luci-static/cpe37' ]; then
		uci -q set luci.main.mediaurlbase='/luci-static/bootstrap'
	fi
	uci -q delete luci.themes.CPE37
	uci commit luci
}
endef

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
