#import "SVBCommon.h"
#import "SVBAuth.h"
#import <CoreFoundation/CFNotificationCenter.h>
#import <unistd.h>
#import <stdlib.h>
#import <stdio.h>
#import <limits.h>
#import <signal.h>

// ============================================================
// 共享核心: 配置管理 / 素材文件夹 / 播放器 / 背景视图 / 诊断
//
// 素材模型 (v1.3 宿主容器优先 + 多根聚合 + 多根齐写):
//   候选根 (按优先级):
//     0) <信息App 数据容器>/Library/SMSVideoBG   <- tweak 进程 100% 可读写 (核心)
//     1) /var/jb/Library/SMSVideoBG              <- jbroot, 越狱进程可达
//     2) /var/mobile/Documents/SMSVideoBG        <- Filza 常用目录
//     3) <本进程家目录>/Documents/SMSVideoBG
//   v10.4.0: 不再分界面子目录 —— 所有界面共用素材根里的同一批视频,
//   每个界面单独记住自己选了哪一个文件/什么效果。旧版子目录里的素材
//   会在启动时自动摊平到根目录, 空目录随后删除。
//
// 配置模型: NSUserDefaults(suite) + 每个根下 .svb_config.plist 双写。
//   信息App 进程若读不到 prefs, 仍可从 .svb_config.plist 读到开关状态。
//   配置里同时带上 config_version, 便于诊断「插件读到的开关是否最新」。
// ============================================================

NSString * const SVBContextMain     = @"main";
NSString * const SVBContextAll      = @"all";
NSString * const SVBContextKnown    = @"known";
NSString * const SVBContextUnknown  = @"unknown";
NSString * const SVBContextUnread   = @"unread";
NSString * const SVBContextJunk     = @"junk";
NSString * const SVBContextDeleted  = @"deleted";
NSString * const SVBContextChat     = @"chat";

// v10.4.0: 运维文件全部改成点前缀 —— Filza 默认不显示, 素材文件夹里只剩视频。
// 旧名字 (_config.plist 等) 保留为「迁移源」: 启动时自动改名为新名字。
static NSString * const SVBConfigFileName    = @".svb_config.plist";
static NSString * const SVBConfigFileNameOld = @"_config.plist";
static NSString * const SVBAliveFileName     = @".svb_alive";
static NSString * const SVBAliveFileNameOld  = @"_tweak_alive";
static NSString * const SVBLogFileName       = @".svb_tweak.log";
static NSString * const SVBLogFileNameOld    = @"_tweak.log";
static NSString * const SVBProbeFileName     = @".svb_probe";
static NSString * const SVBProbeFileNameOld  = @"_app_probe";
// 诊断日志最长保留天数 (超过自动删除 —— 用户要求「诊断报告不要一直保留」)
static const NSTimeInterval SVBLogMaxAgeDays = 3.0;

// ---- v9.9.11 前后台自愈 / 切后台自动清理 的共享状态 ----
static volatile BOOL sSVBInBackground = NO;       // 宿主当前是否在后台
static int64_t sSVBKillGeneration = 0;            // 代际号: 一递增, 已排队的清理立即作废
static UIBackgroundTaskIdentifier sSVBKillTask = 0;   // 0 == UIBackgroundTaskInvalid (它不是编译期常量)

// 真正的终止动作 (只会在信息App 进程里被调用; 调用前已校验 bundle id)
static void SVBPerformBackgroundKill(void) {
    @try {
        [[SVBManager shared] log:@"后台清理: 结束宿主进程 (pid %d) —— 避免回前台视频卡住", (int)getpid()];
    } @catch (NSException *e) {}
    usleep(180 * 1000);          // 给日志落盘留点时间
    kill(getpid(), SIGKILL);     // 干净终止 (不留 crash 报告)
    _exit(0);                    // 兜底: SIGKILL 万一被拦
}

NSArray<NSArray<NSString *> *> *SVBContextDefinitions(void) {
    return @[ @[SVBContextMain,    @"主页面",       @"打开信息App 的第一屏(过滤器列表)"],
              @[SVBContextAll,     @"所有信息",     @"信息主列表(所有会话)"],
              @[SVBContextKnown,   @"已知发件人",   @"已知发件人列表"],
              @[SVBContextUnknown, @"未知发件人",   @"未知发件人列表"],
              @[SVBContextUnread,  @"未读信息",     @"未读信息列表"],
              @[SVBContextJunk,    @"垃圾信息",     @"垃圾信息列表"],
              @[SVBContextDeleted, @"最近删除",     @"最近删除列表"],
              @[SVBContextChat,    @"对话详情",     @"点进某个会话后的聊天界面"] ];
}

NSString *SVBJBMediaDirectory(void) {
    return [@"/var/jb/Library/" stringByAppendingString:SVB_MEDIA_DIR_NAME];
}

NSString *SVBHostBundleIdentifier(void) {
    static NSString *bid = nil;
    if (bid) return bid;
    @try {
        bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    } @catch (NSException *e) {
        bid = @"";
    }
    return bid;
}

static BOOL SVBIsControlApp(void) {
    return [SVBHostBundleIdentifier() isEqualToString:SVB_APP_BUNDLE_ID];
}

NSString *SVBAppContainerMediaDirectory(void) {
    NSString *home = NSHomeDirectory();
    if (!home.length) return nil;
    return [[home stringByAppendingPathComponent:@"Library"]
            stringByAppendingPathComponent:SVB_MEDIA_DIR_NAME];
}

// 定位指定 bundleId 的数据容器 (越权/jailbreak 进程可用)
NSString *SVBFindAppDataContainer(NSString *bundleId) {
    if (!bundleId.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *bases = @[@"/var/mobile/Containers/Data/Application",
                                   @"/private/var/mobile/Containers/Data/Application"];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    for (NSString *base in bases) {
        NSArray *uuids = [fm contentsOfDirectoryAtPath:base error:nil];
        for (NSString *u in uuids)
            [dirs addObject:[base stringByAppendingPathComponent:u]];
    }
    if (!dirs.count) return nil;
    // 1) 容器元数据精确匹配
    for (NSString *dir in dirs) {
        NSString *meta = [dir stringByAppendingPathComponent:
                          @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([d[@"MCMMetadataIdentifier"] isEqualToString:bundleId]) return dir;
    }
    // 2) 兜底: 目录内含 Library/SMS 特征 (苹果「信息」数据)
    for (NSString *dir in dirs) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Library/SMS"]])
            return dir;
    }
    return nil;
}

NSString *SVBRootLabel(NSString *root) {
    if (!root.length) return @"?";
    if ([root hasPrefix:SVB_MEDIA_FRIENDLY_PARENT]) return SVB_AUTHOR_NAME;
    if ([root containsString:@"/Containers/Data/Application"]) return @"信息App容器";
    if ([root hasPrefix:@"/var/jb"] || [root containsString:@"/var/jb/"]) return @"jbroot";
    if ([root hasPrefix:@"/var/mobile/Documents"]) return @"共享文档";
    if ([root containsString:@"/var/mobile"]) return @"家目录";
    return root.lastPathComponent;
}

static NSArray<NSString *> *sSVBRoots = nil;

void SVBRefreshMediaRoots(void) {
    sSVBRoots = nil;
}

// 旧版遗留根 (只用于启动时把旧素材搬进主根, 不参与日常读取)
static NSArray<NSString *> *SVBLegacyRoots(void) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    [a addObject:SVBJBMediaDirectory()];   // v1.5~10.2 的兜底根, 里面可能还有用户放的素材
    [a addObject:[@"/var/mobile/Documents/" stringByAppendingString:SVB_MEDIA_DIR_NAME]];
    NSString *home = NSHomeDirectory();
    if (home.length)
        [a addObject:[[home stringByAppendingPathComponent:@"Documents"]
                      stringByAppendingPathComponent:SVB_MEDIA_DIR_NAME]];
    return a;
}

// v10.3.0: 单一素材根 —— 信息App 数据容器(mobile 侧定位容器, tweak 侧=自身家目录,
// 两者指向同一物理目录)。导入/读取/删除全部只看这里, 路径精确唯一。
// jbroot 不再作为日常读取根 (沙盒宿主读不到), 只当"定位不到容器"时的应急落点。
NSArray<NSString *> *SVBRootCandidates(void) {
    if (sSVBRoots) return sSVBRoots;
    NSMutableArray<NSString *> *a = [NSMutableArray array];

    NSString *primary = nil;
    if (SVBIsControlApp()) {
        NSString *c = SVBFindAppDataContainer(SVB_SMS_BUNDLE_ID);
        if (c.length)
            primary = [[c stringByAppendingPathComponent:@"Library"]
                       stringByAppendingPathComponent:SVB_MEDIA_DIR_NAME];
    } else {
        primary = SVBAppContainerMediaDirectory();
    }
    if (primary.length) [a addObject:primary];
    if (!a.count) [a addObject:SVBJBMediaDirectory()];   // 应急兜底(仅定位不到容器时)

    sSVBRoots = [a copy];
    return sSVBRoots;
}

// ---- v10.4.0 运维文件治理 (在插件 %ctor 与控制App 启动时各跑一次) ----
//   ① 旧名字文件 (_config.plist/_tweak_alive/_tweak.log/_app_probe) 改名/清理,
//      让 Filza 里不再出现这些下划线开头的杂项;
//   ② 诊断日志超过 3 天自动删除 (用户要求「诊断报告不要一直保留」);
//   ③ 旧版按界面分的子目录 (main/all/known/...) 摊平: 视频移到素材根,
//      空目录删除 —— 所有界面共用一个文件夹。
static BOOL SVBCleanupIsMovie(NSString *f) {
    if ([f hasPrefix:@"."] || [f hasPrefix:@"_"]) return NO;
    return [@[@"mp4", @"mov", @"m4v", @"3gp", @"mkv", @"webm"]
            containsObject:f.pathExtension.lowercaseString];
}

void SVBCleanupHousekeeping(void) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDate *now = [NSDate date];
        for (NSString *root in SVBRootCandidates()) {
            if (![fm fileExistsAtPath:root]) continue;

            // ① 配置: 旧名 -> 新名 (新名已在则旧名直接删, 它必然是旧版本写的过期副本)
            NSString *cfgNew = [root stringByAppendingPathComponent:SVBConfigFileName];
            NSString *cfgOld = [root stringByAppendingPathComponent:SVBConfigFileNameOld];
            if ([fm fileExistsAtPath:cfgOld]) {
                if (![fm fileExistsAtPath:cfgNew])
                    [fm moveItemAtPath:cfgOld toPath:cfgNew error:nil];
                if ([fm fileExistsAtPath:cfgOld]) [fm removeItemAtPath:cfgOld error:nil];
            }
            // ① 其余旧名杂项: 心跳/日志/探针在新机制下都会重建, 旧文件直接删
            for (NSString *old in (@[[root stringByAppendingPathComponent:SVBAliveFileNameOld],
                                     [root stringByAppendingPathComponent:SVBLogFileNameOld],
                                     [root stringByAppendingPathComponent:SVBProbeFileNameOld]]))
                if ([fm fileExistsAtPath:old]) [fm removeItemAtPath:old error:nil];

            // ② 过期诊断文件删除 (日志/探针; 心跳会持续刷新, 不按龄删)
            for (NSString *p in (@[[root stringByAppendingPathComponent:SVBLogFileName],
                                   [root stringByAppendingPathComponent:SVBProbeFileName]])) {
                NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
                NSDate *mt = at[NSFileModificationDate];
                if (mt && [now timeIntervalSinceDate:mt] > SVBLogMaxAgeDays * 86400.0)
                    [fm removeItemAtPath:p error:nil];
            }

            // ③ 摊平界面子目录: 里面的视频上移到素材根, 空目录删除
            for (NSArray<NSString *> *def in SVBContextDefinitions()) {
                NSString *sub = [root stringByAppendingPathComponent:def[0]];
                if (![fm fileExistsAtPath:sub]) continue;
                NSDictionary *at = [fm attributesOfItemAtPath:sub error:nil];
                if (![at[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
                for (NSString *f in [fm contentsOfDirectoryAtPath:sub error:nil]) {
                    if (!SVBCleanupIsMovie(f)) continue;
                    NSString *src = [sub stringByAppendingPathComponent:f];
                    NSString *dst = [root stringByAppendingPathComponent:f];
                    if ([fm fileExistsAtPath:dst]) {
                        // 根目录已有同名: 保留已有的, 这份换个名字 (不丢用户文件)
                        NSString *alt = [root stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"%@_子目录.%@",
                                f.stringByDeletingPathExtension, f.pathExtension]];
                        [fm moveItemAtPath:src toPath:alt error:nil];
                    } else {
                        [fm moveItemAtPath:src toPath:dst error:nil];
                    }
                }
                // 只删空目录: 里面有非视频残留就留着 (绝不误删用户的东西)
                NSArray *rest = [fm contentsOfDirectoryAtPath:sub error:nil];
                if (rest.count == 0) [fm removeItemAtPath:sub error:nil];
            }
        }

        // ② 共享日志 (Documents/Library) 超龄也删
        for (NSString *p in (@[@"/var/mobile/Documents/smsvideobg_debug.log",
                               @"/var/mobile/Library/smsvideobg_debug.log"])) {
            NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
            NSDate *mt = at[NSFileModificationDate];
            if (mt && [now timeIntervalSinceDate:mt] > SVBLogMaxAgeDays * 86400.0)
                [fm removeItemAtPath:p error:nil];
        }
    } @catch (NSException *e) {}
}

#pragma mark - 统一素材路径 (v10.3.0)

NSString *SVBMediaFriendlyRoot(void) {
    return [SVB_MEDIA_FRIENDLY_PARENT stringByAppendingPathComponent:SVB_AUTHOR_NAME];
}

// v10.4.0: 不再按界面分子目录 —— 所有界面共用这一个文件夹。
// ctx 参数保留只为兼容旧调用点, 一律返回素材根本身。
NSString *SVBMediaFriendlyPathForContext(NSString *ctx) {
    return SVBMediaFriendlyRoot();
}

