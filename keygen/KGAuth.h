#import <Foundation/Foundation.h>

// ============================================================
// 授权核心 (签发端 v2.4.0) —— 纯离线授权串 + 产品位
//
//   与插件端 SVBAuth.m / MVBAuth.m **严格一致** (指纹算法三处必须完全相同):
//     设备指纹 H32 = SHA256("VideoBG-AUTH/v1|<归一化UDID>") 前 16 字节 -> 32 位大写 HEX
//     归一化       = 大写 + 只留 A-Z0-9
//
//   ★ 什么是产品位 (v2.4.0 新增)
//     「信息视频背景」与「备忘录视频背景」是两个独立插件, 但共用同一把签名密钥、
//     同一套指纹算法 —— 所以同一台设备在两版里算出的 H32 完全一样。签发时多填一个
//     产品位, 就能决定这个码给谁用:
//       · "all"   -> 两版都能导入 (通用码: 卖全家桶 / 自己用省事)
//       · "sms"   -> 只有信息视频背景认
//       · "memos" -> 只有备忘录视频背景认
//     插件端导入/复验时会拿这个字段做放行判定, 并用它重建签名原文。
// ============================================================

// 产品位取值
#define KG_PRODUCT_ALL    @"all"
#define KG_PRODUCT_SMS    @"sms"
#define KG_PRODUCT_MEMOS  @"memos"

// 产品位 -> 人话 (UI 展示用)
NSString *KGProductText(NSString *product);

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

// ---- 离线授权串 (v2.1.0; v2.2.0 自定义期限; v2.4.0 加产品位) ----
// 客户端默认「纯离线模式」下的唯一授权通道: 生成一段文本发给客户,
// 客户在控制 App 粘贴导入即授权, 全程不需要任何网络(所以也不需要梯子)。
//   串 = "VIDEOBGOFFLINE1:" + base64(JSON{"h":H32,"e":到期dayIndex,"t":ts,
//                                          "s":sig,"p":产品位})
//   签名原文 = "VIDEOBG/v1|<p>|<H32>|<e>|<t>", HMAC-SHA256(secret, 原文) 全 32 字节小写 hex
//   插件端导入时会: ① 校验 H32 == 本机(一串只对一台设备有效); ② 验签;
//                  ③ 校验产品位 (all 或本插件标识);
//                  ④ 期限完全按这里传入的 dayIndex 算 —— 不再截断,
//                     因为客户端会把 h/e/t/s/p 全字段存下来并每次判定时复验签名,
//                     客户手改任何一位都会验签失败、记录作废。
//   product 传 nil / 空串时按 "all"(通用) 处理。
//   注意: 离线串一旦发出, 在到期前无法远程收回 —— 想控制节奏就签短一点。
NSString *KGAuthBuildOfflineTicket(NSString *secret, NSString *udid, uint32_t dayIndex,
                                   NSString *product);
// 展示用: 过长时截断成 "头…尾"
NSString *KGAuthShortTicket(NSString *ticket);
