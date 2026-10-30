#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/*
 * V0.2.99（AevonGripProbeV299）：方案 A 灰度探测骨架 —— 呼出主通道贴 Stheno。
 *
 * 目标（用户 Aevon(76) 拍板）：呼出手势换到 hook SBGrabberTongue（系统边缘抓手舌，
 * Stheno 用 Orion hook 同类在其呼出链上被用户实证可行）。本版只做「观察」：
 *   hook 该类的 touches 系列方法，把它收到的触摸阶段/坐标/视图形态打进日志，
 *   不改任何触摸行为（原实现照常转发），为下一版确定呼出手势判据取真机数据。
 *
 * 为什么观察先行：Stheno 符号已 strip，其 hook 的具体方法与手势阈值逆向不到明文；
 *   我们需要先知道「抓手舌在哪些位置、收到什么形状的触摸序列」才能定呼出判据。
 *
 * 安全设计（任何一条不成立就退回原样）：
 *   · Prefs 总开关 GripHookProbe 默认关（灰度，用户在设置里显式打开才装）；
 *   · 类探测失败（iOS 变更 / roothide 环境差异）→ 静默放弃，零副作用；
 *   · 类内安全交换（同 AevonSceneHookSwap 纪律：类自身有实现才 setImplementation，
 *     否则 addMethod + 从父类取原实现 —— 绝不覆盖父类方法）；
 *   · 回调 @try 全包，任何异常 fail-open（照常转发原实现，绝不吞系统手势）；
 *   · 日志限流（同一秒最多 8 行），防抓手舌高频 moved 刷爆 Aevon.log；
 *   · 0.2.72 铁律遵守：只对单个已知类做 method 操作，绝不全类表枚举。
 */

extern void AevonGripProbeTouch(NSInteger phase, CGFloat x, CGFloat y);

static IMP AevonGripOrigBegan = NULL, AevonGripOrigMoved = NULL;
static IMP AevonGripOrigEnded = NULL, AevonGripOrigCancelled = NULL;
static IMP AevonGripOrigSetState = NULL, AevonGripOrig_SetState = NULL;
static BOOL AevonGripHookInstalled = NO;
static CFTimeInterval AevonGripLastLogAt = 0;

static void AevonGripLogRateLimited(NSInteger phase, NSSet *touches, UIView *view) {
    @try {
        CFTimeInterval now = CACurrentMediaTime();
        if (now - AevonGripLastLogAt < 0.125) { return; }
        AevonGripLastLogAt = now;
        UITouch *t = touches.anyObject;
        CGPoint p = t ? [t locationInView:view] : CGPointZero;
        AevonGripProbeTouch(phase, p.x, p.y);
    } @catch (NSException *exception) {
    }
}

#define AEVON_GRIP_TOUCH_HOOK(name, phaseVal)                                            \
static void AevonGripHook##name(id self, SEL _cmd, NSSet *touches, UIEvent *event) {     \
    if (AevonGripOrig##name) {                                                           \
        ((void (*)(id, SEL, NSSet *, UIEvent *))AevonGripOrig##name)(self, _cmd, touches, event); \
    }                                                                                    \
    @try {                                                                               \
        AevonGripLogRateLimited(phaseVal, touches, (UIView *)self);                      \
    } @catch (NSException *exception) {                                                  \
    }                                                                                    \
}

AEVON_GRIP_TOUCH_HOOK(Began, 0)
AEVON_GRIP_TOUCH_HOOK(Moved, 1)
AEVON_GRIP_TOUCH_HOOK(Ended, 2)
AEVON_GRIP_TOUCH_HOOK(Cancelled, 3)

