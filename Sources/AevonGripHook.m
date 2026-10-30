#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <math.h>

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

// ---------------------------------------------------------------------------
// V0.3.4（AevonGripSystemLegV304，用户定档「路线 A：真正改成 Stheno 式（挂系统识别器）」）
//
// 0.3.3 之前的呼出主通道是「自建 5pt 竖条 + 自建 UIPan」，本质是从 App 手里**抢**触摸
//（所以必须靠 App 侧吞摸收尾，卡屏温床）。Stheno 从不抢：它 hook 系统手势识别器，触摸
// 本来就属于系统手势，App 侧走系统自带的 cancel 语义。
//
// 0.3.2 探针给了这条路的前提（Aevon(81) 日志第 316/323/325 行）：
//   右缘 (414,693) 落指后 6ms `_UIPendingEdgeSwipeGestureRecognizer → began`，
//   55ms 后 `SBFluidSwitcherScreenEdgePanGestureRecognizer → began`、
//   `UIScreenEdgePanGestureRecognizer → began`，同拍 `SBScreenEdgePan` /
//   `SBReachability` / `SBCoverSheetPresentation` 全部 → failed。
//   ⇒ 系统边沿手势管线**看得见右缘**，只是我们之前没用它。
//   ⇒ 同时实锤 `SBGrabberTongue._handlePullGesture:` 10 次命中全在底部手势簇，
//     右缘零命中 —— Stheno 0.1.23 的「主通道」在 17.3.1 上不覆盖右缘，所以照抄它的
//     代码路径无效，要照抄它**骑系统识别器**的架构。
//
// 本腿做法（全程公有 API，不碰私有方法）：
//   ① 全局观察 `UIGestureRecognizer.setState:`（0.3.2 已实证可装、零崩溃）；
//   ② 只在**边沿族**类名（EdgeSwipe / ScreenEdgePan / EdgePan）且 state=Began 时介入；
//   ③ 落点 x 必须在右缘 24pt 内才认领（否则是 App 中部的普通拖动，一律不碰）；
//   ④ 认领 = 给该识别器**外挂一个 target**（addTarget:action:，公有 API），后续
//      Changed 帧从识别器自己的 `locationInView:nil` 读位移，dx ≤ -8pt 且 |dy| < 40pt
//      → 回调 Swift 呼盘。**一根手指都不从 App 的投递链里拿掉**，因此结构上不会再出现
//      「App 收到 began 收不到 ended」。
//   ⑤ 同一根手指可能被多个识别器同时 began（日志里就是三个类同拍），所以候选是**列表**
//      （最多 4 个并行跟踪），谁先过阈值谁呼盘；重复呼盘由 Swift 侧 0.6s 节流 + 已展开
//      判定吸收。每个候选 2.0 秒过期（fail-open，绝不留悬挂 target）。
//   ⑥ 任何一步失败都只影响本腿（静默跳过），把手 + sendEvent 两条老腿原样保留当回退网。
// ---------------------------------------------------------------------------

extern void AevonGripSystemSummon(double x, double y, double startX, double startY, const char *cls);
extern void AevonGripLegProbe(const char *cls, double x, double y, double edges,
                              int delays, int cancels, const char *viewCls);
/// V0.3.5（AevonGripLegOutcomeV305）：认领了但没走到呼盘时的结局上报。
extern void AevonGripLegOutcome(const char *cls, int kind, double maxDx, int frames);

static BOOL gAevonLegProbeOn = NO;      // 设置页 GripHookProbe 打开时才打实例级细节
/* V0.3.9（AevonGripOwnLegV309）：自建识别器腿的全局状态 —— **定义必须放在这里**，
 * 因为 AevonGripLegObserve（下方）要读 gAevonOwnLegEnabled 决定装不装；
 * 放到文件尾部会变成「use of undeclared identifier」（0.3.9 第一次构建就栽在这）。 */
static BOOL gAevonOwnLegEnabled = NO;       // 自建腿总闸（prefs 打开才 YES）
static BOOL gAevonOwnRegistered = NO;       // 走的是「管理器注册」那条路（view 由系统给，可能恒 nil）
static BOOL gAevonOwnManagerTried = NO;
static BOOL gAevonOwnLegProbeOn = NO;       // GripHookProbe（只控制取证深度）
static id gAevonOwnGesture = nil;           // 我们自己的识别器实例（ARC 全局强引用）
static id gAevonOwnManager = nil;           // 系统手势管理器（拿不到就不装，保持借识别器腿）
/* V0.3.10（AevonOwnLegRegV310）：装配重试计数 + 取证只打一次。
 * 0.3.9 的装配只在「第一次看到边沿识别器」时发生 —— 那一次滑动必然白扔，
 * 而且管理器只找一次，找到不成就永远不装。这里改成主动重试（6s 起每 2s，上限 15 次）。 */
static int gAevonOwnArmTries = 0;
static BOOL gAevonOwnCensusLogged = NO;
/* V0.3.9：装配入口前置声明 —— 定义在文件尾部，而调用点（AevonGripLegObserve）在上方。 */
extern void AevonGripOwnLegArm(UIView *host);
extern void AevonGripOwnLegKick(void);
static BOOL gAevonLegEnabled = YES;     // 系统腿总闸（安装失败/异常时置 NO，退回老腿）
static BOOL gAevonGlobalHooksInstalled = NO;
static IMP gAevonOrigPubSetState = NULL;
static IMP gAevonOrigPrivSetState = NULL;

@class AevonGripLegProxy;

