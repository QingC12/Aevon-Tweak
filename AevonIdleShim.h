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
///      `isIdleTimerDisabled` / `isDisabled` 等 getter 直接返回 YES（存在哪个 hook 哪个）。
/// 只要有一个生效就不会黑屏；两个都失效也不会有副作用（我们只改返回值，不动别的逻辑）。
void AevonIdleSetActive(BOOL on);

/// V0.0.54（AevonIdleResetV54）：周期性「重新起算空闲计时器」。
///
/// Aevon(47) 第 2 条：只 hook getter 在真机上根本没挡住 —— 看视频 1 分钟照样黑屏锁屏。
/// 说明系统判定路径不读那两个 getter。这里改成直接动计时器本体：
/// `SBIdleTimerGlobalCoordinator` 上的 `resetIdleTimer` / `_resetIdleTimer` /
/// `resetIdleTimerAndCancelPrevious` 等（存在哪个调哪个，幂等），
/// 每次调用都等价于「用户刚碰了一下屏幕」。同时重申 `setIdleTimerDisabled`。
///
/// 返回 YES = 本机确实支持某个 reset 方法（日志据此判断哪条通道生效）。
BOOL AevonIdleReassert(void);

/// 当前是否处于「压住空闲锁屏」状态（日志 / 幂等用）
BOOL AevonIdleIsActive(void);
