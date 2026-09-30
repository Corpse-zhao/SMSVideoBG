#import <Foundation/Foundation.h>

// ============================================================
// 授权模块 v10.3.0 —— 纯离线授权串 (只有这一条通道)
//
//   流程:
//     ① 控制App「授权」页读本机 UDID, 客户复制发给作者;
//     ② 作者在签发 App 里粘贴 UDID, 选有效天数, 点「签发」-> 得到一段
//        以 SVBOFFLINE1: 开头的授权串, 复制发给客户;
//     ③ 客户在控制 App「粘贴离线授权」导入 -> 立即授权。
//
//   本模块**不发起任何网络请求** —— 客户国内网络直连即可, 完全不需要梯子。
//   判定 = 纯本地 HMAC 验签 + 到期日比较。
//
//   隐私: 授权串里带的是 SHA256("SMSVideoBG-AUTH/v1|<归一化UDID>") 前 16 字节
//         的大写十六进制 (32 位, 即 H32 指纹), 不暴露 UDID 原文。
//
//   授权串格式:
//     "SVBOFFLINE1:" + base64(JSON{"h":H32,"e":到期dayIndex,"t":ts,"s":64位hex})
//     到期 dayIndex = 自 2020-01-01 UTC 起的天数; 4294967295 = 永久
//     签名原文 = "SVBGOFFLINE/v1|<H32>|<e>|<t>", HMAC-SHA256(secret, 原文) 全 32 字节小写 hex
//
//   本地记录 (配置键 auth_offline) 会把 h/e/t/s 全字段存下来, **每次判定都复验
//   一次签名** —— 因此有效期完全按作者签发的天数, 没有上限; 客户手改 plist 里
//   任何一位都会验签失败、记录作废。
//
//   代价: 纯离线无法远程撤销 —— 授权串一旦发出, 只能等到期。想控制节奏就签短一点。
// ============================================================

#define SVB_AUTH_FOREVER 4294967295u

typedef NS_ENUM(NSInteger, SVBAuthState) {
    SVBAuthStateNoUDID       = 0,   // 读不到设备 UDID, 无法授权
    SVBAuthStateUnauthorized = 1,   // 还没有导入授权串
    SVBAuthStateAuthorized   = 2,   // 已授权且在有效期内
    SVBAuthStateExpired      = 3,   // 已过期 (找作者要一段新的)
    SVBAuthStateOffline      = 4,   // 保留值 (v10.3.0 起不再产生: 已无联网校验)
};

// ---- 设备 ----
// 本机 UDID (真 UDID 优先, 退到硬件序列号; 读不到返回 nil)
NSString *SVBAuthUDID(void);
// 识别方式文案 ("硬件 UDID" / "硬件序列号" / "读不到")
NSString *SVBAuthUDIDSource(void);
// 归一化: 大写 + 只留 A-Z0-9
NSString *SVBAuthNormalizeUDID(NSString *raw);
// UDID -> 指纹键 (SHA256 前 16 字节, 32 位大写 HEX); 与签发 App 严格一致
NSString *SVBAuthHashForUDID(NSString *udid);
// 本机指纹键 (无 UDID 返回 nil)
NSString *SVBAuthDeviceHash(void);

// ---- 授权判定 (纯本地, 零网络) ----
// detail 回传到期/原因文本
SVBAuthState SVBAuthCurrentState(NSString **detail);
// 门禁便捷入口 (插件各处使用)
BOOL SVBAuthIsAuthorized(void);
#define SVBIsLicensed() SVBAuthIsAuthorized()

// 状态 -> 人话
NSString *SVBAuthStateText(SVBAuthState st, NSString *detail);

// 作废 SVBAuthIsAuthorized 的 60 秒判定缓存 (导入/清除授权串后立即生效)
void SVBAuthInvalidateCache(void);

// ---- 离线授权串 (作者签发 -> 客户粘贴) ----
// 导入: 校验①绑定本机指纹 ②签名 ③未过期; message 回传结果文案
BOOL SVBAuthImportTicket(NSString *text, NSString **message);
// 清除已导入的授权 (本机变回未授权)
void SVBAuthClearTicket(void);
// 本地有有效授权串? 回传到期文本
BOOL SVBAuthHasOfflineTicket(NSString **expText);
// 人话描述 (无则 "无")
NSString *SVBAuthOfflineTicketInfo(void);

// ---- 诊断 (纯本地, 不联网) ----
// 返回人话报告: 本机 UDID/指纹、当前授权状态、本地授权串内容与验签结果。
NSString *SVBAuthDiagnose(void);

// ---- 日期工具 (与签发 App 对齐) ----
uint32_t SVBAuthDayIndexNow(void);
NSString *SVBAuthDateTextForDayIndex(uint32_t idx);
