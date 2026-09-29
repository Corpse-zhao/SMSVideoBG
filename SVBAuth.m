#import "SVBAuth.h"
#import "SVBCommon.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <string.h>
#import <math.h>

// 与签发 App 共用同一把密钥 (CI 从 GitHub Secret SVB_LICENSE_SECRET 注入)
#ifndef SVB_LICENSE_SECRET
#define SVB_LICENSE_SECRET "SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"
#endif
static const char *const kAuthSecret = SVB_LICENSE_SECRET;

#define SVB_AUTH_KEY_MAP @"auth_map"        // 缓存: {H32: 到期dayIndex}
#define SVB_AUTH_KEY_TS  @"auth_ts"         // 缓存: 上次成功同步时间
#define SVB_AUTH_KEY_TRY @"auth_try_ts"     // 缓存: 上次尝试时间 (节流)
#define SVB_AUTH_KEY_VTS @"auth_ver_ts"     // 缓存: 已采用名单自带的 ts (防旧名单回滚)
#define SVB_AUTH_KEY_URL @"auth_url"        // 自定义授权服务地址 (空 = 用内置多源)
#define SVB_AUTH_INTERVAL (30 * 60.0)       // 30 分钟拉一次
#define SVB_AUTH_TIMEOUT  9.0               // 单源超时 (并发拉, 不必留太长)
#define SVB_AUTH_BODY_WINDOW 3.0            // 拿到首个可用响应后再等这么久, 取最新的一份

// UDID 哈希前缀 (与签发 App 严格一致)
static NSString * const kAuthHashPrefix = @"SMSVideoBG-AUTH/v1|";

#pragma mark - 日期工具

static NSTimeInterval SVBAuthEpoch(void) {   // 2020-01-01 00:00:00 UTC
    static NSTimeInterval e = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = 1577836800.0; });
    return e;
}

uint32_t SVBAuthDayIndexNow(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now < SVBAuthEpoch()) return 0;
    double d = floor((now - SVBAuthEpoch()) / 86400.0);
    if (d < 0) return 0;
    if (d > 4294967294.0) return 4294967294u;
    return (uint32_t)d;
}

NSString *SVBAuthDateTextForDayIndex(uint32_t idx) {
    if (idx == SVB_AUTH_FOREVER) return @"永久";
    NSTimeInterval ts = SVBAuthEpoch() + (NSTimeInterval)idx * 86400.0 + 86399.0;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd";
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

#pragma mark - UDID / 哈希

NSString *SVBAuthNormalizeUDID(NSString *raw) {
    if (!raw.length) return nil;
    NSString *up = [raw uppercaseString];
    NSMutableString *s = [NSMutableString stringWithCapacity:up.length];
    for (NSUInteger i = 0; i < up.length; i++) {
        unichar c = [up characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) [s appendFormat:@"%c", (char)c];
    }
    return s.length ? s : nil;
}

// MobileGestalt (dlopen, 不引入私有框架链接依赖)
static NSString *SVBAuthMGString(NSString *key) {
    static CFStringRef (*answer)(CFStringRef) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (handle) answer = (CFStringRef (*)(CFStringRef))dlsym(handle, "MGGetStringAnswer");
    });
    if (!answer) return nil;
    CFStringRef v = NULL;
    @try { v = answer((__bridge CFStringRef)key); } @catch (NSException *e) {}
    if (!v) return nil;
    NSString *s = (__bridge_transfer NSString *)v;
    return s.length ? s : nil;
}

NSString *SVBAuthUDID(void) {
    NSString *udid = SVBAuthMGString(@"UniqueDeviceID");
    if (udid.length) return udid;
    NSString *sn = SVBAuthMGString(@"SerialNumber");
    if (sn.length) return sn;
    return nil;
}

NSString *SVBAuthUDIDSource(void) {
    if (SVBAuthMGString(@"UniqueDeviceID").length) return @"硬件 UDID";
    if (SVBAuthMGString(@"SerialNumber").length)  return @"硬件序列号";
    return @"读不到";
}

