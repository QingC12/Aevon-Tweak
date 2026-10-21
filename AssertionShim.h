#import <Foundation/Foundation.h>

/// 偏好写入（在 Objective-C 中调用 CFPreferences，规避 Swift 对 CFPropertyListRef 的类型推断歧义）。
/// 读写域与设置界面（Preferences.framework）一致：com.splitkit.tweak。
void SKPrefSetBool(NSString *key, BOOL value);
void SKPrefSetInt(NSString *key, NSInteger value);

@interface SKAssertionShim : NSObject
+ (void)acquireKeepAliveForPID:(int)pid;
+ (void)releaseKeepAliveForPID:(int)pid;
@end
