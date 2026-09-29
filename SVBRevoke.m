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
#define SVB_RENEW_KEY_MAP   @"renew_map"          // v9.9.14 缓存: 续签表 {旧码hash: 新码}
#define SVB_GRANT_KEY_MAP   @"grant_map"          // v9.9.15 缓存: 改签表 {码hash: 到期dayIndex}

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

#pragma mark - 远程续签表 (v9.9.14)

// 签名原文: "SVBGRENEW/v1|<ts>|<hash=新码 升序逗号连接>" (与签发 App 严格一致)
static NSString *SVBRenewPayloadString(NSInteger ts, NSDictionary<NSString *, NSString *> *renew) {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *h in renew) {
        if (![h isKindOfClass:[NSString class]]) continue;
        id c = [renew objectForKey:h];
        if (![c isKindOfClass:[NSString class]]) continue;
        NSString *cn = SVBLicenseNormalize((NSString *)c);
        NSString *hu = [(NSString *)h uppercaseString];
        if (hu.length != 16 || cn.length != 24) continue;
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", hu, cn]];
    }
    [pairs sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"SVBGRENEW/v1|%ld|%@",
            (long)ts, [pairs componentsJoinedByString:@","]];
}

// 解析并验签续签表; 通过返回 {旧码hash: 新码24字符}, 否则 nil
static NSDictionary<NSString *, NSString *> *SVBRenewMapFromJSON(NSData *json) {
    if (!json.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)obj;
    NSNumber *ver = d[@"v"], *ts = d[@"ts"];
    NSDictionary *renew = d[@"renew"];
    NSString *sig = d[@"sig"];
    if (![ver isKindOfClass:[NSNumber class]] || ver.integerValue != 1) return nil;
    if (![ts isKindOfClass:[NSNumber class]]) return nil;
    if (![renew isKindOfClass:[NSDictionary class]]) return nil;
    if (![sig isKindOfClass:[NSString class]] || sig.length != 64) return nil;

    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (NSString *h in renew) {
        if (![h isKindOfClass:[NSString class]] || h.length != 16) return nil;
        id c = [renew objectForKey:h];
        if (![c isKindOfClass:[NSString class]]) return nil;
        NSString *cn = SVBLicenseNormalize((NSString *)c);
        if (cn.length != 24) return nil;
        [clean setObject:cn forKey:[h uppercaseString]];
    }
    NSString *expect = SVBRevokeSignatureHex(SVBRenewPayloadString(ts.integerValue, clean));
    if (![[sig lowercaseString] isEqualToString:expect]) return nil;
    return clean;
}