// 把「统一路径」做成指向真实素材根的软链。
//   ① 不存在 -> 建父目录 + 建软链;
//   ② 已是软链 -> 指向不对就重建 (指向对了就什么都不做);
//   ③ 是个真目录(用户早就往这里丢过素材) -> 先把视频搬进真实根, 原目录改名备份, 再建软链。
//      (改名而不是删除 —— 用户的东西一个字节都不丢)
static NSInteger SVBAdoptFriendlyDirIfReal(NSString *link, NSString *target) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger copied = 0;
    BOOL (^isMovie)(NSString *) = ^BOOL (NSString *f) {
        if ([f hasPrefix:@"."] || [f hasPrefix:@"_"]) return NO;
        return [@[@"mp4", @"mov", @"m4v", @"3gp", @"mkv", @"webm"]
                containsObject:f.pathExtension.lowercaseString];
    };

    // v10.4.0: 不分界面 —— 子目录里和根目录散落的视频全部搬进真实根「根部」
    NSArray<NSString *> *scanDirs = @[];
    {
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        for (NSArray<NSString *> *def in SVBContextDefinitions()) {
            NSString *d = [link stringByAppendingPathComponent:def[0]];
            if ([fm fileExistsAtPath:d]) [dirs addObject:d];
        }
        [dirs addObject:link];   // 根目录散落文件最后扫 (含子目录搬上来的不在内)
        scanDirs = dirs;
    }
    for (NSString *dir in scanDirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (!isMovie(f)) continue;
            NSDictionary *attr = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
            if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
            NSString *dst = [target stringByAppendingPathComponent:f];
            if ([fm fileExistsAtPath:dst]) continue;      // 同名保留真实根里已有的
            if ([fm copyItemAtPath:[dir stringByAppendingPathComponent:f] toPath:dst error:nil]) copied++;
        }
    }
    return copied;
}

static NSString *SVBFriendlyBackupStamp(void) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    return [df stringFromDate:[NSDate date]] ?: @"bak";
}

BOOL SVBEnsureFriendlyMediaPath(NSString **detail) {
    NSString *msg = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parent = SVB_MEDIA_FRIENDLY_PARENT;
    NSString *link   = SVBMediaFriendlyRoot();

    @try {
        // 真实素材根 (容器) —— mediaDirectory 会顺便把它建好
        NSString *target = [[SVBManager shared] mediaDirectory];
        if (!target.length) { msg = @"定位不到信息App 素材目录"; return NO; }
        // 只有定位到信息App 容器时才做软链: 万一退到应急根(jbroot), 软链会指向错地方
        if (![target containsString:@"/Containers/Data/Application"]) {
            msg = @"定位不到信息App 数据容器（先打开一次「信息」App，再回到这里点一次）";
            return NO;
        }
        [[SVBManager shared] contextDirectory:SVBContextAll];   // 顺便保证素材根存在 (v10.4.0 起不再有 all/ 子目录)

        if (![fm fileExistsAtPath:parent]) {
            [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
            [fm setAttributes:@{NSFileOwnerAccountName: @"mobile",
                                NSFileGroupOwnerAccountName: @"mobile",
                                NSFilePosixPermissions: @(0755)}
                 ofItemAtPath:parent error:nil];
        }
        if (![fm fileExistsAtPath:parent]) { msg = @"建不了 /var/mobile/信息视频背景素材"; return NO; }

        NSDictionary *attr = [fm attributesOfItemAtPath:link error:nil];
        NSString *type = attr[NSFileType];
        NSString *note = nil;

        if (!attr) {
            // ① 还没有: 直接建软链
        } else if ([type isEqualToString:NSFileTypeSymbolicLink]) {
            NSString *dest = [fm destinationOfSymbolicLinkAtPath:link error:nil];
            if ([dest isEqualToString:target]) {
                if (detail) *detail = [NSString stringWithFormat:@"%@\n(软链 -> 信息App 素材目录, 已就绪)", link];
                return YES;
            }
            if (![fm removeItemAtPath:link error:nil]) {   // 指向别处(旧容器 UUID) -> 重建
                msg = @"旧软链删不掉：请用 Filza 删掉这个软链后重开本App";
                return NO;
            }
        } else if ([type isEqualToString:NSFileTypeDirectory]) {
            // ③ 用户已经在这条路径上放过素材: 先搬进来, 原目录改名备份(不删)
            NSInteger n = SVBAdoptFriendlyDirIfReal(link, target);
            NSString *bak = [NSString stringWithFormat:@"%@_旧目录备份_%@", link, SVBFriendlyBackupStamp()];
            if ([fm moveItemAtPath:link toPath:bak error:nil]) {
                note = [NSString stringWithFormat:
                        @"已把这里原有的 %ld 个视频搬进素材目录，原文件夹改名备份为「%@」——没删任何东西。",
                        (long)n, bak.lastPathComponent];
            } else if ([fm fileExistsAtPath:link]) {
                msg = [NSString stringWithFormat:@"%@ 是个真文件夹且改名失败：先用 Filza 把它改个名, 再重开本App", link];
                return NO;
            }
        } else {
            // 普通文件占位 -> 挪走
            NSString *bak = [NSString stringWithFormat:@"%@_旧文件_%@", link, SVBFriendlyBackupStamp()];
            if ([fm moveItemAtPath:link toPath:bak error:nil])
                note = [NSString stringWithFormat:@"原位置的同名文件已改名备份为「%@」。", bak.lastPathComponent];
        }

        NSError *lerr = nil;
        if (![fm createSymbolicLinkAtPath:link withDestinationPath:target error:&lerr]) {
            msg = [NSString stringWithFormat:@"软链建不了：%@", lerr.localizedDescription ?: @"未知原因"];
            return NO;
        }
        [fm setAttributes:@{NSFileOwnerAccountName: @"mobile",
                            NSFileGroupOwnerAccountName: @"mobile"}
             ofItemAtPath:parent error:nil];

        if (detail) {
            NSString *base = [NSString stringWithFormat:@"%@\n(软链 -> 信息App 素材目录, 已就绪)", link];
            *detail = note.length ? [NSString stringWithFormat:@"%@\n\n%@", base, note] : base;
        }
        return YES;
    } @catch (NSException *e) {
        msg = [NSString stringWithFormat:@"异常：%@", e.reason];
    }
    if (detail) *detail = msg ?: @"未知错误";
    return NO;
}

// 在 Filza 中打开路径; 没装 Filza 就把路径复制到剪贴板并说明。
BOOL SVBOpenPathInFilza(NSString *path, NSString **message) {
    if (!path.length) path = SVBMediaFriendlyRoot();
    if (![NSThread isMainThread]) {
        __block BOOL ok = NO;
        __block NSString *m = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ ok = SVBOpenPathInFilza(path, &m); });
        if (message) *message = m;
        return ok;
    }
    UIApplication *app = [UIApplication sharedApplication];
    NSString *enc = [path stringByAddingPercentEncodingWithAllowedCharacters:
                     [NSCharacterSet URLPathAllowedCharacterSet]] ?: path;
    // Filza 支持的两种写法都试一遍
    NSArray<NSString *> *cands = @[[NSString stringWithFormat:@"filza://view%@", enc],
                                   [NSString stringWithFormat:@"filza://%@", enc]];
    for (NSString *s in cands) {
        NSURL *u = [NSURL URLWithString:s];
        if (u && [app canOpenURL:u]) {
            [app openURL:u options:@{} completionHandler:nil];
            if (message) *message = [NSString stringWithFormat:@"已在 Filza 中打开：\n%@", path];
            return YES;
        }
    }
    // 兜底: 有些越狱环境 canOpenURL 判定不准 -> 盲开一次, 同时把路径放进剪贴板
    NSURL *u0 = [NSURL URLWithString:cands.firstObject];
    if (u0) [app openURL:u0 options:@{} completionHandler:nil];
    [UIPasteboard generalPasteboard].string = path;
    if (message) *message = [NSString stringWithFormat:
        @"没检测到 Filza（或未装 Filza File Manager）。\n\n路径已复制到剪贴板：\n%@", path];
    return NO;
}

// 目录可写性探测 (创建目录 + 写探针文件)
static BOOL SVBDirWritable(NSString *dir) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (![fm fileExistsAtPath:dir]) return NO;
        NSString *probe = [dir stringByAppendingPathComponent:SVBProbeFileName];
        BOOL ok = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (ok) [fm removeItemAtPath:probe error:nil];
        return ok;
    } @catch (NSException *e) {
        return NO;
    }
}

static char SVBBGKey;
static char SVBAppliedCtxKey;   // v1.7.19: 每个 VC 实际挂载的语境 (离开时精确暂停对应播放器)
static char SVBBubbleOrigColorKey;   // 气泡原始底色 (v1.7.4: 半透明化时保留文字清晰)
static char SVBBubbleOrigContentsKey; // v1.7.5: 气泡原始 layer.contents (气泡底图)
static char SVBBubbleOrigAlphaKey;    // v1.7.9: 气泡原始 alpha (最低档彻底隐藏时缓存)
static char SVBOrigEffectKey;         // v1.7.13: 原始 UIVisualEffectView.effect (原样档恢复材质)
static BOOL SVBBalloonDrawSwizzled = NO; // v1.7.7: 气泡 drawRect 拦截只做一次
static BOOL SVBHierarchyDumped = NO;     // v1.7.8: 聊天页层级转储只做一次
static NSString *SVBLastHeartbeatTag = nil;

// 从视图向上找宿主 VC (chrome 节流补扫需要)
static UIViewController *SVBViewControllerForView(UIView *view) {
    UIResponder *r = view.nextResponder;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    return (UIViewController *)r;
}

// 对外暴露的可写性探测 (控制App 诊断页需要)
BOOL SVBDirWritablePath(NSString *dir) {
    return SVBDirWritable(dir);
}

#pragma mark - 管理器

@interface SVBManager ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVPlayer *> *players;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVPlayerItem *> *items;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVPlayerLooper *> *loopers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *playerPaths;
@property (nonatomic, strong) NSMutableSet<NSString *> *loggedClasses;
// 私有方法前置声明 (避免 -Wobjc-method-access 在 -Werror 下报错)
- (NSArray<NSString *> *)configPaths;
- (CGFloat)numForKey:(NSString *)k default:(CGFloat)d;
- (NSArray<NSString *> *)directoriesForContext:(NSString *)ctx includeRootFallback:(BOOL)fallback;
- (BOOL)isMovieFile:(NSString *)name;
- (NSArray<NSString *> *)listFilesInDir:(NSString *)dir;
- (void)attachBackground:(SVBVideoBackgroundView *)bg toViewController:(UIViewController *)vc;
- (void)detachBackground:(SVBVideoBackgroundView *)bg fromViewController:(UIViewController *)vc;
- (void)clearBackgroundsOfView:(UIView *)view depth:(NSInteger)depth;
- (void)deepChromePass:(UIView *)view depth:(NSInteger)depth ctx:(NSString *)ctx;
- (void)bubblePass:(UIView *)view depth:(NSInteger)depth inCell:(BOOL)inCell ctx:(NSString *)ctx sysBg:(BOOL)sysBg;
- (void)dumpVisibleResidue:(UIView *)view ctx:(NSString *)ctx;   // v1.7.12
- (void)collectResidue:(UIView *)v depth:(NSInteger)depth effAlpha:(CGFloat)ea into:(NSMutableString *)out; // v1.7.12
- (void)applyBubbleAlpha:(UIView *)balloon ctx:(NSString *)ctx;
- (void)hideViewTemporarily:(UIView *)v;   // v1.7.9
- (void)restoreViewAlpha:(UIView *)v;      // v1.7.9
- (BOOL)subtreeContainsVideoBg:(UIView *)view depth:(NSInteger)depth; // v1.7.9
- (BOOL)viewHasTextDescendant:(UIView *)view depth:(NSInteger)depth;
- (BOOL)viewHasImageDescendant:(UIView *)view depth:(NSInteger)depth;
- (void)clearDrawnBackgroundsOf:(UIView *)view depth:(NSInteger)depth on:(BOOL)on;
- (void)applyTextShadow:(UIView *)view;
- (void)swizzleBalloonDrawingIfNeeded;
- (void)patchDrawMethodOf:(Class)cls selector:(SEL)sel patched:(NSMutableSet<NSValue *> *)patched kind:(NSInteger)kind;
- (void)dumpHierarchyForDiagnosis:(UIView *)view;
- (void)dumpHierarchyRec:(UIView *)v depth:(NSInteger)depth into:(NSMutableString *)out;
- (void)refreshInView:(UIView *)view;
- (void)playerDidEnd:(NSNotification *)n;
- (void)collectVideoViewsIn:(UIView *)view into:(NSMutableArray *)out;
- (void)pauseAllPlayers;
- (void)scheduleBackgroundKill;
@end

@implementation SVBManager

+ (instancetype)shared {
    static SVBManager *_svbSharedInstance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _svbSharedInstance = [self new];
    });
    return _svbSharedInstance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _players       = [NSMutableDictionary new];
        _items         = [NSMutableDictionary new];
        _loopers       = [NSMutableDictionary new];
        _playerPaths   = [NSMutableDictionary new];
        _loggedClasses = [NSMutableSet new];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerDidEnd:)
                                                     name:@"AVPlayerItemDidPlayToEndTime"
                                                   object:nil];
    }
    return self;
}

- (void)playerDidEnd:(NSNotification *)n {
    @try {
        AVPlayerItem *item = n.object;
        for (NSString *k in self.players) {
            if (self.items[k] == item) {
                if (self.loopers[k]) continue; // AVPlayerLooper 已无缝循环, 不干预
                [self.players[k] seekToTime:kCMTimeZero];
                [self.players[k] play];
            }
        }
    } @catch (NSException *e) {}
}

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:SVB_SUITE];
}

#pragma mark - 配置 (prefs + 文件 双写双读)

- (NSArray<NSString *> *)configPaths {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *root in SVBRootCandidates())
        [a addObject:[root stringByAppendingPathComponent:SVBConfigFileName]];
    return a;
}

// 读取用: 新名字 + 旧名字 (_config.plist, v10.3 及更早写的) 都认
- (NSArray<NSString *> *)configReadPaths {
    NSMutableArray *a = [[self configPaths] mutableCopy];
    for (NSString *root in SVBRootCandidates())
        [a addObject:[root stringByAppendingPathComponent:SVBConfigFileNameOld]];
    return a;
}

- (NSDictionary *)effectiveConfig {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    @try {
        NSDictionary *pd = [[self prefs] dictionaryRepresentation];
        if ([pd isKindOfClass:[NSDictionary class]]) [d addEntriesFromDictionary:pd];
    } @catch (NSException *e) {}
    for (NSString *path in [self configReadPaths]) {
        @try {
            NSDictionary *fd = [NSDictionary dictionaryWithContentsOfFile:path];
            if ([fd isKindOfClass:[NSDictionary class]]) [d addEntriesFromDictionary:fd];
        } @catch (NSException *e) {}
    }
    return d;
}

