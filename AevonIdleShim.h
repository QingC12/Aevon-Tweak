#import <Foundation/Foundation.h>

/// 有浮窗时压住系统空闲锁屏（V0.0.51，AevonIdleNoLockV51）。
///
/// 为什么必须做在 ObjC 里：要 swizzle SpringBoard 私有的
/// `SBIdleTimerGlobalCoordinator`，Swift 侧没有方便的入口，
/// 而本工程的约定就是「ObjC 只做桥接垫片」，正好放这里。
///
/// 双通道：
///   ① 公开 API `UIApplication.isIdleTimerDisabled` —— 在 SpringBoard 进程里设真；
///   ② 私有类 `SBIdleTimerGlobalCoordinator` 的
///      `isIdleTimerDisabled` / `isDisabled` 两个 getter 直接返回 YES（存在哪个 hook 哪个）。
/// 只要有一个生效就不会黑屏；两个都失效也不会有副作用（我们只改返回值，不动别的逻辑）。
void AevonIdleSetActive(BOOL on);

/// 当前是否处于「压住空闲锁屏」状态（日志 / 幂等用）
BOOL AevonIdleIsActive(void);
