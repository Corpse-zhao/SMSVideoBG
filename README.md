# 信息视频背景 (SMSVideoBG)

为 iOS「信息」App 注入视频背景的越狱插件。适配 iPhone 14 Pro Max / iOS 16.6 / roothide 隐根 (rootless 打包, /var/jb)。

## 功能

- 七类界面独立视频背景（每界面独立开关）：
  - 所有信息 / 已知发件人 / 未知发件人 / 未读信息 / 垃圾信息 / 最近删除 / 对话详情
- 总开关 + 全局效果：透明度（默认 65%）/ 模糊度（默认 8）/ 音量（默认关闭）
- 素材管理，两种方式（每个界面一个独立文件夹：all/known/unknown/unread/junk/deleted/chat）：
  - 相册导入：控制 App 内点「＋ 从相册导入视频素材」，可一次多选（最多 20 个），导入结束会逐个报出成功/失败原因
  - Filza 直放：主目录 = 信息 App 数据容器 `.../Data/Application/<MobileSMS 容器>/Library/SMSVideoBG/<界面名>/`（控制 App 素材页底部会显示精确路径，直接照着放即可）；兜底目录 `/var/jb/Library/SMSVideoBG/<界面名>/`

### 导入失败怎么排查（v1.7 起）

导入结束后弹窗会给出每个视频的失败原因（形如 `[文件/public.mpeg-4] 复制失败: ...`）；完整日志在控制 App 主页底部「诊断报告」→「复制全部」。

常见原因：
- 视频还在 iCloud 云端 → 先在「照片」里下载到本机再导入
- 视频过大 / 存储空间不足 → 清理空间后重试
- 单个都失败且日志显示「没有任何可写素材目录」 → 控制 App 没找到信息 App 容器，重启手机后重试
- 控制入口：
  - 独立控制 App「信息视频背景」（SMSVideoBGApp）
  - 系统「设置」/ OneSettings 收纳 面板（SMSPrefs.bundle），面板内可一键打开控制 App（smsvideobg://）

## 构建

推送即触发 GitHub Actions（macOS 运行器 + Apple 原生工具链，arm64e 必需）：

```
gmake package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

产物：`packages/com.nvb.smsvideobg_*_iphoneos-arm64.deb`

## 架构

| 组件 | 说明 |
|---|---|
| Tweak.x + SVBCommon.m | 主插件，注入 MobileSMS |
| PrefsController.m + SVBCommon.m | SMSPrefs.bundle 设置面板 |
| app/*.m + SVBCommon.m | 独立控制 App |
| 共享配置 | NSUserDefaults suite `com.nvb.smsvideobg` + Darwin 通知实时刷新 |
