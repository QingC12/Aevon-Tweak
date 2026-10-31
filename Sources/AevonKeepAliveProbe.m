/* AevonKeepAliveProbe.m —— V0.3.26（AevonKeepAliveProbeV326）
 *
 * 用户 Aevon(99) #2：「全屏 App 时开窗返回桌面，悬浮窗会闪黑两次才出现实时内容」。
 *
 * 0.3.25 的日志把病灶定位到了：**那两次黑是我们自己重申出来的**。
 *   58.629 过渡哨命中 → 什么都没盖（B3 生效）
 *   59.529 回桌面布防（此刻 cs=0，已经黑了 0.9 秒）
 *   59.531 重申浮窗场景前台  立即    cs=0 → cs=1   ← 第一次黑
 *   59.951 重申浮窗场景前台  +0.40s  cs=0 → cs=1   ← 第二次黑
 * 而 `AevonWindowView` 里 0.2.55 的注释早就写着「每一次 updateSettings 重申都会让
 * 远程表面重建一次，屏幕上就是黑一下、再亮一下」。
 *
 * 所以正确的方向不是「少重申一次」，而是**别让场景掉到 cs=0** —— 也就是场景保活。
 * Stheno 侧的结构（ScreenCore 类普查，23 个 SCWS* 类）已经查清：
 *   · `SCWSNativeFullRequest`（`__returnSession` / `__returnDeadline` / `__needsRestore`）
 *   · `SCWSNativeFullReturnHost`（`-start` / `-returnToWindow` / `-completeReturn:`）
 *   · `SCWSFullscreenScene`（`__promoted` / `__suspended`）
 *   · `SCSystemSceneContext`（`previousDeactivationReasons` / `changedDeactivationReasons`
 *     / `previousForeground` / `changedForeground`）
 *   · `SCSystemSceneDriver -sc_protectForegroundHandoffForTransitionContext:`（0x560c8）
 * 这些都是 Stheno 自己的编排类，**不可移植**（它们要 manager/session/driver 一整套对象）。
 * 可移植的是它们底下真正对 SpringBoard 生效的那一层：`UIApplicationSceneDeactivationManager`
 * 的 deactivation reason 断言 —— Stheno 的 `previous* / changed*` 记账正是在它之上。
 *
 * ⛔ 所以本版是**探针版**（用户 0.3.26 授权「一次部署多个探针」）：
 *    只做只读取证 + 一个安全的写探针（deactivation 断言），把实测矩阵打回来，
 *    下一版再按实证落最终机制。
 *
 * 纪律：
 *   · 所有选择子调用一律 `@try/@catch` —— Swift 抓不到 NSException，未知选择子会直接
 *     打成 SIGABRT/SIGTRAP；这层是本模块唯一的崩溃防线。
 *   · 全程 fail-open：任何一步失败只记日志，绝不影响回桌面既有路径。
 *   · 直接写 `deactivationReasons` 的探针**默认关闭**（`AevonKeepReasonsWriteV326`）——
 *     归档(14) 记着「主场景的 deactivation 状态机绝不碰」（SIGTRAP 教训），
 *     断言是正规通道，直写是核选项。
 *   · 总闸 `AevonKeepAliveOff326`：写 true 即整段不跑。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "AevonKeepAliveProbe.h"

/* 由 Swift 侧 @_cdecl("AevonKeepAliveLog") 实现：统一走 AevonLog，带标记串。 */
extern void AevonKeepAliveLog(const char *utf8Detail);

__attribute__((used)) static const char AevonKeepAliveProbeV326[] = "AevonKeepAliveProbeV326";
__attribute__((used)) static const char AevonKeepAliveAssertV326[] = "AevonKeepAliveAssertV326";
__attribute__((used)) static const char AevonKeepAliveMatrixV326[] = "AevonKeepAliveMatrixV326";
__attribute__((used)) static const char AevonKeepAliveNoWriteV326[] = "AevonKeepAliveNoWriteV326";

