/* V0.3.28（AevonSysAssertV328）：跟踪期间压制系统手势 —— Stheno 第 ④ 层的移植。
 *
 * 反汇编依据（ScreenCore.dylib `SCArcGestureCoordinator -sc_acquireSystemGestureDisableAssertion`，
 * 0x27f0c）：
 *
 *   Class mgr = NSClassFromString(@"SBSystemGestureManager");
 *   id mdm = [mgr mainDisplayManager];
 *   SEL sel = @selector(acquireSystemGestureDisableAssertionForReason:exceptSystemGestureTypes:);
 *   id ex  = [mdm respondsToSelector:@selector(deviceHardwareButtonGestureTypes)]
 *          ? [mdm deviceHardwareButtonGestureTypes] : nil;
 *   id a   = [mdm acquireSystemGestureDisableAssertionForReason:@"ScreenCoreArcMenuGesture"
 *                                     exceptSystemGestureTypes:ex];
 *
 * Stheno 用它把「跟踪中的系统手势」整体压住，`exceptSystemGestureTypes` 单独保护
 * 电源键/音量键手势。Aevon 主库同样在 SpringBoard 进程里，这套接口可以直接用。
 *
 * ⛔ 安全线（写在最前面，改这个文件前先读完）：
 *   断言不释放 = 用户**永久失去右滑返回**，而且 respring 之前无法自愈。
 *   所以：① acquire / release 都幂等；② Tick 每拍检查，超过 5.0s 无条件释放；
 *        ③ 任何一步 respondsToSelector 不过就返回 NULL，绝不硬调；④ 全程 @try。
 */

#ifndef AEVON_GRIP_ASSERT_H
#define AEVON_GRIP_ASSERT_H

/* 申请断言。reason 只用于系统侧记账（纯 ASCII）。失败（含任何私有接口缺失）静默返回，
 * 调用方把它当成「没拿到」继续跑 —— 断言是加速项，不是功能前置条件。
 *
 * 返回 void 而不是句柄：本文件第一版返回 `void *` 并在内部 `CFBridgingRetain`
 * （+1 retain），而调用点根本不接返回值 —— 那就是每呼一次盘泄漏一个断言对象。
 * 句柄由本文件的静态变量持有，外部只需要 Acquire / Release 两个动词。 */
void AevonGripAssertAcquire(const char *reason);

/* 释放。幂等：没持有时调用是空操作，重复调用也是空操作。 */
void AevonGripAssertRelease(void);

/* 超时兜底：由已有的 0.28s 节拍器调用。持有超过 5.0s 强制释放。 */
void AevonGripAssertTick(void);

/* 只读取证：返回 1 = 当前持有断言。日志用。 */
int AevonGripAssertHeld(void);

#endif /* AEVON_GRIP_ASSERT_H */
