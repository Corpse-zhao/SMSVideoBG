#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

@class SVBVideoBackgroundView;   // 前向声明 (SVBManager 接口里要引用, 完整定义在本文件末尾)

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

// v11.0.0: 双宿主版 —— 同一个插件同时接管「信息」与「备忘录」:
//   - 备忘录(com.apple.mobilenotes)的 7 类界面语境见下方 NVB 常量;
//   - 控制App 首页可切「信息 / 备忘录」两个管理页, 各自独立开关;
//   - 备忘录素材根 = 备忘录App 数据容器 (控制App 双容器齐写)。
#define SVB_VERSION @"11.0.4"
#define SVB_SUITE @"com.nvb.smsvideobg"
#define SVB_DARWIN_NOTE "com.nvb.smsvideobg/prefs.changed"
#define SVB_MEDIA_DIR_NAME @"SMSVideoBG"

// ------------------------------------------------------------
// 统一素材路径 (v10.4.0)
//   用户只认这一个文件夹: /var/mobile/信息视频背景素材/板栗仁/
//   v10.4.0 起不再分界面子目录 —— 所有界面 (主页面/所有信息/对话详情…)
//   共用这一个文件夹里的同一批视频, 每个界面单独记住自己选了哪个文件和效果。
//   它是「软链」—— 真实文件仍然躺在信息App 数据容器里
//   (<信息App容器>/Library/SMSVideoBG/), 因为沙盒宿主进程只能读容器,
//   读不到 /var/mobile 下的普通目录。软链让 Filza 里看到的路径就是这一条,
//   两边指向同一份物理文件, 放哪都生效 (改的都是同一批文件)。
// ------------------------------------------------------------
#define SVB_AUTHOR_NAME @"板栗仁"
#define SVB_MEDIA_FRIENDLY_PARENT @"/var/mobile/信息视频背景素材"
#define SVB_APP_BUNDLE_ID @"com.nvb.smsvideobg.app"
#define SVB_URL_SCHEME @"smsvideobg"

// 目标进程 = 苹果「信息」/ 苹果「备忘录」(v11.0.0 双宿主)
#define SVB_SMS_BUNDLE_ID @"com.apple.MobileSMS"
#define SVB_NOTES_BUNDLE_ID @"com.apple.mobilenotes"

// 插件侧最可靠的根目录 (jbroot: 越狱进程必可访问)
NSString *SVBJBMediaDirectory(void);

// ---- 统一素材路径 (v10.3.0): 用户只看/只用这一条 ----
// /var/mobile/信息视频背景素材/板栗仁  (软链 -> 信息App 容器内的真实素材根)
NSString *SVBMediaFriendlyRoot(void);
// 统一素材路径 (v10.4.0 起不分界面, 恒返回 SVBMediaFriendlyRoot();
// ctx 参数保留只为兼容旧调用点)
NSString *SVBMediaFriendlyPathForContext(NSString *ctx);
// 建好统一素材路径 (父目录 + 软链) 并保证指向真实素材根。
// 若该路径已存在一个**真目录**(用户早就往那儿放过素材), 会先把里面的视频
// 搬进真实素材根, 再把原目录改名备份 (绝不删除), 然后换成软链。
// detail 回传人话结果/失败原因。控制App 启动时、postinst 里都会调。
BOOL SVBEnsureFriendlyMediaPath(NSString **detail);
// 在 Filza 中打开某个路径 (没装 Filza 时退回复制路径到剪贴板)。
// message 回传提示文案。必须在主线程调用。
BOOL SVBOpenPathInFilza(NSString *path, NSString **message);

// v10.4.0 运维文件治理 (插件 %ctor 与控制App 启动时各跑一次):
//   ① 旧名杂项 (_config.plist/_tweak_alive/_tweak.log/_app_probe) 改名到点前缀
//      新名或删除 —— Filza 里素材文件夹只剩视频, 不再有一堆下划线文件;
//   ② 诊断日志/探针超过 3 天自动删除 (「诊断报告不要一直保留」);
//   ③ 旧版按界面分的子目录摊平: 视频上移到素材根, 空目录删除。
void SVBCleanupHousekeeping(void);

// v11.0.0: 双容器素材同步 (仅控制App 有意义 —— 两个容器根都可写):
// 把每个可写根里的视频补拷到其它可写根, 保证信息App 与备忘录进程
// 各自的容器里都有全量素材 (Filza 只往一个软链里丢文件也能两边生效)。
NSInteger SVBSyncMediaAcrossRoots(void);

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
// v1.9.0: 忽略「诊断横幅」开关强制显示 (未授权提示用)
void SVBShowDebugBannerForce(NSString *text);

extern NSString * const SVBContextMain;     // 主页面 (信息App 根页: 过滤器列表)
extern NSString * const SVBContextAll;      // 所有信息
extern NSString * const SVBContextKnown;    // 已知发件人
extern NSString * const SVBContextUnknown;  // 未知发件人
extern NSString * const SVBContextUnread;   // 未读信息
extern NSString * const SVBContextJunk;     // 垃圾信息
extern NSString * const SVBContextDeleted;  // 最近删除
extern NSString * const SVBContextChat;     // 对话详情

// 7 类界面定义: @[key, 标题, 说明]
NSArray<NSArray<NSString *> *> *SVBContextDefinitions(void);

