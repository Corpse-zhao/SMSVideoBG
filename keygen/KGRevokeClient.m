#import "KGRevokeClient.h"
#import "KGCore.h"

static NSString * const kKGTokenKey = @"kg_gh_token";
static NSString * const kKGRepoKey  = @"kg_gh_repo";
static NSString * const kKGFileKey  = @"kg_gh_file";
static NSString * const kKGBranchKey = @"kg_gh_branch";
static NSString * const kKGRenewFileKey = @"kg_gh_renew_file";   // v1.3.0 续签表文件名
static NSString * const kKGLicenseFileKey = @"kg_gh_license_file"; // v1.4.0 改签表文件名

static NSString *KGPref(NSString *key, NSString *fallback) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    return v.length ? v : fallback;
}

@implementation KGRevokeClient

+ (NSString *)token { return KGPref(kKGTokenKey, @""); }
+ (void)setToken:(NSString *)t {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (t.length) [d setObject:t forKey:kKGTokenKey]; else [d removeObjectForKey:kKGTokenKey];
}
+ (NSString *)repo { return KGPref(kKGRepoKey, @"Corpse-zhao/SMSVideoBG"); }
+ (void)setRepo:(NSString *)r {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (r.length) [d setObject:r forKey:kKGRepoKey]; else [d removeObjectForKey:kKGRepoKey];
}
+ (NSString *)filePath { return KGPref(kKGFileKey, @"revoked.json"); }
+ (void)setFilePath:(NSString *)p {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (p.length) [d setObject:p forKey:kKGFileKey]; else [d removeObjectForKey:kKGFileKey];
}
// 名单放独立分支, 与代码分支互不干扰 (代码全量提交不会顶掉作废名单)
+ (NSString *)branch { return KGPref(kKGBranchKey, @"revoke"); }
+ (void)setBranch:(NSString *)b {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (b.length) [d setObject:b forKey:kKGBranchKey]; else [d removeObjectForKey:kKGBranchKey];
}
+ (BOOL)configured { return self.token.length > 0; }
// v1.3.0 续签表文件名 (与作废名单同分支)
+ (NSString *)renewFilePath { return KGPref(kKGRenewFileKey, @"renewals.json"); }

#pragma mark - 底层同步请求 (在后台队列调用, 阻塞至多 20 秒)

+ (NSDictionary *)syncRequest:(NSString *)method
                          url:(NSString *)urlStr
                        token:(NSString *)token
                         body:(NSData *)body
                       accept:(NSString *)accept {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return @{@"status": @0, @"data": [NSData data]};

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    req.timeoutInterval = 15;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:@"SMSVideoBG-KeyGen" forHTTPHeaderField:@"User-Agent"];
    if (token.length) [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    if (accept.length) [req setValue:accept forHTTPHeaderField:@"Accept"];
    if (body) {
        req.HTTPBody = body;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    __block NSData *data = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            data = d;
            if ([r isKindOfClass:[NSHTTPURLResponse class]])
                status = ((NSHTTPURLResponse *)r).statusCode;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22 * NSEC_PER_SEC)));
    return @{@"status": @(status), @"data": data ?: [NSData data]};
}

+ (NSString *)errorTextForStatus:(NSInteger)status data:(NSData *)data {
    NSString *msg = nil;
    if (data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"message"] isKindOfClass:[NSString class]])
            msg = obj[@"message"];
    }
    if (status == 401) return @"Token 无效或已过期";
    if (status == 403) return @"被拒绝：Token 权限不足或触发限流";
    if (status == 404) return @"仓库或文件不存在（检查仓库名，Token 需要 repo 权限）";
    if (status == 0)   return @"连不上 GitHub（检查网络/代理）";
    return msg.length ? [NSString stringWithFormat:@"HTTP %ld：%@", (long)status, msg]
                      : [NSString stringWithFormat:@"HTTP %ld", (long)status];
}

