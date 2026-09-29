#import "AppDelegate.h"
#import "SVBAuth.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <AVKit/AVKit.h>

// ============================================================
// 控制App主页: 总开关 + 全局效果 + 七类界面开关 + 素材管理页
// v1.8: 精致现代风 —— 渐变主色 / 卡片式分组 / 渐变徽章图标 / 现代滑杆
//       (只动 UI 层, 配置与导入逻辑零改动)
// ============================================================

static char SVBSwitchAssocKey;
static char SVBProxyAssocKey;

#pragma mark - 主题

// 主色: 玫红 -> 紫 (视频工具气质, 与素材气质呼应)
static UIColor *SVBAccent(void)  { return [UIColor colorWithRed:0.98 green:0.27 blue:0.51 alpha:1.0]; }
static UIColor *SVBAccent2(void) { return [UIColor colorWithRed:0.63 green:0.32 blue:0.98 alpha:1.0]; }
// 卡片底色 (自动适配深色模式)
static UIColor *SVBCardColor(void) { return [UIColor secondarySystemGroupedBackgroundColor]; }
// 选中态卡片底色 (比卡片略深一档)
static UIColor *SVBCardSelectedColor(void) { return [UIColor tertiarySystemGroupedBackgroundColor]; }

// 圆角渐变底 + 白色 SF Symbol -> 行首徽章图标 (符号缺失时退化为纯渐变方块)
static UIImage *SVBBadgeIcon(NSString *symbol, UIColor *c1, UIColor *c2) {
    CGFloat s = 29;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat new];
    fmt.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s)
                                                     cornerRadius:8.5];
        [p addClip];
        CGGradientRef g = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)(@[
            (id)c1.CGColor, (id)c2.CGColor]), NULL);
        if (g) {
            CGContextDrawLinearGradient(ctx.CGContext, g, CGPointMake(0, 0), CGPointMake(s, s), 0);
            CGGradientRelease(g);
        }
        UIImage *sym = symbol ? [UIImage systemImageNamed:symbol] : nil;
        UIImage *white = sym ? [sym imageWithTintColor:[UIColor whiteColor]] : nil;
        if (white) {
            CGFloat box = 16.5;
            CGFloat k = MIN(box / MAX(white.size.width, 0.5), box / MAX(white.size.height, 0.5));
            CGSize ds = CGSizeMake(MAX(white.size.width * k, 1), MAX(white.size.height * k, 1));
            [white drawInRect:CGRectMake((s - ds.width) / 2, (s - ds.height) / 2, ds.width, ds.height)];
        }
    }];
}

// 七类界面 + 功能行的徽章配色表
static UIImage *SVBIconForKey(NSString *key) {
    UIColor *p1 = [UIColor colorWithRed:0.98 green:0.27 blue:0.51 alpha:1];
    UIColor *p2 = [UIColor colorWithRed:0.63 green:0.32 blue:0.98 alpha:1];
    if ([key isEqualToString:SVBContextMain])    return SVBBadgeIcon(@"square.grid.2x2.fill", p1, p2);
    if ([key isEqualToString:SVBContextAll])     return SVBBadgeIcon(@"bubble.left.and.bubble.right.fill",
                                            [UIColor colorWithRed:0.25 green:0.55 blue:1.0 alpha:1],
                                            [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1]);
    if ([key isEqualToString:SVBContextKnown])   return SVBBadgeIcon(@"person.crop.circle.fill",
                                            [UIColor colorWithRed:0.00 green:0.72 blue:0.63 alpha:1],
                                            [UIColor colorWithRed:0.20 green:0.85 blue:0.75 alpha:1]);
    if ([key isEqualToString:SVBContextUnknown]) return SVBBadgeIcon(@"questionmark.circle.fill",
                                            [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1],
                                            [UIColor colorWithRed:1.00 green:0.75 blue:0.20 alpha:1]);
    if ([key isEqualToString:SVBContextUnread])  return SVBBadgeIcon(@"envelope.badge.fill",
                                            [UIColor colorWithRed:1.00 green:0.29 blue:0.29 alpha:1],
                                            [UIColor colorWithRed:1.00 green:0.50 blue:0.40 alpha:1]);
    if ([key isEqualToString:SVBContextJunk])    return SVBBadgeIcon(@"trash.fill",
                                            [UIColor colorWithRed:0.45 green:0.50 blue:0.60 alpha:1],
                                            [UIColor colorWithRed:0.60 green:0.65 blue:0.75 alpha:1]);
    if ([key isEqualToString:SVBContextDeleted]) return SVBBadgeIcon(@"arrow.uturn.left.circle.fill",
                                            [UIColor colorWithRed:0.63 green:0.32 blue:0.98 alpha:1],
                                            [UIColor colorWithRed:0.50 green:0.55 blue:1.00 alpha:1]);
    if ([key isEqualToString:SVBContextChat])    return SVBBadgeIcon(@"message.fill",
                                            [UIColor colorWithRed:1.00 green:0.36 blue:0.47 alpha:1],
                                            [UIColor colorWithRed:1.00 green:0.55 blue:0.45 alpha:1]);
    if ([key isEqualToString:@"__master"])       return SVBBadgeIcon(@"sparkles", p1, p2);
    if ([key isEqualToString:@"__debug"])        return SVBBadgeIcon(@"ant.fill",
                                            [UIColor colorWithRed:0.45 green:0.50 blue:0.60 alpha:1],
                                            [UIColor colorWithRed:0.62 green:0.67 blue:0.77 alpha:1]);
    if ([key isEqualToString:@"__folder"])       return SVBBadgeIcon(@"folder.fill",
                                            [UIColor colorWithRed:0.25 green:0.55 blue:1.00 alpha:1],
                                            [UIColor colorWithRed:0.45 green:0.70 blue:1.00 alpha:1]);
    if ([key isEqualToString:@"__diag"])         return SVBBadgeIcon(@"doc.text.magnifyingglass",
                                            [UIColor colorWithRed:0.35 green:0.35 blue:0.95 alpha:1],
                                            [UIColor colorWithRed:0.55 green:0.45 blue:1.00 alpha:1]);
    if ([key isEqualToString:@"__import"])       return SVBBadgeIcon(@"plus.circle.fill",
                                            [UIColor colorWithRed:0.98 green:0.27 blue:0.51 alpha:1],
                                            [UIColor colorWithRed:0.63 green:0.32 blue:0.98 alpha:1]);
    // v10.3.0: 跳转素材文件夹
    if ([key isEqualToString:@"__open"])         return SVBBadgeIcon(@"arrow.up.forward.app.fill",
                                            [UIColor colorWithRed:0.20 green:0.62 blue:0.92 alpha:1],
                                            [UIColor colorWithRed:0.35 green:0.80 blue:0.98 alpha:1]);
    if ([key isEqualToString:@"__video"])        return SVBBadgeIcon(@"video.fill",
                                            [UIColor colorWithRed:0.30 green:0.69 blue:0.45 alpha:1],
                                            [UIColor colorWithRed:0.45 green:0.82 blue:0.55 alpha:1]);
    return nil;
}

// 卡片式单元格: 每行挂圆角背景 (首行上圆角/末行下圆角/中行直角), 组内成一体
static void SVBApplyCardStyle(UITableViewCell *cell, NSInteger row, NSInteger rows) {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = SVBCardColor();
    card.layer.cornerRadius = 16;
    card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner
                             | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    if (rows > 1) {
        if (row == 0)
            card.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        else if (row == rows - 1)
            card.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        else
            card.layer.cornerRadius = 0;
    }
    cell.backgroundView = card;
    UIView *sel = [[UIView alloc] init];
    sel.backgroundColor = SVBCardSelectedColor();
    sel.layer.cornerRadius = card.layer.cornerRadius;
    sel.layer.maskedCorners = card.layer.maskedCorners;
    cell.selectedBackgroundView = sel;
}

#pragma mark - v10.3.0 跳转素材路径

// 跳转到统一素材路径 (/var/mobile/信息视频背景素材/板栗仁)。
// 先用 SVBEnsureFriendlyMediaPath 把目录/软链自愈好, 再交给 Filza 打开;
// 没装 Filza 时把路径复制到剪贴板并弹窗说明。
static void SVBJumpToMediaPath(UIViewController *vc, NSString *path) {
    NSString *ensureMsg = nil;
    if (!SVBEnsureFriendlyMediaPath(&ensureMsg)) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"素材路径不可用"
                             message:ensureMsg ?: @"未知错误"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:ac animated:YES completion:nil];
        return;
    }
    NSString *msg = nil;
    if (SVBOpenPathInFilza(path, &msg)) return;    // 已经跳到 Filza
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"素材路径"
                         message:msg ?: path
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

#pragma mark - v10.4.0e 诊断报告开关式 (记录器)

// 报告文件夹与「板栗仁」文件夹同级: /var/mobile/信息视频背景素材/看不懂的报告/
// 开关打开 = 开始记录; 关闭 = 停止并把过程日志存成「文件名带生成时间」的正式文件
static NSString *SVBDiagnoseReportDir(void) {
    return [SVB_MEDIA_FRIENDLY_PARENT stringByAppendingPathComponent:@"看不懂的报告"];
}

// 开关状态存配置 diagnose_report
static BOOL SVBDiagnoseReportEnabled(void) {
    id v = [[SVBManager shared] configValueForKey:@"diagnose_report"];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}

// 完整诊断报告文本 (快照内容; 函数体在文件末尾 SVBDiagnosticsController 段之前)
static NSString *SVBGenerateDiagnoseReport(void);

// 时间戳: 文件名/快照头用
static NSString *SVBDiagStamp(NSDate *d) {
    static NSDateFormatter *df = nil;
    if (!df) {
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    }
    return [df stringFromDate:d ?: [NSDate date]] ?: @"unknown";
}

// 进行中的日志 (点前缀隐藏, 关闭时改名成正式文件)
static NSString *SVBDiagWorkingPath(void) {
    return [SVBDiagnoseReportDir() stringByAppendingPathComponent:@".svb_report_session.log"];
}

// 追加一份快照到进行中的日志
static void SVBDiagAppendSnapshot(NSString *reason) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = SVBDiagnoseReportDir();
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"\n---- 快照 %@ (%@) ----\n", SVBDiagStamp(nil), reason ?: @"定时"];
        [s appendString:SVBGenerateDiagnoseReport() ?: @""];
        NSString *p = SVBDiagWorkingPath();
        NSFileHandle *h = [fm fileHandleForWritingAtPath:p];
        if (!h) {
            NSString *head = [NSString stringWithFormat:
                @"==== 诊断记录开始 %@ ====\n", SVBDiagStamp(nil)];
            [fm createFileAtPath:p
                          contents:[head dataUsingEncoding:NSUTF8StringEncoding]
                         attributes:nil];
            h = [fm fileHandleForWritingAtPath:p];
        }
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (NSException *e) {}
}

// 关闭开关: 进行中的日志改名成带生成时间的正式文件
static void SVBDiagFinalize(void) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *p = SVBDiagWorkingPath();
        if (![fm fileExistsAtPath:p]) return;
        NSFileHandle *h = [fm fileHandleForWritingAtPath:p];
        if (h) {
            [h seekToEndOfFile];
            NSData *tail = [[NSString stringWithFormat:
                @"==== 记录结束 %@ ====\n", SVBDiagStamp(nil)]
                dataUsingEncoding:NSUTF8StringEncoding];
            [h writeData:tail];
            [h closeFile];
        }
        NSString *final = [SVBDiagnoseReportDir() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"诊断报告_生成时间%@.txt", SVBDiagStamp(nil)]];
        if ([fm fileExistsAtPath:final]) [fm removeItemAtPath:final error:nil];
        [fm moveItemAtPath:p toPath:final error:nil];
    } @catch (NSException *e) {}
}

// 记录期间定时快照 (60 秒一份; App 被杀后下次启动开关还开着就接着记)
static NSTimer *sSVBDiagTimer = nil;

