export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 信息 App 是 arm64e 进程, 需要 arm64e 切片, 且必须用 macOS CI (Apple 原生工具链):
# Linux 工具链的 arm64e 注入系统进程时 objc readClass SIGBUS (NotesVideoBG v2.2-v3.1 的崩溃根因)。
export ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileSMS

include $(THEOS)/makefiles/common.mk

# ------------------------------------------------------------
# 授权签名密钥 (v1.9.0)
#   源码是公开仓库, 密钥只注入到编译产物里:
#     - CI: GitHub 仓库 Settings -> Secrets -> SVB_LICENSE_SECRET  (build.yml 传入)
#     - 本地: export SVB_LICENSE_SECRET=... 或 gmake SVB_LICENSE_SECRET=...
#   未注入时回退到内置兜底值 —— 兜底值在源码里可见, 仅供本地自测,
#   正式分发必须配置 Secret, 否则任何人拿到源码就能自己签发激活码。
#   签发端用同一密钥: tools/license_gen.py (读同名环境变量)
# ------------------------------------------------------------
ifeq ($(strip $(SVB_LICENSE_SECRET)),)
SVB_LICENSE_SECRET = SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET
endif
LICENSE_CFLAGS = -DSVB_LICENSE_SECRET='"$(SVB_LICENSE_SECRET)"'

# ------------------------------------------------------------
# 内置 Gitee(码云) 名单地址 (v10.1.0) —— 可选的"国内直连首选源"
#   配置后编译进插件: 客户端零配置也能走 Gitee 拉名单(国内不用挂代理)。
#     - CI: GitHub 仓库 Settings -> Secrets -> SVB_GITEE_URL
#           例 https://gitee.com/你的用户名/仓库名/raw/master/auth.json
#     - 未配置时: 插件只在自定义源 + GitHub 镜像里找; 客户端也可在
#       授权页长按自行填写该地址。
# ------------------------------------------------------------
ifeq ($(strip $(SVB_GITEE_URL)),)
GITEE_CFLAGS =
else
GITEE_CFLAGS = -DSVB_GITEE_URL='"$(SVB_GITEE_URL)"'
endif

# 实例 1: 主插件 (注入信息 App, 视频背景渲染)
TWEAK_NAME = SMSVideoBG
SMSVideoBG_FILES = Tweak.x SVBCommon.m SVBAuth.m
SMSVideoBG_FRAMEWORKS = UIKit AVFoundation CoreMedia
SMSVideoBG_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations $(LICENSE_CFLAGS) $(GITEE_CFLAGS)

include $(THEOS_MAKE_PATH)/tweak.mk

# 实例 2: 独立控制 App (v1.1 起取消设置面板: 面板加载进「设置」进程有闪退风险,
# 且用户偏好独立 App 控制, 功能完全等价)
APPLICATION_NAME = SMSVideoBGApp
SMSVideoBGApp_FILES = app/main.m app/AppDelegate.m SVBCommon.m SVBAuth.m
SMSVideoBGApp_FRAMEWORKS = UIKit AVFoundation AVKit CoreMedia
SMSVideoBGApp_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations $(LICENSE_CFLAGS) $(GITEE_CFLAGS)
SMSVideoBGApp_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk

# 自定义 Info.plist (显示名/URL Scheme/可替换图标声明) 进 .app 并重新签名
after-stage::
	$(ECHO_NOTHING)if [ -f Resources/Info.plist ] && [ -d "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app" ]; then cp Resources/Info.plist "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/Info.plist"; fi$(ECHO_END)
	$(ECHO_NOTHING)if [ -f Resources/CustomIcon.png ] && [ -d "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app" ]; then cp Resources/CustomIcon.png "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/CustomIcon.png"; fi$(ECHO_END)
	$(ECHO_NOTHING)if [ -f Resources/CustomIconB.png ] && [ -d "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app" ]; then cp Resources/CustomIconB.png "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/CustomIconB.png"; fi$(ECHO_END)
	$(ECHO_NOTHING)command -v ldid >/dev/null 2>&1 && [ -f "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/SMSVideoBGApp" ] && ldid -S "$(THEOS_STAGING_DIR)/SMSVideoBGApp.app/SMSVideoBGApp" || true$(ECHO_END)