NSString *SVBAuthHashForUDID(NSString *udid) {
    NSString *norm = SVBAuthNormalizeUDID(udid);
    if (!norm.length) return nil;
    NSString *payload = [kAuthHashPrefix stringByAppendingString:norm];
    const char *utf8 = payload.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02X", digest[i]];
    return hex;
}

NSString *SVBAuthDeviceHash(void) {
    NSString *udid = SVBAuthUDID();
    if (!udid.length) return nil;
    return SVBAuthHashForUDID(udid);
}

#pragma mark - 白名单解析

static NSString *SVBAuthHexLower(const unsigned char *bytes, int n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (int i = 0; i < n; i++) [s appendFormat:@"%02x", bytes[i]];
    return s;
}

// 签名原文: "SVBAUTH/v1|<ts>|<H32=dayIndex 升序逗号连接>"
static NSString *SVBAuthPayloadString(NSInteger ts, NSDictionary<NSString *, NSNumber *> *devices) {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *h in devices) {
        if (![h isKindOfClass:[NSString class]]) continue;
        id v = [devices objectForKey:h];
        if (![v respondsToSelector:@selector(longLongValue)]) continue;
        long long n = [v longLongValue];
        NSString *hu = [(NSString *)h uppercaseString];
        if (hu.length != 32 || n < 0 || n > 0xFFFFFFFFLL) continue;
        [pairs addObject:[NSString stringWithFormat:@"%@=%llu", hu, n]];
    }
    [pairs sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"SVBAUTH/v1|%ld|%@", (long)ts,
            [pairs componentsJoinedByString:@","]];
}

static NSString *SVBAuthSignatureHex(NSString *payload) {
    if (!payload.length) return @"";
    const char *utf8 = payload.UTF8String;
    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    CCHmac(kCCHmacAlgSHA256, kAuthSecret, strlen(kAuthSecret), utf8, strlen(utf8), mac);
    return SVBAuthHexLower(mac, CC_SHA256_DIGEST_LENGTH);
}

// 解析并验签; 通过返回 {H32: @(dayIndex)}, 否则 nil
// outTs (可空) 回传名单自带的 ts —— 多源竞速时用它挑最新的一份
static NSDictionary<NSString *, NSNumber *> *SVBAuthMapFromJSON(NSData *json, NSInteger *outTs) {
    if (outTs) *outTs = 0;
    if (!json.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)obj;
    NSNumber *ver = d[@"v"], *ts = d[@"ts"];
    NSDictionary *dev = d[@"devices"];
    NSString *sig = d[@"sig"];
    if (![ver isKindOfClass:[NSNumber class]] || ver.integerValue != 1) return nil;
    if (![ts isKindOfClass:[NSNumber class]]) return nil;
    if (![dev isKindOfClass:[NSDictionary class]]) return nil;
    if (![sig isKindOfClass:[NSString class]] || sig.length != 64) return nil;

    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (NSString *h in dev) {
        if (![h isKindOfClass:[NSString class]] || h.length != 32) return nil;
        id v = [dev objectForKey:h];
        if (![v isKindOfClass:[NSNumber class]]) return nil;
        long long n = [v longLongValue];
        if (n < 0 || n > 0xFFFFFFFFLL) return nil;
        [clean setObject:@(n) forKey:[h uppercaseString]];
    }
    NSString *expect = SVBAuthSignatureHex(SVBAuthPayloadString(ts.integerValue, clean));
    if (![[sig lowercaseString] isEqualToString:expect]) return nil;
    if (outTs) *outTs = ts.integerValue;
    return clean;
}

#pragma mark - 缓存