/*
 * V0.3.0（AevonGripProbe2V300，用户 Aevon(78) #3 探针换目标 + 确认「继续探测」）：
 * Aevon(77)/(78) 两轮实锤 SBGrabberTongue 的 view 收不到 touches（系统识别器在
 * view 之前消费触摸）—— [GripHook] 除安装行外零数据，touches 探测目标作废。
 * 换目标：hook 识别器的状态机入口 setState:（公开 API）与 _setState:（私有，
 * 有才装）—— 状态变迁（possible/began/changed/ended/cancelled/failed）是
 * 「系统怎么判呼出」的直接信号。状态变迁每次只发一笔（setState 是状态变更时
 * 调用，不是逐 moved 调用），不限流。仍只观察：原实现照常转发。
 * phase 编码：10 + UIGestureRecognizerState（10=possible 11=began 12=changed
 * 13=ended 14=cancelled 15=failed 16=recognized），与 touches 0~3 区分。
 */
static void AevonGripHookSetState(id self, SEL _cmd, UIGestureRecognizerState state) {
    if (AevonGripOrigSetState) {
        ((void (*)(id, SEL, UIGestureRecognizerState))AevonGripOrigSetState)(self, _cmd, state);
    }
    @try {
        AevonGripProbeTouch(10 + (NSInteger)state, 0, 0);
    } @catch (NSException *exception) {
    }
}

static void AevonGripHook_SetState(id self, SEL _cmd, UIGestureRecognizerState state) {
    if (AevonGripOrig_SetState) {
        ((void (*)(id, SEL, UIGestureRecognizerState))AevonGripOrig_SetState)(self, _cmd, state);
    }
    @try {
        AevonGripProbeTouch(20 + (NSInteger)state, 0, 0);
    } @catch (NSException *exception) {
    }
}

/// 类内安全交换（纪律同 AevonSceneHookSwap）。
static void AevonGripHookSwap(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL || original == NULL) { return; }
    if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        Class superClass = class_getSuperclass(cls);
        *original = superClass ? class_getMethodImplementation(superClass, sel) : NULL;
    } else {
        *original = method_setImplementation(method, replacement);
    }
}

BOOL AevonGripHookProbeInstall(void) {
    if (AevonGripHookInstalled) { return YES; }
    @try {
        Class cls = NSClassFromString(@"SBGrabberTongue");
        if (cls == Nil) {
            AevonGripProbeTouch(-1, 0, 0);   // -1 = 类探测失败（环境差异，下一版换目标）
            return NO;
        }
        AevonGripHookSwap(cls, @selector(touchesBegan:withEvent:),      (IMP)AevonGripHookBegan,      &AevonGripOrigBegan);
        AevonGripHookSwap(cls, @selector(touchesMoved:withEvent:),      (IMP)AevonGripHookMoved,      &AevonGripOrigMoved);
        AevonGripHookSwap(cls, @selector(touchesEnded:withEvent:),      (IMP)AevonGripHookEnded,      &AevonGripOrigEnded);
        AevonGripHookSwap(cls, @selector(touchesCancelled:withEvent:),  (IMP)AevonGripHookCancelled,  &AevonGripOrigCancelled);
        /* V0.3.0（AevonGripProbe2V300）：状态机探测。setState: 经继承链必拿得到
         * 编码；_setState: 有才装（iOS 变更时静默跳过）。类内安全交换同上。 */
        if (class_getInstanceMethod(cls, @selector(setState:)) != NULL) {
            AevonGripHookSwap(cls, @selector(setState:), (IMP)AevonGripHookSetState, &AevonGripOrigSetState);
        }
        SEL privSel = NSSelectorFromString(@"_setState:");
        if (class_getInstanceMethod(cls, privSel) != NULL) {
            AevonGripHookSwap(cls, privSel, (IMP)AevonGripHook_SetState, &AevonGripOrig_SetState);
        }
        AevonGripHookInstalled = YES;
        AevonGripProbeTouch(-2, 0, 0);       // -2 = 安装成功
        return YES;
    } @catch (NSException *exception) {
        AevonGripProbeTouch(-3, 0, 0);       // -3 = 安装异常
        return NO;
    }
}
