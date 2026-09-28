#import "SVBCommon.h"
#import <CoreFoundation/CFNotificationCenter.h>

// ============================================================
// 信息视频背景 (SMSVideoBG) - 主插件
// 作者: 板栗仁 | rootless / roothide / ElleKit / iOS 16.x
//
//  - 所有信息 / 已知发件人 / 未知发件人 / 未读信息 / 垃圾信息 /
//    最近删除 / 对话详情 七类界面独立开关 + 独立素材文件夹
//  - 全局: 总开关 / 透明度 / 模糊度 / 音量(默认关闭)
//  - 所有 Hook 均有异常保护, 不影响宿主 App 正常启动
//
//  v1.3 诊断强化:
//   1. filter 里除 com.apple.MobileSMS 外还挂了 com.apple.mobilenotes
//      作为「注入探针」: 打开备忘录若也能看到诊断横幅, 说明注入管线本身
//      是通的, 问题只在信息App 这一侧 (反之说明 dylib 根本没被加载)。
//   2. 只在信息App 进程里做界面 Hook (SVBIsSMSProcess 守卫), 其它进程
//      只写心跳 + 显示横幅, 不干扰宿主。
//   3. 进 App 后窗口顶部会出现一条可点关闭的横幅, 显示注入状态与各素材根
//      的可见性 —— 这是判断「插件到底进没进信息App」最直接的证据。
// ============================================================

// 当前进程是不是苹果「信息」App (只有它是真正要挂背景的目标)
static BOOL SVBIsSMSProcess(void) {
    static int cached = -1;
    if (cached < 0) {
        NSString *bid = SVBHostBundleIdentifier();
        cached = [bid isEqualToString:SVB_SMS_BUNDLE_ID] ? 1 : 0;
    }
    return cached == 1;
}

// 类名 -> 界面语境 (信息 App 私有框架 CK*/MT*/IM* 前缀)
static NSString *SVBContextForClassName(NSString *name) {
    if (!name || name.length < 2) return nil;
    // 排除系统基类与前缀噪声
    if ([name hasPrefix:@"UI"] || [name hasPrefix:@"_UI"] ||
        [name hasPrefix:@"NS"]  || [name hasPrefix:@"WK"]  ||
        [name hasPrefix:@"SF"]  || [name hasPrefix:@"_TtC"]) return nil;

    // 排除键盘 / 选择器 / 输入相关
    if ([name containsString:@"Keyboard"] || [name containsString:@"Picker"] ||
        [name containsString:@"Input"]    || [name containsString:@"Compose"] ||
        [name containsString:@"Recents"]  || [name containsString:@"Contact"]) return nil;

    // 对话详情 (优先级最高, Transcript 是聊天页核心类)
    if ([name containsString:@"Transcript"])  return SVBContextChat;

    // 特殊列表
    if ([name containsString:@"Junk"])            return SVBContextJunk;
    if ([name containsString:@"RecentlyDeleted"]) return SVBContextDeleted;
    if ([name containsString:@"Deleted"])         return SVBContextDeleted;
    if ([name containsString:@"Unread"])          return SVBContextUnread;

    // 会话列表 (所有信息; 已知/未知发件人由过滤器检测细分)
    if ([name containsString:@"ConversationList"] ||
        [name containsString:@"Conversations"]    ||
        [name containsString:@"MessagesList"]     ||
        [name containsString:@"Filter"]           ||
        [name containsString:@"Message"]          ||
        [name containsString:@"CK"])              return SVBContextAll;

    return nil;
}

// 只对「确认返回对象类型(@)的方法」做消息发送 —— 返回结构体/原始类型的选择器
// 若直接 objc_msgSend 会崩 (实测: 信息App「过滤条件」页闪退即此因)
static BOOL SVBReturnsObject(Class cls, SEL s) {
    Method m = class_getInstanceMethod(cls, s);
    if (m) return method_getTypeEncoding(m)[0] == '@';
    m = class_getClassMethod(cls, s);
    if (m) return method_getTypeEncoding(m)[0] == '@';
    return NO;
}

