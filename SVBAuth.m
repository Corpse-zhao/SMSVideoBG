#import "SVBAuth.h"
#import "SVBCommon.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <string.h>
#import <math.h>

// ============================================================
// 授权核心 v10.3.0 —— 纯离线授权串 (零网络)
//   与签发 App (keygen/KGAuth.m) 共用同一把密钥:
//   CI 从 GitHub Secret SVB_LICENSE_SECRET 注入。
// ============================================================

// 与签发 App 共用同一把密钥 (CI 从 GitHub Secret SVB_LICENSE_SECRET 注入)
#ifndef SVB_LICENSE_SECRET
#define SVB_LICENSE_SECRET "SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"
#endif
static const char *const kAuthSecret = SVB_LICENSE_SECRET;

#define SVB_AUTH_KEY_OFFLINE @"auth_offline"  // 离线授权串: {"h","e","t","s","at"}
// 只读遗留: v10.2 及更早版本走在线名单时缓存的 {H32: dayIndex}。
// 本机若曾在线授权过, 这里命中就继续认 (升级不踢人); 之后不再更新,
// 因为 v10.3.0 起插件一个网络请求都不发。
#define SVB_AUTH_KEY_LEGACY_MAP @"auth_map"

// --- 离线授权串 ---
#define SVB_AUTH_TICKET_TAG @"SVBOFFLINE1:"
// 仅用于兼容 v10.1.x 的旧记录 (那种记录没存签名, 本地可被手改, 只能硬截断保平安);
// v10.2.0 起新记录会把整串字段存下来并在每次读取时复验签名, 因此期限由作者自由指定。
#define SVB_AUTH_TICKET_LEGACY_MAX_DAYS 90

// UDID 哈希前缀 (与签发 App 严格一致)
static NSString * const kAuthHashPrefix = @"SMSVideoBG-AUTH/v1|";

// 前置声明: 「判定」区会用到离线串的签名原文构造函数 (定义在后面的「离线授权串」区)
static NSString *SVBAuthOfflinePayload(NSString *h32, uint32_t exp, NSInteger ts);

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

#pragma mark - UDID / 指纹

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

#pragma mark - 签名

static NSString *SVBAuthHexLower(const unsigned char *bytes, int n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (int i = 0; i < n; i++) [s appendFormat:@"%02x", bytes[i]];
    return s;
}

// HMAC-SHA256(secret, payload) -> 全 32 字节小写十六进制
static NSString *SVBAuthSignatureHex(NSString *payload) {
    if (!payload.length) return @"";
    const char *utf8 = payload.UTF8String;
    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    CCHmac(kCCHmacAlgSHA256, kAuthSecret, strlen(kAuthSecret), utf8, strlen(utf8), mac);
    return SVBAuthHexLower(mac, CC_SHA256_DIGEST_LENGTH);
}

#pragma mark - 判定 (纯本地)

// 只读遗留: 早期在线名单缓存里的本机条目 (升级不踢人, 不再更新)
static BOOL SVBAuthLegacyGrant(uint32_t *outExp) {
    id raw = nil;
    @try { raw = [[SVBManager shared] configValueForKey:SVB_AUTH_KEY_LEGACY_MAP]; } @catch (NSException *e) {}
    if (![raw isKindOfClass:[NSDictionary class]]) return NO;
    NSString *hash = SVBAuthDeviceHash();
    if (!hash.length) return NO;
    NSNumber *n = [(NSDictionary *)raw objectForKey:hash];
    if (![n isKindOfClass:[NSNumber class]]) return NO;
    if (outExp) *outExp = (uint32_t)[n unsignedIntValue];
    return YES;
}

