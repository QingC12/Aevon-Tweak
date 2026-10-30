#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

/*
 * V0.2.99（AevonGripProbeV299）：方案 A 灰度探测骨架 —— 呼出主通道贴 Stheno。
 * V0.3.0（AevonGripProbe2V300）：换目标 hook 识别器状态机。
 * V0.3.1（AevonGripProbe3V301，用户 Aevon(79) #3「如果所有的手势在 ios17.3.1 中不可用，
 *   那么 Stheno 是如何支持的？肯定是我们的探针方式或者方向错了。加强一下或者一次部署
 *   多个手势类探针」）：**广度探测** —— 前两轮只探了 SBGrabberTongue 一个类，touches 与
 *   setState 都零数据。用户判断正确：Stheno 能支持，说明方向错、不是环境不支持。
 *   逆向数据（stheno-ring-gesture-study.md / hook-chain-analysis-report.txt）实锤它 hook 的
 *   是五个系统手势识别器 + 管理器：
 *     SBReachabilityGestureRecognizer / SBGrabberTongue / SBFluidSwitcherGestureManager
 *     / _SBFluidSwitcherPanGestureRecognizer / SBSystemGestureManager
 *   本轮一次装四类探测，覆盖「识别器状态机」与「手势入口方法」两个层面：
 *     ① 全局 UIGestureRecognizer 的 _setState:（覆盖面最大：任何系统手势识别器状态变化
 *        都会经过它，一次就能看到「右缘滑动到底被哪个类识别」）—— 加类名过滤 + 双层限流；
 *     ② SBGrabberTongue 的 _handlePullGesture:（Stheno 主通道，验证 iOS 17.3.1 是否还活着）；
 *     ③ SBReachabilityGestureRecognizer 的 1 参手势入口（有就装）；
 *     ④ SBSystemGestureManager 的 touch/event 入口（有就装）。
 *   全部只观察：原实现照常转发，零语义改变。
 *
 * 安全设计（任何一条不成立就退回原样）：
 *   · Prefs 总开关 GripHookProbe 默认关（用户在设置里显式打开才装）；
 *   · 类探测失败 → 静默跳过（下一版换目标），零副作用；
 *   · 方法签名自检（fail-closed）：参数个数 ≠ 1 的方法一律不装 —— 转发时参数个数不符
 *     会破坏调用约定（这是 hook 私有方法最容易炸的地方）；
 *   · 类内安全交换（类自身有实现才 setImplementation，否则 addMethod + 父类取原实现）；
 *   · 回调 @try 全包，原实现先转发（任何异常都不影响系统手势）；
 *   · 日志双层限流：同类名最多 10 条 + 总量 300 条，只在 began/changed 之外的状态打；
 *   · 0.2.72 铁律遵守：只对已知类做 method 操作，绝不全类表枚举。
 */

extern void AevonGripProbeTouch(NSInteger phase, CGFloat x, CGFloat y);
extern void AevonGripProbeEvent(const char *kind, const char *cls, long state);

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
 * V0.3.0（AevonGripProbe2V300）：SBGrabberTongue 的状态机入口。
 * phase 编码：10 + UIGestureRecognizerState / 20 + state（私有 _setState:）。
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

// ---------------------------------------------------------------------------
// V0.3.1（AevonGripProbe3V301）：广度探测基建
// ---------------------------------------------------------------------------

/// 类名限流表：同类名最多 10 条，全局最多 300 条（class_getName 返回的指针常驻，可直接缓存）
static const char *gAevonGripSeenCls[32];
static int gAevonGripSeenCnt[32];
static int gAevonGripSeenNum = 0;
static int gAevonGripEventTotal = 0;

static BOOL AevonGripEventAllowed(const char *cls) {
    if (cls == NULL) { return NO; }
    if (gAevonGripEventTotal >= 300) { return NO; }
    for (int i = 0; i < gAevonGripSeenNum; i++) {
        if (gAevonGripSeenCls[i] == cls || strcmp(gAevonGripSeenCls[i], cls) == 0) {
            if (gAevonGripSeenCnt[i] >= 10) { return NO; }
            gAevonGripSeenCnt[i]++;
            gAevonGripEventTotal++;
            return YES;
        }
    }
    if (gAevonGripSeenNum < 32) {
        gAevonGripSeenCls[gAevonGripSeenNum] = cls;
        gAevonGripSeenCnt[gAevonGripSeenNum] = 1;
        gAevonGripSeenNum++;
        gAevonGripEventTotal++;
        return YES;
    }
    return NO;
}