// v1.7.16: 主页面 (过滤器选择页) 内容判别 —— 扫描可见 UILabel 文本, 命中 >=2 个
// 过滤器行标题 (所有信息/已知发件人/...) 即认定是主页面。此前两版判据都失败:
// 导航根判别失效 (信息App 内部用 split 容器, 主页面不是 nav 根), 标题判别失效
// (主页面与「所有信息」列表同类同名, 日志实锤均为 CKConversationListCollectionViewController
// + title「信息」)。过滤器行文字是选择页独有的, 列表页绝不会有。
static void SVBScanForFilterRows(UIView *v, NSInteger depth, NSUInteger *hits, NSArray<NSString *> *rows) {
    if (!v || depth > 8) return;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text ?: @"";
        for (NSString *row in rows) {
            if ([t isEqualToString:row]) { (*hits)++; break; }
        }
    }
    for (UIView *s in v.subviews) SVBScanForFilterRows(s, depth + 1, hits, rows);
}

static BOOL SVBIsFilterPickerScreen(UIViewController *vc) {
    if (!vc.view) return NO;
    static NSArray<NSString *> *rowTitles = nil;
    if (!rowTitles) rowTitles = @[@"所有信息", @"已知发件人", @"未知发件人",
                                  @"未读信息", @"垃圾信息", @"最近删除",
                                  @"Known Senders", @"Unknown Senders",
                                  @"Unread Messages", @"Junk", @"Recently Deleted"];
    NSUInteger hits = 0;
    SVBScanForFilterRows(vc.view, 0, &hits, rowTitles);
    return hits >= 2;
}

// 尝试从会话列表控制器上分辨「已知/未知/未读」过滤器
// iOS16 过滤器无公开属性, 运行时尽力探测 + 全量日志, 后续版本按日志校准
static NSString *SVBDetectListContext(UIViewController *vc, NSString *fallback) {
    @try {
        Class cls = [vc class];

        // 0) 导航标题判别 (iOS16 各过滤器列表页自带标题, 是最可靠的判别来源)
        NSString *title = vc.title ?: vc.navigationItem.title;
        if (title.length) {
            [[SVBManager shared] logClassOnce:
                [NSString stringWithFormat:@"title「%@」on %@", title, cls] context:@"(标题探测)"];

            // v1.7.15/16: 主页面 = 信息App 根页 (过滤器列表: 所有信息/已知发件人/...那屏)。
            // 标题恰好是「信息/Messages」时再细分: 导航栈根 或 内容命中过滤器行 (v1.7.16,
            // 选择页与「所有信息」列表同类同名, 只能靠内容区分)。
            BOOL isNavRoot = (vc.navigationController.viewControllers.firstObject == vc);
            if ([title isEqualToString:@"信息"] ||
                [title localizedCaseInsensitiveCompare:@"Messages"] == NSOrderedSame) {
                if (isNavRoot || SVBIsFilterPickerScreen(vc)) return SVBContextMain;
            }

            if ([title containsString:@"已知发件人"] ||
                [title localizedCaseInsensitiveContainsString:@"Known Senders"])
                return SVBContextKnown;
            if ([title containsString:@"未知发件人"] ||
                [title localizedCaseInsensitiveContainsString:@"Unknown Senders"])
                return SVBContextUnknown;
            if ([title containsString:@"未读"] ||
                [title localizedCaseInsensitiveContainsString:@"Unread"])
                return SVBContextUnread;
            if ([title containsString:@"垃圾"] ||
                [title localizedCaseInsensitiveContainsString:@"Junk"] ||
                [title localizedCaseInsensitiveContainsString:@"Spam"])
                return SVBContextJunk;
            if ([title containsString:@"最近删除"] ||
                [title localizedCaseInsensitiveContainsString:@"Recently Deleted"])
                return SVBContextDeleted;
        }

        // 1) 探测 conversationList / list 上的 filter 类属性
        id list = nil;
        for (NSString *selName in (@[@"conversationList", @"list"])) {
            SEL s = NSSelectorFromString(selName);
            if (SVBReturnsObject(cls, s)) {
                id v = ((id (*)(id, SEL))objc_msgSend)(vc, s);
                if ([v isKindOfClass:[NSObject class]]) { list = v; break; }
            }
        }
        id probe = list ?: vc;
        Class probeCls = [probe class];

        for (NSString *selName in (@[@"filter", @"filterMode", @"conversationFilter",
                                     @"currentFilter", @"filterType"])) {
            SEL s = NSSelectorFromString(selName);
            if (!SVBReturnsObject(probeCls, s)) continue;
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(probe, s);
                if (![v isKindOfClass:[NSObject class]]) continue;
                NSString *desc = ([v isKindOfClass:[NSString class]]) ? v : NSStringFromClass([v class]);
                desc = [desc stringByAppendingString:[v description]];
                [[SVBManager shared] log:@"filter probe %@ -> %@ : %@",
                    probeCls, selName, desc];
                if ([desc containsString:@"junk"])         return SVBContextJunk;
                if ([desc containsString:@"deleted"])      return SVBContextDeleted;
                if ([desc containsString:@"unread"])       return SVBContextUnread;
                if ([desc containsString:@"known"])        return SVBContextKnown;
                if ([desc containsString:@"unknown"])      return SVBContextUnknown;
                return fallback;
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
    return fallback;
}

// Darwin 通知回调: 控制App/设置面板改了配置 -> 实时刷新
static void SVBPrefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[SVBManager shared] refreshVisibleBackgrounds];
}

