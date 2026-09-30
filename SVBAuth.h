#import <Foundation/Foundation.h>

// ============================================================
// 授权模块 v10.4.0 —— 纯离线授权串 + 双轨兼容 + 产品位
//
//   流程:
//     ① 控制App「授权」页读本机 UDID, 客户复制发给作者;
//     ② 作者在「板栗」App 里粘贴 UDID, 选有效天数 + 选产品位(通用/仅信息/仅备忘录),
//        点「签发」-> 得到一段以 VIDEOBGOFFLINE1: 开头的授权串, 复制发给客户;
//     ③ 客户在控制 App「粘贴离线授权」导入 -> 立即授权。
//
//   本模块**不发起任何网络请求** —— 客户国内网络直连即可, 完全不需要梯子。
//   判定 = 纯本地 HMAC 验签 + 到期日比较 + 产品位校验。
//
//   ★ 双轨兼容 (v10.4.0 新增) —— 升级不踢人:
//     新轨 = 「板栗」统一串 (与备忘录版同构, 指纹前缀 VideoBG-AUTH/v1|,
//            密钥 VIDEOBG_LICENSE_SECRET, 产品位 all/sms/memos, 本版认 all+sms)
//     老轨 = v10.6.x 及更早的串 (指纹前缀 SMSVideoBG-AUTH/v1|,
//            密钥 SVB_LICENSE_SECRET, 无产品位) —— 继续有效
//
//   授权串格式:
//     新轨 "VIDEOBGOFFLINE1:" + base64(JSON{"h":H32,"e":到期dayIndex,"t":ts,
//                                           "s":64位hex,"p":产品位})
//     老轨 "SVBOFFLINE1:"    + base64(JSON{"h":H32,"e":到期dayIndex,"t":ts,
//                                           "s":64位hex})
//     到期 dayIndex = 自 2020-01-01 UTC 起的天数; 4294967295 = 永久
//     产品位 p = "all"(两版通用) | "sms"(仅信息App) | "memos"(仅备忘录App)
//     签名原文 = 新轨 "VIDEOBG/v1|<p>|<H32>|<e>|<t>"
//              / 老轨 "SVBGOFFLINE/v1|<H32>|<e>|<t>"
//              HMAC-SHA256(对应密钥, 原文) 全 32 字节小写 hex
//
//   本地记录 (配置键 auth_offline) 会把全字段存下来 (新轨额外存 p 和 v=1),
//   **每次判定都复验一次签名** —— 因此有效期完全按作者签发的天数, 没有上限;
//   客户手改 plist 里任何一位都会验签失败、记录作废。老版本写入的记录没有 v
//   字段, 自动按老轨复验。
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