static NSDictionary<NSString *, NSNumber *> *SVBAuthCachedMap(void) {
    id v = nil;
    @try { v = [[SVBManager shared] configValueForKey:SVB_AUTH_KEY_MAP]; } @catch (NSException *e) {}
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

NSInteger SVBAuthCachedCount(void) {
    return (NSInteger)SVBAuthCachedMap().count;
}

NSTimeInterval SVBAuthLastSyncTime(void) {
    id v = nil;
    @try { v = [[SVBManager shared] configValueForKey:SVB_AUTH_KEY_TS]; } @catch (NSException *e) {}
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
}

BOOL SVBAuthCachedHasSelf(NSString **expText) {
    NSString *hash = SVBAuthDeviceHash();
    if (!hash.length) return NO;
    NSNumber *n = [SVBAuthCachedMap() objectForKey:hash];
    if (![n isKindOfClass:[NSNumber class]]) return NO;
    if (expText) *expText = SVBAuthDateTextForDayIndex((uint32_t)[n unsignedIntValue]);
    return YES;
}

#pragma mark - 判定

SVBAuthState SVBAuthCurrentState(NSString **detail) {
    if (detail) *detail = nil;

    NSString *hash = SVBAuthDeviceHash();
    if (!hash.length) {
        if (detail) *detail = @"读不到设备 UDID";
        return SVBAuthStateNoUDID;
    }

    // 顺手触发一次后台同步 (30 分钟节流)
    SVBAuthRefreshIfNeeded(NO);

    NSDictionary<NSString *, NSNumber *> *map = SVBAuthCachedMap();
    NSTimeInterval ts = SVBAuthLastSyncTime();
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    if (!map.count) {
        if (detail) *detail = ts > 0 ? @"本机不在授权名单里" : @"尚未联网校验";
        return ts > 0 ? SVBAuthStateUnauthorized : SVBAuthStateOffline;
    }

    NSNumber *n = [map objectForKey:hash];
    if (![n isKindOfClass:[NSNumber class]]) {
        if (detail) *detail = @"本机不在授权名单里";
        return SVBAuthStateUnauthorized;
    }

    uint32_t exp = (uint32_t)[n unsignedIntValue];
    BOOL forever = (exp == SVB_AUTH_FOREVER);

    // 离线过久 / 时钟回拨 -> 必须联网重新校验 (否则作者删了 UDID 也拦不住)
    if (ts <= 0 || (now - ts) > SVB_AUTH_MAX_OFFLINE_DAYS * 86400.0 || now + 86400.0 < ts) {
        if (detail) *detail = @"离线过久，需要联网校验授权";
        return SVBAuthStateOffline;
    }

    if (!forever) {
        uint32_t today = SVBAuthDayIndexNow();
        if (today > exp) {
            if (detail) *detail = [NSString stringWithFormat:@"已于 %@ 到期",
                                   SVBAuthDateTextForDayIndex(exp)];
            return SVBAuthStateExpired;
        }
        if (detail) *detail = [NSString stringWithFormat:@"有效期至 %@",
                               SVBAuthDateTextForDayIndex(exp)];
    } else {
        if (detail) *detail = @"永久授权";
    }
    return SVBAuthStateAuthorized;
}

// v10.0.1: 缓存挪到文件作用域, 让「强制校验完成」可以立即作废它
// (否则验证成功后最长 60 秒内 SVBIsLicensed() 还是旧结论, 用户会以为没生效)
static SVBAuthState gAuthCachedState = SVBAuthStateOffline;
static NSTimeInterval gAuthCachedAt = 0;

void SVBAuthInvalidateCache(void) {
    gAuthCachedState = SVBAuthStateOffline;
    gAuthCachedAt = 0;
}

BOOL SVBAuthIsAuthorized(void) {
    @try {
        // 60 秒缓存, 避免每次挂背景都重算
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (gAuthCachedAt > 0 && now - gAuthCachedAt < 60.0)
            return gAuthCachedState == SVBAuthStateAuthorized;
        gAuthCachedState = SVBAuthCurrentState(NULL);
        gAuthCachedAt = now;
        return gAuthCachedState == SVBAuthStateAuthorized;
    } @catch (NSException *e) {
        return NO;
    }
}

NSString *SVBAuthStateText(SVBAuthState st, NSString *detail) {
    NSString *core = nil;
    switch (st) {
        case SVBAuthStateAuthorized:   core = @"已授权"; break;
        case SVBAuthStateExpired:      core = @"已过期"; break;
        case SVBAuthStateUnauthorized: core = @"未授权"; break;
        case SVBAuthStateNoUDID:       core = @"无法读取 UDID"; break;
        case SVBAuthStateOffline:
        default:                       core = @"待联网校验"; break;
    }
    return detail.length ? [NSString stringWithFormat:@"%@ · %@", core, detail] : core;
}

#pragma mark - 拉取

// v10.0.2: 多源「并发竞速」—— 国内网络不挂代理也能激活
//   · 国内直连 raw.githubusercontent / api.github.com 基本不通, 靠公共加速镜像兜底;
//   · 名单是 HMAC 签名的, 走任何第三方镜像都无法伪造 (改一个字节就验签失败 -> 忽略),
//     所以"并发拉多个不可信源"在安全上是成立的;
//   · 不再使用 cdn.jsdelivr.net: 它对分支引用有最长 12 小时缓存, 作者删掉 UDID 后
//     可能长时间还拉到旧名单, 与"删除即失效"的语义冲突, 故移除;
//   · 并发而不是顺序: 顺序时每个死源都要把超时耗完才轮到下一个, 首次激活体验很差。

NSString *SVBAuthCustomSourceURL(void) {
    id v = nil;
    @try { v = [[SVBManager shared] configValueForKey:SVB_AUTH_KEY_URL]; } @catch (NSException *e) {}
    return ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) ? (NSString *)v : nil;
}

