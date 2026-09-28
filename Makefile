export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 信息 App 是 arm64e 进程, 需要 arm64e 切片, 且必须用 macOS CI (Apple 原生工具链):
# Linux 工具链的 arm64e 注入系统进程时 objc readClass SIGBUS (NotesVideoBG v2.2-v3.1 的崩溃根因)。
export ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileSMS

include $(THEOS)/makefiles/common.mk

# 实例 1: 主插件 (注入信息 App, 视频背景渲染)
TWEAK_NAME = SMSVideoBG
SMSVideoBG_FILES = Tweak.x SVBCommon.m
SMSVideoBG_FRAMEWORKS = UIKit AVFoundation CoreMedia
SMSVideoBG_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

# 实例 2: 独立控制 App (v1.1 起取消设置面板: 面板加载进「设置」进程有闪退风险,
# 且用户偏好独立 App 控制, 功能完全等价)
APPLICATION_NAME = SMSVideoBGApp
SMSVideoBGApp_FILES = app/main.m app/AppDelegate.m SVBCommon.m
SMSVideoBGApp_FRAMEWORKS = UIKit AVFoundation AVKit CoreMedia
SMSVideoBGApp_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations
SMSVideoBGApp_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# 自定义 Info.plist (显示名/URL Scheme) 进 .app 并重新签名
after-stage::
	$(ECHO_NOTHING)if [ -f Resources/Info.plist ] && [ -d "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app" ]; then cp Resources/Info.plist "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/Info.plist"; fi$(ECHO_END)
	$(ECHO_NOTHING)command -v ldid >/dev/null 2>&1 && [ -f "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/SMSVideoBGApp" ] && ldid -S "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/SMSVideoBGApp" || true$(ECHO_END)
