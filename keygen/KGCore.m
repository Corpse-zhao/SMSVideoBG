#import "KGCore.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <string.h>
#import <time.h>

// 签名密钥: 优先取编译期注入的宏 (CI 从 GitHub Secret 传 -DSVB_LICENSE_SECRET=...);
// 没有注入时用内置兜底值 —— 兜底值随公开源码可见, 仅供本地自测。
#ifndef SVB_LICENSE_SECRET
#define SVB_LICENSE_SECRET "SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"
#endif

NSString *KGCompiledSecret(void) {
    return [NSString stringWithUTF8String:SVB_LICENSE_SECRET];
}

// Crockford 风格 Base32 表 (去掉 I O 0 1 等易混字符), 与插件端/脚本一致
static const char *const kB32Table = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

#define KG_PAYLOAD_LEN 10
#define KG_SIG_LEN      5
#define KG_TOTAL_LEN   15
#define KG_FORMAT_VER  0x01
#define KG_NO_EXPIRE   0xFFFFFFFFu
#define KG_EPOCH       1577836800.0   /* 2020-01-01 00:00:00 UTC */

#pragma mark - Base32

static NSString *KGB32Encode(NSData *data) {
    if (!data.length) return @"";
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    NSMutableString *s = [NSMutableString stringWithCapacity:(n * 8 + 4) / 5];
    uint32_t buf = 0;
    int bits = 0;
    for (NSUInteger i = 0; i < n; i++) {
        buf = ((buf << 8) | b[i]) & 0x1FFFFu;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            [s appendFormat:@"%c", kB32Table[(buf >> bits) & 0x1F]];
        }
    }
    if (bits > 0) [s appendFormat:@"%c", kB32Table[(buf << (5 - bits)) & 0x1F]];
    return s;
}

static NSString *KGClean(NSString *raw) {
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

static NSData *KGB32Decode(NSString *str) {
    NSString *clean = KGClean(str);
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

#pragma mark - 工具

NSString *KGSecretFingerprint(NSString *secret) {
    const char *utf8 = secret.UTF8String;
    if (!utf8) utf8 = "";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:8];
    for (int i = 0; i < 4; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSString *KGDeviceNormalize(NSString *raw) {
    NSString *clean = KGClean(raw);
    if (clean.length != 8) return nil;
    return clean;
}

NSString *KGGrouped(NSString *s) {
    if (s.length != 24) return s;
    NSMutableString *out = [NSMutableString stringWithCapacity:29];
    for (NSUInteger i = 0; i < s.length; i += 4) {
        if (i) [out appendString:@"-"];
        [out appendString:[s substringWithRange:NSMakeRange(i, 4)]];
    }
    return out;
}

uint32_t KGDayIndexFromNow(NSInteger daysFromNow) {
    time_t now = time(NULL);
    long long ts = (long long)now + (long long)daysFromNow * 86400LL;
    long long idx = ((long long)KG_EPOCH < ts) ? (ts - (long long)KG_EPOCH) / 86400LL : -1;
    if (idx <= 0 || idx > (long long)KG_NO_EXPIRE) return 0;   // 0 = 越界 (1970 前或超范围)
    return (uint32_t)idx;
}

NSString *KGDateTextForDayIndex(uint32_t idx) {
    if (idx == KG_NO_EXPIRE) return @"永久";
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd";
    df.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:KG_EPOCH + (NSTimeInterval)idx * 86400.0]];
}

static NSString *KGDateTextForTimestamp(NSTimeInterval ts) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd";
    df.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}

#pragma mark - 签发

