#import "SVBLicense.h"
#import "SVBCommon.h"
#import "SVBRevoke.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <string.h>

// 签名密钥: 优先取编译期注入的宏 (CI 从 GitHub Secret 传 -DSVB_LICENSE_SECRET=...);
// 没有注入时用内置兜底值 —— 兜底值随公开源码可见, 仅供本地自测, 正式分发务必配 Secret。
#ifndef SVB_LICENSE_SECRET
#define SVB_LICENSE_SECRET "SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"
#endif
static const char *const kSVBSecret = SVB_LICENSE_SECRET;

// Crockford 风格 Base32 表 (去掉 I O 0 1 等易混字符), 与 tools/license_gen.py 一致
static const char *const kB32Table = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

#define SVB_LIC_PAYLOAD_LEN 10
#define SVB_LIC_SIG_LEN      5
#define SVB_LIC_TOTAL_LEN   15
#define SVB_LIC_FORMAT_VER  0x01
#define SVB_LIC_NO_EXPIRE   0xFFFFFFFFu
#define SVB_LIC_EPOCH       1577836800.0   /* 2020-01-01 00:00:00 UTC */

#pragma mark - Base32

NSString *SVBLicenseB32Encode(NSData *data) {
    if (!data.length) return @"";
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    NSMutableString *s = [NSMutableString stringWithCapacity:(n * 8 + 4) / 5];
    uint32_t buf = 0;
    int bits = 0;
    for (NSUInteger i = 0; i < n; i++) {
        buf = ((buf << 8) | b[i]) & 0x1FFFFu;   // 保留低位, 防溢出 (bits 最多 12)
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            [s appendFormat:@"%c", kB32Table[(buf >> bits) & 0x1F]];
        }
    }
    if (bits > 0) [s appendFormat:@"%c", kB32Table[(buf << (5 - bits)) & 0x1F]];
    return s;
}

NSString *SVBLicenseNormalize(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || !raw.length) return @"";
    NSString *up = [raw uppercaseString];
    NSMutableString *s = [NSMutableString stringWithCapacity:up.length];
    for (NSUInteger i = 0; i < up.length; i++) {
        unichar c = [up characterAtIndex:i];
        if (c > 127) continue;
        if (strchr(kB32Table, (char)c)) [s appendFormat:@"%c", (char)c];
    }
    return s;
}

NSData *SVBLicenseB32Decode(NSString *str) {
    NSString *clean = SVBLicenseNormalize(str);
    if (!clean.length) return nil;
    NSMutableData *out = [NSMutableData data];
    uint32_t buf = 0;
    int bits = 0;
    for (NSUInteger i = 0; i < clean.length; i++) {
        const char *p = strchr(kB32Table, (char)[clean characterAtIndex:i]);
        if (!p) continue;
        buf = ((buf << 5) | (uint32_t)(p - kB32Table)) & 0x3FFFu;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            uint8_t byte = (uint8_t)((buf >> bits) & 0xFF);
            [out appendBytes:&byte length:1];
        }
    }
    return out.length ? out : nil;
}

#pragma mark - 设备码 (v9.9.11: 硬件标识优先, 兼容历史码)

static NSString *SVBHwMachine(void) {
    char buf[128] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0 || !buf[0]) return @"unknown";
    return [NSString stringWithUTF8String:buf];
}

// 归一化硬件标识: 大写 + 只留 A-Z0-9 (与签发端 KGAlnumUpper 严格一致)
static NSString *SVBAlnumUpper(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || !raw.length) return @"";
    NSString *up = [raw uppercaseString];
    NSMutableString *s = [NSMutableString stringWithCapacity:up.length];
    for (NSUInteger i = 0; i < up.length; i++) {
        unichar c = [up characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) [s appendFormat:@"%c", (char)c];
    }
    return s;
}

