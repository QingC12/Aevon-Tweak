#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AevonAssertionShim.h"
#import "AevonPresenterShim.h"

/// App 画面容器钩子（V0.0.22）：hook SBDeviceApplicationSceneViewController 的
/// viewDidAppear / viewDidDisappear，用来把入口容器搬进 / 搬出 App 画面容器。
/// 类不存在时 Available 返回 NO，Install 静默跳过。
BOOL AevonSceneHookAvailable(void);
void AevonSceneHookInstall(void);

/// V0.1.6（AevonFullscreenCloseV106）：从「全屏 App 画面容器」反查它承载的是哪个 App。
/// 返回形如 `com.apple.Preferences-default` 的场景标识，或直接是 bundleIdentifier；
/// 全部路径都取不到时返回 nil —— 调用方必须把 nil 当作「未知」而不是「不是同一个 App」。
NSString *AevonSceneIdentifierOfViewController(UIViewController *vc);

/// ── V0.1.7（AevonShieldV107 / AevonObjCProbeV107）：探针安全带 ──
///
/// `AevonShieldRun` 把一段 Swift 代码包进 ObjC 的 @try：
/// Swift 的 do/catch 捕不到 `doesNotRecognizeSelector:` 抛出的异常，ObjC 的 @try 能捕。
/// 返回 nil = 正常；非 nil = 异常描述（调用方写日志即可，SpringBoard 不受影响）。
NSString *AevonShieldRun(void (^block)(void));

/// 以下四个是「全进程类表 / 方法名 / ivar 名 / 安全类名」的 ObjC 实现。
/// 为什么不用 Swift 写：Swift 取 `AnyClass` 元类型会走 swift_dynamicCast，
/// 而那正是 V0.1.6 两次自动注销的崩溃点。
NSArray<NSString *> *AevonAllClassNames(void);
NSArray<NSString *> *AevonMethodNamesForClass(NSString *className);
NSArray<NSString *> *AevonIvarNamesForClass(NSString *className);
NSString *AevonSafeClassName(id object);

/// 用 class_respondsToSelector 判断（不向对象发消息），野对象也安全。
BOOL AevonObjectResponds(id object, NSString *selectorName);

/// 给类发无参工厂消息（先验方法存在再发），取不到返回 nil。
id AevonClassFactoryObject(NSString *className, NSString *selectorName);

/// 全局触摸通道（V0.0.23）：hook `UIApplication -sendEvent:`，
/// 把每个触摸的相位 / 身份 / 坐标交给 Swift 侧做边缘判定。
/// 返回 NO 表示这条通道不可用，调用方继续用视图层通道兜底。
BOOL AevonTouchHookInstall(void);