@interface AevonGripLegProxy : NSObject
@property (nonatomic, weak) UIGestureRecognizer *recog;
@property (nonatomic) CGPoint start;
@property (nonatomic) CFTimeInterval stamp;
@property (nonatomic, assign) const char *cls;
@property (nonatomic) BOOL done;
/// V0.3.5（AevonGripLegOutcomeV305）：认领期间见过的最大左向位移（正数 = 向左的 pt 数）
/// 与 changed 帧数 —— 用来区分「没认领」「认领没 changed」「changed 没到阈值」。
@property (nonatomic) double maxDxLeft;
@property (nonatomic) int changedFrames;
/// V0.3.5：结局只报一次（过期清理与状态回调用的是同一个出口）
@property (nonatomic) BOOL reported;
- (void)handleGesture:(UIGestureRecognizer *)g;
@end

static NSMutableArray<AevonGripLegProxy *> *gAevonLegProxies = nil;

static void AevonGripLegDrop(AevonGripLegProxy *p) {
    if (p == nil) { return; }
    p.done = YES;      // 先置位：已排队的回调进来也只走回收分支，不会再呼盘
    @try {
        if (gAevonLegProxies == nil) { gAevonLegProxies = [NSMutableArray array]; }
        UIGestureRecognizer *g = p.recog;
        if (g != nil) {
            [g removeTarget:p action:@selector(handleGesture:)];
        }
        [gAevonLegProxies removeObject:p];
    } @catch (NSException *exception) {
    }
}

/// 过期清理：每个钩子调用顺手扫一遍（代价 = 最多 4 次指针比较）。
static void AevonGripLegPrune(void) {
    if (gAevonLegProxies.count == 0) { return; }
    CFTimeInterval now = CACurrentMediaTime();
    NSArray<AevonGripLegProxy *> *snapshot = [gAevonLegProxies copy];
    for (AevonGripLegProxy *p in snapshot) {
        if (p.done || p.recog == nil || now - p.stamp > 2.0) {
            AevonGripLegDrop(p);
        }
    }
}

/// 边沿族判定：只认这几类系统手势识别器，其余（点击/长按/滚动/键盘）一概不碰。
static BOOL AevonGripIsEdgeClass(const char *cn) {
    if (cn == NULL) { return NO; }
    return strstr(cn, "EdgeSwipe") != NULL
        || strstr(cn, "ScreenEdgePan") != NULL
        || strstr(cn, "EdgePan") != NULL;
}

/// V0.3.5（AevonGripLegOutcomeV305）：认领候选的统一出口 —— 报结局 + 回收。
/// 结局只报一次：过期清理、超 60pt、终态回调三条路都走这里。
static void AevonGripLegFinish(AevonGripLegProxy *p, int kind) {
    if (p == nil) { return; }
    if (p.reported) {
        AevonGripLegDrop(p);
        return;
    }
    p.reported = YES;
    const char *cn = p.cls;
    double mdx = p.maxDxLeft;
    int frames = p.changedFrames;
    AevonGripLegDrop(p);
    AevonGripLegOutcome(cn, kind, mdx, frames);
}

@implementation AevonGripLegProxy

- (void)handleGesture:(UIGestureRecognizer *)g {
    @try {
        if (self.done) {
            AevonGripLegDrop(self);
            return;
        }
        UIGestureRecognizerState st = g.state;
        if (st == UIGestureRecognizerStateChanged) {
            CGPoint now = [g locationInView:nil];
            double dx = (double)now.x - (double)self.start.x;
            double dy = (double)now.y - (double)self.start.y;
            /* V0.3.5（AevonGripLegOutcomeV305）：先记账再看要不要呼盘 —— 没记账就永远
             * 分不清「changed 帧根本没来」和「来了但只到 -5pt」。 */
            self.changedFrames += 1;
            if (-dx > self.maxDxLeft) { self.maxDxLeft = -dx; }
            if (dx <= -8.0 && fabs(dy) < 40.0) {
                self.done = YES;
                self.reported = YES;    // 达阈值这条路自己负责呼盘，不再报「未达阈值」
                const char *cn = self.cls;
                double fx = (double)now.x, fy = (double)now.y;
                /* V0.3.6（AevonGripYieldDeepV306）：把 **began 落点 x** 一起带过去。
                 * 呼盘手势天然向左位移 —— Aevon(84) 日志里 7 次「达阈值但被拦
                 * 原因=不在右缘 24pt 内」全是这个：起手 x=420，滑到 x=400 时
                 * 400 < 430-24=406 就被自己否决了。右缘判据必须看起点。 */
                double sx = (double)self.start.x;
                /* V0.3.8（AevonGripZoneV308）：began 落点 y 也一起带过去。
                 * 判据从「右缘整条」收成「把手带」之后，纵向必须看**起点**而不是当前点 ——
                 * 0.3.6 已经用 7 条「不在右缘」实锤过「用当前点自己否决自己」这个坑，
                 * 只是那次踩的是 x（左滑天然向左）、这次会踩 y（上下抖动 |dy|<40pt）。 */
                double sy = (double)self.start.y;
                AevonGripLegDrop(self);
                dispatch_async(dispatch_get_main_queue(), ^{
                    AevonGripSystemSummon(fx, fy, sx, sy, cn != NULL ? cn : "edge");
                });
                return;
            }
            if (dx * dx + dy * dy > 3600.0) {   // 位移超 60pt 还没过阈值 = 不是呼盘手势
                AevonGripLegFinish(self, 2);
            }
        } else if (st == UIGestureRecognizerStateEnded
                   || st == UIGestureRecognizerStateCancelled
                   || st == UIGestureRecognizerStateFailed) {
            // changed 一帧都没收到 = kind 3（这条识别器不往外吐 changed，是最坏信号）
            AevonGripLegFinish(self, self.changedFrames == 0 ? 3 : 1);
        }
    } @catch (NSException *exception) {
    }
}

@end

