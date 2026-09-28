#import "AppDelegate.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// ============================================================
// 控制App主页: 总开关 + 全局效果 + 七类界面开关 + 素材管理页
// ============================================================

static char SVBSwitchAssocKey;
static char SVBProxyAssocKey;

#pragma mark - AppDelegate

@implementation SVBAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[SVBManager shared] log:@"=== 控制App 启动 ==="];
    // 自愈迁移: 把 jbroot/Documents/家目录等旧根里的素材搬进主根 (信息App 容器)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[SVBManager shared] migrateMediaIntoPrimaryRoot];
    });
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SVBHomeViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]];
    nav.navigationBar.prefersLargeTitles = YES;
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
        _titleLabel.font = [UIFont systemFontOfSize:17];
        _valueLabel = [UILabel new];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _slider = [UISlider new];
        _slider.continuous = YES;
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
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        _defs = SVBContextDefinitions();
        self.title = @"信息视频背景";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4; // 总开关 / 界面开关 / 调试 / 说明 (v1.6: 全局效果滑条已下沉到各界面)
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return (NSInteger)_defs.count;
    if (section == 2) return 1; // 注入诊断横幅
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"总开关";
    if (section == 1) return @"各界面背景";
    if (section == 2) return @"调试";
    return @"说明";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1)
        return @"点按某一行可为该界面导入/选用素材并单独设置不透明度/模糊度/音量。每个界面对应素材目录下一个独立的文件夹，用 Filza 直接放入视频同样生效。\n\n「对话详情」= 点进某个对话后上下聊天的那个界面（不是列表）。「未导入素材」的界面不会显示视频背景，导入并打开开关后生效。";
    if (section == 2)
        return @"打开信息App（或备忘录）时，窗口顶部会显示一条横幅：能看到它 = 插件注入成功。横幅里列出每个素材根是否可读、有几个素材，点一下可临时隐藏。";
    if (section == 3) {
        NSString *primary = [[SVBManager shared] mediaDirectory];
        return [NSString stringWithFormat:
                @"素材主目录（导入/删除/选用只作用于这里）：\n%@\n\n兜底目录（Filza 放这里也能读到）：\n%@\n各界面音量默认关闭。设置即时生效，无需注销。",
                primary, SVBJBMediaDirectory()];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
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
            [sw addTarget:self action:@selector(masterToggled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
        c.textLabel.text = @"启用视频背景";
        ((UISwitch *)c.accessoryView).on = [mgr masterEnabled];
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
        NSString *active = [mgr activeVideoNameForContext:key];
        c.detailTextLabel.text = active.length ? active : @"未导入素材";
        c.detailTextLabel.textColor = active.length ? [UIColor secondaryLabelColor] : [UIColor systemOrangeColor];
        sw.tag = 300 + indexPath.row;
        sw.on = [mgr isEnabledForContext:key];
        return c;
    }

    // 调试区: 注入诊断横幅开关
    if (indexPath.section == 2) {
        static NSString *debugSwitchId = @"svb-switch-debug";
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:debugSwitchId];
        if (!c) {
            c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:debugSwitchId];
            UISwitch *sw = [UISwitch new];
            [sw addTarget:self action:@selector(bannerToggled:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
        c.textLabel.text = @"显示注入诊断横幅";
        ((UISwitch *)c.accessoryView).on = [mgr debugBannerEnabled];
        return c;
    }

    // 说明区
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:basicId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:basicId];
    if (indexPath.row == 0) {
        c.textLabel.text = @"素材总目录";
        c.detailTextLabel.text = @"查看/复制路径";
    } else {
        c.textLabel.text = @"诊断报告";
        c.detailTextLabel.text = @"排查问题";
    }
    c.detailTextLabel.textColor = [UIColor systemBlueColor];
    return c;
}

- (void)bannerToggled:(UISwitch *)sw {
    SVBManager *mgr = [SVBManager shared];
    [mgr setConfigValue:@(sw.on) forKey:@"debug_banner"];
    [mgr postChangeNotification];
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
    if (indexPath.section == 1) {
        NSArray<NSString *> *def = _defs[indexPath.row];
        SVBAppMaterialController *vc = [[SVBAppMaterialController alloc] initWithContext:def[0] title:def[1]];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 1) {
            [self.navigationController pushViewController:[[SVBDiagnosticsController alloc] init] animated:YES];
            return;
        }
        NSString *path = [NSString stringWithFormat:
            @"素材主目录：\n%@\n\n兜底目录：\n%@", [[SVBManager shared] mediaDirectory], SVBJBMediaDirectory()];
        UIPasteboard.generalPasteboard.string = path;
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"素材目录（已复制到剪贴板）"
                             message:path
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
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
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(importFromLibrary)];
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
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
    if (section == 0) return [self.contextKey isEqualToString:SVBContextChat] ? 4 : 3; // 不透明度/模糊度/音量 (对话详情另加气泡不透明度)
    return MAX(1, (NSInteger)[[SVBManager shared] videosForContext:self.contextKey].count) + 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"本界面效果（仅作用于该界面）" : @"素材";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 1) return nil;
    // v1.5: 主根精确唯一 (导入/删除/选用都在这里), jbroot 仅作 Filza 兜底
    NSString *primary = [[SVBManager shared] mediaDirectory];
    return [NSString stringWithFormat:
        @"素材主目录（导入/删除/选用只作用于这里，Filza 放文件也请放这）：\n%@\n\n"
        "兜底目录（放在这里的视频也会被读取，导入时会自动搬进主目录）：\n%@\n\n"
        "左滑素材行可删除；放入新文件后下拉刷新。",
        primary, SVBJBMediaDirectory()];
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
        } else {
            // v1.7.3: 气泡不透明度 (仅对话详情; v1.7.4 只调气泡底色, 文字始终清晰)
            [c setTitle:@"气泡不透明度" value:[mgr bubbleAlphaForContext:self.contextKey] max:1.0
                    display:^NSString *(double v) {
                        if (v >= 0.999) return @"原样";
                        if (v <= 0.06)  return @"仅文字";
                        return [NSString stringWithFormat:@"%.0f%%", v * 100];
                    }];
            c.onValue = ^(double v) {
                [mgr setConfigValue:@(v) forKey:[wself.contextKey stringByAppendingString:@"_bubble_alpha"]];
                [mgr postChangeNotification];
            };
        }
        return c;
    }

    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];

    NSArray<NSString *> *videos = [mgr videosForContext:self.contextKey];
    NSString *active = [mgr activeVideoNameForContext:self.contextKey];

    if (videos.count == 0 && indexPath.row == 0) {
        c.textLabel.text = @"素材文件夹为空，点右上角「＋」从相册导入";
        c.textLabel.textColor = [UIColor secondaryLabelColor];
        c.textLabel.font = [UIFont systemFontOfSize:15];
        c.detailTextLabel.text = nil;
        c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }
    if (indexPath.row < (NSInteger)videos.count) {
        c.textLabel.text = videos[indexPath.row];
        c.textLabel.textColor = [UIColor labelColor];
        c.textLabel.font = [UIFont systemFontOfSize:17];
        c.detailTextLabel.text = @"视频";
        c.accessoryType = [active isEqualToString:videos[indexPath.row]]
                          ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    c.textLabel.text = @"＋ 从相册导入视频素材";
    c.textLabel.textColor = [UIColor systemBlueColor];
    c.textLabel.font = [UIFont systemFontOfSize:17];
    c.detailTextLabel.text = nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;
    NSArray<NSString *> *videos = [[SVBManager shared] videosForContext:self.contextKey];
    if (videos.count == 0 || indexPath.row >= (NSInteger)videos.count) {
        [self importFromLibrary];
        return;
    }
    NSString *name = videos[indexPath.row];
    __weak typeof(self) wself = self;
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:name message:@"选择操作" preferredStyle:UIAlertControllerStyleAlert];
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