NSString *KGBuildCode(NSString *secret, NSString *device, BOOL universal,
                      BOOL forever, NSInteger days,
                      NSString **expiryText, NSString **error) {
    if (expiryText) *expiryText = nil;
    if (error) *error = nil;

    if (secret.length == 0) {
        if (error) *error = @"签名密钥为空, 请先在下方设置";
        return nil;
    }

    uint8_t dev[5] = {0};
    if (!universal) {
        NSString *norm = KGDeviceNormalize(device);
        if (!norm) {
            if (error) *error = @"设备码不合法: 应为 8 位 Base32 字符 (形如 ABCD-EFGH)";
            return nil;
        }
        NSData *d = KGB32Decode(norm);
        if (!d || d.length != 5) {
            if (error) *error = @"设备码解码失败 (应为 5 字节)";
            return nil;
        }
        memcpy(dev, d.bytes, 5);
    }

    uint32_t expDays;
    if (forever) {
        expDays = KG_NO_EXPIRE;
        if (expiryText) *expiryText = @"永久";
    } else {
        if (days <= 0) {
            if (error) *error = @"有效期天数需为正整数, 或打开「永久有效」";
            return nil;
        }
        expDays = KGDayIndexFromNow(days);
        if (expDays == 0) {
            if (error) *error = @"到期时间超出可表示范围";
            return nil;
        }
        if (expiryText) *expiryText = KGDateTextForDayIndex(expDays);
    }

    uint8_t payload[KG_PAYLOAD_LEN] = {0};
    memcpy(payload, dev, 5);
    payload[5] = (uint8_t)((expDays >> 24) & 0xFF);
    payload[6] = (uint8_t)((expDays >> 16) & 0xFF);
    payload[7] = (uint8_t)((expDays >> 8) & 0xFF);
    payload[8] = (uint8_t)(expDays & 0xFF);
    payload[9] = KG_FORMAT_VER;

    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    const char *secUtf8 = secret.UTF8String;
    CCHmac(kCCHmacAlgSHA256, secUtf8, strlen(secUtf8), payload, KG_PAYLOAD_LEN, mac);

    NSMutableData *raw = [NSMutableData dataWithBytes:payload length:KG_PAYLOAD_LEN];
    [raw appendBytes:mac length:KG_SIG_LEN];
    return KGGrouped(KGB32Encode(raw));
}

#pragma mark - 校验

NSString *KGVerifyCode(NSString *secret, NSString *code, NSString *device) {
    if (secret.length == 0) return @"✗ 密钥为空";

    NSData *raw = KGB32Decode(code);
    if (!raw || raw.length != KG_TOTAL_LEN)
        return [NSString stringWithFormat:@"✗ 长度不对 (解码 %lu 字节, 应为 15)", (unsigned long)(raw ? raw.length : 0)];

    const uint8_t *p = raw.bytes;
    NSData *payload = [raw subdataWithRange:NSMakeRange(0, KG_PAYLOAD_LEN)];
    NSData *sig = [raw subdataWithRange:NSMakeRange(KG_PAYLOAD_LEN, KG_SIG_LEN)];

    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    const char *secUtf8 = secret.UTF8String;
    CCHmac(kCCHmacAlgSHA256, secUtf8, strlen(secUtf8), payload.bytes, KG_PAYLOAD_LEN, mac);
    if (memcmp(mac, sig.bytes, KG_SIG_LEN) != 0)
        return @"✗ 签名不匹配 (密钥不同或激活码被改过)";
    if (p[9] != KG_FORMAT_VER)
        return [NSString stringWithFormat:@"✗ 格式版本不支持 (0x%02X)", p[9]];

    BOOL universal = YES;
    for (int i = 0; i < 5; i++) if (p[i] != 0) { universal = NO; break; }

    uint32_t expDays = ((uint32_t)p[5] << 24) | ((uint32_t)p[6] << 16) |
                       ((uint32_t)p[7] << 8) | (uint32_t)p[8];
    NSString *who = universal ? @"通用码" :
        [NSString stringWithFormat:@"绑 %@", KGGrouped(KGB32Encode([NSData dataWithBytes:p length:5]))];

    if (!universal && device.length) {
        NSString *norm = KGDeviceNormalize(device);
        NSData *mine = norm ? KGB32Decode(norm) : nil;
        if (mine && mine.length == 5 && memcmp(mine.bytes, p, 5) != 0)
            return [NSString stringWithFormat:@"✗ 签名有效但设备不匹配 (%@)", who];
    }

    if (expDays == KG_NO_EXPIRE)
        return [NSString stringWithFormat:@"✓ 有效 · 永久 · %@", who];

    NSTimeInterval expTs = KG_EPOCH + (NSTimeInterval)expDays * 86400.0 + 86399.0;
    NSString *txt = KGDateTextForTimestamp(expTs);
    if ([[NSDate date] timeIntervalSince1970] > expTs + 86400.0)
        return [NSString stringWithFormat:@"✗ 已过期 (%@)", txt];
    return [NSString stringWithFormat:@"✓ 有效 · 至 %@ · %@", txt, who];
}