static void SVBDiagStartTimer(void) {
    if (sSVBDiagTimer) return;
    sSVBDiagTimer = [NSTimer timerWithTimeInterval:60.0 repeats:YES block:^(NSTimer *t) {
        if (!SVBDiagnoseReportEnabled()) {
            [t invalidate];
            sSVBDiagTimer = nil;
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            SVBDiagAppendSnapshot(@"定时");
        });
    }];
    [[NSRunLoop mainRunLoop] addTimer:sSVBDiagTimer forMode:NSRunLoopCommonModes];
}

static void SVBDiagStopTimer(void) {
    if (sSVBDiagTimer) {
        [sSVBDiagTimer invalidate];
        sSVBDiagTimer = nil;
    }
}

// App 启动: 开关开着就接着记 (补一条「App 启动」快照), 关着不动旧报告
static void SVBDiagnoseReportResume(void) {
    if (!SVBDiagnoseReportEnabled()) return;
    SVBEnsureFriendlyMediaPath(NULL);
    SVBDiagAppendSnapshot(@"控制App 启动");
    SVBDiagStartTimer();
}

#pragma mark - AppDelegate

@implementation SVBAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[SVBManager shared] log:@"=== 控制App 启动 ==="];
    // v10.3.0: 先把统一素材路径 /var/mobile/信息视频背景素材/板栗仁 建好(软链自愈),
    // 再把 jbroot/Documents/家目录等旧根里的素材搬进真实素材根 (信息App 容器)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SVBEnsureFriendlyMediaPath(NULL);
        [[SVBManager shared] migrateMediaIntoPrimaryRoot];
        // v10.4.0: 旧名杂项改名 / 过期诊断日志删除 / 界面子目录摊平
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            SVBCleanupHousekeeping();
        });
        // v10.4.0e: 诊断报告开关 —— 开着就接着记录过程日志, 关着不动旧报告
        SVBDiagnoseReportResume();
    });
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SVBHomeViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    nav.navigationBar.prefersLargeTitles = YES;
    nav.view.tintColor = SVBAccent();   // v1.8: 全局主色 (返回按钮/按钮/勾选)
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

// URL Scheme 兜底入口 (smsvideobg://open)
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    return YES;
}

@end

#pragma mark - 相册导入 (v1.7: 多选批量 + 三路线加载 + 不嵌套调用 + 失败原因透出)
//
// 「很多素材导不进来」的三个根因, 这里逐一拆掉:
//   1) 旧版第一路线 loadDataRepresentation 会把整个视频读进内存
//      -> 手机拍的 4K/长视频必然失败或被系统内存杀掉 -> 改成最后才用的兜底路线
//      现在顺序: 就地文件(零拷贝) -> 文件表示(流式, 不占内存) -> 内存数据流
//   2) 旧版在第一个 load 的 completion 里直接发起第二个 load
//      -> NSItemProvider 内部加载是串行的, 这会排队僵死, 现象就是「选了视频一直没反应」
//      -> 现在每一次尝试都换队列/换调用栈再发起
//   3) 旧版只在 provider 的第一个匹配 UTI 上死磕 (常见只给抽象类型 public.movie)
//      -> 现在把注册类型按「具体 UTI -> 抽象 UTI」全试一遍
// 另: 保留相册原始文件名 (provider.suggestedName), 便于在列表里辨认。

static NSArray<NSString *> *SVBOrderedTypes(NSItemProvider *provider) {
    NSArray *raw = ((NSArray *(*)(id, SEL))objc_msgSend)(provider, @selector(registeredTypeIdentifiers));
    if (![raw isKindOfClass:[NSArray class]]) raw = @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSArray *pref = @[@"com.apple.quicktime-movie", @"public.mpeg-4", @"public.mpeg-4-video",
                      @"com.apple.m4v-video", @"public.3gpp", @"public.avi",
                      @"public.movie", @"public.video", @"public.audiovisual-content", @"public.data"];
    for (NSString *p in pref)
        if ([raw containsObject:p] && ![out containsObject:p]) [out addObject:p];
    for (NSString *t in raw)
        if ([t isKindOfClass:[NSString class]] && ![out containsObject:t]) [out addObject:t];
    if (!out.count) [out addObject:@"public.movie"];
    return out;
}

// 相册视频原始文件名 (拿不到就 UUID)
static NSString *SVBSuggestedFileName(NSItemProvider *provider) {
    NSString *sug = nil;
    SEL sel = NSSelectorFromString(@"suggestedName");
    if ([provider respondsToSelector:sel]) sug = ((id (*)(id, SEL))objc_msgSend)(provider, sel);
    if (![sug isKindOfClass:[NSString class]] || !sug.length)
        return [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"mp4"];
    sug = sug.lastPathComponent;                       // 去掉任何路径成分
    NSString *base = sug.stringByDeletingPathExtension;
    NSString *ext  = sug.pathExtension.lowercaseString;
    if (!base.length) base = [NSUUID UUID].UUIDString;
    if (!ext.length || ![@[@"mp4", @"mov", @"m4v", @"3gp", @"mkv", @"webm"] containsObject:ext]) ext = @"mp4";
    return [base stringByAppendingPathExtension:ext];
}

static void SVBFetchStep(NSItemProvider *provider, NSArray<NSString *> *types,
                         NSInteger mode, NSUInteger ti, NSString *dstPath,
                         SVBManager *mgr, NSMutableArray<NSString *> *failures,
                         void (^done)(BOOL ok, NSString *why));

// 换队列/换调用栈再进入下一个尝试 (关键: 破除 NSItemProvider 串行加载队列僵死)
static void SVBFetchNext(NSItemProvider *provider, NSArray<NSString *> *types, NSInteger mode, NSUInteger ti,
                         NSString *dstPath, SVBManager *mgr, NSMutableArray<NSString *> *failures,
                         void (^done)(BOOL ok, NSString *why)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SVBFetchStep(provider, types, mode, ti, dstPath, mgr, failures, done);
    });
}

// mode: 0=就地文件 1=文件表示 2=内存数据流
static void SVBFetchStep(NSItemProvider *provider, NSArray<NSString *> *types, NSInteger mode, NSUInteger ti,
                         NSString *dstPath, SVBManager *mgr, NSMutableArray<NSString *> *failures,
                         void (^done)(BOOL ok, NSString *why)) {
    if (mode > 2) {
        done(NO, failures.count ? [failures componentsJoinedByString:@" | "] : @"未知原因");
        return;
    }
    if (ti >= types.count) { SVBFetchNext(provider, types, mode + 1, 0, dstPath, mgr, failures, done); return; }

    NSString *type = types[ti];
    NSString *modeName = (mode == 0 ? @"就地" : (mode == 1 ? @"文件" : @"内存"));
    NSFileManager *fm = [NSFileManager defaultManager];

    void (^fail)(NSString *why) = ^(NSString *why) {
        NSString *tag = [NSString stringWithFormat:@"[%@/%@]", modeName, type];
        [mgr log:@"相册导入 %@ 不行: %@", tag, why ?: @"失败"];
        [failures addObject:[NSString stringWithFormat:@"%@ %@", tag, why ?: @"失败"]];
        SVBFetchNext(provider, types, mode, ti + 1, dstPath, mgr, failures, done);
    };

    SEL sel = nil;
    if (mode == 0)      sel = NSSelectorFromString(@"loadInPlaceFileRepresentationForTypeIdentifier:completionHandler:");
    else if (mode == 1) sel = NSSelectorFromString(@"loadFileRepresentationForTypeIdentifier:completionHandler:");
    else                sel = NSSelectorFromString(@"loadDataRepresentationForTypeIdentifier:completionHandler:");
    if (![provider respondsToSelector:sel]) { fail(@"系统不支持该方式"); return; }

    if (mode == 2) {
        ((void (*)(id, SEL, NSString *, void (^)(NSData *, NSError *)))objc_msgSend)(provider, sel, type,
            ^(NSData *data, NSError *err) {
                if (!data.length) { fail(err.localizedDescription ?: @"数据为空"); return; }
                [fm removeItemAtPath:dstPath error:nil];
                NSError *wErr = nil;
                if ([data writeToFile:dstPath options:NSDataWritingAtomic error:&wErr]) done(YES, nil);
                else fail(wErr.localizedDescription ?: @"写盘失败");
            });
        return;
    }

    ((void (*)(id, SEL, NSString *, void (^)(NSURL *, NSError *)))objc_msgSend)(provider, sel, type,
        ^(NSURL *url, NSError *err) {
            if (!url) { fail(err.localizedDescription ?: @"未返回文件"); return; }
            BOOL scoped = [url startAccessingSecurityScopedResource];
            @try {
                [fm removeItemAtPath:dstPath error:nil];
                NSError *cErr = nil;
                if ([fm copyItemAtPath:url.path toPath:dstPath error:&cErr]) done(YES, nil);
                else fail(cErr.localizedDescription ?: @"复制失败");
            } @catch (NSException *e) {
                fail(e.reason ?: @"异常");
            }
            if (scoped) [url stopAccessingSecurityScopedResource];
        });
}

// 串行处理每个选中项: 取到临时文件 -> 立刻 process 导入 -> 删临时文件
// (逐个处理而不是全部下载完再导入 -> 临时目录不会被撑爆)
// process 返回 nil 表示成功, 否则返回失败原因
static void SVBRunImportQueue(NSArray *results, NSUInteger idx, NSString *tmpDir, SVBManager *mgr,
                              NSString *(^process)(NSURL *tmpURL),
                              NSMutableArray<NSString *> *errs, NSInteger okCount,
                              void (^done)(NSInteger okCount)) {
    if (idx >= results.count) { done(okCount); return; }

    NSItemProvider *provider = nil;
    id res = results[idx];
    SEL ipSel = NSSelectorFromString(@"itemProvider");
    if ([res respondsToSelector:ipSel]) provider = ((id (*)(id, SEL))objc_msgSend)(res, ipSel);
    if (!provider) {
        [errs addObject:[NSString stringWithFormat:@"第%lu个: 读取相册素材失败", (unsigned long)(idx + 1)]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            SVBRunImportQueue(results, idx + 1, tmpDir, mgr, process, errs, okCount, done);
        });
        return;
    }

    NSArray<NSString *> *types = SVBOrderedTypes(provider);
    [mgr log:@"相册导入 [%lu/%lu] 可选类型=%@", (unsigned long)(idx + 1), (unsigned long)results.count, types];
    NSString *dst = [tmpDir stringByAppendingPathComponent:SVBSuggestedFileName(provider)];

    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    SVBFetchStep(provider, types, 0, 0, dst, mgr, failures, ^(BOOL ok, NSString *why) {
        // provider 的回调线程不保证是后台 -> 立刻切走, 复制大文件绝不占主线程
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSInteger nextOk = okCount;
            if (ok) {
                NSString *reason = process ? process([NSURL fileURLWithPath:dst]) : @"内部错误";
                if (!reason) {
                    nextOk++;
                    [mgr log:@"相册导入 成功 [%lu/%lu]", (unsigned long)(idx + 1), (unsigned long)results.count];
                } else {
                    [errs addObject:[NSString stringWithFormat:@"第%lu个(%@): %@",
                                     (unsigned long)(idx + 1), dst.lastPathComponent, reason]];
                }
            } else {
                [errs addObject:[NSString stringWithFormat:@"第%lu个: %@", (unsigned long)(idx + 1), why ?: @"失败"]];
            }
            [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
            SVBRunImportQueue(results, idx + 1, tmpDir, mgr, process, errs, nextOk, done);
        });
    });
}