static NSDictionary<NSString *, NSString *> *SVBRenewCachedMap(void) {
    id v = nil;
    @try { v = [[SVBManager shared] configValueForKey:SVB_RENEW_KEY_MAP]; } @catch (NSException *e) {}
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

NSInteger SVBRevokeCachedRenewCount(void) {
    return (NSInteger)SVBRenewCachedMap().count;
}

// 应用续签表: 本机激活码命中旧码 -> 自动换新码 (对方无需重新输入)
BOOL SVBRevokeApplyRenewal(void) {
    @try {
        SVBManager *mgr = [SVBManager shared];
        id v = [mgr configValueForKey:@"license_code"];
        NSString *code = [v isKindOfClass:[NSString class]] ? SVBLicenseNormalize(v) : @"";
        if (code.length != 24) return NO;

        NSString *h = SVBRevokeHashForCode(code);
        if (h.length != 16) return NO;
        NSDictionary *map = SVBRenewCachedMap();
        NSString *newCode = [map objectForKey:h];
        if (![newCode isKindOfClass:[NSString class]]) return NO;
        newCode = SVBLicenseNormalize(newCode);
        if (newCode.length != 24 || [newCode isEqualToString:code]) return NO;

        // 新码必须: 签名合法 + 绑定本机(或通用) + 未被作废
        if (SVBLicenseVerify(newCode, NULL) != SVBLicenseStateValid) {
            [mgr log:@"[renew] 远端续签表命中, 但新码校验未通过, 忽略"];
            return NO;
        }
        if (SVBRevokeIsCodeRevoked(newCode)) {
            [mgr log:@"[renew] 远端续签表命中, 但新码已被作废, 忽略"];
            return NO;
        }
        [mgr setConfigValue:newCode forKey:@"license_code"];
        [mgr log:@"[renew] 远程续签生效: %@… -> %@…",
                 [code substringToIndex:12], [newCode substringToIndex:12]];
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

#pragma mark - 远程改签表 (v9.9.15)

// 签名原文: "SVBGLICENSE/v1|<ts>|<hash=dayIndex 升序逗号连接>" (与签发 App 严格一致)
static NSString *SVBGrantPayloadString(NSInteger ts, NSDictionary<NSString *, NSNumber *> *grants) {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *h in grants) {
        if (![h isKindOfClass:[NSString class]]) continue;
        id v = [grants objectForKey:h];
        if (![v respondsToSelector:@selector(longLongValue)]) continue;
        long long n = [v longLongValue];
        NSString *hu = [(NSString *)h uppercaseString];
        if (hu.length != 16 || n <= 0 || n > 0xFFFFFFFFLL) continue;
        [pairs addObject:[NSString stringWithFormat:@"%@=%llu", hu, n]];
    }
    [pairs sortUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"SVBGLICENSE/v1|%ld|%@",
            (long)ts, [pairs componentsJoinedByString:@","]];
}

// 解析并验签改签表; 通过返回 {码hash: dayIndex}, 否则 nil
static NSDictionary<NSString *, NSNumber *> *SVBGrantMapFromJSON(NSData *json) {
    if (!json.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)obj;
    NSNumber *ver = d[@"v"], *ts = d[@"ts"];
    NSDictionary *grants = d[@"grants"];
    NSString *sig = d[@"sig"];
    if (![ver isKindOfClass:[NSNumber class]] || ver.integerValue != 1) return nil;
    if (![ts isKindOfClass:[NSNumber class]]) return nil;
    if (![grants isKindOfClass:[NSDictionary class]]) return nil;
    if (![sig isKindOfClass:[NSString class]] || sig.length != 64) return nil;

    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (NSString *h in grants) {
        if (![h isKindOfClass:[NSString class]] || h.length != 16) return nil;
        id v = [grants objectForKey:h];
        if (![v isKindOfClass:[NSNumber class]]) return nil;
        long long n = [v longLongValue];
        if (n <= 0 || n > 0xFFFFFFFFLL) return nil;
        [clean setObject:@(n) forKey:[h uppercaseString]];
    }
    NSString *expect = SVBRevokeSignatureHex(SVBGrantPayloadString(ts.integerValue, clean));
    if (![[sig lowercaseString] isEqualToString:expect]) return nil;
    return clean;
}

static NSDictionary<NSString *, NSNumber *> *SVBGrantCachedMap(void) {
    id v = nil;
    @try { v = [[SVBManager shared] configValueForKey:SVB_GRANT_KEY_MAP]; } @catch (NSException *e) {}
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

NSInteger SVBRevokeCachedGrantCount(void) {
    return (NSInteger)SVBGrantCachedMap().count;
}

uint32_t SVBRevokeGrantForCode(NSString *code) {
    NSString *norm = SVBLicenseNormalize(code);
    if (norm.length != 24) return 0;
    NSString *h = SVBRevokeHashForCode(norm);
    if (h.length != 16) return 0;
    NSNumber *g = [SVBGrantCachedMap() objectForKey:h];
    if (![g respondsToSelector:@selector(longLongValue)]) return 0;
    long long n = [g longLongValue];
    if (n <= 0 || n > 0xFFFFFFFFLL) return 0;
    return (uint32_t)n;
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

// 依次尝试的地址 (第一条命中即可); kind = 名单文件名
static NSArray<NSString *> *SVBRevokeURLs(NSString *filename) {
    NSMutableArray *urls = [NSMutableArray array];
    @try {
        id custom = [[SVBManager shared] configValueForKey:@"revoke_url"];
        if ([custom isKindOfClass:[NSString class]] && [(NSString *)custom length])
            [urls addObject:custom];
    } @catch (NSException *e) {}
    // 名单放在 revoke 分支 (独立于代码分支, 代码全量推送不会顶掉它)
    NSString *base = @"Corpse-zhao/SMSVideoBG";
    [urls addObject:[NSString stringWithFormat:
        @"https://api.github.com/repos/%@/contents/%@?ref=revoke", base, filename]];
    [urls addObject:[NSString stringWithFormat:
        @"https://cdn.jsdelivr.net/gh/%@@revoke/%@", base, filename]];
    [urls addObject:[NSString stringWithFormat:
        @"https://raw.githubusercontent.com/%@/revoke/%@", base, filename]];
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

// 通用拉取链 (在后台队列调用): 逐个 URL 试, accept 处理结果, 返回 YES 即停
// v9.9.14: 改为回调式, 作废名单 / 续签表两条链共用
static void SVBFetchChain(NSArray<NSString *> *urls, NSUInteger idx,
                          BOOL (^accept)(NSData *body, NSInteger status, NSString *url)) {
    if (idx >= urls.count) return;
    NSString *urlStr = urls[idx];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { SVBFetchChain(urls, idx + 1, accept); return; }

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

    if (accept(body, status, urlStr)) return;
    SVBFetchChain(urls, idx + 1, accept);
}

#pragma mark - 凭证自动上报 (v9.9.16)

// 客户侧自动把授权凭证 (SMSVideoBG-ACT1|...) 上报到作者的私有仓库,
// 作者签发 App 「☁️ 拉取云端凭证」一键收进台账 —— 客户不用再手动发凭证。
// 上传令牌: fine-grained PAT, 只授权 SMSVideoBG-Receipts 的 Contents 读写,
// 编译期从 GitHub Secret SVB_UPLOAD_TOKEN 注入 (仓库公开, 令牌泄露最多被
// 清空凭证表, 碰不到主仓库的作废/改签名单, 不影响授权体系)。
#ifndef SVB_UPLOAD_TOKEN
#define SVB_UPLOAD_TOKEN ""
#endif

#define SVB_RCP_KEY_TS @"receipt_report_ts"     // 节流: 上次尝试时间
#define SVB_RCP_REPO   @"Corpse-zhao/SMSVideoBG-Receipts"

// 签名原文: "SVBGRCP/v1|<ts>|<凭证行 升序逗号连接>" (与签发 App KGReceiptsParseJSON 严格一致)
static NSString *SVBRcptPayloadString(NSInteger ts, NSArray<NSString *> *lines) {
    NSArray *sorted = [lines sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"SVBGRCP/v1|%ld|%@",
            (long)ts, [sorted componentsJoinedByString:@","]];
}

// 解析并验签云端凭证表; 通过返回 {设备码8: 凭证行}, 否则 nil
static NSDictionary<NSString *, NSString *> *SVBRcptMapFromJSON(NSData *json) {
    if (!json.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)obj;
    NSNumber *ver = d[@"v"], *ts = d[@"ts"];
    NSDictionary *rc = d[@"receipts"];
    NSString *sig = d[@"sig"];
    if (![ver isKindOfClass:[NSNumber class]] || ver.integerValue != 1) return nil;
    if (![ts isKindOfClass:[NSNumber class]]) return nil;
    if (![rc isKindOfClass:[NSDictionary class]]) return nil;
    if (![sig isKindOfClass:[NSString class]] || sig.length != 64) return nil;

    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *k in rc) {
        if (![k isKindOfClass:[NSString class]] || k.length != 8) return nil;
        id v = [rc objectForKey:k];
        if (![v isKindOfClass:[NSString class]]) return nil;
        NSString *line = (NSString *)v;
        if (![line hasPrefix:@"SMSVideoBG-ACT1|"]) return nil;
        NSArray *f = [line componentsSeparatedByString:@"|"];
        if (f.count < 5 || ![[f[1] stringByReplacingOccurrencesOfString:@"-"
                                                         withString:@""].uppercaseString isEqualToString:k])
            return nil;
        [lines addObject:line];
    }
    NSString *expect = SVBRevokeSignatureHex(SVBRcptPayloadString(ts.integerValue, lines));
    if (![[sig lowercaseString] isEqualToString:expect]) return nil;
    return rc;
}

static NSData *SVBRcptBuildJSON(NSInteger ts, NSDictionary<NSString *, NSString *> *receipts) {
    NSDictionary *d = @{@"v": @1,
                        @"ts": @(ts),
                        @"receipts": receipts,
                        @"sig": SVBRevokeSignatureHex(SVBRcptPayloadString(ts,
                            [receipts allValues]))};
    return [NSJSONSerialization dataWithJSONObject:d
                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                             error:NULL];
}

// 同步上报 (在后台队列调用): GET 现表 -> 验签合并本机凭证 -> PUT 覆盖
static void SVBRevokeReportReceipt(void) {
    @try {
        NSString *token = @SVB_UPLOAD_TOKEN;
        if (token.length == 0) return;                       // 未配置上传令牌: 静默跳过
        SVBManager *mgr = [SVBManager shared];
        if (SVBLicenseCurrentState(NULL) != SVBLicenseStateValid) return;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

        // 注意: 不用 SVBActivationReceipt() —— 它内部走 SVBDeviceCodeEnsure()
        // (会写共享配置, 仅供控制App 调用)。插件进程只读设备码 + 自拼凭证行,
        // 与 SVBLicense.m 的格式严格一致: SMSVideoBG-ACT1|dev|code|ts|sig16
        NSString *code = nil;
        NSTimeInterval firstSeen = 0;
        id v = [mgr configValueForKey:@"license_code"];
        if ([v isKindOfClass:[NSString class]]) code = SVBLicenseNormalize(v);
        id fv = [mgr configValueForKey:@"license_first_seen"];
        if ([fv respondsToSelector:@selector(doubleValue)]) firstSeen = [fv doubleValue];
        if (firstSeen <= 0) firstSeen = now;                 // 只用不落盘, 避免插件进程写配置
        NSString *dev = SVBLicenseNormalize(SVBDeviceCode());
        if (code.length != 24 || dev.length != 8) return;

        NSString *payload = [NSString stringWithFormat:@"SVBACTIVATE/v1|%@|%@|%.0f", dev, code, firstSeen];
        const char *utf8 = payload.UTF8String;
        unsigned char mac[CC_SHA256_DIGEST_LENGTH] = {0};
        CCHmac(kCCHmacAlgSHA256, kRevokeSecret, strlen(kRevokeSecret), utf8, strlen(utf8), mac);
        NSString *sig = [[SVBRevokeHexLower(mac, 8) uppercaseString] substringToIndex:16];
        NSString *receipt = [NSString stringWithFormat:@"SMSVideoBG-ACT1|%@|%@|%.0f|%@",
                             dev, code, firstSeen, sig];

        // 每天最多尝试一次
        id tsv = nil;
        @try { tsv = [mgr configValueForKey:SVB_RCP_KEY_TS]; } @catch (NSException *e) {}
        NSTimeInterval last = [tsv respondsToSelector:@selector(doubleValue)] ? [tsv doubleValue] : 0;
        if (last > 0 && now - last < 86400.0) return;
        [mgr setConfigValue:@(now) forKey:SVB_RCP_KEY_TS];

        NSString *apiURL = [NSString stringWithFormat:
            @"https://api.github.com/repos/%@/contents/receipts.json", SVB_RCP_REPO];

        // GET (JSON accept 拿 sha + base64 内容)
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:apiURL]];
        req.timeoutInterval = SVB_REVOKE_TIMEOUT;
        req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

        __block NSData *resp = nil;
        __block NSInteger status = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                resp = d;
                if ([r isKindOfClass:[NSHTTPURLResponse class]])
                    status = ((NSHTTPURLResponse *)r).statusCode;
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                  (int64_t)((SVB_REVOKE_TIMEOUT + 6.0) * NSEC_PER_SEC)));
        if (status != 200 && status != 404) {
            [mgr log:@"[rcpt] 上报失败: HTTP %ld", (long)status];
            return;
        }

        // 现表: 404 = 空; 验签不过则丢弃 (只用本机凭证重建, 自愈)
        NSMutableDictionary<NSString *, NSString *> *receipts = [NSMutableDictionary dictionary];
        NSString *sha = nil;
        if (status == 200 && resp.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:resp options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *meta = (NSDictionary *)obj;
                if ([meta[@"sha"] isKindOfClass:[NSString class]]) sha = meta[@"sha"];
                if ([meta[@"content"] isKindOfClass:[NSString class]]) {
                    NSString *b64 = [(NSString *)meta[@"content"]
                        stringByReplacingOccurrencesOfString:@"\n" withString:@""];
                    NSData *raw = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
                    NSDictionary *old = SVBRcptMapFromJSON(raw);
                    if (old) [receipts addEntriesFromDictionary:old];
                }
            }
        }

        if ([receipts objectForKey:dev] && [[receipts objectForKey:dev] isEqualToString:receipt]) {
            [mgr log:@"[rcpt] 云端凭证已是最新"];
            return;
        }
        [receipts setObject:receipt forKey:dev];

        NSData *body = SVBRcptBuildJSON((NSInteger)now, receipts);
        NSString *b64 = [body base64EncodedStringWithOptions:0];
        NSMutableDictionary *put = [NSMutableDictionary dictionaryWithDictionary:
            @{@"message": @"report receipt",
              @"content": b64,
              @"branch":  @"main"}];
        if (sha.length) put[@"sha"] = sha;

        NSData *putBody = [NSJSONSerialization dataWithJSONObject:put options:0 error:NULL];
        NSMutableURLRequest *preq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:apiURL]];
        preq.HTTPMethod = @"PUT";
        preq.timeoutInterval = SVB_REVOKE_TIMEOUT;
        preq.HTTPBody = putBody;
        [preq setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [preq setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
        [preq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        __block NSInteger pstatus = 0;
        dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
        NSURLSessionDataTask *ptask = [[NSURLSession sharedSession]
            dataTaskWithRequest:preq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                if ([r isKindOfClass:[NSHTTPURLResponse class]])
                    pstatus = ((NSHTTPURLResponse *)r).statusCode;
                dispatch_semaphore_signal(sem2);
            }];
        [ptask resume];
        dispatch_semaphore_wait(sem2, dispatch_time(DISPATCH_TIME_NOW,
                                                   (int64_t)((SVB_REVOKE_TIMEOUT + 6.0) * NSEC_PER_SEC)));

        if (pstatus == 200 || pstatus == 201)
            [mgr log:@"[rcpt] 授权凭证已自动上报 (%lu 台设备在云端)", (unsigned long)receipts.count];
        else
            [mgr log:@"[rcpt] 上报失败: HTTP %ld", (long)pstatus];
    } @catch (NSException *e) {}
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            SVBManager *mgr = [SVBManager shared];
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

            // 链 1: 作废名单
            SVBFetchChain(SVBRevokeURLs(@"revoked.json"), 0,
                ^BOOL(NSData *body, NSInteger status, NSString *url) {
                    return SVBRevokeAccept(body, status, url, mgr, now);
                });

            // 链 2 (v9.9.14): 续签表 {旧码hash: 新码}, 拉到即自动换码
            SVBFetchChain(SVBRevokeURLs(@"renewals.json"), 0,
                ^BOOL(NSData *body, NSInteger status, NSString *url) {
                    if (status == 404) {
                        [mgr setConfigValue:@{} forKey:SVB_RENEW_KEY_MAP];
                        [mgr log:@"[renew] 续签表不存在(404), 按空表处理 via %@", url];
                        return YES;
                    }
                    if (status != 200 || !body.length) return NO;
                    NSDictionary *map = SVBRenewMapFromJSON(body);
                    if (!map) {
                        [mgr log:@"[renew] 续签表验签失败, 忽略 via %@", url];
                        return NO;
                    }
                    [mgr setConfigValue:map forKey:SVB_RENEW_KEY_MAP];
                    [mgr log:@"[renew] 续签表已更新: %lu 条 via %@",
                             (unsigned long)map.count, url];
                    return YES;
                });

            // 链 3 (v9.9.15): 改签表 {码hash: 到期dayIndex}, 作者远程改授权时间用
            SVBFetchChain(SVBRevokeURLs(@"licenses.json"), 0,
                ^BOOL(NSData *body, NSInteger status, NSString *url) {
                    if (status == 404) {
                        [mgr setConfigValue:@{} forKey:SVB_GRANT_KEY_MAP];
                        [mgr log:@"[grant] 改签表不存在(404), 按空表处理 via %@", url];
                        return YES;
                    }
                    if (status != 200 || !body.length) return NO;
                    NSDictionary *map = SVBGrantMapFromJSON(body);
                    if (!map) {
                        [mgr log:@"[grant] 改签表验签失败, 忽略 via %@", url];
                        return NO;
                    }
                    [mgr setConfigValue:map forKey:SVB_GRANT_KEY_MAP];
                    [mgr log:@"[grant] 改签表已更新: %lu 条 via %@",
                             (unsigned long)map.count, url];
                    return YES;
                });

            // 两条链都落定后应用续签 (旧码 -> 新码)
            SVBRevokeApplyRenewal();

            // v9.9.16: 把本机授权凭证自动上报到作者私有仓库 (每天最多一次)
            SVBRevokeReportReceipt();
        } @catch (NSException *e) {}
        [SVBRevokeLock() lock];
        gSVBRevokeRunning = NO;
        [SVBRevokeLock() unlock];
    });
}