// 离线授权串是否有效 (有效时回传到期 dayIndex)
// 记录里存了完整字段(h/e/t/s), 每次读取都复验一次签名 ——
// 因此有效期由作者自由指定, 没有上限; 客户手改 plist 里任何一位都会验签失败。
static BOOL SVBAuthOfflineTicketExp(uint32_t *outExp) {
    id raw = nil;
    @try { raw = [[SVBManager shared] configValueForKey:SVB_AUTH_KEY_OFFLINE]; } @catch (NSException *e) {}
    if (![raw isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *d = (NSDictionary *)raw;

    id e = d[@"e"];
    if (![e respondsToSelector:@selector(unsignedIntValue)]) return NO;
    uint32_t exp = (uint32_t)[e unsignedIntValue];

    NSString *h = d[@"h"];
    NSString *sig = d[@"s"];
    id t = d[@"t"];

    if ([h isKindOfClass:[NSString class]] && h.length &&
        [sig isKindOfClass:[NSString class]] && sig.length &&
        [t respondsToSelector:@selector(integerValue)]) {
        // ---- 新格式: 有签名, 逐次复验 ----
        NSString *mine = SVBAuthDeviceHash();
        if (!mine.length || ![[h uppercaseString] isEqualToString:mine]) return NO;
        NSString *expect = SVBAuthSignatureHex(
            SVBAuthOfflinePayload([h uppercaseString], exp, [t integerValue]));
        if (![[sig lowercaseString] isEqualToString:expect]) return NO;
    } else {
        // ---- v10.1.x 旧格式: 没存签名, 本地可被手改, 只能硬截断保平安 ----
        if (exp == SVB_AUTH_FOREVER) return NO;     // 旧格式不允许永久
        id at = d[@"at"];
        NSTimeInterval imported = [at respondsToSelector:@selector(doubleValue)] ? [at doubleValue] : 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (imported <= 0 || (now - imported) > SVB_AUTH_TICKET_LEGACY_MAX_DAYS * 86400.0) return NO;
        uint32_t cap = SVBAuthDayIndexNow() + SVB_AUTH_TICKET_LEGACY_MAX_DAYS;
        if (exp > cap) exp = cap;
    }

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

    // ① 离线授权串: 纯本地验签 —— v10.3.0 唯一的授权通道
    uint32_t offExp = 0;
    if (SVBAuthOfflineTicketExp(&offExp)) {
        if (detail) *detail = (offExp == SVB_AUTH_FOREVER)
            ? @"永久有效"
            : [NSString stringWithFormat:@"有效期至 %@", SVBAuthDateTextForDayIndex(offExp)];
        return SVBAuthStateAuthorized;
    }

    // ② 只读遗留: 老版本在线名单缓存里如果本来就有本机, 继续认 (不改不写)
    uint32_t legacyExp = 0;
    if (SVBAuthLegacyGrant(&legacyExp)) {
        if (legacyExp == SVB_AUTH_FOREVER) {
            if (detail) *detail = @"永久有效";
            return SVBAuthStateAuthorized;
        }
        if (SVBAuthDayIndexNow() <= legacyExp) {
            if (detail) *detail = [NSString stringWithFormat:@"有效期至 %@",
                                   SVBAuthDateTextForDayIndex(legacyExp)];
            return SVBAuthStateAuthorized;
        }
        if (detail) *detail = [NSString stringWithFormat:@"已于 %@ 到期",
                               SVBAuthDateTextForDayIndex(legacyExp)];
        return SVBAuthStateExpired;
    }

    // ③ 没有有效授权串
    if (detail) *detail = @"尚未导入授权串";
    return SVBAuthStateUnauthorized;
}

// v10.0.1: 缓存挪到文件作用域, 让「导入授权串」可以立即作废它
// (否则导入成功后最长 60 秒内 SVBIsLicensed() 还是旧结论, 用户会以为没生效)
static SVBAuthState gAuthCachedState = SVBAuthStateUnauthorized;
static NSTimeInterval gAuthCachedAt = 0;

void SVBAuthInvalidateCache(void) {
    gAuthCachedState = SVBAuthStateUnauthorized;
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
        default:                       core = @"未授权"; break;
    }
    return detail.length ? [NSString stringWithFormat:@"%@ · %@", core, detail] : core;
}

#pragma mark - 离线授权串

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

        // ③ 期限完全按作者签发的内容 (不再有 90 天上限)
        //    本条记录会把 h/e/t/s 一起存下来, 每次判定都复验签名 ——
        //    客户手改 plist 里任何一位都会验签失败, 记录直接作废。
        uint32_t today = SVBAuthDayIndexNow();
        uint32_t use = want;
        if (use != SVB_AUTH_FOREVER && use < today) {
            fail = @"这段授权串已经过期了";
            break;
        }

        [SVBManager.shared setConfigValue:@{ @"h": [mine uppercaseString],
                                             @"e": @(use),
                                             @"t": tk,
                                             @"s": [sig lowercaseString],
                                             @"at": @([[NSDate date] timeIntervalSince1970]) }
                                   forKey:SVB_AUTH_KEY_OFFLINE];
        SVBAuthInvalidateCache();

        if (message) {
            *message = (use == SVB_AUTH_FOREVER)
                ? @"导入成功，本机已授权（永久有效）。"
                : [NSString stringWithFormat:@"导入成功，本机已授权（有效期至 %@）。",
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

#pragma mark - 诊断 (纯本地, 绝不联网)

NSString *SVBAuthDiagnose(void) {
    NSMutableString *o = [NSMutableString string];
    @try {
        NSString *udid = SVBAuthUDID();
        NSString *mine = SVBAuthDeviceHash() ?: @"";

        [o appendString:@"=== 设备 ===\n"];
        [o appendFormat:@"识别方式 : %@\n", SVBAuthUDIDSource()];
        [o appendFormat:@"UDID     : %@\n", udid.length ? udid : @"读不到"];
        [o appendFormat:@"设备指纹 : %@\n", mine.length ? mine : @"算不出"];
        [o appendString:@"(把 UDID 整串发给作者, 作者会回你一段授权串)\n\n"];

        [o appendString:@"=== 本机授权 ===\n"];
        [o appendFormat:@"授权状态 : %@\n", SVBAuthStateText(SVBAuthCurrentState(NULL), NULL)];
        [o appendFormat:@"离线授权 : %@\n", SVBAuthOfflineTicketInfo()];

        id raw = nil;
        @try { raw = [[SVBManager shared] configValueForKey:SVB_AUTH_KEY_OFFLINE]; } @catch (NSException *e) {}
        if ([raw isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = (NSDictionary *)raw;
            [o appendFormat:@"记录内容 : e=%@ t=%@\n", d[@"e"] ?: @"?", d[@"t"] ?: @"?"];
            [o appendFormat:@"验签结果 : %@\n", SVBAuthOfflineTicketExp(NULL)
                ? @"通过 ✓" : @"不通过 ✗（记录被改过或不属于本机）"];
        } else {
            [o appendString:@"记录内容 : 还没有导入过授权串\n"];
        }

        uint32_t legacy = 0;
        [o appendFormat:@"旧版名单 : %@\n", SVBAuthLegacyGrant(&legacy)
            ? [NSString stringWithFormat:@"本机在旧版在线名单缓存里（至 %@，只读兼容）",
               SVBAuthDateTextForDayIndex(legacy)]
            : @"无"];

        [o appendString:@"\n=== 说明 ===\n"];
        [o appendString:@"· v10.3.0 起插件**不发起任何网络请求**，授权只用离线授权串，"
                    "国内网络直连即可，不需要代理 / 梯子。\n"];
        [o appendString:@"· 未授权 → 点「本机 UDID」复制发给作者，拿到授权串后点「粘贴离线授权」导入。\n"];
        [o appendString:@"· 已过期 → 找作者要一段新的授权串（作者可以自由指定天数）。\n"];
        [o appendString:@"· 导入了仍显示未授权 → 仔细核对 UDID 是否本机的（串只对一台设备有效）。\n"];
        [o appendFormat:@"\n%@  %@", SVB_VERSION, SVBAuthUDIDSource()];
    } @catch (NSException *e) {
        [o appendFormat:@"诊断异常：%@", e.reason];
    }
    return o;
}
