export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 独立签发 App, 不注入系统进程, arm64 切片即可
export ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# ------------------------------------------------------------
# 签名密钥: 与主插件共用同一 GitHub Secret (SVB_LICENSE_SECRET)。
# 两边密钥一致, 签发的激活码才能被插件识别。
# ------------------------------------------------------------
ifeq ($(strip $(SVB_LICENSE_SECRET)),)
SVB_LICENSE_SECRET = SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET
endif
KEYGEN_CFLAGS = -DSVB_LICENSE_SECRET='"$(SVB_LICENSE_SECRET)"'

APPLICATION_NAME = SVBKeyGen
SVBKeyGen_FILES = main.m KGAppDelegate.m KGAuth.m
SVBKeyGen_FRAMEWORKS = UIKit
SVBKeyGen_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations $(KEYGEN_CFLAGS)
SVBKeyGen_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# 覆盖 Theos 生成的 Info.plist (中文名/图标声明) + ldid 伪签名
after-stage::
	$(ECHO_NOTHING)bash stage_extras.sh "$(THEOS_STAGING_DIR)"$(ECHO_END)
