#import <Foundation/Foundation.h>

// ============================================================
// GitHub 同步客户端 (v1.1.0) —— 把「作废名单」推到仓库, 或从仓库拉取
//   Token 存在本机 (NSUserDefaults), 不写进源码/二进制
//   仓库默认 Corpse-zhao/SMSVideoBG, 文件默认 revoked.json (main 分支)
//   拉取: api.github.com (最新) -> jsdelivr CDN -> raw.githubusercontent.com
//   推送: GET contents 拿 sha -> PUT 覆盖写入 (409/422 自动重试一次)
// ============================================================
@interface KGRevokeClient : NSObject

+ (NSString *)token;
+ (void)setToken:(NSString *)t;
+ (NSString *)repo;
+ (void)setRepo:(NSString *)r;
+ (NSString *)filePath;
+ (void)setFilePath:(NSString *)p;
+ (BOOL)configured;      // 配了 Token 才能推送

// 拉取并验签; 成功 hashes 非空 (可能是空数组 = 名单为空), 失败 error 非空
+ (void)fetchWithSecret:(NSString *)secret
             completion:(void (^)(NSArray<NSString *> *hashes, NSString *error))done;

// 推送本地名单 (自动加时间戳与签名)
+ (void)pushHashes:(NSArray<NSString *> *)hashes
            secret:(NSString *)secret
        completion:(void (^)(BOOL ok, NSString *error))done;
@end
