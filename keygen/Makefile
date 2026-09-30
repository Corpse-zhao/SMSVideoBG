export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 独立签发 App, 不注入系统进程, arm64 切片即可
export ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# ------------------------------------------------------------
# 签名密钥 (v2.4.0: 两个插件统一)
#   与主插件、备忘录版共用同一个 GitHub Secret (VIDEOBG_LICENSE_SECRET)。
#   三边密钥一致 + 指纹算法一致, 签出的码才能被插件识别;
#   具体给哪个插件用, 由授权串里的「产品位」决定 (通用 / 仅信息 / 仅备忘录)。
#   兼容旧名: 新名没配时自动回退读 SVB_LICENSE_SECRET。
# ------------------------------------------------------------
LICENSE_SECRET_RAW = $(VIDEOBG_LICENSE_SECRET)
ifeq ($(strip $(LICENSE_SECRET_RAW)),)
LICENSE_SECRET_RAW = $(SVB_LICENSE_SECRET)
endif
ifeq ($(strip $(LICENSE_SECRET_RAW)),)
LICENSE_SECRET_RAW = VIDEOBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET
endif
KEYGEN_CFLAGS = -DVIDEOBG_LICENSE_SECRET='"$(LICENSE_SECRET_RAW)"'

APPLICATION_NAME = SVBKeyGen
SVBKeyGen_FILES = main.m KGAppDelegate.m KGAuth.m
SVBKeyGen_FRAMEWORKS = UIKit
SVBKeyGen_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations $(KEYGEN_CFLAGS)
SVBKeyGen_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# 覆盖 Theos 生成的 Info.plist (中文名/图标声明) + ldid 伪签名
after-stage::
	$(ECHO_NOTHING)bash stage_extras.sh "$(THEOS_STAGING_DIR)"$(ECHO_END)