// 调起相册选择器 (多选), 回调 results = PHPickerResult 数组 (主线程)
static void SVBAppPickVideos(UIViewController *host, void (^done)(NSArray *results)) {
    void *h = dlopen("/System/Library/Frameworks/PhotosUI.framework/PhotosUI", RTLD_LAZY);
    Class pickerCls = h ? NSClassFromString(@"PHPickerViewController") : nil;
    Class cfgCls    = h ? NSClassFromString(@"PHPickerConfiguration") : nil;
    if (!pickerCls || !cfgCls) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"暂不可用"
                             message:@"无法调起相册选择器，请用 Filza 把视频放进素材文件夹。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:ac animated:YES completion:nil];
        return;
    }

    id cfg = [[cfgCls alloc] init];
    Class filterCls = NSClassFromString(@"PHPickerFilter");
    if (filterCls) {
        id filter = ((id (*)(id, SEL))objc_msgSend)(filterCls, @selector(videosFilter));
        ((void (*)(id, SEL, id))objc_msgSend)(cfg, @selector(setFilter:), filter);
    }
    ((void (*)(id, SEL, long))objc_msgSend)(cfg, @selector(setSelectionLimit:), (long)20);
    // 原始格式 (1 = Current): 不触发系统转码 —— 转码失败是「导不进来」的常见来源
    SEL repSel = NSSelectorFromString(@"setPreferredAssetRepresentationMode:");
    if ([cfg respondsToSelector:repSel]) ((void (*)(id, SEL, long))objc_msgSend)(cfg, repSel, (long)1);

    id pc = ((id (*)(id, SEL))objc_msgSend)(pickerCls, @selector(alloc));
    pc    = ((id (*)(id, SEL, id))objc_msgSend)(pc, @selector(initWithConfiguration:), cfg);

    // 代理对象: 运行时小类实现 picker:didFinishPicking: (不声明协议)
    Class proxyCls = objc_getClass("SVBPickerProxy");
    if (!proxyCls) {
        proxyCls = objc_allocateClassPair([NSObject class], "SVBPickerProxy", 0);
        class_addMethod(proxyCls, @selector(picker:didFinishPicking:),
                        imp_implementationWithBlock(^(id self, id picker, NSArray *results) {
            NSArray *list = [results isKindOfClass:[NSArray class]] ? results : @[];
            void (^handler)(NSArray *) = objc_getAssociatedObject(picker, "doneBlock");
            // 必须等选择器完全收起后再回调: 否则接下来 present 进度框会被「正在转场」挡掉
            [picker dismissViewControllerAnimated:YES completion:^{
                if (list.count && handler) handler(list);
            }];
        }), "v@:@@");
        objc_registerClassPair(proxyCls);
    }
    id proxy = [[proxyCls alloc] init];
    // PHPicker 的 delegate 是 weak 引用 -> 用关联对象挂在 picker 上保活
    objc_setAssociatedObject(pc, &SVBProxyAssocKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pc, "doneBlock", done, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(pc, @selector(setDelegate:), proxy);
    [host presentViewController:pc animated:YES completion:nil];
}

// 导入结果汇总 (成功/失败原因一目了然, 不再"点了没反应")
static void SVBShowImportSummary(UIViewController *host, NSInteger okCount, NSInteger total,
                                 NSArray<NSString *> *errs) {
    [[SVBManager shared] postChangeNotification];
    if ([host isKindOfClass:[UITableViewController class]])
        [[(UITableViewController *)host tableView] reloadData];

    NSString *title = errs.count == 0 ? @"导入完成" : (okCount > 0 ? @"部分导入完成" : @"导入失败");
    NSMutableString *msg = [NSMutableString stringWithFormat:@"成功 %ld / %ld 个。", (long)okCount, (long)total];
    if (errs.count) {
        [msg appendString:@"\n\n失败原因：\n"];
        NSArray *show = errs.count > 5 ? [errs subarrayWithRange:NSMakeRange(0, 5)] : errs;
        [msg appendString:[show componentsJoinedByString:@"\n"]];
        if (errs.count > 5) [msg appendFormat:@"\n… 另有 %ld 个", (long)(errs.count - 5)];
        for (NSString *e in errs)
            if ([e containsString:@"iCloud"] || [e containsString:@"network"] || [e containsString:@"Network"]) {
                [msg appendString:@"\n\n提示：部分视频可能还在 iCloud 云端，请先在「照片」里下载到本机再导入。"];
                break;
            }
        [msg appendString:@"\n\n（详细日志见主页底部「诊断报告」）"];
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:ac animated:YES completion:nil];
}

// 从相册导入素材到某个界面 (多选 + 逐个导入 + 进度提示 + 结果汇总)
static void SVBAppImportFromLibrary(UIViewController *host, NSString *ctx) {
    SVBManager *mgr = [SVBManager shared];
    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"svb_import"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir
                             withIntermediateDirectories:YES attributes:nil error:nil];

    SVBAppPickVideos(host, ^(NSArray *results) {
        UIAlertController *hud = [UIAlertController
            alertControllerWithTitle:@"正在导入视频…"
                             message:[NSString stringWithFormat:@"共 %lu 个，大视频请多等一会儿",
                                      (unsigned long)results.count]
                      preferredStyle:UIAlertControllerStyleAlert];
        // 等进度框真正显示出来再开工 (小文件瞬间完成时, 否则 dismiss 会被忽略)
        [host presentViewController:hud animated:YES completion:^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSMutableArray<NSString *> *errs = [NSMutableArray array];
                SVBRunImportQueue(results, 0, tmpDir, mgr, ^NSString *(NSURL *tmpURL) {
                    NSError *err = nil;
                    NSString *name = [mgr importVideoFromFile:tmpURL toContext:ctx error:&err];
                    if (name) return nil;
                    return err.localizedDescription ?: @"复制到素材目录失败";
                }, errs, 0, ^(NSInteger okCount) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSInteger total = (NSInteger)results.count;
                        if (hud.presentingViewController) {
                            [hud dismissViewControllerAnimated:YES completion:^{
                                SVBShowImportSummary(host, okCount, total, errs);
                            }];
                        } else {
                            SVBShowImportSummary(host, okCount, total, errs);
                        }
                    });
                });
            });
        }];
    });
}

#pragma mark - 滑杆单元格 (UISlider + 右侧数值)

// v10.1.0: 通用长文本页 (授权诊断报告等)
@interface SVBTextViewController : UIViewController
@property (nonatomic, copy) NSString *headTitle;
@property (nonatomic, copy) NSString *text;
@end

@interface SVBSliderCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, copy)   void (^onValue)(double value);
@property (nonatomic, copy)   NSString *(^displayFmt)(double);
- (void)setTitle:(NSString *)t value:(double)v max:(double)m display:(NSString *(^)(double))fmt;
@end

@implementation SVBSliderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _valueLabel = [UILabel new];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
        _valueLabel.textColor = SVBAccent();
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _slider = [UISlider new];
        _slider.continuous = YES;
        _slider.minimumTrackTintColor = SVBAccent();
        _slider.maximumTrackTintColor = [UIColor tertiarySystemFillColor];
        _slider.tintColor = SVBAccent();
        [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];

        [self.contentView addSubview:_titleLabel];
        [self.contentView addSubview:_valueLabel];
        [self.contentView addSubview:_slider];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _slider.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
            [_slider.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_slider.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_slider.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
            [_slider.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        ]];
    }
    return self;
}

- (void)setTitle:(NSString *)t value:(double)v max:(double)m display:(NSString *(^)(double))fmt {
    self.titleLabel.text = t;
    self.displayFmt = fmt;
    self.slider.minimumValue = 0;
    self.slider.maximumValue = (float)m;
    self.slider.value = (float)v;
    self.valueLabel.text = fmt ? fmt(v) : [NSString stringWithFormat:@"%.2f", v];
}

- (void)sliderChanged:(UISlider *)s {
    self.valueLabel.text = self.displayFmt ? self.displayFmt(s.value)
                                           : [NSString stringWithFormat:@"%.2f", s.value];
}

- (void)sliderEnded:(UISlider *)s {
    if (self.onValue) self.onValue(s.value);
}

@end

#pragma mark - 主页

@implementation SVBHomeViewController {
    NSArray<NSArray<NSString *> *> *_defs;
    // v10.3.0: 未授权时首页只留「授权」一栏 (开关全部隐藏), 且无需再点进授权页
    SVBAuthState _authState;
    NSString *_authDetail;
    BOOL _authSyncing;
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        _defs = SVBContextDefinitions();
        self.title = @"信息视频背景";
    }
    return self;
}

#pragma mark - v10.0.1 未授权时首页只显示授权栏

// 已授权 -> 完整设置页; 未授权/过期 -> 只显示授权栏
- (BOOL)authOK { return SVBIsLicensed(); }

// v10.3.0: 授权 = 纯离线授权串 (插件零网络请求)
- (NSInteger)authRowCount { return 3; }
// 行语义: 0=授权状态  1=本机 UDID  2=粘贴离线授权
- (NSInteger)authRowKindAt:(NSInteger)row {
    if (row == 0) return 0;
    if (row == 1) return 1;
    return (row == 2) ? 2 : -1;
}

- (void)svbReloadAuthState {
    NSString *det = nil;
    SVBAuthInvalidateCache();           // v10.3.0: 纯本地复算, 无任何联网
    _authState = SVBAuthCurrentState(&det);
    _authDetail = det;
}

- (void)svbCopyUDID {
    NSString *udid = SVBAuthUDID();
    if (!udid.length) {
        [self svbAlert:@"读不到 UDID"
                   msg:@"本机读不到硬件 UDID / 序列号，没法走 UDID 授权。\n"
                        @"请联系作者说明情况。"];
        return;
    }
    [UIPasteboard generalPasteboard].string = udid;
    [self svbAlert:@"UDID 已复制"
               msg:[NSString stringWithFormat:
        @"%@\n\n识别方式：%@\n把它发给作者，作者会回你一段以 SVBOFFLINE1: 开头的授权串。\n\n"
        @"拿到后回到本页点「粘贴离线授权」导入即可 —— 不用联网、不需要梯子。",
        udid, SVBAuthUDIDSource()]];
}

- (void)svbClearLicense {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"清除本机授权？"
                         message:@"清除后本机变回未授权（视频背景开关会被隐藏），"
                                 @"把之前作者发的授权串重新粘回来即可恢复。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        SVBAuthClearTicket();
        [w svbReloadAuthState];
        [w.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.tableView;
    ac.popoverPresentationController.sourceRect =
        CGRectMake(self.tableView.bounds.size.width / 2, 80, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)svbAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// v1.8: 首页 Hero 渐变卡 (标题+副标题+渐变图标, 替代系统大标题)
// v1.8.6: 副标题可自定义 (默认「不要为了升级而放弃越狱的快乐」, 长按 Hero 卡编辑)
- (NSString *)heroSubtitle {
    NSString *s = [[SVBManager shared] configValueForKey:@"hero_subtitle"];
    return [s isKindOfClass:[NSString class]] && s.length ? s : @"不要为了升级而放弃越狱的快乐";
}

- (UIView *)makeHeroHeader {
    CGFloat w = [UIScreen mainScreen].bounds.size.width - 24;
    CGFloat h = 112;
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w + 24, h + 16)];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(12, 8, w, h)];
    card.layer.cornerRadius = 20;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = card.bounds;
    g.colors = @[(id)SVBAccent().CGColor, (id)SVBAccent2().CGColor];
    g.startPoint = CGPointMake(0, 0.5);
    g.endPoint   = CGPointMake(1, 0.5);
    g.cornerRadius = 20;
    [card.layer insertSublayer:g atIndex:0];
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.20;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    card.layer.shadowRadius = 12;

    UIImageView *icon = [[UIImageView alloc] initWithImage:
        SVBBadgeIcon(@"play.rectangle.on.rectangle.fill",
                     [UIColor colorWithWhite:1 alpha:0.35],
                     [UIColor colorWithWhite:1 alpha:0.15])];
    icon.frame = CGRectMake(18, (h - 46) / 2, 46, 46);
    icon.layer.cornerRadius = 13;
    icon.layer.masksToBounds = YES;
    [card addSubview:icon];

    UILabel *title = [UILabel new];
    title.text = @"信息视频背景";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    title.frame = CGRectMake(76, h / 2 - 26, w - 96, 28);
    [card addSubview:title];

    UILabel *sub = [UILabel new];
    sub.text = [self heroSubtitle];
    sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.82];
    sub.frame = CGRectMake(76, h / 2 + 4, w - 96, 18);
    [card addSubview:sub];

    // v1.8.6: 长按 Hero 卡编辑副标题 (存配置, 立即刷新)
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(editHeroSubtitle:)];
    [card addGestureRecognizer:lp];

    [wrap addSubview:card];
    return wrap;
}