// 确保 revoke 分支存在 (不存在就从 main 的 tip 建一个)
+ (BOOL)ensureBranchWithToken:(NSString *)tok error:(NSString **)err {
    NSString *br = [self branch];
    NSString *rep = [self repo];

    NSDictionary *r = [self syncRequest:@"GET"
                                    url:[NSString stringWithFormat:@"https://api.github.com/repos/%@/git/ref/heads/%@", rep, br]
                                  token:tok body:nil accept:@"application/vnd.github+json"];
    NSInteger st = [r[@"status"] integerValue];
    if (st == 200) return YES;
    if (st != 404) { if (err) *err = [self errorTextForStatus:st data:r[@"data"]]; return NO; }

    NSDictionary *m = [self syncRequest:@"GET"
                                    url:[NSString stringWithFormat:@"https://api.github.com/repos/%@/git/ref/heads/main", rep]
                                  token:tok body:nil accept:@"application/vnd.github+json"];
    NSString *sha = nil;
    id mo = [NSJSONSerialization JSONObjectWithData:m[@"data"] options:0 error:NULL];
    if ([mo isKindOfClass:[NSDictionary class]] && [mo[@"object"] isKindOfClass:[NSDictionary class]])
        sha = mo[@"object"][@"sha"];
    if (!sha.length) {
        if (err) *err = @"拿不到 main 分支指针（检查仓库名 / Token 权限）";
        return NO;
    }

    NSData *body = [NSJSONSerialization dataWithJSONObject:
                        @{@"ref": [NSString stringWithFormat:@"refs/heads/%@", br], @"sha": sha}
                                                   options:0 error:NULL];
    NSDictionary *c = [self syncRequest:@"POST"
                                    url:[NSString stringWithFormat:@"https://api.github.com/repos/%@/git/refs", rep]
                                  token:tok body:body accept:@"application/vnd.github+json"];
    NSInteger cs = [c[@"status"] integerValue];
    if (cs == 200 || cs == 201) return YES;
    if (err) *err = [self errorTextForStatus:cs data:c[@"data"]];
    return NO;
}

+ (NSArray<NSString *> *)fetchURLs {
    NSString *rep = [self repo];
    NSString *path = [self filePath];
    NSString *br = [self branch];
    return @[[NSString stringWithFormat:@"https://api.github.com/repos/%@/contents/%@?ref=%@", rep, path, br],
             [NSString stringWithFormat:@"https://cdn.jsdelivr.net/gh/%@@%@/%@", rep, br, path],
             [NSString stringWithFormat:@"https://raw.githubusercontent.com/%@/%@/%@", rep, br, path]];
}

#pragma mark - 拉取 / 推送

+ (void)fetchWithSecret:(NSString *)secret
             completion:(void (^)(NSArray<NSString *> *, NSString *))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *urls = [KGRevokeClient fetchURLs];
        NSArray *result = nil;
        NSString *err = @"连不上远端（检查网络）";

        for (NSUInteger i = 0; i < urls.count; i++) {
            NSString *accept = (i == 0) ? @"application/vnd.github.raw" : nil;
            NSDictionary *r = [KGRevokeClient syncRequest:@"GET" url:urls[i]
                                                    token:(i == 0 ? [KGRevokeClient token] : nil)
                                                     body:nil accept:accept];
            NSInteger status = [r[@"status"] integerValue];
            NSData *data = r[@"data"];

            if (status == 200) {
                NSArray *hashes = KGRevokeParseJSON(data, secret);
                if (hashes) { result = hashes; err = nil; break; }
                err = @"远端名单验签失败（密钥不一致 / 文件被改过）";
                continue;
            }
            if (status == 404) { result = @[]; err = nil; break; }   // 还没有名单文件 = 空名单
            err = [KGRevokeClient errorTextForStatus:status data:data];
        }

        dispatch_async(dispatch_get_main_queue(), ^{ done(result, err); });
    });
}