static BOOL gOff = NO;
static BOOL gWriteProbe = NO;
static BOOL gConfigLoaded = NO;
static BOOL gMatrixLogged = NO;
static BOOL gActive = NO;

static id gManager = nil;        /* UIApplicationSceneDeactivationManager */
static id gAssertion = nil;      /* UIApplicationSceneDeactivationAssertion */
static __weak id gScene = nil;   /* FBScene（弱引用：场景可能被系统收走） */
static CFTimeInterval gBeganAt = 0;

static void aev_ensure_config(void) {
    if (gConfigLoaded) { return; }
    gConfigLoaded = YES;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id off = [d objectForKey:@"AevonKeepAliveOff326"];
    gOff = (off != nil) ? [off boolValue] : NO;
    id wr = [d objectForKey:@"AevonKeepReasonsWriteV326"];
    gWriteProbe = (wr != nil) ? [wr boolValue] : NO;
}

static SEL aev_sel(NSString *name) { return NSSelectorFromString(name); }

static BOOL aev_responds(id obj, NSString *sel) {
    if (obj == nil) { return NO; }
    return [obj respondsToSelector:aev_sel(sel)];
}

/* 安全调用：0 参 / 1 参（对象） / 2 参（对象 + 对象）。全部 @try。 */
static id aev_call0(id obj, NSString *sel) {
    if (!aev_responds(obj, sel)) { return nil; }
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(obj, aev_sel(sel));
    } @catch (NSException *e) {
        AevonKeepAliveLog([NSString stringWithFormat:@"%@ 抛异常：%@", sel, e.reason].UTF8String);
        return nil;
    }
}

static id aev_call1(id obj, NSString *sel, id a) {
    if (!aev_responds(obj, sel)) { return nil; }
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(obj, aev_sel(sel), a);
    } @catch (NSException *e) {
        AevonKeepAliveLog([NSString stringWithFormat:@"%@ 抛异常：%@", sel, e.reason].UTF8String);
        return nil;
    }
}

static id aev_call2(id obj, NSString *sel, id a, id b) {
    if (!aev_responds(obj, sel)) { return nil; }
    @try {
        return ((id (*)(id, SEL, id, id))objc_msgSend)(obj, aev_sel(sel), a, b);
    } @catch (NSException *e) {
        AevonKeepAliveLog([NSString stringWithFormat:@"%@ 抛异常：%@", sel, e.reason].UTF8String);
        return nil;
    }
}

/* 读一个数值型键（deactivationReasons / foreground 之类）：KVC 只读，失败返回 -999。 */
static long long aev_read_int(id obj, NSString *key) {
    if (obj == nil) { return -999; }
    @try {
        id v = [obj valueForKey:key];
        if (v == nil) { return -999; }
        return [v longLongValue];
    } @catch (NSException *e) {
        return -998;
    }
}

/* ---- 一、类型与方法矩阵（每个进程只打一次）---- */