- (void)editHeroSubtitle:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"自定义副标题"
                         message:@"长按首页顶部渐变卡随时改"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [self heroSubtitle];
        tf.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *t = ac.textFields.firstObject.text;
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [[SVBManager shared] setConfigValue:t.length ? t : @"不要为了升级而放弃越狱的快乐"
                                     forKey:@"hero_subtitle"];
        self.tableView.tableHeaderView = [self makeHeroHeader];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.tableHeaderView = [self makeHeroHeader];
    // v10.3.0: 未授权首页只有「授权」一栏, 长按各行的快捷动作
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(tableLongPressed:)];
    [self.tableView addGestureRecognizer:lp];
}

- (void)tableLongPressed:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [gr locationInView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:p];
    if (!ip) return;
    if (![self authOK]) {
        NSInteger kind = [self authRowKindAt:ip.row];
        if (kind == 0)      [self svbAuthMenu];        // 授权状态行 -> 诊断 / 清除授权
        else if (kind == 1) [self svbCopyUDID];        // 本机 UDID 行 -> 复制
        else                [self svbImportTicket];    // 粘贴离线授权行 -> 直接导入
        return;
    }
    if (ip.section == 3 && ip.row == 0) [self svbAuthMenu];   // 授权状态 -> 诊断 / 清除授权
    if (ip.section == 3 && ip.row == 1) {                     // 素材路径 -> 复制路径
        UIPasteboard.generalPasteboard.string = SVBMediaFriendlyRoot();
        [self svbAlert:@"素材路径已复制" msg:SVBMediaFriendlyRoot()];
    }
}

// v10.3.0: 长按「授权状态」-> 授权诊断 / 清除本机授权
- (void)svbAuthMenu {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"授权"
                         message:@"本插件只认「离线授权串」：作者按你的 UDID 生成一段文本发你，"
                                 @"在这里粘贴导入即可。全程不联网，不需要代理 / 梯子。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"授权诊断" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [self svbShowDiagnose]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"粘贴离线授权" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [self svbImportTicket]; }]];
    if (SVBAuthHasOfflineTicket(NULL)) {
        [ac addAction:[UIAlertAction actionWithTitle:@"清除本机授权" style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction *a) { [self svbClearLicense]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.tableView;
    ac.popoverPresentationController.sourceRect =
        CGRectMake(self.tableView.bounds.size.width / 2, 80, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

// v10.1.0: 粘贴作者发来的离线授权串 (无需联网)
- (void)svbImportTicket {
    NSString *clip = [UIPasteboard generalPasteboard].string ?: @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"粘贴离线授权串"
                         message:@"把作者发给你的一整段文本（以 SVBOFFLINE1: 开头）粘进来。\n"
                                 @"不用联网立即生效，有效期按作者签发的天数计。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [clip rangeOfString:@"SVBOFFLINE1:"].location != NSNotFound ? clip : @"";
        tf.placeholder = @"SVBOFFLINE1:...";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *msg = nil;
        BOOL ok = SVBAuthImportTicket(ac.textFields.firstObject.text, &msg);
        SVBAuthInvalidateCache();
        [self svbReloadAuthState];
        [self.tableView reloadData];
        [self svbAlert:ok ? @"导入成功" : @"导入失败" msg:msg ?: @""];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// v10.3.0: 授权诊断 —— 纯本地自检 (UDID / 指纹 / 授权串验签), 不联网所以瞬间出结果
- (void)svbShowDiagnose {
    NSString *rep = SVBAuthDiagnose();
    SVBTextViewController *vc = [[SVBTextViewController alloc] init];
    vc.headTitle = @"授权诊断";
    vc.text = rep;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self svbReloadAuthState];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // v10.0.1: 未授权只留「授权」一栏, 全部设置开关隐藏
    if (![self authOK]) return 1;
    return 4; // 总开关 / 界面开关 / 调试 / 说明 (v1.6: 全局效果滑条已下沉到各界面)
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (![self authOK]) return [self authRowCount];
    if (section == 0) return 1;
    if (section == 1) return (NSInteger)_defs.count;
    if (section == 2) return 2; // 切后台自动清理 / 注入诊断横幅 (v9.9.11)
    return 4; // 授权状态 / 素材路径 / 诊断报告 / App名称与图标
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (![self authOK]) return @"授权";
    if (section == 0) return @"总开关";
    if (section == 1) return @"各界面背景";
    if (section == 2) return @"后台与调试";
    return @"说明";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (![self authOK]) {
        return @"① 点「本机 UDID」那一行复制，发给作者；\n"
                "② 作者会回你一段以 SVBOFFLINE1: 开头的授权串；\n"
                "③ 点「粘贴离线授权」把它导入，立刻生效。\n\n"
                "本机不发起任何网络请求，不需要代理 / 梯子。有效期按作者签发的内容计，"
                "到期找作者要一段新的即可。\n\n"
                "长按第一行可查看「授权诊断」或清除本机授权。";
    }
    if (section == 1)
        return @"点按某一行可为该界面选用素材并单独设置不透明度/模糊度/音量。所有界面共用同一个素材文件夹（见下方「素材路径」），用 Filza 把视频直接丢进去，每个界面都能选它当背景。\n\n「对话详情」= 点进某个对话后上下聊天的那个界面（不是列表）。「未导入素材」的界面不会显示视频背景，导入并打开开关后生效。";
    if (section == 2)
        return @"「切后台自动清理」：信息App 划到后台超过设定时间就自动结束它的进程（从后台再进去等于重开），用来解决个别情况下回前台视频卡住的问题；设定时间内回来（复制粘贴、看眼别的 App）不会被清理。点这一行可以改时间。\n\n「显示注入诊断横幅」：打开信息App（或备忘录）时，窗口顶部会显示一条横幅：能看到它 = 插件注入成功。横幅里列出素材目录是否可读、有几个素材，点一下可临时隐藏。";
    if (section == 3) {
        return [NSString stringWithFormat:
                @"所有界面的素材都放在这一个文件夹里（点「素材路径」可直接跳到 Filza）：\n%@\n\n"
                "不再分界面子文件夹 —— 把视频直接丢进去，主页面/所有信息/对话详情等每个界面都能选它当背景，"
                "各界面可单独选不同的视频、单独调效果。\n"
                "「诊断报告」开关：有问题时打开 —— 打开后开始记录，每分钟记一次快照，"
                "关闭开关时把从打开到关闭这期间的日志存进素材文件夹旁的「看不懂的报告」文件夹，"
                "文件名带生成时间（如 诊断报告_生成时间20260929-211953.txt）；没问题就保持关闭。\n"
                "各界面音量默认关闭。设置即时生效，无需注销。",
                SVBMediaFriendlyRoot()];
    }
    return nil;
}

// v10.3.0: 未授权首页的唯一一栏 —— 授权状态 / 本机 UDID(点按复制) / 粘贴离线授权
- (UITableViewCell *)authOnlyCell:(NSInteger)row tableView:(UITableView *)tableView {
    static NSString *authOnlyId = @"svb-home-authonly";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:authOnlyId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:authOnlyId];
    // 复用时把上一轮的样式全部还原
    c.textLabel.text = nil;
    c.textLabel.textColor = [UIColor labelColor];
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    c.detailTextLabel.text = nil;
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.detailTextLabel.font = [UIFont systemFontOfSize:15];
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSInteger kind = [self authRowKindAt:row];
    NSInteger total = [self authRowCount];

    if (kind == 0) {
        BOOL ok = (_authState == SVBAuthStateAuthorized);
        c.textLabel.text = @"授权状态";
        c.detailTextLabel.text = SVBAuthStateText(_authState, _authDetail);
        c.detailTextLabel.textColor = ok ? SVBAccent() : [UIColor systemOrangeColor];
        c.detailTextLabel.font = [UIFont systemFontOfSize:14];
        c.imageView.image = SVBBadgeIcon(ok ? @"checkmark.seal.fill" : @"lock.fill",
            ok ? [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1]
               : [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1],
            ok ? [UIColor colorWithRed:0.35 green:0.85 blue:0.65 alpha:1]
               : [UIColor colorWithRed:1.00 green:0.42 blue:0.30 alpha:1]);
        c.selectionStyle = UITableViewCellSelectionStyleNone;   // 纯信息, 点不动
    } else if (kind == 1) {
        c.textLabel.text = @"本机 UDID";
        c.detailTextLabel.text = SVBAuthUDID() ?: @"读取失败";
        c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightSemibold];
        c.detailTextLabel.textColor = SVBAccent();
        c.imageView.image = SVBBadgeIcon(@"iphone.gen3",
            [UIColor colorWithRed:0.25 green:0.55 blue:1.00 alpha:1],
            [UIColor colorWithRed:0.40 green:0.80 blue:1.00 alpha:1]);
    } else if (kind == 2) {
        // v10.3.0: 唯一的授权入口 —— 粘贴作者发的离线授权串
        c.textLabel.text = @"粘贴离线授权";
        c.detailTextLabel.text = SVBAuthOfflineTicketInfo();
        c.detailTextLabel.font = [UIFont systemFontOfSize:13.5];
        c.detailTextLabel.textColor = SVBAuthHasOfflineTicket(NULL)
            ? SVBAccent() : [UIColor secondaryLabelColor];
        c.imageView.image = SVBBadgeIcon(@"doc.on.clipboard",
            [UIColor colorWithRed:0.45 green:0.75 blue:0.35 alpha:1],
            [UIColor colorWithRed:0.70 green:0.85 blue:0.40 alpha:1]);
    }
    SVBApplyCardStyle(c, row, total);
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self authOK]) return [self authOnlyCell:indexPath.row tableView:tableView];

    static NSString *basicId  = @"svb-basic";
    static NSString *switchId = @"svb-switch";
    static NSString *linkId   = @"svb-link";
    SVBManager *mgr = [SVBManager shared];

    // 总开关
    if (indexPath.section == 0) {
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:switchId];
        if (!c) {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:switchId];
            UISwitch *sw = [UISwitch new];
            sw.onTintColor = SVBAccent();
            [sw addTarget:self action:@selector(masterToggled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
        c.textLabel.text = @"启用视频背景";
        c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        c.imageView.image = SVBIconForKey(@"__master");
        ((UISwitch *)c.accessoryView).on = [mgr masterEnabled];
        SVBApplyCardStyle(c, 0, 1);
        return c;
    }

    // 界面开关 + 素材入口
    if (indexPath.section == 1) {
        NSArray<NSString *> *def = _defs[indexPath.row];
        NSString *key = def[0];
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:linkId];
        if (!c) {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:linkId];
            UISwitch *sw = [UISwitch new];
            sw.onTintColor = SVBAccent();
            [sw addTarget:self action:@selector(contextToggled:) forControlEvents:UIControlEventValueChanged];
            [c.contentView addSubview:sw];
            sw.translatesAutoresizingMaskIntoConstraints = NO;
            [NSLayoutConstraint activateConstraints:@[
                [sw.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
                [sw.centerYAnchor constraintEqualToAnchor:c.contentView.centerYAnchor],
            ]];
            objc_setAssociatedObject(c, &SVBSwitchAssocKey, sw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UISwitch *sw = objc_getAssociatedObject(c, &SVBSwitchAssocKey);
        c.textLabel.text = def[1];
        // v1.8.1: 最外层不显示任何素材信息, 只有图标+标题+开关
        c.detailTextLabel.text = nil;
        sw.tag = 300 + indexPath.row;
        sw.on = [mgr isEnabledForContext:key];
        c.imageView.image = SVBIconForKey(key);
        SVBApplyCardStyle(c, indexPath.row, (NSInteger)_defs.count);
        return c;
    }

    // 后台与调试区 (v9.9.11: row0 = 切后台自动清理, row1 = 注入诊断横幅)
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            static NSString *bgKillId = @"svb-cell-bgkill";
            UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:bgKillId];
            if (!c) {
                // v9.9.13: 秒数放行尾 detailText, 开关独立做 accessoryView
                // (旧版把标签+开关塞 StackView 当 accessoryView, 布局不稳会跑位)
                c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:bgKillId];
                UISwitch *sw = [UISwitch new];
                sw.onTintColor = SVBAccent();
                [sw addTarget:self action:@selector(bgKillToggled:) forControlEvents:UIControlEventValueChanged];
                c.accessoryView = sw;
            }
            BOOL on = [mgr bgKillEnabled];
            c.textLabel.text = @"切后台自动清理";
            c.detailTextLabel.text = on ? [NSString stringWithFormat:@"%.0f 秒", [mgr bgKillDelay]] : @"关闭";
            c.detailTextLabel.textColor = on ? SVBAccent() : [UIColor secondaryLabelColor];
            ((UISwitch *)c.accessoryView).on = on;
            c.imageView.image = SVBBadgeIcon(@"bolt.slash.fill",
                [UIColor colorWithRed:1.00 green:0.45 blue:0.35 alpha:1],
                [UIColor colorWithRed:1.00 green:0.28 blue:0.45 alpha:1]);
            SVBApplyCardStyle(c, 0, 2);
            return c;
        }
        static NSString *debugSwitchId = @"svb-switch-debug";
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:debugSwitchId];
        if (!c) {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:debugSwitchId];
            UISwitch *sw = [UISwitch new];
            sw.onTintColor = SVBAccent();
            [sw addTarget:self action:@selector(bannerToggled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
        c.textLabel.text = @"显示注入诊断横幅";
        c.imageView.image = SVBIconForKey(@"__debug");
        ((UISwitch *)c.accessoryView).on = [mgr debugBannerEnabled];
        SVBApplyCardStyle(c, 1, 2);
        return c;
    }

    // 说明区 (v1.9.0: 授权状态提到第一行)
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:basicId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:basicId];
    c.accessoryType = UITableViewCellAccessoryNone;   // v10.4.0: 复用时清掉, 防箭头串行
    if (indexPath.row == 0) {
        NSString *det = nil;
        SVBAuthState st = SVBAuthCurrentState(&det);
        BOOL ok = (st == SVBAuthStateAuthorized);
        c.textLabel.text = @"授权状态";
        c.detailTextLabel.text = SVBAuthStateText(st, det);
        c.detailTextLabel.textColor = ok ? SVBAccent() : [UIColor systemOrangeColor];
        c.imageView.image = SVBBadgeIcon(ok ? @"checkmark.seal.fill" : @"lock.fill",
            ok ? [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1]
               : [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1],
            ok ? [UIColor colorWithRed:0.35 green:0.85 blue:0.65 alpha:1]
               : [UIColor colorWithRed:1.00 green:0.42 blue:0.30 alpha:1]);
        SVBApplyCardStyle(c, 0, 4);
        return c;
    }
    if (indexPath.row == 1) {
        // v10.4.0: 统一素材路径 —— 点按跳 Filza, 长按复制路径
        //   (去掉行尾的 › 和右侧箭头: 用户要求「板栗仁路径后面的 > 符号删掉」)
        c.textLabel.text = @"素材路径";
        c.detailTextLabel.text = SVBMediaFriendlyRoot().lastPathComponent;
        c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        c.imageView.image = SVBIconForKey(@"__folder");
        c.accessoryType = UITableViewCellAccessoryNone;
    } else if (indexPath.row == 2) {
        // v10.4.0: 诊断报告改开关式 —— 开=生成「看不懂的报告」文件, 关=不生成并删除
        static NSString *diagId = @"svb-cell-diag";
        UITableViewCell *dc = [tableView dequeueReusableCellWithIdentifier:diagId];
        if (!dc) {
            dc = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:diagId];
            UISwitch *sw = [UISwitch new];
            sw.onTintColor = SVBAccent();
            [sw addTarget:self action:@selector(diagnoseToggled:) forControlEvents:UIControlEventValueChanged];
            dc.accessoryView = sw;
        }
        BOOL on = SVBDiagnoseReportEnabled();
        dc.textLabel.text = @"诊断报告";
        dc.detailTextLabel.text = on ? @"记录中 · 看不懂的报告" : @"关闭";
        dc.detailTextLabel.textColor = on ? SVBAccent() : [UIColor secondaryLabelColor];
        dc.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        dc.imageView.image = SVBIconForKey(@"__diag");
        ((UISwitch *)dc.accessoryView).on = on;
        SVBApplyCardStyle(dc, 2, 4);
        return dc;
    } else {
        c.textLabel.text = @"App 名称与图标";
        c.detailTextLabel.text = @"自定义外观";
        c.imageView.image = SVBBadgeIcon(@"paintbrush.fill",
            [UIColor colorWithRed:1.00 green:0.62 blue:0.20 alpha:1],
            [UIColor colorWithRed:1.00 green:0.45 blue:0.55 alpha:1]);
    }
    c.detailTextLabel.textColor = SVBAccent();
    SVBApplyCardStyle(c, indexPath.row, 4);
    return c;
}

