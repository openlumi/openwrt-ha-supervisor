include $(TOPDIR)/rules.mk

PKG_NAME:=owrt-supervisor
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/owrt-supervisor
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Minimal Home Assistant supervisor for OpenWrt
  PKGARCH:=all
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-math \
	+dockerd +docker +socat +uclient-fetch +libustream-mbedtls +ca-bundle
endef

define Package/owrt-supervisor/conffiles
/etc/config/owrt-supervisor
endef

define Build/Compile
endef

define Package/owrt-supervisor/install
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d $(1)/usr/sbin $(1)/usr/share/ucode/supervisor $(1)/usr/share/owrt-supervisor \
		$(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_BIN) ../../files/usr/sbin/owrt-supervisor ../../files/usr/sbin/owrt-supervisor-http $(1)/usr/sbin/
	$(INSTALL_DATA) ../../files/usr/share/ucode/supervisor/*.uc $(1)/usr/share/ucode/supervisor/
	$(INSTALL_DATA) ../../files/usr/share/owrt-supervisor/catalog.json $(1)/usr/share/owrt-supervisor/
	$(INSTALL_DATA) ../../files/lib/upgrade/keep.d/owrt-supervisor $(1)/lib/upgrade/keep.d/
	$(INSTALL_CONF) ../../files/etc/config/owrt-supervisor $(1)/etc/config/
	$(INSTALL_BIN) ../../files/etc/init.d/owrt-supervisor $(1)/etc/init.d/
	$(INSTALL_BIN) ../../files/etc/uci-defaults/90-owrt-supervisor $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,owrt-supervisor))
