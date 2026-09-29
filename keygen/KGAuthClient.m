#import "KGAuthClient.h"
#import "KGAuth.h"

static NSString * const kKGTokenKey  = @"kg_gh_token";
static NSString * const kKGRepoKey   = @"kg_gh_repo";
static NSString * const kKGBranchKey = @"kg_gh_branch";
static NSString * const kKGFilePath  = @"auth.json";

static NSString *KGPref(NSString *key, NSString *fallback) {
    NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    return v.length ? v : fallback;
}

@implementation KGAuthClient

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
+ (NSString *)branch { return KGPref(kKGBranchKey, @"revoke"); }
+ (void)setBranch:(NSString *)b {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (b.length) [d setObject:b forKey:kKGBranchKey]; else [d removeObjectForKey:kKGBranchKey];
}
+ (BOOL)configured { return self.token.length > 0; }

#pragma mark - Gitee 配置 (v2.1.0)

static NSString * const kKGGiteeTokenKey  = @"kg_gitee_token";
static NSString * const kKGGiteeRepoKey   = @"kg_gitee_repo";
static NSString * const kKGGiteeBranchKey = @"kg_gitee_branch";

+ (NSString *)giteeToken { return KGPref(kKGGiteeTokenKey, @""); }
+ (void)setGiteeToken:(NSString *)t {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (t.length) [d setObject:t forKey:kKGGiteeTokenKey]; else [d removeObjectForKey:kKGGiteeTokenKey];
}
+ (NSString *)giteeRepo { return KGPref(kKGGiteeRepoKey, @""); }
+ (void)setGiteeRepo:(NSString *)r {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (r.length) [d setObject:r forKey:kKGGiteeRepoKey]; else [d removeObjectForKey:kKGGiteeRepoKey];
}
+ (NSString *)giteeBranch { return KGPref(kKGGiteeBranchKey, @"master"); }
+ (void)setGiteeBranch:(NSString *)b {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (b.length) [d setObject:b forKey:kKGGiteeBranchKey]; else [d removeObjectForKey:kKGGiteeBranchKey];
}
+ (BOOL)giteeConfigured { return self.giteeToken.length > 0 && self.giteeRepo.length > 0; }

+ (NSString *)giteeRawURL {
    NSString *repo = self.giteeRepo;
    if (!repo.length) return nil;
    return [NSString stringWithFormat:@"https://gitee.com/%@/raw/%@/%@",
            repo, self.giteeBranch, kKGFilePath];
}

#pragma mark - 底层同步请求 (后台队列调用, 最多阻塞 22 秒)

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
    if (status == 404) return @"仓库/分支/文件不存在（检查仓库名与 Token 权限）";
    if (status == 0)   return @"连不上 GitHub（检查网络/代理）";
    return msg.length ? [NSString stringWithFormat:@"HTTP %ld：%@", (long)status, msg]
                      : [NSString stringWithFormat:@"HTTP %ld", (long)status];
}

