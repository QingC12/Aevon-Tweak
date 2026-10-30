#import <UIKit/UIKit.h>
#import <objc/runtime.h>
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

extern void AevonGripSystemSummon(double x, double y, double startX, const char *cls);
extern void AevonGripLegProbe(const char *cls, double x, double y, double edges,
                              int delays, int cancels, const char *viewCls);
/// V0.3.5（AevonGripLegOutcomeV305）：认领了但没走到呼盘时的结局上报。
extern void AevonGripLegOutcome(const char *cls, int kind, double maxDx, int frames);

static BOOL gAevonLegProbeOn = NO;      // 设置页 GripHookProbe 打开时才打实例级细节
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
                AevonGripLegDrop(self);
                dispatch_async(dispatch_get_main_queue(), ^{
                    AevonGripSystemSummon(fx, fy, sx, cn != NULL ? cn : "edge");
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

/* V0.3.7（AevonYieldDefaultV307）：让路模式转正 —— GripSystemYield 默认值
 * false → true，SB 侧把手默认不接触摸，右缘呼盘全部交给系统边沿识别器。
 * 依据 Aevon(85)：让路开启的 67 秒里 33 次呼盘 33 次全由系统识别器腿完成
 * （前台全在抖音 com.ss.iphone.ugc.Aweme —— __RESTRICT、Aevon 无注入），
 * 「手指落在把手上」0 条、「（全局通道）」0 条、「不在右缘」0 条、0 崩溃。
 * 这就是 Stheno 的架构：只骑系统识别器，Aevon 一根手指都不碰。
 * 标记必须是纯 ASCII 且带 used —— 注释永不进二进制，App 侧标记同理。 */
__attribute__((used)) static const char AevonYieldDefaultV307Marker[] = "AevonYieldDefaultV307";