/// 认领右缘 began：外挂 target 并记起始点（外挂动作走下一个 runloop，
/// 避免在 UIKit 手势状态机内部改 target 列表）。
static void AevonGripLegArm(UIGestureRecognizer *g, CGPoint start, const char *cn) {
    if (g == nil || cn == NULL) { return; }
    if (gAevonLegProxies == nil) { gAevonLegProxies = [NSMutableArray array]; }
    if (gAevonLegProxies.count >= 4) { return; }
    AevonGripLegProxy *p = [[AevonGripLegProxy alloc] init];
    p.recog = g;
    p.start = start;
    p.stamp = CACurrentMediaTime();
    p.cls = cn;
    [gAevonLegProxies addObject:p];

    /* 实例级探针（GripHookProbe 打开才有这一行）：edges / 延迟投递属性 / 宿主的视图类，
     * 用来定案「右缘这只手到底挂在哪个实例上、它是否本来就在延迟触摸」。 */
    double edges = -1.0;
    if ([g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
        edges = (double)((UIScreenEdgePanGestureRecognizer *)g).edges;
    }
    int delays = g.delaysTouchesBegan ? 1 : 0;
    int cancels = g.cancelsTouchesInView ? 1 : 0;
    const char *viewCls = "nil";
    @try {
        UIView *v = g.view;
        if (v != nil) { viewCls = class_getName(object_getClass(v)); }
    } @catch (NSException *exception) {
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (p.done) { return; }
            [g addTarget:p action:@selector(handleGesture:)];
            if (gAevonLegProbeOn) {
                AevonGripLegProbe(cn, (double)start.x, (double)start.y, edges, delays, cancels, viewCls);
            }
        } @catch (NSException *exception) {
        }
    });
}

/// 全局 setState: 的唯一观察点：探针记账 + 右缘 began 认领（两条钩子共用）。
static void AevonGripLegObserve(id self, NSInteger state) {
    @try {
        AevonGripLegPrune();
        Class c = object_getClass(self);
        const char *cn = c ? class_getName(c) : NULL;
        if (gAevonLegProbeOn && (state == 1 || state == 3 || state == 4 || state == 5)) {
            if (AevonGripEventAllowed(cn)) {
                AevonGripProbeEvent("recog", cn, (long)state);
            }
        }
        if (!gAevonLegEnabled || state != 1) { return; }
        if (!AevonGripIsEdgeClass(cn)) { return; }
        UIGestureRecognizer *g = (UIGestureRecognizer *)self;
        /* V0.3.9（AevonGripOwnLegV309）：宿主视图此刻就在眼前 —— 系统边沿识别器
         * 挂在 UISystemGestureView 上，我们自己的识别器要挂的正是同一个视图。
         * 第一次见到时装配（第一根手指赶不上，从第二根开始生效，可接受）。 */
        if (gAevonOwnLegEnabled) {
            AevonGripOwnLegArm(g.view);
        }
        CGPoint p = [g locationInView:nil];
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        if (p.x < sw - 24.0) { return; }        // 只认右缘起手，屏幕中部拖动一律不碰
        for (AevonGripLegProxy *old in gAevonLegProxies) {
            if (old.recog == g) { return; }     // 同一识别器不重复认领
        }
        AevonGripLegArm(g, p, cn);
    } @catch (NSException *exception) {
    }
}

static void AevonGripGlobalSetState(id self, SEL _cmd, NSInteger state) {
    if (gAevonOrigPrivSetState) {
        ((void (*)(id, SEL, NSInteger))gAevonOrigPrivSetState)(self, _cmd, state);
    }
    AevonGripLegObserve(self, state);
}

