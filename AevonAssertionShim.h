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
