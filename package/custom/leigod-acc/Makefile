#
# Copyright (C) 2015-2016 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v3.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=leigod-acc
PKG_VERSION:=2026.09.27
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

# The vendor executable is a packed, sectionless AArch64 ELF.  The generic
# sstrip pass truncates its opaque trailer, so preserve it byte-for-byte.
RSTRIP:=:

# kmod-netem is enabled in the image for optional delay simulation;
# core acceleration does not require replacing a running device kernel.
define Package/$(PKG_NAME)
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Powerful Leigod Game Accelerater
	DEPENDS:=@aarch64 +libpcap +nftables +kmod-nft-tproxy +kmod-tun +tc-full +curl
	URL:=https://www.leigod.com/
endef

define Package/$(PKG_NAME)/description
leigod-acc is a powerful game accelerater
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/bin
	cp ./files/acc-gw.router.arm64 $(PKG_BUILD_DIR)/bin/acc-gw.router.arm64
	chmod +x $(PKG_BUILD_DIR)/bin/acc-gw.router.arm64
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/sbin/leigod
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/acc-gw.router.arm64 $(1)/usr/sbin/leigod/acc-gw.router.arm64
	$(INSTALL_DATA) ./files/version $(1)/usr/sbin/leigod/version
	$(INSTALL_DATA) ./files/ipdatacloud_country.xdb $(1)/usr/sbin/leigod/ipdatacloud_country.xdb
	$(INSTALL_DIR) $(1)/etc/config
	$(LN) /usr/sbin/leigod/ipdatacloud_country.xdb $(1)/etc/config/ipdatacloud_country.xdb
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