static void AevonGripGlobalSetStatePub(id self, SEL _cmd, NSInteger state) {
    if (gAevonOrigPubSetState) {
        ((void (*)(id, SEL, NSInteger))gAevonOrigPubSetState)(self, _cmd, state);
    }
    AevonGripLegObserve(self, state);
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

/// V0.3.4（AevonGripSystemLegV304）：系统识别器腿安装 —— **常驻**，不看探针开关
///（探针开关只控制实例级细节日志）。装不上就 fail-open 退回把手 + sendEvent 两条老腿。
BOOL AevonGripSystemLegInstall(void) {
    if (gAevonGlobalHooksInstalled) { return YES; }
    @try {
        Class gr = [UIGestureRecognizer class];

        /* ① 公有 setState:（0.3.2 实证：iOS 17.3.1 上存在的就是它） */
        Method pub = class_getInstanceMethod(gr, @selector(setState:));
        if (pub != NULL) {
            const char *enc = method_getTypeEncoding(pub);
            if (enc != NULL && enc[0] == 'v' && AevonGripEncArgCount(enc) == 1) {
                gAevonOrigPubSetState = method_setImplementation(pub, (IMP)AevonGripGlobalSetStatePub);
            }
        }

        /* ② 私有 _setState:（17.3.1 实测不存在；将来存在就一起观察，转发指针独立防递归） */
        SEL privSel = NSSelectorFromString(@"_setState:");
        Method priv = class_getInstanceMethod(gr, privSel);
        if (priv != NULL) {
            const char *enc = method_getTypeEncoding(priv);
            if (enc != NULL && enc[0] == 'v' && AevonGripEncArgCount(enc) == 1) {
                gAevonOrigPrivSetState = method_setImplementation(priv, (IMP)AevonGripGlobalSetState);
            }
        }

        if (gAevonOrigPubSetState == NULL && gAevonOrigPrivSetState == NULL) {
            gAevonLegEnabled = NO;
            AevonGripProbeEvent("skip", "AevonGripSystemLegV304 无 setState: 可装 → 本腿关闭", 0);
            return NO;
        }
        gAevonGlobalHooksInstalled = YES;
        AevonGripProbeEvent("install",
            "AevonGripSystemLegV304 系统识别器腿已装（右缘 began 认领 + 外挂 target 跟踪）", 1);
        return YES;
    } @catch (NSException *exception) {
        gAevonLegEnabled = NO;
        return NO;
    }
}

BOOL AevonGripHookProbeInstall(void) {
    if (AevonGripHookInstalled) { return YES; }
    @try {
        /* V0.3.4：探针开关只负责打开实例级细节日志；观察钩子本身由系统腿常驻安装。 */
        gAevonLegProbeOn = YES;
        AevonGripSystemLegInstall();
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

        /* ⑤ V0.3.4：原「全局 _setState: 安装」整段删除 —— 系统腿的 AevonGripSystemLegInstall
         * 已经统一处理公有/私有两条 setState:（不管装没装探针都常驻），这里再装一次会把
         * 转发指针覆盖掉，表现为手势状态回调丢失。 */

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

        /* ⑦ V0.3.4：原 0.3.2 的「全局 setState: 补探」并进 AevonGripSystemLegInstall
         *（常驻安装、探针开关只控制细节日志），此处不再重复安装 —— 两条腿各装一次
         * setImplementation 会互相覆盖转发指针，表现为无限递归/丢帧。 */

        AevonGripHookInstalled = YES;
        AevonGripProbeTouch(-2, 0, 0);       // -2 = 安装成功
        return YES;
    } @catch (NSException *exception) {
        AevonGripProbeTouch(-3, 0, 0);       // -3 = 安装异常
        return NO;
    }
}

/* ===========================================================================
 * V0.3.9（AevonGripOwnLegV309）：自建识别器腿 —— 走 Stheno 真正的那条路
 *
 * 为什么必须自己造一个识别器（而不是继续借系统的）：
 *   Aevon(87) 实锤 —— 50 次呼盘里 24 次在桌面、16 次在抖音、9 次在 QQ，
 *   而 App 侧 dylib 只加载了 Preferences / Spotlight / Filza 三个进程。
 *   也就是说「App 侧吞带」在真实使用场景里 98% 的时候根本不在场：
 *   它不是「有时失效」，是「绝大多数时候不在」。那条路对抖音（__RESTRICT）、
 *   QQ（未注入）、桌面（SpringBoard 被排除）天生无效，调参救不回来。
 *
 *   唯一能覆盖这三处的机制是「在 App 收到 began 之前就把触摸收走」，
 *   而这件事只有握有仲裁身份的识别器做得到 —— 而 0.0.x 的老教训（0.1.9）
 *   是「把自己造的 pan 挂到 App 的 window 上」：没有仲裁身份 → 永远停
 *   possible → UIKit 一直不补发被扣的 began → 「只能点不能滑」。
 *   差别不是 delaysTouchesBegan 有毒，是**缺了注册这一步**。
 *
 * Stheno 的原版结构（ScreenCore 的 SCArcGestureCoordinator，classdump 实锤）：
 *   -sc_registerSystemGestureRecognizer:  把自己的识别器注册进系统手势管线
 *   -gestureRecognizer:shouldReceiveTouch: / -sc_canBeginAtPoint:  触摸级过滤
 *   -sc_handleArcPan:                      真正的手势处理
 *   -sc_acquireSystemGestureDisableAssertion  关掉竞争的系统手势
 * 本版对应：AevonOwnLegGesture + AevonOwnTryRegister + 白名单取证。
 *
 * 安全设计（任何一条不成立都不会影响现有功能）：
 *   · 开关 GripOwnLeg 默认关 —— 不打开等于这段代码不存在；
 *   · 拿不到系统手势管理器 → 退回「直接挂到系统边沿识别器的宿主视图」（UISystemGestureView）；
 *   · 注册方法按白名单逐个试签名（返回 void + 恰好 1 个 id 参数），不符一律不调；
 *   · 绝不枚举全类表（0.2.72 SIGTRAP 铁律），只对已知类做 method_getTypeEncoding；
 *   · 0.1.9 复发的闸：0.28s 内没达阈值 → 主动 failed 放行；纵向为主 → 放行；
 *     抬手没左滑 → 放行。任何一条路径都不会把触摸扣到抬手之后；
 *   · 断言（acquireSystemGestureDisableAssertion…）只在 GripHookProbe 打开时做取证调用，
 *     日常不申请 —— 它的真实语义（会不会连系统手势一起关掉）还没验证，先不动手。
 * =========================================================================== */

extern int AevonGripOwnBandHit(double x, double y);
extern void AevonGripOwnSummon(double x, double y, double startX, double startY);
extern void AevonGripOwnLog(const char *kind, const char *detail);

/* 全局状态（gAevonOwnLegEnabled / gAevonOwnGesture …）定义在前置区 —— 见
 * AevonGripLegObserve 上方的说明，别挪回这里。 */

#pragma mark - 自建识别器

@interface AevonOwnLegGesture : UIGestureRecognizer
@end

@implementation AevonOwnLegGesture {
    CGPoint _ownStart;
    BOOL _ownSummoned;
    NSTimer *_ownBail;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        /* 这两行就是「App 一像素都不跟」的全部来源：
         * delaysTouchesBegan = YES → 未决期间不向视图派发 began；
         * cancelsTouchesInView = YES → 识别成功时把已派发的触摸 cancel 掉。
         * 与 0.1.9 的唯一区别是这个识别器有仲裁身份（不是挂在 App 的 window 上）。 */
        self.delaysTouchesBegan = YES;
        self.cancelsTouchesInView = YES;
    }
    return self;
}

- (void)dealloc {
    [_ownBail invalidate];
}

