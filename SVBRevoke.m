#import "SVBRevoke.h"
#import "SVBCommon.h"
#import "SVBLicense.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <string.h>

// 与插件端授权模块 / 签发 App 共用同一把密钥 (CI 从 GitHub Secret 注入)
#ifndef SVB_LICENSE_SECRET
#define SVB_LICENSE_SECRET "SVBG-LICENSE-FALLBACK-INSECURE-SET-CI-SECRET"
#endif
static const char *const kRevokeSecret = SVB_LICENSE_SECRET;

#define SVB_REVOKE_KEY_LIST @"revoke_hashes"      // 缓存: 条目数组
#define SVB_REVOKE_KEY_TS   @"revoke_ts"          // 缓存: 上次成功拉取时间
#define SVB_REVOKE_KEY_TRY  @"revoke_try_ts"      // 缓存: 上次尝试时间 (节流用)
#define SVB_REVOKE_KEY_ECHO @"revoke_echo"        // 控制App: 上次动作结果文案

#define SVB_REVOKE_INTERVAL (30 * 60.0)           // 30 分钟拉一次
#define SVB_REVOKE_TIMEOUT  12.0                  // 单个 URL 超时

#pragma mark - 工具

static NSString *SVBRevokeHexLower(const unsigned char *bytes, int n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (int i = 0; i < n; i++) [s appendFormat:@"%02x", bytes[i]];
    return s;
}

NSString *SVBRevokeHashForCode(NSString *code) {
    NSString *norm = SVBLicenseNormalize(code);
    if (!norm.length) return nil;
    const char *utf8 = norm.UTF8String;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(utf8, (CC_LONG)strlen(utf8), digest);
    return [SVBRevokeHexLower(digest, 8) uppercaseString];
}

NSString *SVBRevokePayloadString(NSInteger ts, NSArray<NSString *> *hashes) {
    NSArray *sorted = [hashes sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"SVBGREVOKE/v1|%ld|%@",
            (long)ts, [sorted componentsJoinedByString:@","]];
}

NSString *SVBRevokeSignatureHex(NSString *payload) {
    if (!payload.length) return @"";
    const char *utf8 = payload.UTF8String;
    unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
    CCHmac(kCCHmacAlgSHA256, kRevokeSecret, strlen(kRevokeSecret), utf8, strlen(utf8), mac);
    return SVBRevokeHexLower(mac, CC_SHA256_DIGEST_LENGTH);
}

NSArray<NSString *> *SVBRevokeHashesFromJSON(NSData *json) {
    if (!json.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)obj;

    NSNumber *ver = d[@"v"];
    NSNumber *ts  = d[@"ts"];
    NSArray  *rev = d[@"revoked"];
    NSString *sig = d[@"sig"];
    if (![ver isKindOfClass:[NSNumber class]] || ver.integerValue != 1) return nil;
    if (![ts isKindOfClass:[NSNumber class]]) return nil;
    if (![rev isKindOfClass:[NSArray class]]) return nil;
    if (![sig isKindOfClass:[NSString class]] || sig.length != 64) return nil;

    NSMutableArray *clean = [NSMutableArray arrayWithCapacity:rev.count];
    for (id h in rev) {
        if (![h isKindOfClass:[NSString class]]) return nil;
        NSString *u = [h uppercaseString];
        if (u.length != 16) return nil;
        for (NSUInteger i = 0; i < u.length; i++) {
            unichar ch = [u characterAtIndex:i];
            if (!((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'F'))) return nil;
        }
        [clean addObject:u];
    }

    NSString *expect = SVBRevokeSignatureHex(SVBRevokePayloadString(ts.integerValue, clean));
    if (![[sig lowercaseString] isEqualToString:expect]) return nil;
    return clean;
}

#pragma mark - 缓存读取

