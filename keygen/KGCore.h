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

// 清洗用户输入: 去空白/分隔符, 转大写, 只留 Base32 字符
NSString *KGCodeNormalize(NSString *raw);

// 从 8 字节设备码 → 格式化成 ABCD-EFGH (用于展示/核对)
NSString *KGDeviceCodeFromBytes(NSData *dev5);

// v1.2.0: 设备输入统一入口 —— 现在既能收 8 位设备码, 也能收硬件标识/UDID/序列号
//   输入 "ABCD-EFGH"  : 按设备码解码成 5 字节
//   输入 其它(≥9位)   : 按归一化后的硬件标识做 SHA256, 取前 5 字节 (与插件端一致)
//   mode 回传识别结果 ("设备码" / "硬件标识"), error 回传错误描述
NSData *KGDeviceBytesFromInput(NSString *input, NSString **mode, NSString **error);

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

// v1.4.0: 按绝对到期天数索引签发 (dayIndex = KG_NO_EXPIRE 即永久)。
// 用于强制升级/续签时原样保留客户的剩余有效期。
NSString *KGBuildCodeWithDayIndex(NSString *secret, NSString *device, BOOL universal,
                                  uint32_t dayIndex,
                                  NSString **expiryText, NSString **error);

// 校验一枚激活码 (本地自检 / 验客户回传的码), 返回人话结论
NSString *KGVerifyCode(NSString *secret, NSString *code, NSString *device);

// ============================================================
// 远程作废名单 (v1.1.0, 与插件端 SVBRevoke.m 严格对齐)
//   {"v":1,"ts":<unix秒>,"revoked":["16位大写HEX",...],"sig":"<64位小写HEX>"}
//   签名原文: "SVBGREVOKE/v1|<ts>|<hash 升序逗号连接>"
//   签名算法: HMAC-SHA256(secret, 原文) 全 32 字节十六进制
//   条目      = SHA256(归一化激活码) 前 8 字节的大写十六进制
// ============================================================
NSString *KGRevokeHashForCode(NSString *code);
NSString *KGRevokePayloadString(NSInteger ts, NSArray<NSString *> *hashes);
NSString *KGRevokeSignatureHex(NSString *payload, NSString *secret);
// 解析并验签; 通过返回条目数组(大写), 否则 nil
NSArray<NSString *> *KGRevokeParseJSON(NSData *json, NSString *secret);
// 生成名单文件内容
NSData *KGRevokeBuildJSON(NSString *secret, NSInteger ts, NSArray<NSString *> *hashes);

// ============================================================
// 远程续签表 (v1.3.0, 与插件端 SVBRevoke.m 严格对齐)
//   renewals.json (与作废名单同在 revoke 分支, 签发 App 维护):
//     {"v":1,"ts":<unix秒>,"renew":{"<旧码hash16>":"<新码24字符>"},"sig":"<64位hex>"}
//   签名原文: "SVBGRENEW/v1|<ts>|<hash=新码 归一化升序, 逗号连接>"
//   签名算法: HMAC-SHA256(secret, 原文) 全 32 字节十六进制
//   插件拉到表后: 本机旧码命中 -> 验新码签名合法且未作废 -> 自动换码,
//   客户什么都不用输入 —— 续签直达。
// ============================================================
NSString *KGRenewPayloadString(NSInteger ts, NSDictionary<NSString *, NSString *> *renew);
// 解析并验签续签表; 通过返回 {旧码hash: 新码24字符}, 否则 nil
NSDictionary<NSString *, NSString *> *KGRenewParseJSON(NSData *json, NSString *secret);
// 生成续签表文件内容
NSData *KGRenewBuildJSON(NSString *secret, NSInteger ts, NSDictionary<NSString *, NSString *> *renew);

// ============================================================
// 授权凭证 (v1.2.0, 与插件端 SVBActivationReceipt() 严格对齐)
//   客户在控制 App 授权页复制的一行文本, 发你后粘进本 App 登记台账:
//     SMSVideoBG-ACT1|<设备码8>|<激活码24>|<激活时间Unix秒>|<签名16HEX>
//   签名原文 = "SVBACTIVATE/v1|<设备码>|<激活码>|<激活时间>"
//   签名算法 = HMAC-SHA256(secret, 原文) 前 8 字节的大写十六进制
//   凭证签名只证明「这行是装了插件的设备生成的」, 不含密钥, 无法反推。
// ============================================================
NSString *KGReceiptPayloadString(NSString *dev8, NSString *code24, NSTimeInterval ts);

// 把 8 位设备码格式化成 ABCD-EFGH
NSString *KGGroupDevice8(NSString *dev8);

// 只解码激活码本身 (不验签): 返回 device/universal/forever/exp/daysLeft/dayIndex
NSDictionary *KGDecodeCode(NSString *code);

// 解析客户发来的凭证: 抽段落 -> 验凭证签名 -> 验激活码 -> 校验设备绑定
// 成功返回 @{device, code, activatedAt, exp, forever, universal, daysLeft, ...}
// 失败返回 nil, error 回传人话原因
NSDictionary *KGParseReceipt(NSString *secret, NSString *text, NSString **error);
