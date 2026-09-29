#import "KGAuth.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#include <string.h>
#include <math.h>

#ifndef SVB_LICENSE_SECRET
#define SVB_LICENSE_SECRET "SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"
#endif

static NSString * const kAuthHashPrefix = @"SMSVideoBG-AUTH/v1|";

NSString *KGCompiledSecret(void) { return @SVB_LICENSE_SECRET; }

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

#pragma mark - 白名单 JSON

static NSString *KGAuthPayloadString(NSInteger ts, NSDictionary<NSString *, NSNumber *> *devices) {
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

static NSString *KGAuthSignatureHex(NSString *payload, NSString *secret) {
    if (!payload.length || !secret.length) return @"";
    const char *utf8 = payload.UTF8String;
    const char *key = secret.UTF8String;
    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), utf8, strlen(utf8), mac);
    return KGHexLower(mac, CC_SHA256_DIGEST_LENGTH);
}

NSData *KGAuthBuildJSON(NSString *secret, NSInteger ts, NSDictionary<NSString *, NSNumber *> *devices) {
    if (!secret.length) return nil;
    NSDictionary *clean = devices ?: @{};
    NSString *payload = KGAuthPayloadString(ts, clean);
    NSDictionary *d = @{@"v": @1,
                        @"ts": @(ts),
                        @"devices": clean,
                        @"sig": KGAuthSignatureHex(payload, secret)};
    return [NSJSONSerialization dataWithJSONObject:d
                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                             error:NULL];
}

NSDictionary<NSString *, NSNumber *> *KGAuthParseJSON(NSData *json, NSString *secret) {
    if (!json.length || !secret.length) return nil;
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
    NSString *expect = KGAuthSignatureHex(KGAuthPayloadString(ts.integerValue, clean), secret);
    if (![[sig lowercaseString] isEqualToString:expect]) return nil;
    return clean;
}

#pragma mark - 离线授权串 (v2.1.0)

static NSString *KGAuthOfflinePayload(NSString *h32, uint32_t exp, NSInteger ts) {
    return [NSString stringWithFormat:@"SVBGOFFLINE/v1|%@|%u|%ld",
            h32, (unsigned)exp, (long)ts];
}

NSString *KGAuthBuildOfflineTicket(NSString *secret, NSString *udid, uint32_t dayIndex) {
    if (!secret.length) return nil;
    NSString *h32 = KGAuthHashForUDID(udid);
    if (!h32.length) return nil;

    NSInteger ts = (NSInteger)[[NSDate date] timeIntervalSince1970];
    NSString *sig = KGAuthSignatureHex(KGAuthOfflinePayload(h32, dayIndex, ts), secret);
    NSDictionary *d = @{ @"h": h32, @"e": @(dayIndex), @"t": @(ts), @"s": sig };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingSortedKeys
                                                     error:NULL];
    if (!json.length) return nil;
    return [@"SVBOFFLINE1:" stringByAppendingString:[json base64EncodedStringWithOptions:0]];
}

NSString *KGAuthShortTicket(NSString *ticket) {
    if (!ticket.length) return @"";
    if (ticket.length <= 44) return ticket;
    return [NSString stringWithFormat:@"%@…%@",
            [ticket substringToIndex:26],
            [ticket substringFromIndex:ticket.length - 12]];
}