// ---- v11.0.0 备忘录语境 (com.apple.mobilenotes, IC* 私有类) ----
// v11.0.4: 按用户真机页面重命名 —— 首页/文件夹/内部页/笔记/搜索一下/多多创新
extern NSString * const SVBContextNBody;      // 「内部页」点开某条备忘录后的浏览界面
extern NSString * const SVBContextNEdit;      // 「笔记」右下角新建笔记进入的编辑界面 (v11.0.4 新增)
extern NSString * const SVBContextNList;      // 「文件夹」点进 所有iCloud/各文件夹 后的列表页
extern NSString * const SVBContextNFolder;    // 「首页」打开备忘录看到的第一屏
extern NSString * const SVBContextNGallery;   // 「画廊」缩略图视图
extern NSString * const SVBContextNSearch;    // 「搜索一下」搜索页
extern NSString * const SVBContextNPopup;     // 「多多创新」左下角新建文件夹等弹出的面板 (v11.0.4 新增)
extern NSString * const SVBContextNRecent;    // 「最近删除」
extern NSString * const SVBContextNInternal;  // 「其它内部页」兜底 (近似全屏的 IC* 页)

// 备忘录 7 类界面定义: @[key, 标题, 说明]
NSArray<NSArray<NSString *> *> *SVBNotesContextDefinitions(void);
// 信息 + 备忘录 全部语境定义 (运维/迁移遍历用)
NSArray<NSArray<NSString *> *> *SVBAllContextDefinitions(void);

// 当前宿主进程是否为备忘录 (tweak 侧判进程用)
BOOL SVBIsNotesHostProcess(void);

// 备忘录统一素材路径: /var/mobile/信息视频背景素材/备忘录
// (软链 -> 备忘录App 数据容器内的真实素材根; 定位不到容器时返回路径本身)
NSString *SVBNotesFriendlyRoot(void);

@interface SVBManager : NSObject
+ (instancetype)shared;
- (NSUserDefaults *)prefs;

#pragma mark 配置 (文件 + prefs 双写, 跨沙盒必达)
- (NSDictionary *)effectiveConfig;
- (id)configValueForKey:(NSString *)key;
- (void)setConfigValue:(id)value forKey:(NSString *)key;

- (BOOL)masterEnabled;
// v11.0.0: 备忘录总开关 (与信息总开关独立, 默认关 —— 需在控制App 备忘录页打开)
- (BOOL)notesMasterEnabled;
// v11.0.1: 本进程当前是否有「挂载且未隐藏」的视频背景视图 (0.5s 缓存) ——
// 备忘录清扫 gate: 没有可见背景时绝不清白卡, 避免页面露黑底
- (BOOL)hasVisibleBackgroundViews;
// v11.0.2: 暂停除指定语境外的全部播放器 (备忘录防串音)
- (void)pauseAllPlayersExcept:(NSString *)ctx;
// v11.0.3: 预载播放器 (后台建好即暂停, 进页面零等待)
- (void)preloadPlayerForContext:(NSString *)ctx;
// v11.0.4: 弹窗面板背景 (备忘录「多多创新」, 铺进 UIAlertController 内容容器)
- (void)applyPopupBackgroundToAlertController:(UIAlertController *)vc context:(NSString *)ctx;
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
- (NSString *)renameVideoName:(NSString *)name to:(NSString *)newName forContext:(NSString *)ctx;
- (NSString *)appDisplayName;
// 素材自愈迁移: 把其它可读根里的素材搬进主根 (信息App 容器), 让旧导入立即生效
- (void)migrateMediaIntoPrimaryRoot;

#pragma mark 背景应用
- (AVPlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force;
- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx;
// v1.7.19: 该 VC 实际挂载过的语境 (apply 时记录; 没挂过返回 nil) —— 离开页面时按它精确暂停
- (NSString *)appliedContextForViewController:(UIViewController *)vc;
- (void)detachFromViewController:(UIViewController *)vc;   // 页面离开时摘除背景
- (void)refreshVisibleBackgrounds;
- (void)postChangeNotification;
// v10.4.0f: 素材热刷新看门狗 (2秒一检: 选中素材变了/同名文件被替换 -> 立即刷新,
// 不再依赖 Darwin 通知 —— 通知在宿主挂起/直接改 Filza 文件时到不了)
- (void)startMediaWatchdog;

#pragma mark - v9.9.11 前后台自愈 (切后台再回前台视频不卡)

// 宿主 App 生命周期回调 (由 Tweak 在 %ctor 里注册通知后转发进来)
- (void)handleAppEnterBackground;
- (void)handleAppWillEnterForeground;
- (void)handleAppDidBecomeActive;
- (void)handleAudioInterruption:(NSNotification *)n;
// 音频会话重新激活 + 重连 AVPlayerLayer + 续播
//   force=NO  轻量修复 (清 layer 内容缓存 + 重设 player + play)
//   force=YES 逐界面强制重建播放器 (looper 队列被清空/解码失败的终极大招)
- (void)recoverVideoPlaybackForce:(BOOL)force;
// 屏幕上全部视频背景视图 (自愈/诊断用)
- (NSArray<SVBVideoBackgroundView *> *)allVideoBackgroundViews;

#pragma mark - v9.9.11 切后台自动清理

@property (nonatomic, assign) BOOL bgKillEnabled;          // 默认开: 切后台 N 秒后结束信息App
@property (nonatomic, assign) NSTimeInterval bgKillDelay;  // 默认 5 秒
- (void)cancelScheduledBackgroundKill;

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
// v9.9.11: 重建显示管线 (后台被系统回收内容后会卡在最后一帧)
- (void)reconnectPlayerForce:(BOOL)force;
// v9.9.11: 显示管线是否正常 (layer 有可用画面且播放器在走)
- (BOOL)playbackLooksBroken;
@end
