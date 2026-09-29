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
#define SVB_AUTH_KEY_GITEE @"auth_gitee"    // Gitee(码云) 名单地址 (国内直连)
#define SVB_AUTH_KEY_OFFLINE @"auth_offline" // 离线授权串: {"e":到期dayIndex,"at":导入时间}
#define SVB_AUTH_INTERVAL (30 * 60.0)       // 30 分钟拉一次
#define SVB_AUTH_TIMEOUT  9.0               // 单源超时 (并发拉, 不必留太长)
#define SVB_AUTH_BODY_WINDOW 3.0            // 拿到首个可用响应后再等这么久, 取最新的一份

// --- 离线授权串 (v10.1.0) ---
#define SVB_AUTH_TICKET_TAG @"SVBOFFLINE1:"
#define SVB_AUTH_TICKET_MAX_DAYS 30         // 离线授权有效期上限(天): 防断网永久白嫖

// 编译期内置的 Gitee 名单地址 (CI 用 GitHub Secret SVB_GITEE_URL 注入;
// 也可在控制 App 里填, 写入配置键 auth_gitee 后优先级更高)
#ifndef SVB_GITEE_URL
#define SVB_GITEE_URL ""
#endif

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

// 离线授权串是否有效 (有效时回传到期 dayIndex)
static BOOL SVBAuthOfflineTicketExp(uint32_t *outExp) {
    id raw = nil;
    @try { raw = [[SVBManager shared] configValueForKey:SVB_AUTH_KEY_OFFLINE]; } @catch (NSException *e) {}
    if (![raw isKindOfClass:[NSDictionary class]]) return NO;
    id e = [(NSDictionary *)raw objectForKey:@"e"];
    if (![e respondsToSelector:@selector(unsignedIntValue)]) return NO;
    uint32_t exp = (uint32_t)[e unsignedIntValue];
    // 硬性上限: 就算记录被手改, 也只认"导入日起最多 30 天"这一档
    if (exp != SVB_AUTH_FOREVER) {
        uint32_t cap = SVBAuthDayIndexNow() + SVB_AUTH_TICKET_MAX_DAYS;
        if (exp > cap) exp = cap;
    }
    if (exp == SVB_AUTH_FOREVER) return NO;     // 离线串不允许永久
    if (SVBAuthDayIndexNow() > exp) return NO;  // 已过期
    if (outExp) *outExp = exp;
    return YES;
}

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

    // "在线名单新鲜" = 最近 30 天内成功联网校验过 (含确认名单为空)
    BOOL onlineFresh = (ts > 0 &&
                        (now - ts) <= SVB_AUTH_MAX_OFFLINE_DAYS * 86400.0 &&
                        now + 86400.0 >= ts);

    uint32_t offExp = 0;
    BOOL offOK = SVBAuthOfflineTicketExp(&offExp);

    NSNumber *n = [map objectForKey:hash];

    if ([n isKindOfClass:[NSNumber class]]) {
        uint32_t exp = (uint32_t)[n unsignedIntValue];

        if (onlineFresh) {
            if (exp != SVB_AUTH_FOREVER) {
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

        // 名单命中但离线过久: 有离线串先用离线串的期限顶着
        if (offOK) {
            if (detail) *detail = [NSString stringWithFormat:@"离线授权 · 有效期至 %@",
                                   SVBAuthDateTextForDayIndex(offExp)];
            return SVBAuthStateAuthorized;
        }
        if (detail) *detail = @"离线过久，需要联网校验授权";
        return SVBAuthStateOffline;
    }

    // 名单里没有本机:
    // 名单非空 + 刚联网确认过 -> 以在线为准(作者删掉 UDID 即掉授权, 离线串不救)
    if (onlineFresh && map.count > 0) {
        if (detail) *detail = @"本机不在授权名单里";
        return SVBAuthStateUnauthorized;
    }

    // 名单为空 / 尚未联网: 允许离线授权串生效
    if (offOK) {
        if (detail) *detail = [NSString stringWithFormat:@"离线授权 · 有效期至 %@",
                               SVBAuthDateTextForDayIndex(offExp)];
        return SVBAuthStateAuthorized;
    }

    if (ts <= 0) {
        if (detail) *detail = @"尚未联网校验";
        return SVBAuthStateOffline;
    }
    if (detail) *detail = @"本机不在授权名单里";
    return SVBAuthStateUnauthorized;
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

#pragma mark - 离线授权串 (v10.1.0)

// 只留 base64 合法字符, 并补齐 padding (客户复制时常带空格/换行)
static NSData *SVBAuthB64Decode(NSString *s) {
    if (!s.length) return nil;
    NSMutableString *m = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=') {
            [m appendFormat:@"%C", c];
        }
    }
    if (!m.length) return nil;
    NSUInteger pad = (4 - (m.length % 4)) % 4;
    for (NSUInteger i = 0; i < pad; i++) [m appendString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:m options:0];
}

