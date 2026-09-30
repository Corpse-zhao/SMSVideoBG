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
//   1. filter 只挂 com.apple.MobileSMS (信息App), 备忘录已拆分为独立工程。
//   2. 只在信息App 进程里做界面 Hook (SVBIsSMSProcess 守卫), 其它进程
//      只写心跳, 不干扰宿主。
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

static void SVBClearContainerBGs(UIView *v, NSInteger depth) {
    if (!v || depth > 14) return;
    if ([v isKindOfClass:[SVBVideoBackgroundView class]]) return;
    if (!SVBMainSweepActive()) { SVBRestoreHiddenCards(); return; }
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
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    SVB_SAFE_APPLY(SVBContextChat)
    SVBApplyChatBubbles(self);   // v10.5.0: 隐藏气泡只留文字
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try { [[SVBManager shared] setContextActive:NO context:SVBContextChat]; } @catch (NSException *e) {}
    SVBRestoreChatBlur();
    SVBRestoreMappedBalloons();   // 撤掉气泡隐藏与文字映射
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
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    SVB_SAFE_APPLY(SVBContextChat)
    SVBApplyChatBubbles(self);   // v10.5.0: 隐藏气泡只留文字
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SVB_SMS_GUARD()
    @try { [[SVBManager shared] setContextActive:NO context:SVBContextChat]; } @catch (NSException *e) {}
    SVBRestoreChatBlur();
    SVBRestoreMappedBalloons();   // 撤掉气泡隐藏与文字映射
}
%end

// 消息气泡本体: 气泡图 = UIImage (CKBalloonView 继承 CKBalloonImageView 的 image)。
// 文字在 CKTextBalloonView 的 UITextView 子视图里, 清掉气泡图不影响文字。
// 注: CKBalloonView 只有前向声明, 属性一律经由 UIView* 访问
%hook CKBalloonView
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
        if (!SVBMainSweepActive()) return;
        if (color && ![color isEqual:[UIColor clearColor]])
            %orig([UIColor clearColor]);
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
// 这段在「任何被注入的进程」里都会跑 (信息App / 备忘录探针 / 其它)
// ------------------------------------------------------------------
%ctor {
    @autoreleasepool {   // 早期加载时主线程还没有 autorelease pool
        @try {
            NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
            BOOL isSB = [proc isEqualToString:@"SpringBoard"];

            // v10.4.0g: SpringBoard (桌面) 崩溃 = 全机安全模式, 桌面侧零文件 IO ——
            // 心跳/日志只在宿主 App (信息/备忘录探针) 里写, 桌面只保留 displayName 钩子
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
