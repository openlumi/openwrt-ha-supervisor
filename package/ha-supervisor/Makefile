include $(TOPDIR)/rules.mk

PKG_NAME:=ha-supervisor
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/ha-supervisor
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Minimal Home Assistant supervisor for OpenWrt
  PKGARCH:=all
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-math \
	+dockerd +docker +socat +uclient-fetch +libustream-mbedtls +ca-bundle
endef

define Package/ha-supervisor/conffiles
/etc/config/ha-supervisor
endef

define Build/Compile
endef

define Package/ha-supervisor/install
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d $(1)/usr/share/nftables.d/chain-pre/dstnat $(1)/usr/sbin $(1)/usr/share/ucode/supervisor $(1)/usr/share/ha-supervisor \
		$(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_BIN) ../../files/usr/sbin/ha-supervisor ../../files/usr/sbin/ha-supervisor-http $(1)/usr/sbin/
	$(INSTALL_DATA) ../../files/usr/share/ucode/supervisor/*.uc $(1)/usr/share/ucode/supervisor/
	$(INSTALL_DATA) ../../files/usr/share/ha-supervisor/catalog-*.json $(1)/usr/share/ha-supervisor/
	$(INSTALL_DATA) ../../files/usr/share/nftables.d/chain-pre/dstnat/90-ha-supervisor.nft $(1)/usr/share/nftables.d/chain-pre/dstnat/
	$(INSTALL_DATA) ../../files/lib/upgrade/keep.d/ha-supervisor $(1)/lib/upgrade/keep.d/
	$(INSTALL_CONF) ../../files/etc/config/ha-supervisor $(1)/etc/config/
	$(INSTALL_BIN) ../../files/etc/init.d/ha-supervisor $(1)/etc/init.d/
	$(INSTALL_BIN) ../../files/etc/uci-defaults/90-ha-supervisor $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,ha-supervisor))
