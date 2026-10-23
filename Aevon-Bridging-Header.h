#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AevonAssertionShim.h"
#import "AevonPresenterShim.h"
#import "AevonIdleShim.h"
#import "AevonOverlayShim.h"
#import "AevonSceneShim.h"

/// App 画面容器钩子（V0.0.22）：hook SBDeviceApplicationSceneViewController 的
/// viewDidAppear / viewDidDisappear，用来把入口容器搬进 / 搬出 App 画面容器。
/// 类不存在时 Available 返回 NO，Install 静默跳过。
BOOL AevonSceneHookAvailable(void);
void AevonSceneHookInstall(void);

/// 全局触摸通道（V0.0.23）：hook `UIApplication -sendEvent:`，
/// 把每个触摸的相位 / 身份 / 坐标交给 Swift 侧做边缘判定。
/// 返回 NO 表示这条通道不可用，调用方继续用视图层通道兜底。
BOOL AevonTouchHookInstall(void);