+ (void)pushHashes:(NSArray<NSString *> *)hashes
            secret:(NSString *)secret
        completion:(void (^)(BOOL, NSString *))done {
    NSString *tok = [self token];
    if (!tok.length) { done(NO, @"未配置 GitHub Token，无法推送"); return; }
    if (!secret.length) { done(NO, @"签名密钥为空"); return; }

    NSString *apiURL = [NSString stringWithFormat:@"https://api.github.com/repos/%@/contents/%@?ref=%@",
                        [self repo], [self filePath], [self branch]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = @"推送失败";
        BOOL ok = NO;

        // 名单在独立分支: 第一次使用时自动建分支
        NSString *branchErr = nil;
        if (![KGRevokeClient ensureBranchWithToken:tok error:&branchErr]) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, branchErr ?: @"无法准备名单分支"); });
            return;
        }

        for (int attempt = 0; attempt < 2; attempt++) {
            NSString *sha = nil;
            NSDictionary *g = [KGRevokeClient syncRequest:@"GET" url:apiURL token:tok
                                                     body:nil accept:@"application/vnd.github+json"];
            NSInteger gs = [g[@"status"] integerValue];
            if (gs == 200) {
                id obj = [NSJSONSerialization JSONObjectWithData:g[@"data"] options:0 error:NULL];
                if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"sha"] isKindOfClass:[NSString class]])
                    sha = obj[@"sha"];
            } else if (gs != 404) {
                err = [KGRevokeClient errorTextForStatus:gs data:g[@"data"]];
                break;
            }

            NSData *content = KGRevokeBuildJSON(secret, (NSInteger)[[NSDate date] timeIntervalSince1970], hashes);
            if (!content) { err = @"名单序列化失败"; break; }

            NSMutableDictionary *payload = [NSMutableDictionary dictionary];
            payload[@"message"] = [NSString stringWithFormat:@"更新作废名单 (%lu 条)", (unsigned long)hashes.count];
            payload[@"content"] = [content base64EncodedStringWithOptions:0];
            payload[@"branch"] = [KGRevokeClient branch];
            if (sha.length) payload[@"sha"] = sha;

            NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
            NSDictionary *p = [KGRevokeClient syncRequest:@"PUT" url:apiURL token:tok
                                                     body:body accept:@"application/vnd.github+json"];
            NSInteger ps = [p[@"status"] integerValue];
            if (ps == 200 || ps == 201) { ok = YES; err = nil; break; }
            if (ps == 409 || ps == 422) { err = @"写入冲突（远端被同时修改），已重试"; continue; }
            err = [KGRevokeClient errorTextForStatus:ps data:p[@"data"]];
            break;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ done(ok, err); });
    });
}

