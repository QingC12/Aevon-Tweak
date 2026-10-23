#import "AevonIdleShim.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

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

/* V0.0.55（AevonIdleAssertV55）：真正让系统「以为有人在用」。
 *
 * Aevon(48) 第 3 条已经第三次反馈「主悬浮窗开启期间还是会随着系统设置的时间黑屏锁屏」，
 * Aevon(48) 日志里那行写得很清楚：
 *   `已启用空闲计时器重置通道（resetIdleTimer 未命中，仅保留 getter 兜底，每 12 秒一次）`
 * —— 单例没找到、reset 方法没命中，等于整条通道空转。
 *
 * 这里换成正路：SpringBoard 的 `SBIdleTimerGlobalCoordinator` 支持
 * `acquireIdleTimerDisableAssertionForReason:`，拿到的是一个断言对象，
 * 只要持有它就等于「本进程声明：别锁屏」（和 App 里 setIdleTimerDisabled 同语义，
 * 但作用在 SpringBoard 自己身上，正好是我们需要的）。
 * 关闭最后一个浮窗时 `invalidate` 归还 —— 绝不永久禁用锁屏。
 */
static id gAevonIdleAssertion = nil;

static BOOL AevonIdleAcquireAssertion(void) {
    if (gAevonIdleAssertion != nil) { return YES; }
    id coordinator = AevonIdleCoordinatorInstance();
    if (coordinator == nil) { return NO; }
    for (NSString *name in @[@"acquireIdleTimerDisableAssertionForReason:",
                             @"_acquireIdleTimerDisableAssertionForReason:",
                             @"acquireIdleTimerDisableAssertionForReason"]) {
        SEL sel = NSSelectorFromString(name);
        if (![coordinator respondsToSelector:sel]) { continue; }
        @try {
            id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id assertion = fn(coordinator, sel, @"Aevon 浮窗播放中");
            if (assertion != nil) {
                gAevonIdleAssertion = assertion;
                NSLog(@"[Aevon] 空闲锁屏：已取得系统禁用断言（%@）", name);
                return YES;
            }
        } @catch (NSException *exception) {
        }
    }
    return NO;
}

static void AevonIdleReleaseAssertion(void) {
    if (gAevonIdleAssertion == nil) { return; }
    @try {
        id assertion = gAevonIdleAssertion;
        gAevonIdleAssertion = nil;
        if ([assertion respondsToSelector:NSSelectorFromString(@"invalidate")]) {
            void (*fn)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
            fn(assertion, NSSelectorFromString(@"invalidate"));
        }
        NSLog(@"[Aevon] 空闲锁屏：已归还系统禁用断言");
    } @catch (NSException *exception) {
    }
}

/* V0.0.55（AevonLockBlockV55）：最后一道闸 —— 直接拦掉「空闲触发的锁屏请求」。
 *
 * 断言 + 重置都可能被系统某条判定路径绕过（前两版已经证明），
 * 所以这里在真正的锁屏入口 `SBLockScreenManager -lockUIFromSource:withOptions:` 上做判定：
 *   · 有浮窗 → 丢弃这次锁屏请求（屏幕不会黑，也不会进锁屏）；
 *   · 侧键手动锁屏（source = 1）永远放行 —— 用户主动按电源键必须能锁。
 * 每次请求都打一行 source 值（限频），下一版就能确证枚举是否猜对。
 */
typedef void (*AevonLockUIFn)(id, SEL, long long, id);
typedef void (*AevonLockUIFnCompletion)(id, SEL, long long, id, id);
static AevonLockUIFn gAevonOrigLockUI = NULL;
static AevonLockUIFnCompletion gAevonOrigLockUICompletion = NULL;
static BOOL gAevonLockBlockInstalled = NO;

static const long long AevonLockSourceLockButton = 1;

static void AevonLockUIFiltered(id self, SEL _cmd, long long source, id options) {
    if (gAevonIdleActive && source != AevonLockSourceLockButton) {
        static CFTimeInterval lastAt = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastAt > 2.0) {
            lastAt = now;
            NSLog(@"[Aevon] 已拦下空闲锁屏请求（source=%lld，有浮窗在显示）AevonLockBlockV55", source);
        }
        return;
    }
    if (gAevonOrigLockUI != NULL) { gAevonOrigLockUI(self, _cmd, source, options); }
}

static void AevonLockUIFilteredCompletion(id self, SEL _cmd, long long source, id options, id completion) {
    if (gAevonIdleActive && source != AevonLockSourceLockButton) {
        if (completion != nil) {
            @try {
                void (^block)(BOOL) = completion;
                block(NO);
            } @catch (NSException *exception) {
            }
        }
        return;
    }
    if (gAevonOrigLockUICompletion != NULL) {
        gAevonOrigLockUICompletion(self, _cmd, source, options, completion);
    }
}

static void AevonIdleInstallLockBlock(void) {
    if (gAevonLockBlockInstalled) { return; }
    @try {
        Class cls = objc_getClass("SBLockScreenManager");
        if (cls == Nil) { return; }
        gAevonLockBlockInstalled = YES;

        SEL sel = NSSelectorFromString(@"lockUIFromSource:withOptions:");
        Method method = class_getInstanceMethod(cls, sel);
        if (method != NULL) {
            gAevonOrigLockUI = (AevonLockUIFn)method_setImplementation(method, (IMP)AevonLockUIFiltered);
            NSLog(@"[Aevon] 空闲锁屏：已接管 lockUIFromSource:withOptions:");
        }
        SEL sel2 = NSSelectorFromString(@"lockUIFromSource:withOptions:completion:");
        Method method2 = class_getInstanceMethod(cls, sel2);
        if (method2 != NULL) {
            gAevonOrigLockUICompletion =
                (AevonLockUIFnCompletion)method_setImplementation(method2, (IMP)AevonLockUIFilteredCompletion);
            NSLog(@"[Aevon] 空闲锁屏：已接管 lockUIFromSource:withOptions:completion:");
        }
    } @catch (NSException *exception) {
    }
}

void AevonIdleSetActive(BOOL on) {
    BOOL changed = (gAevonIdleActive != on);
    gAevonIdleActive = on;

    if (on) {
        AevonIdleInstallHook();
        AevonIdleInstallLockBlock();
        AevonIdleAcquireAssertion();
    } else {
        AevonIdleReleaseAssertion();
    }

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
    AevonIdleInstallLockBlock();
    BOOL assertion = AevonIdleAcquireAssertion();
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
    // V0.0.55：断言拿到也算「通道已就绪」—— 它比 reset 更硬
    return assertion || reset;
}

BOOL AevonIdleIsActive(void) {
    return gAevonIdleActive;
}
