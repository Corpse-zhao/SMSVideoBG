#import <Foundation/Foundation.h>

// ============================================================
// 授权模块 (v1.9.0)
//   模型: 离线签名激活码 + 设备绑定 + 到期时间
//   密钥: 编译期宏 SVB_LICENSE_SECRET (CI 从 GitHub Secret 注入,
//         不随公开源码泄漏; 本地未注入时用内置兜底值)
//
//   激活码 = Base32( payload(10B) + HMAC-SHA256(secret,payload)[0..5) )
//   payload:
//     [0..5)   设备码原始 5 字节 (全 0 = 通用码, 不绑设备)
//     [5..9)   到期日 = 自 2020-01-01 UTC 起的天数, uint32 BE
//              0xFFFFFFFF = 永久
//     [9]      格式版本 = 0x01
//   总长 15 字节 -> Base32 24 字符 -> 显示为 6 组 4 字符
// ============================================================

typedef NS_ENUM(NSInteger, SVBLicenseState) {
    SVBLicenseStateUnlicensed  = 0,   // 没有填激活码
    SVBLicenseStateValid       = 1,   // 已激活且在有效期内
    SVBLicenseStateExpired     = 2,   // 已过期
    SVBLicenseStateWrongDevice = 3,   // 激活码绑的是别的设备
    SVBLicenseStateInvalid     = 4,   // 激活码格式/签名错误
    SVBLicenseStateClockTamper = 5,   // 系统时间被回拨
    SVBLicenseStateRevoked     = 6,   // 已被作者远程作废 (见 SVBRevoke.h)
};

// ---- 设备码 (v9.9.11: 硬件标识优先) ----
// 主码 = 硬件标识(真 UDID/序列号) 的 SHA256 前 5 字节 -> Base32 8 字符;
// 越狱环境读不到硬件标识时退回旧算法 (IDFV+机型)。
// 旧码全部保留为「兼容码」, 历史激活码继续有效。
// 只读共享配置里的设备码, 没有返回 nil (插件端用; 插件不生成设备码, 避免与
// 控制App 进程读到的标识不一致导致误判)
NSString *SVBDeviceCode(void);
// 计算/迁移并写入共享配置 (仅供控制App 调用)
NSString *SVBDeviceCodeEnsure(void);
// 本机全部可用设备码 (主码 + 兼容码 + 现算的硬件/旧算法码)
NSArray<NSString *> *SVBDeviceCodeCandidates(void);
// 硬件标识原文 (真 UDID / 序列号, 读不到返回 nil) 与识别方式描述
NSString *SVBHardwareRawIDForDisplay(void);
NSString *SVBHardwareIDSource(void);

// ---- 校验 ----
// 纯函数: 校验激活码, 不改任何状态。detail 回传到期日文本 ("永久" / "2027-10-01")
SVBLicenseState SVBLicenseVerify(NSString *code, NSString **detail);

// 读配置里的激活码做完整判定 (含时钟回拨检测), 带 60 秒缓存
SVBLicenseState SVBLicenseCurrentState(NSString **detail);
// 便捷入口: 插件端每次挂背景前调用
BOOL SVBIsLicensed(void);

// ---- 展示 ----
NSString *SVBLicenseStateText(SVBLicenseState st, NSString *detail);
// 清洗用户输入: 去空白/分隔符, 转大写
NSString *SVBLicenseNormalize(NSString *raw);

// ---- 编码工具 (与签发脚本 tools/license_gen.py 严格对齐) ----
NSString *SVBLicenseB32Encode(NSData *data);
NSData   *SVBLicenseB32Decode(NSString *str);

// ---- 授权凭证 (v9.9.12) ----
// 客户把这行文本发给作者, 作者粘进「激活码签发」App 即可登记台账。
// 本机确实处于已激活状态时返回一行文本, 否则返回 nil:
//   SMSVideoBG-ACT1|<设备码8位>|<激活码24字符>|<激活时间Unix秒>|<签名16位HEX>
//   签名原文 = "SVBACTIVATE/v1|<设备码>|<激活码>|<激活时间>"
//   签名算法 = HMAC-SHA256(secret, 原文) 取前 8 字节的大写十六进制
// 签名只证明「这行凭证确实由装了本插件的设备生成」, 不泄漏密钥。
NSString *SVBActivationReceipt(void);
