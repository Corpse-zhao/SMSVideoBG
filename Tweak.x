#import "SVBCommon.h"
#import "SVBAuth.h"
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
//   1. 只在信息App 进程里做界面 Hook (SVBIsSMSProcess 守卫), 其它被注入
//      进程只写心跳 + 显示横幅, 不干扰宿主。
//   2. 进 App 后窗口顶部会出现一条可点关闭的横幅, 显示注入状态与各素材根
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

// v1.9.0 授权总闸: 未激活/过期时, 所有「给视频背景让路」的透明化处理 (清底、藏卡、
// 拆材质) 一律停手 —— 否则页面被清成透明却没有任何背景, 比不装插件还难看。
// 同时 SVBManager 的挂载入口也做了同样判断 (双保险)。
static BOOL SVBShouldProcess(void) {
    if (!SVBIsLicensed()) return NO;
    return [[SVBManager shared] masterEnabled];
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
    // v10.5.1: 诊断报告实测 CKChatController 之前落到 ctx=all, 于是 %hook UIViewController
    // 的兜底分支会在它出现时把语境覆盖成 all -> 聊天页被当普通列表处理。补上判定。
    if ([name containsString:@"ChatController"] || [name hasPrefix:@"CKChat"])
        return SVBContextChat;

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

// 横幅刷新 (注入探针进程也能用, 内容会标明是哪个 App)
static void SVBRefreshBanner(NSString *ctx) {
    @try {
        // v1.9.0: 未授权提示不受「诊断横幅」开关影响, 必须让用户看到原因
        if (!SVBIsLicensed()) SVBShowDebugBannerForce([[SVBManager shared] bannerTextForContext:ctx]);
        else                 SVBShowDebugBanner([[SVBManager shared] bannerTextForContext:ctx]);
    } @catch (NSException *e) {}
}

// v1.7.20: 主页面容器清扫升级。v1.7.18 只清 UIView.backgroundColor, 实测白卡依旧
// (用户截图实锤), 白色来源还有三类:
//   a) 直接设在 CALayer 上的底色 (圆角卡片常这么画, UIView 层是 nil);
//   b) UIVisualEffectView 模糊卡 / UIImageView 背景图 (此前豁免不敢动);
//   c) 滚动复用后系统重新铺白 (定时补扫覆盖不到)。
// 对策:
//   a) layer 层底色一并清;
//   b) 「大面积 + 无文字/控件」的视图判为卡片底, 整体藏掉 (alpha 记录可恢复);
//      cell 的 backgroundView/selectedBackgroundView 子树整体跳过 (v1.7.20 实锤:
//      任何改动都会和 backgroundConfiguration 重应用撞车, 点选时 SIGABRT);
//   c) 白色改在「赋色源头」拦: UICollectionViewListCell 背景配置 setter + 默认外观
//      重铺 (_updateDefaultBackgroundAppearance) + 分区背景装饰视图的
//      setBackgroundColor: (系统每赋一次色就被改回透明)。
// 总开关或主页面开关关闭时, 恢复所有被藏的卡片。
static char SVBOrigAlphaKey;
static char SVBOrigHiddenKey;
static NSMutableArray<UIView *> *SVBHiddenCards;

// 子树里有没有「必须可见」的内容 (文字/控件/输入框) —— 有就不能整体藏
static void SVBRestoreMappedBalloons(void);   // 前向声明 (定义在气泡映射段)
static BOOL SVBSubtreeHasContent(UIView *v, NSInteger depth) {
    if (!v || depth > 8) return NO;
    if ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UIControl class]] ||
        [v isKindOfClass:[UITextField class]]) return YES;
    for (UIView *s in v.subviews)
        if (SVBSubtreeHasContent(s, depth + 1)) return YES;
    return NO;
}

// 子树里有没有视频背景视图 (绝不能藏到它的祖先)
static BOOL SVBSubtreeHasVideoBg(UIView *v, NSInteger depth) {
    if (!v || depth > 10) return NO;
    if ([v isKindOfClass:[SVBVideoBackgroundView class]]) return YES;
    for (UIView *s in v.subviews)
        if (SVBSubtreeHasVideoBg(s, depth + 1)) return YES;
    return NO;
}

// 大面积卡片判定: 横贯版面 (>=55% 父宽) 且有一定高度, 里面没有文字/控件
static BOOL SVBIsBigCard(UIView *v) {
    CGSize sz = v.bounds.size;
    if (sz.width < 120 || sz.height < 36) return NO;
    CGFloat supW = v.superview ? v.superview.bounds.size.width : 0;
    if (supW > 0 && sz.width < supW * 0.55) return NO;
    if (SVBSubtreeHasContent(v, 0)) return NO;
    if (SVBSubtreeHasVideoBg(v, 0)) return NO;
    return YES;
}