static void aev_log_matrix(void) {
    if (gMatrixLogged) { return; }
    gMatrixLogged = YES;

    NSString *mgrName = @"UIApplicationSceneDeactivationManager";
    NSString *asrtName = @"UIApplicationSceneDeactivationAssertion";
    NSString *predName = @"UIApplicationSceneDeactivationPredicate";
    NSString *pred2Name = @"UIApplicationSceneDeactivationPredicateSceneExtension";

    Class mgrCls = NSClassFromString(mgrName);
    Class asrtCls = NSClassFromString(asrtName);
    Class predCls = NSClassFromString(predName);
    Class pred2Cls = NSClassFromString(pred2Name);

    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"矩阵 管理器=%@ 断言=%@ 谓词=%@/%@",
                    mgrCls ? @"有" : @"无", asrtCls ? @"有" : @"无",
                    predCls ? @"有" : @"无", pred2Cls ? @"有" : @"无"];

    id mgr = nil;
    if (mgrCls) {
        mgr = aev_call0((id)mgrCls, @"sharedManager");
        if (mgr == nil) {
            @try {
                mgr = ((id (*)(id, SEL))objc_msgSend)((id)mgrCls, aev_sel(@"new"));
            } @catch (NSException *e) { mgr = nil; }
        }
    }
    if (mgr != nil) {
        [m appendFormat:@" 管理器实例=%@", NSStringFromClass([mgr class])];
        [m appendFormat:@" newAssertion=%d setReasons=%d acquire=%d",
                      aev_responds(mgr, @"newAssertionWithReason:"),
                      aev_responds(mgr, @"_setDeactivationReasons:onScene:withSettings:reason:"),
                      aev_responds(mgr, @"acquireWithPredicate:transitionContext:")];
    } else {
        [m appendString:@" 管理器实例=无"];
    }
    if (asrtCls) {
        [m appendFormat:@" 断言 acquire=%d acquirePred=%d relinquish=%d",
                      [asrtCls instancesRespondToSelector:aev_sel(@"acquire")],
                      [asrtCls instancesRespondToSelector:aev_sel(@"acquireWithPredicate:transitionContext:")],
                      [asrtCls instancesRespondToSelector:aev_sel(@"relinquish")]];
    }
    if (predCls) {
        [m appendFormat:@" 谓词 allScenes=%d",
                      aev_responds((id)predCls, @"predicateMatchingAllScenes")];
    }
    AevonKeepAliveLog(m.UTF8String);
}

/* ---- 二、只读取证：场景的 deactivation 账 ---- */

static void aev_log_reasons(NSString *tag) {
    if (gScene == nil) {
        AevonKeepAliveLog([NSString stringWithFormat:@"%@ 场景已不在（弱引用空）", tag].UTF8String);
        return;
    }
    long long sceneside = aev_read_int(gScene, @"deactivationReasons");
    id settings = aev_call0(gScene, @"settings");
    long long settside = aev_read_int(settings, @"deactivationReasons");
    long long fg = aev_read_int(settings, @"foreground");
    long long cs = aev_read_int(gScene, @"contentState");
    AevonKeepAliveLog([NSString stringWithFormat:
                       @"%@ 读数 场景.deactivation=%lld settings.deactivation=%lld fg=%lld cs=%lld",
                       tag, sceneside, settside, fg, cs].UTF8String);
}

/* ---- 三、写探针 A：deactivation 断言（正规通道，默认开）---- */

static void aev_try_assertion(void) {
    Class mgrCls = NSClassFromString(@"UIApplicationSceneDeactivationManager");
    if (mgrCls == nil) {
        AevonKeepAliveLog("断言跳过：管理器类不存在（AevonKeepAliveAssertV326）");
        return;
    }
    if (gManager == nil) {
        gManager = aev_call0((id)mgrCls, @"sharedManager");
        if (gManager == nil) {
            @try {
                gManager = ((id (*)(id, SEL))objc_msgSend)((id)mgrCls, aev_sel(@"new"));
            } @catch (NSException *e) { gManager = nil; }
        }
    }
    if (gManager == nil) {
        AevonKeepAliveLog("断言跳过：拿不到管理器实例");
        return;
    }
    /* reason 1 = 通用「Other」。见头注释：断言持有期会让该场景不被 deactivate。 */
    NSNumber *reason = @(1);
    id assertion = nil;
    @try {
        if (aev_responds(gManager, @"newAssertionWithReason:")) {
            assertion = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(gManager,
                                                                    aev_sel(@"newAssertionWithReason:"),
                                                                    1);
        }
    } @catch (NSException *e) {
        AevonKeepAliveLog([NSString stringWithFormat:@"newAssertionWithReason: 抛异常：%@",
                           e.reason].UTF8String);
        assertion = nil;
    }
    (void)reason;
    if (assertion == nil) {
        AevonKeepAliveLog("断言未建（newAssertionWithReason: 不可用）");
        return;
    }
    gAssertion = assertion;
    /* 谓词：优先全场景谓词，拿不到就退回不带谓词的 acquire。 */
    id predicate = aev_call0(NSClassFromString(@"UIApplicationSceneDeactivationPredicate"),
                             @"predicateMatchingAllScenes");
    BOOL ok = NO;
    @try {
        if (predicate != nil && aev_responds(assertion, @"acquireWithPredicate:transitionContext:")) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(assertion,
                                                     aev_sel(@"acquireWithPredicate:transitionContext:"),
                                                     predicate, nil);
            ok = YES;
        } else if (aev_responds(assertion, @"acquire")) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, aev_sel(@"acquire"));
            ok = YES;
        }
    } @catch (NSException *e) {
        AevonKeepAliveLog([NSString stringWithFormat:@"断言 acquire 抛异常：%@", e.reason].UTF8String);
        ok = NO;
    }
    AevonKeepAliveLog([NSString stringWithFormat:
                       @"断言 %@（谓词=%@，reason=1）（AevonKeepAliveAssertV326）",
                       ok ? @"已持有" : @"未持有", predicate ? @"全场景" : @"无"].UTF8String);
}

