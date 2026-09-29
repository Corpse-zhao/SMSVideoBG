#import <Foundation/Foundation.h>

// ============================================================
// 远程作废名单 (v9.9.10)
//
//   背景: 激活码是离线签名的, 插件本地只做「签名/设备/到期」三项校验,
//         没有任何通道能让已激活的设备掉授权。要远程作废, 必须有一条
//         把「作废」信息送进设备的通道 —— 这里用仓库里的公开名单文件。
//
//   名单文件 (仓库的 revoke 分支, 由「激活码签发」App 维护):
//   ⚠️ 放独立分支而不是 main: 每次发代码是「整树重建」提交, 若名单在 main
//      会被代码提交顶掉 -> 作废全部失效。独立分支与本仓库的代码推送互不干扰。
//     {"v":1,"ts":<unix秒>,"revoked":["16位大写HEX", ...],"sig":"<64位小写HEX>"}
//   签名原文: "SVBGREVOKE/v1|<ts>|<hash 升序逗号连接>"
//   签名算法: HMAC-SHA256(secret, 原文) 全 32 字节的十六进制
//   条目      = SHA256(归一化激活码) 前 8 字节的大写十六进制
//
//   采用名单前必须验签通过 —— 否则任何拿到仓库写权限的人(或被劫持的网络)
//   都能伪造/清空名单。验签失败或拉取失败一律沿用上一次的缓存。
//
//   拉取地址 (依次尝试, 配置里的 revoke_url 可覆盖):
//     api.github.com?ref=revoke (最新) -> cdn.jsdelivr.net @revoke (国内可达, 缓存 12h)
//     -> raw.githubusercontent.com (国内常不通)
//   节流: 30 分钟内不重复拉取; 插件加载 / 控制App 打开授权页时触发。
// ============================================================

// 激活码 -> 名单条目 (归一化后 SHA256 前 8 字节的大写 hex, 16 字符)
NSString *SVBRevokeHashForCode(NSString *code);

// 该激活码是否已在缓存的名单里
BOOL SVBRevokeIsCodeRevoked(NSString *code);

// ---- 远程续签表 (v9.9.14, 与签发 App 的 renewals.json 严格对齐) ----
//   {"v":1,"ts":..,"renew":{"<旧码hash16>":"<新码24字符>"},"sig":..}
//   签名原文 "SVBGRENEW/v1|<ts>|<hash=新码 升序逗号连接>", 与作废名单同密钥。
//   本机激活码命中表内旧码 -> 验新码合法且未作废 -> 自动写入 license_code,
//   客户无需重新输入激活码 —— 续签直达。
// 应用缓存的续签表 (换码成功返回 YES); 无表/未命中/新码不合法 = NO
BOOL SVBRevokeApplyRenewal(void);
// 缓存的续签条目数 (控制App 展示用)
NSInteger SVBRevokeCachedRenewCount(void);

// ---- 远程改签表 (v9.9.15, 签发 App 的 licenses.json) ----
//   {"v":1,"ts":..,"grants":{"<码hash16>":<到期dayIndex>},"sig":..}
//   签名原文 "SVBGLICENSE/v1|<ts>|<hash=dayIndex 升序逗号连接>", 与作废名单同密钥。
//   命中改签表时: 到期日以表为准 (可续签/改短/复活过期码), 且优先于作废名单
//   —— 老版本没有这张表, 所以作废只对老版本生效 (强制升级的底座)。
// 该码的远程到期 dayIndex (0 = 无改签记录; 0xFFFFFFFF = 永久)
uint32_t SVBRevokeGrantForCode(NSString *code);
// 缓存的改签条目数 (控制App 展示用)
NSInteger SVBRevokeCachedGrantCount(void);

// 缓存状态 (控制App 展示用)
NSInteger SVBRevokeCachedCount(void);
NSTimeInterval SVBRevokeLastFetchTime(void);

// 异步刷新 (内部节流; force=YES 忽略节流)
void SVBRevokeRefreshIfNeeded(BOOL force);

// ---- 与签发端共用的拼装/校验工具 (便于交叉自测) ----
NSString *SVBRevokePayloadString(NSInteger ts, NSArray<NSString *> *hashes);
NSString *SVBRevokeSignatureHex(NSString *payload);
// 解析并验签名单 JSON; 通过返回条目数组 (大写), 否则 nil
NSArray<NSString *> *SVBRevokeHashesFromJSON(NSData *json);