// 横幅刷新 (注入探针进程也能用, 内容会标明是哪个 App)
static void SVBRefreshBanner(NSString *ctx) {
    @try {
        SVBShowDebugBanner([[SVBManager shared] bannerTextForContext:ctx]);
    } @catch (NSException *e) {}
}

#pragma mark - 信息 App Hook

@interface CKConversationListController : UIViewController @end
@interface CKTranscriptController : UIViewController @end
@interface CKConversationListCollectionViewController : UIViewController @end
@interface CKChatController : UIViewController @end

#define SVB_SMS_GUARD() if (!SVBIsSMSProcess()) return;
#define SVB_SAFE_APPLY(ctx) @try { \
    [[SVBManager shared] applyToViewController:self context:(ctx)]; \
    SVBRefreshBanner(ctx); \
} @catch (NSException *e) {}

// iOS16 列表 cell 的白色底色来自 backgroundConfiguration (滚动复用被系统重设)。
// v1.5 曾在 layoutSubviews 里反复置空 -> 触发集合布局失效循环 -> SIGABRT (崩溃日志实锤:
// _updateVisibleCellsNow 递归中 _cellBackgroundChanged -> _invalidateLayout -> 抛异常)。
// v1.5.3 改法: 钩 setter, 把系统设置的背景配置就地改成透明 (一次性赋值, 无自触发循环);
// layoutSubviews 只清 UIView 底色, 绝不再碰 backgroundConfiguration。
%hook UICollectionViewListCell
- (void)setBackgroundConfiguration:(UIBackgroundConfiguration *)cfg {
    @try {
        if (cfg && SVBIsSMSProcess() && [[SVBManager shared] masterEnabled])
            cfg.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
    %orig(cfg);
}
- (void)layoutSubviews {
    %orig;
    @try {
        if (!SVBIsSMSProcess()) return;
        if (![[SVBManager shared] masterEnabled]) return;
        // 只清 UIView 层底色 (UIView.backgroundColor 不触发集合布局失效, 安全)
        if (self.backgroundColor && ![self.backgroundColor isEqual:[UIColor clearColor]])
            self.backgroundColor = [UIColor clearColor];
        UIView *cv = self.contentView;
        if (cv.backgroundColor && ![cv.backgroundColor isEqual:[UIColor clearColor]])
            cv.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
}
%end

// 列表头/脚 (大标题 + 搜索框区域) 滚动复用时同样会重设白色底色
%hook UICollectionReusableView
- (void)layoutSubviews {
    %orig;
    @try {
        if (!SVBIsSMSProcess()) return;
        if (![[SVBManager shared] masterEnabled]) return;
        if (self.backgroundColor && ![self.backgroundColor isEqual:[UIColor clearColor]])
            self.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
}
%end

%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    @try {
        if (!SVBIsSMSProcess()) return;
        if (![[SVBManager shared] masterEnabled]) return;
        if (self.backgroundView) self.backgroundView = nil;
        if (self.backgroundColor && ![self.backgroundColor isEqual:[UIColor clearColor]])
            self.backgroundColor = [UIColor clearColor];
        UIView *cv = self.contentView;
        if (cv.backgroundColor && ![cv.backgroundColor isEqual:[UIColor clearColor]])
            cv.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
}
%end

// 列表语境兜底 —— 标题探测失败时, 导航栈根 = 主页面, 其余 = 所有信息
static NSString *SVBListFallback(UIViewController *vc) {
    if (vc.navigationController.viewControllers.firstObject == vc)
        return SVBContextMain;
    return SVBContextAll;
}

// 会话列表 (所有信息 / 已知 / 未知 / 未读 过滤器尽力细分)
// v1.4: viewDidAppear 复用 viewWillAppear 的检测结果, 不再强制按 all 铺背景
// v1.5: viewDidAppear 重新检测一次 (标题可能迟设); 离开页面时摘除背景
// (注: %orig 不能放进 #define, logos 预处理在宏展开之前, 所以 viewDidDisappear 逐个显式写)
static char SVBDetectedCtxKey;

%hook CKConversationListController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    NSString *ctx = SVBDetectListContext(self, SVBListFallback(self));
    objc_setAssociatedObject(self, &SVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[SVBManager shared] logClassOnce:NSStringFromClass([self class]) context:ctx];
    SVB_SAFE_APPLY(ctx)
    [[SVBManager shared] setContextActive:YES context:ctx]; // v1.6 回来恢复播放
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    NSString *ctx = SVBDetectListContext(self,
        objc_getAssociatedObject(self, &SVBDetectedCtxKey) ?: SVBListFallback(self));
    objc_setAssociatedObject(self, &SVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SVB_SAFE_APPLY(ctx)
    // v1.7.16: 选择页/列表页同类同名, 内容判别依赖 label 布局 —— 延迟复检一次,
    // 若归类变化 (如 all -> main) 就改挂背景
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            __strong typeof(wself) sself = wself;
            if (!sself || !sself.isViewLoaded || !sself.view.window) return;
            NSString *ctx2 = SVBDetectListContext(sself,
                objc_getAssociatedObject(sself, &SVBDetectedCtxKey) ?: SVBListFallback(sself));
            if (![ctx2 isEqualToString:ctx]) {
                objc_setAssociatedObject(sself, &SVBDetectedCtxKey, ctx2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [[SVBManager shared] applyToViewController:sself context:ctx2];
                SVBRefreshBanner(ctx2);
            }
        } @catch (NSException *e) {}
    });
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    // v1.6 离开暂停该界面播放器 (防声音互串); 背景视图本身保留, 不做结构变更
    NSString *ctx = objc_getAssociatedObject(self, &SVBDetectedCtxKey) ?: SVBContextAll;
    @try { [[SVBManager shared] setContextActive:NO context:ctx]; } @catch (NSException *e) {}
}
%end

// 对话详情
%hook CKTranscriptController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    [[SVBManager shared] logClassOnce:NSStringFromClass([self class]) context:SVBContextChat];
    SVB_SAFE_APPLY(SVBContextChat)
    [[SVBManager shared] setContextActive:YES context:SVBContextChat];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    SVB_SAFE_APPLY(SVBContextChat)
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try { [[SVBManager shared] setContextActive:NO context:SVBContextChat]; } @catch (NSException *e) {}
}
%end