/* ---- 四、写探针 B：直接写 deactivationReasons=0（默认关）---- */

static void aev_try_reasons_write(void) {
    if (!gWriteProbe) {
        AevonKeepAliveLog([NSString stringWithFormat:
                           @"直写跳针关闭（AevonKeepReasonsWriteV326 未开 %@）",
                           [NSString stringWithUTF8String:AevonKeepAliveNoWriteV326]].UTF8String);
        return;
    }
    Class mgrCls = NSClassFromString(@"UIApplicationSceneDeactivationManager");
    id mgr = gManager;
    if (mgr == nil && mgrCls != nil) {
        mgr = aev_call0((id)mgrCls, @"sharedManager");
        if (mgr == nil) {
            @try { mgr = ((id (*)(id, SEL))objc_msgSend)((id)mgrCls, aev_sel(@"new")); }
            @catch (NSException *e) { mgr = nil; }
        }
    }
    if (mgr == nil || gScene == nil) {
        AevonKeepAliveLog("直写跳过：管理器或场景缺失");
        return;
    }
    NSString *sel = @"_setDeactivationReasons:onScene:withSettings:reason:";
    if (!aev_responds(mgr, sel)) {
        AevonKeepAliveLog("直写跳过：_setDeactivationReasons: 不存在");
        return;
    }
    @try {
        ((void (*)(id, SEL, NSUInteger, id, id, id))objc_msgSend)(
            mgr, aev_sel(sel), 0, gScene, nil, @"AevonKeepAlive");
        AevonKeepAliveLog("直写已提交 deactivationReasons=0（AevonKeepAliveProbeV326）");
    } @catch (NSException *e) {
        AevonKeepAliveLog([NSString stringWithFormat:@"直写抛异常：%@", e.reason].UTF8String);
    }
}

/* ---- 对外接口 ---- */

int AevonKeepAliveProbeBegin(void *scene) {
    aev_ensure_config();
    if (gOff || scene == NULL) { return 0; }
    gScene = (__bridge id)scene;
    if (gScene == nil) { return 0; }
    gBeganAt = CACurrentMediaTime();
    gActive = YES;

    aev_log_matrix();
    aev_log_reasons(@"进入");
    aev_try_assertion();
    aev_try_reasons_write();
    aev_log_reasons(@"写入后");
    return 1;
}

void AevonKeepAliveProbeEnd(void) {
    if (!gActive) { return; }
    gActive = NO;
    double held = (CACurrentMediaTime() - gBeganAt) * 1000.0;
    aev_log_reasons(@"结束前");
    if (gAssertion != nil) {
        @try {
            if (aev_responds(gAssertion, @"relinquish")) {
                ((void (*)(id, SEL))objc_msgSend)(gAssertion, aev_sel(@"relinquish"));
            }
        } @catch (NSException *e) {
            /* 释放失败不重试，下一轮重建 */
        }
        gAssertion = nil;
    }
    AevonKeepAliveLog([NSString stringWithFormat:
                       @"本轮结束 持有 %.0fms（AevonKeepAliveProbeV326）", held].UTF8String);
    gScene = nil;
}

int AevonKeepAliveProbeActive(void) { return gActive ? 1 : 0; }
