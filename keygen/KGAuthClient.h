#import <Foundation/Foundation.h>

// ============================================================
// GitHub 同步客户端 (v2.0.0) —— 维护远端授权白名单 auth.json
//   Token 只存本机 (NSUserDefaults), 不写进源码/二进制
//   仓库默认 Corpse-zhao/SMSVideoBG, 分支 revoke, 文件 auth.json
//   拉取: api.github.com (带 token, 可读私有分支) -> jsdelivr -> raw
//   推送: 自动建 revoke 分支 -> GET 拿 sha -> PUT 覆盖 (冲突自动重试)
// ============================================================
@interface KGAuthClient : NSObject

+ (NSString *)token;
+ (void)setToken:(NSString *)t;
+ (NSString *)repo;
+ (void)setRepo:(NSString *)r;
+ (NSString *)branch;
+ (void)setBranch:(NSString *)b;
+ (BOOL)configured;      // 配了 Token 才能推送

// 拉取远端名单文件; status=200 时 body 为文件内容, 404 = 名单还不存在
+ (void)fetchAuthFile:(void (^)(NSInteger status, NSData *body, NSString *error))done;

// 推送整个名单 (自动加时间戳与签名, 覆盖远端)
+ (void)pushDevices:(NSDictionary<NSString *, NSNumber *> *)devices
             secret:(NSString *)secret
         completion:(void (^)(BOOL ok, NSString *error))done;
@end