- (id)configValueForKey:(NSString *)key {
    if (!key.length) return nil;
    @try {
        return [self effectiveConfig][key];
    } @catch (NSException *e) {
        return nil;
    }
}

- (void)setConfigValue:(id)value forKey:(NSString *)key {
    if (!key.length) return;
    // 1) prefs 通道 (控制App 侧一定可用)
    @try {
        NSUserDefaults *p = [self prefs];
        if (value) [p setObject:value forKey:key];
        else       [p removeObjectForKey:key];
        [p synchronize];
    } @catch (NSException *e) {}
    // 2) 文件通道 (每个可写根各写一份完整配置)
    @try {
        NSMutableDictionary *d = [[self effectiveConfig] mutableCopy];
        if (value) d[key] = value;
        else       [d removeObjectForKey:key];
        for (NSString *path in [self configPaths]) {
            NSString *dir = [path stringByDeletingLastPathComponent];
            if (!SVBDirWritable(dir)) continue;
            if (![d writeToFile:path atomically:YES]) {
                [self log:@"配置写盘失败: %@", path];
            }
        }
    } @catch (NSException *e) {}
}

- (BOOL)masterEnabled {
    id v = [self configValueForKey:@"master_enabled"];
    return v ? [v boolValue] : YES; // 默认开
}

// v1.8.5: 自定义 App 显示名 (SpringBoard 的 SBApplication.displayName 钩子读这个)
- (NSString *)appDisplayName {
    id v = [self configValueForKey:@"app_display_name"];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

- (CGFloat)numForKey:(NSString *)k default:(CGFloat)d {
    id v = [self configValueForKey:k];
    return v ? [v doubleValue] : d;
}

- (CGFloat)globalAlpha  { return MAX(0.0, MIN(1.0,  [self numForKey:@"alpha"  default:0.65])); }
- (CGFloat)globalBlur   { return MAX(0.0, MIN(30.0, [self numForKey:@"blur"   default:8.0]));  }
- (CGFloat)globalVolume { return MAX(0.0, MIN(1.0,  [self numForKey:@"volume" default:0.0]));  } // 默认静音

// v1.6: 每个界面独立效果 (键: <ctx>_alpha/_blur/_volume; 未设置时回退全局值,
// 所以老用户升级后各界面先保持原全局效果, 一动滑条即独立)
- (CGFloat)alphaForContext:(NSString *)ctx {
    return MAX(0.0, MIN(1.0, [self numForKey:[ctx stringByAppendingString:@"_alpha"]
                                    default:[self globalAlpha]]));
}
- (CGFloat)blurForContext:(NSString *)ctx {
    return MAX(0.0, MIN(30.0, [self numForKey:[ctx stringByAppendingString:@"_blur"]
                                     default:[self globalBlur]]));
}
- (CGFloat)volumeForContext:(NSString *)ctx {
    return MAX(0.0, MIN(1.0, [self numForKey:[ctx stringByAppendingString:@"_volume"]
                                    default:[self globalVolume]]));
}
// v1.7.3: 气泡不透明度 (仅对话详情; 1.0 = 原样, 调低让气泡变透)
- (CGFloat)bubbleAlphaForContext:(NSString *)ctx {
    return MAX(0.05, MIN(1.0, [self numForKey:[ctx stringByAppendingString:@"_bubble_alpha"]
                                     default:1.0]));
}

// v1.6: 界面离开暂停 / 回来恢复 (解决多界面视频同时出声的互串)
- (void)setContextActive:(BOOL)active context:(NSString *)ctx {
    @try {
        AVPlayer *p = self.players[ctx];
        if (!p) return;
        if (active) {
            if (p.rate == 0.0) [p play];
        } else {
            if (p.rate != 0.0) [p pause];
        }
    } @catch (NSException *e) {}
}

- (BOOL)isEnabledForContext:(NSString *)ctx {
    id v = [self configValueForKey:[ctx stringByAppendingString:@"_enabled"]];
    return v ? [v boolValue] : NO; // 默认关
}

- (void)setEnabled:(BOOL)on forContext:(NSString *)ctx {
    [self setConfigValue:@(on) forKey:[ctx stringByAppendingString:@"_enabled"]];
    [self postChangeNotification];
}

- (void)postChangeNotification {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(SVB_DARWIN_NOTE), NULL, NULL, YES);
}

#pragma mark - 调试日志 / 心跳 (多通道必达)

- (void)log:(NSString *)fmt, ... {
    @try {
        va_list args;
        va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        // 每行都带「进程名 + pid」: 一眼看出这行是信息App 插件写的还是控制App 写的
        NSString *proc = NSProcessInfo.processInfo.processName ?: @"?";
        NSString *line = [NSString stringWithFormat:@"[%@] (%@ pid%d) %@\n",
                          [NSDate date], proc, (int)getpid(), msg];

        // 通道 1: prefs suite (控制App 诊断页读这个)
        //   v10.4.0: 超过 3 天自动清空 —— 诊断日志不一直保留
        @try {
            NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:SVB_SUITE];
            NSDate *stamp = [ud objectForKey:@"svb_debug_log_at"];
            BOOL stale = stamp && [[NSDate date] timeIntervalSinceDate:stamp] > SVBLogMaxAgeDays * 86400.0;
            NSString *old = stale ? @"" : ([ud stringForKey:@"svb_debug_log"] ?: @"");
            NSString *nu = [old stringByAppendingString:line];
            if (nu.length > 12000) nu = [nu substringFromIndex:nu.length - 12000];
            [ud setObject:nu forKey:@"svb_debug_log"];
            [ud setObject:[NSDate date] forKey:@"svb_debug_log_at"];
            [ud synchronize];
        } @catch (NSException *e) {}

        // 通道 2: 每个素材根各写一份 .svb_tweak.log (点前缀, Filza 默认不显示)
        //   信息App 容器根必然可写 -> 控制App 也能读到插件在信息App 里写的日志
        //   v10.4.0: 超过 3 天或 400KB 自动删除
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            for (NSString *root in SVBRootCandidates()) {
                [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *p = [root stringByAppendingPathComponent:SVBLogFileName];
                NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
                NSDate *mt = at[NSFileModificationDate];
                BOOL tooBig = [at[NSFileSize] unsignedLongLongValue] > 400000;
                BOOL tooOld = mt && [[NSDate date] timeIntervalSinceDate:mt] > SVBLogMaxAgeDays * 86400.0;
                if (tooBig || tooOld) [fm removeItemAtPath:p error:nil];
                FILE *f = fopen(p.UTF8String, "a");
                if (f) { fputs(line.UTF8String, f); fclose(f); }
            }
        } @catch (NSException *e) {}

        // 通道 3/4: 常见可写目录 (Filza 查看方便) —— 同样超 3 天自动删
        for (NSString *p in (@[@"/var/mobile/Documents/smsvideobg_debug.log",
                               @"/var/mobile/Library/smsvideobg_debug.log"])) {
            @try {
                NSFileManager *fm = [NSFileManager defaultManager];
                NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
                NSDate *mt = at[NSFileModificationDate];
                if (mt && [[NSDate date] timeIntervalSinceDate:mt] > SVBLogMaxAgeDays * 86400.0)
                    [fm removeItemAtPath:p error:nil];
                FILE *f = fopen(p.UTF8String, "a");
                if (f) { fputs(line.UTF8String, f); fclose(f); }
            } @catch (NSException *e) {}
        }
        @try {
            NSString *tp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"svb_debug.log"];
            FILE *tf = fopen(tp.UTF8String, "a");
            if (tf) { fputs(line.UTF8String, tf); fclose(tf); }
        } @catch (NSException *e) {}
    } @catch (NSException *e) {}
}

// 存活心跳: 信息App 进程里插件每次活动都刷新, 控制App 诊断页据此判断是否注入
- (void)writeHeartbeat:(NSString *)tag {
    @try {
        if (tag.length && SVBLastHeartbeatTag && [SVBLastHeartbeatTag isEqualToString:tag]) return;
        SVBLastHeartbeatTag = [tag copy];
        NSString *line = [NSString stringWithFormat:@"[%@] %@ pid=%d %@\n",
                          [NSDate date], NSProcessInfo.processInfo.processName ?: @"?",
                          (int)getpid(), tag ?: @"(alive)"];
        for (NSString *root in SVBRootCandidates()) {
            if (!SVBDirWritable(root)) continue;
            NSString *alive = [root stringByAppendingPathComponent:SVBAliveFileName];
            [line writeToFile:alive atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {}
}

- (NSString *)readHeartbeat {
    NSMutableString *r = [NSMutableString string];
    for (NSString *root in SVBRootCandidates()) {
        NSString *p = [root stringByAppendingPathComponent:SVBAliveFileName];
        NSString *c = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (c.length) [r appendFormat:@"%@\n  %@", p, c];
    }
    return r;
}

- (NSString *)readTweakLog {
    NSMutableString *r = [NSMutableString string];
    for (NSString *root in SVBRootCandidates()) {
        NSString *p = [root stringByAppendingPathComponent:SVBLogFileName];
        NSString *c = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!c.length) continue;
        if (c.length > 2500) c = [c substringFromIndex:c.length - 2500];
        [r appendFormat:@"### %@ (%@)\n%@\n", [root lastPathComponent], SVBRootLabel(root), c];
    }
    return r;
}

// 各根素材计数摘要 (横幅 / 诊断共用)
- (NSString *)rootsSummaryForContext:(NSString *)ctx {
    NSMutableString *s = [NSMutableString string];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger idx = 0;
    for (NSString *root in SVBRootCandidates()) {
        idx++;
        BOOL ex = [fm fileExistsAtPath:root];
        NSArray *items = ex ? [fm contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:ctx ?: SVBContextAll]
                                                      error:nil] : nil;
        NSUInteger n = 0;
        for (NSString *f in items) if (![f hasPrefix:@"."] && ![f hasPrefix:@"_"]) n++;
        [s appendFormat:@"根%ld %@ 在=%@ 可读=%@ 素材=%lu\n", (long)idx,
            SVBRootLabel(root), ex ? @"是" : @"否",
            [fm isReadableFileAtPath:root] ? @"是" : @"否", (unsigned long)n];
    }
    return s;
}

- (BOOL)debugBannerEnabled {
    id v = [self configValueForKey:@"debug_banner"];
    return v ? [v boolValue] : YES; // 默认显示, 方便确认注入是否成功
}

// 注入横幅文案: 一眼看清「插件有没有进信息App」+「素材到底读没读到」
- (NSString *)bannerTextForContext:(NSString *)ctx {
    // v10.0.0: 未授权时横幅只报授权状态 —— 用户得知道视频背景为什么不生效
    NSString *licDetail = nil;
    SVBAuthState lic = SVBAuthCurrentState(&licDetail);
    if (lic != SVBAuthStateAuthorized) {
        NSString *udid = SVBAuthUDID() ?: @"(读不到)";
        NSString *appName = [self appDisplayName];
        if (!appName.length) appName = @"信息视频背景";
        // v10.3.0: 只有离线授权一条路 -> 提示客户把 UDID 发给作者换授权串
        NSString *how = @"把上面这串 UDID 发给作者；作者会回一段授权串，在控制 App 点「粘贴离线授权」导入即可（不用联网、不需要梯子）";
        return [NSString stringWithFormat:
            @"⚠️ %@ v%@ 未生效\n授权状态：%@\n本机 UDID %@\n%@\n（点本横幅可隐藏）",
            appName, SVB_VERSION, SVBAuthStateText(lic, licDetail), udid, how];
    }

    NSString *bid = SVBHostBundleIdentifier();
    NSString *host = [bid isEqualToString:SVB_SMS_BUNDLE_ID] ? @"信息App"
                   : ([bid isEqualToString:SVB_APP_BUNDLE_ID] ? @"控制App"
                   : ([bid isEqualToString:@"com.apple.mobilenotes"] ? @"备忘录(注入探针)"
                   : (bid.length ? bid : @"未知进程")));
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"SMSVideoBG v%@ · 已注入【%@】pid %d\n", SVB_VERSION, host, (int)getpid()];
    [s appendString:[self rootsSummaryForContext:ctx ?: SVBContextAll]];
    BOOL on = [self masterEnabled] && [self isEnabledForContext:ctx ?: SVBContextAll];
    BOOL has = [self activeVideoPathForContext:ctx ?: SVBContextAll].length > 0;
    [s appendFormat:@"界面[%@] 开关=%@ 素材=%@ 生效=%@\n",
        ctx ?: SVBContextAll, on ? @"开" : @"关", has ? @"有" : @"无",
        (on && has) ? @"是✓" : @"否✗"];
    [s appendString:@"（点本横幅可隐藏；控制App 里可关闭）"];
    return s;
}