static void SVBRecordHideCard(UIView *v) {
    if (!v || v.hidden) return;
    if (!SVBHiddenCards) SVBHiddenCards = [NSMutableArray new];
    // 清理已脱离视图树的旧记录, 防数组随滚动膨胀
    NSIndexSet *dead = [SVBHiddenCards indexesOfObjectsPassingTest:
        ^BOOL(UIView *h, NSUInteger i, BOOL *stop) { return h.superview == nil; }];
    if (dead.count) [SVBHiddenCards removeObjectsAtIndexes:dead];
    if (objc_getAssociatedObject(v, &SVBOrigAlphaKey)) { v.hidden = YES; return; }
    objc_setAssociatedObject(v, &SVBOrigAlphaKey, @(v.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &SVBOrigHiddenKey, @(v.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [SVBHiddenCards addObject:v];
    v.hidden = YES;
}

static void SVBRestoreHiddenCards(void) {
    if (!SVBHiddenCards.count) return;
    for (UIView *v in [SVBHiddenCards copy]) {
        NSNumber *a = objc_getAssociatedObject(v, &SVBOrigAlphaKey);
        NSNumber *h = objc_getAssociatedObject(v, &SVBOrigHiddenKey);
        if (a) v.alpha = a.doubleValue;
        if (h) v.hidden = h.boolValue;
    }
    [SVBHiddenCards removeAllObjects];
}

static BOOL SVBMainSweepActive(void) {
    if (!SVBIsLicensed()) return NO;   // v1.9.0: 未授权不做任何清扫
    SVBManager *m = [SVBManager shared];
    return m.masterEnabled && [m isEnabledForContext:SVBContextMain];
}

// v10.4.1: 「任意页面」清扫门 —— 只要本进程挂着可见的视频背景 (哪个语境都行),
// 列表滚动时重铺的白色卡片就该被清。
// 此前容器清扫/装饰视图拦截只认「主页面」语境: 用户在「所有信息/未读/未知…」
// 列表里下滑, 系统重铺的分区白卡没人拦 -> 成条成块的白带 (真机视频实锤)。
// (hasVisibleBackgroundViews 自带 0.5s 缓存, 高频调用无开销)
static BOOL SVBSMSListSweepActive(void) {
    if (!SVBIsLicensed()) return NO;
    SVBManager *m = [SVBManager shared];
    if (!m.masterEnabled) return NO;
    return [m hasVisibleBackgroundViews];
}

static void SVBClearContainerBGs(UIView *v, NSInteger depth) {
    if (!v || depth > 14) return;
    if ([v isKindOfClass:[SVBVideoBackgroundView class]]) return;
    if (!SVBMainSweepActive() && !SVBSMSListSweepActive()) { SVBRestoreHiddenCards(); return; }
    // v1.7.21: cell 的系统托管背景子树整体跳过 (不藏不清)。v1.7.20 曾藏
    // backgroundView/selectedBackgroundView + layoutSubviews 持续重扫, 与系统的
    // backgroundConfiguration 重应用撞车 —— 点选单元格时 SIGABRT (崩溃日志实锤:
    // _applyBackgroundViewConfiguration -> invalidateLayout 期间再被我们改动)。
    // 白色改为在「赋色源头」拦 (见下面 UICollectionViewListCell / 分区装饰视图钩子)。
    UIView *cellBg = nil, *cellSelBg = nil;
    if ([v isKindOfClass:[UICollectionViewCell class]]) {
        UICollectionViewCell *c = (UICollectionViewCell *)v;
        cellBg = c.backgroundView;
        cellSelBg = c.selectedBackgroundView;
    }
    BOOL isProtected = [v isKindOfClass:[UILabel class]] ||
                       [v isKindOfClass:[UIImageView class]] ||
                       [v isKindOfClass:[UIControl class]] ||
                       [v isKindOfClass:[UITextField class]] ||
                       [v isKindOfClass:[UIVisualEffectView class]];
    if (!isProtected) {
        if (v.backgroundColor && ![v.backgroundColor isEqual:[UIColor clearColor]])
            v.backgroundColor = [UIColor clearColor];
        // v1.7.20: layer 层底色 (圆角白卡常直接设在 CALayer 上, UIView 层是 nil)
        if (v.layer.backgroundColor && !CGColorEqualToColor(v.layer.backgroundColor, [UIColor clearColor].CGColor))
            v.layer.backgroundColor = NULL;
    }
    // v1.7.20: 大面积无内容的白卡/模糊卡/背景图 -> 整体藏掉 (文字图标小控件不动)
    if (SVBIsBigCard(v)) SVBRecordHideCard(v);
    for (UIView *s in v.subviews) {
        if (s == cellBg || s == cellSelBg) continue;   // 托管背景子树不碰
        SVBClearContainerBGs(s, depth + 1);
    }
}

// 主页面挂背景 + 清扫 + 延迟补扫 (cell 滚动复用/系统重设底色后再清)
static void SVBApplyMainPage(UIViewController *vc) {
    [[SVBManager shared] applyToViewController:vc context:SVBContextMain];
    SVBClearContainerBGs(vc.view, 0);
    SVBRefreshBanner(SVBContextMain);
    __weak UIViewController *wvc = vc;
    NSTimeInterval delays[3] = {0.45, 1.2, 2.5};
    for (int i = 0; i < 3; i++) {
        NSTimeInterval t = delays[i];
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


#pragma mark - 对话详情: 隐藏消息气泡, 只留文字 (v10.5.0)

static BOOL SVBBubbleSweepActive(void) {
    if (!SVBIsLicensed()) return NO;   // 未授权不做任何清扫
    SVBManager *m = [SVBManager shared];
    return m.masterEnabled && [m isEnabledForContext:SVBContextChat];
}

static char SVBOrigEffectKey;
static NSMutableArray<UIVisualEffectView *> *SVBBlurredViews;

// 气泡的本质 = 视图自身的底色 (backgroundColor / layer.backgroundColor), 气泡形状
// 只是一个 mask。全部清透明后气泡消失, 文字 (UILabel/UITextView) 原样保留。
// 日期/时间分隔的「模糊胶囊」: 去掉 effect (模糊), 里面的文字子视图照常显示。
static void SVBClearChatBubbleBGs(UIView *v, NSInteger depth) {
    if (!v || depth > 20) return;
    if ([v isKindOfClass:[SVBVideoBackgroundView class]]) return;
    @try {
        if ([v isKindOfClass:[UIVisualEffectView class]]) {
            UIVisualEffectView *ev = (UIVisualEffectView *)v;
            if (ev.effect) {
                if (!SVBBlurredViews) SVBBlurredViews = [NSMutableArray new];
                if (!objc_getAssociatedObject(ev, &SVBOrigEffectKey)) {
                    objc_setAssociatedObject(ev, &SVBOrigEffectKey, ev.effect,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [SVBBlurredViews addObject:ev];
                }
                ev.effect = nil;
            }
        } else {
            if (v.backgroundColor && ![v.backgroundColor isEqual:[UIColor clearColor]])
                v.backgroundColor = [UIColor clearColor];
            if (v.layer.backgroundColor &&
                !CGColorEqualToColor(v.layer.backgroundColor, [UIColor clearColor].CGColor))
                v.layer.backgroundColor = NULL;
            if (v.layer.shadowOpacity != 0) v.layer.shadowOpacity = 0;
        }
    } @catch (NSException *e) {}
    for (UIView *s in v.subviews) SVBClearChatBubbleBGs(s, depth + 1);
}

static void SVBRestoreChatBlur(void) {
    if (!SVBBlurredViews.count) return;
    for (UIVisualEffectView *ev in [SVBBlurredViews copy]) {
        if (!ev.superview) continue;
        UIVisualEffect *e = objc_getAssociatedObject(ev, &SVBOrigEffectKey);
        if (e) { @try { ev.effect = e; } @catch (NSException *x) {} }
        objc_setAssociatedObject(ev, &SVBOrigEffectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [SVBBlurredViews removeAllObjects];
}

// 只在消息列表 (UICollectionView = transcript) 里清, 不碰输入栏/导航栏 ——
// 输入框的胶囊底色保留, 保证打字区域可读。
static void SVBSweepChatCollections(UIView *root) {
    if (!root) return;
    if ([root isKindOfClass:[UICollectionView class]]) {
        SVBClearChatBubbleBGs(root, 0);
        return;
    }
    for (UIView *s in root.subviews) SVBSweepChatCollections(s);
}

// 进对话时清一轮 + 延迟补扫 (滚动复用/系统重设底色后再清)
static void SVBApplyChatBubbles(UIViewController *vc) {
    if (!vc.view) return;
    if (!SVBBubbleSweepActive()) { SVBRestoreChatBlur(); SVBRestoreMappedBalloons(); return; }
    SVBSweepChatCollections(vc.view);
    __weak UIViewController *wvc = vc;
    NSTimeInterval delays[4] = {0.35, 0.9, 2.0, 3.5};
    for (int i = 0; i < 4; i++) {
        NSTimeInterval t = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIViewController *s = wvc;
                if (!s || !s.isViewLoaded || !s.view.window) return;
                if (!SVBBubbleSweepActive()) { SVBRestoreChatBlur(); SVBRestoreMappedBalloons(); return; }
                SVBSweepChatCollections(s.view);
            } @catch (NSException *e) {}
        });
    }
}

// Darwin 通知回调: 控制App/设置面板改了配置 -> 实时刷新
static void SVBPrefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[SVBManager shared] refreshVisibleBackgrounds];
}


// 气泡「底色涂料」清: 底色 + 阴影 + 形状图层描填。
// 注意: 气泡图是一张 UIImage (CKBalloonView : CKBalloonImageView), 在 setImage: 钩子里
// 处理; 这里**绝不能动 layer.contents** —— 文字气泡会光栅化, 清 contents 连字一起没。
static void SVBStripBalloonPaint(UIView *v) {
    if (!v) return;
    @try {
        if (v.backgroundColor && ![v.backgroundColor isEqual:[UIColor clearColor]])
            v.backgroundColor = [UIColor clearColor];
        if (v.layer.backgroundColor &&
            !CGColorEqualToColor(v.layer.backgroundColor, [UIColor clearColor].CGColor))
            v.layer.backgroundColor = NULL;
        if (v.layer.shadowOpacity != 0) v.layer.shadowOpacity = 0;
        for (CALayer *sl in v.layer.sublayers) {
            if ([sl isKindOfClass:[CAShapeLayer class]]) {
                CAShapeLayer *sh = (CAShapeLayer *)sl;
                if (sh.fillColor) sh.fillColor = NULL;
                if (sh.strokeColor) sh.strokeColor = NULL;
            }
        }
    } @catch (NSException *e) {}
}

// ============ 气泡整体隐藏 + 文字映射 (v10.4.0 气泡方案二) ============
// 思路 (用户拍板): 整个气泡视图直接藏掉 (图+底色+系统文字全没了),
// 把消息文字取出来用我们自己的 UILabel 画一份 —— 白字黑影, 任何视频上都清楚,
// 也不受系统 vibrancy/气泡图影响。照片/视频等非文字气泡不动。
static char SVBBalloonAlphaKey;
static char SVBBalloonHiddenKey;
static char SVBMappedLabelKey;
static NSMutableArray<UIView *> *SVBHiddenBalloons;

static UITextView *SVBFindTextView(UIView *v, NSInteger depth) {
    if (!v || depth > 8) return nil;
    if ([v isKindOfClass:[UITextView class]]) return (UITextView *)v;
    for (UIView *s in v.subviews) {
        UITextView *r = SVBFindTextView(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

static void SVBRestoreMappedBalloons(void) {
    if (!SVBHiddenBalloons.count) return;
    for (UIView *b in [SVBHiddenBalloons copy]) {
        if (b.superview) {
            NSNumber *a = objc_getAssociatedObject(b, &SVBBalloonAlphaKey);
            NSNumber *h = objc_getAssociatedObject(b, &SVBBalloonHiddenKey);
            if (a) b.alpha = a.doubleValue;
            if (h) b.hidden = h.boolValue;
        }
        UILabel *lb = objc_getAssociatedObject(b, &SVBMappedLabelKey);
        if (lb) [lb removeFromSuperview];
        objc_setAssociatedObject(b, &SVBMappedLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [SVBHiddenBalloons removeAllObjects];
}

static void SVBMapBalloonText(UIView *balloon) {
    if (!balloon || !balloon.superview) return;
    UITextView *tv = SVBFindTextView(balloon, 0);
    if (!tv) return;                       // 非文字气泡 (照片/视频) 不动
    if (!balloon.hidden) {
        if (!SVBHiddenBalloons) SVBHiddenBalloons = [NSMutableArray new];
        NSIndexSet *dead = [SVBHiddenBalloons indexesOfObjectsPassingTest:
            ^BOOL(UIView *h, NSUInteger i, BOOL *stop) { return h.superview == nil; }];
        if (dead.count) [SVBHiddenBalloons removeObjectsAtIndexes:dead];
        objc_setAssociatedObject(balloon, &SVBBalloonAlphaKey, @(balloon.alpha),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(balloon, &SVBBalloonHiddenKey, @(balloon.hidden),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [SVBHiddenBalloons addObject:balloon];
        balloon.hidden = YES;              // 整个气泡藏掉 (图+底色+系统文字)
    }
    UILabel *lb = objc_getAssociatedObject(balloon, &SVBMappedLabelKey);
    if (!lb) {
        lb = [UILabel new];
        lb.tag = 0x53564242;               // 'SVBB'
        lb.numberOfLines = 0;
        lb.lineBreakMode = NSLineBreakByWordWrapping;
        // 跟随系统深浅色: 深色模式白字 / 浅色模式黑字 (动态 provider 自动切换)
        lb.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return (t.userInterfaceStyle == UIUserInterfaceStyleDark)
                ? [UIColor whiteColor] : [UIColor blackColor];
        }];
        lb.shadowOffset = CGSizeMake(0, 1);
        lb.font = [UIFont systemFontOfSize:17];
        [balloon.superview addSubview:lb];
        objc_setAssociatedObject(balloon, &SVBMappedLabelKey, lb,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // 影子跟模式走 (v10.4.0d: 浅色模式白影整个删掉, 只留黑字;
    // 深色模式保留黑影衬白字)
    BOOL dark = (balloon.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    lb.shadowColor = dark ? [UIColor colorWithWhite:0 alpha:0.75] : nil;
    if (!dark) lb.shadowOffset = CGSizeZero;
    // 同步内容 / 字号 / 位置 (hidden 视图仍参与布局, frame 有效)
    NSString *text = tv.text ?: @"";
    if (![lb.text isEqualToString:text]) lb.text = text;
    if (tv.font && ![lb.font isEqual:tv.font]) lb.font = tv.font;
    CGRect fr = [balloon convertRect:tv.frame toView:balloon.superview];
    CGSize need = [lb sizeThatFits:CGSizeMake(fr.size.width, CGFLOAT_MAX)];
    if (need.height > fr.size.height) fr.size.height = need.height + 2;
    if (!CGRectEqualToRect(lb.frame, fr)) lb.frame = fr;
}

#pragma mark - 对话详情: 顶部导航栏 / 底部输入栏「整块隐藏 + 自行映射」(v10.5.0)

// 与气泡同一套思路, 但对象是「系统 chrome」:
//   顶部 = 那一条白 (联系人头像 + 名字 + 返回按钮区)
//   底部 = 输入框胶囊那一条 (相机/App/文字胶囊/麦克风)
// 做法: 把整块 chrome 容器 alpha=0 (连材质/圆角/胶囊底色一起消失),
//       再用我们自己的 UIView/UILabel 在同一位置重画需要看得见的东西。
//       用 alpha 而不是 hidden —— 视图仍参与布局, 我们才能读到它的 frame 做映射。
//
// 顶部导航栏: 整块 alpha=0, 再用自己的视图重画「返回按钮 + 联系人名 + 号码」。
// 底部 (v10.6.2 改): **不再整块隐藏** —— 用户反馈要看到并用到底部输入框、
//       上传照片按钮、以及下面那一排功能键。现在只清掉容器自身的白底与内部
//       bar 背景层, 控件原样保留、可点可打字; 视频从控件缝隙里透出来。

static NSMutableArray<UIView *> *SVBHiddenChrome;      // 被藏掉的 chrome 容器
static NSMutableArray<UIView *> *SVBMappedChrome;      // 我们自己画的映射视图

static char SVBChromeAlphaKey;
static char SVBChromeHiddenKey;
static char SVBChromeMappedKey;

// v10.6.2: 只清「白底」但**保留控件**的底条容器 (底部输入框那一条)
static NSMutableArray<UIView *> *SVBTranslucentChrome;
static char SVBTransBgKey;
static char SVBTransLayerBgKey;
static char SVBIconTrayKey;                 // v10.6.3: 标记「底部 App 抽屉」视图
static NSMutableArray<UIView *> *SVBShiftedViews;   // v10.6.5: 被 transform 下移过的输入栏
static char SVBShiftKey;                          // v10.6.5: 存原始 transform 以便还原

// 返回按钮的点击目标: UIAction 的 identifier 是 readonly 且 actionWithTitle:image:
// 传 nil 会撞 -Wnonnull (CI 开了 -Werror), 干脆用一个常驻辅助对象 + target-action,
// 每个按钮把自己的 block 存进关联对象, 辅助对象统一转发。
@interface SVBChromeActionProxy : NSObject
+ (instancetype)shared;
- (void)handle:(UIButton *)sender;
@end

static char SVBChromeActionBlockKey;

@implementation SVBChromeActionProxy
+ (instancetype)shared {
    static SVBChromeActionProxy *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [SVBChromeActionProxy new]; });
    return p;
}
- (void)handle:(UIButton *)sender {
    void (^blk)(void) = objc_getAssociatedObject(sender, &SVBChromeActionBlockKey);
    if (blk) @try { blk(); } @catch (NSException *e) {}
}
@end

// v10.5.1: 顶部 / 底部 chrome 改用「几何定位」—— 不再猜类名。
// v10.5.0 实测无效的原因 (配合诊断报告 2026-09-30):
//   ① 聊天页顶部那条**不是**标准 navigationBar, 底部输入条也是私有类 ——
//      按类名关键词搜 / 取 navigationController.navigationBar 都找不到真身;
//   ② 报告实测到的真实类名: CKChatController / CKMessageEntryView (输入栏 VC) /
//      CKBrowserSwitcherFooterView (App 抽屉) / CKGradientView (渐变遮罩, 浅色下就是白)。
// 判定规则: 条状 (高 22 ~ 屏高34%) + 全宽 (>=92%) + 落在顶部/底部条带。
//
// 安全铁律 (沿用):
//   ① 遇到 UICollectionView / UITableView 直接跳过整棵子树 —— 列表内部 (日期分隔条 /
//      气泡 / cell) 一概不碰, 这是防误伤最关键的一条
//   ② 跳过 SVBVideoBackgroundView 子树 (别把视频藏了)
//   ③ 跳过 keyboard 子树
//   ④ 系统托管 cell backgroundView / selectedBackgroundView 子树绝不碰 (SIGABRT 史)
static BOOL SVBIsListClass(UIView *v) {
    return [v isKindOfClass:[UICollectionView class]] ||
           [v isKindOfClass:[UITableView class]];
}

static BOOL SVBIsSystemManagedCellBg(UIView *v) {
    UIView *pv = v.superview;
    if (![pv isKindOfClass:[UICollectionViewCell class]]) return NO;
    UICollectionViewCell *pc = (UICollectionViewCell *)pv;
    return (pc.backgroundView && v == pc.backgroundView) ||
           (pc.selectedBackgroundView && v == pc.selectedBackgroundView);
}

// v10.5.2c: 去重加入 (同一个视图可能被几何扫描和 VC 补扫同时收进来)
static void SVBAddUniqueView(NSMutableArray<UIView *> *a, UIView *v) {
    if (!v || !a) return;
    if (![a containsObject:v]) [a addObject:v];
}

// v10.5.2c: 输入条 / App 抽屉在真机上是**私有 VC** —— 诊断报告实测:
//   CKMessageEntryView           「名字叫 View, 其实是 UIViewController」= 底部输入栏
//   CKBrowserSwitcherFooterView  = 底部 App / 表情抽屉
// 它们的**视图类名**未必等于 VC 类名 (v10.5.0 按视图类名搜就是这么漏的),
// 几何也可能因内缩边距不满足 fullWidth 而漏判。所以再按 VC 类名在 VC 树里定点补一遍,
// 命中就把它的 view / inputAccessoryView 一起收进「底部条」集合。
// 注: VC 树是**全局**的 —— 输入条有时挂在窗口级容器或 nav 栈的兄弟 VC 上,
//     不在 CKChatController.view 子树里 (v10.5.1 只扫 vc.view 漏掉的真因)。
static void SVBScanChromeVCs(UIViewController *vc, NSInteger depth,
                             NSMutableArray<UIView *> *out_) {
    if (!vc || depth > 8) return;
    @try {
        NSString *cls = NSStringFromClass([vc class]);
        if ([cls containsString:@"MessageEntryView"] ||
            [cls containsString:@"BrowserSwitcher"] ||
            [cls containsString:@"ChatInput"]) {
            BOOL isTray = [cls containsString:@"BrowserSwitcher"];
            if (vc.isViewLoaded && vc.view.superview) {
                SVBAddUniqueView(out_, vc.view);
                // v10.6.3: 打标 —— 抽屉要跟输入框一样做「深度」透明化 (图标自己那层白底)
                if (isTray) objc_setAssociatedObject(vc.view, &SVBIconTrayKey, @YES,
                                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            UIView *iav = vc.inputAccessoryView;
            if (iav && iav.superview) {
                SVBAddUniqueView(out_, iav);
                if (isTray) objc_setAssociatedObject(iav, &SVBIconTrayKey, @YES,
                                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    } @catch (NSException *e) {}
    for (UIViewController *c in vc.childViewControllers)
        SVBScanChromeVCs(c, depth + 1, out_);
    @try {
        UIViewController *pv = vc.presentedViewController;
        if (pv) SVBScanChromeVCs(pv, depth + 1, out_);
    } @catch (NSException *e) {}
}

// 递归扫「条状全宽容器」+「已知遮罩类」。命中即收, 不再往里钻。
static void SVBScanBands(UIView *root, UIView *space, NSInteger depth,
                         NSMutableArray<UIView *> *tops,
                         NSMutableArray<UIView *> *bottoms,
                         NSMutableArray<UIView *> *masks) {
    if (!root || depth > 6) return;
    CGRect sb = space.bounds;
    CGFloat W = sb.size.width, H = sb.size.height;
    if (W < 1 || H < 1) return;
    CGFloat safeTop = space.safeAreaInsets.top;    if (safeTop < 1) safeTop = 44.0;
    CGFloat safeBot = space.safeAreaInsets.bottom; if (safeBot < 1) safeBot = 34.0;
    // v10.5.2c: 原 topLimit = safeTop+74 太紧 —— 聊天页顶部是「大头像+名字+副标题」
    // 的高导航栏 (约 96pt), 从安全区下沿起算时 maxY 会到 safeTop+96, 再加渐变层
    // 就直接超过 74, 被判成「不是顶条」而漏掉。
    CGFloat topLimit    = safeTop + 132.0;              // 顶条下沿的允许上限
    CGFloat bottomStart = H - (safeBot + 150.0);        // 底条上沿的允许下限

    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[SVBVideoBackgroundView class]]) continue;
        if (sub.hidden) continue;
        if (SVBIsListClass(sub)) continue;              // 列表整棵子树跳过 (不递归)
        if (SVBIsSystemManagedCellBg(sub)) continue;
        NSString *cls = NSStringFromClass([sub class]);
        NSString *low = cls.lowercaseString;
        if ([low containsString:@"keyboard"]) continue;

        // 已知遮罩 (诊断报告实测 CKGradientView = 顶部/底部渐变, 浅色模式下就是那条白):
        // 一律直接藏, 不参与几何判定
        if ([cls containsString:@"CKGradientView"]) { SVBAddUniqueView(masks, sub); continue; }

        CGRect f = [sub convertRect:sub.bounds toView:space];
        BOOL fullWidth = f.size.width >= W * 0.92;
        BOOL strip = (f.size.height >= 22.0) && (f.size.height <= H * 0.34);
        if (fullWidth && strip && CGRectIntersectsRect(f, sb)) {
            // 顶条: 顶边贴屏幕最上 (或落在状态栏附近), 或底边不超过安全区 + topLimit 余量
            // v10.5.2c: 用 SVBAddUniqueView 而非 addObject —— vc.view 本身就是某个 window
            // 的子树, 两轮扫描会把同一视图收两次, 日志计数会虚高一倍。
            if (f.origin.y <= safeTop + 8.0 || CGRectGetMaxY(f) <= topLimit) {
                SVBAddUniqueView(tops, sub);
                continue;
            }
            if (f.origin.y >= bottomStart) { SVBAddUniqueView(bottoms, sub); continue; }
        }
        SVBScanBands(sub, space, depth + 1, tops, bottoms, masks);
    }
}

// v10.6.2: 判断一段文字像不像电话号码 (纯数字 + +-() 空格点, 至少 5 位)。
// 用来把聊天页副标题里的号码挑出来 —— 「iMessage」「SMS」这类会被字母判掉。
static BOOL SVBLooksLikePhone(NSString *t) {
    if (t.length < 5 || t.length > 28) return NO;
    NSInteger digits = 0, others = 0;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c >= '0' && c <= '9') digits++;
        else if (c == '+' || c == '-' || c == ' ' || c == '(' || c == ')' || c == '.') others++;
        else return NO;
    }
    return digits >= 5 && others <= 8;
}

// v10.6.2: 从顶条子树里抓「名字 + 号码」两段文字。
//   名字 = 字号最大的那条 (联系人名 / 群名 / Apple)
//   号码 = 其余里最像电话号码的; 挑不到就退而取字号最小的那条 (iOS 副标题位)
static void SVBPickTopTexts(UIView *top, NSString **name, UIFont **nameFont,
                            NSString **sub, UIFont **subFont) {
    if (!top) return;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableArray<NSNumber *> *sizes = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:top];
    NSInteger guard = 0;
    while (stack.count && guard++ < 600) {          // 广度优先, 带硬上限防跑飞
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)v;
            if (l.text.length) {
                [texts addObject:l.text];
                [sizes addObject:@(l.font ? l.font.pointSize : 0.0)];
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    if (!texts.count) return;

    NSUInteger nameIdx = 0;
    CGFloat bestSz = -1.0;
    for (NSUInteger i = 0; i < texts.count; i++) {
        CGFloat sz = sizes[i].doubleValue;
        if (sz > bestSz) { bestSz = sz; nameIdx = i; }
    }
    *name = texts[nameIdx];
    *nameFont = [UIFont systemFontOfSize:(bestSz > 0 ? bestSz : 17.0)];

    NSUInteger subIdx = NSNotFound;
    for (NSUInteger i = 0; i < texts.count; i++) {          // 先找像号码的
        if (i == nameIdx) continue;
        if (SVBLooksLikePhone(texts[i])) { subIdx = i; break; }
    }
    if (subIdx == NSNotFound) {                             // 退而取字号最小的
        CGFloat minSz = 1e9;
        for (NSUInteger i = 0; i < texts.count; i++) {
            if (i == nameIdx) continue;
            CGFloat sz = sizes[i].doubleValue;
            if (sz < minSz) { minSz = sz; subIdx = i; }
        }
    }
    if (subIdx != NSNotFound) {
        *sub = texts[subIdx];
        CGFloat ss = sizes[subIdx].doubleValue;
        *subFont = [UIFont systemFontOfSize:(ss > 0 ? ss : 11.0)];
    }
}

// v10.6.2b: 把子树里所有 label 文字拼起来 (诊断用, 带长度上限)
static NSString *SVBTextDump(UIView *top, NSInteger maxLen) {
    if (!top) return @"(无)";
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:top];
    NSInteger guard = 0;
    while (stack.count && guard++ < 600) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            NSString *t = ((UILabel *)v).text;
            if (t.length) [a addObject:t];
        }
        [stack addObjectsFromArray:v.subviews];
    }
    NSString *joined = a.count ? [a componentsJoinedByString:@" | "] : @"(无)";
    if ((NSInteger)joined.length > maxLen)
        joined = [[joined substringToIndex:maxLen] stringByAppendingString:@"…"];
    return joined;
}

// v10.6.2b: 在子树里找第一段「像电话号码」的文字 (副标题不在顶条里时的兜底)
static NSString *SVBFindPhoneText(UIView *v, NSInteger d) {
    if (!v || d > 8) return nil;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length && SVBLooksLikePhone(t)) return t;
    }
    for (UIView *s2 in v.subviews) {
        NSString *r = SVBFindPhoneText(s2, d + 1);
        if (r) return r;
    }
    return nil;
}

// v10.6.3 【核心】子树里有没有「可见内容」。
// 【为什么必须有这个】导航栏的**内容层** (UINavigationBarContentView, 装着返回按钮和
// 标题) 同样满足「条状 + 全宽 + 贴顶」的几何判据 -> 会被 SVBScanBands 收进 tops
// -> 被 alpha=0 -> **系统返回键和标题被一起藏掉**。这正是用户看到的
// 「上面没有对方号码、左上角也没有返回键」。
// 所以: 有内容一律不允许整体隐藏, 只能去掉它的背景色。
static BOOL SVBTopHasContent(UIView *v, NSInteger d) {
    if (!v || d > 6) return NO;
    @try {
        if ([v isKindOfClass:[UILabel class]]) {
            if (((UILabel *)v).text.length) return YES;
        } else if ([v isKindOfClass:[UITextField class]] ||
                   [v isKindOfClass:[UITextView class]] ||
                   [v isKindOfClass:[UIControl class]]) {
            return YES;
        } else if ([v isKindOfClass:[UIImageView class]]) {
            if (((UIImageView *)v).image) return YES;
        }
    } @catch (NSException *e) {}
    for (UIView *s2 in v.subviews) {
        if (SVBTopHasContent(s2, d + 1)) return YES;
    }
    return NO;
}

// v10.6.4: 子树里有没有文字输入控件 —— 用来把「输入栏」和「App 抽屉」分开。
//   有  -> 是 CKMessageEntryView 那条输入栏 (用户说它已经完美, 一律不碰)
//   没有-> 是 App 抽屉(功能键那一排), 要做深度透明化
static BOOL SVBSubtreeHasTextInput(UIView *v, NSInteger d) {
    if (!v || d > 6) return NO;
    @try {
        if ([v isKindOfClass:[UITextField class]] ||
            [v isKindOfClass:[UITextView class]]) return YES;
    } @catch (NSException *e) {}
    for (UIView *s2 in v.subviews) {
        if (SVBSubtreeHasTextInput(s2, d + 1)) return YES;
    }
    return NO;
}

// v10.6.3: 系统导航栏的「返回键 / 标题」现在是不是真的能看见 (alpha>0, 未 hidden, 在屏上)。
//   YES -> 用系统的, 我们不再自绘 (自绘只会有重影 / 错位风险)
//   NO  -> 系统内容确实不可见, 才启用自绘兜底
static BOOL SVBNavContentVisible(UIView *nav) {
    if (!nav) return NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:nav];
    NSInteger guard = 0;
    while (stack.count && guard++ < 500) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        @try {
            if (v.alpha > 0.05 && !v.hidden && v.window) {
                if ([v isKindOfClass:[UIControl class]]) return YES;
                if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) return YES;
            }
        } @catch (NSException *e) {}
        [stack addObjectsFromArray:v.subviews];
    }
    return NO;
}

// 把 chrome 容器藏掉 (alpha=0 而非 hidden, 保证它仍参与布局 —— 我们要读它的 frame)
static void SVBHideChromeView(UIView *v) {
    if (!v || !v.superview) return;
    if (!SVBHiddenChrome) SVBHiddenChrome = [NSMutableArray new];
    // 只在首次藏时记录原值 (重复调用不能覆盖, 否则恢复时拿到的是 0)
    if (!objc_getAssociatedObject(v, &SVBChromeAlphaKey)) {
        objc_setAssociatedObject(v, &SVBChromeAlphaKey, @(v.alpha),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &SVBChromeHiddenKey, @(v.hidden),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (![SVBHiddenChrome containsObject:v]) [SVBHiddenChrome addObject:v];
    }
    v.alpha = 0.0;
}

// v10.6.2: 取「所有窗口」—— 三条路并集去重。
// 【根因】`UIApplication.sharedApplication.windows` 在 scene 化的 App (iOS 13+) 里
// 可能返回**空数组**。v10.5.2 的 window 扫描就栽在这: 窗口列表为空 => 实际只扫了
// vc.view => 而 UINavigationBar 是 UINavigationController 的**兄弟视图**,
// 根本不在 CKChatController.view 里 => 顶部导航栏(那条白)永远扫不到。
// (底部之所以被处理到, 是因为走了 SVBScanChromeVCs 按 VC 类名找 CKMessageEntryView,
//  与窗口列表无关 —— 这也解释了「列表页好了、对话详情顶部没好」。)
static NSArray<UIWindow *> *SVBAllWindows(UIView *anchor) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    @try { if (anchor && anchor.window && ![out containsObject:anchor.window])
                [out addObject:anchor.window]; } @catch (NSException *e) {}
    @try {
        for (UIWindow *w in UIApplication.sharedApplication.windows)
            if (w && ![out containsObject:w]) [out addObject:w];
    } @catch (NSException *e) {}
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows)
                if (w && ![out containsObject:w]) [out addObject:w];
        }
    } @catch (NSException *e) {}
    return out;
}

