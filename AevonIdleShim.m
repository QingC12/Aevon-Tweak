#import "AevonIdleShim.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

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
/* V0.0.54（AevonIdleResetV54）：真正能推迟到期的那几个方法。
 * 只 hook getter 在真机上被证明不够（Aevon(47) 第 2 条：看视频照样 1 分钟锁屏）——
 * 系统的判定路径未必读这两个 getter。周期性调 `resetIdleTimer` 才是「模拟用户活动」，
 * 每次都把空闲计时器重新起算，等价于用户一直在操作屏幕。 */
static id gAevonIdleCoordinator = nil;

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

/// 拿到 `SBIdleTimerGlobalCoordinator` 的单例（不同系统版本单例方法名不一样，逐个试）。
static id AevonIdleCoordinatorInstance(void) {
    if (gAevonIdleCoordinator != nil) { return gAevonIdleCoordinator; }
    Class cls = objc_getClass("SBIdleTimerGlobalCoordinator");
    if (cls == NULL) { return nil; }
    for (NSString *name in @[@"sharedInstance", @"sharedCoordinator", @"globalCoordinator"]) {
        SEL sel = NSSelectorFromString(name);
        if (![cls respondsToSelector:sel]) { continue; }
        @try {
            // 用 methodForSelector + 函数指针（ARC 下 cast objc_msgSend 容易被编译器拦）
            typedef id (*AevonIdFn)(id, SEL);
            AevonIdFn fn = (AevonIdFn)[(id)cls methodForSelector:sel];
            id inst = fn ? fn((id)cls, sel) : nil;
            if (inst != nil) {
                gAevonIdleCoordinator = inst;
                return inst;
            }
        } @catch (NSException *exception) {
        }
    }
    return nil;
}

/// 把空闲计时器重新起算（V0.0.54）。
///
/// 系统里这个方法叫法随版本变，全部试一遍 —— 命中哪个都够用，重复调用是幂等的。
/// 返回 YES = 至少命中一个，说明这条兜底路径真实存在（日志据此判断哪条通道生效）。
static BOOL AevonIdleResetCoordinator(void) {
    id inst = AevonIdleCoordinatorInstance();
    if (inst == nil) { return NO; }
    BOOL hit = NO;
    NSArray<NSString *> *names = @[@"resetIdleTimer",
                                   @"_resetIdleTimer",
                                   @"resetIdleTimerAndCancelPrevious",
                                   @"_resetIdleTimerAndCancelPrevious",
                                   @"_updateIdleTimer",
                                   @"_resetIdleTimerIfNecessary"];
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if (![inst respondsToSelector:sel]) { continue; }
        @try {
            typedef void (*AevonVoidFn)(id, SEL);
            AevonVoidFn fn = (AevonVoidFn)[inst methodForSelector:sel];
            if (fn != NULL) {
                fn(inst, sel);
                hit = YES;
            }
        } @catch (NSException *exception) {
        }
    }
    return hit;
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
    /* V0.0.54：另外两个常见别名也一并接管（部分版本判定走 `_isIdleTimerDisabled`
     * 或 `isDisabledIgnoringReasons`，hook 到就多一层保险）。 */
    for (NSString *name in @[@"_isIdleTimerDisabled", @"isDisabledIgnoringReasons"]) {
        SEL sel = NSSelectorFromString(name);
        Method m = class_getInstanceMethod(cls, sel);
        if (m == NULL) { continue; }
        IMP old = method_getImplementation(m);
        if (old == (IMP)AevonIdleGet) { continue; }
        if (gAevonOrigIsDisabled == NULL) {
            gAevonOrigIsDisabled = (BOOL (*)(id, SEL))old;
        }
        method_setImplementation(m, (IMP)AevonIdleGet);
        NSLog(@"[Aevon] 空闲锁屏：已 hook SBIdleTimerGlobalCoordinator %@", name);
    }
    (void)AevonIdleCoordinatorInstance();
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

/// V0.0.54（AevonIdleResetV54）：周期性「重新起算空闲计时器」。
///
/// Swift 侧的 `AevonIdleGuard` 每 12 秒调一次。原来只重申 `setIdleTimerDisabled`，
/// 真机上 1 分钟照样锁屏 —— 说明系统不读那条路径。这里直接动计时器本体：
/// 每一次调用都等价于「用户刚碰了一下屏幕」，看视频再久也不会黑屏。
/// 返回 YES = 本机支持这条通道（日志据此判断哪条生效）。
BOOL AevonIdleReassert(void) {
    if (!gAevonIdleActive) { return NO; }
    AevonIdleInstallHook();
    BOOL reset = AevonIdleResetCoordinator();

    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { return; }
        SEL setter = @selector(setIdleTimerDisabled:);
        if (![app respondsToSelector:setter]) { return; }
        typedef void (*AevonIdleSetter)(id, SEL, BOOL);
        AevonIdleSetter fn = (AevonIdleSetter)[app methodForSelector:setter];
        if (fn != NULL) { fn(app, setter, YES); }
    });
    return reset;
}

BOOL AevonIdleIsActive(void) {
    return gAevonIdleActive;
}
