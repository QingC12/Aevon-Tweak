#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AevonAssertionShim.h"
#import "AevonPresenterShim.h"
#import "AevonSceneDriverShim.h"

/// App 画面容器钩子（V0.0.22）：hook SBDeviceApplicationSceneViewController 的
/// viewDidAppear / viewDidDisappear，用来把入口容器搬进 / 搬出 App 画面容器。
/// 类不存在时 Available 返回 NO，Install 静默跳过。
BOOL AevonSceneHookAvailable(void);
void AevonSceneHookInstall(void);

/// V0.2.99（AevonGripProbeV299）：SBGrabberTongue 探测骨架（方案 A 灰度，默认关）。
/// 类不存在或安装异常返回 NO，调用方只记日志。
BOOL AevonGripHookProbeInstall(void);

/// V0.3.4（AevonGripSystemLegV304，用户定档「路线 A：真正改成 Stheno 式」）：
/// 呼出主通道换成**系统手势识别器腿** —— 全局观察 `UIGestureRecognizer.setState:`，
/// 边沿族识别器在右缘 began 时被认领（外挂 target 跟踪），位移过阈值回调 Swift 呼盘。
/// **常驻安装**（不受 GripHookProbe 开关影响，那开关只控制实例级细节日志）。
/// 返回 NO = 没有可装的 setState:，本腿关闭，调用方照旧用把手 + sendEvent 两条老腿。
BOOL AevonGripSystemLegInstall(void);

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

/// 安全类名：直接用 object_getClass + class_getName，不走 Swift 的 AnyClass 转换
///（Swift 取 `AnyClass` 元类型会走 swift_dynamicCast，而那正是 V0.1.6 两次自动注销的崩溃点）。
NSString *AevonSafeClassName(id object);

/// 用 class_respondsToSelector 判断（不向对象发消息），野对象也安全。
BOOL AevonObjectResponds(id object, NSString *selectorName);

/// 视图宿主链（只读）：`本视图(x,y) ↑ 父视图(x,y) ↑ …`，最多 depth 级。
NSString *AevonViewHostChain(id view, NSInteger depth);

/// 定向名单的类方法名清单（**只查传入的类，不遍历全类表**）。
/// 调用者：AevonWindowView 的开窗路线探测。
NSArray<NSString *> *AevonMethodNamesForClass(NSString *className);

/// V0.2.81（AevonDeadCodeV281）：`AevonAllClassNames` / `AevonIvarNamesForClass` /
/// `AevonClassFactoryObject` / `AevonDescribeRecognizersOfObject` /
/// `AevonObjectIvarSummary` 五个声明随两套启动探针（V0.1.7 / V0.1.14）一并删除。
/// 类表枚举自 0.2.72 起被永久封印（SB 进程全类表 +initialize → swift_dynamicCast SIGTRAP），
/// 定向探测的结论也早已落进日志与逆向报告，留着只是给每次启动多背几百毫秒。

/// 全局触摸通道（V0.0.23）：hook `UIApplication -sendEvent:`，
/// 把每个触摸的相位 / 身份 / 坐标交给 Swift 侧做边缘判定。
/// 返回 NO 表示这条通道不可用，调用方继续用视图层通道兜底。
BOOL AevonTouchHookInstall(void);