// v10.6.2: 清除视图内部的「bar 背景层 / 材质模糊」——只碰纯装饰, 不动输入框与按钮。
static void SVBClearBarBackgroundsInside(UIView *v, NSInteger d) {
    if (!v || d > 6) return;
    @try {
        NSString *cls = NSStringFromClass([v class]);
        if ([cls hasPrefix:@"_UIBarBackground"] || [cls containsString:@"BarBackground"]) {
            v.hidden = YES;
            return;
        }
    } @catch (NSException *e) {}
    for (UIView *s2 in v.subviews) SVBClearBarBackgroundsInside(s2, d + 1);
}

// v10.6.2: 底条「只去白底、保留控件」。用户要能看见并用到底部输入框 / 上传照片 /
// 那一排功能键, 所以不能再 alpha=0。原值缓存以便离开页面时还原。
static void SVBTranslucentChromeView(UIView *v) {
    if (!v || !v.superview) return;
    if (!SVBTranslucentChrome) SVBTranslucentChrome = [NSMutableArray new];
    if (!objc_getAssociatedObject(v, &SVBTransBgKey)) {
        objc_setAssociatedObject(v, &SVBTransBgKey, v.backgroundColor ?: (id)[NSNull null],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIColor *lb = v.layer.backgroundColor ? [UIColor colorWithCGColor:v.layer.backgroundColor] : nil;
        objc_setAssociatedObject(v, &SVBTransLayerBgKey, lb ?: (id)[NSNull null],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (![SVBTranslucentChrome containsObject:v]) [SVBTranslucentChrome addObject:v];
    }
    v.backgroundColor = [UIColor clearColor];
    v.layer.backgroundColor = NULL;
    SVBClearBarBackgroundsInside(v, 0);
}

// v10.6.3: 底部 App 抽屉(功能键那一排) 的**深度**透明化。
// 为什么不能只清容器: 浅色模式下每个图标外面那层白底挂在自己的按钮上
// (CKBrowserIconView / UIButton 的 backgroundColor), 清容器底部根本清不掉。
// 所以这里递归往下清, 但 cell 与输入控件一律不碰 (SIGABRT 史 + 别把输入框弄坏)。
static void SVBTranslucentIconTray(UIView *v, NSInteger d) {
    if (!v || d > 8) return;
    @try {
        if ([v isKindOfClass:[SVBVideoBackgroundView class]]) return;
        if ([v isKindOfClass:[UICollectionViewCell class]] ||
            [v isKindOfClass:[UITableViewCell class]]) return;      // cell 一律不碰
        if ([v isKindOfClass:[UITextField class]] ||
            [v isKindOfClass:[UITextView class]]) return;           // 输入控件别动
        NSString *cls = NSStringFromClass([v class]);
        if ([cls hasPrefix:@"_UIBarBackground"] || [cls containsString:@"BarBackground"]) {
            v.hidden = YES;
            return;
        }
        // v10.6.4: 底部那条白在浅色模式下多半是**毛玻璃**而不是纯色背景 ——
        // 只改 backgroundColor 是清不掉的, 必须把 effect 摘掉(保留视图结构, 不用 hidden)。
        if ([v isKindOfClass:[UIVisualEffectView class]]) {
            ((UIVisualEffectView *)v).effect = nil;
            v.backgroundColor = [UIColor clearColor];
            if (v.layer.backgroundColor) v.layer.backgroundColor = NULL;
            return;
        }
        if (v.backgroundColor && ![v.backgroundColor isEqual:[UIColor clearColor]])
            v.backgroundColor = [UIColor clearColor];
        if (v.layer.backgroundColor) v.layer.backgroundColor = NULL;
    } @catch (NSException *e) {}
    for (UIView *s2 in v.subviews) SVBTranslucentIconTray(s2, d + 1);
}

// v10.6.6 【关键】从底条元素继续往下钻, 把「输入栏」和「App 抽屉」分开处理。
// 【为什么必须在里面钻】SVBScanBands 命中一条就 `continue` 不再往里钻 —— 底部的结构是
//     inputAccessoryView (容器: 条状+全宽+贴底 => 被收进 bottoms 并 continue)
//     ├── CKMessageEntryView.view      (输入栏)
//     └── CKBrowserSwitcherFooterView  (App 抽屉)
//   容器一被收进来, 里面这两份**都不会被单独收集**; 而容器含输入控件 =>
//   整块被判成"输入栏"保留 => 输入栏自己的白底没人清(闪白)、抽屉整条没人碰(毫无变化)。
//   前几版一直在 bottoms 这一层加码, 作用对象始终是这个容器, 所以怎么改都无效。
//
// 判据: 落在底部条带 + 宽度 >= 屏宽 80%("整条") + 高度 18~170。
//   输入栏里的加号/麦克风按钮宽约 50pt, 不满足 80% => 不会被误伤。
static void SVBDeepProcessBottom(UIView *v, UIView *space, NSInteger depth,
                                 UIView **entryOut, CGFloat *trayHOut,
                                 NSUInteger *trayCntOut) {
    if (!v || depth > 8) return;
    CGRect sb = space.bounds;
    CGFloat W = sb.size.width, H = sb.size.height;
    if (W < 1.0 || H < 1.0) return;
    CGFloat safeBot = space.safeAreaInsets.bottom; if (safeBot < 1.0) safeBot = 34.0;
    CGFloat zoneTop = H - (safeBot + 240.0);
    for (UIView *sub in v.subviews) {
        if (!sub || sub.hidden) continue;
        if ([sub isKindOfClass:[SVBVideoBackgroundView class]]) continue;
        if (SVBIsSystemManagedCellBg(sub)) continue;
        NSString *low = NSStringFromClass([sub class]).lowercaseString;
        if ([low containsString:@"keyboard"]) continue;
        if ([sub isKindOfClass:[UITextField class]] ||
            [sub isKindOfClass:[UITextView class]]) continue;
        CGRect f = [sub convertRect:sub.bounds toView:space];
        BOOL inBottom = (f.origin.y >= zoneTop) || (CGRectGetMaxY(f) >= zoneTop);
        BOOL wide     = (f.size.width >= W * 0.80);
        BOOL bandish  = (f.size.height >= 18.0 && f.size.height <= 170.0);
        if (inBottom && wide && bandish) {
            if (SVBSubtreeHasTextInput(sub, 0)) {
                // 这一份里有输入框 => 输入栏本体: 只清背景, 控件全留
                SVBTranslucentChromeView(sub);
                if (entryOut && !*entryOut) *entryOut = sub;
                SVBDeepProcessBottom(sub, space, depth + 1, entryOut, trayHOut, trayCntOut);
                continue;
            }
            // 不含输入控件 => App 抽屉(功能键那一排): 整栏隐藏
            SVBTranslucentIconTray(sub, 0);
            SVBHideChromeView(sub);
            for (UIView *g in sub.subviews) SVBHideChromeView(g);
            if (trayCntOut) (*trayCntOut)++;
            if (trayHOut) {
                CGFloat h = f.size.height;
                if (h >= 20.0 && h <= 120.0)
                    *trayHOut = (*trayHOut < 1.0) ? h : MIN(*trayHOut, h);
            }
            continue;
        }
        SVBDeepProcessBottom(sub, space, depth + 1, entryOut, trayHOut, trayCntOut);
    }
}

// v10.6.2: frame 是否落在「顶部条带 / 底部条带」(全宽 + 条状, 不是整屏)
static BOOL SVBIsChromeBand(CGRect f, CGFloat W, CGFloat H, CGFloat safeTop, CGFloat safeBot) {
    if (f.size.width < W * 0.92) return NO;
    if (f.size.height < 6.0 || f.size.height > H * 0.42) return NO;
    if (f.origin.y <= safeTop + 8.0) return YES;
    if (CGRectGetMaxY(f) <= safeTop + 140.0) return YES;
    if (f.origin.y >= H - (safeBot + 160.0)) return YES;
    return NO;
}

// v10.6.2: 深扫 —— 与 SVBScanBands 的关键区别是**不跳过列表子树**。
// 顶部那条白很可能挂在 transcript 的 collection view 里, 而 SVBScanBands
// 遇到 UICollectionView 会整棵 skip -> 永远找不到。这里只对「具名装饰层」
// (CKGradientView / *BarBackground*) 和「条带内纯容器的平铺白底」动手,
// cell 一律不碰 (SIGABRT 史)。不在上下条带的子树直接剪掉。
static void SVBSweepDeepChrome(UIView *root, UIView *space, NSInteger depth) {
    if (!root || depth > 20) return;
    CGRect sb = space.bounds;
    CGFloat W = sb.size.width, H = sb.size.height;
    if (W < 1 || H < 1) return;
    CGFloat safeTop = space.safeAreaInsets.top;    if (safeTop < 1) safeTop = 44.0;
    CGFloat safeBot = space.safeAreaInsets.bottom; if (safeBot < 1) safeBot = 34.0;
    CGRect topZone = CGRectMake(0, 0, W, safeTop + 150.0);
    CGRect botZone = CGRectMake(0, H - (safeBot + 170.0), W, safeBot + 170.0);
    for (UIView *sub in root.subviews) {
        if (!sub || sub.hidden) continue;
        if ([sub isKindOfClass:[SVBVideoBackgroundView class]]) continue;
        if (SVBIsSystemManagedCellBg(sub)) continue;
        NSString *low = NSStringFromClass([sub class]).lowercaseString;
        if ([low containsString:@"keyboard"]) continue;
        CGRect f = [sub convertRect:sub.bounds toView:space];
        if (!CGRectIntersectsRect(f, topZone) && !CGRectIntersectsRect(f, botZone)) continue;
        BOOL cell = [sub isKindOfClass:[UICollectionViewCell class]] ||
                    [sub isKindOfClass:[UITableViewCell class]];
        if (!cell) {
            NSString *cls = NSStringFromClass([sub class]);
            BOOL band = SVBIsChromeBand(f, W, H, safeTop, safeBot);
            if (band && ([cls containsString:@"CKGradientView"] ||
                         [cls hasPrefix:@"_UIBarBackground"] ||
                         [cls containsString:@"BarBackground"])) {
                // v10.6.3: 万一这个"背景层"里嵌了内容(极少数), 也只清背景不整体藏
                if (SVBTopHasContent(sub, 0)) SVBTranslucentChromeView(sub);
                else                          SVBHideChromeView(sub);
                continue;
            }
            if (band) {
                BOOL keep = [sub isKindOfClass:[UIControl class]] ||
                            [sub isKindOfClass:[UILabel class]] ||
                            [sub isKindOfClass:[UIImageView class]] ||
                            [sub isKindOfClass:[UITextField class]] ||
                            [sub isKindOfClass:[UITextView class]] ||
                            [sub isKindOfClass:[UIVisualEffectView class]] ||
                            [sub isKindOfClass:[UIScrollView class]];
                if (!keep) {                 // 纯容器的平铺白底: 只清底色, 子控件全留
                    if (sub.backgroundColor && ![sub.backgroundColor isEqual:[UIColor clearColor]])
                        sub.backgroundColor = [UIColor clearColor];
                    if (sub.layer.backgroundColor) sub.layer.backgroundColor = NULL;
                }
            }
        }
        SVBSweepDeepChrome(sub, space, depth + 1);
    }
}

#pragma mark - 顶部条映射 (返回按钮 + 名字)

static void SVBMapChatTop(UIViewController *vc, UIView *topBand,
                          NSString *titleText, UIFont *titleFont,
                          NSString *subText, UIFont *subFont,
                          BOOL sysOk) {
    UIView *host = topBand.superview;
    if (!host) return;
    UIView *layer = objc_getAssociatedObject(vc, &SVBChromeMappedKey);
    if (layer && layer.superview && layer.superview != host) {
        [layer removeFromSuperview];
        objc_setAssociatedObject(vc, &SVBChromeMappedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        layer = nil;
    }
    if (!layer || !layer.superview) {
        layer = [UIView new];
        layer.tag = 0x5356424E;                 // 'SVBN'
        layer.userInteractionEnabled = YES;
        [host addSubview:layer];
        objc_setAssociatedObject(vc, &SVBChromeMappedKey, layer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!SVBMappedChrome) SVBMappedChrome = [NSMutableArray new];
        if (![SVBMappedChrome containsObject:layer]) [SVBMappedChrome addObject:layer];
    }
    CGRect lf = [topBand convertRect:topBand.bounds toView:host];
    if (!CGRectEqualToRect(layer.frame, lf)) layer.frame = lf;
    layer.backgroundColor = [UIColor clearColor];

    // v10.6.2b: 导航栏的 frame 从 y=0 起算 (**含状态栏**), 直接按整条高度居中会把
    // 标题/返回键塞进灵动岛与状态栏底下 —— 用户实拍就是「返回键看不见」。
    // 先算出「安全带」(安全区顶边在 layer 坐标系里的 y), 所有内容只在安全带内居中。
    CGFloat safeT = topBand.safeAreaInsets.top;
    if (safeT < 1) safeT = vc.view.safeAreaInsets.top;
    if (safeT < 1) safeT = 44.0;
    CGFloat contentTop = safeT - lf.origin.y;
    if (contentTop < 0) contentTop = 0;
    if (contentTop > lf.size.height - 30.0) contentTop = 0;   // 数值不合理就不偏移
    CGFloat contentH = lf.size.height - contentTop;
    CGFloat ccx = lf.size.width / 2.0;
    CGFloat ccy = contentTop + contentH / 2.0;

    BOOL dark = (vc.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    UIColor *fg = dark ? [UIColor whiteColor] : [UIColor blackColor];

    // ---- 标题 ----
    UILabel *title = (UILabel *)[layer viewWithTag:0x53564254];   // 'SVBT'
    if (!title) {
        title = [UILabel new];
        title.tag = 0x53564254;
        title.textAlignment = NSTextAlignmentCenter;
        [layer addSubview:title];
    }
    // v10.6.3: sysOk=YES 表示系统导航栏的标题(联系人名)本来就看得见 ——
    // 再自绘一遍会重影/错位, 所以自绘标题只在「系统内容确实不可见」时才启用。
    title.hidden = sysOk;
    title.text = sysOk ? @"" : (titleText ?: @"");
    title.textColor = fg;
    title.font = titleFont ?: [UIFont boldSystemFontOfSize:17];
    CGFloat maxW = MAX(40.0, lf.size.width - 140.0);
    CGSize need = [title sizeThatFits:CGSizeMake(maxW, CGFLOAT_MAX)];
    BOOL hasSub = (subText.length > 0);
    CGFloat titleTop = hasSub ? (ccy - need.height - 0.5) : (ccy - need.height / 2.0);
    if (!sysOk)
        title.frame = CGRectMake(floor(ccx - need.width / 2.0), floor(titleTop),
                                 need.width, need.height);

    // ---- 副行 (对方号码) ----
    UILabel *subLine = (UILabel *)[layer viewWithTag:0x53564253];   // 'SVBS'
    if (hasSub) {
        if (!subLine) {
            subLine = [UILabel new];
            subLine.tag = 0x53564253;
            subLine.textAlignment = NSTextAlignmentCenter;
            [layer addSubview:subLine];
        }
        subLine.hidden = NO;
        subLine.text = subText;
        subLine.textColor = fg;
        subLine.font = subFont ?: [UIFont systemFontOfSize:11];
        CGSize n2 = [subLine sizeThatFits:CGSizeMake(maxW, CGFLOAT_MAX)];
        // v10.6.3: sysOk 时导航栏的标题已被系统占住, 号码就放到「副标题位」(靠下);
        // 否则按自绘标题的下方排。
        CGFloat subY = sysOk ? (lf.size.height - n2.height - 2.0) : (ccy + 0.5);
        if (subY < contentTop) subY = contentTop;
        subLine.frame = CGRectMake(floor(ccx - n2.width / 2.0), floor(subY),
                                   n2.width, n2.height);
    } else if (subLine) {
        subLine.hidden = YES;
    }

    // ---- 返回按钮 (‹) ----
    // 用辅助对象转发 block (UIAction.identifier 只读, 且 actionWithTitle:image: 传 nil
    // 会撞 -Wnonnull —— 两坑都踩过, 见 skill 14.8)。
    UIButton *back = (UIButton *)[layer viewWithTag:0x53564242];  // 'SVBB'
    if (!back) {
        back = [UIButton buttonWithType:UIButtonTypeSystem];
        back.tag = 0x53564242;
        [layer addSubview:back];
    }
    [back setTitle:@"‹" forState:UIControlStateNormal];
    [back setTitleColor:fg forState:UIControlStateNormal];
    back.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightRegular];
    // v10.6.3: 系统返回键可见时(sysOk)不重复画 —— 系统的位置/手势/无障碍都是对的
    back.hidden = sysOk;
    // v10.6.2b: 返回键只在安全带 (状态栏以下) 内撑满, 否则会顶到灵动岛里
    back.frame = CGRectMake(4, contentTop, 58, contentH);
    __weak UIViewController *wvc = vc;
    objc_setAssociatedObject(back, &SVBChromeActionBlockKey, ^{
        UIViewController *s = wvc;
        if (!s) return;
        @try { [s.navigationController popViewControllerAnimated:YES]; }
        @catch (NSException *e) {}
    }, OBJC_ASSOCIATION_COPY_NONATOMIC);
    // 注: action:nil 会撞 -Wnonnull, 必须写明确 selector
    [back removeTarget:[SVBChromeActionProxy shared]
                action:@selector(handle:)
      forControlEvents:UIControlEventTouchUpInside];
    [back addTarget:[SVBChromeActionProxy shared]
             action:@selector(handle:)
   forControlEvents:UIControlEventTouchUpInside];
}

static void SVBClearMappedChrome(void) {
    for (UIView *v in [SVBMappedChrome copy]) {
        if (v.superview) [v removeFromSuperview];
    }
    [SVBMappedChrome removeAllObjects];
    // v10.6.2: 还原「只去了白底」的底条容器 (底条不再 alpha=0)
    for (UIView *v in [SVBTranslucentChrome copy]) {
        if (!v.superview) continue;
        id bg = objc_getAssociatedObject(v, &SVBTransBgKey);
        id lb = objc_getAssociatedObject(v, &SVBTransLayerBgKey);
        v.backgroundColor = ([bg isKindOfClass:[UIColor class]] ? (UIColor *)bg : nil);
        v.layer.backgroundColor = ([lb isKindOfClass:[UIColor class]]
                                   ? ((UIColor *)lb).CGColor : NULL);
        objc_setAssociatedObject(v, &SVBTransBgKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &SVBTransLayerBgKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [SVBTranslucentChrome removeAllObjects];
    for (UIView *v in [SVBHiddenChrome copy]) {
        if (!v.superview) continue;
        NSNumber *a = objc_getAssociatedObject(v, &SVBChromeAlphaKey);
        NSNumber *h = objc_getAssociatedObject(v, &SVBChromeHiddenKey);
        if (a) v.alpha = a.doubleValue;
        if (h) v.hidden = h.boolValue;
        objc_setAssociatedObject(v, &SVBChromeAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &SVBChromeHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [SVBHiddenChrome removeAllObjects];
    // v10.6.5: 还原被下移过的输入栏
    for (UIView *v in [SVBShiftedViews copy]) {
        if (!v.superview) continue;
        NSValue *iv = objc_getAssociatedObject(v, &SVBShiftKey);
        if (iv) v.transform = iv.CGAffineTransformValue;
        objc_setAssociatedObject(v, &SVBShiftKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [SVBShiftedViews removeAllObjects];
}

// v10.6.3: 系统导航栏**没**显示号码时, 直接从会话对象里把对方号码取出来。
// 路径: CKChatController.conversation -> CKConversation.chat -> IMChat.participants
//       -> IMHandle.address / displayID; 单聊退化用 CKConversation.recipient。
// 全部走 KVC + @try, 拿不到就返回 nil (绝不抛异常)。
static NSString *SVBPeerNumberFromVC(UIViewController *vc) {
    if (!vc) return nil;
    @try {
        if (![vc respondsToSelector:NSSelectorFromString(@"conversation")]) return nil;
        id conv = [vc valueForKey:@"conversation"];
        if (!conv) return nil;
        NSMutableArray *handles = [NSMutableArray array];
        @try {
            id chat = [conv valueForKey:@"chat"];
            if (chat) {
                id ps = [chat valueForKey:@"participants"];
                if ([ps isKindOfClass:[NSArray class]]) [handles addObjectsFromArray:ps];
                else if ([ps isKindOfClass:[NSSet class]])
                    [handles addObjectsFromArray:[(NSSet *)ps allObjects]];
            }
        } @catch (NSException *e) {}
        if (!handles.count) {
            @try {
                id rec = [conv valueForKey:@"recipient"];
                if (rec) [handles addObject:rec];
            } @catch (NSException *e) {}
        }
        for (id h in handles) {
            NSString *addr = nil;
            @try { addr = [h valueForKey:@"address"]; } @catch (NSException *e) {}
            if (!addr.length) @try { addr = [h valueForKey:@"displayID"]; } @catch (NSException *e) {}
            if (addr.length) return addr;
        }
    } @catch (NSException *e) {}
    return nil;
}

// 一轮完整处理: 扫 -> (兜底 nav bar) -> 抓标题 -> 藏 -> 映射
static void SVBDoChatChrome(UIViewController *vc) {
    if (!vc || !vc.view) return;
    NSMutableArray<UIView *> *tops = [NSMutableArray array];
    NSMutableArray<UIView *> *bottoms = [NSMutableArray array];
    NSMutableArray<UIView *> *masks = [NSMutableArray array];
    @try {
        SVBScanBands(vc.view, vc.view, 0, tops, bottoms, masks);
    } @catch (NSException *e) {}
    // v10.5.2 【关键修复】: 还必须扫 window!
    // 老坑 (memory 有记): docked inputAccessory (键盘收起时的输入条) 以及部分私有
    // 顶/底栏挂在**窗口级容器**上, 根本不在 vc.view 里 —— 只在 vc.view 内扫永远找不到。
    // v10.5.0 本来是从 window 扫的, v10.5.1 改成只扫 vc.view 反而把这个覆盖丢了。
    // 纯键盘窗口跳过 (键盘子树本来就一律跳过)。
    @try {
        for (UIWindow *w in SVBAllWindows(vc.view)) {
            NSString *wcls = NSStringFromClass([w class]).lowercaseString;
            if ([wcls containsString:@"keyboard"]) continue;
            SVBScanBands(w, w, 0, tops, bottoms, masks);
        }
    } @catch (NSException *e) {}

    // v10.6.2: 深扫兜底 —— 不跳过列表子树, 专杀条带里的渐变遮罩/bar 背景/平铺白底。
    // (顶部那条白很可能挂在 transcript 的 collection view 里, 几何扫描会整棵 skip)
    @try {
        SVBSweepDeepChrome(vc.view, vc.view, 0);
        for (UIWindow *w in SVBAllWindows(vc.view)) {
            NSString *wcls = NSStringFromClass([w class]).lowercaseString;
            if ([wcls containsString:@"keyboard"]) continue;
            SVBSweepDeepChrome(w, w, 0);
        }
    } @catch (NSException *e) {}

    // v10.5.2c: 再按「私有 VC 类名」定点补一遍底条 (几何 + window 扫描都失效时的保险)。
    // 同时抓聊天页自己的 inputAccessoryView —— 它可能被系统收进键盘窗口,
    // 而键盘窗口在上面已被我们跳过, 几何扫不到。
    @try {
        SVBScanChromeVCs(vc, 0, bottoms);
        for (UIWindow *w in SVBAllWindows(vc.view)) {
            NSString *wcls = NSStringFromClass([w class]).lowercaseString;
            if ([wcls containsString:@"keyboard"]) continue;
            UIViewController *rvc = w.rootViewController;
            if (rvc) SVBScanChromeVCs(rvc, 0, bottoms);
        }
        UIView *iavTop = vc.inputAccessoryView;   // UIResponder 属性, 非第一响应者时可能为 nil
        if (iavTop && iavTop.superview) SVBAddUniqueView(bottoms, iavTop);
    } @catch (NSException *e) {}

    // 几何没找到顶条 -> 退回标准导航栏兜底 (有则藏着无害)
    if (!tops.count) {
        UINavigationBar *nav = vc.navigationController.navigationBar;
        if (nav && nav.window && nav.superview) [tops addObject:nav];
    }
    UIView *top = tops.firstObject;

    // 标题先抓后藏 (alpha 不影响读 text)
    NSString *titleText = nil;
    UIFont *titleFont = nil;
    NSString *subText = nil;
    UIFont *subFont = nil;
    if (top) {
        @try {
            SVBPickTopTexts(top, &titleText, &titleFont, &subText, &subFont);
        } @catch (NSException *e) {}
    }
    if (!titleText.length) {
        NSString *t = vc.title;
        if (!t.length) t = vc.navigationItem.title;
        if (t.length) titleText = t;
    }
    // v10.6.2b: 号码兜底 —— 顶条里找不到像电话号码的副标题时, 再去导航栏里找一遍
    if (!subText.length) {
        @try {
            NSString *num = SVBFindPhoneText(top, 0);
            if (!num.length) {
                UINavigationBar *nb = vc.navigationController.navigationBar;
                if (nb && nb != top) num = SVBFindPhoneText(nb, 0);
            }
            if (num.length) {
                subText = num;
                subFont = [UIFont systemFontOfSize:11];
            }
        } @catch (NSException *e) {}
    }

    // v10.6.3 【关键修复】顶部「有内容」的视图只能清背景, 绝不能整体 alpha=0。
    // 导航栏内容层同样满足「条状+全宽+贴顶」的几何判据, 旧代码把它一起 alpha=0,
    // 于是系统返回键 + 标题(含对方号码) 全没了 —— 这就是用户这次报的两个现象。
    for (UIView *v in tops) {
        if (SVBTopHasContent(v, 0)) SVBTranslucentChromeView(v);   // 导航栏内容层: 只清背景
        else                        SVBHideChromeView(v);          // 纯背景层: 照旧藏
    }
    for (UIView *v in masks) {
        if (SVBTopHasContent(v, 0)) SVBTranslucentChromeView(v);
        else                        SVBHideChromeView(v);
    }
    // v10.6.2: 底条**不再 alpha=0** —— 用户要看到并用到底部输入框 / 上传照片 /
    // 下面那一排功能键。改成「只清掉容器自身白底 + 内部 bar 背景层」, 控件原样保留。
    // v10.6.6 【关键修复】不能只看 bottoms 这一层 ——
    // SVBScanBands 命中一条 `continue`, 所以底部那个 inputAccessoryView 容器一被收进
    // bottoms, 里面的「输入栏」和「App 抽屉」就都不会被单独收集; 容器里含输入控件
    // => 整块被判成"输入栏"保留 => ① 输入栏自己那层白没人清(闪白) ② 抽屉没人碰(毫无变化)。
    // 现在改成**钻进容器内部**逐份处理。
    UIView *entryView = nil;
    CGFloat trayH = 0.0;
    NSUInteger trayCntHidden = 0;
    for (UIView *v in bottoms) {
        SVBTranslucentChromeView(v);
        SVBDeepProcessBottom(v, vc.view, 0, &entryView, &trayH, &trayCntHidden);
    }
    // v10.6.5: 输入栏下移到最底下。用 transform 而不是改 frame/约束 ——
    // transform 独立于 Auto Layout, 系统重排时不会被覆盖。
    if (entryView && trayH > 8.0) {
        if (!SVBShiftedViews) SVBShiftedViews = [NSMutableArray new];
        if (!objc_getAssociatedObject(entryView, &SVBShiftKey)) {
            objc_setAssociatedObject(entryView, &SVBShiftKey,
                [NSValue valueWithCGAffineTransform:entryView.transform],
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (![SVBShiftedViews containsObject:entryView])
                [SVBShiftedViews addObject:entryView];
        }
        entryView.transform = CGAffineTransformMakeTranslation(0, trayH);
    }

    // v10.6.3: 系统导航栏的返回键/标题此刻是否真的可见 -> 决定自绘层要不要画
    BOOL sysOk = NO;
    for (UIView *v in tops) { if (SVBNavContentVisible(v)) { sysOk = YES; break; } }
    if (!sysOk) {
        @try {
            UINavigationBar *nb0 = vc.navigationController.navigationBar;
            if (nb0) sysOk = SVBNavContentVisible(nb0);
        } @catch (NSException *e) {}
    }
    // v10.6.3: 号码 —— 系统顶条里已经显示号码就别重复; 没显示就去会话对象里取对方的号
    BOOL sysShowsNumber = (subText.length > 0) && SVBLooksLikePhone(subText);
    if (sysShowsNumber) {
        subText = nil;                       // 系统已显示, 自绘层不重复
    } else {
        @try {
            NSString *peer = SVBPeerNumberFromVC(vc);
            if (peer.length) { subText = peer; subFont = [UIFont systemFontOfSize:12]; }
        } @catch (NSException *e) {}
    }

    if (top) {
        @try {
            SVBMapChatTop(vc, top, titleText, titleFont, subText, subFont, sysOk);
        } @catch (NSException *e) {}
    }

    // v10.5.2: 诊断 —— 把本轮命中写进日志 (节流 1.5s)。万一还没生效, 下次诊断报告里
    // 就能直接看到「扫到了什么/什么都没扫到」, 不用再靠猜。
    @try {
        static NSTimeInterval sLastChromeLog = 0;
        NSTimeInterval nowTs = [NSDate date].timeIntervalSince1970;
        if (nowTs - sLastChromeLog > 1.5) {
            sLastChromeLog = nowTs;
            NSMutableString *desc = [NSMutableString string];
            for (UIView *v in tops)
                [desc appendFormat:@"顶[%@ h=%.0f] ", NSStringFromClass([v class]), v.bounds.size.height];
            for (UIView *v in bottoms)
                [desc appendFormat:@"底[%@ h=%.0f] ", NSStringFromClass([v class]), v.bounds.size.height];
            for (UIView *v in masks)
                [desc appendFormat:@"罩[%@] ", NSStringFromClass([v class])];
            if (!desc.length) desc = [NSMutableString stringWithString:@"(无命中)"];
            [[SVBManager shared] log:@"chat chrome 命中 %lu/%lu/%lu -> %@",
                (unsigned long)tops.count, (unsigned long)bottoms.count,
                (unsigned long)masks.count, desc];
            // v10.6.2: 带上「名字/号码」实际取到什么 (定位号码映射用)
            [[SVBManager shared] log:@"chat chrome 文字: 名=%@ / 号=%@",
                titleText.length ? titleText : @"(无)",
                subText.length ? subText : @"(无)"];
            [[SVBManager shared] log:@"chat chrome 顶条文字候选: %@", SVBTextDump(top, 150)];
            UINavigationBar *nbLog = vc.navigationController.navigationBar;
            if (nbLog && nbLog != top)
                [[SVBManager shared] log:@"chat chrome 导航栏文字候选: %@", SVBTextDump(nbLog, 150)];
            // v10.6.3: 顶部内容保护是否生效 / 系统返回键可见性 / 抽屉是否被识别
            NSMutableString *td = [NSMutableString string];
            for (UIView *v in tops)
                [td appendFormat:@"%@(内容=%d) ", NSStringFromClass([v class]),
                                     (int)SVBTopHasContent(v, 0)];
            BOOL sysOkLog = NO;
            for (UIView *v in tops) { if (SVBNavContentVisible(v)) { sysOkLog = YES; break; } }
            NSUInteger trayCnt = 0;
            for (UIView *v in bottoms)
                if (NSStringFromClass([v class]).length &&
                    (objc_getAssociatedObject(v, &SVBIconTrayKey) != nil)) trayCnt++;
            [[SVBManager shared] log:@"chat chrome 顶部保护: sysOk=%d 抽屉=%lu 明细: %@",
                (int)sysOkLog, (unsigned long)trayCnt, td];
            // v10.6.4: 底条逐个元素 + 是否含输入控件(决定谁走深度透明化)
            NSMutableString *bd = [NSMutableString string];
            for (UIView *v in bottoms)
                [bd appendFormat:@"%@(输入=%d h=%.0f) ", NSStringFromClass([v class]),
                                     (int)SVBSubtreeHasTextInput(v, 0), v.bounds.size.height];
            [[SVBManager shared] log:@"chat chrome 底条明细: %@",
                bd.length ? bd : @"(无)"];
            // v10.6.5: 抽屉隐藏 + 输入栏下移的结果 (entryView/trayH 就在本函数作用域内)
            [[SVBManager shared] log:@"chat chrome 底条处理: 输入栏=%@ 抽屉高=%.0f 隐藏数=%lu",
                entryView ? NSStringFromClass([entryView class]) : @"(未找到)",
                trayH, (unsigned long)trayCntHidden];
        }
    } @catch (NSException *e) {}
}

// 入口: 进对话时调用一次; 与气泡一样做延迟补扫 (系统重建 chrome 后再藏)
static void SVBApplyChatChrome(UIViewController *vc) {
    // v10.6.4: 原来是 `!vc.view.window` 就直接 return —— 但 push 转场的 viewWillAppear
    // 阶段 view.window 往往还是 nil, 于是整条链路只能等 viewDidAppear(转场结束)之后
    // 才第一次生效 => 用户看到「进对话详情要一秒白块才消失」。
    // 放宽成「有 view 就干活」: 扫描本身只依赖视图树, 不依赖 window。
    if (!vc || !vc.view) return;
    if (!vc.view.window && !vc.view.superview) return;
    BOOL active = SVBBubbleSweepActive();
    @try {
        static NSTimeInterval sLastEnterLog = 0;
        NSTimeInterval nowTs = [NSDate date].timeIntervalSince1970;
        if (nowTs - sLastEnterLog > 1.5) {
            sLastEnterLog = nowTs;
            [[SVBManager shared] log:@"chat chrome 进入: vc=%@ active=%d windows=%lu",
                NSStringFromClass([vc class]), (int)active,
                (unsigned long)SVBAllWindows(vc.view).count];
        }
    } @catch (NSException *e) {}
    if (!active) { SVBClearMappedChrome(); return; }
    if (!SVBHiddenChrome) SVBHiddenChrome = [NSMutableArray new];
    if (!SVBMappedChrome) SVBMappedChrome = [NSMutableArray new];
    @try { SVBDoChatChrome(vc); } @catch (NSException *e) {}
    __weak UIViewController *wvc = vc;
    // v10.6.4: 补扫点 8 -> 16 个, 并且把第一个点前移到 **0.0s**(立刻来一发)。
    // 旧版第一个点是 0.25s 且那时导航栏往往还没建好 => 用户感知「过一秒才消失」。
    NSTimeInterval delays[16] = {0.0, 0.05, 0.12, 0.2, 0.3, 0.45, 0.6, 0.8,
                                 1.05, 1.35, 1.75, 2.2, 2.8, 3.6, 4.8, 6.5};
    for (int i = 0; i < 16; i++) {
        NSTimeInterval t = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIViewController *s = wvc;
                if (!s || !s.isViewLoaded) return;
                if (!s.view.window && !s.view.superview) return;   // v10.6.4: 同放宽策略
                if (!SVBBubbleSweepActive()) { SVBClearMappedChrome(); return; }
                SVBDoChatChrome(s);
            } @catch (NSException *e) {}
        });
    }
}

#pragma mark - 信息 App Hook

@interface CKConversationListController : UIViewController @end
@interface CKTranscriptController : UIViewController @end
@interface CKConversationListCollectionViewController : UIViewController @end
@interface CKChatController : UIViewController @end
@interface CKMessageEntryView : UIViewController @end

#define SVB_SMS_GUARD() if (!SVBIsSMSProcess()) return;
#define SVB_SAFE_APPLY(ctx) @try { \
    [[SVBManager shared] applyToViewController:self context:(ctx)]; \
    SVBRefreshBanner(ctx); \
} @catch (NSException *e) {}

// v1.7.19: 主页面语境走 SVBApplyMainPage (挂背景+容器清扫+补扫), 其它语境照旧。
// 此前只有 Filter 兜底分支做清扫, 显式钩子 (退回主页面时走这条) 只铺背景不清扫,
// 导致「退回来又变白」。
#define SVB_APPLY_CTX(vc, c) @try { \
    if ([c isEqualToString:SVBContextMain]) SVBApplyMainPage(vc); \
    else [[SVBManager shared] applyToViewController:(vc) context:(c)]; \
    SVBRefreshBanner(c); \
} @catch (NSException *e) {}

// v1.7.21: 白色一律在「赋色源头」拦, 不做任何 layout 中途改动 (v1.7.20 的
// layoutSubviews 持续重扫已撤 —— 与 backgroundConfiguration 重应用撞车崩溃)。

// 1) 选中态白卡: 见下方 _updateDefaultBackgroundAppearance 钩子说明。
%hook UICollectionViewListCell
- (void)setBackgroundConfiguration:(UIBackgroundConfiguration *)cfg {
    @try {
        if (cfg && SVBIsSMSProcess() && SVBShouldProcess())
            cfg.backgroundColor = [UIColor clearColor];
    } @catch (NSException *e) {}
    %orig(cfg);
}
// v1.7.21: 选中/高亮白卡 —— 点一下单元格出现的白, 来自系统的默认选中外观重铺
// (崩溃日志实锤路径: _setLayoutAttributes -> _updateDefaultBackgroundAppearance ->
// _applyBackgroundViewConfiguration, 不经过公开的 setBackgroundConfiguration:
// setter, 所以之前拦不到)。对策: 系统铺完默认外观后, 异步 (避开 layout 重入)
// 给 cell 补一个全透明 backgroundConfiguration —— 走公共 API, 是 UIKit 设计内的
// 合法赋值路径, 之后选中/高亮状态都基于这份透明配置, 白卡不再回来。
- (void)_updateDefaultBackgroundAppearance {
    %orig;
    @try {
        if (!SVBIsSMSProcess()) return;
        if (!SVBShouldProcess()) return;
        if (self.backgroundConfiguration) return;
        __weak UICollectionViewListCell *wcell = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (!wcell.backgroundConfiguration)
                    wcell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}
- (void)layoutSubviews {
    %orig;
    @try {
        if (!SVBIsSMSProcess()) return;
        if (!SVBShouldProcess()) return;
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
        if (!SVBShouldProcess()) return;
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
        if (!SVBShouldProcess()) return;
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
    SVB_APPLY_CTX(self, ctx)
    [[SVBManager shared] setContextActive:YES context:ctx]; // v1.6 回来恢复播放
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    NSString *ctx = SVBDetectListContext(self,
        objc_getAssociatedObject(self, &SVBDetectedCtxKey) ?: SVBListFallback(self));
    objc_setAssociatedObject(self, &SVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SVB_APPLY_CTX(self, ctx)
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
                SVB_APPLY_CTX(sself, ctx2)
            }
        } @catch (NSException *e) {}
    });
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    // v1.6 离开暂停该界面播放器 (防声音互串); 背景视图本身保留, 不做结构变更
    // v1.7.19: 按「该 VC 实际挂载过的语境」暂停 (检测值中途会变, 按它暂停会错杀/漏停)
    NSString *ctx = [[SVBManager shared] appliedContextForViewController:self]
        ?: objc_getAssociatedObject(self, &SVBDetectedCtxKey) ?: SVBContextAll;
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
    // v10.6.4: 转场期间就先处理一次 —— 白块不必等到 viewDidAppear 之后才消失
    SVBApplyChatChrome(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    SVB_SAFE_APPLY(SVBContextChat)
    SVBApplyChatBubbles(self);   // v10.5.0: 隐藏气泡只留文字
    SVBApplyChatChrome(self);    // v10.5.0: 顶部导航栏/底部输入栏整块隐藏 + 自行映射
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try { [[SVBManager shared] setContextActive:NO context:SVBContextChat]; } @catch (NSException *e) {}
    SVBRestoreChatBlur();
    SVBRestoreMappedBalloons();   // 撤掉气泡隐藏与文字映射
    SVBClearMappedChrome();       // 还原导航栏/输入栏
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
    SVB_APPLY_CTX(self, ctx)
    [[SVBManager shared] setContextActive:YES context:ctx];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    NSString *ctx = SVBDetectListContext(self,
        objc_getAssociatedObject(self, &SVBDetectedCtxKey) ?: SVBListFallback(self));
    objc_setAssociatedObject(self, &SVBDetectedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SVB_APPLY_CTX(self, ctx)
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
                SVB_APPLY_CTX(sself, ctx2)
            }
        } @catch (NSException *e) {}
    });
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    // v1.7.19: 按「该 VC 实际挂载过的语境」暂停 (检测值中途会变, 按它暂停会错杀/漏停)
    NSString *ctx = [[SVBManager shared] appliedContextForViewController:self]
        ?: objc_getAssociatedObject(self, &SVBDetectedCtxKey) ?: SVBContextAll;
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
    // v10.6.4: 转场期间就先处理一次 —— 白块不必等到 viewDidAppear 之后才消失
    SVBApplyChatChrome(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    SVB_SAFE_APPLY(SVBContextChat)
    SVBApplyChatBubbles(self);   // v10.5.0: 隐藏气泡只留文字
    SVBApplyChatChrome(self);    // v10.5.0: 顶部导航栏/底部输入栏整块隐藏 + 自行映射
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try { [[SVBManager shared] setContextActive:NO context:SVBContextChat]; } @catch (NSException *e) {}
    SVBRestoreChatBlur();
    SVBRestoreMappedBalloons();   // 撤掉气泡隐藏与文字映射
    SVBClearMappedChrome();       // 还原导航栏/输入栏
}
%end

// v10.6.5: 输入栏的「首帧闪白」。
// 输入栏是 inputAccessoryView, 它出现在屏幕上的**第一帧**还带着系统白底;
// 而主链路要等 viewDidAppear 之后的补扫才去清 => 那一帧被用户看见了(闪一下白)。
// 直接在输入栏 VC 自己的 viewWillAppear / viewDidAppear 里清, 赶在首帧之前。
// (Logos 对不存在的类会静默跳过, 所以写死这个类名不会崩, 只是不生效。)
%hook CKMessageEntryView
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    if (!SVBBubbleSweepActive()) return;
    @try { SVBTranslucentChromeView(self.view); } @catch (NSException *e) {}
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    if (!SVBBubbleSweepActive()) return;
    @try { SVBTranslucentChromeView(self.view); } @catch (NSException *e) {}
}
%end

// 消息气泡本体: 气泡图 = UIImage (CKBalloonView 继承 CKBalloonImageView 的 image)。
// 文字在 CKTextBalloonView 的 UITextView 子视图里, 清掉气泡图不影响文字。
// 注: CKBalloonView 只有前向声明, 属性一律经由 UIView* 访问
%hook CKBalloonView
// v10.6.6: 滚动复用 / 新消息插入时会有一帧气泡背景还没被清掉(用户说"气泡被卡出来"),
// 补一道 layoutSubviews —— 与 CKTextBalloonView 是同一套做法(那边本来就在用)。
- (void)layoutSubviews {
    %orig;
    if (SVBBubbleSweepActive()) SVBStripBalloonPaint((UIView *)self);
}
- (void)setBackgroundColor:(UIColor *)color {
    %orig;
    // 先让系统把色赋上, 再清掉; color 已是透明时不再赋值, 避免递归
    UIView *v = (UIView *)self;
    if (SVBBubbleSweepActive() && color && ![color isEqual:[UIColor clearColor]])
        SVBStripBalloonPaint(v);
}
- (void)didMoveToSuperview {
    %orig;
    if (SVBBubbleSweepActive()) SVBStripBalloonPaint((UIView *)self);
}
%end

// 文字类气泡: 整体藏掉 + 文字映射成自己的 UILabel (深色白字/浅色黑字)。
// didMoveToSuperview = 进层级就藏 (赶在首帧绘制前, 消除滚动/新消息时气泡闪一下);
// 布局/复用都会重新映射, 滚动复用不串内容。
%hook CKTextBalloonView
- (void)didMoveToSuperview {
    %orig;
    if (SVBBubbleSweepActive()) {
        // 此时文字可能还没赋值: 先把气泡藏住 (防闪), 文字在随后的 layoutSubviews 补映射
        @try {
            UIView *v = (UIView *)self;
            if (!v.hidden && v.superview) {
                if (!SVBHiddenBalloons) SVBHiddenBalloons = [NSMutableArray new];
                objc_setAssociatedObject(v, &SVBBalloonAlphaKey, @(v.alpha),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(v, &SVBBalloonHiddenKey, @(v.hidden),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [SVBHiddenBalloons addObject:v];
                v.hidden = YES;
            }
        } @catch (NSException *e) {}
    }
}
- (void)layoutSubviews {
    %orig;
    if (SVBBubbleSweepActive()) {
        SVBMapBalloonText((UIView *)self);
    } else {
        SVBRestoreMappedBalloons();
    }
}
- (void)prepareForReuse {
    %orig;
    // 复用: 撤掉自己的映射 label, 恢复可见 (新内容会在下一次 layoutSubviews 重新映射)
    UILabel *lb = objc_getAssociatedObject(self, &SVBMappedLabelKey);
    if (lb) {
        [lb removeFromSuperview];
        objc_setAssociatedObject(self, &SVBMappedLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *v = (UIView *)self;
    NSNumber *a = objc_getAssociatedObject(v, &SVBBalloonAlphaKey);
    if (a) v.alpha = a.doubleValue;
    else v.alpha = 1;
    v.hidden = NO;
    [SVBHiddenBalloons removeObject:v];
}
%end

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
// v10.5.2: 聊天页主 VC 的双保险 —— 兜底钩子的 viewWillAppear 里有「视图本体必须是
// 列表」的限制, CKChatController 走不到; 万一 %hook CKChatController 那条路没生效
// (类名在不同系统版本上不同), 这里再补一次。只认 ChatController, 不碰别的 VC。
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try {
        NSString *name = NSStringFromClass([self class]);
        if ([name containsString:@"ChatController"]) SVBApplyChatChrome(self);
    } @catch (NSException *e) {}
}
// v1.7.19: 只走兜底路径的页面 (如主页面/Filter 类) 离开时也要暂停自己的播放器,
// 防声音穿透到其它界面。按「实际挂载过的语境」精确暂停。
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try {
        NSString *applied = [[SVBManager shared] appliedContextForViewController:self];
        if (applied.length)
            [[SVBManager shared] setContextActive:NO context:applied];
    } @catch (NSException *e) {}
}
%end

// v1.7.21: 分区背景装饰视图 —— 分组白卡其实是 compositional list layout 的
// section 背景装饰 (报告实锤: _UICollectionViewListLayoutSectionBackgroundColorDecorationView)。
// 系统在布局失效时会反复重新赋色 (点选单元格/滚动都会触发) —— 钩它的
// setBackgroundColor:, 系统每铺一次白我就地改回透明, 事件驱动、零布局干扰。
// (装饰视图不是 cell, 改它的颜色不走 cell 背景变更流程, 安全。)
@interface _UICollectionViewListLayoutSectionBackgroundColorDecorationView : UIView @end
%hook _UICollectionViewListLayoutSectionBackgroundColorDecorationView
- (void)setBackgroundColor:(UIColor *)color {
    %orig;
    @try {
        if (!SVBIsSMSProcess()) return;
        if (!SVBMainSweepActive() && !SVBSMSListSweepActive()) return;
        if (color && ![color isEqual:[UIColor clearColor]])
            %orig([UIColor clearColor]);
    } @catch (NSException *e) {}
}
// v10.4.1: 布局期间就地再清一次 —— 滚动/复用会新建装饰视图, 它的白底可能
// 不是走 setBackgroundColor: 铺的 (或铺得比我们的钩子早一帧), 只在布局末尾
// 兜一道, 白带就不会先显示出来。(装饰视图不是 cell, 改色不触发集合布局重入)
- (void)layoutSubviews {
    %orig;
    @try {
        if (!SVBIsSMSProcess()) return;
        if (!SVBMainSweepActive() && !SVBSMSListSweepActive()) return;
        if (self.backgroundColor && ![self.backgroundColor isEqual:[UIColor clearColor]])
            self.backgroundColor = [UIColor clearColor];
        if (self.layer.backgroundColor &&
            !CGColorEqualToColor(self.layer.backgroundColor, [UIColor clearColor].CGColor))
            self.layer.backgroundColor = NULL;
    } @catch (NSException *e) {}
}
%end

// ------------------------------------------------------------------
// v10.4.1: 滚动期间的白带兜底 —— 系统在滚动/回弹时重铺白色卡片 (分区底、cell 容器),
// 往往比我们的「源头拦截」早一帧显示出来, 观感就是一条条白带。这里在滚动回调里做
// **极轻量**清扫: 只抹容器自身底色, 不碰系统托管的 backgroundView/selectedBackgroundView
// 子树、也不藏卡片 —— 避免 v1.7.21 那类「布局重入 -> SIGABRT」。
// 节流 0.12s, 且只在「本进程有可见视频背景」时才跑。
// ------------------------------------------------------------------
static CFAbsoluteTime sSVBLastScrollSweep = 0;

static void SVBScrollSweepList(UIView *scrollView) {
    for (UIView *v in scrollView.subviews) {
        if ([v isKindOfClass:[SVBVideoBackgroundView class]]) continue;
        if ([v isKindOfClass:[UICollectionViewCell class]] ||
            [v isKindOfClass:[UITableViewCell class]]) {
            // cell 本体 + contentView 底色 (改 UIView 底色不走集合布局失效, 安全)
            if (v.backgroundColor && ![v.backgroundColor isEqual:[UIColor clearColor]])
                v.backgroundColor = [UIColor clearColor];
            UIView *cv = [(UITableViewCell *)v contentView];
            if (cv.backgroundColor && ![cv.backgroundColor isEqual:[UIColor clearColor]])
                cv.backgroundColor = [UIColor clearColor];
            // cell 内部一层容器 (系统白卡/分区底) 浅清, 跳过文字图标等受保护控件
            for (UIView *s in v.subviews) {
                if (s == cv) continue;
                if ([s isKindOfClass:[SVBVideoBackgroundView class]]) continue;
                if ([s isKindOfClass:[UILabel class]] || [s isKindOfClass:[UIImageView class]] ||
                    [s isKindOfClass:[UIControl class]] || [s isKindOfClass:[UITextField class]] ||
                    [s isKindOfClass:[UIVisualEffectView class]]) continue;
                if (s.backgroundColor && ![s.backgroundColor isEqual:[UIColor clearColor]])
                    s.backgroundColor = [UIColor clearColor];
                if (s.layer.backgroundColor &&
                    !CGColorEqualToColor(s.layer.backgroundColor, [UIColor clearColor].CGColor))
                    s.layer.backgroundColor = NULL;
            }
        } else {
            // 装饰视图/容器 (非 cell): 底色 + layer 底色一起抹
            if (v.backgroundColor && ![v.backgroundColor isEqual:[UIColor clearColor]])
                v.backgroundColor = [UIColor clearColor];
            if (v.layer.backgroundColor &&
                !CGColorEqualToColor(v.layer.backgroundColor, [UIColor clearColor].CGColor))
                v.layer.backgroundColor = NULL;
        }
    }
}

static void SVBScrollSweepIfNeeded(UIScrollView *sv) {
    if (!sv) return;
    if (!SVBIsSMSProcess()) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sSVBLastScrollSweep < 0.12) return;
    if (!SVBSMSListSweepActive()) return;
    sSVBLastScrollSweep = now;
    @try { SVBScrollSweepList(sv); } @catch (NSException *e) {}
}

%hook UIScrollView
// 手指拖动/减速期间 UIKit 走 setBounds:, 程序化滚动走 setContentOffset: —— 两个都接
- (void)setBounds:(CGRect)bounds {
    %orig;
    @try {
        if ([self isKindOfClass:[UICollectionView class]] ||
            [self isKindOfClass:[UITableView class]]) SVBScrollSweepIfNeeded(self);
    } @catch (NSException *e) {}
}
- (void)setContentOffset:(CGPoint)contentOffset {
    %orig;
    @try {
        if ([self isKindOfClass:[UICollectionView class]] ||
            [self isKindOfClass:[UITableView class]]) SVBScrollSweepIfNeeded(self);
    } @catch (NSException *e) {}
}
- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    %orig;
    @try {
        if ([self isKindOfClass:[UICollectionView class]] ||
            [self isKindOfClass:[UITableView class]]) SVBScrollSweepIfNeeded(self);
    } @catch (NSException *e) {}
}
%end

// ------------------------------------------------------------------
// v1.8.5: App 名称自定义 —— installd/SpringBoard 会缓存 Info.plist 的显示名,
// 改 plist + 注销根本不刷新 (用户实测)。改从「显示层」钩:
// SpringBoard 里 SBApplication.displayName 就是桌面图标下的名字, 读我们的
// 配置 (app_display_name, 控制App 双通道写盘) 直接替换, 即存即显、注销也不丢。
// ------------------------------------------------------------------
@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end
%hook SBApplication
- (NSString *)displayName {
    NSString *orig = %orig;
    @try {
        if ([[self bundleIdentifier] isEqualToString:@"com.nvb.smsvideobg.app"]) {
            // v10.4.0g: 5 秒缓存 —— 桌面摆图标/切页会高频调 displayName,
            // 不缓存就是每次都开 NSUserDefaults 读盘, 桌面主线程被我们拖累
            static NSString *cached = nil;
            static CFAbsoluteTime last = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (!cached || now - last > 5.0) {
                last = now;
                cached = [[SVBManager shared] appDisplayName] ?: @"";
            }
            if (cached.length) return cached;
        }
    } @catch (NSException *e) {}
    return orig;
}
%end

// ------------------------------------------------------------------
// 插件入口: 写心跳 + 挂横幅 + 注册 Darwin 通知
// 这段在「任何被注入的进程」里都会跑 (信息App / 控制App / 其它)
// ------------------------------------------------------------------
%ctor {
    @autoreleasepool {   // 早期加载时主线程还没有 autorelease pool
        @try {
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            BOOL isSB = [proc isEqualToString:@"SpringBoard"];

            // v10.4.0g: SpringBoard (桌面) 崩溃 = 全机安全模式, 桌面侧零文件 IO ——
            // 心跳/日志只在宿主 App (信息/控制App) 里写, 桌面只保留 displayName 钩子
            // SpringBoard 只用 displayName 钩子, 不做素材迁移/诊断横幅 (防干扰桌面启动)
            if (!isSB) {
                [[SVBManager shared] writeHeartbeat:
                    [NSString stringWithFormat:@"tweak 已注入 %@", proc]];
                [[SVBManager shared] log:@"=== SMSVideoBG v%@ tweak loaded in %@ ===",
                    SVB_VERSION, proc];
                // 自愈迁移: 把 jbroot 等其它可读根里的旧素材搬进主根 (信息App 容器)
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [[SVBManager shared] migrateMediaIntoPrimaryRoot];
                    // v10.4.0: 旧名杂项改名/过期诊断日志删除/界面子目录摊平
                    SVBCleanupHousekeeping();
                });

                CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                NULL,
                                                SVBPrefsChanged,
                                                CFSTR(SVB_DARWIN_NOTE),
                                                NULL,
                                                CFNotificationSuspensionBehaviorDeliverImmediately);

                // v10.4.0f: 素材热刷新看门狗 —— Darwin 通知在宿主挂起/直接改文件时
                // 到不了, 换素材只能靠注销才生效; 这里 2 秒一检兜底
                [[SVBManager shared] startMediaWatchdog];

                // v9.9.11: 前后台自愈 —— 后台暂停、回前台重连显示管线并续播
                // (AVPlayerLayer 的内容会被系统回收, 光 play 不重绘 -> 卡在最后一帧)
                // 顺带监听音频中断结束 (来电/闹钟后自动续播)
                @try {
                    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
                    SVBManager *m = [SVBManager shared];
                    [nc addObserver:m selector:@selector(handleAppEnterBackground)
                               name:UIApplicationDidEnterBackgroundNotification object:nil];
                    [nc addObserver:m selector:@selector(handleAppWillEnterForeground)
                               name:UIApplicationWillEnterForegroundNotification object:nil];
                    [nc addObserver:m selector:@selector(handleAppDidBecomeActive)
                               name:UIApplicationDidBecomeActiveNotification object:nil];
                    [nc addObserver:m selector:@selector(handleAudioInterruption:)
                               name:AVAudioSessionInterruptionNotification object:nil];
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
        } @catch (NSException *e) {}
    }
}