// MobileGestalt 读取 (dlopen 方式, 不引入私有框架链接依赖)
static NSString *SVBMobileGestaltString(NSString *key) {
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

// 硬件标识: 依次试 真 UDID -> 硬件序列号; 都读不到返回 nil
// (iOS 7 起公开 API 已无真 UDID, 越狱环境下 MobileGestalt 通常可读)
static NSString *SVBHardwareRawID(void) {
    NSString *udid = SVBMobileGestaltString(@"UniqueDeviceID");
    if (udid.length) return udid;
    NSString *sn = SVBMobileGestaltString(@"SerialNumber");
    if (sn.length) return sn;
    return nil;
}

NSString *SVBHardwareRawIDForDisplay(void) { return SVBHardwareRawID(); }

NSString *SVBHardwareIDSource(void) {
    if (SVBMobileGestaltString(@"UniqueDeviceID").length) return @"硬件 UDID";
    if (SVBMobileGestaltString(@"SerialNumber").length)  return @"硬件序列号";
    return @"IDFV（兼容模式）";
}

// 任意字符串 -> 5 字节指纹 (SHA256 前 5 字节)
static NSData *SVBFingerprint5FromString(NSString *raw) {
    NSString *norm = SVBAlnumUpper(raw);
    if (!norm.length) return nil;
    const char *utf8 = norm.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    return [NSData dataWithBytes:digest length:5];
}

// 硬件指纹: 读得到硬件标识就用它 (换机/重装 App 都不变)
static NSData *SVBHardwareFingerprint5(void) {
    NSString *raw = SVBHardwareRawID();
    return raw.length ? SVBFingerprint5FromString(raw) : nil;
}

// 旧算法 (兼容 v9.9.10 之前签发的激活码): SHA256("SMSVideoBG/v1|<IDFV>|<机型>") 前 5 字节
static NSData *SVBLegacyFingerprint5(void) {
    NSString *idfv = nil;
    @try { idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString]; } @catch (NSException *e) {}
    NSString *raw = [NSString stringWithFormat:@"SMSVideoBG/v1|%@|%@",
                     idfv.length ? idfv : @"no-idfv", SVBHwMachine()];
    const char *utf8 = raw.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    return [NSData dataWithBytes:digest length:5];
}

// 5 字节指纹 -> 显示用设备码 "ABCD-EFGH"
static NSString *SVBCodeFromFingerprint5(NSData *d) {
    if (d.length != 5) return nil;
    NSString *b32 = SVBLicenseB32Encode(d);
    if (b32.length < 8) return nil;
    return [NSString stringWithFormat:@"%@-%@", [b32 substringToIndex:4], [b32 substringFromIndex:4]];
}

// 本机所有可用设备码: 配置里记录的(主码+兼容码) + 现算的(硬件码/旧算法码)
// 只要激活码绑的是其中任意一个, 都算本机 —— 既不打断老客户的授权,
// 又能在重装/换算法后继续用同一台设备。
NSArray<NSString *> *SVBDeviceCodeCandidates(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        SVBManager *mgr = [SVBManager shared];
        id main = [mgr configValueForKey:@"device_code"];
        if ([main isKindOfClass:[NSString class]] && [(NSString *)main length]) [out addObject:main];
        id alts = [mgr configValueForKey:@"device_code_alt"];
        if ([alts isKindOfClass:[NSArray class]]) {
            for (id a in alts) {
                if ([a isKindOfClass:[NSString class]] && [(NSString *)a length] && ![out containsObject:a])
                    [out addObject:a];
            }
        }
    } @catch (NSException *e) {}

    NSString *hw = SVBCodeFromFingerprint5(SVBHardwareFingerprint5());
    if (hw.length && ![out containsObject:hw]) [out addObject:hw];
    NSString *lg = SVBCodeFromFingerprint5(SVBLegacyFingerprint5());
    if (lg.length && ![out containsObject:lg]) [out addObject:lg];
    return out;
}

// 设备绑定比对: 激活码里的 5 字节命中任一候选即通过
static BOOL SVBDevicePayloadMatches(const uint8_t *p5) {
    NSArray *cands = SVBDeviceCodeCandidates();
    for (NSString *c in cands) {
        NSData *d = SVBLicenseB32Decode(c);
        if (d.length == 5 && memcmp(d.bytes, p5, 5) == 0) return YES;
    }
    return NO;
}

NSString *SVBDeviceCode(void) {
    NSString *s = nil;
    @try {
        id v = [[SVBManager shared] configValueForKey:@"device_code"];
        if ([v isKindOfClass:[NSString class]]) s = SVBLicenseNormalize(v);
    } @catch (NSException *e) {}
    if (s.length != 8) return nil;
    return [NSString stringWithFormat:@"%@-%@", [s substringToIndex:4], [s substringFromIndex:4]];
}