// 确保 revoke 分支存在 (不存在就从 main 的 tip 建一个)
+ (BOOL)ensureBranchWithToken:(NSString *)tok error:(NSString **)err {
    NSString *br = [self branch];
    NSString *rep = [self repo];

    NSDictionary *r = [self syncRequest:@"GET"
                                    url:[NSString stringWithFormat:
                                        @"https://api.github.com/repos/%@/git/ref/heads/%@", rep, br]
                                  token:tok body:nil accept:@"application/vnd.github+json"];
    NSInteger st = [r[@"status"] integerValue];
    if (st == 200) return YES;
    if (st != 404) { if (err) *err = [self errorTextForStatus:st data:r[@"data"]]; return NO; }

    NSDictionary *m = [self syncRequest:@"GET"
                                    url:[NSString stringWithFormat:
                                        @"https://api.github.com/repos/%@/git/ref/heads/main", rep]
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

#pragma mark - 拉取 / 推送

+ (void)fetchAuthFile:(void (^)(NSInteger, NSData *, NSString *))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *rep = [KGAuthClient repo];
        NSString *br  = [KGAuthClient branch];
        NSString *tok = [KGAuthClient token];

        NSArray *urls = @[
            [NSString stringWithFormat:@"https://api.github.com/repos/%@/contents/%@?ref=%@",
                rep, kKGFilePath, br],
            [NSString stringWithFormat:@"https://cdn.jsdelivr.net/gh/%@@%@/%@", rep, br, kKGFilePath],
            [NSString stringWithFormat:@"https://raw.githubusercontent.com/%@/%@/%@", rep, br, kKGFilePath],
        ];

        NSInteger lastStatus = 0;
        NSString *lastErr = @"连不上远端（检查网络）";
        for (NSUInteger i = 0; i < urls.count; i++) {
            // 第一个源走 API 时需要 token (私有分支/私有仓库), CDN 源不需要
            NSString *accept = (i == 0) ? @"application/vnd.github.raw" : nil;
            NSString *tk = (i == 0) ? tok : nil;
            NSDictionary *r = [KGAuthClient syncRequest:@"GET" url:urls[i] token:tk body:nil accept:accept];
            NSInteger status = [r[@"status"] integerValue];
            NSData *data = r[@"data"];
            lastStatus = status;

            if (status == 200) {
                dispatch_async(dispatch_get_main_queue(), ^{ done(200, data, nil); });
                return;
            }
            if (status == 404) {
                // API 源 404 = 文件/分支不存在; CDN 源 404 也当不存在处理
                dispatch_async(dispatch_get_main_queue(), ^{ done(404, nil, nil); });
                return;
            }
            lastErr = [KGAuthClient errorTextForStatus:status data:data];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(lastStatus, nil, lastErr); });
    });
}

+ (void)pushDevices:(NSDictionary<NSString *, NSNumber *> *)devices
             secret:(NSString *)secret
         completion:(void (^)(BOOL, NSString *))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tok = [KGAuthClient token];
        if (!tok.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"还没配 GitHub Token（在下方「GitHub 同步」里填）");
            });
            return;
        }
        if (!secret.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, @"签名密钥为空"); });
            return;
        }

        NSString *err = nil;
        if (![KGAuthClient ensureBranchWithToken:tok error:&err]) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(NO, err ?: @"分支准备失败"); });
            return;
        }

        NSString *rep = [KGAuthClient repo];
        NSString *br  = [KGAuthClient branch];
        NSString *apiURL = [NSString stringWithFormat:
            @"https://api.github.com/repos/%@/contents/%@", rep, kKGFilePath];

        BOOL ok = NO;
        NSString *lastErr = @"写入失败";
        for (int attempt = 0; attempt < 3; attempt++) {
            // 拿文件 sha (覆盖已有文件必须带)
            NSDictionary *h = [KGAuthClient syncRequest:@"GET"
                url:[NSString stringWithFormat:@"%@?ref=%@", apiURL, br]
              token:tok body:nil accept:@"application/vnd.github+json"];
            NSInteger hs = [h[@"status"] integerValue];
            NSString *sha = nil;
            if (hs == 200) {
                id ho = [NSJSONSerialization JSONObjectWithData:h[@"data"] options:0 error:NULL];
                if ([ho isKindOfClass:[NSDictionary class]] && [ho[@"sha"] isKindOfClass:[NSString class]])
                    sha = ho[@"sha"];
            } else if (hs != 404) {
                lastErr = [KGAuthClient errorTextForStatus:hs data:h[@"data"]];
                break;
            }

            NSInteger ts = (NSInteger)[[NSDate date] timeIntervalSince1970];
            NSData *json = KGAuthBuildJSON(secret, ts, devices);
            if (!json.length) { lastErr = @"名单内容生成失败"; break; }

            NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:
                @{@"message": [NSString stringWithFormat:@"auth: %lu device(s)", (unsigned long)devices.count],
                  @"content": [json base64EncodedStringWithOptions:0],
                  @"branch":  br}];
            if (sha.length) payload[@"sha"] = sha;

            NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
            NSDictionary *p = [KGAuthClient syncRequest:@"PUT" url:apiURL token:tok
                                                   body:body accept:@"application/vnd.github+json"];
            NSInteger ps = [p[@"status"] integerValue];
            if (ps == 200 || ps == 201) { ok = YES; lastErr = nil; break; }
            if (ps == 409 || ps == 422) { lastErr = @"写入冲突（远端被同时修改），已重试"; continue; }
            lastErr = [KGAuthClient errorTextForStatus:ps data:p[@"data"]];
            break;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ done(ok, lastErr); });
    });
}

