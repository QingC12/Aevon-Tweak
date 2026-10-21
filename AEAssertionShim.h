#import <Foundation/Foundation.h>

/// 偏好写入（在 Objective-C 中调用 CFPreferences，规避 Swift 对 CFPropertyListRef 的类型推断歧义）。
/// 读写域与设置界面（Preferences.framework）一致：com.aevon.tweak。
void AEPrefSetBool(NSString *key, BOOL value);
void AEPrefSetInt(NSString *key, NSInteger value);

@interface AEAssertionShim : NSObject
+ (void)acquireKeepAliveForPID:(int)pid;
+ (void)releaseKeepAliveForPID:(int)pid;
@end