// 注入自检: dylib / filter plist 实际落点 (定位「插件没进信息App」类问题)
- (NSString *)injectionReport {
    NSMutableString *r = [NSMutableString string];
    NSFileManager *fm = [NSFileManager defaultManager];
    @try {
        char buf[PATH_MAX];
        NSString *real = nil;
        if (realpath("/var/jb", buf)) real = [NSString stringWithUTF8String:buf];
        [r appendFormat:@"/var/jb -> %@\n", real ?: @"(不存在/无法解析)"];

        NSMutableArray *dirs = [NSMutableArray array];
        [dirs addObject:@"/var/jb/Library/MobileSubstrate/DynamicLibraries"];
        NSArray *mobileList = [fm contentsOfDirectoryAtPath:@"/var/mobile" error:nil];
        for (NSString *e in mobileList) {
            if ([e hasPrefix:@".jbroot"] || [e hasPrefix:@".roothide"])
                [dirs addObject:[[@"/var/mobile" stringByAppendingPathComponent:e]
                                 stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries"]];
        }
        for (NSString *d in dirs) {
            BOOL ok = [fm fileExistsAtPath:d];
            [r appendFormat:@"%@\n  exists=%d\n", d, (int)ok];
            if (!ok) continue;
            NSArray *files = [fm contentsOfDirectoryAtPath:d error:nil];
            for (NSString *f in [files sortedArrayUsingSelector:@selector(compare:)]) {
                if (![f hasPrefix:@"SMSVideoBG"]) continue;
                NSDictionary *at = [fm attributesOfItemAtPath:[d stringByAppendingPathComponent:f] error:nil];
                [r appendFormat:@"   %@ (%@ 字节)\n", f, at[NSFileSize] ?: @"?"];
            }
            NSString *fp = [d stringByAppendingPathComponent:@"SMSVideoBG.plist"];
            NSString *c = [NSString stringWithContentsOfFile:fp encoding:NSUTF8StringEncoding error:nil];
            if (c.length)
                [r appendFormat:@"   filter: %@\n",
                    [c stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        }
        BOOL ek = [fm fileExistsAtPath:@"/var/jb/usr/lib/libellekit.dylib"] ||
                  [fm fileExistsAtPath:@"/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"] ||
                  [fm fileExistsAtPath:@"/var/jb/usr/lib/libsubstrate.dylib"];
        [r appendFormat:@"hook 库(ellekit/substrate)=%d\n", (int)ek];

        // v1.3: 信息App 数据容器定位 + 跨容器写入探针
        [r appendString:@"\n--- 信息App 数据容器 (v1.3 主素材根) ---\n"];
        NSString *c = SVBFindAppDataContainer(SVB_SMS_BUNDLE_ID);
        if (!c.length) {
            [r appendString:@"未定位到 com.apple.MobileSMS 数据容器 ❌\n"];
            [r appendString:@"  -> 控制App 无法把素材直送信息App 容器, 只能靠共享根。\n"];
        } else {
            [r appendFormat:@"container: %@\n", c];
            NSString *dir = [[c stringByAppendingPathComponent:@"Library"]
                             stringByAppendingPathComponent:SVB_MEDIA_DIR_NAME];
            [r appendFormat:@"素材根: %@\n  exists=%d writable=%d\n", dir,
                (int)[fm fileExistsAtPath:dir], (int)SVBDirWritable(dir)];
            NSString *probe = [dir stringByAppendingPathComponent:SVBProbeFileName];
            BOOL ok = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [r appendFormat:@"  跨容器写入探针: %@\n", ok ? @"成功 ✓ (素材可直送信息App)" : @"失败 ✗ (权限不足)"];
        }
    } @catch (NSException *e) {
        [r appendFormat:@"注入自检异常: %@\n", e.reason];
    }
    return r;
}

#pragma mark - 素材目录 (多根聚合 / 多根齐写)

- (NSArray<NSString *> *)mediaRoots {
    NSMutableArray *out_ = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in SVBRootCandidates()) {
        if ([fm fileExistsAtPath:dir] && [fm isReadableFileAtPath:dir]) [out_ addObject:dir];
    }
    if (!out_.count) [out_ addObject:[self mediaDirectory]];
    return out_;
}

// 实际可写的根 (导入时全部写入 -> 无论插件能读哪个根都能生效)
- (NSArray<NSString *> *)writableRoots {
    NSMutableArray *out_ = [NSMutableArray array];
    for (NSString *dir in SVBRootCandidates()) {
        if (SVBDirWritable(dir)) [out_ addObject:dir];
    }
    return out_;
}

- (NSString *)mediaDirectory {
    static NSString *resolved = nil;
    if (resolved && SVBDirWritable(resolved)) return resolved;
    resolved = nil;
    for (NSString *dir in SVBRootCandidates()) {
        if (SVBDirWritable(dir)) { resolved = [dir copy]; break; }
    }
    if (!resolved) resolved = SVBRootCandidates().lastObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:resolved
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return resolved;
}

- (NSString *)contextDirectory:(NSString *)ctx {
    // v10.4.0: 不再按界面分子目录 —— 所有界面共用素材根这一个文件夹。
    // ctx 参数保留为兼容旧调用点。旧版子目录会在启动时摊平 (SVBCleanupHousekeeping)。
    NSString *dir = [self mediaDirectory];
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    } @catch (NSException *e) {}
    return dir;
}

// 某界面的所有候选目录: 素材根本体 + (兼容) 旧版按界面分的子目录 ——
// 子目录只读, 摊平完成后即不再存在; 不在这里创建任何子目录。
- (NSArray<NSString *> *)directoriesForContext:(NSString *)ctx includeRootFallback:(BOOL)fallback {
    NSMutableArray *out_ = [NSMutableArray array];
    for (NSString *root in [self mediaRoots]) {
        [out_ addObject:root];
        NSString *sub = [root stringByAppendingPathComponent:ctx];
        if ([[NSFileManager defaultManager] fileExistsAtPath:sub]) [out_ addObject:sub];
    }
    return out_;
}

- (BOOL)isMovieFile:(NSString *)name {
    if (!name || [name hasPrefix:@"."]) return NO;
    static NSArray *exts = nil;
    if (!exts) exts = @[@"mp4", @"mov", @"m4v", @"3gp", @"mkv", @"webm"];
    return [exts containsObject:name.pathExtension.lowercaseString];
}

- (NSArray<NSString *> *)listFilesInDir:(NSString *)dir {
    NSMutableArray *out_ = [NSMutableArray array];
    @try {
        NSError *err = nil;
        NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:&err];
        if (err && err.code != NSFileReadNoSuchFileError)
            [self log:@"列目录失败 %@: %@", dir, err.localizedDescription];
        for (NSString *f in all) {
            if ([f hasPrefix:@"."] || [f hasPrefix:@"_"]) continue; // 跳过隐藏/内部文件
            NSDictionary *attrs = [[NSFileManager defaultManager]
                attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
            // 仅在确认是目录时排除; 属性查不到的文件也显示 (宁多勿漏)
            if (attrs && ![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
            [out_ addObject:f];
        }
    } @catch (NSException *e) {}
    [out_ sortUsingSelector:@selector(compare:)];
    return out_;
}

// 列出某界面素材: 聚合所有根的专属文件夹; 全空时回退到各根目录根部的文件
- (NSArray<NSString *> *)videosForContext:(NSString *)ctx {
    @try {
        // v10.4.0: 单一文件夹 —— 直接扫素材根 (旧版子目录若还没摊平也一并算数)
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *root in [self mediaRoots]) {
            [names addObjectsFromArray:[self listFilesInDir:root]];
            NSString *sub = [root stringByAppendingPathComponent:ctx];
            if ([[NSFileManager defaultManager] fileExistsAtPath:sub])
                [names addObjectsFromArray:[self listFilesInDir:sub]];
        }

        NSMutableArray *uniq = [NSMutableArray array];
        for (NSString *n in names)
            if (![uniq containsObject:n]) [uniq addObject:n];
        [uniq sortUsingSelector:@selector(compare:)];
        return uniq;
    } @catch (NSException *e) {
        return @[];
    }
}

// 素材自愈迁移: 把其它可读根里的素材搬进主根 (信息App 容器)。
// 背景: 历史导入可能落在 jbroot / Documents / 家目录等共享根,
// 而 tweak 所在的沙盒宿主进程可能读不到这些根 (横幅实测「共享文档 可读=否」)。
// 主根 (容器根) 是唯一 100% 可达的位置 -> 启动时把其它根的素材复制进来即可。
- (void)migrateMediaIntoPrimaryRoot {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *primary = [self mediaDirectory];
        if (!primary.length) return;

        // 迁移源: 辅根 (jbroot) + 旧版遗留根 (/var/mobile/Documents 等)
        NSMutableArray<NSString *> *srcRoots = [NSMutableArray array];
        NSArray<NSString *> *cands = SVBRootCandidates();
        for (NSUInteger i = 1; i < cands.count; i++) [srcRoots addObject:cands[i]];
        for (NSString *legacy in SVBLegacyRoots())
            if (![srcRoots containsObject:legacy]) [srcRoots addObject:legacy];

        NSInteger copied = 0;
        for (NSString *root in srcRoots) {
            if ([root isEqualToString:primary]) continue;
            // v10.4.0: 全部进主根「根部」—— 不再保留按界面的子目录结构
            for (NSArray<NSString *> *def in SVBContextDefinitions()) {
                NSString *srcDir = [root stringByAppendingPathComponent:def[0]];
                if (![fm fileExistsAtPath:srcDir]) continue;
                for (NSString *f in [self listFilesInDir:srcDir]) {
                    if (![self isMovieFile:f]) continue;
                    NSString *dst = [primary stringByAppendingPathComponent:f];
                    if ([fm fileExistsAtPath:dst]) continue;
                    NSError *err = nil;
                    if ([fm copyItemAtPath:[srcDir stringByAppendingPathComponent:f]
                                    toPath:dst error:&err]) {
                        copied++;
                        [self log:@"迁移素材 -> 主根: %@", dst];
                    } else if (err) {
                        [self log:@"迁移失败 %@: %@", f, err.localizedDescription];
                    }
                }
            }
            // 旧根根目录里散落的视频也搬
            for (NSString *f in [self listFilesInDir:root]) {
                if (![self isMovieFile:f]) continue;
                NSString *dst = [primary stringByAppendingPathComponent:f];
                if ([fm fileExistsAtPath:dst]) continue;
                if ([fm copyItemAtPath:[root stringByAppendingPathComponent:f] toPath:dst error:nil]) {
                    copied++;
                    [self log:@"迁移素材 -> 主根: %@", dst];
                }
            }
        }
        if (copied) {
            [self log:@"素材自愈迁移完成: %ld 个文件进入主根 %@", (long)copied, primary];
            [self postChangeNotification];
        }

        // v10.4.0: 顺带清掉「指向已不存在文件」的选中素材配置 ——
        // 素材删光后 App 不应再显示旧素材名/继续铺背景
        for (NSArray<NSString *> *def in SVBContextDefinitions()) {
            NSString *key = [def[0] stringByAppendingString:@"_video"];
            NSString *sel = [self configValueForKey:key];
            if (sel.length && ![self videosForContext:def[0]].count)
                [self setConfigValue:nil forKey:key];
        }
    } @catch (NSException *e) {
        [self log:@"迁移异常: %@ / %@", e.name, e.reason];
    }
}

- (NSString *)activeVideoNameForContext:(NSString *)ctx {
    NSString *sel = [self configValueForKey:[ctx stringByAppendingString:@"_video"]];
    if ([sel isKindOfClass:[NSString class]] && sel.length &&
        [[self videosForContext:ctx] containsObject:sel]) return sel;
    return [self videosForContext:ctx].firstObject; // 默认取排序第一个
}

- (NSString *)activeVideoPathForContext:(NSString *)ctx {
    NSString *name = [self activeVideoNameForContext:ctx];
    if (!name.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [self directoriesForContext:ctx includeRootFallback:YES]) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

- (void)setActiveVideoName:(NSString *)name forContext:(NSString *)ctx {
    [self setConfigValue:(name.length ? name : nil)
                  forKey:[ctx stringByAppendingString:@"_video"]];
    [self postChangeNotification];
}

// 把文件复制到指定目录 (失败返回错误)
static BOOL SVBCopyInto(NSString *srcPath, NSString *dir, NSString *name, NSError **err) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) return NO;
    NSString *dest = [dir stringByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) return YES;
    return [fm copyItemAtPath:srcPath toPath:dest error:err];
}

- (NSString *)importVideoFromFile:(NSURL *)srcURL toContext:(NSString *)ctx error:(NSError **)error {
    @try {
        SVBRefreshMediaRoots();   // 每次导入前重新定位信息App 容器
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *srcPath = srcURL.path;

        // 0. 源文件体检 —— 失败必须给出人话原因, 不能静默返回 nil
        if (!srcPath.length || ![fm fileExistsAtPath:srcPath]) {
            [self log:@"导入失败: 源文件不存在 %@", srcPath];
            if (error) *error = [NSError errorWithDomain:@"SVB" code:-3
                userInfo:@{NSLocalizedDescriptionKey: @"源文件不存在（可能已被系统清理，请重试）"}];
            return nil;
        }
        NSDictionary *srcAttr = [fm attributesOfItemAtPath:srcPath error:nil];
        unsigned long long srcSize = srcAttr ? [srcAttr[NSFileSize] unsignedLongLongValue] : 0;
        if (srcSize == 0) {
            [self log:@"导入失败: 源文件为空 %@", srcPath];
            if (error) *error = [NSError errorWithDomain:@"SVB" code:-4
                userInfo:@{NSLocalizedDescriptionKey: @"源视频为空（0 字节），无法导入"}];
            return nil;
        }

        NSString *ext = srcURL.pathExtension.length ? srcURL.pathExtension.lowercaseString : @"mp4";
        if (![self isMovieFile:[@"a." stringByAppendingString:ext]]) ext = @"mp4";
        [self log:@"导入开始: %@ (%.1f MB) -> %@", srcPath, (double)srcSize / 1048576.0, ctx];

        // 1. 目标根 = 全部可写根 (多根齐写: 信息App 容器 + 共享根)
        NSMutableArray<NSString *> *targets = [NSMutableArray array];
        NSMutableArray<NSString *> *failedRoots = [NSMutableArray array];
        for (NSString *root in SVBRootCandidates()) {
            if (!SVBDirWritable(root)) { [failedRoots addObject:root]; continue; }
            NSString *dir = [root stringByAppendingPathComponent:ctx];
            if (SVBDirWritable(dir)) [targets addObject:dir];
            else [failedRoots addObject:dir];
        }
        [self log:@"导入目标根 %lu 个, 不可写 %lu 个", (unsigned long)targets.count,
              (unsigned long)failedRoots.count];
        for (NSString *f in failedRoots) [self log:@"  不可写: %@", f];

        if (!targets.count) {
            if (error) *error = [NSError errorWithDomain:@"SVB" code:-1
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                          @"没有任何可写素材目录（请在诊断报告中查看）"}];
            return nil;
        }

        // 2. 文件名 = 原名(去扩展); 在所有目标根里都不冲突 (跨根统一, 避免同名覆盖)
        NSString *base = srcPath.lastPathComponent.stringByDeletingPathExtension;
        if (!base.length) base = [NSString stringWithFormat:@"素材%.0f", [[NSDate date] timeIntervalSince1970]];
        if ([base hasPrefix:@"."] || [base hasPrefix:@"_"]) base = [@"素材" stringByAppendingString:base];
        NSString *name = [base stringByAppendingPathExtension:ext];
        NSInteger i = 2;
        BOOL clash = YES;
        while (clash) {
            clash = NO;
            for (NSString *dir in targets)
                if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:name]]) { clash = YES; break; }
            if (clash) {
                name = [[NSString stringWithFormat:@"%@ (%ld)", base, (long)i]
                        stringByAppendingPathExtension:ext];
                i++;
            }
        }

        // 3. 逐根复制 (任一成功即算导入成功; 失败逐条记日志)
        NSString *primary = targets.firstObject;
        NSUInteger okCount = 0;
        for (NSString *dir in targets) {
            NSError *cErr = nil;
            if (SVBCopyInto(srcPath, dir, name, &cErr)) {
                okCount++;
                [self log:@"导入成功: %@ -> %@/%@", srcURL.path, SVBRootLabel(dir), name];
            } else {
                [self log:@"导入失败: %@ (%@)", dir, cErr.localizedDescription ?: @"复制失败"];
            }
        }

        if (okCount == 0) {
            if (error) *error = [NSError errorWithDomain:@"SVB" code:-1
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                          @"所有素材目录都复制失败（请在诊断报告中查看）"}];
            return nil;
        }

        // 4. 校验主根确实落地且大小一致 (半截文件会让播放器黑屏)
        NSString *primaryPath = [primary stringByAppendingPathComponent:name];
        NSDictionary *dstAttr = [fm attributesOfItemAtPath:primaryPath error:nil];
        unsigned long long dstSize = dstAttr ? [dstAttr[NSFileSize] unsignedLongLongValue] : 0;
        if (dstSize != srcSize) {
            [self log:@"导入告警: 主根文件大小不一致 (%llu != %llu) %@", dstSize, srcSize, primaryPath];
        } else {
            [self log:@"导入校验通过: %@ (%.1f MB)", name, (double)dstSize / 1048576.0];
        }

        if (![self activeVideoNameForContext:ctx]) [self setActiveVideoName:name forContext:ctx];
        [self postChangeNotification];
        return name;
    } @catch (NSException *e) {
        [self log:@"导入异常: %@ / %@", e.name, e.reason];
        if (error) *error = [NSError errorWithDomain:@"SVB" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                       [NSString stringWithFormat:@"导入异常: %@", e.reason]}];
        return nil;
    }
}

