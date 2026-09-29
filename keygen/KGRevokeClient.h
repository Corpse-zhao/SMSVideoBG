#import <Foundation/Foundation.h>

// ============================================================
// GitHub 同步客户端 (v1.1.0) —— 把「作废名单」推到仓库, 或从仓库拉取
//   Token 存在本机 (NSUserDefaults), 不写进源码/二进制
//   仓库默认 Corpse-zhao/SMSVideoBG, 分支默认 revoke, 文件默认 revoked.json
//   拉取: api.github.com?ref= (最新) -> jsdelivr CDN -> raw.githubusercontent.com
//   推送: 自动建 revoke 分支 -> GET contents 拿 sha -> PUT 覆盖 (冲突自动重试)
// ============================================================
@interface KGRevokeClient : NSObject

+ (NSString *)token;
+ (void)setToken:(NSString *)t;
+ (NSString *)repo;
+ (void)setRepo:(NSString *)r;
+ (NSString *)filePath;
+ (void)setFilePath:(NSString *)p;
// 名单所在分支 (默认 revoke —— 独立于代码分支, 不会被代码提交顶掉)
+ (NSString *)branch;
+ (void)setBranch:(NSString *)b;
+ (BOOL)configured;      // 配了 Token 才能推送

// 拉取并验签; 成功 hashes 非空 (可能是空数组 = 名单为空), 失败 error 非空
+ (void)fetchWithSecret:(NSString *)secret
             completion:(void (^)(NSArray<NSString *> *hashes, NSString *error))done;

// 推送本地名单 (自动加时间戳与签名)
+ (void)pushHashes:(NSArray<NSString *> *)hashes
            secret:(NSString *)secret
        completion:(void (^)(BOOL ok, NSString *error))done;

// v1.4.0: 追加作废条目 (先拉远端现名单合并, 再整体签名覆盖 —— 不会清掉已有条目)
+ (void)revokeAdditionalHashes:(NSArray<NSString *> *)add
                        secret:(NSString *)secret
                    completion:(void (^)(BOOL ok, NSString *error))done;

// v1.3.0 续签表: 与远端已有表合并后整体签名覆盖 (renewals.json, 同 revoke 分支)
+ (void)pushRenewals:(NSDictionary<NSString *, NSString *> *)add
              secret:(NSString *)secret
          completion:(void (^)(BOOL ok, NSString *error))done;

// v1.4.0 改签表: {码hash16: dayIndex十进制字符串} 合并推送 (licenses.json, 同 revoke 分支)
//   removeKeys 非空时先把这些条目从远端表里删掉 (取消改签)
+ (void)pushGrants:(NSDictionary<NSString *, NSString *> *)add
        removeKeys:(NSArray<NSString *> *)remove
            secret:(NSString *)secret
        completion:(void (^)(BOOL ok, NSString *error))done;

// v1.5.0 云端凭证表: 读私有仓库 SMSVideoBG-Receipts 的 receipts.json (客户插件自动上报)
//   status=200 时 body 为文件内容; 404 = 还没有任何上报
+ (void)fetchReceiptsFile:(void (^)(NSInteger status, NSData *body, NSString *error))done;
@end