#pragma mark - Gitee 推送 (v2.1.0)

+ (void)pushToGitee:(NSDictionary<NSString *, NSNumber *> *)devices
             secret:(NSString *)secret
         completion:(void (^)(BOOL ok, NSString *error))done {
    NSString *tok  = self.giteeToken;
    NSString *repo = self.giteeRepo;
    NSString *br   = self.giteeBranch;
    if (!tok.length || !repo.length) {
        if (done) done(NO, @"未配置 Gitee 令牌或仓库");
        return;
    }
    if (!br.length) br = @"master";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger ts = (NSInteger)[[NSDate date] timeIntervalSince1970];
        NSData *json = KGAuthBuildJSON(secret, ts, devices ?: @{});
        if (!json.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO, @"名单生成失败"); });
            return;
        }
        NSString *b64 = [json base64EncodedStringWithOptions:0];
        NSString *enc = [tok stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
        NSString *base = [NSString stringWithFormat:
            @"https://gitee.com/api/v5/repos/%@/contents/%@", repo, kKGFilePath];

        // ① 取现有 sha (404 = 文件还不存在, 直接创建)
        NSDictionary *g = [self syncRequest:@"GET"
            url:[NSString stringWithFormat:@"%@?access_token=%@&ref=%@", base, enc, br]
          token:@"" body:nil accept:@"application/json"];
        NSInteger gs = [g[@"status"] integerValue];
        NSData *gd = g[@"data"];
        NSString *sha = nil;
        if (gs == 200 && gd.length) {
            id o = [NSJSONSerialization JSONObjectWithData:gd options:0 error:NULL];
            if ([o isKindOfClass:[NSDictionary class]] &&
                [o[@"sha"] isKindOfClass:[NSString class]])
                sha = o[@"sha"];
        } else if (gs != 404 && gs != 0) {
            NSString *m = nil;
            if (gd.length) {
                id o = [NSJSONSerialization JSONObjectWithData:gd options:0 error:NULL];
                if ([o isKindOfClass:[NSDictionary class]] && [o[@"message"] isKindOfClass:[NSString class]])
                    m = o[@"message"];
            }
            NSString *msg = (gs == 401 || gs == 403)
                ? @"Gitee 令牌无效/权限不足（需勾 projects 权限）"
                : [NSString stringWithFormat:@"Gitee 读取失败(HTTP %ld)%@%@",
                        (long)gs, m.length ? @"：" : @"", m ?: @""];
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO, msg); });
            return;
        }

        // ② 上传 (access_token 同时在 query 与 body, 兼容两种解析)
        NSMutableDictionary *b = [NSMutableDictionary dictionary];
        b[@"access_token"] = tok;
        b[@"content"] = b64;
        b[@"message"] = @"update auth.json (SMSVideoBG)";
        b[@"branch"] = br;
        if (sha.length) b[@"sha"] = sha;
        NSData *bd = [NSJSONSerialization dataWithJSONObject:b options:0 error:NULL];

        NSDictionary *p = [self syncRequest:@"POST"
            url:[NSString stringWithFormat:@"%@?access_token=%@", base, enc]
          token:@"" body:bd accept:@"application/json"];
        NSInteger ps = [p[@"status"] integerValue];
        NSData *pd = p[@"data"];

        if (ps == 200 || ps == 201) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(YES, nil); });
            return;
        }

        NSString *m = nil;
        if (pd.length) {
            id o = [NSJSONSerialization JSONObjectWithData:pd options:0 error:NULL];
            if ([o isKindOfClass:[NSDictionary class]]) {
                if ([o[@"message"] isKindOfClass:[NSString class]]) m = o[@"message"];
                else if ([o[@"error"] isKindOfClass:[NSString class]]) m = o[@"error"];
            }
        }
        NSString *msg;
        if (ps == 0)        msg = @"连不上 Gitee（检查网络）";
        else if (ps == 401 || ps == 403) msg = @"Gitee 令牌无效/权限不足（需勾 projects 权限）";
        else if (ps == 404) msg = @"Gitee 仓库或分支不存在（检查仓库名、分支名，仓库需为公开）";
        else msg = [NSString stringWithFormat:@"Gitee 上传失败(HTTP %ld)%@%@",
                        (long)ps, m.length ? @"：" : @"", m ?: @""];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO, msg); });
    });
}

@end