NSString *SVBDeviceCodeEnsure(void) {
    // 主码: 硬件码优先, 读不到硬件标识则退回旧算法
    NSString *primary = SVBCodeFromFingerprint5(SVBHardwareFingerprint5());
    if (!primary.length) primary = SVBCodeFromFingerprint5(SVBLegacyFingerprint5());
    if (!primary.length) return SVBDeviceCode();

    @try {
        SVBManager *mgr = [SVBManager shared];

        // 兼容码集合: 历史主码 + 历史兼容码 + 旧算法码 (全部保留, 老激活码继续有效)
        NSMutableArray *alts = [NSMutableArray array];
        id cur = [mgr configValueForKey:@"device_code"];
        if ([cur isKindOfClass:[NSString class]] && [(NSString *)cur length] &&
            ![(NSString *)cur isEqualToString:primary]) [alts addObject:cur];
        id oldAlts = [mgr configValueForKey:@"device_code_alt"];
        if ([oldAlts isKindOfClass:[NSArray class]]) {
            for (id a in oldAlts) {
                if ([a isKindOfClass:[NSString class]] && [(NSString *)a length] &&
                    ![(NSString *)a isEqualToString:primary] && ![alts containsObject:a]) [alts addObject:a];
            }
        }
        NSString *legacy = SVBCodeFromFingerprint5(SVBLegacyFingerprint5());
        if (legacy.length && ![legacy isEqualToString:primary] && ![alts containsObject:legacy])
            [alts addObject:legacy];

        BOOL needWrite = !([cur isKindOfClass:[NSString class]] &&
                           [(NSString *)cur isEqualToString:primary]);
        if (needWrite) [mgr setConfigValue:primary forKey:@"device_code"];
        if (alts.count) [mgr setConfigValue:alts forKey:@"device_code_alt"];

        NSString *raw = SVBHardwareRawID();
        if (raw.length) [mgr setConfigValue:raw forKey:@"device_raw_id"];
    } @catch (NSException *e) {}
    return primary;
}

#pragma mark - 校验

static uint32_t SVBReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

SVBLicenseState SVBLicenseVerify(NSString *code, NSString **detail) {
    if (detail) *detail = nil;

    NSData *raw = SVBLicenseB32Decode(code);
    if (!raw || raw.length != SVB_LIC_TOTAL_LEN) return SVBLicenseStateInvalid;
    const uint8_t *p = raw.bytes;
    if (p[9] != SVB_LIC_FORMAT_VER) return SVBLicenseStateInvalid;

    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    CCHmac(kCCHmacAlgSHA256, kSVBSecret, strlen(kSVBSecret), p, SVB_LIC_PAYLOAD_LEN, mac);
    if (memcmp(mac, p + SVB_LIC_PAYLOAD_LEN, SVB_LIC_SIG_LEN) != 0)
        return SVBLicenseStateInvalid;

    // 设备绑定 (全 0 = 通用码); v9.9.11: 硬件码/历史码任一命中即算本机
    BOOL universal = YES;
    for (int i = 0; i < 5; i++) if (p[i] != 0) { universal = NO; break; }
    if (!universal && !SVBDevicePayloadMatches(p)) return SVBLicenseStateWrongDevice;

    // 到期时间
    uint32_t days = SVBReadBE32(p + 5);
    if (days == SVB_LIC_NO_EXPIRE) {
        if (detail) *detail = @"永久";
        return SVBLicenseStateValid;
    }
    NSTimeInterval expiry = SVB_LIC_EPOCH + (NSTimeInterval)days * 86400.0 + 86399.0;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd";
    df.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    if (detail) *detail = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:expiry]];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now > expiry + 86400.0) return SVBLicenseStateExpired;   // 1 天宽限
    return SVBLicenseStateValid;
}