static NSString *SVBAuthOfflinePayload(NSString *h32, uint32_t exp, NSInteger ts) {
    return [NSString stringWithFormat:@"SVBGOFFLINE/v1|%@|%u|%ld",
            h32, (unsigned)exp, (long)ts];
}

BOOL SVBAuthImportTicket(NSString *text, NSString **message) {
    NSString *fail = nil;
    do {
        NSString *t = text ?
            [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
        if (!t.length) { fail = @"内容是空的"; break; }

        // 容忍前后带了别的文字: 从标记处截取
        NSRange r = [t rangeOfString:SVB_AUTH_TICKET_TAG];
        if (r.location != NSNotFound)
            t = [t substringFromIndex:r.location + r.length];

        NSData *raw = SVBAuthB64Decode(t);
        if (!raw.length) { fail = @"格式不对（不是有效的授权串）"; break; }

        id obj = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
        if (![obj isKindOfClass:[NSDictionary class]]) { fail = @"授权串内容无法解析"; break; }
        NSDictionary *d = (NSDictionary *)obj;

        NSString *h = d[@"h"];
        NSNumber *e = d[@"e"], *tk = d[@"t"];
        NSString *sig = d[@"s"];
        if (![h isKindOfClass:[NSString class]] ||
            ![e isKindOfClass:[NSNumber class]] ||
            ![tk isKindOfClass:[NSNumber class]] ||
            ![sig isKindOfClass:[NSString class]]) { fail = @"授权串字段不完整"; break; }

        NSString *mine = SVBAuthDeviceHash();
        if (!mine.length) { fail = @"读不到本机 UDID，无法导入"; break; }

        // ① 必须绑定本机
        if (![[h uppercaseString] isEqualToString:mine]) {
            fail = [NSString stringWithFormat:
                    @"这段授权串不是本机的（串内 %@…，本机 %@…）",
                    [h substringToIndex:MIN((NSUInteger)8, h.length)],
                    [mine substringToIndex:MIN((NSUInteger)8, mine.length)]];
            break;
        }

        // ② 验签
        uint32_t want = (uint32_t)[e unsignedIntValue];
        NSString *expect = SVBAuthSignatureHex(
            SVBAuthOfflinePayload(mine, want, [tk integerValue]));
        if (![[sig lowercaseString] isEqualToString:expect]) {
            fail = @"授权串校验不通过（内容被改过或不是本插件签发）";
            break;
        }

        // ③ 有效期强制截断到 30 天内
        uint32_t today = SVBAuthDayIndexNow();
        uint32_t cap = today + SVB_AUTH_TICKET_MAX_DAYS;
        uint32_t use = (want == SVB_AUTH_FOREVER || want > cap) ? cap : want;
        if (use < today) { fail = @"这段授权串已经过期了"; break; }

        [SVBManager.shared setConfigValue:@{ @"e": @(use),
                                             @"at": @([[NSDate date] timeIntervalSince1970]) }
                                   forKey:SVB_AUTH_KEY_OFFLINE];
        SVBAuthInvalidateCache();

        if (message) {
            *message = [NSString stringWithFormat:
                @"导入成功，本机已授权（离线有效期至 %@）。\n"
                @"联网校验成功一次后会自动转成完整期限的在线授权。",
                SVBAuthDateTextForDayIndex(use)];
        }
        return YES;
    } while (0);

    if (message) *message = fail ? fail : @"导入失败";
    return NO;
}

void SVBAuthClearTicket(void) {
    @try {
        [SVBManager.shared setConfigValue:@{} forKey:SVB_AUTH_KEY_OFFLINE];
        SVBAuthInvalidateCache();
    } @catch (NSException *e) {}
}

BOOL SVBAuthHasOfflineTicket(NSString **expText) {
    uint32_t exp = 0;
    if (!SVBAuthOfflineTicketExp(&exp)) return NO;
    if (expText) *expText = SVBAuthDateTextForDayIndex(exp);
    return YES;
}

NSString *SVBAuthOfflineTicketInfo(void) {
    NSString *txt = nil;
    if (!SVBAuthHasOfflineTicket(&txt)) return @"无";
    return [NSString stringWithFormat:@"有效 · 至 %@", txt];
}

#pragma mark - 拉取

// v10.0.2: 多源「并发竞速」—— 国内网络不挂代理也能激活
//   · 国内直连 raw.githubusercontent / api.github.com 基本不通, 靠公共加速镜像兜底;
//   · 名单是 HMAC 签名的, 走任何第三方镜像都无法伪造 (改一个字节就验签失败 -> 忽略),
//     所以"并发拉多个不可信源"在安全上是成立的;
//   · 不再使用 cdn.jsdelivr.net: 它对分支引用有最长 12 小时缓存, 作者删掉 UDID 后
//     可能长时间还拉到旧名单, 与"删除即失效"的语义冲突, 故移除;
//   · 并发而不是顺序: 顺序时每个死源都要把超时耗完才轮到下一个, 首次激活体验很差。
// v10.1.0: 客户实测"公共加速镜像在国内手机上也基本拉不到", 故把 Gitee(码云)
//          作为首选国内直连源 —— 它是国内站点, 手机直连稳定, 且 raw 每次 302
//          到带签名的新地址, 不做长缓存, "删除即失效"不受影响。

NSString *SVBAuthGiteeURL(void) {
    id v = nil;
    @try { v = [[SVBManager shared] configValueForKey:SVB_AUTH_KEY_GITEE]; } @catch (NSException *e) {}
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return (NSString *)v;
    NSString *k = @SVB_GITEE_URL;
    return k.length ? k : nil;
}

void SVBAuthSetGiteeURL(NSString *url) {
    @try {
        NSString *t = url ? [url stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
        SVBManager *mgr = [SVBManager shared];
        [mgr setConfigValue:(t.length ? t : @"") forKey:SVB_AUTH_KEY_GITEE];
        [mgr setConfigValue:@(0) forKey:SVB_AUTH_KEY_TRY];   // 清节流: 下次立即按新地址拉
        SVBAuthInvalidateCache();
    } @catch (NSException *e) {}
}

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
    if (custom) [urls addObject:custom];            // 自定义源 (最高优先)

    NSString *gitee = SVBAuthGiteeURL();            // 国内直连首选
    if (gitee.length) [urls addObject:gitee];

    NSString *raw = @"https://raw.githubusercontent.com/Corpse-zhao/SMSVideoBG/revoke/auth.json";
    // GitHub 公共加速镜像 (挂了代理时很快; 国内手机实测多数不稳, 仅作兜底)
    [urls addObject:[@"https://ghfast.top/"   stringByAppendingString:raw]];
    [urls addObject:[@"https://gh-proxy.com/" stringByAppendingString:raw]];
    [urls addObject:[@"https://ghproxy.net/"  stringByAppendingString:raw]];
    [urls addObject:[@"https://gh.xmly.dev/"  stringByAppendingString:raw]];
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

#pragma mark - 诊断 (v10.1.0)

// 同步探测单个地址 (仅诊断用, 会阻塞; 超时 8 秒)
static NSInteger SVBAuthProbeSync(NSString *urlStr, NSData **outData,
                                  NSString **outErr, double *outSec) {
    if (outData) *outData = nil;
    if (outErr)  *outErr  = nil;
    if (outSec)  *outSec  = 0;

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { if (outErr) *outErr = @"地址非法"; return -1; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 8.0;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    req.HTTPShouldHandleCookies = NO;
    if ([urlStr containsString:@"api.github.com"])
        [req setValue:@"application/vnd.github.raw" forHTTPHeaderField:@"Accept"];

    __block NSData *body = nil;
    __block NSInteger status = 0;
    __block NSString *errStr = nil;
    NSTimeInterval t0 = [[NSDate date] timeIntervalSince1970];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            body = data;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]])
                status = ((NSHTTPURLResponse *)resp).statusCode;
            if (err) errStr = err.localizedDescription;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(14.0 * NSEC_PER_SEC)));

    if (outSec)  *outSec  = [[NSDate date] timeIntervalSince1970] - t0;
    if (outData) *outData = body;
    if (outErr)  *outErr  = errStr;
    return status;
}