- (void)bannerToggled:(UISwitch *)sw {
    SVBManager *mgr = [SVBManager shared];
    [mgr setConfigValue:@(sw.on) forKey:@"debug_banner"];
    [mgr postChangeNotification];
}

// v10.4.0e: 诊断报告开关 —— 开=开始记录(打开到关闭期间的日志); 关=停止并保存成带生成时间的文件
- (void)diagnoseToggled:(UISwitch *)sw {
    BOOL on = sw.on;
    [[SVBManager shared] setConfigValue:@(on) forKey:@"diagnose_report"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SVBEnsureFriendlyMediaPath(NULL);
        if (on) {
            SVBDiagAppendSnapshot(@"开关打开");
            SVBDiagStartTimer();
        } else {
            SVBDiagStopTimer();
            SVBDiagFinalize();
        }
    });
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:2 inSection:3]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - v9.9.11 切后台自动清理

- (void)bgKillToggled:(UISwitch *)sw {
    SVBManager *mgr = [SVBManager shared];
    mgr.bgKillEnabled = sw.on;
    // 只刷新这一行, 更新行尾秒数/关闭文案
    for (UITableViewCell *c in self.tableView.visibleCells) {
        if ([c.reuseIdentifier isEqualToString:@"svb-cell-bgkill"]) {
            BOOL on = mgr.bgKillEnabled;
            c.detailTextLabel.text = on ? [NSString stringWithFormat:@"%.0f 秒", mgr.bgKillDelay] : @"关闭";
            c.detailTextLabel.textColor = on ? SVBAccent() : [UIColor secondaryLabelColor];
        }
    }
}

- (void)bgKillDelayTapped {
    SVBManager *mgr = [SVBManager shared];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"切后台多久后清理"
                         message:@"这个时间内回到信息App 不会被清理（复制粘贴、看眼别的 App 都来得及）。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *d in @[@3, @5, @10, @30]) {
        NSString *t = [NSString stringWithFormat:@"%.0f 秒", d.doubleValue];
        if (fabs(mgr.bgKillDelay - d.doubleValue) < 0.01) t = [t stringByAppendingString:@"   ✓"];
        [ac addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
            [SVBManager shared].bgKillDelay = d.doubleValue;
            [self.tableView reloadData];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)masterToggled:(UISwitch *)sw {
    SVBManager *mgr = [SVBManager shared];
    [mgr setConfigValue:@(sw.on) forKey:@"master_enabled"];
    [mgr postChangeNotification];
}

- (void)contextToggled:(UISwitch *)sw {
    NSInteger row = sw.tag - 300;
    if (row < 0 || row >= (NSInteger)_defs.count) return;
    SVBManager *mgr = [SVBManager shared];
    NSString *key = _defs[row][0];
    [mgr setEnabled:sw.on forContext:key];
    if (sw.on && ![mgr activeVideoPathForContext:key]) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"还没有素材"
                             message:[NSString stringWithFormat:@"请点按「%@」一行导入素材，或用 Filza 把视频放进对应素材文件夹。", _defs[row][1]]
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // v10.0.1: 未授权首页只有授权栏, 点行直接办事, 不再跳授权页
    if (![self authOK]) {
        NSInteger kind = [self authRowKindAt:indexPath.row];
        if (kind == 1)      [self svbCopyUDID];      // 本机 UDID -> 复制
        else if (kind == 2) [self svbImportTicket];  // 粘贴离线授权
        return;
    }
    if (indexPath.section == 2 && indexPath.row == 0) {
        [self bgKillDelayTapped];   // v9.9.13: 点整行改清理延时
        return;
    }
    if (indexPath.section == 1) {
        NSArray<NSString *> *def = _defs[indexPath.row];
        SVBAppMaterialController *vc = [[SVBAppMaterialController alloc] initWithContext:def[0] title:def[1]];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            [self.navigationController pushViewController:[[SVBAuthController alloc] init] animated:YES];
            return;
        }
        if (indexPath.row == 1) {
            // v10.3.0: 素材路径 —— 直接跳到 Filza (没装 Filza 就把路径放剪贴板)
            SVBJumpToMediaPath(self, SVBMediaFriendlyRoot());
            return;
        }
        // v10.4.0e: 诊断报告行点击不再跳查看页, 只留开关 (报告直接看文件)
        if (indexPath.row == 3) {
            [self.navigationController pushViewController:[[SVBAppIdentityController alloc] init] animated:YES];
            return;
        }
    }
}

@end

#pragma mark - 素材管理页 (App 版)

@implementation SVBAppMaterialController

