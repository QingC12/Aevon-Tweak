/* V0.3.28（AevonSysAssertV328）：Stheno 第 ④ 层移植 —— 跟踪期压制系统手势。
 * 接口语义与安全线见 AevonGripAssert.h 顶部注释。本文件只做三件事：
 *   ① 按 Stheno 的调用序列申请 SBSystemGestureManager 的 disable 断言；
 *   ② 幂等释放；
 *   ③ 5s 超时强制释放（防泄漏 → 防用户永久失去右滑返回）。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import "AevonGripAssert.h"

/* 标记必须进二进制（纯 ASCII + used）。release dylib strip 之后函数符号名查不到，
 * CI 只能查这些串，见 build.yml 的 V0.3.28 段。 */
__attribute__((used)) static const char AevonSysAssertV328Marker[] = "AevonSysAssertV328";
__attribute__((used)) static const char AevonSysAssertFailsafeV328Marker[] = "AevonSysAssertFailsafeV328";

/* 硬上限：超过这个秒数无条件释放。
 * 为什么是 5.0s：一次呼盘手势从落指到抬手极少超过 3s（识别器自己的 0.9s 上限 +
 * 圆盘交互），5s 留了一倍余量；再长就说明某条收尾路径漏了 release，
 * 此时「释放」的代价远小于「用户右滑返回失灵」。 */
static const double kAevonAssertMaxHold = 5.0;

static id gAssertion = nil;            /* 当前持有的断言对象（强引用，防提前释放） */
static CFTimeInterval gAssertionAt = 0;  /* 申请时刻 */

/* 只调「确认存在且签名是我们的预期」的方法。任何不确定都返回 nil，不硬调。
 * ⛔ 不枚举全类表（0.2.72 SIGTRAP 铁律）：只查具体选择子。 */
static id aev_msg0(id obj, const char *sel) {
    if (obj == nil) { return nil; }
    SEL s = sel_registerName(sel);
    if (![obj respondsToSelector:s]) { return nil; }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(obj, s);
    } @catch (NSException *e) {
        return nil;
    }
}

void AevonGripAssertAcquire(const char *reason) {
    if (gAssertion != nil) {
        /* 已持有：刷新时刻但不重复申请（重复申请会叠出多个断言对象，
         * 一旦漏释放就是「越用越难释放」）。 */
        gAssertionAt = CACurrentMediaTime();
        return;
    }
    @try {
        Class mgr = NSClassFromString(@"SBSystemGestureManager");
        if (mgr == Nil) { return; }
        id mdm = aev_msg0((id)mgr, "mainDisplayManager");
        if (mdm == nil) { return; }

        SEL sel = sel_registerName("acquireSystemGestureDisableAssertionForReason:exceptSystemGestureTypes:");
        if (![mdm respondsToSelector:sel]) { return; }

        /* 硬件按键手势单独豁免：Stheno 也这么做（cfstr `deviceHardwareButtonGestureTypes`），
         * 否则压制期间锁屏键/音量键手势一起失效。取不到就传 nil，退化为「全压」。 */
        id except = aev_msg0(mdm, "deviceHardwareButtonGestureTypes");

        NSString *rsn = (reason != NULL)
            ? [NSString stringWithUTF8String:reason]
            : @"AevonArcMenuGesture";
        if (rsn.length == 0) { rsn = @"AevonArcMenuGesture"; }

        id a = ((id (*)(id, SEL, id, id))objc_msgSend)(mdm, sel, rsn, except);
        if (a == nil) { return; }
        gAssertion = a;
        gAssertionAt = CACurrentMediaTime();
    } @catch (NSException *e) {
        gAssertion = nil;
        gAssertionAt = 0;
    }
}

void AevonGripAssertRelease(void) {
    if (gAssertion == nil) { return; }
    id a = gAssertion;
    gAssertion = nil;
    gAssertionAt = 0;
    @try {
        /* 断言对象的释放方式按能力递减尝试：relinquish / invalidate / 直接 nil。 */
        SEL rq = sel_registerName("relinquish");
        SEL iv = sel_registerName("invalidate");
        if ([a respondsToSelector:rq]) {
            ((void (*)(id, SEL))objc_msgSend)(a, rq);
        } else if ([a respondsToSelector:iv]) {
            ((void (*)(id, SEL))objc_msgSend)(a, iv);
        }
    } @catch (NSException *e) {
        /* 释放失败也不能抛出去 —— 调用点在 -reset 里，抛了会打断手势状态机。 */
    }
}

void AevonGripAssertTick(void) {
    if (gAssertion == nil) { return; }
    if (gAssertionAt <= 0) { AevonGripAssertRelease(); return; }
    if (CACurrentMediaTime() - gAssertionAt > kAevonAssertMaxHold) {
        AevonGripAssertRelease();
    }
}

int AevonGripAssertHeld(void) {
    return (gAssertion != nil) ? 1 : 0;
}
