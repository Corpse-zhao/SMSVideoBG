#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// ============================================================
// 信息视频背景 (SMSVideoBG) - 共享核心
// 作者: 板栗仁 | rootless / roothide / ElleKit / iOS 16.x
//
// v1.3 关键设计: 素材根「宿主容器优先」
//   roothide 把越狱根藏在 .jbroot-XXXX 随机路径下, 信息App 是系统沙盒
//   App, 其进程内既可能看不到 /var/jb, 也可能读不到 /var/mobile/Documents。
//   唯一必然可读写的只有「信息App 自己的数据容器」:
//       <信息App容器>/Library/SMSVideoBG/<界面>/
//   因此:
//     - tweak 侧 以自身容器为主根 (100% 可读写 -> 心跳/日志/素材必达)
//     - 控制App 侧 自动定位 MobileSMS 数据容器, 导入时把素材「多根齐写」
//   同时保留 jbroot / Documents 等共享根作为兜底, 用户放哪都能被扫到。
// ============================================================

#define SVB_VERSION @"1.7.3"
#define SVB_SUITE @"com.nvb.smsvideobg"
#define SVB_DARWIN_NOTE "com.nvb.smsvideobg/prefs.changed"
#define SVB_MEDIA_DIR_NAME @"SMSVideoBG"
#define SVB_APP_BUNDLE_ID @"com.nvb.smsvideobg.app"
#define SVB_URL_SCHEME @"smsvideobg"

// 目标进程 = 苹果「信息」
#define SVB_SMS_BUNDLE_ID @"com.apple.MobileSMS"

// 插件侧最可靠的根目录 (jbroot: 越狱进程必可访问)
NSString *SVBJBMediaDirectory(void);

// 全部候选素材根, 顺序 = 优先级 (v1.3: 容器根在前)
NSArray<NSString *> *SVBRootCandidates(void);
// 清空根目录缓存 (控制App 在报告页/导入前调用, 以便重新定位信息App 容器)
void SVBRefreshMediaRoots(void);

// 当前进程自身数据容器内的素材目录 (tweak 侧 100% 可读写)
NSString *SVBAppContainerMediaDirectory(void);
// 查找指定 bundleId 的数据容器真实路径, 找不到返回 nil (需越权进程)
NSString *SVBFindAppDataContainer(NSString *bundleId);
// 当前进程宿主 bundle id (信息App = com.apple.MobileSMS)
NSString *SVBHostBundleIdentifier(void);
// 根的短标签 (诊断/横幅展示用)
NSString *SVBRootLabel(NSString *root);
// 目录可写性探测 (创建目录 + 写探针文件), 供控制App 诊断页使用
BOOL SVBDirWritablePath(NSString *dir);

// 注入可视化横幅: 挂在宿主 App 窗口顶部, 点按隐藏
void SVBShowDebugBanner(NSString *text);

extern NSString * const SVBContextAll;      // 所有信息
extern NSString * const SVBContextKnown;    // 已知发件人
extern NSString * const SVBContextUnknown;  // 未知发件人
extern NSString * const SVBContextUnread;   // 未读信息
extern NSString * const SVBContextJunk;     // 垃圾信息
extern NSString * const SVBContextDeleted;  // 最近删除
extern NSString * const SVBContextChat;     // 对话详情

// 7 类界面定义: @[key, 标题, 说明]
NSArray<NSArray<NSString *> *> *SVBContextDefinitions(void);

@interface SVBManager : NSObject
+ (instancetype)shared;
- (NSUserDefaults *)prefs;

#pragma mark 配置 (文件 + prefs 双写, 跨沙盒必达)
- (NSDictionary *)effectiveConfig;
- (id)configValueForKey:(NSString *)key;
- (void)setConfigValue:(id)value forKey:(NSString *)key;

- (BOOL)masterEnabled;
// 全局效果 (0~1)
- (CGFloat)globalAlpha;
- (CGFloat)globalBlur;
- (CGFloat)globalVolume;
// v1.6: 每个界面独立的效果参数 (未单独设置时回退到全局值)
- (CGFloat)alphaForContext:(NSString *)ctx;
- (CGFloat)blurForContext:(NSString *)ctx;
- (CGFloat)volumeForContext:(NSString *)ctx;
- (CGFloat)bubbleAlphaForContext:(NSString *)ctx;
// v1.6: 界面离开时暂停该界面的播放器, 回来时恢复 (防多界面视频声音互串)
- (void)setContextActive:(BOOL)active context:(NSString *)ctx;
// 界面开关
- (BOOL)isEnabledForContext:(NSString *)ctx;
- (void)setEnabled:(BOOL)on forContext:(NSString *)ctx;
// 调试横幅开关 (默认开)
- (BOOL)debugBannerEnabled;

#pragma mark 素材目录 (多根聚合 / 多根齐写)
- (NSArray<NSString *> *)mediaRoots;                            // 实际存在且可读的根
- (NSArray<NSString *> *)writableRoots;                         // 实际可写的根
- (NSString *)mediaDirectory;                                   // 导入写入用 (第一个可写)
- (NSString *)contextDirectory:(NSString *)ctx;                 // mediaDirectory/ctx
- (NSArray<NSString *> *)videosForContext:(NSString *)ctx;      // 文件名列表(聚合+去重)
- (NSString *)activeVideoNameForContext:(NSString *)ctx;        // 当前选用文件名
- (NSString *)activeVideoPathForContext:(NSString *)ctx;        // 完整路径(不存在返回 nil)
- (void)setActiveVideoName:(NSString *)name forContext:(NSString *)ctx;
- (NSString *)importVideoFromFile:(NSURL *)srcURL toContext:(NSString *)ctx error:(NSError **)error;
- (void)deleteVideoName:(NSString *)name forContext:(NSString *)ctx;
// 素材自愈迁移: 把其它可读根里的素材搬进主根 (信息App 容器), 让旧导入立即生效
- (void)migrateMediaIntoPrimaryRoot;

#pragma mark 背景应用
- (AVPlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force;
- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx;
- (void)detachFromViewController:(UIViewController *)vc;   // 页面离开时摘除背景
- (void)refreshVisibleBackgrounds;
- (void)postChangeNotification;

#pragma mark 诊断
- (void)log:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2);   // 多通道 (全部可写根)
- (void)logClassOnce:(NSString *)name context:(NSString *)ctx;
- (void)writeHeartbeat:(NSString *)tag;                      // 插件存活心跳 (宿主App 进程)
- (NSString *)readHeartbeat;                                 // 控制App 侧读取
- (NSString *)readTweakLog;                                  // 控制App 侧读插件日志
- (NSString *)injectionReport;                               // 注入自检 (dylib / filter / 容器)
- (NSString *)rootsSummaryForContext:(NSString *)ctx;        // 各根素材计数摘要
- (NSString *)bannerTextForContext:(NSString *)ctx;          // 注入横幅文案
@end

@interface SVBVideoBackgroundView : UIView
@property (nonatomic, copy) NSString *contextKey;
@property (nonatomic, strong) AVPlayerLayer *videoLayer;
- (instancetype)initWithFrame:(CGRect)frame contextKey:(NSString *)key;
- (void)configure;
@end