- (instancetype)initWithContext:(NSString *)ctx title:(NSString *)title {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _contextKey = [ctx copy];
        _contextTitle = [title copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.contextTitle;
    // v1.8.2: 去掉右上角「＋」, 导入只保留「从相册导入视频素材」一个入口
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.refreshControl.tintColor = SVBAccent();
    // 下拉刷新 (方便 Filza 放完文件后刷新)
    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(refreshFiles) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;
}

- (void)refreshFiles {
    SVBManager *mgr = [SVBManager shared];
    SVBRefreshMediaRoots();   // 重新定位信息App 容器
    [mgr postChangeNotification];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // v1.6: 本界面效果 / 素材列表
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3; // 不透明度/模糊度/音量 (v10.4.0d: 气泡不透明度滑杆已删)
    // 素材行 + 「从相册导入视频素材」+ 「在 Filza 中打开素材文件夹」
    return MAX(1, (NSInteger)[[SVBManager shared] videosForContext:self.contextKey].count) + 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"本界面效果（仅作用于该界面）" : @"素材";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 1) return nil;
    // v10.4.0: 所有界面共用一个素材文件夹, 不再分子目录
    return [NSString stringWithFormat:
        @"所有界面共用这一个素材文件夹（点下方「在 Filza 中打开素材文件夹」直达）：\n%@\n\n"
        "把视频直接丢进去即可，本界面会列出文件夹里全部视频；放新文件后下拉刷新。左滑素材行可删除。",
        SVBMediaFriendlyRoot()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId   = @"svb-app-mat";
    static NSString *sliderId = @"svb-app-mat-slider";
    SVBManager *mgr = [SVBManager shared];

    // 本界面效果滑杆
    if (indexPath.section == 0) {
        SVBSliderCell *c = [tableView dequeueReusableCellWithIdentifier:sliderId];
        if (!c) c = [[SVBSliderCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:sliderId];
        __weak typeof(self) wself = self;
        if (indexPath.row == 0) {
            [c setTitle:@"不透明度" value:[mgr alphaForContext:self.contextKey] max:1.0
                    display:^NSString *(double v) { return [NSString stringWithFormat:@"%.0f%%", v * 100]; }];
            c.onValue = ^(double v) {
                [mgr setConfigValue:@(v) forKey:[wself.contextKey stringByAppendingString:@"_alpha"]];
                [mgr postChangeNotification];
            };
        } else if (indexPath.row == 1) {
            [c setTitle:@"模糊度" value:[mgr blurForContext:self.contextKey] max:30.0
                    display:^NSString *(double v) { return [NSString stringWithFormat:@"%.0f", v]; }];
            c.onValue = ^(double v) {
                [mgr setConfigValue:@(v) forKey:[wself.contextKey stringByAppendingString:@"_blur"]];
                [mgr postChangeNotification];
            };
        } else if (indexPath.row == 2) {
            [c setTitle:@"音量" value:[mgr volumeForContext:self.contextKey] max:1.0
                    display:^NSString *(double v) { return v <= 0.001 ? @"关闭" : [NSString stringWithFormat:@"%.0f%%", v * 100]; }];
            c.onValue = ^(double v) {
                [mgr setConfigValue:@(v) forKey:[wself.contextKey stringByAppendingString:@"_volume"]];
                [mgr postChangeNotification];
            };
        }
        // v10.4.0d: 气泡不透明度滑杆已删 (对话详情也不再有第 4 行)
        SVBApplyCardStyle(c, indexPath.row, 3);
        return c;
    }

    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
    c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    NSArray<NSString *> *videos = [mgr videosForContext:self.contextKey];
    NSString *active = [mgr activeVideoNameForContext:self.contextKey];
    NSInteger rows = (NSInteger)MAX(1, (NSInteger)videos.count) + 2;

    if (videos.count == 0 && indexPath.row == 0) {
        c.textLabel.text = @"素材文件夹为空，点下方「从相册导入视频素材」";
        c.textLabel.textColor = [UIColor secondaryLabelColor];
        c.textLabel.font = [UIFont systemFontOfSize:15];
        c.imageView.image = nil;
        c.detailTextLabel.text = nil;
        c.accessoryType = UITableViewCellAccessoryNone;
        SVBApplyCardStyle(c, 0, rows);
        return c;
    }
    // v10.4.0b: 空列表时行号整体后移 1 (第 0 行是占位提示), 否则「从相册导入」
    // 的行号判断 (row == videos.count) 永远不成立, 那一行错画成 Filza 跳转
    NSInteger mediaBase = videos.count ? (NSInteger)videos.count : 1;
    if (indexPath.row < (NSInteger)videos.count) {
        // v1.8.4: 显示素材本名 (用户会自己重命名; 隐藏扩展名, 超长中间截断)
        NSString *show = videos[indexPath.row].stringByDeletingPathExtension;
        if (!show.length) show = videos[indexPath.row];
        c.textLabel.text = show;
        c.textLabel.textColor = [UIColor labelColor];
        c.textLabel.font = [UIFont systemFontOfSize:17];
        BOOL isActive = [active isEqualToString:videos[indexPath.row]];
        c.detailTextLabel.text = isActive ? @"使用中" : nil;
        c.detailTextLabel.textColor = isActive ? SVBAccent() : [UIColor secondaryLabelColor];
        c.imageView.image = SVBIconForKey(@"__video");
        c.accessoryType = isActive ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        c.tintColor = SVBAccent();
        SVBApplyCardStyle(c, indexPath.row, rows);
        return c;
    }
    if (indexPath.row == mediaBase) {
        c.textLabel.text = @"从相册导入视频素材";
        c.textLabel.textColor = SVBAccent();
        c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        c.imageView.image = SVBIconForKey(@"__import");
        c.detailTextLabel.text = nil;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        SVBApplyCardStyle(c, indexPath.row, rows);
        return c;
    }
    // v10.4.0: 跳转到统一素材路径 (所有界面共用这一个文件夹)
    c.textLabel.text = @"在 Filza 中打开素材文件夹";
    c.textLabel.textColor = SVBAccent();
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    c.imageView.image = SVBIconForKey(@"__open");
    c.detailTextLabel.text = @"跳转";
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.detailTextLabel.font = [UIFont systemFontOfSize:13.5];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    SVBApplyCardStyle(c, indexPath.row, rows);
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    NSArray<NSString *> *videos = [[SVBManager shared] videosForContext:self.contextKey];
    NSInteger n = (NSInteger)videos.count;
    // v10.4.0b: 空列表时行号后移 1 (与 cellForRowAtIndexPath 的 mediaBase 对齐)
    NSInteger mediaBase = n ? n : 1;
    // v10.3.0: 最后一行 = 跳转素材路径 (Filza)
    if (indexPath.row > mediaBase) { [self openFolderInFilza]; return; }
    if (indexPath.row == mediaBase || n == 0) {
        [self importFromLibrary];
        return;
    }
    NSString *name = videos[indexPath.row];
    __weak typeof(self) wself = self;
    // v1.8.2: 标题不露文件名; 新增「预览此素材」全屏播放
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"素材操作" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"预览此素材" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [wself previewVideoNamed:name];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"选用此素材" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[SVBManager shared] setActiveVideoName:name forContext:wself.contextKey];
        [[SVBManager shared] refreshVisibleBackgrounds];
        [wself.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除此素材" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[SVBManager shared] deleteVideoName:name forContext:wself.contextKey];
        [[SVBManager shared] refreshVisibleBackgrounds];
        [wself.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// v10.3.0: 跳到本界面的素材文件夹 (Filza)
- (void)openFolderInFilza {
    [[SVBManager shared] contextDirectory:self.contextKey];   // 保证素材根存在
    SVBJumpToMediaPath(self, SVBMediaFriendlyPathForContext(self.contextKey));
}

// v1.8.2: 素材预览 —— AVPlayerViewController 全屏播放, 关闭即停
- (void)previewVideoNamed:(NSString *)name {
    NSString *path = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    // v10.4.0b: 素材在根「根部」(v10.4.0 摊平), 旧版子目录也兼容找一下
    for (NSString *root in [[SVBManager shared] mediaRoots]) {
        NSString *p = [root stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) { path = p; break; }
        p = [[root stringByAppendingPathComponent:self.contextKey] stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) { path = p; break; }
    }
    if (!path.length) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"找不到文件" message:@"素材可能已被移动或删除"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
    AVPlayer *player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:path]];
    AVPlayerViewController *pvc = [[AVPlayerViewController alloc] init];
    pvc.player = player;
    [self presentViewController:pvc animated:YES completion:^{ [player play]; }];
}

// 左滑删除素材 (v1.4, v1.6 起仅素材分区可编辑)
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return NO;
    NSArray<NSString *> *videos = [[SVBManager shared] videosForContext:self.contextKey];
    if (videos.count == 0) return NO; // 占位提示行不可编辑
    return indexPath.row < (NSInteger)videos.count;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 1) return;
    NSArray<NSString *> *videos = [[SVBManager shared] videosForContext:self.contextKey];
    if (indexPath.row >= (NSInteger)videos.count) return;
    NSString *name = videos[indexPath.row];
    [[SVBManager shared] deleteVideoName:name forContext:self.contextKey];
    [[SVBManager shared] refreshVisibleBackgrounds];
    [tableView reloadData];
}

// v1.8.3: 左滑动作 = 重命名 + 删除 (系统会自动优先用滑动动作, commitEditingStyle 保留兜底)
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return nil;
    NSArray<NSString *> *videos = [[SVBManager shared] videosForContext:self.contextKey];
    if (indexPath.row >= (NSInteger)videos.count) return nil; // 占位提示行不参与
    NSString *name = videos[indexPath.row];
    __weak typeof(self) wself = self;

    UIContextualAction *rename = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"重命名"
                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [wself renameVideoNamed:name];
        done(YES);
    }];
    rename.backgroundColor = [UIColor systemIndigoColor];

    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [[SVBManager shared] deleteVideoName:name forContext:wself.contextKey];
        [[SVBManager shared] refreshVisibleBackgrounds];
        [wself.tableView reloadData];
        done(YES);
    }];

    return [UISwipeActionsConfiguration configurationWithActions:@[rename, del]];
}

// 重命名弹窗: 文本框预填原名, 确认后改名 (改名的是使用中素材时配置自动同步)
- (void)renameVideoNamed:(NSString *)name {
    __weak typeof(self) wself = self;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"重命名素材"
                         message:@"留空或无改动则取消"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = name.stringByDeletingPathExtension;
        tf.clearButtonMode = UITextFieldViewModeAlways;
        tf.returnKeyType = UIReturnKeyDone;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *input = ac.textFields.firstObject.text;
        if (!input.length) return;
        NSString *final = [[SVBManager shared] renameVideoName:name
                                                            to:input
                                                    forContext:wself.contextKey];
        if (final) {
            [[SVBManager shared] refreshVisibleBackgrounds];
            [wself.tableView reloadData];
        } else {
            UIAlertController *fail = [UIAlertController
                alertControllerWithTitle:@"重命名失败"
                                 message:@"名字无效或与现有素材重名"
                          preferredStyle:UIAlertControllerStyleAlert];
            [fail addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [wself presentViewController:fail animated:YES completion:nil];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)importFromLibrary {
    // v1.7: 多选批量导入 + 进度提示 + 失败原因汇总 (实现见文件顶部 SVBAppImportFromLibrary)
    SVBAppImportFromLibrary(self, self.contextKey);
}

@end

#pragma mark - App 名称与图标 (v1.8.3)

// 调起相册选「一张图片」(图标用), 复用视频选择器的运行时代理套路
static void SVBAppPickImage(UIViewController *host, void (^done)(UIImage *image)) {
    void *h = dlopen("/System/Library/Frameworks/PhotosUI.framework/PhotosUI", RTLD_LAZY);
    Class pickerCls = h ? NSClassFromString(@"PHPickerViewController") : nil;
    Class cfgCls    = h ? NSClassFromString(@"PHPickerConfiguration") : nil;
    if (!pickerCls || !cfgCls) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"暂不可用" message:@"无法调起相册选择器"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:ac animated:YES completion:nil];
        return;
    }
    id cfg = [[cfgCls alloc] init];
    Class filterCls = NSClassFromString(@"PHPickerFilter");
    if (filterCls) {
        id filter = ((id (*)(id, SEL))objc_msgSend)(filterCls, @selector(imagesFilter));
        ((void (*)(id, SEL, id))objc_msgSend)(cfg, @selector(setFilter:), filter);
    }
    ((void (*)(id, SEL, long))objc_msgSend)(cfg, @selector(setSelectionLimit:), (long)1);

    id pc = ((id (*)(id, SEL))objc_msgSend)(pickerCls, @selector(alloc));
    pc    = ((id (*)(id, SEL, id))objc_msgSend)(pc, @selector(initWithConfiguration:), cfg);

    Class proxyCls = objc_getClass("SVBPickerProxy");
    if (!proxyCls) {
        proxyCls = objc_allocateClassPair([NSObject class], "SVBPickerProxy", 0);
        class_addMethod(proxyCls, @selector(picker:didFinishPicking:),
                        imp_implementationWithBlock(^(id self, id picker, NSArray *results) {
            NSArray *list = [results isKindOfClass:[NSArray class]] ? results : @[];
            void (^handler)(NSArray *) = objc_getAssociatedObject(picker, "doneBlock");
            [picker dismissViewControllerAnimated:YES completion:^{
                if (list.count && handler) handler(list);
            }];
        }), "v@:@@");
        objc_registerClassPair(proxyCls);
    }
    id proxy = [[proxyCls alloc] init];
    objc_setAssociatedObject(pc, &SVBProxyAssocKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pc, "doneBlock", ^(NSArray *results) {
        // 取出图片 (loadObjectOfClass 是 UIKit 公开分类方法)
        NSItemProvider *provider = [results.firstObject respondsToSelector:@selector(itemProvider)]
                                   ? [results.firstObject itemProvider] : nil;
        if (!provider) { if (done) done(nil); return; }
        [provider loadObjectOfClass:[UIImage class]
                  completionHandler:^(id obj, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIImage *img = [obj isKindOfClass:[UIImage class]] ? obj : nil;
                // PNG/HEIC 拿到的可能是带方向的 -> 规范化重绘
                if (img && img.imageOrientation != UIImageOrientationUp) {
                    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc]
                        initWithSize:img.size];
                    img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                        [img drawInRect:(CGRect){CGPointZero, img.size}];
                    }];
                }
                if (done) done(img);
            });
        }];
    }, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(pc, @selector(setDelegate:), proxy);
    [host presentViewController:pc animated:YES completion:nil];
}