// iOS 15/16 会话列表的新实现 (ChatKit 改用 collection VC)
%hook CKConversationListCollectionViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    NSString *ctx = SVBDetectListContext(self, SVBListFallback(self));
    objc_setAssociatedObject(self, &SVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [[SVBManager shared] logClassOnce:NSStringFromClass([self class]) context:ctx];
    SVB_SAFE_APPLY(ctx)
    [[SVBManager shared] setContextActive:YES context:ctx];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    NSString *ctx = SVBDetectListContext(self,
        objc_getAssociatedObject(self, &SVBDetectedCtxKey) ?: SVBListFallback(self));
    objc_setAssociatedObject(self, &SVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SVB_SAFE_APPLY(ctx)
    // v1.7.16: 延迟复检, 归类变化时改挂背景 (同上)
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            __strong typeof(wself) sself = wself;
            if (!sself || !sself.isViewLoaded || !sself.view.window) return;
            NSString *ctx2 = SVBDetectListContext(sself,
                objc_getAssociatedObject(sself, &SVBDetectedCtxKey) ?: SVBListFallback(sself));
            if (![ctx2 isEqualToString:ctx]) {
                objc_setAssociatedObject(sself, &SVBDetectedCtxKey, ctx2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [[SVBManager shared] applyToViewController:sself context:ctx2];
                SVBRefreshBanner(ctx2);
            }
        } @catch (NSException *e) {}
    });
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    NSString *ctx = objc_getAssociatedObject(self, &SVBDetectedCtxKey) ?: SVBContextAll;
    @try { [[SVBManager shared] setContextActive:NO context:ctx]; } @catch (NSException *e) {}
}
%end

