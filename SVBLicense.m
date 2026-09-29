#import "SVBLicense.h"
#import "SVBCommon.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
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

#pragma mark - 设备码

static NSString *SVBHwMachine(void) {
    char buf[128] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0 || !buf[0]) return @"unknown";
    return [NSString stringWithUTF8String:buf];
}

// 设备指纹 = SHA256("SMSVideoBG/v1|<IDFV>|<机型>") 前 5 字节
static NSData *SVBDeviceFingerprint5(void) {
    NSString *idfv = nil;
    @try { idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString]; } @catch (NSException *e) {}
    NSString *raw = [NSString stringWithFormat:@"SMSVideoBG/v1|%@|%@",
                     idfv.length ? idfv : @"no-idfv", SVBHwMachine()];
    const char *utf8 = raw.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    return [NSData dataWithBytes:digest length:5];
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
    NSString *c = SVBDeviceCode();
    if (c) return c;
    NSString *b32 = SVBLicenseB32Encode(SVBDeviceFingerprint5());
    if (b32.length < 8) return nil;
    NSString *code = [NSString stringWithFormat:@"%@-%@", [b32 substringToIndex:4], [b32 substringFromIndex:4]];
    @try { [[SVBManager shared] setConfigValue:code forKey:@"device_code"]; } @catch (NSException *e) {}
    return code;
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

    // 设备绑定 (全 0 = 通用码)
    BOOL universal = YES;
    for (int i = 0; i < 5; i++) if (p[i] != 0) { universal = NO; break; }
    if (!universal) {
        NSString *mine = SVBDeviceCode();
        NSData *mineData = mine ? SVBLicenseB32Decode(mine) : nil;
        if (!mineData || mineData.length != 5 || memcmp(mineData.bytes, p, 5) != 0)
            return SVBLicenseStateWrongDevice;
    }

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
        case SVBLicenseStateUnlicensed:
        default:
            return @"未激活";
    }
}