/// type encoding 参数个数（fail-closed 用）：先跳到 ':' 之后，再数类型段。
/// "v24@0:8q16" → 1；"v@:@" → 1；"v@:" → 0。解析不出返回 -1（视为不可装）。
static int AevonGripEncArgCount(const char *enc) {
    if (enc == NULL) { return -1; }
    const char *p = strchr(enc, ':');
    if (p == NULL) { return -1; }
    p++;
    int n = 0;
    while (*p) {
        while (*p == 'r' || *p == 'n' || *p == 'N' || *p == 'o' || *p == 'O'
               || *p == 'R' || *p == 'V' || *p == 'A'
               || (*p >= '0' && *p <= '9')) {
            p++;
        }
        if (*p == '\0') { break; }
        if (*p == '^') { p++; continue; }
        if (*p == '{' || *p == '(' || *p == '[') {
            char open = *p;
            char close = (open == '{') ? '}' : ((open == '(') ? ')' : ']');
            int depth = 0;
            while (*p) {
                if (*p == open) { depth++; }
                else if (*p == close) { depth--; if (depth == 0) { p++; break; } }
                p++;
            }
        } else {
            p++;
        }
        n++;
    }
    return n;
}

/// 通用「1 个 id 参数」观察钩子：原实现照常转发，只记类名。
#define AEVON_GRIP_ONE_ARG_HOOK(fnName, tagStr, origVar)                                 \
static IMP origVar = NULL;                                                               \
static void fnName(id self, SEL _cmd, id arg) {                                           \
    if (origVar) { ((void (*)(id, SEL, id))origVar)(self, _cmd, arg); }                   \
    @try {                                                                                \
        Class c = object_getClass(self);                                                  \
        const char *cn = c ? class_getName(c) : NULL;                                     \
        if (AevonGripEventAllowed(cn)) { AevonGripProbeEvent(tagStr, cn, 0); }            \
    } @catch (NSException *exception) {                                                   \
    }                                                                                     \
}

AEVON_GRIP_ONE_ARG_HOOK(AevonGripHookPull, "pull", AevonGripOrigPull)
AEVON_GRIP_ONE_ARG_HOOK(AevonGripHookSysGesture, "sysgesture", AevonGripOrigSysGesture)
AEVON_GRIP_ONE_ARG_HOOK(AevonGripHookSysTouch, "systouch", AevonGripOrigSysTouch)

/*
 * V0.3.2（AevonGripProbe4V302，用户 Aevon(80)「先查抖音卡屏是哪个版本出现的问题」+
 *   定档「本轮构建一版纯探针」）：**事件投递链类普查**。
 *
 * 目的只有一个：找出发往「未注入 App（抖音）」的触摸在 SpringBoard 侧到底由哪个类路由。
 * 这是「SB 侧窄口径吞摸」的选点依据 —— 0.2.85 的笔记就写了这条路要单独做，但一直没定
 * 落点。本轮只查「类与方法是否存在 + 签名参数数」，**不安装任何钩子、零行为改变**。
 * 下一版拿到清单后再决定装哪个（届时才需要签名自检 + 限流）。
 */
static void AevonGripCensusClass(NSString *clsName, NSArray<NSString *> *sels) {
    @try {
        Class cls = NSClassFromString(clsName);
        if (cls == Nil) {
            AevonGripProbeEvent("census", [[NSString stringWithFormat:@"%@=无", clsName] UTF8String], 0);
            return;
        }
        NSMutableString *hit = [NSMutableString string];
        for (NSString *s in sels) {
            Method m = class_getInstanceMethod(cls, NSSelectorFromString(s));
            if (m == NULL) { continue; }
            const char *enc = method_getTypeEncoding(m);
            [hit appendFormat:@" %@/%d", s, enc ? AevonGripEncArgCount(enc) : -1];
        }
        NSString *line = [NSString stringWithFormat:@"%@=有%@", clsName,
                          hit.length > 0 ? (id)hit : (id)@" (无候选方法)"];
        AevonGripProbeEvent("census", [line UTF8String], 0);
    } @catch (NSException *exception) {
    }
}

/// 全局识别器状态钩子（全局 UIGestureRecognizer._setState: 用）
static IMP AevonGripOrigGlobalSetState = NULL;

static void AevonGripGlobalSetState(id self, SEL _cmd, NSInteger state) {
    if (AevonGripOrigGlobalSetState) {
        ((void (*)(id, SEL, NSInteger))AevonGripOrigGlobalSetState)(self, _cmd, state);
    }
    @try {
        // 只记终态与起始态；changed(2) 逐帧刷屏，不记
        if (state != 1 && state != 3 && state != 4 && state != 5) {
            return;
        }
        Class c = object_getClass(self);
        const char *cn = c ? class_getName(c) : NULL;
        if (AevonGripEventAllowed(cn)) {
            AevonGripProbeEvent("recog", cn, (long)state);
        }
    } @catch (NSException *exception) {
    }
}