- (void)deleteVideoName:(NSString *)name forContext:(NSString *)ctx {
    NSFileManager *fm = [NSFileManager defaultManager];
    // v10.4.0: 旧版遗留根 (jbroot/Documents/家目录) 里的同名副本也要一并删 ——
    // 否则每次启动的自愈迁移会把旧根副本再复制回主根, 表现为「删了马上又出来」
    NSMutableArray *dirs = [[self directoriesForContext:ctx includeRootFallback:YES] mutableCopy];
    for (NSString *root in SVBLegacyRoots()) {
        [dirs addObject:root];
        NSString *sub = [root stringByAppendingPathComponent:ctx];
        if ([fm fileExistsAtPath:sub]) [dirs addObject:sub];
    }
    for (NSString *dir in dirs) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) [fm removeItemAtPath:p error:nil];
    }
    if ([[self configValueForKey:[ctx stringByAppendingString:@"_video"]] isEqualToString:name]) {
        [self setActiveVideoName:nil forContext:ctx];
    }
    [self postChangeNotification];
}

// v1.8.3: 重命名素材 —— 所有根目录副本一并改名 (导入是多根同步的), 返回最终名字
// (输入已消毒/去重)。改名的是使用中素材时同步更新配置。
- (NSString *)renameVideoName:(NSString *)name to:(NSString *)newName forContext:(NSString *)ctx {
    // 消毒: 去首尾空白, 剔除路径分隔符与控制字符, 不允许为空
    newName = [newName stringByTrimmingCharactersInSet:
               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"] mutableCopy];
    [bad formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]];
    newName = [[newName componentsSeparatedByCharactersInSet:bad]
               componentsJoinedByString:@"_"];
    if (!newName.length) return nil;

    // 保留原扩展名 (视频文件识别依赖扩展名)
    NSString *oldExt = name.pathExtension;
    if (oldExt.length && ![newName.pathExtension.lowercaseString isEqualToString:oldExt.lowercaseString])
        newName = [newName stringByAppendingPathExtension:oldExt];

    // 与现存素材重名 -> 自动加序号
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *finalName = newName;
    NSArray<NSString *> *dirs = [self directoriesForContext:ctx includeRootFallback:YES];
    __block BOOL exists = NO;
    for (int i = 2; i < 100; i++) {
        exists = NO;
        for (NSString *dir in dirs) {
            if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:finalName]]) { exists = YES; break; }
        }
        if (!exists) break;
        NSString *base = newName.stringByDeletingPathExtension;
        finalName = [NSString stringWithFormat:@"%@ (%d).%@", base, i, newName.pathExtension];
    }
    if (exists) return nil; // 尝试 100 次仍重名, 放弃

    // 逐个根目录改名
    BOOL renamed = NO;
    for (NSString *dir in dirs) {
        NSString *src = [dir stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:src]) {
            NSError *err = nil;
            if ([fm moveItemAtPath:src
                            toPath:[dir stringByAppendingPathComponent:finalName]
                             error:&err]) {
                renamed = YES;
            } else {
                [self log:@"重命名失败 %@ -> %@: %@", name, finalName, err.localizedDescription];
            }
        }
    }
    if (!renamed) return nil;

    // 使用中素材改名 -> 配置同步
    if ([[self configValueForKey:[ctx stringByAppendingString:@"_video"]] isEqualToString:name])
        [self setActiveVideoName:finalName forContext:ctx];
    [self postChangeNotification];
    return finalName;
}

#pragma mark - 播放器 (每界面一个, 播完回开头循环)

- (AVPlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force {
    @try {
        NSString *path = [self activeVideoPathForContext:ctx];
        if (!path) return nil;

        AVPlayer *p = self.players[ctx];
        if (p && !force && [self.playerPaths[ctx] isEqualToString:path]) return p;

        // 清理旧播放器 (looper 必须先 disable, 否则它会继续往队列塞副本)
        AVPlayerLooper *oldLooper = self.loopers[ctx];
        if (oldLooper) { [oldLooper disableLooping]; [self.loopers removeObjectForKey:ctx]; }
        AVPlayer *old = self.players[ctx];
        [old pause];
        [self.players removeObjectForKey:ctx];
        [self.items removeObjectForKey:ctx];

        // v1.4: AVQueuePlayer + AVPlayerLooper 无缝循环 (播完不再黑屏)
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
        AVQueuePlayer *qp = [[AVQueuePlayer alloc] init];
        AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:qp templateItem:item];
        p = qp;
        self.players[ctx]     = p;
        self.items[ctx]       = item;
        self.loopers[ctx]     = looper;
        self.playerPaths[ctx] = path;
        p.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        CGFloat vol = [self volumeForContext:ctx]; // v1.6: 按界面音量
        p.volume = vol;
        p.muted  = (vol <= 0.001); // 音量默认关闭
        // v1.7.3: 不抢占音频会话 —— AVPlayer 默认 soloAmbient(独占), 一播就把
        // 音乐/小说 App 掐断 (静音也一样, 因为占的是会话不是音量)。
        // 换成 ambient 混音模式: 与其它 App 音频共存, 互不打断。
        @try {
            [[AVAudioSession sharedInstance]
                setCategory:AVAudioSessionCategoryAmbient withOptions:0 error:nil];
        } @catch (NSException *e) {}
        [p play];
        return p;
    } @catch (NSException *e) {
        return nil;
    }
}

#pragma mark - 背景应用

// 收集视图树里的 UIToolbar (垃圾信息「全部已读/全部删除」、最近删除「全部删除/全部恢复」等底部操作栏)
static void SVBCollectToolbars(UIView *view, NSMutableArray<UIToolbar *> *out_, NSInteger depth) {
    if (depth > 8) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIToolbar class]]) [out_ addObject:(UIToolbar *)sub];
        SVBCollectToolbars(sub, out_, depth + 1);
    }
}

// v1.7.19: 读回某 VC 实际挂载过的语境 (apply 时写入); 没挂过返回 nil
- (NSString *)appliedContextForViewController:(UIViewController *)vc {
    @try {
        return objc_getAssociatedObject(vc, &SVBAppliedCtxKey);
    } @catch (NSException *e) { return nil; }
}

- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx {
    @try {
        if (!vc.isViewLoaded || !vc.view) return;

        // v1.7.19: 记录该 VC 实际请求挂载的语境 (无论开关与否), 离开时按它精确暂停
        objc_setAssociatedObject(vc, &SVBAppliedCtxKey, ctx, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // v1.9.0: 授权门禁 —— 所有挂背景的路径都汇聚到这里, 未激活/过期一律不挂
        // (这样无论从哪个钩子进来都拦得住, 不需要在 Tweak.x 各处补判断)
        BOOL on = SVBIsLicensed() && [self masterEnabled] && [self isEnabledForContext:ctx] &&
                  [self activeVideoPathForContext:ctx].length > 0;

        SVBVideoBackgroundView *bg = objc_getAssociatedObject(vc, &SVBBGKey);
        if (!on) {
            [self detachBackground:bg fromViewController:vc];
            if (bg) objc_setAssociatedObject(vc, &SVBBGKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        if (!bg || ![bg.contextKey isEqualToString:ctx]) {
            [self detachBackground:bg fromViewController:vc];
            bg = [[SVBVideoBackgroundView alloc] initWithFrame:vc.view.bounds contextKey:ctx];
            objc_setAssociatedObject(vc, &SVBBGKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [self attachBackground:bg toViewController:vc];
        [bg configure];

        vc.view.backgroundColor = [UIColor clearColor];
        [self clearBackgroundsOfView:vc.view depth:0];

        // 导航栏滚动时会从透明(scrollEdge)切到不透明(standard)外观 -> 顶部白条。
        // 背景生效期间两种外观都设为透明, 并保持住 (写在 apply 里, 每次出现都刷新)。
        UINavigationController *nav = vc.navigationController;
        if (nav.navigationBar &&
            [nav.navigationBar respondsToSelector:@selector(setStandardAppearance:)]) {
            UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
            [ap configureWithTransparentBackground];
            nav.navigationBar.standardAppearance  = ap;
            nav.navigationBar.scrollEdgeAppearance = ap;
        }

        // v1.7.1 底部工具栏 (垃圾信息「全部已读/全部删除」、最近删除「全部删除/全部恢复」)
        // 是系统材质白底, 不透明会挡住背景 —— 与导航栏同理, 各种外观全部设透明。
        // 注意 scrollEdgeAppearance 是 iOS15 API, 14.5 SDK 无声明, 必须运行时调用。
        @try {
            NSMutableArray<UIToolbar *> *bars = [NSMutableArray array];
            SVBCollectToolbars(vc.view, bars, 0);
            for (UIToolbar *tb in bars) {
                UIToolbarAppearance *tap = [[UIToolbarAppearance alloc] init];
                [tap configureWithTransparentBackground];
                if ([tb respondsToSelector:@selector(setStandardAppearance:)])
                    tb.standardAppearance = tap;
                SEL edgeSel = NSSelectorFromString(@"setScrollEdgeAppearance:");
                if ([tb respondsToSelector:edgeSel])
                    ((void (*)(id, SEL, id))objc_msgSend)(tb, edgeSel, tap);
                if ([tb respondsToSelector:@selector(setCompactAppearance:)])
                    tb.compactAppearance = tap;
                tb.backgroundColor = [UIColor clearColor];
            }
        } @catch (NSException *e) {}

        // v1.7.2: 深度透明化 (对话详情顶部头像区/输入条/底部栏模糊层)。
        // 输入条可能挂在窗口级容器 (docked inputAccessory), 所以 window 也扫一遍。
        @try {
            [self deepChromePass:vc.view depth:0 ctx:ctx];
            if ([ctx isEqualToString:SVBContextChat]) {
                [self swizzleBalloonDrawingIfNeeded]; // v1.7.7: 拦掉 drawRect 画的气泡底
                if (!SVBHierarchyDumped) {            // v1.7.8: 层级转储 (每进程一次)
                    SVBHierarchyDumped = YES;
                    [self dumpHierarchyForDiagnosis:vc.view];
                }
                [self bubblePass:vc.view depth:0 inCell:NO ctx:ctx sysBg:NO];
            }
            for (UIWindow *w in UIApplication.sharedApplication.windows) {
                if (w == vc.view.window) continue;
                [self deepChromePass:w depth:0 ctx:ctx];
            }
        } @catch (NSException *e) {}

        // 记录一次活动 (供诊断页判断 hook 是否真的触发)
        [self writeHeartbeat:[NSString stringWithFormat:@"apply ctx=%@ cls=%@",
                              ctx, NSStringFromClass([vc class])]];
    } @catch (NSException *e) {
        // 任何异常都不允许导致信息 App 崩溃
    }
}

// 页面离开时摘除背景 (防止列表页跳转后残留 / 串扰)
// v1.5.2: pop/转场期间绝不触碰 UICollectionView 的 backgroundView ——
// 运行时置空/移除私有子类在转场中持有的视图, 与「过滤条件」闪退时机完全吻合, 判定为主嫌。
// 转场中保留挂载无害: 同一 VC 换 ctx 时 apply 会整体替换; VC pop 时随视图树一起释放。
- (void)detachFromViewController:(UIViewController *)vc {
    @try {
        SVBVideoBackgroundView *bg = objc_getAssociatedObject(vc, &SVBBGKey);
        if (!bg) return;
        UIView *host = vc.view;
        if (![host isKindOfClass:[UICollectionView class]]) {
            [self detachBackground:bg fromViewController:vc];
        }
        objc_setAssociatedObject(vc, &SVBBGKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {}
}

// 挂载: UITableView 用 backgroundView; UICollectionView(iOS16 信息列表) 用运行时
//       调用 setBackgroundView:(14.5 SDK 头文件没有该属性); 其余插到最底层。
- (void)attachBackground:(SVBVideoBackgroundView *)bg toViewController:(UIViewController *)vc {
    UIView *host = vc.view;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    if ([host isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)host;
        if (tv.backgroundView != bg) tv.backgroundView = bg;
        return;
    }

    SEL getBG = NSSelectorFromString(@"backgroundView");
    SEL setBG = NSSelectorFromString(@"setBackgroundView:");
    if ([host isKindOfClass:[UICollectionView class]] && [host respondsToSelector:setBG]) {
        id cur = [host respondsToSelector:getBG]
               ? ((id (*)(id, SEL))objc_msgSend)(host, getBG) : nil;
        if (cur != bg) ((void (*)(id, SEL, id))objc_msgSend)(host, setBG, bg);
        return;
    }

    if (bg.superview != host) {
        [bg removeFromSuperview];
        [host insertSubview:bg atIndex:0];
    }
}

- (void)detachBackground:(SVBVideoBackgroundView *)bg fromViewController:(UIViewController *)vc {
    if (!bg) return;
    UIView *host = vc.view;
    if ([host isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)host;
        if (tv.backgroundView == bg) tv.backgroundView = nil;
    } else {
        SEL getBG = NSSelectorFromString(@"backgroundView");
        SEL setBG = NSSelectorFromString(@"setBackgroundView:");
        if ([host respondsToSelector:setBG] && [host respondsToSelector:getBG]) {
            id cur = ((id (*)(id, SEL))objc_msgSend)(host, getBG);
            if (cur == bg) ((void (*)(id, SEL, id))objc_msgSend)(host, setBG, (id)nil);
        }
    }
    [bg removeFromSuperview];
}

// 把挡住视频的底色全部抹透明 (iOS16 信息用 collection view + 不透明 cell,
// 不抹掉的话视频层被整片盖住 -> 看起来「没生效」)
- (void)clearBackgroundsOfView:(UIView *)view depth:(NSInteger)depth {
    if (depth > 6) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]] || [sub isKindOfClass:[UIButton class]]) continue;
        BOOL clearable = [sub isKindOfClass:[UIScrollView class]] ||
                         [sub isKindOfClass:[UITextView class]]  ||
                         [sub isKindOfClass:[UITableViewCell class]] ||
                         [sub isKindOfClass:[UICollectionViewCell class]] ||
                         [sub isKindOfClass:[UICollectionReusableView class]] || // 列表头/脚 (大标题+搜索)
                         [sub isKindOfClass:[UISearchBar class]];
        if (clearable) {
            sub.backgroundColor = [UIColor clearColor];
            if ([sub respondsToSelector:@selector(contentView)]) {
                UIView *cv = ((UIView *(*)(id, SEL))objc_msgSend)(sub, @selector(contentView));
                cv.backgroundColor = [UIColor clearColor];
            }
        }
        [self clearBackgroundsOfView:sub depth:depth + 1];
    }
    if ([view isKindOfClass:[UIScrollView class]] || [view isKindOfClass:[UITextView class]]) {
        view.backgroundColor = [UIColor clearColor];
    }
}

// v1.7.2: 深度透明化「系统 chrome」层。
// 底部操作栏的白雾是 UIVisualEffectView 材质模糊 (改外观拆不掉, 必须拆模糊层本身);
// 对话详情顶部头像区/底部输入条是私有容器视图, 且输入条可能挂在窗口级容器
// (docked inputAccessory) 而非 vc.view 内 —— 所以本方法也会对全部 window 扫。
- (void)deepChromePass:(UIView *)view depth:(NSInteger)depth ctx:(NSString *)ctx {
    if (depth > 14) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[SVBVideoBackgroundView class]]) continue;
        NSString *cls = NSStringFromClass([sub class]);
        NSString *low = cls.lowercaseString;
        // 键盘整棵子树跳过 (拆键盘模糊会毁掉键盘观感)
        if ([low containsString:@"keyboard"]) continue;
        if (depth <= 3) [self logClassOnce:cls context:ctx];
        // v1.7.14: 聊天页「原样」档 (ba>=0.999) = 看消息模式, 页面内部完全收手
        // (透明化只作用于透明/隐藏档), 杜绝一切对原样外观的干扰
        BOOL originMode = [ctx isEqualToString:SVBContextChat] &&
                          [self bubbleAlphaForContext:ctx] >= 0.999;
        // 材质模糊层: 底部栏/输入条的白雾就是它 -> 直接拆。
        // v1.7.13: 先缓存原始 effect; **聊天页「原样」档不拆** —— iOS16 的 backdrop 特效
        // 视图被拆成 nil 后会渲染成纯黑块 (用户截图实锤: 原样档气泡=黑块+隐约文字),
        // 原样=看消息模式, 材质恢复原样; 透明/隐藏档才拆。
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            UIVisualEffectView *ev = (UIVisualEffectView *)sub;
            id origEff = objc_getAssociatedObject(ev, &SVBOrigEffectKey);
            if (!origEff && ev.effect) {
                objc_setAssociatedObject(ev, &SVBOrigEffectKey, ev.effect,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                origEff = ev.effect;
            }
            BOOL restoreNow = [ctx isEqualToString:SVBContextChat] &&
                              [self bubbleAlphaForContext:ctx] >= 0.999;
            if (restoreNow) {
                if (origEff && !ev.effect) ev.effect = origEff;
            } else {
                ev.effect = nil;
            }
            continue;
        }
        if ([sub isKindOfClass:[UILabel class]] || [sub isKindOfClass:[UIButton class]]) {
            // 文字/按钮不动
        } else if (!originMode) {
            // chrome 容器关键词命中即清背景 (工具栏/输入条/头部/抽屉/导航等); 原样档不碰
            BOOL chrome = [low containsString:@"toolbar"] || [low containsString:@"input"] ||
                          [low containsString:@"header"] || [low containsString:@"navbar"] ||
                          [low containsString:@"navigationbar"] || [low containsString:@"drawer"] ||
                          [low containsString:@"bottombar"] || [low containsString:@"accessory"] ||
                          [low containsString:@"avatar"] || [low containsString:@"contact"] ||
                          [low containsString:@"statusbar"];
            if (chrome) {
                sub.backgroundColor = [UIColor clearColor];
                if ([sub respondsToSelector:@selector(contentView)]) {
                    UIView *cv = ((UIView *(*)(id, SEL))objc_msgSend)(sub, @selector(contentView));
                    cv.backgroundColor = [UIColor clearColor];
                }
            }
        }
        [self deepChromePass:sub depth:depth + 1 ctx:ctx];
    }
}

