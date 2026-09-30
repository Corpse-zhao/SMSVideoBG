export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 信息 App 是 arm64e 进程, 需要 arm64e 切片, 且必须用 macOS CI (Apple 原生工具链):
# Linux 工具链的 arm64e 注入系统进程时 objc readClass SIGBUS (NotesVideoBG v2.2-v3.1 的崩溃根因)。
export ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileSMS

include $(THEOS)/makefiles/common.mk

# ------------------------------------------------------------
# 授权签名密钥 (v10.5.0: 两个插件统一)
#   源码是公开仓库, 密钥只注入到编译产物里:
#     - CI: GitHub 仓库 Settings -> Secrets -> VIDEOBG_LICENSE_SECRET
#           (信息版仓库与备忘录版仓库必须配**同一个值**)
#     - 本地: export VIDEOBG_LICENSE_SECRET=... 或 gmake VIDEOBG_LICENSE_SECRET=...
#   兼容旧名: 新名没配时自动回退读 SVB_LICENSE_SECRET。
#   未注入时回退到内置兜底值 —— 兜底值在源码里可见, 仅供本地自测,
#   正式分发必须配置 Secret, 否则任何人拿到源码就能自己签发激活码。
#   ★ 两边密钥相同 + 指纹算法相同 => 同一台设备算出同一个 H32 =>
#     靠授权串里的「产品位」决定这个码给哪个插件用 (all / sms / memos)。
# ------------------------------------------------------------
LICENSE_SECRET_RAW = $(VIDEOBG_LICENSE_SECRET)
ifeq ($(strip $(LICENSE_SECRET_RAW)),)
LICENSE_SECRET_RAW = $(SVB_LICENSE_SECRET)
endif
ifeq ($(strip $(LICENSE_SECRET_RAW)),)
LICENSE_SECRET_RAW = VIDEOBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET
endif
LICENSE_CFLAGS = -DVIDEOBG_LICENSE_SECRET='"$(LICENSE_SECRET_RAW)"'

# v10.3.0: 授权只走「离线授权串」, 插件端零网络请求 —— 原来的 Gitee/镜像名单
# 地址注入位(GITEE_CFLAGS)已随在线名单一起删除。

# 实例 1: 主插件 (注入信息 App, 视频背景渲染)
TWEAK_NAME = SMSVideoBG
SMSVideoBG_FILES = Tweak.x SVBCommon.m SVBAuth.m
SMSVideoBG_FRAMEWORKS = UIKit AVFoundation CoreMedia
SMSVideoBG_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations $(LICENSE_CFLAGS)

include $(THEOS_MAKE_PATH)/tweak.mk

# 实例 2: 独立控制 App (v1.1 起取消设置面板: 面板加载进「设置」进程有闪退风险,
# 且用户偏好独立 App 控制, 功能完全等价)
APPLICATION_NAME = SMSVideoBGApp
SMSVideoBGApp_FILES = app/main.m app/AppDelegate.m SVBCommon.m SVBAuth.m
SMSVideoBGApp_FRAMEWORKS = UIKit AVFoundation AVKit CoreMedia
SMSVideoBGApp_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations $(LICENSE_CFLAGS)
SMSVideoBGApp_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# 自定义 Info.plist (显示名/URL Scheme/可替换图标声明) 进 .app 并重新签名
after-stage::
	$(ECHO_NOTHING)if [ -f Resources/Info.plist ] && [ -d "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app" ]; then cp Resources/Info.plist "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/Info.plist"; fi$(ECHO_END)
	$(ECHO_NOTHING)if [ -f Resources/CustomIcon.png ] && [ -d "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app" ]; then cp Resources/CustomIcon.png "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/CustomIcon.png"; fi$(ECHO_END)
	$(ECHO_NOTHING)if [ -f Resources/CustomIconB.png ] && [ -d "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app" ]; then cp Resources/CustomIconB.png "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/CustomIconB.png"; fi$(ECHO_END)
	$(ECHO_NOTHING)command -v ldid >/dev/null 2>&1 && [ -f "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/SMSVideoBGApp" ] && ldid -S "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/SMSVideoBGApp" || true$(ECHO_END)
