#import <Foundation/Foundation.h>

// ============================================================
// 激活码签发 App — 算法核心 (与插件端 SVBLicense.m / tools/license_gen.py 严格一致)
//
//   payload(10B) = 设备码原始5B | 到期天数(uint32 BE) | 格式版本(0x01)
//   签名         = HMAC-SHA256(secret, payload) 前 5 字节
//   激活码       = Base32(payload + 签名) -> 24 字符, 显示为 6 组 4 字符
//   Base32 字母表 = ABCDEFGHJKLMNPQRSTUVWXYZ23456789 (去 I O 0 1)
//   到期天数     = 自 2020-01-01 UTC 起的天数, 0xFFFFFFFF = 永久
// ============================================================

// 编译期注入的签名密钥 (CI 与主插件共用同一 GitHub Secret); 未注入时为兜底值
NSString *KGCompiledSecret(void);

// 密钥指纹: SHA256 十六进制前 8 位 (用来确认与插件编译时注入的一致)
NSString *KGSecretFingerprint(NSString *secret);

// 设备码清洗: 大写 + 只留 Base32 字符; 合法(8 字符)返回原样, 否则 nil
NSString *KGDeviceNormalize(NSString *raw);

// 每 4 个字符插一个 '-': ABCDEFGH -> ABCD-EFGH
NSString *KGGrouped(NSString *s);

// 从现在起 daysFromNow 天后对应的到期天数索引 (自 2020-01-01 UTC)
uint32_t KGDayIndexFromNow(NSInteger daysFromNow);

// 到期天数索引 -> UTC 日期文本 "2027-09-29"; 0xFFFFFFFF -> "永久"
NSString *KGDateTextForDayIndex(uint32_t idx);

// 签发一枚激活码
//   secret     签名密钥
//   device     设备码 ("ABCD-EFGH"); universal=YES 时忽略
//   universal  YES = 通用码 (不绑设备)
//   forever    YES = 永久
//   days       有效期天数 (forever=NO 时生效, 必须 > 0)
//   expiryText 回传到期描述 ("永久" / "2027-09-29")
//   error      回传错误描述
// 成功返回格式化激活码 (6 组 4 字符), 失败返回 nil
NSString *KGBuildCode(NSString *secret, NSString *device, BOOL universal,
                      BOOL forever, NSInteger days,
                      NSString **expiryText, NSString **error);

// 校验一枚激活码 (本地自检 / 验客户回传的码), 返回人话结论
NSString *KGVerifyCode(NSString *secret, NSString *code, NSString *device);