// iOS 15/16 聊天页实现
%hook CKChatController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    [[SVBManager shared] logClassOnce:NSStringFromClass([self class]) context:SVBContextChat];
    SVB_SAFE_APPLY(SVBContextChat)
    [[SVBManager shared] setContextActive:YES context:SVBContextChat];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    SVB_SAFE_APPLY(SVBContextChat)
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try { [[SVBManager shared] setContextActive:NO context:SVBContextChat]; } @catch (NSException *e) {}
}
%end

// v1.7.18: 主页面容器清扫 —— 选择页的单元格是 CK 私有类, 不是 UICollectionViewListCell
// (全局清底 hook 对它无效), 白色圆角底来自 cell 或其内部容器的 backgroundColor。
// 递归清掉所有普通容器的底色 (文字/图标/控件/输入框/材质视图不动), 延迟补扫两次
// 防系统重设。与其它列表页的透明效果对齐 (用户要求)。
static void SVBClearContainerBGs(UIView *v, NSInteger depth) {
    if (!v || depth > 14) return;
    if ([v isKindOfClass:[SVBVideoBackgroundView class]]) return;
    BOOL isProtected = [v isKindOfClass:[UILabel class]] ||
                       [v isKindOfClass:[UIImageView class]] ||
                       [v isKindOfClass:[UIControl class]] ||
                       [v isKindOfClass:[UITextField class]] ||
                       [v isKindOfClass:[UIVisualEffectView class]];
    if (!isProtected && v.backgroundColor && ![v.backgroundColor isEqual:[UIColor clearColor]])
        v.backgroundColor = [UIColor clearColor];
    for (UIView *s in v.subviews) SVBClearContainerBGs(s, depth + 1);
}

// 主页面挂背景 + 清扫 + 延迟补扫 (cell 滚动复用/系统重设底色后再清)
static void SVBApplyMainPage(UIViewController *vc) {
    [[SVBManager shared] applyToViewController:vc context:SVBContextMain];
    SVBClearContainerBGs(vc.view, 0);
    SVBRefreshBanner(SVBContextMain);
    __weak UIViewController *wvc = vc;
    for (NSTimeInterval t in (@[@0.45, @1.2])) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIViewController *s = wvc;
                if (!s || !s.isViewLoaded || !s.view.window) return;
                SVBClearContainerBGs(s.view, 0);
            } @catch (NSException *e) {}
        });
    }
}