SVBLicenseState SVBLicenseCurrentState(NSString **detail) {
    if (detail) *detail = nil;

    NSString *code = nil;
    @try {
        id v = [[SVBManager shared] configValueForKey:@"license_code"];
        if ([v isKindOfClass:[NSString class]]) code = v;
    } @catch (NSException *e) {}
    if (SVBLicenseNormalize(code).length == 0) return SVBLicenseStateUnlicensed;

    NSString *det = nil;
    SVBLicenseState st = SVBLicenseVerify(code, &det);

    // v9.9.10: 远程作废名单优先判定 —— 签名/设备/到期都通过, 但作者已把码作废
    if (st == SVBLicenseStateValid && SVBRevokeIsCodeRevoked(code)) {
        if (detail) *detail = det;
        return SVBLicenseStateRevoked;
    }

    if (st == SVBLicenseStateValid) {
        // 防「改系统时间续期」: 记录见过的最大时间, 时间被回拨 > 2 天即判异常
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        id lastV = nil;
        @try { lastV = [[SVBManager shared] configValueForKey:@"license_last_seen"]; } @catch (NSException *e) {}
        NSTimeInterval last = (lastV && [lastV respondsToSelector:@selector(doubleValue)]) ? [lastV doubleValue] : 0;
        if (last > 0 && now + 2 * 86400.0 < last) {
            if (detail) *detail = det;
            return SVBLicenseStateClockTamper;
        }
        if (now > last + 3600.0) {   // 每小时最多写一次, 降 IO
            @try { [[SVBManager shared] setConfigValue:@(now) forKey:@"license_last_seen"]; } @catch (NSException *e) {}
        }
    }
    if (detail) *detail = det;
    return st;
}

BOOL SVBIsLicensed(void) {
    static SVBLicenseState cached = (SVBLicenseState)-1;
    static NSTimeInterval cachedAt = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (cached < 0 || now - cachedAt > 60.0) {
        cached = SVBLicenseCurrentState(NULL);
        cachedAt = now;
    }
    return cached == SVBLicenseStateValid;
}

#pragma mark - 展示

NSString *SVBLicenseStateText(SVBLicenseState st, NSString *detail) {
    switch (st) {
        case SVBLicenseStateValid:
            if (detail.length && ![detail isEqualToString:@"永久"])
                return [NSString stringWithFormat:@"已激活 · 有效期至 %@", detail];
            return @"已激活 · 永久有效";
        case SVBLicenseStateExpired:
            return detail.length ? [NSString stringWithFormat:@"已过期（%@）", detail] : @"已过期";
        case SVBLicenseStateWrongDevice:
            return @"设备不匹配";
        case SVBLicenseStateInvalid:
            return @"激活码无效";
        case SVBLicenseStateClockTamper:
            return @"系统时间异常";
        case SVBLicenseStateRevoked:
            return @"已作废 · 授权已被取消";
        case SVBLicenseStateUnlicensed:
        default:
            return @"未激活";
    }
}

#pragma mark - 授权凭证 (v9.9.12)

static NSString *SVBHexUpper(const uint8_t *b, NSUInteger n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02X", b[i]];
    return s;
}

// 凭证签名原文 (与签发端 KGReceiptPayloadString 严格一致)
static NSString *SVBReceiptPayload(NSString *dev8, NSString *code24, NSTimeInterval ts) {
    return [NSString stringWithFormat:@"SVBACTIVATE/v1|%@|%@|%.0f", dev8, code24, ts];
}

NSString *SVBActivationReceipt(void) {
    // 只有当前真的处于「已激活」才出凭证 (已作废 / 已过期 / 设备不符都不出)
    if (!SVBIsLicensed()) return nil;

    NSString *code = nil;
    NSTimeInterval firstSeen = 0;
    @try {
        SVBManager *mgr = [SVBManager shared];
        id v = [mgr configValueForKey:@"license_code"];
        if ([v isKindOfClass:[NSString class]]) code = SVBLicenseNormalize(v);
        id f = [mgr configValueForKey:@"license_first_seen"];
        if (f && [f respondsToSelector:@selector(doubleValue)]) firstSeen = [f doubleValue];
    } @catch (NSException *e) {}
    if (code.length != 24) return nil;

    NSString *devNorm = SVBLicenseNormalize(SVBDeviceCodeEnsure());
    if (devNorm.length != 8) return nil;

    // 首次激活时间: 控制 App 保存激活码时会写; 老用户升级上来则此时补记一次
    if (firstSeen <= 0) {
        firstSeen = [[NSDate date] timeIntervalSince1970];
        @try { [[SVBManager shared] setConfigValue:@(firstSeen) forKey:@"license_first_seen"]; } @catch (NSException *e) {}
    }

    NSString *payload = SVBReceiptPayload(devNorm, code, firstSeen);
    const char *utf8 = payload.UTF8String;
    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    CCHmac(kCCHmacAlgSHA256, kSVBSecret, strlen(kSVBSecret), utf8, strlen(utf8), mac);

    return [NSString stringWithFormat:@"SMSVideoBG-ACT1|%@|%@|%.0f|%@",
            devNorm, code, firstSeen, SVBHexUpper(mac, 8)];
}
