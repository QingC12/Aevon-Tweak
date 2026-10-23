#import "AevonIdleShim.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/// V0.0.51（AevonIdleNoLockV51）：有浮窗时禁止系统空闲锁屏。
///
/// 用户 Aevon(44) 第 3 条：「使用悬浮窗观看抖音视频时，屏幕会随着系统设置的
/// 1 分钟或者 2 分钟时间黑屏锁屏」。
///
/// 根因：浮窗里的画面是 SpringBoard 进程内的一个场景视图，它**不产生任何用户活动**
/// （触摸都被我们自己吞了 / 用户只是看着不动），于是系统的空闲定时器照常到期 →
/// backboardd 判定空闲 → 锁屏。iOS 里唯一的正路就是让持有窗口的进程声明
/// `idleTimerDisabled`。
///
/// 这里做两条通道，互为兜底：
///   ① `UIApplication.isIdleTimerDisabled`（公开 API，SpringBoard 进程里生效）；
///   ② `SBIdleTimerGlobalCoordinator` 的 getter 被 swizzle 成「有浮窗就 YES」。
/// 只在**至少有一个浮窗**时打开，关掉最后一个窗立刻恢复 —— 绝不让用户忘了关而一直不锁屏。

static BOOL gAevonIdleActive = NO;
static BOOL gAevonIdleInstalled = NO;
static BOOL (*gAevonOrigIsIdleTimerDisabled)(id, SEL) = NULL;
static BOOL (*gAevonOrigIsDisabled)(id, SEL) = NULL;

/// 两个 getter 共用的替换实现：active 时一律 YES，否则走原实现
static BOOL AevonIdleGet(id self, SEL _cmd) {
    if (gAevonIdleActive) { return YES; }
    if (_cmd == @selector(isIdleTimerDisabled) && gAevonOrigIsIdleTimerDisabled != NULL) {
        return gAevonOrigIsIdleTimerDisabled(self, _cmd);
    }
    if (gAevonOrigIsDisabled != NULL) {
        return gAevonOrigIsDisabled(self, _cmd);
    }
    return NO;
}

static void AevonIdleInstallHook(void) {
    if (gAevonIdleInstalled) { return; }
    gAevonIdleInstalled = YES;

    Class cls = objc_getClass("SBIdleTimerGlobalCoordinator");
    if (cls == NULL) {
        NSLog(@"[Aevon] 空闲锁屏：本系统没有 SBIdleTimerGlobalCoordinator，只走 UIApplication 通道");
        return;
    }
    // 只在能拿到原实现时才替换 —— 拿不到就跳过，免得把别处的语义改坏
    SEL sel1 = @selector(isIdleTimerDisabled);
    Method m1 = class_getInstanceMethod(cls, sel1);
    if (m1 != NULL && gAevonOrigIsIdleTimerDisabled == NULL) {
        gAevonOrigIsIdleTimerDisabled = (BOOL (*)(id, SEL))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)AevonIdleGet);
        NSLog(@"[Aevon] 空闲锁屏：已 hook SBIdleTimerGlobalCoordinator isIdleTimerDisabled");
    }
    SEL sel2 = NSSelectorFromString(@"isDisabled");
    Method m2 = class_getInstanceMethod(cls, sel2);
    if (m2 != NULL && gAevonOrigIsDisabled == NULL) {
        gAevonOrigIsDisabled = (BOOL (*)(id, SEL))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)AevonIdleGet);
        NSLog(@"[Aevon] 空闲锁屏：已 hook SBIdleTimerGlobalCoordinator isDisabled");
    }
}

void AevonIdleSetActive(BOOL on) {
    BOOL changed = (gAevonIdleActive != on);
    gAevonIdleActive = on;

    if (on) { AevonIdleInstallHook(); }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { return; }
        SEL setter = @selector(setIdleTimerDisabled:);
        if (![app respondsToSelector:setter]) { return; }
        BOOL current = NO;
        SEL getter = @selector(isIdleTimerDisabled);
        if ([app respondsToSelector:getter]) { current = app.idleTimerDisabled; }
        if (current == on) { return; }
        // BOOL 参数不能走 performSelector:withObject:（那是对象参数），必须直接拿 IMP 调
        typedef void (*AevonIdleSetter)(id, SEL, BOOL);
        AevonIdleSetter fn = (AevonIdleSetter)[app methodForSelector:setter];
        if (fn != NULL) { fn(app, setter, on); }
    });

    if (changed) {
        NSLog(@"[Aevon] 空闲锁屏 %@（%s）", on ? @"已压住" : @"已恢复", on ? "AevonIdleNoLockV51" : "restore");
    }
}

BOOL AevonIdleIsActive(void) {
    return gAevonIdleActive;
}