void SVBAuthSetCustomSourceURL(NSString *url) {
    @try {
        NSString *t = url ? [url stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
        SVBManager *mgr = [SVBManager shared];
        [mgr setConfigValue:(t.length ? t : @"") forKey:SVB_AUTH_KEY_URL];
        [mgr setConfigValue:@(0) forKey:SVB_AUTH_KEY_TRY];   // 清节流: 下次立即按新地址拉
        SVBAuthInvalidateCache();
    } @catch (NSException *e) {}
}

static NSArray<NSString *> *SVBAuthURLs(void) {
    NSMutableArray *urls = [NSMutableArray array];
    NSString *custom = SVBAuthCustomSourceURL();
    if (custom) [urls addObject:custom];

    NSString *raw = @"https://raw.githubusercontent.com/Corpse-zhao/SMSVideoBG/revoke/auth.json";
    // 国内可直连的 GitHub 加速镜像 (返回的就是原始文件内容, 不夹带页面)
    [urls addObject:[@"https://ghfast.top/"   stringByAppendingString:raw]];
    [urls addObject:[@"https://gh-proxy.com/" stringByAppendingString:raw]];
    [urls addObject:[@"https://ghproxy.net/"  stringByAppendingString:raw]];
    // 原生源 (海外网络 / 挂了代理时最快最可靠)
    [urls addObject:@"https://api.github.com/repos/Corpse-zhao/SMSVideoBG/contents/auth.json?ref=revoke"];
    [urls addObject:raw];
    return urls;
}

static NSLock *SVBAuthLock(void) {
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

static BOOL gSVBAuthRunning = NO;

static void SVBAuthFetchAll(NSArray<NSString *> *urls) {
    if (!urls.count) return;

    NSLock *lock = [[NSLock alloc] init];
    __block NSMutableArray *bodies = [NSMutableArray array];   // 200 响应体
    __block NSTimeInterval firstBodyAt = 0;                    // 首个响应体到达时间
    __block NSInteger saw404 = 0;

    dispatch_group_t grp = dispatch_group_create();
    for (NSString *urlStr in urls) {
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) continue;

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.timeoutInterval = SVB_AUTH_TIMEOUT;
        req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        req.HTTPShouldHandleCookies = NO;
        if ([urlStr containsString:@"api.github.com"])
            [req setValue:@"application/vnd.github.raw" forHTTPHeaderField:@"Accept"];

        dispatch_group_enter(grp);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:req
              completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                @try {
                    NSInteger status = 0;
                    if ([resp isKindOfClass:[NSHTTPURLResponse class]])
                        status = ((NSHTTPURLResponse *)resp).statusCode;
                    [lock lock];
                    if (status == 404) {
                        saw404++;
                    } else if (!err && status == 200 && data.length) {
                        [bodies addObject:data];
                        if (firstBodyAt <= 0)
                            firstBodyAt = [[NSDate date] timeIntervalSince1970];
                    }
                    [lock unlock];
                } @catch (NSException *e) {}
                dispatch_group_leave(grp);
            }];
        [task resume];
    }

    // 收集窗口: 全部完成 / 拿到首个响应后再等一会 / 总超时, 三者先到为准
    NSTimeInterval deadline = [[NSDate date] timeIntervalSince1970] + SVB_AUTH_TIMEOUT + 3.0;
    while (1) {
        NSTimeInterval tick = [[NSDate date] timeIntervalSince1970];
        if (tick >= deadline) break;
        [lock lock];
        NSUInteger cnt = bodies.count;
        NSTimeInterval fb = firstBodyAt;
        [lock unlock];
        if (cnt > 0 && fb > 0 && tick - fb >= SVB_AUTH_BODY_WINDOW) break;
        if (dispatch_group_wait(grp, dispatch_time(DISPATCH_TIME_NOW,
                                                   (int64_t)(0.25 * NSEC_PER_SEC))) == 0) break;
    }

    [lock lock];
    NSArray *snapshot = [bodies copy];
    NSInteger n404 = saw404;
    [lock unlock];

    // 取 ts 最大的那一份 (并发多源里可能有缓存住的旧名单)
    NSDictionary *best = nil;
    NSInteger bestTs = 0;
    for (NSData *b in snapshot) {
        NSInteger t = 0;
        NSDictionary *m = SVBAuthMapFromJSON(b, &t);
        if (!m) continue;
        if (!best || t > bestTs) { best = m; bestTs = t; }
    }

    SVBManager *mgr = [SVBManager shared];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    if (best) {
        id pv = [mgr configValueForKey:SVB_AUTH_KEY_VTS];
        NSInteger prevTs = [pv respondsToSelector:@selector(integerValue)] ? [pv integerValue] : 0;
        if (bestTs < prevTs) {   // 防"旧名单回滚"把已删除的设备复活
            [mgr log:@"[auth] 拉到的名单更旧 (v=%ld < %ld), 忽略", (long)bestTs, (long)prevTs];
            return;
        }
        [mgr setConfigValue:best forKey:SVB_AUTH_KEY_MAP];
        [mgr setConfigValue:@(bestTs) forKey:SVB_AUTH_KEY_VTS];
        [mgr setConfigValue:@(now) forKey:SVB_AUTH_KEY_TS];
        SVBAuthInvalidateCache();   // v10.0.1: 结论可能变了, 立即作废 60 秒判定缓存
        [mgr log:@"[auth] 授权名单已更新: %lu 台设备 (v=%ld)",
                 (unsigned long)best.count, (long)bestTs];
        return;
    }

    if (n404 > 0) {
        // 各源都说"没有名单文件": 只有本地也没缓存时才认定为"确认未授权"
        if (SVBAuthCachedCount() == 0) {
            [mgr setConfigValue:@(now) forKey:SVB_AUTH_KEY_TS];
            SVBAuthInvalidateCache();
        }
        [mgr log:@"[auth] 各源均无名单文件(404), 本地缓存 %ld 台",
                 (long)SVBAuthCachedCount()];
        return;
    }
    [mgr log:@"[auth] 全部源失败或验签不通过, 沿用旧缓存"];
}

static void SVBAuthRefreshForce(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            SVBAuthFetchAll(SVBAuthURLs());
        } @catch (NSException *e) {}
        [SVBAuthLock() lock];
        gSVBAuthRunning = NO;
        [SVBAuthLock() unlock];
    });
}

void SVBAuthRefreshIfNeeded(BOOL force) {
    @try {
        SVBManager *mgr = [SVBManager shared];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        id tryV = [mgr configValueForKey:SVB_AUTH_KEY_TRY];
        NSTimeInterval lastTry = [tryV respondsToSelector:@selector(doubleValue)] ? [tryV doubleValue] : 0;
        if (!force && lastTry > 0 && now - lastTry < SVB_AUTH_INTERVAL) return;
        [mgr setConfigValue:@(now) forKey:SVB_AUTH_KEY_TRY];

        [SVBAuthLock() lock];
        if (gSVBAuthRunning) { [SVBAuthLock() unlock]; return; }
        gSVBAuthRunning = YES;
        [SVBAuthLock() unlock];

        SVBAuthRefreshForce();
    } @catch (NSException *e) {}
}