/// 放行（failed）：触摸原样还回去，App 该收什么收什么。
- (void)ownPass:(const char *)why {
    [_ownBail invalidate];
    _ownBail = nil;
    if (self.state == UIGestureRecognizerStatePossible) {
        self.state = UIGestureRecognizerStateFailed;
        AevonGripOwnLog("pass", why);
    }
}

/// 0.1.9 复发的闸门：0.28s 内没达到阈值就当成「不是呼盘手势」，立刻放行。
- (void)ownBailFired {
    _ownBail = nil;
    [self ownPass:"0.28s 内未达阈值 → 放行（AevonNoStuckV309 防扣死）"];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint p = (t != nil) ? [t locationInView:nil] : CGPointZero;
    /* 落点判据在**落指那一刻**做 —— 这才是自建腿相对「借识别器」的本质优势：
     * 0.3.8 只能在达阈值之后用后置几何否决，那时 App 已经跟了 8pt 了。 */
    if (AevonGripOwnBandHit((double)p.x, (double)p.y) == 0) {
        [self ownPass:"落点不在把手带内 → 立刻放行（侧滑返回/边缘滚动不受影响）"];
        return;
    }
    _ownStart = p;
    _ownSummoned = NO;
    [_ownBail invalidate];
    _ownBail = [NSTimer scheduledTimerWithTimeInterval:0.28
                                                target:self
                                              selector:@selector(ownBailFired)
                                              userInfo:nil
                                               repeats:NO];
    AevonGripOwnLog("hold", "落点在把手带内 → 扣住触摸，等左滑达阈值（App 此时收不到 began）");
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible || _ownSummoned) { return; }
    UITouch *t = touches.anyObject;
    CGPoint p = (t != nil) ? [t locationInView:nil] : CGPointZero;
    CGFloat dx = p.x - _ownStart.x;
    CGFloat dy = p.y - _ownStart.y;
    if (fabs((double)dy) > 40.0) {
        [self ownPass:"纵向为主 → 放行（不抢滚动/翻页）"];
        return;
    }
    if (dx <= -8.0) {
        _ownSummoned = YES;
        [_ownBail invalidate];
        _ownBail = nil;
        self.state = UIGestureRecognizerStateBegan;
        AevonGripOwnSummon((double)p.x, (double)p.y,
                           (double)_ownStart.x, (double)_ownStart.y);
        self.state = UIGestureRecognizerStateEnded;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [_ownBail invalidate];
    _ownBail = nil;
    if (self.state == UIGestureRecognizerStatePossible) {
        self.state = UIGestureRecognizerStateFailed;
        AevonGripOwnLog("tap", "点击（没左滑）→ 放行，App 收得到这一下");
    } else if (self.state == UIGestureRecognizerStateBegan
               || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [_ownBail invalidate];
    _ownBail = nil;
    self.state = UIGestureRecognizerStateCancelled;
}

@end

#pragma mark - 系统手势管理器取证（白名单，不枚举）

/// 只对**已知方法名**做探测 —— 0.2.72 的 SIGTRAP 就是全类表枚举炸的，
/// 这里一次全类表枚举都没有（连那个 API 名都不写：注释也会命中 CI 的防回退断言）。
static void AevonOwnProbeSels(Class cls, NSString *tag) {
    if (cls == Nil) { return; }
    /* V0.3.10：装配改成「每 2s 重试一次」，取证只打一轮 —— 不然 15 次重试会刷 15 行。 */
    if (gAevonOwnCensusLogged) { return; }
    NSArray<NSString *> *names = @[
        @"addGestureRecognizer:toDisplayWithIdentity:",
        @"addGestureRecognizer:", @"addGestureRecognizer:withType:",
        @"registerGestureRecognizer:", @"registerGestureRecognizer:forType:",
        @"_registerGestureRecognizer:", @"_registerGestureRecognizer:forType:",
        @"acquireSystemGestureDisableAssertionForReason:exceptSystemGestureTypes:"
    ];
    NSMutableString *hits = [NSMutableString string];
    for (NSString *n in names) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(n));
        if (m == NULL) { continue; }
        const char *enc = method_getTypeEncoding(m);
        [hits appendFormat:@" %@=%s", n, enc ? enc : "?"];
    }
    NSString *line = [NSString stringWithFormat:@"%@（%s）%@",
                      tag, class_getName(cls),
                      hits.length > 0 ? hits : @" 白名单零命中"];
    AevonGripOwnLog("census", line.UTF8String);
}

static id AevonOwnLookupManager(void) {
    id found = nil;
    /* ① SB 侧单例：17.3.1 上类存在，但此前普查「无候选方法」——
     *    所以这里先取证再取实例，两个白名单单例名都试。 */
    Class sbm = NSClassFromString(@"SBSystemGestureManager");
    if (sbm != Nil) {
        AevonOwnProbeSels(sbm, @"SBSystemGestureManager");
        for (NSString *s in @[@"sharedInstance", @"sharedSystemGestureManager"]) {
            SEL sel = NSSelectorFromString(s);
            if ([sbm respondsToSelector:sel]) {
                id inst = ((id (*)(id, SEL))objc_msgSend)(sbm, sel);
                if (inst != nil) { found = inst; break; }
            }
        }
    }
    /* ② UIKit 私有 manager：对象属性走 KVC（标量才禁 perform，对象安全）。
     * V0.3.10（AevonOwnLegRegV310）：0.3.9 只问了 UIApplication —— 单一来源，
     * 拿不到就整条腿放弃。这里补三个来源：UIScreen、前台 UIWindowScene、后台场景。 */
    if (found == nil) {
        NSMutableArray *owners = [NSMutableArray array];
        @try {
            [owners addObject:[UIApplication sharedApplication]];
        } @catch (NSException *exception) {
        }
        @try {
            [owners addObject:[UIScreen mainScreen]];
        } @catch (NSException *exception) {
        }
        @try {
            for (UIScene *s in [[UIApplication sharedApplication] connectedScenes]) {
                [owners addObject:s];
            }
        } @catch (NSException *exception) {
        }
        for (id owner in owners) {
            if (owner == nil) { continue; }
            for (NSString *k in @[@"_systemGestureManager", @"systemGestureManager"]) {
                @try {
                    id v = [owner valueForKey:k];
                    if (v != nil) {
                        AevonOwnProbeSels([v class], @"UISystemGestureManager");
                        found = v;
                        break;
                    }
                } @catch (NSException *exception) {
                }
            }
            if (found != nil) { break; }
        }
    }
    return found;
}