static NSString *SVBAuthTimeText(NSTimeInterval ts) {
    if (ts <= 0) return @"从未";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm";
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

NSString *SVBAuthDiagnose(void) {
    NSMutableString *o = [NSMutableString string];
    @try {
        NSString *udid = SVBAuthUDID();
        NSString *mine = SVBAuthDeviceHash() ?: @"";

        [o appendString:@"=== 设备 ===\n"];
        [o appendFormat:@"识别方式 : %@\n", SVBAuthUDIDSource()];
        [o appendFormat:@"UDID     : %@\n", udid.length ? udid : @"读不到"];
        [o appendFormat:@"名单指纹 : %@\n", mine.length ? mine : @"算不出"];
        [o appendString:@"(把上面这行 UDID 整串发给作者即可)\n\n"];

        [o appendString:@"=== 本地 ===\n"];
        [o appendFormat:@"授权状态 : %@\n", SVBAuthStateText(SVBAuthCurrentState(NULL), NULL)];
        [o appendFormat:@"缓存名单 : %ld 台%@\n", (long)SVBAuthCachedCount(),
                         SVBAuthCachedHasSelf(NULL) ? @"（含本机）" : @"（不含本机）"];
        [o appendFormat:@"最后同步 : %@\n", SVBAuthTimeText(SVBAuthLastSyncTime())];
        [o appendFormat:@"离线授权 : %@\n\n", SVBAuthOfflineTicketInfo()];

        [o appendString:@"=== 逐个源实测 ===\n"];
        NSArray<NSString *> *urls = SVBAuthURLs();
        NSString *customU = SVBAuthCustomSourceURL();
        NSString *giteeU  = SVBAuthGiteeURL();
        NSUInteger i = 0;
        for (NSString *u in urls) {
            i++;
            NSData *data = nil; NSString *err = nil; double sec = 0;
            NSInteger st = SVBAuthProbeSync(u, &data, &err, &sec);

            NSString *tag = u;
            if (customU.length && [customU isEqualToString:u])
                tag = [@"[自定义] " stringByAppendingString:u];
            else if (giteeU.length && [giteeU isEqualToString:u])
                tag = [@"[Gitee] " stringByAppendingString:u];
            if (tag.length > 64)
                tag = [@"…" stringByAppendingString:[tag substringFromIndex:tag.length - 62]];

            [o appendFormat:@"%lu) %@\n", (unsigned long)i, tag];
            if (st > 0) {
                [o appendFormat:@"   HTTP %ld · %lu 字节 · %.1fs\n",
                     (long)st, (unsigned long)data.length, sec];
            } else {
                [o appendFormat:@"   连不上：%@（%.1fs）\n", err.length ? err : @"无响应/超时/DNS 失败", sec];
            }

            if (st == 404) {
                [o appendString:@"   → 文件不存在，按“空名单”处理\n"];
            } else if (st == 200 && data.length) {
                NSInteger rts = 0;
                NSDictionary<NSString *, NSNumber *> *m = SVBAuthMapFromJSON(data, &rts);
                if (!m) {
                    [o appendString:@"   → 验签不通过（内容被改过，已忽略）\n"];
                } else {
                    BOOL has = mine.length && [m objectForKey:mine] != nil;
                    [o appendFormat:@"   → 验签通过 · %lu 台 · 版本 %@ · %@\n",
                         (unsigned long)m.count,
                         SVBAuthTimeText((NSTimeInterval)rts),
                         has ? @"✅ 含本机" : @"❌ 不含本机"];
                }
            } else if (st == 403) {
                [o appendString:@"   → 被拒绝(403)，该源不可用\n"];
            }
            [o appendString:@"\n"];
        }

        [o appendString:@"=== 怎么读 ===\n"];
        [o appendString:@"· 全部“连不上” → 本机拉不到任何源：改用 Gitee 地址，或粘贴离线授权串\n"];
        [o appendString:@"· “验签通过 ✅ 含本机”但仍未授权 → 用「立即联网校验」刷一次\n"];
        [o appendString:@"· “验签通过 ❌ 不含本机” → 你的 UDID 不在作者名单里，把 UDID 发给作者\n"];
        [o appendString:@"· “验签不通过” → 名单被改坏了，让作者重新签发一次\n"];
        [o appendFormat:@"\n%@  %@", SVB_VERSION, SVBAuthUDIDSource()];
    } @catch (NSException *e) {
        [o appendFormat:@"诊断异常：%@", e.reason];
    }
    return o;
}
