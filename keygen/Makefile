export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 独立签发 App, 不注入系统进程, arm64 切片即可
export ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# ------------------------------------------------------------
# 板栗 v3.0.0 —— 信息/备忘录 两版统一授权签发
# 签名密钥: 与两版插件共用同一个 GitHub Secret (VIDEOBG_LICENSE_SECRET)。
# 两边密钥一致, 签发的激活码才能被插件识别。
# ------------------------------------------------------------
ifeq ($(strip $(VIDEOBG_LICENSE_SECRET)),)
VIDEOBG_LICENSE_SECRET = VIDEOBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET
endif
KEYGEN_CFLAGS = -DVIDEOBG_LICENSE_SECRET='"$(VIDEOBG_LICENSE_SECRET)"'

APPLICATION_NAME = BanliKeyGen
BanliKeyGen_FILES = main.m KGAppDelegate.m KGAuth.m
BanliKeyGen_FRAMEWORKS = UIKit
BanliKeyGen_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations $(KEYGEN_CFLAGS)
BanliKeyGen_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# 覆盖 Theos 生成的 Info.plist (中文名/图标声明) + ldid 伪签名
after-stage::
	$(ECHO_NOTHING)bash stage_extras.sh "$(THEOS_STAGING_DIR)"$(ECHO_END)