// v1.7.3: 短信气泡半透明 (仅对话详情)。
// 气泡类 (类名含 balloon/bubble) 按用户设置的不透明度整体调低;
// 其余普通容器清底色 (文字标签/头像图片/按钮保留), 让视频从气泡后面透出来。
// 气泡内类名会写进诊断日志, 万一某一版没识别到可以精准校准。
- (void)bubblePass:(UIView *)view depth:(NSInteger)depth inCell:(BOOL)inCell ctx:(NSString *)ctx sysBg:(BOOL)sysBg {
    if (depth > 12) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[SVBVideoBackgroundView class]]) continue;
        NSString *cls = NSStringFromClass([sub class]);
        NSString *low = cls.lowercaseString;
        BOOL cell = inCell || [sub isKindOfClass:[UICollectionViewCell class]] ||
                               [sub isKindOfClass:[UITableViewCell class]];
        // v1.7.14: 系统托管的 cell 背景视图 (backgroundView/selectedBackgroundView) 只藏不清 ——
        // 直接清它们的底色会干扰系统的 backgroundConfiguration 重应用流程, 已实锤导致
        // UICollectionView 崩溃 (SIGABRT in _applyBackgroundViewConfiguration)
        BOOL isSysBg = sysBg;
        UIView *pv = sub.superview;
        if ([pv isKindOfClass:[UICollectionViewCell class]]) {
            UICollectionViewCell *pc = (UICollectionViewCell *)pv;
            if ((pc.backgroundView && sub == pc.backgroundView) ||
                (pc.selectedBackgroundView && sub == pc.selectedBackgroundView)) isSysBg = YES;
        }
        if (cell && depth <= 5) [self logClassOnce:cls context:ctx];
        CGFloat ba = [self bubbleAlphaForContext:ctx];
        if (cell) {
            // v1.7.11: 隐藏档 cell 内**无差别全藏** —— 用户截图实锤黑块宿主类名不含任何
            // 关键词 (balloon/bubble/background...全不沾), 猜类名没有意义; 只要子树里没有
            // 视频背景视图就一律 alpha=0, 拉高滑条时全部恢复。
            if (ba <= 0.06 && !isSysBg && ![self subtreeContainsVideoBg:sub depth:0]) {
                [self hideViewTemporarily:sub];
            } else {
                [self restoreViewAlpha:sub]; // 拉高滑条: 恢复曾被隐藏的容器/标签
            }
            if ([low containsString:@"balloon"] || [low containsString:@"bubble"]) {
                [self applyBubbleAlpha:sub ctx:ctx];
            } else if (ba < 0.999 && !isSysBg &&
                       ![sub isKindOfClass:[UILabel class]] &&
                       ![sub isKindOfClass:[UIButton class]] &&
                       ![sub isKindOfClass:[UIImageView class]] &&
                       ![sub isKindOfClass:[UIVisualEffectView class]]) {
                // 普通容器: 底色清掉 (文字/头像/按钮不动)
                sub.backgroundColor = nil;
            }
            // v1.7.6: 文字可读性 —— 气泡底被拆掉后, 白字压亮视频会看不清, 加深色投影
            if ([self bubbleAlphaForContext:ctx] < 0.999) [self applyTextShadow:sub];
        }
        // v1.7.12: 隐藏档非 cell 层全藏, 豁免名单再缩——UIVisualEffectView (暗色材质)
        // 也拆 effect + 藏掉 (deepChromePass 已拆过 effect, 这里双保险)。
        if (ba <= 0.06 && !isSysBg &&
            ![sub isKindOfClass:[UIImageView class]] &&
            ![sub isKindOfClass:[UIButton class]] &&
            ![sub isKindOfClass:[UIControl class]] &&
            ![sub isKindOfClass:[UITextField class]] &&
            ![self subtreeContainsVideoBg:sub depth:0]) {
            if ([sub isKindOfClass:[UIVisualEffectView class]])
                ((UIVisualEffectView *)sub).effect = nil;
            [self hideViewTemporarily:sub];
        } else {
            [self restoreViewAlpha:sub];
        }
        // v1.7.6/14: 浅雾兜底 (ba<0.999 才动手, 原样档完全收手; 系统托管背景不清)
        if (ba < 0.999 && !isSysBg &&
            ![sub isKindOfClass:[UILabel class]] &&
            ![sub isKindOfClass:[UIButton class]] &&
            ![sub isKindOfClass:[UIImageView class]] &&
            ![sub isKindOfClass:[UIVisualEffectView class]] &&
            ![sub isKindOfClass:[UIControl class]] &&
            ![sub isKindOfClass:[UITextField class]]) {
            sub.backgroundColor = nil;
            if (sub.layer.backgroundColor) sub.layer.backgroundColor = NULL;
        }
        [self bubblePass:sub depth:depth + 1 inCell:cell ctx:ctx sysBg:isSysBg];
    }
    // v1.7.12: 隐藏档跑完后扫一遍「还没藏住」的视图写诊断日志 (有效 alpha 计算到根)
    if (depth == 0 && [self bubbleAlphaForContext:ctx] <= 0.06) {
        [self dumpVisibleResidue:view ctx:ctx];
    }
}

// v1.7.12: 残留元素报告 —— 隐藏档开启时, 把消息区里**还没被藏住**的视图 (有效 alpha>0.01
// 且未 hidden) 写进诊断日志; 用户再反馈黑块/白雾时可直接指认宿主类名。10s 节流。
- (void)dumpVisibleResidue:(UIView *)view ctx:(NSString *)ctx {
    static NSTimeInterval lastDump = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - lastDump < 10) return;
    lastDump = now;
    NSMutableString *out = [NSMutableString stringWithFormat:@"=== 隐藏档残留报告 (%@) ===\n", ctx];
    [self collectResidue:view depth:0 effAlpha:1.0 into:out];
    [out appendString:@"=== 残留报告结束 ===\n"];
    [self log:@"%@", out];
}

- (void)collectResidue:(UIView *)v depth:(NSInteger)depth effAlpha:(CGFloat)ea into:(NSMutableString *)out {
    if (depth > 12) return;
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[SVBVideoBackgroundView class]]) continue;
        NSString *low = NSStringFromClass([sub class]).lowercaseString;
        if ([low containsString:@"keyboard"]) continue;
        CGFloat e = ea * sub.alpha;
        if (e > 0.01 && !sub.hidden &&
            sub.frame.size.width > 2 && sub.frame.size.height > 2) {
            [out appendFormat:@"  RESIDUE d=%ld %@ f=%@ al=%.2f eff=%.2f\n",
             (long)depth, NSStringFromClass([sub class]),
             NSStringFromCGRect(sub.frame), sub.alpha, e];
        }
        [self collectResidue:sub depth:depth + 1 effAlpha:e into:out];
    }
}

// 气泡是否含文字子视图 (决定能不能安全地用 alpha 整体调淡)
- (BOOL)viewHasTextDescendant:(UIView *)view depth:(NSInteger)depth {
    if (depth > 6) return NO;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]] || [sub isKindOfClass:[UITextView class]] ||
            [sub isKindOfClass:[UITextField class]]) return YES;
        if ([self viewHasTextDescendant:sub depth:depth + 1]) return YES;
    }
    return NO;
}

// v1.7.4: 气泡半透明, 但**文字必须保持清晰**。
// 关键: 不能用 view.alpha —— alpha 会被子视图继承, 气泡里的文字会跟着一起消失
// (v1.7.3 的 bug 就是这个)。正确做法 = 只把气泡自己的底色换成「同色 + 目标透明度」,
// 文字层不透明度完全不动。
// 拿不到底色时 (图片/纯绘制型气泡) 才考虑 alpha 兜底, 且只在确认气泡内没有文字时用;
// 否则宁可让气泡整块透明 (视频透出来) 也绝不让文字看不见。
- (void)applyBubbleAlpha:(UIView *)balloon ctx:(NSString *)ctx {
    CGFloat ba = [self bubbleAlphaForContext:ctx];
    @try {
        // v1.7.9: 滑条最低档 = 气泡连文字**彻底隐藏** (用户方案)。
        // 整个视图 alpha=0 —— 文字、底色、底图、甚至拦不住的 drawRect 自绘内容全部一起
        // 消失 (alpha 作用于整棵子树的合成结果), 视频完整透出来; 想看消息拉高滑条即可。
        // v1.7.10: 阈值放宽到 0.06 (旧「仅文字」区并入隐藏档)。
        if (ba <= 0.06 && ![self subtreeContainsVideoBg:balloon depth:0]) {
            [self hideViewTemporarily:balloon];
            return;
        }
        [self restoreViewAlpha:balloon]; // 从隐藏档拉回来时恢复
        UIColor *orig = objc_getAssociatedObject(balloon, &SVBBubbleOrigColorKey);
        if (!orig) { // 第一次遇到: 记下原始底色
            UIColor *cur = balloon.backgroundColor;
            if (cur && CGColorGetAlpha(cur.CGColor) > 0.01) {
                objc_setAssociatedObject(balloon, &SVBBubbleOrigColorKey, cur,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                orig = cur;
            }
        }
        if (!orig && balloon.layer.backgroundColor) { // 底色画在 layer 上
            UIColor *lc = [UIColor colorWithCGColor:balloon.layer.backgroundColor];
            if (lc && CGColorGetAlpha(lc.CGColor) > 0.01) {
                objc_setAssociatedObject(balloon, &SVBBubbleOrigColorKey, lc,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                orig = lc;
            }
        }
        balloon.alpha = 1.0; // 永远恢复整体不透明 (文字清晰)
        if (orig) {
            balloon.layer.backgroundColor = NULL; // 统一由 view 底色控制
            balloon.backgroundColor = (ba < 0.999) ? [orig colorWithAlphaComponent:ba] : orig;
        } else {
            balloon.backgroundColor = [UIColor clearColor];
            balloon.layer.backgroundColor = NULL;
            if (ba < 0.999 && ![self viewHasTextDescendant:balloon depth:0]) balloon.alpha = ba;
        }
        // v1.7.5: 气泡底如果画在 layer.contents (可拉伸气泡图片) 上, 清底色是没用的——
        // 这就是「气泡还是实心白、白底上白字看不见」的来源。文字在子视图里, 清 contents 不影响文字。
        id origImg = objc_getAssociatedObject(balloon, &SVBBubbleOrigContentsKey);
        if (!origImg && balloon.layer.contents) {
            origImg = balloon.layer.contents;
            objc_setAssociatedObject(balloon, &SVBBubbleOrigContentsKey, origImg,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (ba < 0.999) {
            if (origImg) balloon.layer.contents = NULL; // 拆掉气泡底图
            [self clearDrawnBackgroundsOf:balloon depth:0 on:YES];
        } else if (origImg) {
            balloon.layer.contents = origImg;           // 拉回「原样」时恢复底图
            [self clearDrawnBackgroundsOf:balloon depth:0 on:NO];
        }
    } @catch (NSException *e) {}
}

// 视图树里有没有 UIImageView (有图片内容的气泡——如照片消息——不能拆底图, 会把照片也拆掉)
- (BOOL)viewHasImageDescendant:(UIView *)view depth:(NSInteger)depth {
    if (depth > 5) return NO;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIImageView class]]) return YES;
        if ([self viewHasImageDescendant:sub depth:depth + 1]) return YES;
    }
    return NO;
}