static NSArray<NSString *> *SVBRevokeCachedList(void) {
    id v = nil;
    @try { v = [[SVBManager shared] configValueForKey:SVB_REVOKE_KEY_LIST]; } @catch (NSException *e) {}
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

NSInteger SVBRevokeCachedCount(void) {
    return (NSInteger)SVBRevokeCachedList().count;
}

NSTimeInterval SVBRevokeLastFetchTime(void) {
    id v = nil;
    @try { v = [[SVBManager shared] configValueForKey:SVB_REVOKE_KEY_TS]; } @catch (NSException *e) {}
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
}

BOOL SVBRevokeIsCodeRevoked(NSString *code) {
    NSArray *list = SVBRevokeCachedList();
    if (!list.count) return NO;
    NSString *h = SVBRevokeHashForCode(code);
    if (!h.length) return NO;
    return [list containsObject:h];
}

#pragma mark - 拉取

// 依次尝试的地址 (第一条命中即可)
static NSArray<NSString *> *SVBRevokeURLs(void) {
    NSMutableArray *urls = [NSMutableArray array];
    @try {
        id custom = [[SVBManager shared] configValueForKey:@"revoke_url"];
        if ([custom isKindOfClass:[NSString class]] && [(NSString *)custom length])
            [urls addObject:custom];
    } @catch (NSException *e) {}
    [urls addObject:@"https://api.github.com/repos/Corpse-zhao/SMSVideoBG/contents/revoked.json"];
    [urls addObject:@"https://cdn.jsdelivr.net/gh/Corpse-zhao/SMSVideoBG@main/revoked.json"];
    [urls addObject:@"https://raw.githubusercontent.com/Corpse-zhao/SMSVideoBG/main/revoked.json"];
    return urls;
}

static NSLock *SVBRevokeLock(void) {
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

// 拉取结果处理: 写入缓存 (返回是否结束整条链)
static BOOL SVBRevokeAccept(NSData *body, NSInteger status, NSString *url, SVBManager *mgr, NSTimeInterval now) {
    if (status == 404) {
        // 名单文件还不存在 = 没有任何作废项
        [mgr setConfigValue:@[] forKey:SVB_REVOKE_KEY_LIST];
        [mgr setConfigValue:@(now) forKey:SVB_REVOKE_KEY_TS];
        [mgr log:@"[revoke] 名单文件不存在(404), 按空名单处理 via %@", url];
        return YES;
    }
    if (status != 200 || !body.length) return NO;

    NSArray *hashes = SVBRevokeHashesFromJSON(body);
    if (!hashes) {
        [mgr log:@"[revoke] 名单验签失败, 忽略该响应 via %@ (状态 %ld)", url, (long)status];
        return NO;   // 换下一个源再试
    }
    [mgr setConfigValue:hashes forKey:SVB_REVOKE_KEY_LIST];
    [mgr setConfigValue:@(now) forKey:SVB_REVOKE_KEY_TS];
    [mgr log:@"[revoke] 名单已更新: %lu 条 via %@", (unsigned long)hashes.count, url];
    return YES;
}

// 同步拉取 (在后台队列调用): 逐个 URL 试, 成功即返回
static void SVBRevokeFetchChain(NSArray<NSString *> *urls, NSUInteger idx) {
    if (idx >= urls.count) return;
    NSString *urlStr = urls[idx];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { SVBRevokeFetchChain(urls, idx + 1); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = SVB_REVOKE_TIMEOUT;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    req.HTTPShouldHandleCookies = NO;
    if ([urlStr containsString:@"api.github.com"])
        [req setValue:@"application/vnd.github.raw" forHTTPHeaderField:@"Accept"];

    __block NSData *body = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            body = data;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]])
                status = ((NSHTTPURLResponse *)resp).statusCode;
            if (err) { body = nil; }
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                              (int64_t)((SVB_REVOKE_TIMEOUT + 6.0) * NSEC_PER_SEC)));

    SVBManager *mgr = [SVBManager shared];
    if (SVBRevokeAccept(body, status, urlStr, mgr, [[NSDate date] timeIntervalSince1970])) return;
    SVBRevokeFetchChain(urls, idx + 1);
}

static void SVBRevokeRefreshForce(void);

// 并发标记: 同一时刻只允许一条拉取链在跑
static BOOL gSVBRevokeRunning = NO;

void SVBRevokeRefreshIfNeeded(BOOL force) {
    @try {
        SVBManager *mgr = [SVBManager shared];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        id tryV = [mgr configValueForKey:SVB_REVOKE_KEY_TRY];
        NSTimeInterval lastTry = [tryV respondsToSelector:@selector(doubleValue)] ? [tryV doubleValue] : 0;
        if (!force && lastTry > 0 && now - lastTry < SVB_REVOKE_INTERVAL) return;
        [mgr setConfigValue:@(now) forKey:SVB_REVOKE_KEY_TRY];

        [SVBRevokeLock() lock];
        if (gSVBRevokeRunning) { [SVBRevokeLock() unlock]; return; }
        gSVBRevokeRunning = YES;
        [SVBRevokeLock() unlock];

        SVBRevokeRefreshForce();
    } @catch (NSException *e) {}
}

static void SVBRevokeRefreshForce(void) {
    NSArray *urls = SVBRevokeURLs();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            SVBRevokeFetchChain(urls, 0);
        } @catch (NSException *e) {}
        [SVBRevokeLock() lock];
        gSVBRevokeRunning = NO;
        [SVBRevokeLock() unlock];
    });
}