// v1.3.0 推送续签表: 先拉远端已有表合并, 再整体签名覆盖
+ (void)pushRenewals:(NSDictionary<NSString *, NSString *> *)add
              secret:(NSString *)secret
          completion:(void (^)(BOOL, NSString *))done {
    NSString *tok = [self token];
    if (!tok.length) { done(NO, @"未配置 GitHub Token，无法推送"); return; }
    if (!secret.length) { done(NO, @"签名密钥为空"); return; }
    if (!add.count) { done(NO, @"没有要推送的续签条目"); return; }

    // 清洗入参: 只留 hash16 -> code24
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (NSString *h in add) {
        NSString *hu = [h uppercaseString];
        NSString *cn = KGCodeNormalize([add objectForKey:h] ?: @"");   // 自动去空格/横线
        if (hu.length == 16 && cn.length == 24) [entries setObject:cn forKey:hu];
    }
    if (!entries.count) { done(NO, @"续签条目格式不合法"); return; }

    NSString *path = [self renewFilePath];
    NSString *apiURL = [NSString stringWithFormat:@"https://api.github.com/repos/%@/contents/%@?ref=%@",
                        [self repo], path, [self branch]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = @"推送失败";
        BOOL ok = NO;

        NSString *branchErr = nil;
        if (![KGRevokeClient ensureBranchWithToken:tok error:&branchErr]) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, branchErr ?: @"无法准备名单分支"); });
            return;
        }

        // 合并远端已有续签表 (旧表已验签; 推送前会整体重新签名)
        NSMutableDictionary *merged = [entries mutableCopy];
        NSDictionary *g = [KGRevokeClient syncRequest:@"GET" url:apiURL token:tok
                                                 body:nil accept:@"application/vnd.github.raw"];
        NSInteger gs = [g[@"status"] integerValue];
        if (gs == 200) {
            NSDictionary *old = KGRenewParseJSON(g[@"data"], secret);
            if (old) [merged addEntriesFromDictionary:old];
        }
        if (gs != 200 && gs != 404) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, [KGRevokeClient errorTextForStatus:gs data:g[@"data"]]); });
            return;
        }

        for (int attempt = 0; attempt < 2; attempt++) {
            // 拿文件 sha (覆盖已有文件必须带)
            NSString *fileSHA = nil;
            NSDictionary *h = [KGRevokeClient syncRequest:@"GET" url:apiURL token:tok
                                                     body:nil accept:@"application/vnd.github+json"];
            NSInteger hs = [h[@"status"] integerValue];
            if (hs == 200) {
                id obj = [NSJSONSerialization JSONObjectWithData:h[@"data"] options:0 error:NULL];
                if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"sha"] isKindOfClass:[NSString class]])
                    fileSHA = obj[@"sha"];
            } else if (hs != 404) {
                err = [KGRevokeClient errorTextForStatus:hs data:h[@"data"]];
                break;
            }

            NSData *content = KGRenewBuildJSON(secret,
                                               (NSInteger)[[NSDate date] timeIntervalSince1970],
                                               merged);
            if (!content) { err = @"续签表序列化失败"; break; }

            NSMutableDictionary *payload = [NSMutableDictionary dictionary];
            payload[@"message"] = [NSString stringWithFormat:@"更新续签表 (%lu 条)", (unsigned long)merged.count];
            payload[@"content"] = [content base64EncodedStringWithOptions:0];
            payload[@"branch"] = [KGRevokeClient branch];
            if (fileSHA.length) payload[@"sha"] = fileSHA;

            NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
            NSDictionary *p = [KGRevokeClient syncRequest:@"PUT" url:apiURL token:tok
                                                     body:body accept:@"application/vnd.github+json"];
            NSInteger ps = [p[@"status"] integerValue];
            if (ps == 200 || ps == 201) { ok = YES; err = nil; break; }
            if (ps == 409 || ps == 422) { err = @"写入冲突（远端被同时修改），已重试"; continue; }
            err = [KGRevokeClient errorTextForStatus:ps data:p[@"data"]];
            break;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ done(ok, err); });
    });
}

// v1.4.0: 追加作废条目 (拉远端现名单合并后整体重签, 不清掉已有条目)
+ (void)revokeAdditionalHashes:(NSArray<NSString *> *)add
                        secret:(NSString *)secret
                    completion:(void (^)(BOOL, NSString *))done {
    NSString *tok = [self token];
    if (!tok.length) { done(NO, @"未配置 GitHub Token，无法推送"); return; }
    if (!secret.length) { done(NO, @"签名密钥为空"); return; }

    NSMutableArray *adds = [NSMutableArray array];
    for (NSString *h in add) {
        NSString *u = [h uppercaseString];
        if (u.length == 16 && ![adds containsObject:u]) [adds addObject:u];
    }
    if (!adds.count) { done(NO, @"没有要作废的条目"); return; }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 拉远端现名单 (任一源 200 即用; 404 = 空名单)
        NSArray *current = nil;
        NSString *err = nil;
        NSArray *urls = [KGRevokeClient fetchURLs];
        for (NSUInteger i = 0; i < urls.count; i++) {
            NSString *accept = (i == 0) ? @"application/vnd.github.raw" : nil;
            NSDictionary *r = [KGRevokeClient syncRequest:@"GET" url:urls[i]
                                                    token:(i == 0 ? tok : nil)
                                                     body:nil accept:accept];
            NSInteger st = [r[@"status"] integerValue];
            if (st == 200) {
                NSArray *parsed = KGRevokeParseJSON(r[@"data"], secret);
                if (parsed) { current = parsed; break; }
                err = @"远端名单验签失败（密钥不一致 / 文件被改过）";
                continue;
            }
            if (st == 404) { current = @[]; break; }
            err = [KGRevokeClient errorTextForStatus:st data:r[@"data"]];
        }
        if (!current && err) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, err); });
            return;
        }

        NSMutableArray *merged = [current ?: @[] mutableCopy];
        for (NSString *u in adds) if (![merged containsObject:u]) [merged addObject:u];

        [KGRevokeClient pushHashes:merged secret:secret completion:done];
    });
}

