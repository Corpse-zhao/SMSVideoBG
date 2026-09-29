#import <Foundation/Foundation.h>

// ============================================================
// 授权核心 (签发端 v2.0.0) —— UDID 白名单制
//
//   与插件端 SVBAuth.m 严格一致:
//     名单键 H32 = SHA256("SMSVideoBG-AUTH/v1|<归一化UDID>") 前 16 字节 -> 32 位大写 HEX
//     归一化     = 大写 + 只留 A-Z0-9
//   白名单文件 auth.json (revoke 分支):
//     {"v":1,"ts":<unix秒>,"devices":{"<H32>":<到期dayIndex>},"sig":"<64位hex>"}
//     到期 dayIndex = 自 2020-01-01 UTC 起的天数; 4294967295 = 永久
//     签名原文 = "SVBAUTH/v1|<ts>|<H32=dayIndex 升序逗号连接>"
//     签名算法 = HMAC-SHA256(secret, 原文) 全 32 字节小写十六进制
// ============================================================

#define KG_AUTH_FOREVER 4294967295u

// 编译期注入的签名密钥 (CI 与主插件共用同一 GitHub Secret); 未注入时为兜底值
NSString *KGCompiledSecret(void);
// 密钥指纹: SHA256 十六进制前 8 位 (确认与插件端注入的一致)
NSString *KGSecretFingerprint(NSString *secret);

// UDID 归一化: 大写 + 只留 A-Z0-9; 空返回 nil
NSString *KGAuthNormalizeUDID(NSString *raw);

// UDID -> 名单键 (32 位大写 HEX); 归一化失败返回 nil
NSString *KGAuthHashForUDID(NSString *udid);

// UDID 看起来是否合法 (归一化后 >= 8 位)
BOOL KGAuthUDIDLooksValid(NSString *udid);
// UDID 展示用: 前 8 位 + … + 后 4 位 (太长时截断)
NSString *KGAuthShortUDID(NSString *udid);

// 日期
uint32_t KGDayIndexFromNow(NSInteger daysFromNow);
NSString *KGDateTextForDayIndex(uint32_t idx);

// 生成白名单文件内容 (devices = {H32: @(dayIndex)})
NSData *KGAuthBuildJSON(NSString *secret, NSInteger ts, NSDictionary<NSString *, NSNumber *> *devices);
// 解析并验签; 通过返回 {H32: @(dayIndex)}, 否则 nil
NSDictionary<NSString *, NSNumber *> *KGAuthParseJSON(NSData *json, NSString *secret);

// ---- 离线授权串 (v2.1.0, v2.2.0 支持自定义期限) ----
// 客户端默认「纯离线模式」下的唯一授权通道: 生成一段文本发给客户,
// 客户在控制 App 粘贴导入即授权, 全程不需要任何网络(所以也不需要梯子)。
//   串 = "SVBOFFLINE1:" + base64(JSON{"h":H32,"e":到期dayIndex,"t":ts,"s":sig})
//   签名原文 = "SVBGOFFLINE/v1|<H32>|<e>|<t>", HMAC-SHA256(secret, 原文) 全 32 字节小写 hex
//   插件端导入时会: ① 校验 H32 == 本机(一串只对一台设备有效); ② 验签;
//                  ③ 期限完全按这里传入的 dayIndex 算 —— v10.2.0 起不再截断,
//                     因为客户端会把 h/e/t/s 全字段存下来并每次判定时复验签名,
//                     客户手改任何一位都会验签失败、记录作废。
//   注意: 离线串一旦发出, 在到期前无法远程收回 —— 想控制节奏就签短一点。
NSString *KGAuthBuildOfflineTicket(NSString *secret, NSString *udid, uint32_t dayIndex);
// 展示用: 过长时截断成 "头…尾"
NSString *KGAuthShortTicket(NSString *ticket);