// v1.7.9: 彻底隐藏视图 —— 缓存原 alpha 后置 0 (连 drawRect 自绘内容一起消失)。
- (void)hideViewTemporarily:(UIView *)v {
    NSNumber *orig = objc_getAssociatedObject(v, &SVBBubbleOrigAlphaKey);
    if (!orig) {
        orig = @(v.alpha);
        objc_setAssociatedObject(v, &SVBBubbleOrigAlphaKey, orig,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    v.alpha = 0.0;
}

// v1.7.9: 从隐藏档拉回来时恢复原 alpha。
- (void)restoreViewAlpha:(UIView *)v {
    NSNumber *orig = objc_getAssociatedObject(v, &SVBBubbleOrigAlphaKey);
    if (orig && v.alpha <= 0.001 && [orig doubleValue] > 0.001) {
        v.alpha = [orig doubleValue];
    }
}

// v1.7.9: 安全阀 —— 视频背景视图若在某容器子树里, 该容器绝不能整体隐藏 (会把视频也藏了)。
- (BOOL)subtreeContainsVideoBg:(UIView *)view depth:(NSInteger)depth {
    if (depth > 8) return NO;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[SVBVideoBackgroundView class]]) return YES;
        if ([self subtreeContainsVideoBg:sub depth:depth + 1]) return YES;
    }
    return NO;
}

// v1.7.6: 给文字加深色投影 (拆掉气泡底后白字压亮视频看不清)。已有投影的不覆盖。
- (void)applyTextShadow:(UIView *)view {
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lb = (UILabel *)view;
        if (!lb.shadowColor) {
            lb.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.55];
            lb.shadowOffset = CGSizeMake(0, 1);
        }
    }
}

// v1.7.7/8: 终极修法 —— 气泡/装饰背景是自己画的 (drawRect 或 drawLayer:inContext:),
// 清底色/拆contents/拆模糊层全碰不到。动态扫描 CK 系 Balloon/Decoration/Platter/Background
// 类, 拦截两条绘制路径: 气泡透明开启时不画底, 拉回「原样」时恢复。
// 只挂类**自己实现**的方法 (class_copyMethodList), 避免基类/子类共享 Method 被双重包装。
- (void)patchDrawMethodOf:(Class)cls selector:(SEL)sel patched:(NSMutableSet<NSValue *> *)patched kind:(NSInteger)kind {
    unsigned cnt = 0;
    Method *list = class_copyMethodList(cls, &cnt);
    if (!list) return;
    for (unsigned i = 0; i < cnt; i++) {
        if (list[i] && method_getName(list[i]) == sel) {
            NSValue *key = [NSValue valueWithPointer:list[i]];
            if (![patched containsObject:key]) {
                [patched addObject:key];
                if (kind == 0) { // drawRect:(CGRect)
                    void (*orig)(id, SEL, CGRect) = (void (*)(id, SEL, CGRect))method_getImplementation(list[i]);
                    __block void (*origBlock)(id, SEL, CGRect) = orig;
                    __weak SVBManager *wself = self;
                    IMP newImp = imp_implementationWithBlock(^(id v, CGRect r) {
                        if ([wself bubbleAlphaForContext:SVBContextChat] < 0.999) return;
                        origBlock(v, @selector(drawRect:), r);
                    });
                    method_setImplementation(list[i], newImp);
                } else { // drawLayer:inContext:(CALayer*, CGContext*)
                    void (*orig)(id, SEL, id, void *) = (void (*)(id, SEL, id, void *))method_getImplementation(list[i]);
                    __block void (*origBlock)(id, SEL, id, void *) = orig;
                    __weak SVBManager *wself = self;
                    IMP newImp = imp_implementationWithBlock(^(id v, id layer, void *ctxp) {
                        if ([wself bubbleAlphaForContext:SVBContextChat] < 0.999) return;
                        origBlock(v, @selector(drawLayer:inContext:), layer, ctxp);
                    });
                    method_setImplementation(list[i], newImp);
                }
                [self log:@"绘制拦截: %@ %@ (%@)", cls,
                          NSStringFromSelector(sel),
                          kind == 0 ? @"drawRect" : @"drawLayer"];
            }
            break;
        }
    }
    free(list);
}

- (void)swizzleBalloonDrawingIfNeeded {
    if (SVBBalloonDrawSwizzled) return;
    SVBBalloonDrawSwizzled = YES;
    @try {
        NSMutableSet<NSValue *> *patched = [NSMutableSet set];
        // 固定名单优先 (诊断日志实锤的气泡类)
        for (NSString *clsName in @[@"CKBalloonView", @"CKTextBalloonView",
                                    @"CKHyperlinkBalloonView", @"CKBalloonViewIOS17"]) {
            Class cls = objc_getClass(clsName.UTF8String);
            if (!cls) continue;
            [self patchDrawMethodOf:cls selector:@selector(drawRect:) patched:patched kind:0];
            [self patchDrawMethodOf:cls selector:@selector(drawLayer:inContext:) patched:patched kind:1];
        }
        // v1.7.8: 动态扫描 —— CK 系里 Balloon/Decoration/Platter/Background 一律拦
        // (雾可能横跨整组消息 = 分组装饰背景 decoration view, 不一定是气泡)
        int num = objc_getClassList(NULL, 0);
        if (num > 0) {
            __unsafe_unretained Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * num);
            if (classes) {
                num = objc_getClassList(classes, num);
                for (int i = 0; i < num; i++) {
                    NSString *nm = NSStringFromClass(classes[i]);
                    if (![nm hasPrefix:@"CK"] && ![nm hasPrefix:@"_CK"]) continue;
                    BOOL hit = [nm containsString:@"Balloon"] || [nm containsString:@"Decoration"] ||
                               [nm containsString:@"Platter"] || [nm containsString:@"Background"];
                    if (!hit) continue;
                    // 文字类不能拦 (拦了字就没了): UITextView/UILabel 子视图系排除
                    if ([classes[i] isSubclassOfClass:[UITextView class]] ||
                        [classes[i] isSubclassOfClass:[UILabel class]] ||
                        [classes[i] isSubclassOfClass:[UIControl class]]) continue;
                    [self patchDrawMethodOf:classes[i] selector:@selector(drawRect:) patched:patched kind:0];
                    [self patchDrawMethodOf:classes[i] selector:@selector(drawLayer:inContext:) patched:patched kind:1];
                }
                free(classes);
            }
        }
        [self log:@"气泡绘制拦截完成, 共拦截 %lu 个方法", (unsigned long)patched.count];
    } @catch (NSException *e) {
        [self log:@"气泡 drawRect 拦截失败: %@", e];
    }
}

// v1.7.8: 一次性把聊天页完整层级 (类名/frame/底色透明度/contents/效果/透明度) 写进诊断日志,
// 若雾仍在, 下一版不用猜 —— 日志直接指出雾的宿主。
- (void)dumpHierarchyForDiagnosis:(UIView *)view {
    NSMutableString *out = [NSMutableString stringWithCapacity:1024];
    [out appendFormat:@"=== chat 层级转储 v%@ (ba=%.2f) ===\n", SVB_VERSION,
        [self bubbleAlphaForContext:SVBContextChat]];
    [self dumpHierarchyRec:view depth:0 into:out];
    [out appendFormat:@"=== 转储结束 ===\n"];
    [self log:@"%@", out];
    // v1.7.14: 独立存储键 —— prefs 日志通道只留 12K, 大转储会被新日志挤掉导致报告永远看不到
    @try {
        NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:SVB_SUITE];
        NSString *old = [ud stringForKey:@"svb_debug_dump"] ?: @"";
        NSString *nu = [old stringByAppendingString:out];
        if (nu.length > 60000) nu = [nu substringFromIndex:nu.length - 60000];
        [ud setObject:nu forKey:@"svb_debug_dump"];
        [ud synchronize];
    } @catch (NSException *e) {}
}

- (void)dumpHierarchyRec:(UIView *)v depth:(NSInteger)depth into:(NSMutableString *)out {
    if (depth > 12 || out.length > 40000) return;
    if ([v isKindOfClass:[SVBVideoBackgroundView class]]) {
        [out appendFormat:@"%*s<SVBVideoBackgroundView>\n", (int)(depth * 2), ""];
        return;
    }
    CGFloat r_ = 0, g_ = 0, b_ = 0, a_ = 0;
    BOOL hasBg = NO;
    if (v.backgroundColor) { hasBg = [v.backgroundColor getRed:&r_ green:&g_ blue:&b_ alpha:&a_] || CGColorGetAlpha(v.backgroundColor.CGColor) > 0; a_ = CGColorGetAlpha(v.backgroundColor.CGColor); }
    BOOL isEffect = [v isKindOfClass:[UIVisualEffectView class]];
    // v1.7.14: 补充 RGB 颜色值 (黑块=暗色底还是黑材质, 只有 alpha 分不出来) 与 effect 内容
    NSString *bgInfo;
    if (!hasBg) bgInfo = @"n";
    else if (r_ || g_ || b_) bgInfo = [NSString stringWithFormat:@"y(%.2f,%.2f,%.2f a%.2f)", r_, g_, b_, a_];
    else bgInfo = [NSString stringWithFormat:@"y(gray a%.2f)", a_];
    [out appendFormat:@"%*s%@ f=%@ bg=%@ ctn=%d fx=%d al=%.2f hd=%d\n",
     (int)(depth * 2), "", NSStringFromClass(v.class), NSStringFromCGRect(v.frame),
     bgInfo, v.layer.contents != nil, isEffect, v.alpha, v.hidden];
    for (UIView *s in v.subviews) [self dumpHierarchyRec:s depth:depth + 1 into:out];
}

// v1.7.5: 清除/恢复气泡里「画背景」的子视图 (类名含 background/mask/shape/fill 的绘制视图)。
// 只动没有文字、没有图片内容的子视图; on=NO 时按缓存恢复 (恢复路径简单起见仅清层内容——
// 实际使用中滑到「原样」的场景少见, 主要保证不崩、可恢复底图)。
- (void)clearDrawnBackgroundsOf:(UIView *)view depth:(NSInteger)depth on:(BOOL)on {
    if (depth > 4) return;
    for (UIView *sub in view.subviews) {
        NSString *low = NSStringFromClass([sub class]).lowercaseString;
        BOOL drawer = [low containsString:@"background"] || [low containsString:@"mask"] ||
                      [low containsString:@"shape"] || [low containsString:@"fill"];
        if (drawer && ![self viewHasTextDescendant:sub depth:0] &&
            ![self viewHasImageDescendant:sub depth:0]) {
            if (on) {
                sub.backgroundColor = nil;
                sub.layer.contents = NULL;
            }
        }
        [self clearDrawnBackgroundsOf:sub depth:depth + 1 on:on];
    }
}

- (void)refreshVisibleBackgrounds {
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) [self refreshInView:w];
        }
        for (UIWindow *w in UIApplication.sharedApplication.windows) [self refreshInView:w];
    } @catch (NSException *e) {}
}

- (void)refreshInView:(UIView *)view {
    if ([view isKindOfClass:[SVBVideoBackgroundView class]]) {
        [(SVBVideoBackgroundView *)view configure];
        return;
    }
    for (UIView *sub in view.subviews) [self refreshInView:sub];
}

// 诊断: 每个类名只记录一次, 供后续版本校准界面识别
- (void)logClassOnce:(NSString *)name context:(NSString *)ctx {
    if (!name || [self.loggedClasses containsObject:name]) return;
    [self.loggedClasses addObject:name];
    [self log:@"VC: %@ -> ctx=%@", name, ctx ?: @"(跳过)"];
}

#pragma mark - v9.9.11 前后台自愈 (切后台再回前台视频不卡)
//
// 卡住的根因 (两个叠加):
//   1) App 进后台后系统会失活 AVAudioSession, 回前台时 player 处于暂停,
//      rate=0 -> 画面上就是「停在最后一帧不动」;
//   2) AVPlayerLayer 的显示内容会被系统回收 (purge), 光靠 play 不会重绘,
//      必须重新绑定 layer.player 才能重建显示管线;
//   3) AVQueuePlayer + AVPlayerLooper 的队列副本偶尔会被清空 -> 彻底播不出来,
//      这种情况只能重建播放器。
// 因此策略分三级: 轻量重连 -> 复核 -> 强制重建。

- (void)collectVideoViewsIn:(UIView *)view into:(NSMutableArray *)out {
    if ([view isKindOfClass:[SVBVideoBackgroundView class]]) { [out addObject:view]; return; }
    for (UIView *sub in view.subviews) [self collectVideoViewsIn:sub into:out];
}