/// display identity：注册 API 的第二个参数。Stheno 存的是 `__systemDisplayIdentity`，
/// 来源就是屏幕/场景的 displayIdentity。拿不到就传 nil（让系统自己取主屏）。
static id AevonOwnDisplayIdentity(void) {
    NSMutableArray *owners = [NSMutableArray array];
    @try {
        [owners addObject:[UIScreen mainScreen]];
    } @catch (NSException *exception) {
    }
    @try {
        for (UIScene *s in [[UIApplication sharedApplication] connectedScenes]) {
            [owners addObject:s];
        }
    } @catch (NSException *exception) {
    }
    for (id owner in owners) {
        if (owner == nil) { continue; }
        for (NSString *k in @[@"_displayIdentity", @"displayIdentity"]) {
            @try {
                id v = [owner valueForKey:k];
                if (v != nil) { return v; }
            } @catch (NSException *exception) {
            }
        }
    }
    return nil;
}

/* V0.3.10（AevonOwnLegRegV310）：注册候选换成 **Stheno 逆向 strings 实测的真名**。
 *
 * `analysis/screencore/strings_ScreenCore.txt` 里连续三行就是 Stheno 的调用序列：
 *     662  _UISystemGestureManager
 *     664  addGestureRecognizer:toDisplayWithIdentity:
 *     669  SBSystemGestureManager
 *     671  acquireSystemGestureDisableAssertionForReason:exceptSystemGestureTypes:
 *
 * 而 0.3.9 试的三个候选（`addGestureRecognizer:` / `registerGestureRecognizer:`
 * / `_registerGestureRecognizer:`）**一个都不是真名** —— 所以那一版即使开关打开，
 * 也必然落到「挂宿主旁听」这条没有仲裁身份的退路。这版先试两参真名。
 */
/// 注册：白名单逐个试，签名必须「返回 void + 参数个数与候选一致」，否则不调。
static BOOL AevonOwnTryRegister(id mgr, UIGestureRecognizer *g) {
    if (mgr == nil || g == nil) { return NO; }
    /* ①两参真名：addGestureRecognizer:toDisplayWithIdentity:（Stheno 用的就是它） */
    SEL sel2 = NSSelectorFromString(@"addGestureRecognizer:toDisplayWithIdentity:");
    if ([mgr respondsToSelector:sel2]) {
        Method m = class_getInstanceMethod([mgr class], sel2);
        if (m != NULL) {
            const char *enc = method_getTypeEncoding(m);
            if (enc == NULL || enc[0] != 'v' || AevonGripEncArgCount(enc) != 2) {
                NSString *line = [NSString stringWithFormat:
                                  @"addGestureRecognizer:toDisplayWithIdentity: 签名不符（%s）→ 不调",
                                  enc ? enc : "?"];
                AevonGripOwnLog("register", line.UTF8String);
            } else {
                id identity = AevonOwnDisplayIdentity();
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, sel2, g, identity);
                    NSString *line = [NSString stringWithFormat:
                                      @"已用 addGestureRecognizer:toDisplayWithIdentity: 注册进系统手势管理器"
                                      @"（拿到仲裁身份；identity=%s）",
                                      identity != nil ? class_getName(object_getClass(identity)) : "nil"];
                    AevonGripOwnLog("register", line.UTF8String);
                    return YES;
                } @catch (NSException *exception) {
                    NSString *line = [NSString stringWithFormat:
                                      @"addGestureRecognizer:toDisplayWithIdentity: 抛异常 %@ → 换下一个",
                                      exception.name];
                    AevonGripOwnLog("register", line.UTF8String);
                }
            }
        }
    }
    /* ②一参写法（留作兜底：部分系统版本上 SBSystemGestureManager 是 addGestureRecognizer:） */
    NSArray<NSString *> *cands = @[@"addGestureRecognizer:",
                                   @"registerGestureRecognizer:",
                                   @"_registerGestureRecognizer:"];
    for (NSString *name in cands) {
        SEL sel = NSSelectorFromString(name);
        if (![mgr respondsToSelector:sel]) { continue; }
        Method m = class_getInstanceMethod([mgr class], sel);
        if (m == NULL) { continue; }
        const char *enc = method_getTypeEncoding(m);
        if (enc == NULL || enc[0] != 'v' || AevonGripEncArgCount(enc) != 1) {
            NSString *line = [NSString stringWithFormat:@"%@ 签名不符（%s）→ 不调",
                              name, enc ? enc : "?"];
            AevonGripOwnLog("register", line.UTF8String);
            continue;
        }
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, sel, g);
            NSString *line = [NSString stringWithFormat:@"已用 %@ 注册进系统手势管理器（拿到仲裁身份）", name];
            AevonGripOwnLog("register", line.UTF8String);
            return YES;
        } @catch (NSException *exception) {
            NSString *line = [NSString stringWithFormat:@"%@ 抛异常 %@ → 换下一个", name, exception.name];
            AevonGripOwnLog("register", line.UTF8String);
        }
    }
    return NO;
}

