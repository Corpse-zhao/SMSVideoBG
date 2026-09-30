#import "KGAuth.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#include <string.h>
#include <math.h>

// 板栗 v3.0.0: 与两版插件共用同一把密钥 (见 KGAuth.h)
#ifndef VIDEOBG_LICENSE_SECRET
#define VIDEOBG_LICENSE_SECRET "VIDEOBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"
#endif

// 指纹前缀 —— 与两版插件端 (SVBAuth.m / MVBAuth.m) **必须完全相同**,
// 否则同一台设备在不同插件里算出的 H32 不同, 授权串就没法通用
static NSString * const kAuthHashPrefix = @"VideoBG-AUTH/v1|";

NSString *KGCompiledSecret(void) { return @VIDEOBG_LICENSE_SECRET; }

// 产品位 -> 人话 (UI 展示用)
NSString *KGProductText(NSString *product) {
    NSString *p = [product lowercaseString];
    if ([p isEqualToString:KG_PRODUCT_SMS])   return @"仅信息视频背景";
    if ([p isEqualToString:KG_PRODUCT_MEMOS]) return @"仅备忘录视频背景";
    return @"通用（信息版+备忘录版）";   // "all" 或空/未知都按通用
}

static NSString *KGHexLower(const unsigned char *bytes, int n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (int i = 0; i < n; i++) [s appendFormat:@"%02x", bytes[i]];
    return s;
}

NSString *KGSecretFingerprint(NSString *secret) {
    if (!secret.length) return @"-";
    const char *utf8 = secret.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    return [[KGHexLower(digest, 4) uppercaseString] substringToIndex:8];
}

NSString *KGAuthNormalizeUDID(NSString *raw) {
    if (!raw.length) return nil;
    NSString *up = [raw uppercaseString];
    NSMutableString *s = [NSMutableString stringWithCapacity:up.length];
    for (NSUInteger i = 0; i < up.length; i++) {
        unichar c = [up characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) [s appendFormat:@"%c", (char)c];
    }
    return s.length ? s : nil;
}

BOOL KGAuthUDIDLooksValid(NSString *udid) {
    NSString *n = KGAuthNormalizeUDID(udid);
    return n.length >= 8 && n.length <= 64;
}

NSString *KGAuthShortUDID(NSString *udid) {
    NSString *n = KGAuthNormalizeUDID(udid);
    if (!n.length) return @"-";
    if (n.length <= 16) return n;
    return [NSString stringWithFormat:@"%@…%@", [n substringToIndex:12], [n substringFromIndex:n.length - 4]];
}

NSString *KGAuthHashForUDID(NSString *udid) {
    NSString *norm = KGAuthNormalizeUDID(udid);
    if (!norm.length) return nil;
    NSString *payload = [kAuthHashPrefix stringByAppendingString:norm];
    const char *utf8 = payload.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02X", digest[i]];
    return hex;
}

#pragma mark - 日期

static NSTimeInterval KGEpoch(void) {
    static NSTimeInterval e = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = 1577836800.0; });   // 2020-01-01 UTC
    return e;
}

uint32_t KGDayIndexFromNow(NSInteger daysFromNow) {
    NSTimeInterval target = [[NSDate date] timeIntervalSince1970] + (NSTimeInterval)daysFromNow * 86400.0;
    if (target < KGEpoch()) return 0;
    double d = floor((target - KGEpoch()) / 86400.0);
    if (d < 0) return 0;
    if (d > 4294967294.0) return 4294967294u;
    return (uint32_t)d;
}

NSString *KGDateTextForDayIndex(uint32_t idx) {
    if (idx == KG_AUTH_FOREVER) return @"永久";
    NSTimeInterval ts = KGEpoch() + (NSTimeInterval)idx * 86400.0 + 86399.0;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd";
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]];
}


#pragma mark - 离线授权串 (v2.1.0)

static NSString *KGAuthOfflinePayload(NSString *prod, NSString *h32, uint32_t exp, NSInteger ts) {
    // 与插件端严格一致: VIDEOBG/v1|<产品位>|<H32>|<e>|<t>
    NSString *p = prod.length ? [prod lowercaseString] : KG_PRODUCT_ALL;
    return [NSString stringWithFormat:@"VIDEOBG/v1|%@|%@|%u|%ld",
            p, h32, (unsigned)exp, (long)ts];
}

// HMAC-SHA256(secret, payload) -> 全 32 字节小写十六进制
// 与插件端 MVBAuth.m 的 MVBAuthSignatureHex 严格一致: 插件端验签用的就是这条原文
static NSString *KGAuthSignatureHex(NSString *payload, NSString *secret) {
    if (!payload.length || !secret.length) return @"";
    const char *key = secret.UTF8String;
    const char *utf8 = payload.UTF8String;
    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), utf8, strlen(utf8), mac);
    return KGHexLower(mac, CC_SHA256_DIGEST_LENGTH);
}

NSString *KGAuthBuildOfflineTicket(NSString *secret, NSString *udid, uint32_t dayIndex,
                                   NSString *product) {
    if (!secret.length) return nil;
    NSString *h32 = KGAuthHashForUDID(udid);
    if (!h32.length) return nil;

    // 产品位: 空/未知按 "all"(通用) —— 保证老调用点不传时行为不变
    NSString *prod = product.length ? [product lowercaseString] : KG_PRODUCT_ALL;
    NSInteger ts = (NSInteger)[[NSDate date] timeIntervalSince1970];
    NSString *sig = KGAuthSignatureHex(KGAuthOfflinePayload(prod, h32, dayIndex, ts), secret);
    NSDictionary *d = @{ @"h": h32, @"e": @(dayIndex), @"t": @(ts),
                         @"s": sig, @"p": prod };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingSortedKeys
                                                     error:NULL];
    if (!json.length) return nil;
    return [@"VIDEOBGOFFLINE1:" stringByAppendingString:[json base64EncodedStringWithOptions:0]];
}

NSString *KGAuthShortTicket(NSString *ticket) {
    if (!ticket.length) return @"";
    if (ticket.length <= 44) return ticket;
    return [NSString stringWithFormat:@"%@…%@",
            [ticket substringToIndex:26],
            [ticket substringFromIndex:ticket.length - 12]];
}
