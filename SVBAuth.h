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
//
//   v10.1.0 增补 —— 为客户侧"国内网络零依赖"兜底:
//     A. 国内直连源: Gitee(码云) raw 匿名可读, 国内手机直连稳定;
//        地址走配置键 auth_gitee, 未配置时退编译期 SVB_GITEE_URL。
//     B. 离线授权串: 作者在签发 App 生成一段文本发给客户, 客户在控制 App
//        粘贴导入 -> 立即授权, 全程不需要任何网络。
//        串格式: "SVBOFFLINE1:" + base64({"h":H32,"e":到期dayIndex,"t":ts,"s":sig})
//        签名原文 = "SVBGOFFLINE/v1|<H32>|<e>|<t>", 同样 HMAC-SHA256。
//        导入时的规则: ① h 必须等于本机指纹(防止一串通用); ② 验签;
//        ③ 有效期强制截断到 30 天内(离线授权最长续 30 天, 防断网永久白嫖)。
//        一旦成功联网校验且在线名单非空, 就改以在线名单为准 —— 作者删掉
//        UDID 仍然会掉授权, 离线串不会把它救回来。
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

// ---- 自定义授权服务地址 (v10.0.2) ----
// 内置多源: 自定义(若有) + Gitee(若配) + ghfast.top / gh-proxy.com / ghproxy.net
//           三个加速镜像 + api.github.com + raw.githubusercontent.com,
//           全部并发拉取, 取名单自带 ts 最新的一份。
// 想换成自建托管点(如腾讯云 COS)时, 把完整 URL 填进来即可, 无需改代码。
NSString *SVBAuthCustomSourceURL(void);            // nil = 用内置多源
void SVBAuthSetCustomSourceURL(NSString *url);     // 传 nil/空串 = 恢复内置多源
NSInteger SVBAuthCachedCount(void);          // 缓存名单里的台数
NSTimeInterval SVBAuthLastSyncTime(void);    // 上次成功同步时间 (0 = 从未)
BOOL SVBAuthCachedHasSelf(NSString **expText);  // 本机命中缓存名单? 回传到期文本

// ---- Gitee(码云) 名单地址 (v10.1.0, 国内直连首选) ----
// 完整 raw 地址, 形如 https://gitee.com/<用户名>/<仓库名>/raw/<分支>/auth.json
// 匿名可读(仓库需公开), 国内手机直连稳定, 不受 GitHub 被墙影响。
NSString *SVBAuthGiteeURL(void);                   // nil = 未配置
void SVBAuthSetGiteeURL(NSString *url);            // 传 nil/空串 = 清除

// ---- 离线授权串 (v10.1.0, 完全不依赖网络) ----
// 作者在签发 App 里点「生成离线授权串」-> 复制发给客户
// -> 客户在控制 App「粘贴离线授权」-> 立即生效, 全程不需要网络。
// 有效期最长 30 天; 成功联网校验后自动转为在线授权(以作者名单为准)。
BOOL SVBAuthImportTicket(NSString *text, NSString **message);  // 导入, message 回传结果文案
void SVBAuthClearTicket(void);                                 // 清除已导入的离线授权
BOOL SVBAuthHasOfflineTicket(NSString **expText);              // 本地有有效离线授权? 回传到期文本
NSString *SVBAuthOfflineTicketInfo(void);                      // 人话描述 (无则"无")

// ---- 诊断 (v10.1.0) ----
// 同步逐个源探测一遍, 返回人话报告: 本机 UDID/指纹、缓存状态、每个源的结果
// (HTTP 码 / 错误 / 耗时 / 是否验签通过 / 名单台数 / 是否含本机)。
// 会阻塞数秒, 请在后台线程调用。
NSString *SVBAuthDiagnose(void);

// ---- 日期工具 (与签发 App 对齐) ----
uint32_t SVBAuthDayIndexNow(void);
NSString *SVBAuthDateTextForDayIndex(uint32_t idx);