/// 退路：直接挂到系统边沿识别器的宿主视图（UISystemGestureView）。
/// 不依赖任何未知 API；层级上仍然在 App 之上，只是没有管理器层面的仲裁登记。
static void AevonOwnAttachTo(UIView *host) {
    if (host == nil || gAevonOwnGesture != nil) { return; }
    AevonOwnLegGesture *g = [[AevonOwnLegGesture alloc] init];
    [host addGestureRecognizer:g];
    gAevonOwnGesture = g;
    NSString *line = [NSString stringWithFormat:@"已挂到宿主 %s（退路：未拿到管理器仲裁身份）",
                      class_getName(object_getClass(host))];
    AevonGripOwnLog("attach", line.UTF8String);
}

/// 取证用的断言（只在 GripHookProbe 打开时调；日常不申请）。
void AevonGripOwnLegAssertProbe(void) {
    if (!gAevonOwnLegProbeOn || gAevonOwnManager == nil) { return; }
    SEL sel = NSSelectorFromString(@"acquireSystemGestureDisableAssertionForReason:exceptSystemGestureTypes:");
    if (![gAevonOwnManager respondsToSelector:sel]) { return; }
    Method m = class_getInstanceMethod([gAevonOwnManager class], sel);
    if (m == NULL) { return; }
    const char *enc = method_getTypeEncoding(m);
    if (enc == NULL || enc[0] != '@' || AevonGripEncArgCount(enc) != 2) {
        AevonGripOwnLog("assert", "签名不符（期望 @…@16Q24）→ 跳过");
        return;
    }
    @try {
        id token = ((id (*)(id, SEL, id, unsigned long long))objc_msgSend)
            (gAevonOwnManager, sel, @"AevonGripOwnLegV309", 0ULL);
        NSString *line = token != nil ? @"断言已拿到（只取证，不改变行为）" : @"断言返回 nil";
        AevonGripOwnLog("assert", line.UTF8String);
    } @catch (NSException *exception) {
        AevonGripOwnLog("assert", "断言调用抛异常 → 已跳过");
    }
}

/// 装配入口：由 AevonGripLegObserve 在第一次看到边沿识别器时调用（宿主就在眼前）。
/// 装配一次（不递归、不排定时器）：管理器注册优先，宿主旁听只在探针打开时才做。
/// 返回 YES 表示这一段已经装好（成功注册 或 探针旁听），NO 表示还可以再试。
static BOOL AevonOwnTryArmOnce(UIView *host) {
    if (gAevonOwnRegistered) { return YES; }
    if (gAevonOwnGesture != nil) { return YES; }
    /* ①管理器注册 —— 不依赖宿主视图，这是拿仲裁身份的唯一正路 */
    gAevonOwnManager = AevonOwnLookupManager();
    gAevonOwnManagerTried = YES;
    if (gAevonOwnManager != nil) {
        AevonOwnLegGesture *g = [[AevonOwnLegGesture alloc] init];
        if (AevonOwnTryRegister(gAevonOwnManager, g)) {
            gAevonOwnGesture = g;
            gAevonOwnRegistered = YES;
            return YES;
        }
    }
    /* ②宿主旁听：**没有仲裁身份**（我们这只不 gate 跨进程派发），日常不启用 ——
     *    0.3.9 把它当默认退路是错的：注册失败时它会让「打开开关后行为反而更差」。
     *    只有 GripHookProbe 打开时才挂上做取证。 */
    if (gAevonOwnLegProbeOn && host != nil) {
        AevonOwnAttachTo(host);
        return YES;
    }
    return NO;
}

void AevonGripOwnLegArm(UIView *host) {
    if (!gAevonOwnLegEnabled) { return; }
    /* 走管理器注册的识别器，view 由系统在合适时机给（可能一直是 nil）—— 不重装。 */
    if (gAevonOwnRegistered) { return; }
    if (gAevonOwnGesture != nil) {
        /* 旁听那条路：宿主视图（UISystemGestureView）随场景重建会消失，
         * 识别器的 view 变 nil 就说明它已经不在任何视图上了 → 重装到新宿主。 */
        UIGestureRecognizer *cur = (UIGestureRecognizer *)gAevonOwnGesture;
        if (cur.view != nil) { return; }
        gAevonOwnGesture = nil;
    }
    AevonOwnTryArmOnce(host);
}

/* V0.3.10（AevonOwnLegRegV310）：主动装配 —— 不等第一次滑动。
 *
 * 0.3.9 的装配只发生在 `AevonGripLegObserve` 里（看到系统边沿识别器状态迁移时），
 * 也就是说「开关打开后的第一次右缘滑动必然白扔一次」，而管理器也只找一次，
 * 找不成就永远不装。这里改成：开关一打开就开始试，每 2s 一次、上限 15 次
 *（约 30s，足够 SpringBoard 把窗口建好），试到就停。
 * fail-open：全试完仍不成功 → 什么都不挂，行为与 0.3.9 关闭时完全一致。
 */
void AevonGripOwnLegKick(void) {
    if (!gAevonOwnLegEnabled || gAevonOwnRegistered) { return; }
    if (gAevonOwnArmTries >= 15) { return; }
    gAevonOwnArmTries++;
    if (AevonOwnTryArmOnce(nil)) { return; }
    if (gAevonOwnArmTries >= 15) {
        AevonGripOwnLog("giveup", "重试 15 次（约 30s）仍未拿到仲裁身份 → 不挂宿主旁听，"
                                 "保持借识别器腿（AevonOwnLegRegV310 fail-open）");
        return;
    }
    if (gAevonOwnArmTries == 1) {
        AevonGripOwnLog("kick", "首次装配未成功（管理器或注册方法未命中）→ 每 2s 再试，上限 15 次");
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AevonGripOwnLegKick();
    });
}