- (void)importFromLibrary {
    // v1.7: 多选批量导入 + 进度提示 + 失败原因汇总 (实现见文件顶部 SVBAppImportFromLibrary)
    SVBAppImportFromLibrary(self, self.contextKey);
}

@end

#pragma mark - 诊断报告页

@implementation SVBDiagnosticsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"诊断报告";
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
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

    [r appendString:@"\n--- 各界面素材 (逐根扫描) ---\n"];
    for (NSArray<NSString *> *def in SVBContextDefinitions()) {
        [r appendFormat:@"[%@] %@\n", def[0], def[1]];
        for (NSString *root in SVBRootCandidates()) {
            NSString *dir = [root stringByAppendingPathComponent:def[0]];
            NSError *err = nil;
            NSArray *raw = [fm contentsOfDirectoryAtPath:dir error:&err];
            if (err) {
                [r appendFormat:@"   %@ -> 错误: %@\n", dir, err.localizedDescription];
            } else {
                [r appendFormat:@"   %@ -> %lu 项%@\n", dir, (unsigned long)raw.count,
                    raw.count ? [NSString stringWithFormat:@" %@", [raw componentsJoinedByString:@","]] : @""];
            }
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
    NSString *tl = [mgr readTweakLog];
    [r appendString:(tl.length ? tl : @"(空)\n")];

    [r appendString:@"\n--- 控制App 侧日志(末尾) ---\n"];
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:SVB_SUITE];
    NSString *logText = [ud stringForKey:@"svb_debug_log"] ?: @"(无日志)";
    if (logText.length > 3000) logText = [logText substringFromIndex:logText.length - 3000];
    [r appendString:logText];

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
}

@end
