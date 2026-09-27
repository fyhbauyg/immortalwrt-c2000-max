# C2000MAX CPE theme, derived from luci-theme-argon (Apache-2.0).
include $(TOPDIR)/rules.mk

LUCI_TITLE:=C2000MAX CPE Theme (Argon + daisyUI)
LUCI_DEPENDS:=+luci-base +luci-theme-argon
LUCI_MINIFY_CSS:=0
PKG_LICENSE:=Apache-2.0 MIT ISC
PKG_VERSION:=2.0.6

define Package/luci-theme-cpeargon/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ "$$(uci -q get luci.main.mediaurlbase)" = '/luci-static/cpeargon' ]; then
		uci -q set luci.main.mediaurlbase='/luci-static/argon'
	fi
	uci -q delete luci.themes.CPEArgon
	uci commit luci
}
endef

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
