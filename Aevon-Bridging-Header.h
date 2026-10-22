#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AevonAssertionShim.h"
#import "AevonPresenterShim.h"

/// App 画面容器钩子（V0.0.22）：hook SBDeviceApplicationSceneViewController 的
/// viewDidAppear / viewDidDisappear，用来把入口容器搬进 / 搬出 App 画面容器。
/// 类不存在时 Available 返回 NO，Install 静默跳过。
BOOL AevonSceneHookAvailable(void);
void AevonSceneHookInstall(void);