// v1.4.0 推送改签表: 合并远端 licenses.json 后整体重签覆盖; removeKeys 用于取消改签
+ (void)pushGrants:(NSDictionary<NSString *, NSString *> *)add
        removeKeys:(NSArray<NSString *> *)remove
            secret:(NSString *)secret
        completion:(void (^)(BOOL, NSString *))done {
    NSString *tok = [self token];
    if (!tok.length) { done(NO, @"未配置 GitHub Token，无法推送"); return; }
    if (!secret.length) { done(NO, @"签名密钥为空"); return; }
    if (!add.count && !remove.count) { done(NO, @"没有要推送的改签条目"); return; }

    NSString *path = KGPref(kKGLicenseFileKey, @"licenses.json");
    NSString *apiURL = [NSString stringWithFormat:@"https://api.github.com/repos/%@/contents/%@?ref=%@",
                        [self repo], path, [self branch]];

    // 清洗入参
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (NSString *h in add) {
        NSString *hu = [h uppercaseString];
        NSString *v = [add objectForKey:h];
        if (hu.length == 16 && v.length) [entries setObject:v forKey:hu];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = @"推送失败";
        BOOL ok = NO;

        NSString *branchErr = nil;
        if (![KGRevokeClient ensureBranchWithToken:tok error:&branchErr]) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, branchErr ?: @"无法准备名单分支"); });
            return;
        }

        // 拉远端现表合并 (拉不到/验签失败按空表处理, 推送前整体重签)
        NSMutableDictionary *merged = [entries mutableCopy];
        NSDictionary *g = [KGRevokeClient syncRequest:@"GET" url:apiURL token:tok
                                                 body:nil accept:@"application/vnd.github.raw"];
        NSInteger gs = [g[@"status"] integerValue];
        if (gs == 200) {
            NSDictionary *old = KGLicenseParseJSON(g[@"data"], secret);
            if (old) {
                [merged addEntriesFromDictionary:old];
                for (NSString *h in remove) {
                    if ([h isKindOfClass:[NSString class]]) [merged removeObjectForKey:[h uppercaseString]];
                }
            }
        }
        if (!merged.count) { err = @"合并后改签表为空"; 
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, err); });
            return; }

        for (int attempt = 0; attempt < 2; attempt++) {
            NSString *fileSHA = nil;
            NSDictionary *h = [KGRevokeClient syncRequest:@"GET" url:apiURL token:tok
                                                     body:nil accept:@"application/vnd.github+json"];
            NSInteger hs = [h[@"status"] integerValue];
            if (hs == 200) {
                id obj = [NSJSONSerialization JSONObjectWithData:h[@"data"] options:0 error:NULL];
                if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"sha"] isKindOfClass:[NSString class]])
                    fileSHA = obj[@"sha"];
            } else if (hs != 404) {
                err = [KGRevokeClient errorTextForStatus:hs data:h[@"data"]];
                break;
            }

            NSData *content = KGLicenseBuildJSON(secret,
                                                 (NSInteger)[[NSDate date] timeIntervalSince1970],
                                                 merged);
            if (!content) { err = @"改签表序列化失败"; break; }

            NSMutableDictionary *payload = [NSMutableDictionary dictionary];
            payload[@"message"] = [NSString stringWithFormat:@"更新改签表 (%lu 条)", (unsigned long)merged.count];
            payload[@"content"] = [content base64EncodedStringWithOptions:0];
            payload[@"branch"] = [KGRevokeClient branch];
            if (fileSHA.length) payload[@"sha"] = fileSHA;

            NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
            NSDictionary *p = [KGRevokeClient syncRequest:@"PUT" url:apiURL token:tok
                                                     body:body accept:@"application/vnd.github+json"];
            NSInteger ps = [p[@"status"] integerValue];
            if (ps == 200 || ps == 201) { ok = YES; err = nil; break; }
            if (ps == 409 || ps == 422) { err = @"写入冲突（远端被同时修改），已重试"; continue; }
            err = [KGRevokeClient errorTextForStatus:ps data:p[@"data"]];
            break;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ done(ok, err); });
    });
}

@end