- (NSArray<SVBVideoBackgroundView *> *)allVideoBackgroundViews {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) [self collectVideoViewsIn:w into:out];
        }
        for (UIWindow *w in UIApplication.sharedApplication.windows) [self collectVideoViewsIn:w into:out];
    } @catch (NSException *e) {}
    return out;
}

- (void)pauseAllPlayers {
    for (NSString *k in self.players.allKeys) {
        @try { [self.players[k] pause]; } @catch (NSException *e) {}
    }
}

- (void)recoverVideoPlaybackForce:(BOOL)force {
    @try {
        // 1) 音频会话: 后台被失活, 不重新激活的话续播会静默失败
        @try {
            AVAudioSession *s = [AVAudioSession sharedInstance];
            [s setCategory:AVAudioSessionCategoryAmbient withOptions:0 error:nil];
            [s setActive:YES error:nil];
        } @catch (NSException *e) {}

        // 2) 播放器自检: 队列被清空 / item 解码失败 -> 只能重建
        for (NSString *ctx in self.players.allKeys) {
            AVPlayer *p = self.players[ctx];
            BOOL bad = force || !p || p.status == AVPlayerStatusFailed;
            if (!bad && [p isKindOfClass:[AVQueuePlayer class]]) {
                if (((AVQueuePlayer *)p).items.count == 0) bad = YES;   // 无缝循环副本没了
            }
            if (!bad) {
                AVPlayerItem *it = p.currentItem;
                if (!it || it.status == AVPlayerItemStatusFailed) bad = YES;
            }
            if (bad) [self playerForContext:ctx forceRebuild:YES];
        }

        // 3) 重连显示管线 + 续播
        for (SVBVideoBackgroundView *v in [self allVideoBackgroundViews]) {
            [v reconnectPlayerForce:force];
        }
    } @catch (NSException *e) {}
}

- (void)handleAppEnterBackground {
    @try {
        sSVBInBackground = YES;
        [self pauseAllPlayers];                     // 后台不解码, 省电
        if (self.bgKillEnabled) [self scheduleBackgroundKill];
    } @catch (NSException *e) {}
}

- (void)handleAppWillEnterForeground {
    @try {
        sSVBInBackground = NO;
        [self cancelScheduledBackgroundKill];        // 用户回来了 -> 取消清理
        [self recoverVideoPlaybackForce:NO];
    } @catch (NSException *e) {}
}

- (void)handleAppDidBecomeActive {
    @try {
        [self recoverVideoPlaybackForce:NO];
        // 0.6s 后复核: 还没画面 = 轻量修复没救回来 -> 逐界面强制重建
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
                for (SVBVideoBackgroundView *v in [self allVideoBackgroundViews]) {
                    if ([v playbackLooksBroken]) {
                        [self log:@"前后台自愈: 画面未就绪, 强制重建播放器 (ctx=%@)", v.contextKey];
                        [self playerForContext:v.contextKey forceRebuild:YES];
                        [v reconnectPlayerForce:YES];
                    }
                }
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

- (void)handleAudioInterruption:(NSNotification *)n {
    @try {
        NSInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
        if (type == AVAudioSessionInterruptionTypeEnded) {
            [self recoverVideoPlaybackForce:NO];     // 来电/闹钟等打断结束后自动续播
        }
    } @catch (NSException *e) {}
}

#pragma mark - v9.9.11 切后台自动清理 (可选, 默认开)

- (BOOL)bgKillEnabled {
    id v = [self configValueForKey:@"bg_kill"];
    if (!v) return YES;                              // 默认开
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : YES;
}

- (void)setBgKillEnabled:(BOOL)on {
    [self setConfigValue:@(on) forKey:@"bg_kill"];
    [self postChangeNotification];
    if (!on) [self cancelScheduledBackgroundKill];
}

- (NSTimeInterval)bgKillDelay {
    id v = [self configValueForKey:@"bg_kill_delay"];
    NSTimeInterval d = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
    return d >= 1.0 ? d : 5.0;                       // 默认 5 秒 (短暂切走不清理)
}

- (void)setBgKillDelay:(NSTimeInterval)d {
    [self setConfigValue:@(d >= 1.0 ? d : 5.0) forKey:@"bg_kill_delay"];
    [self postChangeNotification];
}

- (void)scheduleBackgroundKill {
    @try {
        // 只在真正的宿主「信息」里做 (绝不误杀 SpringBoard 等)
        if (![SVBHostBundleIdentifier() isEqualToString:SVB_SMS_BUNDLE_ID]) return;
        [self cancelScheduledBackgroundKill];
        int64_t gen = ++sSVBKillGeneration;
        NSTimeInterval delay = self.bgKillDelay;

        UIApplication *app = UIApplication.sharedApplication;
        // 申请后台额度: 否则进后台后 GCD 定时器会被挂起, 定时杀不可靠
        __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
        task = [app beginBackgroundTaskWithName:@"SVBBackgroundKill" expirationHandler:^{
            if (sSVBInBackground) SVBPerformBackgroundKill();   // 宽限期到点仍在后台 -> 直接结束
            if (task != UIBackgroundTaskInvalid) [app endBackgroundTask:task];
        }];
        sSVBKillTask = task;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!sSVBInBackground || gen != sSVBKillGeneration) return;  // 已回前台/已取消
            SVBPerformBackgroundKill();
        });
    } @catch (NSException *e) {}
}

- (void)cancelScheduledBackgroundKill {
    @try {
        sSVBKillGeneration++;                        // 让挂起的 dispatch_after 作废
        if (sSVBKillTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:sSVBKillTask];
            sSVBKillTask = UIBackgroundTaskInvalid;
        }
    } @catch (NSException *e) {}
}

@end

#pragma mark - 视频背景视图

@implementation SVBVideoBackgroundView {
    NSTimeInterval  _lastChromePass;
    CADisplayLink  *_chromeLink;
}

// 低频节流补扫: 工具栏/输入条/头部容器可能在 apply 之后才加进层级,
// 每 0.6s 对宿主 VC + 全部 window 补一遍深度透明化 (树很浅, 开销可忽略)
- (void)chromeTick:(CADisplayLink *)link {
    if (self.hidden || !self.superview) return;
    @try {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - _lastChromePass < 0.6) return;
        _lastChromePass = now;
        UIViewController *host = SVBViewControllerForView(self);
        NSString *ctx = self.contextKey;
        if (host.isViewLoaded && host.view && ctx.length) {
            [[SVBManager shared] deepChromePass:host.view depth:0 ctx:ctx];
            if ([ctx isEqualToString:SVBContextChat])
                [[SVBManager shared] bubblePass:host.view depth:0 inCell:NO ctx:ctx sysBg:NO];
            for (UIWindow *w in UIApplication.sharedApplication.windows) {
                if (w == host.view.window) continue;
                [[SVBManager shared] deepChromePass:w depth:0 ctx:ctx];
            }
        }
    } @catch (NSException *e) {}
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview && !_chromeLink) {
        _chromeLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(chromeTick:)];
        _chromeLink.preferredFramesPerSecond = 2; // 低频, 省电
        [_chromeLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    } else if (!self.superview && _chromeLink) {
        [_chromeLink invalidate];
        _chromeLink = nil;
    }
}

- (void)dealloc {
    [_chromeLink invalidate];
    _chromeLink = nil;
}

- (instancetype)initWithFrame:(CGRect)frame contextKey:(NSString *)key {
    if ((self = [super initWithFrame:frame])) {
        _contextKey = [key copy];
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO; // 不拦截触摸
        AVPlayerLayer *videoLayer = [AVPlayerLayer layer];
        videoLayer.frame = self.bounds;
        videoLayer.videoGravity = AVLayerVideoGravityResizeAspectFill; // 尺寸自适应铺满
        videoLayer.masksToBounds = YES;
        [self.layer addSublayer:videoLayer];
        _videoLayer = videoLayer;
        [self configure];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.videoLayer.frame = self.bounds;
}

- (void)configure {
    @try {
        SVBManager *mgr = [SVBManager shared];
        BOOL on = [mgr masterEnabled] && [mgr isEnabledForContext:self.contextKey] &&
                  [mgr activeVideoPathForContext:self.contextKey].length > 0;
        self.hidden = !on;
        if (!on) {
            self.videoLayer.player = nil;
            self.videoLayer.filters = nil;
            return;
        }

        AVPlayer *p = [mgr playerForContext:self.contextKey forceRebuild:NO];
        if (p && self.videoLayer.player != p) self.videoLayer.player = p;

        // 模糊度 (私有 CAFilter gaussianBlur, v1.6 按界面)
        CGFloat blur = [mgr blurForContext:self.contextKey];
        if (blur > 0.01) {
            Class cls = objc_getClass("CAFilter");
            SEL sel = NSSelectorFromString(@"filterWithName:");
            id f = nil;
            if (cls && [(id)cls respondsToSelector:sel]) {
                f = ((id (*)(id, SEL, id))objc_msgSend)((id)cls, sel, @"gaussianBlur");
                if (f) [f setValue:@(blur) forKey:@"inputRadius"];
            }
            self.videoLayer.filters = f ? @[f] : nil;
        } else {
            self.videoLayer.filters = nil;
        }

        // 不透明度 (v1.6 按界面)
        self.videoLayer.opacity = (float)[mgr alphaForContext:self.contextKey];

        // 音量 (v1.6 按界面, 默认静音)
        if (p) {
            CGFloat vol = [mgr volumeForContext:self.contextKey];
            p.volume = vol;
            p.muted  = (vol <= 0.001);
            if (p.rate == 0.0) [p play];
        }
    } @catch (NSException *e) {}
}

#pragma mark - v9.9.11 前后台自愈

// 重建显示管线。后台被系统回收内容后, AVPlayerLayer 不会自行重绘 ——
// 只 play 没有用, 必须把 player 重新绑一次 (先摘后挂) 才会重新出画面。
- (void)reconnectPlayerForce:(BOOL)force {
    @try {
        if (self.hidden) return;
        SVBManager *mgr = [SVBManager shared];
        AVPlayer *p = [mgr playerForContext:self.contextKey forceRebuild:NO];
        if (!p) return;

        AVPlayerLayer *L = self.videoLayer;
        if (force || L.player != p) {
            L.player = nil;      // 摘掉 -> 显示管线失效
            L.player = p;        // 重新挂上 -> 强制重建
        } else {
            [L setNeedsDisplay];
        }
        if (p.rate == 0.0) [p play];
        [self configure];        // 顺带把不透明度/模糊/音量重新套一遍
    } @catch (NSException *e) {}
}

// 画面是否处于「后台回来的卡死态」: 片源已就绪, 但 layer 没画面 / 停了
- (BOOL)playbackLooksBroken {
    @try {
        if (self.hidden || !self.superview) return NO;
        AVPlayer *p = [SVBManager shared].players[self.contextKey];
        if (!p) return NO;                                   // 本来就没背景
        AVPlayerItem *it = p.currentItem;
        if (!it || it.status != AVPlayerItemStatusReadyToPlay) return NO;   // 还在加载, 不算坏
        if (!self.videoLayer.isReadyForDisplay) return YES;  // 典型症状: 有片源但没画面
        if (p.rate == 0.0) return YES;                       // 该播却没播
        return NO;
    } @catch (NSException *e) { return NO; }
}

@end

#pragma mark - 注入可视化横幅 (v1.3 诊断核心)

// 挂在宿主 App 窗口顶部的诊断条: 能看到这条 = 插件确实注入进该进程了。
// 文案里带「各根是否存在/可读/素材数」, 顺带定位「素材到底读没读到」。
static BOOL sSVBBannerDismissed = NO;

@interface SVBDebugBanner : UIView
@property (nonatomic, strong) UILabel *label;
- (void)handleTap;
+ (void)show:(NSString *)text;
+ (void)show:(NSString *)text force:(BOOL)force;
@end

@implementation SVBDebugBanner

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.09 green:0.11 blue:0.17 alpha:0.94];
        self.layer.cornerRadius = 10;
        self.layer.masksToBounds = YES;
        self.userInteractionEnabled = YES;
        _label = [[UILabel alloc] init];
        _label.numberOfLines = 0;
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.97];
        _label.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:7],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-7],
        ]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                    initWithTarget:self action:@selector(handleTap)]];
    }
    return self;
}

- (void)handleTap {
    sSVBBannerDismissed = YES;
    [UIView animateWithDuration:0.18 animations:^{ self.alpha = 0; }
                     completion:^(BOOL finished) { [self removeFromSuperview]; }];
}

+ (void)show:(NSString *)text {
    [self show:text force:NO];
}

// v1.9.0: force=YES 时忽略「诊断横幅开关」(未授权提示必须让用户看到),
// 但用户点掉横幅 (dismissed) 仍然尊重, 免得反复弹出来烦人。
+ (void)show:(NSString *)text force:(BOOL)force {
    if (sSVBBannerDismissed || !text.length) return;
    if (!force && ![[SVBManager shared] debugBannerEnabled]) return;

    void (^block)(void) = ^{
        @try {
            UIWindow *win = nil;
            for (UIWindow *w in UIApplication.sharedApplication.windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (!win) win = UIApplication.sharedApplication.windows.firstObject;
            if (!win) return;

            SVBDebugBanner *b = nil;
            for (UIView *v in win.subviews) {
                if ([v isKindOfClass:[SVBDebugBanner class]]) { b = (SVBDebugBanner *)v; break; }
            }
            if (!b) {
                b = [[SVBDebugBanner alloc] initWithFrame:CGRectMake(8, 0, win.bounds.size.width - 16, 0)];
                b.translatesAutoresizingMaskIntoConstraints = NO;
                [win addSubview:b];
                [NSLayoutConstraint activateConstraints:@[
                    [b.leadingAnchor constraintEqualToAnchor:win.leadingAnchor constant:8],
                    [b.trailingAnchor constraintEqualToAnchor:win.trailingAnchor constant:-8],
                    [b.topAnchor constraintEqualToAnchor:win.safeAreaLayoutGuide.topAnchor constant:2],
                ]];
            }
            b.label.text = text;
            [win bringSubviewToFront:b];
        } @catch (NSException *e) {}
    };

    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

@end

void SVBShowDebugBanner(NSString *text) {
    [SVBDebugBanner show:text];
}

// v1.9.0: 强制显示 (忽略「诊断横幅」开关) —— 未授权提示用
void SVBShowDebugBannerForce(NSString *text) {
    [SVBDebugBanner show:text force:YES];
}