@implementation SVBAppIdentityController {
    UIImageView *_iconPreview;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"App 名称与图标";
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 2; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"名称：保存后桌面即时生效（若未刷新，注销一次）。\n图标：从相册选一张方图即可，系统会弹窗确认，立即生效；想改回来再选一次原图就行。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 两行分开复用符: 防图标预览 accessoryView 串到名称行
    static NSString *idName  = @"svb-identity-name";
    static NSString *idIcon  = @"svb-identity-icon";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:
                          indexPath.row == 0 ? idName : idIcon];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                       reuseIdentifier:indexPath.row == 0 ? idName : idIcon];
    if (indexPath.row == 0) {
        c.textLabel.text = @"App 名称";
        // 优先显示已生效的自定义名 (桌面显示的就是它), 否则显示包内名
        NSString *custom = [[SVBManager shared] appDisplayName];
        NSString *cur = custom.length ? custom :
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        c.detailTextLabel.text = cur.length ? cur : @"信息视频背景";
    } else {
        c.textLabel.text = @"App 图标";
        // 预览当前生效图标: setAlternateIconName 换过之后当前图在 A/B 两个文件之一
        NSString *cur = [[UIApplication sharedApplication] alternateIconName];
        NSString *file = [cur isEqualToString:@"CustomIconB"] ? @"CustomIconB" : @"CustomIcon";
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:file ofType:@"png"];
        UIImage *img = iconPath ? [UIImage imageWithContentsOfFile:iconPath] : nil;
        if (!c.accessoryView) {
            _iconPreview = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
            _iconPreview.layer.cornerRadius = 10;
            _iconPreview.layer.masksToBounds = YES;
            _iconPreview.contentMode = UIViewContentModeScaleAspectFill;
            _iconPreview.layer.borderWidth = 0.5;
            _iconPreview.layer.borderColor = [UIColor separatorColor].CGColor;
            c.accessoryView = _iconPreview;
        }
        _iconPreview.image = img;
    }
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.textLabel.font = [UIFont systemFontOfSize:17];
    SVBApplyCardStyle(c, indexPath.row, 2);
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) [self renameApp];
    else [self changeIcon];
}

// 改名称: v1.8.5 改走「SpringBoard 显示层」方案 —— installd 缓存 Info.plist 的
// 显示名, 改 plist+注销无效 (用户实测)。名字写入共享配置 (app_display_name),
// SpringBoard 里的 SBApplication.displayName 钩子读到即替换, 即存即显。
// Info.plist 照旧同步写一份 (uicache/重装后保持一致)。
- (void)renameApp {
    NSString *custom = [[SVBManager shared] appDisplayName];
    NSString *cur = custom.length ? custom :
        [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"信息视频背景";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"App 名称" message:@"保存后桌面立即生效（若未刷新，注销一次）"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = cur; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = ac.textFields.firstObject.text;
        name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) return;
        SVBManager *mgr = [SVBManager shared];
        [mgr setConfigValue:name forKey:@"app_display_name"];
        // 包内 Info.plist 同步写 (失败不影响, 显示层已由钩子接管)
        NSString *plistPath = [[NSBundle mainBundle] pathForResource:@"Info" ofType:@"plist"];
        NSMutableDictionary *plist = plistPath ?
            [NSMutableDictionary dictionaryWithContentsOfFile:plistPath] : nil;
        if (plist) {
            plist[@"CFBundleDisplayName"] = name;
            plist[@"CFBundleName"]        = name;
            [plist writeToFile:plistPath atomically:YES];
        }
        [self.tableView reloadData];
        [self alert:@"已保存" msg:@"桌面名称已更新，若未刷新请注销一次。"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// 换图标: v1.8.5 改 A/B 双位轮换 —— setAlternateIconName 对「同名」请求是 no-op
// (第一次能换, 第二次起系统不重读文件, 用户实测)。每次写到「当前没在用的那个」
// 图标位再切换, 名字变了系统必然重读。
- (void)changeIcon {
    __weak typeof(self) wself = self;
    SVBAppPickImage(self, ^(UIImage *image) {
        if (!image) return;
        // 居中裁方
        CGFloat side = MIN(image.size.width, image.size.height);
        CGRect crop = CGRectMake((image.size.width - side) / 2,
                                 (image.size.height - side) / 2, side, side);
        CGImageRef cg = CGImageCreateWithImageInRect(image.CGImage, crop);
        if (!cg) { [wself alert:@"处理失败" msg:@"图片无法读取"]; return; }
        UIImage *square = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        // 缩到 1024 并转 PNG
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc]
            initWithSize:CGRectMake(0, 0, 1024, 1024).size];
        UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [square drawInRect:CGRectMake(0, 0, 1024, 1024)];
        }];
        NSData *png = UIImagePNGRepresentation(out);

        // 目标 = 当前没在用的图标位 (nil/CustomIcon -> 写 B; CustomIconB -> 写 A)
        NSString *current = [[UIApplication sharedApplication] alternateIconName];
        NSString *target  = [current isEqualToString:@"CustomIconB"] ? @"CustomIcon" : @"CustomIconB";
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:target ofType:@"png"];
        if (!png || !iconPath || ![png writeToFile:iconPath atomically:YES]) {
            [wself alert:@"写入失败" msg:@"App 包目录不可写，无法更新图标文件。"];
            return;
        }
        // 系统 API 换图标 (会弹系统确认框, 立即生效)
        if (@available(iOS 10.3, *)) {
            [[UIApplication sharedApplication]
                setAlternateIconName:target
                   completionHandler:^(NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (err) [wself alert:@"换图标失败" msg:err.localizedDescription];
                    else     [wself alert:@"已更换"  msg:@"桌面图标已更新。"];
                });
            }];
        }
        [wself.tableView reloadData];
    });
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - 授权页 (v10.3.0: 纯离线授权串)

// 流程: 本机 UDID 复制给作者 -> 作者在签发 App 里生成一段离线授权串 -> 客户在这里导入。
// 全程不联网, 客户国内网络直连即可, 不需要代理 / 梯子。
// 代价: 授权串发出后无法远程收回, 只能等到期 (想控制节奏就让作者签短一点)。
@implementation SVBAuthController {
    SVBAuthState _state;
    NSString *_detail;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"授权";
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self reloadAuth];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadAuth];
}

- (void)reloadAuth {
    NSString *det = nil;
    SVBAuthInvalidateCache();        // 纯本地复算, 不联网
    _state = SVBAuthCurrentState(&det);
    _detail = det;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2;   // 本机 UDID / 授权状态
    if (section == 1) return 2;   // 粘贴离线授权 / 清除本机授权
    return 1;                     // 授权诊断
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"设备";
    if (section == 1) return @"离线授权";
    return @"排查";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return nil;
    if (section == 1)
        return @"把作者发来的授权串（以 SVBOFFLINE1: 开头）点「粘贴离线授权」导入即可，立刻生效。\n"
                "授权串只对一台设备有效（已绑定本机指纹），有效期按作者签发的天数计，到期找作者要一段新的。\n\n"
                "本机不发起任何网络请求 —— 不需要代理 / 梯子。";
    return @"「授权诊断」是纯本机自检（UDID / 指纹 / 授权串验签），不联网，秒出结果。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"svb-auth";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
    c.textLabel.textColor = [UIColor labelColor];
    c.textLabel.text = nil;
    c.detailTextLabel.text = nil;
    c.detailTextLabel.font = [UIFont systemFontOfSize:15];
    c.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == 0 && indexPath.row == 0) {
        c.textLabel.text = @"本机 UDID";
        c.detailTextLabel.text = SVBAuthUDID() ?: @"读取失败";
        c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightSemibold];
        c.detailTextLabel.textColor = SVBAccent();
        c.imageView.image = SVBBadgeIcon(@"iphone.gen3",
            [UIColor colorWithRed:0.25 green:0.55 blue:1.00 alpha:1],
            [UIColor colorWithRed:0.40 green:0.80 blue:1.00 alpha:1]);
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        SVBApplyCardStyle(c, 0, 2);
        return c;
    }
    if (indexPath.section == 0) {
        BOOL ok = (_state == SVBAuthStateAuthorized);
        c.textLabel.text = @"授权状态";
        c.detailTextLabel.text = SVBAuthStateText(_state, _detail);
        c.detailTextLabel.textColor = ok ? SVBAccent() : [UIColor systemOrangeColor];
        c.imageView.image = SVBBadgeIcon(ok ? @"checkmark.seal.fill" : @"lock.fill",
            ok ? [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1]
               : [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1],
            ok ? [UIColor colorWithRed:0.35 green:0.85 blue:0.65 alpha:1]
               : [UIColor colorWithRed:1.00 green:0.42 blue:0.30 alpha:1]);
        c.detailTextLabel.font = [UIFont systemFontOfSize:14];
        SVBApplyCardStyle(c, 1, 2);
        return c;
    }

    // section 1: 离线授权
    if (indexPath.section == 1 && indexPath.row == 0) {
        c.textLabel.text = @"粘贴离线授权";
        c.detailTextLabel.text = SVBAuthOfflineTicketInfo();
        c.detailTextLabel.font = [UIFont systemFontOfSize:13.5];
        c.detailTextLabel.textColor = SVBAuthHasOfflineTicket(NULL)
            ? SVBAccent() : [UIColor secondaryLabelColor];
        c.imageView.image = SVBBadgeIcon(@"doc.on.clipboard",
            [UIColor colorWithRed:0.45 green:0.75 blue:0.35 alpha:1],
            [UIColor colorWithRed:0.70 green:0.85 blue:0.40 alpha:1]);
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        SVBApplyCardStyle(c, 0, 2);
        return c;
    }
    if (indexPath.section == 1) {
        c.textLabel.text = @"清除本机授权";
        c.textLabel.textColor = [UIColor systemRedColor];
        c.detailTextLabel.text = SVBAuthHasOfflineTicket(NULL) ? @"可重新导入" : @"当前没有授权";
        c.detailTextLabel.font = [UIFont systemFontOfSize:13.5];
        c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        c.imageView.image = SVBBadgeIcon(@"trash.fill",
            [UIColor colorWithRed:0.85 green:0.30 blue:0.30 alpha:1],
            [UIColor colorWithRed:1.00 green:0.45 blue:0.40 alpha:1]);
        SVBApplyCardStyle(c, 1, 2);
        return c;
    }

    // section 2: 排查
    c.textLabel.text = @"授权诊断";
    c.detailTextLabel.text = @"本机自检";
    c.detailTextLabel.font = [UIFont systemFontOfSize:13.5];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.imageView.image = SVBBadgeIcon(@"stethoscope",
        [UIColor colorWithRed:0.55 green:0.45 blue:0.90 alpha:1],
        [UIColor colorWithRed:0.75 green:0.55 blue:1.00 alpha:1]);
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    SVBApplyCardStyle(c, 0, 1);
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 0) { [self copyUDID]; return; }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self importTicket];
        else                    [self clearTicket];
        return;
    }
    [self showDiagnose];
}