// v1.7.17: 延迟复检过滤器选择页 (label 布局可能晚于 viewWillAppear), 命中则挂主页面背景
static void SVBScheduleMainPageCheck(UIViewController *vc) {
    __weak UIViewController *wvc = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            UIViewController *s = wvc;
            if (!s || !s.isViewLoaded || !s.view.window) return;
            if (SVBIsFilterPickerScreen(s)) {
                SVBApplyMainPage(s);
            }
        } @catch (NSException *e) {}
    });
}

// 兜底: 类名关键词分发 (垃圾信息 / 最近删除 / 未读 / 过滤器页等)
%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try {
        NSString *name = NSStringFromClass([self class]);
        NSString *ctx = SVBContextForClassName(name);
        [[SVBManager shared] logClassOnce:name context:ctx];
        if (!ctx) return;
        // v1.7.17: 过滤器选择页(=主页面) —— 此前含 Filter 的类被无差别跳过 (v1.5 为防
        // 「过滤条件」弹出页误铺), 结果主页面从没走到任何 apply 路径, 连 all 的背景都
        // 没有 (用户截图+报告实锤)。现在: 内容命中过滤器行 -> 挂主页面背景; 立即试一次,
        // 没命中再延迟复检一次 (label 可能还没布局)。
        if ([name containsString:@"Filter"]) {
            if (SVBIsFilterPickerScreen(self)) {
                SVBApplyMainPage(self);
            } else {
                SVBScheduleMainPageCheck(self);
            }
            return;
        }
        // 兜底判成 all 时, 先用导航标题细分 (防止过滤器页被误判成「所有信息」)
        if ([ctx isEqualToString:SVBContextAll]) {
            NSString *tctx = SVBDetectListContext(self, nil);
            if (tctx.length) ctx = tctx;
        }
        if ([name containsString:@"Keyboard"] || [name containsString:@"Picker"]) return;
        // v1.5: 只对「视图本体就是列表」的 VC 生效 (非滚动容器上插背景会被上层白底
        // 内容盖住)。v1.7.17: 主页面例外 —— 选择页结构未知, 不做视图类型限制。
        if (![ctx isEqualToString:SVBContextMain] &&
            ![self.view isKindOfClass:[UITableView class]] &&
            ![self.view isKindOfClass:[UICollectionView class]]) return;
        [[SVBManager shared] applyToViewController:self context:ctx];
        SVBRefreshBanner(ctx);
    } @catch (NSException *e) {
        // 保证不崩溃
    }
}
%end

// ------------------------------------------------------------------
// 插件入口: 写心跳 + 挂横幅 + 注册 Darwin 通知
// 这段在「任何被注入的进程」里都会跑 (信息App / 备忘录探针 / 其它)
// ------------------------------------------------------------------
%ctor {
    @autoreleasepool {   // 早期加载时主线程还没有 autorelease pool
        @try {
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            [[SVBManager shared] writeHeartbeat:
                [NSString stringWithFormat:@"tweak 已注入 %@", proc]];
            [[SVBManager shared] log:@"=== SMSVideoBG v%@ tweak loaded in %@ ===",
                SVB_VERSION, proc];

            // 自愈迁移: 把 jbroot 等其它可读根里的旧素材搬进主根 (信息App 容器)
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [[SVBManager shared] migrateMediaIntoPrimaryRoot];
            });

            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL,
                                            SVBPrefsChanged,
                                            CFSTR(SVB_DARWIN_NOTE),
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
        } @catch (NSException *e) {}

        // 等宿主 App 窗口就绪后挂诊断横幅 (重试 ~20 秒, 之后靠 VC 出现时刷新)
        @try {
            __block NSInteger tries = 0;
            dispatch_source_t timer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(timer, ^{
                tries++;
                @try {
                    SVBRefreshBanner(SVBContextAll);
                } @catch (NSException *e) {}
                if (tries >= 10) dispatch_source_cancel(timer);
            });
            dispatch_resume(timer);
        } @catch (NSException *e) {}
    }
}