/// V0.3.2（AevonGripProbe4V302）：公有 `setState:` 版本的观察钩子。
/// 0.3.1 实锤 `UIGestureRecognizer._setState:` 在 iOS 17.3.1 上**不存在**，
/// 所以那条「最强覆盖」的全局探测腿是空的 —— 这里补探公有名 `setState:`。
/// 转发指针独立（不复用 _setState: 那条），避免两个都装上时互相覆盖成无限递归。
static IMP AevonGripOrigGlobalSetStatePub = NULL;

static void AevonGripGlobalSetStatePub(id self, SEL _cmd, NSInteger state) {
    if (AevonGripOrigGlobalSetStatePub) {
        ((void (*)(id, SEL, NSInteger))AevonGripOrigGlobalSetStatePub)(self, _cmd, state);
    }
    @try {
        // 只记 began/ended/cancelled/failed；changed 逐帧刷屏不记
        if (state != 1 && state != 3 && state != 4 && state != 5) {
            return;
        }
        Class c = object_getClass(self);
        const char *cn = c ? class_getName(c) : NULL;
        if (AevonGripEventAllowed(cn)) {
            AevonGripProbeEvent("recog", cn, (long)state);
        }
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

/// 签名自检 + 安装（只装「1 个 id 参数」的入口，fail-closed）。
static BOOL AevonGripInstallOneArg(Class cls, NSString *selName, IMP replacement, IMP *original) {
    if (cls == Nil || selName.length == 0) { return NO; }
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) { return NO; }
    const char *enc = method_getTypeEncoding(m);
    if (enc == NULL || enc[0] != 'v') { return NO; }         // 必须返回 void
    if (AevonGripEncArgCount(enc) != 1) { return NO; }       // 必须恰好 1 个参数
    AevonGripHookSwap(cls, sel, replacement, original);
    return *original != NULL;
}

BOOL AevonGripHookProbeInstall(void) {
    if (AevonGripHookInstalled) { return YES; }
    @try {
        Class cls = NSClassFromString(@"SBGrabberTongue");
        if (cls == Nil) {
            AevonGripProbeTouch(-1, 0, 0);   // -1 = 类探测失败（环境差异）
            return NO;
        }
        AevonGripHookSwap(cls, @selector(touchesBegan:withEvent:),      (IMP)AevonGripHookBegan,      &AevonGripOrigBegan);
        AevonGripHookSwap(cls, @selector(touchesMoved:withEvent:),      (IMP)AevonGripHookMoved,      &AevonGripOrigMoved);
        AevonGripHookSwap(cls, @selector(touchesEnded:withEvent:),      (IMP)AevonGripHookEnded,      &AevonGripOrigEnded);
        AevonGripHookSwap(cls, @selector(touchesCancelled:withEvent:),  (IMP)AevonGripHookCancelled,  &AevonGripOrigCancelled);
        if (class_getInstanceMethod(cls, @selector(setState:)) != NULL) {
            AevonGripHookSwap(cls, @selector(setState:), (IMP)AevonGripHookSetState, &AevonGripOrigSetState);
        }
        SEL privSel = NSSelectorFromString(@"_setState:");
        if (class_getInstanceMethod(cls, privSel) != NULL) {
            AevonGripHookSwap(cls, privSel, (IMP)AevonGripHook_SetState, &AevonGripOrig_SetState);
        }

        /* ② SBGrabberTongue 的 _handlePullGesture:（Stheno 主通道） */
        int pullHooked = AevonGripInstallOneArg(cls, @"_handlePullGesture:",
                                                (IMP)AevonGripHookPull, &AevonGripOrigPull) ? 1 : 0;
        if (pullHooked) {
            AevonGripProbeEvent("install", "SBGrabberTongue._handlePullGesture:", pullHooked);
        }

        /* ③ SBReachabilityGestureRecognizer 的手势入口（Stheno 五个目标之一） */
        Class reach = NSClassFromString(@"SBReachabilityGestureRecognizer");
        if (reach != Nil) {
            NSString *cand[] = { @"_handleGesture:", @"handleGesture:", @"_handleReachabilityGesture:" };
            for (int i = 0; i < 3; i++) {
                if (AevonGripInstallOneArg(reach, cand[i], (IMP)AevonGripHookSysGesture,
                                           &AevonGripOrigSysGesture)) {
                    AevonGripProbeEvent("install",
                        [[NSString stringWithFormat:@"SBReachabilityGestureRecognizer.%@", cand[i]] UTF8String], 1);
                    break;
                }
            }
        }

        /* ④ SBSystemGestureManager 的触摸/事件入口（Stheno 手势管理器层） */
        Class sysMgr = NSClassFromString(@"SBSystemGestureManager");
        if (sysMgr != Nil) {
            NSString *cand[] = { @"_handleTouchEvent:", @"handleTouchEvent:", @"_handleEvent:" };
            for (int i = 0; i < 3; i++) {
                if (AevonGripInstallOneArg(sysMgr, cand[i], (IMP)AevonGripHookSysTouch,
                                           &AevonGripOrigSysTouch)) {
                    AevonGripProbeEvent("install",
                        [[NSString stringWithFormat:@"SBSystemGestureManager.%@", cand[i]] UTF8String], 1);
                    break;
                }
            }
        }

        /* ⑤ 全局识别器状态机（最强覆盖）：UIGestureRecognizer._setState:，签名 1 参才装 */
        SEL globalSel = NSSelectorFromString(@"_setState:");
        Method globalMethod = class_getInstanceMethod([UIGestureRecognizer class], globalSel);
        if (globalMethod != NULL) {
            const char *genc = method_getTypeEncoding(globalMethod);
            if (genc != NULL && genc[0] == 'v' && AevonGripEncArgCount(genc) == 1) {
                AevonGripOrigGlobalSetState = method_setImplementation(globalMethod,
                                                                      (IMP)AevonGripGlobalSetState);
                if (AevonGripOrigGlobalSetState != NULL) {
                    AevonGripProbeEvent("install", "UIGestureRecognizer._setState:", 1);
                }
            } else {
                AevonGripProbeEvent("skip", "UIGestureRecognizer._setState: 签名不符", 0);
            }
        } else {
            AevonGripProbeEvent("skip", "UIGestureRecognizer._setState: 不存在", 0);
        }

        /* ⑥ V0.3.2（AevonGripProbe4V302）：事件投递链类普查 —— 只查存在性/签名，不装钩子。
         * 这是「发往抖音的触摸走哪个类」的候选清单，也是「SB 侧窄口径吞摸」的选点依据。 */
        AevonGripCensusClass(@"BKSHIDEventDeliveryManager",
            @[@"deliveryChainForDescriptor:", @"_deliveryChainsForDescriptor:", @"destinationsForEvent:fromSender:"]);
        AevonGripCensusClass(@"BKSHIDEventDeliveryRuleChangeRequest", @[@"setRule:", @"rule"]);
        AevonGripCensusClass(@"SBTouchDeliveryManager", @[@"_handleTouchEvent:", @"handleTouchEvent:", @"_handleEvent:"]);
        AevonGripCensusClass(@"SBTouchDeliverySession", @[@"_handleTouchEvent:", @"handleEvent:"]);
        AevonGripCensusClass(@"SBMainWorkspace", @[@"_handleEvent:"]);
        AevonGripCensusClass(@"_UISceneEventQueue", @[@"_processEvent:", @"enqueueEvent:"]);
        AevonGripCensusClass(@"SBApplicationSceneHandle", @[@"_handleTouchEvent:", @"_handleEvent:"]);
        AevonGripCensusClass(@"SBDeviceApplicationSceneHandle", @[@"_handleTouchEvent:", @"_handleEvent:"]);
        AevonGripCensusClass(@"UIGestureRecognizer", @[@"setState:", @"_setState:", @"_updateGestureWithEvent:buttonEvent:"]);
        AevonGripCensusClass(@"SBSystemGestureManager", @[@"_handleTouchEvent:", @"handleTouchEvent:", @"_handleEvent:"]);

        /* ⑦ V0.3.2：全局识别器 setState: 补探（0.3.1 实锤 _setState: 不存在，这条腿空着） */
        SEL pubSetStateSel = NSSelectorFromString(@"setState:");
        Method pubSetStateMethod = class_getInstanceMethod([UIGestureRecognizer class], pubSetStateSel);
        if (pubSetStateMethod != NULL) {
            const char *penc = method_getTypeEncoding(pubSetStateMethod);
            if (penc != NULL && penc[0] == 'v' && AevonGripEncArgCount(penc) == 1) {
                AevonGripOrigGlobalSetStatePub = method_setImplementation(pubSetStateMethod,
                                                                         (IMP)AevonGripGlobalSetStatePub);
                if (AevonGripOrigGlobalSetStatePub != NULL) {
                    AevonGripProbeEvent("install", "UIGestureRecognizer.setState:", 1);
                }
            } else {
                AevonGripProbeEvent("skip", "UIGestureRecognizer.setState: 签名不符", 0);
            }
        } else {
            AevonGripProbeEvent("skip", "UIGestureRecognizer.setState: 不存在", 0);
        }

        AevonGripHookInstalled = YES;
        AevonGripProbeTouch(-2, 0, 0);       // -2 = 安装成功
        return YES;
    } @catch (NSException *exception) {
        AevonGripProbeTouch(-3, 0, 0);       // -3 = 安装异常
        return NO;
    }
}