// 复制本机 UDID (发给作者换授权串)
- (void)copyUDID {
    NSString *udid = SVBAuthUDID();
    if (!udid.length) {
        [self alert:@"读不到 UDID"
                 msg:@"本机读不到硬件 UDID / 序列号，没法走 UDID 授权。\n请联系作者说明情况。"];
        return;
    }
    [UIPasteboard generalPasteboard].string = udid;
    [self alert:@"UDID 已复制"
             msg:[NSString stringWithFormat:
        @"%@\n\n识别方式：%@\n把这一整串发给作者，作者会回你一段以 SVBOFFLINE1: 开头的授权串。\n\n"
        @"拿到后回到本页点「粘贴离线授权」导入即可（不用联网）。",
        udid, SVBAuthUDIDSource()]];
}

// 粘贴离线授权串
- (void)importTicket {
    NSString *clip = [UIPasteboard generalPasteboard].string ?: @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"粘贴离线授权串"
                         message:@"把作者发来的一整段文本（以 SVBOFFLINE1: 开头）粘进来。\n"
                                 @"不用联网立即生效，有效期按作者签发的天数计。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [clip rangeOfString:@"SVBOFFLINE1:"].location != NSNotFound ? clip : @"";
        tf.placeholder = @"SVBOFFLINE1:...";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeAlways;
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *a) {
        NSString *msg = nil;
        BOOL ok = SVBAuthImportTicket(ac.textFields.firstObject.text, &msg);
        SVBAuthInvalidateCache();
        [w reloadAuth];
        [w alert:(ok ? @"导入成功" : @"导入失败") msg:msg ?: @""];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// 清除本机授权 (视频背景开关随之隐藏)
- (void)clearTicket {
    if (!SVBAuthHasOfflineTicket(NULL)) {
        [self alert:@"当前没有授权" msg:@"本机没有已导入的授权串，不用清除。"];
        return;
    }
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"清除本机授权？"
                         message:@"清除后本机变回未授权（视频背景开关会被隐藏）。\n"
                                 @"把作者发来的授权串重新粘回来即可恢复。"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) w = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        SVBAuthClearTicket();
        [w reloadAuth];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.tableView;
    ac.popoverPresentationController.sourceRect =
        CGRectMake(self.tableView.bounds.size.width / 2, 120, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

// 纯本地自检报告 (不联网)
- (void)showDiagnose {
    SVBTextViewController *vc = [[SVBTextViewController alloc] init];
    vc.headTitle = @"授权诊断";
    vc.text = SVBAuthDiagnose();
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

// v10.4.0: 报告文本唯一来源 (报告页与「看不懂的报告.txt」文件共用)
static NSString *SVBGenerateDiagnoseReport(void) {
    @try {
    SVBManager *mgr = [SVBManager shared];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableString *r = [NSMutableString string];
    SVBRefreshMediaRoots();   // 重新定位信息App 容器后再出报告

    [r appendFormat:@"=== 诊断报告 %@ ===\n", [NSDate date]];
    [r appendFormat:@"版本: SMSVideoBG v%@ (控制App)\n", SVB_VERSION];
    [r appendFormat:@"本进程容器: %@\n", NSHomeDirectory()];
    [r appendFormat:@"本次导入首选目录: %@\n\n", [mgr mediaDirectory]];

    [r appendString:@"--- 素材根一览 (顺序 = 优先级) ---\n"];
    NSInteger idx = 0;
    for (NSString *root in SVBRootCandidates()) {
        idx++;
        [r appendFormat:@"%ld) [%@] %@\n   exists=%d writable=%d readable=%d\n", (long)idx,
            SVBRootLabel(root), root,
            (int)[fm fileExistsAtPath:root],
            (int)SVBDirWritablePath(root),
            (int)[fm isReadableFileAtPath:root]];
    }

    [r appendString:@"\n--- 共享根目录状态 ---\n"];
    for (NSString *root in SVBRootCandidates()) {
        [r appendFormat:@"%@\n  exists=%d writable=%d readable=%d\n", root,
            (int)[fm fileExistsAtPath:root],
            (int)[fm isWritableFileAtPath:root],
            (int)[fm isReadableFileAtPath:root]];
    }

    [r appendString:@"\n--- 素材文件夹内容 (v10.4.0: 所有界面共用这一个文件夹) ---\n"];
    for (NSString *root in SVBRootCandidates()) {
        NSError *err = nil;
        NSArray *raw = [fm contentsOfDirectoryAtPath:root error:&err];
        [r appendFormat:@"%@\n", root];
        if (err) {
            [r appendFormat:@"   错误: %@\n", err.localizedDescription];
        } else {
            NSMutableArray *movies = [NSMutableArray array];
            for (NSString *f in raw)
                if ([@[@"mp4", @"mov", @"m4v", @"3gp", @"mkv", @"webm"]
                        containsObject:f.pathExtension.lowercaseString]) [movies addObject:f];
            [r appendFormat:@"   视频 %lu 个: %@\n   其它条目 %lu 个 (运维文件为点前缀, Filza 默认不显示)\n",
                (unsigned long)movies.count,
                movies.count ? [movies componentsJoinedByString:@", "] : @"(无)",
                (unsigned long)(raw.count - movies.count)];
        }
        // 旧版界面子目录若还在 (尚未摊平), 一并列出方便排查
        for (NSArray<NSString *> *def in SVBContextDefinitions()) {
            NSString *dir = [root stringByAppendingPathComponent:def[0]];
            NSArray *sub = [fm contentsOfDirectoryAtPath:dir error:nil];
            if (sub.count)
                [r appendFormat:@"   [旧子目录 %@] %lu 项 (启动时会自动搬进根目录)\n", def[0], (unsigned long)sub.count];
        }
    }

    [r appendString:@"\n--- 配置状态 ---\n"];
    [r appendFormat:@"总开关=%d\n", (int)[mgr masterEnabled]];
    for (NSArray<NSString *> *def in SVBContextDefinitions()) {
        [r appendFormat:@"  %@_enabled=%d active=%@\n", def[0],
            (int)[mgr isEnabledForContext:def[0]], [mgr activeVideoPathForContext:def[0]] ?: @"(无)"];
    }

    [r appendString:@"\n--- 插件注入自检 ---\n"];
    [r appendString:[mgr injectionReport]];

    [r appendString:@"\n--- 插件心跳 (被注入进程写的存活标记) ---\n"];
    NSString *hb = [mgr readHeartbeat];
    if (hb.length) {
        [r appendString:hb];
        [r appendString:@"看到心跳 ==> 插件确实被加载进了对应进程 (每行开头会写明进程名)。\n"];
    } else {
        [r appendString:@"未检测到任何心跳 ==> 插件没有被加载进任何进程。\n"];
        [r appendString:@"处理顺序: 1) 上滑彻底关闭信息App 再打开; 2) 仍无 -> 注销(respring)一次;\n"];
        [r appendString:@"3) 打开「备忘录」看窗口顶部有没有出现诊断横幅 -> 有横幅说明注入管线正常、只差信息App; 无横幅说明 dylib 完全没被加载。\n"];
    }

    [r appendString:@"\n--- 判读要点 (v1.3) ---\n"];
    [r appendString:@"• 打开信息App 顶部有诊断横幅 = 插件已注入信息App。\n"];
    [r appendString:@"• 横幅里「信息App容器」这一行的素材数 > 0 = 插件读到了素材 (此时背景必然生效)。\n"];
    [r appendString:@"• 若横幅显示容器素材=0、其它根有素材 -> 说明素材没送进容器, 重开信息App 前先在控制App 里重新导入一次。\n"];

    [r appendString:@"\n--- 插件侧日志尾部 ---\n"];
    [r appendFormat:@"(诊断日志保留 3 天自动删除, 当前时间 %@)\n", [NSDate date]];
    NSString *tl = [mgr readTweakLog];
    [r appendString:(tl.length ? tl : @"(空)\n")];

    [r appendString:@"\n--- 控制App 侧日志(末尾) ---\n"];
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:SVB_SUITE];
    NSString *logText = [ud stringForKey:@"svb_debug_log"] ?: @"(无日志)";
    if (logText.length > 3000) logText = [logText substringFromIndex:logText.length - 3000];
    [r appendString:logText];

    // v1.7.14: 层级转储独立收录 (主日志通道只留 12K, 大转储会被挤掉)
    [r appendString:@"\n--- chat 层级转储 (隐藏/透明排查用) ---\n"];
    NSString *dumpText = [ud stringForKey:@"svb_debug_dump"] ?: @"(无转储 —— 打开一次聊天页后重新生成报告)";
    if (dumpText.length > 40000) dumpText = [dumpText substringFromIndex:dumpText.length - 40000];
    [r appendString:dumpText];

    // --- 崩溃日志 (最近一次 MobileSMS, 闪退排查用) ---
    [r appendString:@"\n--- 信息App 崩溃日志 (最近一次) ---\n"];
    @try {
        NSString *crashDir = @"/var/mobile/Library/Logs/CrashReporter";
        NSFileManager *fm2 = [NSFileManager defaultManager];
        NSArray *files = [fm2 contentsOfDirectoryAtPath:crashDir error:nil] ?: @[];
        NSMutableArray *crashes = [NSMutableArray array];
        for (NSString *f in files) {
            if ([f hasSuffix:@".ips"] && [f containsString:@"MobileSMS"] &&
                ![f containsString:@"Partial"]) {
                [crashes addObject:f];
            }
        }
        if (!crashes.count) {
            [r appendString:@"(未找到 MobileSMS 崩溃日志)\n"];
        } else {
            [crashes sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSDate *da = [fm2 attributesOfItemAtPath:[crashDir stringByAppendingPathComponent:a] error:nil][NSFileModificationDate];
                NSDate *db = [fm2 attributesOfItemAtPath:[crashDir stringByAppendingPathComponent:b] error:nil][NSFileModificationDate];
                return [db compare:da];
            }];
            NSString *newest = crashes.firstObject;
            [r appendFormat:@"文件: %@\n", newest];
            NSString *body = [NSString stringWithContentsOfFile:[crashDir stringByAppendingPathComponent:newest]
                                                       encoding:NSUTF8StringEncoding error:nil];
            if (body.length > 6000) body = [body substringToIndex:6000];
            [r appendString:(body.length ? body : @"(无法读取内容)\n")];
        }
    } @catch (NSException *e) {
        [r appendFormat:@"读取崩溃日志失败: %@ / %@\n", e.name, e.reason];
    }
    return r;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"报告生成异常: %@ / %@", e.name, e.reason];
    }
}

#pragma mark - 诊断报告页

@implementation SVBDiagnosticsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = @"诊断报告";
    // v1.8: 报告装进圆角卡片, 等宽字体 + 内边距, 不再是贴边的白板
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectInset(self.view.bounds, 10, 10)];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.backgroundColor = SVBCardColor();
    tv.layer.cornerRadius = 16;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.text = [self buildReport];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制全部" style:UIBarButtonItemStylePlain
                                         target:self action:@selector(copyAll)];
    [self.view addSubview:tv];
}

- (void)copyAll {
    UIPasteboard.generalPasteboard.string = [self buildReport];
}

- (NSString *)buildReport {
    return SVBGenerateDiagnoseReport();
}

@end

#pragma mark - 通用长文本页

@implementation SVBTextViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _headTitle.length ? _headTitle : @"报告";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.selectable = YES;
    tv.alwaysBounceVertical = YES;
    tv.backgroundColor = [UIColor systemGroupedBackgroundColor];
    tv.textContainerInset = UIEdgeInsetsMake(14, 12, 28, 12);
    tv.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    tv.textColor = [UIColor labelColor];
    tv.text = _text ?: @"";
    [self.view addSubview:tv];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"复制" style:UIBarButtonItemStylePlain
               target:self action:@selector(svbCopyAll)];
}

- (void)svbCopyAll {
    [UIPasteboard generalPasteboard].string = _text ?: @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"已复制" message:@"内容已复制到剪贴板。"
                 preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
