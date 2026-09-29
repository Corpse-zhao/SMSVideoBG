#import <Foundation/Foundation.h>

// ============================================================
// 授权模块 v10.0.0 —— UDID 白名单制 (彻底取代 v1.9 ~ 9.9 的离线激活码)
//
//   流程:
//     ① 控制App「授权」页直接读本机 UDID, 客户复制发给作者;
//     ② 作者在签发 App 里输入 UDID 点「签发授权」-> 写进远端白名单
//        auth.json (revoke 分支);
//     ③ 插件每 30 分钟 (或打开控制App / 联网校验时) 拉取白名单,
//        验签通过 + 本机 UDID 命中 + 未过期 = 已授权;
//     ④ 作者在签发 App 里删掉某个 UDID -> 对方设备最多 30 分钟掉授权。
//
//   隐私: 仓库里存的是 SHA256("SMSVideoBG-AUTH/v1|<归一化UDID>") 前 16 字节
//         的大写十六进制 (32 位), 不存 UDID 原文; UDID 原文只在双方本机。
//
//   auth.json:
//     {"v":1,"ts":<unix秒>,"devices":{"<H32>":<到期dayIndex>},"sig":"<64位hex>"}
//     到期 dayIndex = 自 2020-01-01 UTC 起的天数; 4294967295 = 永久
//     签名原文 = "SVBAUTH/v1|<ts>|<H32=dayIndex 升序逗号连接>"
//     签名算法 = HMAC-SHA256(secret, 原文) 全 32 字节小写十六进制
// ============================================================

#define SVB_AUTH_FOREVER 4294967295u
#define SVB_AUTH_MAX_OFFLINE_DAYS 30.0   // 离线超过这个天数要重新联网校验

typedef NS_ENUM(NSInteger, SVBAuthState) {
    SVBAuthStateNoUDID       = 0,   // 读不到设备 UDID, 无法授权
    SVBAuthStateUnauthorized = 1,   // 本机不在授权名单里
    SVBAuthStateAuthorized   = 2,   // 已授权且在有效期内
    SVBAuthStateExpired      = 3,   // 已过期 (作者可远程续期)
    SVBAuthStateOffline      = 4,   // 需要联网校验 (首次激活 / 离线过久)
};

// ---- 设备 ----
// 本机 UDID (真 UDID 优先, 退到硬件序列号; 读不到返回 nil)
NSString *SVBAuthUDID(void);
// 识别方式文案 ("硬件 UDID" / "硬件序列号" / "读不到")
NSString *SVBAuthUDIDSource(void);
// 归一化: 大写 + 只留 A-Z0-9
NSString *SVBAuthNormalizeUDID(NSString *raw);
// UDID -> 名单键 (SHA256 前 16 字节, 32 位大写 HEX); 与签发 App 严格一致
NSString *SVBAuthHashForUDID(NSString *udid);
// 本机名单键 (无 UDID 返回 nil)
NSString *SVBAuthDeviceHash(void);

// ---- 授权判定 ----
// 读缓存判定 (内部按 30 分钟节流发起后台拉取), detail 回传到期/原因文本
SVBAuthState SVBAuthCurrentState(NSString **detail);
// 门禁便捷入口 (插件各处使用)
BOOL SVBAuthIsAuthorized(void);
#define SVBIsLicensed() SVBAuthIsAuthorized()

// 状态 -> 人话
NSString *SVBAuthStateText(SVBAuthState st, NSString *detail);

// ---- 同步 / 缓存 ----
void SVBAuthRefreshIfNeeded(BOOL force);     // force=YES 立即拉一次
// 作废 SVBAuthIsAuthorized 的 60 秒判定缓存 (拉取成功后内部自动调用;
// 控制 App 收到同步完成通知时也可以主动调一次, 让界面立刻反映新结论)
void SVBAuthInvalidateCache(void);
NSInteger SVBAuthCachedCount(void);          // 缓存名单里的台数
NSTimeInterval SVBAuthLastSyncTime(void);    // 上次成功同步时间 (0 = 从未)
BOOL SVBAuthCachedHasSelf(NSString **expText);  // 本机命中缓存名单? 回传到期文本

// ---- 日期工具 (与签发 App 对齐) ----
uint32_t SVBAuthDayIndexNow(void);
NSString *SVBAuthDateTextForDayIndex(uint32_t idx);
