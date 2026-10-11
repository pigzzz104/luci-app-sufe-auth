include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sufe-auth
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=pigzzz104
PKG_LICENSE:=MIT

LUCI_TITLE:=LuCI support for SUFE Campus Network 802.1X Multi-Account Auth
LUCI_DEPENDS:=+python3 +python3-syslog +ip-full
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
