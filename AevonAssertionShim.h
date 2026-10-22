#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 偏好写入（在 Objective-C 中调用 CFPreferences，规避 Swift 对 CFPropertyListRef 的类型推断歧义）。
/// 读写域与设置界面（Preferences.framework）一致：com.Aevon。
void AevonPrefSetBool(NSString *key, BOOL value);
void AevonPrefSetInt(NSString *key, NSInteger value);
void AevonPrefSetDouble(NSString *key, double value);

@interface AevonAssertionShim : NSObject
+ (void)acquireKeepAliveForPID:(int)pid;
+ (void)releaseKeepAliveForPID:(int)pid;
/// 仅恢复进程执行（不取断言）：suspended 拉起的 App 必须恢复才会渲染画面。
+ (void)resumePID:(int)pid;
@end

/// 取 App 图标（SpringBoard 私有：SBIconController -applicationIconImageForBundleIdentifier:format:scale:）。
/// 全程 @try/@catch，取不到返回 nil —— 调用方必须准备文字兜底，绝不因图标缺失而失败。
UIImage *AevonIconImage(NSString *bundleID, CGFloat scale);

/// V0.0.32：跨进程热区配置通道（notify_set_state / notify_get_state）。
/// 沙盒 App 读不到 com.Aevon 偏好域、也未必能读 jbroot 文件，但 notify(3) 状态
/// 在沙盒里通用 —— SpringBoard 写入后，注入 App 的 AevonGuard 直接读。
/// 打包：x(10bit) y(10bit) w(8bit) h(10bit) enabled(1bit) + 版本标记(8bit)。
void AevonNotifySetZone(double x, double y, double w, double h, int enabled);
/// 读到有效配置返回 1，否则 0（不改动出参）。
int AevonNotifyGetZone(double *x, double *y, double *w, double *h, int *enabled);
