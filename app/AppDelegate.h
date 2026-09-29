#import <UIKit/UIKit.h>
#import "SVBCommon.h"

// ============================================================
// 信息视频背景 独立控制 App
// 作者: 板栗仁
//  - 总开关 / 全局效果(透明度/模糊度/音量) / 七类界面独立开关
//  - 每界面独立素材管理: 相册导入(PHPicker) / 选用 / 删除
//  - Filza 直接放文件同样生效 (素材文件夹路径在页脚展示)
// ============================================================

@interface SVBAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@interface SVBHomeViewController : UITableViewController
@end

@interface SVBAppMaterialController : UITableViewController
@property (nonatomic, copy) NSString *contextKey;
@property (nonatomic, copy) NSString *contextTitle;
- (instancetype)initWithContext:(NSString *)ctx title:(NSString *)title;
@end

@interface SVBDiagnosticsController : UIViewController
@end

@interface SVBAppIdentityController : UITableViewController
@end

// v1.9.0 授权页: 设备码 / 输入激活码 / 移除激活
@interface SVBLicenseController : UITableViewController
@end