/// 开关（由 Swift 启动时按 prefs 调，**设置页改动也会实时调到这里**）。
void AevonGripOwnLegEnable(BOOL on, BOOL probeOn) {
    BOOL was = gAevonOwnLegEnabled;
    gAevonOwnLegEnabled = on;
    gAevonOwnLegProbeOn = probeOn;
    if (on) {
        if (!was) { gAevonOwnArmTries = 0; }
        AevonGripOwnLog("enable", "自建识别器腿已启用 → 立即开始装配"
                                 "（落指即判 + delaysTouchesBegan，AevonOwnLegDefaultV310）");
        dispatch_async(dispatch_get_main_queue(), ^{
            AevonGripOwnLegKick();
        });
    } else {
        /* 关掉：把已装的识别器摘下来，注册状态清零，允许下次再装。
         * 靠管理器注册的那只 view 可能恒 nil，摘不掉 → 直接 enabled = NO 让它彻底失活。 */
        if (gAevonOwnGesture != nil) {
            UIGestureRecognizer *g = (UIGestureRecognizer *)gAevonOwnGesture;
            UIView *v = g.view;
            if (v != nil) {
                [v removeGestureRecognizer:g];
            } else {
                g.enabled = NO;
            }
            gAevonOwnGesture = nil;
        }
        gAevonOwnRegistered = NO;
        gAevonOwnArmTries = 0;
        AevonGripOwnLog("enable", "自建识别器腿关闭（GripOwnLeg = false）：已装识别器摘除，退回借识别器腿");
    }
}

/// 状态查询（给 Swift 侧日志/CI 判断用）。
BOOL AevonGripOwnLegReady(void) {
    return gAevonOwnGesture != nil;
}


/* V0.3.7（AevonYieldDefaultV307）：让路模式转正 —— GripSystemYield 默认值
 * false → true，SB 侧把手默认不接触摸，右缘呼盘全部交给系统边沿识别器。
 * 依据 Aevon(85)：让路开启的 67 秒里 33 次呼盘 33 次全由系统识别器腿完成
 * （前台全在抖音 com.ss.iphone.ugc.Aweme —— __RESTRICT、Aevon 无注入），
 * 「手指落在把手上」0 条、「（全局通道）」0 条、「不在右缘」0 条、0 崩溃。
 * 这就是 Stheno 的架构：只骑系统识别器，Aevon 一根手指都不碰。
 * 标记必须是纯 ASCII 且带 used —— 注释永不进二进制，App 侧标记同理。 */
__attribute__((used)) static const char AevonYieldDefaultV307Marker[] = "AevonYieldDefaultV307";

/* V0.3.8（AevonGripZoneV308）：触发区从「右缘 24pt × 任意高度」收成一条可配的带。
 * 依据 Aevon(86)：68 次呼盘起点 x 406~425（全在右缘），落点 y 从 381 铺到 722 ——
 * 判据里没有 y，于是右缘任意高度左滑都呼盘，还和侧滑返回插件抢手势。
 * 现在横向 GripWidth（12~60，默认 24，下限 17）、纵向 GripY/GripLen（Len 上限
 * 120→400）+ 上下各 10pt 余量；带外归还给插件。GripScope 开关可切回整条兜底。
 * 同一份几何在 App 侧 AevonAppSide.m 的 AevonGripRefreshCache 里镜像一份 ——
 * 触发带必须 ⊂ 吞带，否则会出现「圆盘出来了、App 却跟着滑了几像素」的半截状态。 */
__attribute__((used)) static const char AevonGripZoneV308Marker[] = "AevonGripZoneV308";

/* V0.3.9（AevonGripOwnLegV309）：自建识别器腿 —— 自己造 UIGestureRecognizer、
 * delaysTouchesBegan=YES / cancelsTouchesInView=YES，注册进系统手势管理器
 *（拿不到就退回挂 UISystemGestureView），落指那一刻就用 bandRect 决定收不收这根手指。
 * 依据 Aevon(87)：50 次呼盘里桌面 24 / 抖音 16 / QQ 9 / 设置 1，App 侧 dylib 只加载了
 * 三个进程 —— 旧的「App 侧吞带」在真实场景 98% 的时候不在场，不是失效而是在缺席。
 * 0.1.9 的「只能点不能滑」根因也在此定案：不是 delaysTouchesBegan 有毒，
 * 是当年那个 pan 挂在 App 的 window 上、没有仲裁身份、永远 failed 不了。 */
__attribute__((used)) static const char AevonGripOwnLegV309Marker[] = "AevonGripOwnLegV309";

/* V0.3.10（AevonOwnLegRegV310）：把 0.3.9 的「猜名字」换成 Stheno 逆向实测的真名。
 * strings_ScreenCore.txt 的 662/664 行就是 `_UISystemGestureManager` +
 * `addGestureRecognizer:toDisplayWithIdentity:`；0.3.9 试的三个 1 参候选一个都不是真名，
 * 所以那一版即使开关打开也必然落到「挂宿主旁听」——而旁听没有仲裁身份、不 gate 跨进程。
 * 另外两处：①装配改主动重试（6s 起每 2s，上限 15 次），不再等第一次滑动白扔一次；
 * ②开关改实时生效（走 com.aevon.prefschanged）。默认值同时转正为开。 */
__attribute__((used)) static const char AevonOwnLegRegV310Marker[] = "AevonOwnLegRegV310";
__attribute__((used)) static const char AevonOwnLegDefaultV310Marker[] = "AevonOwnLegDefaultV310";
