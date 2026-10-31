#import <UIKit/UIKit.h>
#import "AevonGripAssert.h"
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
/* V0.3.12：census 按类名去重 —— 0.3.11 的 gAevonOwnCensusLogged 从来没有被置 YES，
 * 结果是每轮 kick 都重打一遍（Aevon(90) 日志里 6 条 census 全是重复）。
 * 换成按 tag 记账，新加的 `_UISystemGestureManager` 也能各打一条、不刷屏。 */
static NSMutableSet<NSString *> *gAevonOwnCensusSeen = nil;
/* V0.3.11（AevonOwnLegTypeV311）：注册 API 的第二个参数是「手势类型」（unsigned long long）。
 * Stheno 逆向数据里没有这个数值（数值枚举不会出现在 strings 里），0.3.9/0.3.10 已经
 * 因为「猜 API 名」烧过两次 run —— 这次**一个常量都不写**：
 *   · 优先从系统自己那只边沿识别器实例上 KVC 读出来（对象/标量都走 KVC，禁 perform）；
 *   · 读不到就钩一次 addGestureRecognizer:withType: 做纯转发取证，抄系统自己传的值。
 * 取到之前 gAevonOwnGestureType 保持 -1，注册函数见到 -1 一律不调（宁可少一轮也不猜）。 */
static long long gAevonOwnGestureType = -1;
static NSMutableDictionary<NSString *, NSNumber *> *gAevonOwnTypeByClass = nil;
static BOOL gAevonOwnTypeHooked = NO;
static IMP gAevonOrigAddWithType = NULL;
static BOOL gAevonOwnTypeProbeLogged = NO;
/* V0.3.12（AevonOwnClaimV312）：借腿呼盘时「连带认领」这根手指。
 *
 * Aevon(90) 只有一句实测，但它把整个机制讲通了：
 *   「只有第一次呼出圆盘时 app 没有跟着操作，后面的机会都跟着操作」
 * 0.3.11 的自建识别器**一次都没成功识别过**（0 自建呼盘、0 moved），而 UIKit 对
 * 「永远返回 failed 的识别器」会撤销触摸延迟资格 —— 于是只有第一根手指被
 * delaysTouchesBegan 扣住，之后系统就把 began 直接派给 App 了。
 *
 * 解法不是再调参数，而是让自建腿**真的赢一次**：借腿（系统识别器）达阈值的那一刻，
 * 自建腿同步进 Began —— 一方面把已经 hold 住的这根手指正式认领（cancelsTouchesInView），
 * 另一方面让 UIKit 重新记住「这只识别器会识别」，下一次触摸继续延迟。
 * 不违反 0.3.3 定下的铁律：这根手指从 began 那一帧就在我们手里，整根一致。 */
static int gAevonOwnClaims = 0;         // 认领次数（日志判据：应与借腿呼盘次数同阶）
static BOOL gAevonOwnIvarLogged = NO;   // ivar 取证只打一轮
static BOOL gAevonOwnUIKitMgrTried = NO;
/* V0.3.11：自建腿最近一次**真正呼盘**的时刻（不是 hold、不是 pass）。
 * 系统腿在同一手势里晚 20ms 达阈值时靠它让路，日志里不再出现成对的「达阈值但被拦」。 */
static CFTimeInterval gAevonOwnSummonStamp = 0;
/* V0.3.28（AevonYieldGuardV328）：本手势被自建腿接管（打出 hold）的时刻。
 * 借腿让路判据从「识别器已注册」改成「本手势真的接管了」—— 静态事实会让
 * 带外的落指变成「系统腿被拦 + 自建腿无 hold」两头空（Aevon(101) 有 6 次）。 */
static CFTimeInterval gAevonOwnHoldStamp = 0;
/* V0.3.29（AevonOwnSwallowV329）：自建腿当前那根手指的 `UITouch` 指针身份。
 *
 * 为什么要把它交给 Swift：0.3.28 的单层带上，召唤率已经 100%，但**这根手指
 * 从来没被挡住**。`presentRing` 把 `ringSource` 无条件写成 `"global"`，于是自建腿
 * 的手指在下一帧被全局通道的「收养」分支接走 —— 那个分支的语义是「只登记喂盘、不吞」，
 * 依据是 0.2.7 的注释「把手是真实控件，命中天然路由」。可 0.3.13 起 `yieldMode`
 * 为真、把手的 `hitTest` 一律返回 nil，这个前提早就没了。
 * 结果：桌面 `UIScrollViewPanGestureRecognizer` 照常起来（翻页），抖音自己的左滑
 * pan 照常起来（进博主页）。Aevon(101)/(102) 两份日志时序完全一致 —— 不是新版引入的
 * 病，是召唤率从 86% 涨到 100% 之后每次都能看见了。
 *
 * 这里只存指针、不做任何判定：绑定与吞咽全部在 Swift 侧按 prefs 开关执行，
 * ObjC 只管把身份递过去。0 = 当前没有自建腿手指。
 */
static uintptr_t gAevonOwnTouchID = 0;
/* V0.3.29（AevonDeskPanGuardV329）：最近一次「自建腿真的召唤了」的时刻。
 * 桌面翻页 pan 的强制失败窗口用它做闸（见 AevonGripDeskPanShouldFail）。 */
static CFTimeInterval gAevonOwnSummonAtGuard = 0;
/* V0.3.30（AevonEarlyBindV330）：本轮吞层真正丢掉了几帧。
 *
 * 为什么要有这个计数器：0.3.29 的日志能证明「绑定成功 36/36」，但**证不出吞层有没有
 * 真的吞掉一帧** —— 绑定日志和实际吞帧之间没有任何可观测点。Aevon(103) 就卡在这里：
 * 现象变差了，而日志上一片绿。计数器在 `-touchesBegan:` 归零、由 SB `sendEvent:` 的
 * 丢弃分支累加，抬手时打进 lift 那一行。0 = 吞层一帧都没拦住（绑定白做了），
 * 等于抬手的帧数 = 整根手指的帧数（吞层完全没生效）。 */
static uintptr_t gAevonOwnSwallowFrames = 0;
/* V0.3.30（AevonEarlyBindV330）：落指预绑 / 取消预绑 —— 定义在文件尾部，
 * 而调用点（-touchesBegan: / -ownPass:）在上方，必须先声明。 */
void AevonGripOwnPreBind(double x, double y);
void AevonGripPreBindCancel(uintptr_t tid);
/* V0.3.9：装配入口前置声明 —— 定义在文件尾部，而调用点（AevonGripLegObserve）在上方。 */
extern void AevonGripOwnLegArm(UIView *host);
extern void AevonGripOwnLegKick(void);
/* V0.3.29（AevonDeskPanGuardV329）：桌面翻页 pan 守卫 —— 定义在文件尾部，
 * 而调用点（AevonGripGlobalSetState / Pub）在上方，必须先声明。 */
static BOOL AevonGripDeskPanShouldFail(id recog);
static void AevonGripDeskPanGuardNote(void);
/* V0.3.32（AevonSysLegRevokeV332）：系统边缘手势腿的 Began 吊销 —— 同上，先声明。 */
static BOOL AevonGripSysLegShouldFail(id recog);
static void AevonGripSysLegRevokeNote(id recog);
/* V0.3.12：认领入口的前置声明（定义在自建识别器之后；Swift 侧用 silgen_name 直链符号）。 */
extern void AevonGripOwnLegClaim(void);
/* V0.3.11：类型值取证也在 AevonGripLegObserve 里触发（那时边沿识别器实例就在手上）。 */
static void AevonOwnProbeGestureType(id recog, const char *cn);
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
            /* V0.3.11：注册要的「手势类型值」不猜常量 —— 就从系统自己这只边沿识别器上读。
             * 每类只读一次（内部 early-return），KVC 全不命中时自动装取证钩子。 */
            AevonOwnProbeGestureType(self, cn);
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
    /* V0.3.29（AevonDeskPanGuardV329）：桌面翻页 pan 想进 Began 时，若自建腿刚召唤过
     * 且它的宿主就在桌面右缘 → 直接把要转发的状态降成 Failed。
     * 改「转发出去的状态」而不是自己再调一次 setState:，天然不会递归。 */
    if (state == 1 && AevonGripDeskPanShouldFail(self)) {
        state = 4;
        AevonGripDeskPanGuardNote();
    } else if (state == 1 && AevonGripSysLegShouldFail(self)) {
        /* V0.3.32（AevonSysLegRevokeV332）：系统边缘手势腿 **Began 就吊销**。
         * 0.3.29 的借腿让路只在它「达阈值」时才拦，而 Aevon(105) 里抖音那 22 次落指
         * 100% 都被 `_UIPendingEdgeSwipeGestureRecognizer` 认领过 Began —— 它在我们
         * 扣住 moved 之前就已经进了 Began，向后端（App 的交互式返回/横滑通道）
         * 发过「边缘手势已开始」。Began 阶段就掐掉，它连通知都发不出去。 */
        state = 4;
        AevonGripSysLegRevokeNote(self);
    }
    if (gAevonOrigPrivSetState) {
        ((void (*)(id, SEL, NSInteger))gAevonOrigPrivSetState)(self, _cmd, state);
    }
    AevonGripLegObserve(self, state);
}

static void AevonGripGlobalSetStatePub(id self, SEL _cmd, NSInteger state) {
    if (state == 1 && AevonGripDeskPanShouldFail(self)) {
        state = 4;
        AevonGripDeskPanGuardNote();
    } else if (state == 1 && AevonGripSysLegShouldFail(self)) {
        state = 4;
        AevonGripSysLegRevokeNote(self);
    }
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
/* V0.3.28（AevonYieldGuardV328）：接管时刻的记账与读取（定义在文件尾）。
 * 前置声明是必须的 —— `-touchesBegan:` 在 1029 行就要用它，定义在 1850 行。 */
void AevonGripOwnStampHold(void);
double AevonGripOwnHoldAge(void);
/// V0.3.14（AevonEdgePadV314）：三段式落点判定 —— 0 不接管 / 1 贴边 / 2 边缘候选（暂扣）。
extern int AevonGripOwnHitLevel(double x, double y);
extern void AevonGripOwnSummon(double x, double y, double startX, double startY);
/// V0.3.30（AevonEarlyBindV330）：落指预绑 —— 把「开始吞」从召唤提前到落指。
/// 由 `AevonGripOwnPreBind` 调用，实现体在 Swift（`@_cdecl("AevonGripPreBindTouch")`）。
extern void AevonGripPreBindTouch(uintptr_t tid, double x, double y);
/// V0.3.30：撤销预绑。tid 传 0 = 用 Swift 侧自己记的那一个。
extern void AevonGripPreBindClear(uintptr_t tid);
/// V0.3.18（AevonSceneGateV318）：系统浮层闸 —— 控制中心 / 通知中心 / 锁屏（含解锁后
/// 还没上滑进桌面）里返回 1。
///
/// 判据在 Swift 侧（`AevonRingGrip.systemOverlayBlockingRing`，复用 0.2.78 让位那套
/// 窗口栈实证），这里只要一个 int —— 热路径上不碰字符串、不碰 prefs。
extern int AevonGripSystemOverlayBlocked(void);
/* V0.3.26（AevonHomeLooseV326）：桌面判定 —— 返回 1 = 前台无 App（桌面 / 锁屏外的空前台）。
 * 读的是 Swift 侧已缓存的 `currentForegroundBundleID`，热路径上只是一次内存读。 */
extern int AevonGripHomeScreenNow(void);
/// V0.3.16（AevonOwnLiftV316）：自建腿抬手回调 —— 召唤成功后这根手指的**终点**。
/// 第三个参数：0 = touchesEnded（正常抬手），1 = touchesCancelled（被系统摘链）。
extern void AevonGripOwnLift(double x, double y, int32_t cancelled);
/// V0.3.17（AevonOwnFeedV317）：自建腿**每帧**喂盘 —— 召唤成功后这根手指的坐标。
///
/// 为什么必须是识别器自己喂：Aevon(94) 的 11 次看门狗日志里，「最后落点」与
/// 「呼盘那一刻的落点」**逐条相等**（383/392/408/415/410/404…），意味着圆盘从
/// 展开到被收，一条移动帧都没收到。而圆盘唯一还活着的喂料方是 SB `sendEvent`
/// 的全局通道，它要先过 `claimPointer` 的 0.12 秒交换闸（每周期开头必盲），
/// 之后还可能被任一帧 `.cancelled` 把 `globalTouchID` 清掉、且本周期内不许复活
/// （`appEdgePointerAdopted` 只在圆盘收起时清）→ 这一整次就永久静默。
/// 识别器与手指是一对一的，坐标直接从识别器拿，不需要任何通道旁证。
/// Stheno 同构：`-sc_handleArcPan:` → `-sc_pointForGestureRecognizer:` → `-sc_updateSelectionAtPoint:`。
extern void AevonGripOwnMove(double x, double y);
extern void AevonGripOwnLog(const char *kind, const char *detail);

/* V0.3.27（AevonGripConeV327 / AevonGripWidenV327，用户 Aevon(100) #1
 * 「桌面和全屏 app 中手势触发并不是 100% 成功」）。
 *
 * Aevon(100) 实测（93 次右缘落指，6 分钟）：
 *   · 桌面   56 次 → 展开 43（77%）
 *   · 抖音   19 次 → 展开 10（53%）
 *   · 设置   13 次 → 展开  6（46%）
 * App 内被拒的 10 次首帧角度：20°×2 / 48° / 50° / 51° / 52° / 54° / 59°。
 * 全部死在 `ady <= adx × 0.25`（14°）这一条 —— 而这个判据**只在首帧生效**，
 * 后面手指再怎么往左走都没有第二次机会（下一帧先撞上 `|dy| >= 12` 立刻放行）。
 *
 * 两处改动：
 *   ① 锥角 0.25（14°）→ 0.40（22°）。20° 那两次是 dx=-36/dy=13，比值 0.36，
 *      差的就是这口气；
 *   ② 首帧判不出「横向」时**不再立刻放行**，再看 2 帧（累计位移会越滑越横向）——
 *      系统识别器本来就是整段持续判定，只有我们在首帧就下结论。
 * 这两条都只作用于 **App 内**：桌面上没有横向滚动内容可抢，只有翻页，
 * 0.3.26 的「首帧横向占优即呼盘 + 灰带扣到抬手」原样保留。 */
/* V0.3.28（AevonEdgeBandOnly328）：`aev_grip_cone_value` / `aev_grip_widen_off`
 * 两个函数整体删除（连同 `AevonGripCone327` / `AevonGripWidenOff327` 两个键）。
 *
 * 它们服务的是「首帧方向角度锥」这一层判据，而 0.3.28 把方向判据整个去掉了：
 * 带内只看位移量、带外一个字节都不碰。留着一个没人调、却要求 `-Werror` 放行的
 * 死函数，只会让下一版读代码的人以为方向还在参与判定。 */


/* 全局状态（gAevonOwnLegEnabled / gAevonOwnGesture …）定义在前置区 —— 见
 * AevonGripLegObserve 上方的说明，别挪回这里。 */

#pragma mark - 放行原因分桶（V0.3.13）

/* V0.3.13（AevonOwnGateV313）：放行原因**四分类 + 坐标 + 限流**。
 *
 * 为什么必须分类：Aevon(91) 那 18 条 pass 全是同一句话「落点不在把手带内」，
 * 一个字都没有落点坐标 —— 于是「很小的几率触发 App 内操作」到底有几次、每次差几 pt，
 * 全都只能靠猜。现在四类分开计数（带外 / 纵向 / 超时 / 抬手），带坐标，
 * 每类只打前 6 条，剩下的只累加不刷日志。
 * V0.3.14 增第五类（边缘候选被严格判据否掉）—— 它和「纵向为主」是两回事，
 * 混在一起下一轮就看不出「暂扣段到底救回了几次、否掉了几次」。 */
enum {
    AevonOwnPassBand = 0,   // 落点不在呼出区（唯一真正会「漏给 App」的一类）
    AevonOwnPassVert,       // 纵向为主 → 让给滚动/翻页
    AevonOwnPassBail,       // 0.28s 内没达阈值
    AevonOwnPassTap,        // 抬手没左滑
    AevonOwnPassStrict,     // V0.3.14：边缘候选但不像纯水平左滑 → 立刻还回去
    AevonOwnPassOverlay,    // V0.3.18：系统浮层在屏（控制中心/通知中心/锁屏）→ 不接管
    AevonOwnPassKindCount
};
static NSInteger gAevonOwnPassByKind[AevonOwnPassKindCount];

static void AevonOwnPassCount(const char *kind, int bucket, NSString *detail) {
    if (bucket < 0 || bucket >= AevonOwnPassKindCount) {
        AevonGripOwnLog(kind, detail.UTF8String);
        return;
    }
    NSInteger n = ++gAevonOwnPassByKind[bucket];
    if (n > 6) { return; }
    NSString *line = [NSString stringWithFormat:@"%@（累计 %ld 条，同类只打前 6 条）",
                      detail, (long)n];
    AevonGripOwnLog(kind, line.UTF8String);
}

#pragma mark - 自建识别器

@interface AevonOwnLegGesture : UIGestureRecognizer
/// V0.3.12（AevonOwnClaimV312）：被借腿连带认领 —— YES 表示真的认领到了。
- (BOOL)ownClaimNow;
/// V0.3.29（AevonOwnSwallowV329）：把这根手指移交给全局吞层（只清自建腿簿记，不动 state）。
- (void)ownHandoff;
/// V0.3.31（AevonSwallowFeedV331）：位移判据本体 —— `-touchesMoved:` 与吞层回喂共用一份。
- (void)ownJudgeMove:(CGPoint)p;
/// V0.3.31（AevonSwallowFeedV331）：吞层回喂入口 —— 这一帧被丢弃了，但判定不能少这一帧。
- (void)ownExternalMove:(CGPoint)p;
/// V0.3.32（AevonHeldBeginV332）：落指判据本体 —— UIKit 派进来的 began 与「吞层扣住
/// 事件之后外部喂进来的 begun」共用同一份。返回 YES = 这根手指归自建腿。
- (BOOL)ownBeginAtPoint:(CGPoint)p touch:(UITouch *)t tid:(uintptr_t)tid;
/// V0.3.32（AevonHeldBeginV332）：回放前「退出本轮」—— 保证绝不半路改吞（0.3.3 铁律）。
- (void)ownDisarm;
/// V0.3.32（AevonHeldBeginV332）：外部收尾 —— 抬手帧被吞掉时 UIKit 不会派 ended 进来。
- (void)ownExternalEndAtPoint:(CGPoint)p;
/// V0.3.32（AevonHeldBeginV332）：是否已判出召唤（吞层据此决定「继续扣住 / 回放」）。
- (int)ownSummonedInt;
@end

@implementation AevonOwnLegGesture {
    CGPoint _ownStart;
    BOOL _ownSummoned;
    NSTimer *_ownBail;
    CFTimeInterval _ownStartStamp;   // V0.3.11：落指时刻（0.9s 总上限的基准）
    int _ownMovedFrames;             // V0.3.11：本手势收到的 moved 帧数（判「注册到底生效没有」）
    int _ownFeedFrames;              // V0.3.17：召唤成功后喂给圆盘的 moved 帧数（>1 = 喂料真的在跑）
    NSTimer *_ownHold;               // V0.3.12：认领后的兜底放行（手指不抬手也不会卡住）
    CGPoint _ownHit;                 // V0.3.14：began 落点（日志与借腿让路判据都用它）
    /* V0.3.28（AevonSummonTTLV328）：`_ownSummoned` 的置位时刻。
     * 顶部守卫 `if (_ownSummoned) return;` 原来没有任何超时 —— 一旦某轮因异常路径
     * （识别器被系统摘掉、Ended 没派进来）没清掉，后续**所有**落指被静默吞掉，
     * 日志表现是「看到右缘 began 有、自建腿 hold 一行都没有」，排查成本极高。 */
    CFTimeInterval _ownSummonedAt;

    __weak UITouch *_ownTouch;       // V0.3.16：召唤那根手指 —— 抬手回调只认它自己
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
    [_ownHold invalidate];
}

/* ---------------------------------------------------------------------------
 * V0.3.16（AevonOwnLiftV316）：必须自己实现 -reset，否则「活到抬手」会变成永久卡死。
 *
 * UIKit 的契约：识别器进入 Ended / Cancelled / Failed 之后会调 `-reset`，把状态
 * 退回 Possible，下一次触摸才重新开始。0.3.15 及以前召唤完立刻置 Ended + reset，
 * `_ownSummoned` 由下一根手指的 `touchesBegan` 顺手清掉，所以从没暴露这个问题。
 *
 * 本版识别器活到抬手，`_ownSummoned` 要一直保持到那一刻；而 `touchesBegan` 顶部的
 * 「召唤中的手指还没抬，别的手指不参与」守卫（`if (_ownSummoned) { return; }`）会
 * 在清标记之前就 return —— 只要漏掉这一处，**第一次呼盘之后自建腿就永久哑火**，
 * 而且日志上完全看不出来（没有 began、没有 pass、什么都没有）。
 * 所以清标记只能由 UIKit 的正式生命周期回调来做，不能寄望于下一次 touchesBegan。
 *
 * Stheno 的 `SCArcGestureRecognizer` 同样是这个结构：ivar `__trackingActive` +
 * `__resetHandler`，`-reset` 里回调 coordinator 的 `sc_finishTracking`。
 * ------------------------------------------------------------------------- */
- (void)reset {
    [super reset];
    [_ownBail invalidate];
    _ownBail = nil;
    /* V0.3.28（AevonSysAssertV328）：识别器生命周期结束 = 跟踪结束，断言必须还。
     * 这是最可靠的一道：UIKit 保证 Ended/Cancelled/Failed 之后一定调 reset。 */
    AevonGripAssertRelease();
    [_ownHold invalidate];
    _ownHold = nil;
    _ownSummoned = NO;
    _ownSummonedAt = 0;
    _ownTouch = nil;
    /* V0.3.29（AevonOwnSwallowV329）：身份一并作废 —— 指针会被复用，
     * 留着它会让下一次绑定绑到一根已经不存在的手指上。 */
    gAevonOwnTouchID = 0;
    _ownMovedFrames = 0;
    _ownFeedFrames = 0;
    _ownStartStamp = 0;
    /* `_ownStart` 归零不是洁癖：万一有「上根手指的 moved 落到新会话里」的怪帧，
     * dx 会变成一个大正数，`dx <= -8` 判据直接不成立，比留着旧起点安全。 */
    _ownStart = CGPointZero;
}

/* V0.3.29（AevonOwnSwallowV329）：把这根手指正式移交给全局吞层。
 *
 * 吞层接手之后，这个识别器**再也不会收到任何帧**（整条 UIEvent 在 `sendEvent:` 就没了），
 * 于是 `-touchesEnded:` / `-reset` / `ownBailRearm` 三条清场路径同时失效。
 * 不清 `_ownSummoned` 的后果很具体：抬手之后 2.5s 内任何新落指都会在
 * `-touchesBegan:` 顶部被当成「上一轮还没结束」直接 return —— 用户感觉是
 * 「呼完一次盘，两秒半内怎么划都没反应」。
 *
 * 故意**不改 `self.state`**：手指已经交给吞层，此时把识别器置 Ended/Cancelled
 * 会让 UIKit 把延迟中的触摸补投给下层，正好是这一版要消灭的那个行为。
 * 断言也不在这里还 —— 由 Swift 侧在全局通道的 ended 里显式归还。 */
- (void)ownHandoff {
    /* V0.3.31（AevonSwallowFeedV331）：只作废身份，**保留 `_ownSummoned` 与 `_ownTouch`**。
     *
     * 0.3.29 的原始写法是「全清」（把 `_ownSummoned` 置假、`_ownTouch` 归 nil、
     * `_ownFeedFrames` 清零），它成立的前提是「吞层接手后识别器再也收不到帧」。
     * 那个前提在本版已经不成立：
     * 抬手帧是**放行**的（`shouldSwallowGlobalTouch` 里 `phase == 3 || 4 → return false`），
     * 识别器照样收得到 ended，`-reset` 也照样会来。
     *
     * 全清的代价已经量出来了：Aevon(103)/(104) 两份日志里
     * `本轮识别器喂 N 帧｜吞层实丢 M 帧` **一条都没打出来** —— state 被抬到了 Began，
     * 但 `_ownSummoned` 是 NO，`-touchesEnded:` 走的是「Began → Ended」那条哑分支，
     * 统计行被跳过。本版正是要靠这一行判「吞层到底吞没吞、回喂有没有跑」，
     * 所以保留标记让识别器走完整的召唤生命周期。
     *
     * 2.5s TTL 守卫（`-touchesBegan:` 顶部）仍然有效：万一 `-reset` 不来，
     * 下一根手指落指时会被超时让位，不会回到「圆盘突然彻底没反应」的死窗口。 */
    gAevonOwnTouchID = 0;
    [_ownBail invalidate];
    _ownBail = nil;
    [_ownHold invalidate];
    _ownHold = nil;
}

/* V0.3.12（AevonOwnClaimV312）：借腿赢下仲裁的那一刻，把这根手指正式认领。
 *
 * 这是 0.3.11「只有第一次生效」的正解：识别器必须真的会识别，UIKit 才继续给它
 * 触摸延迟资格。返回 YES 表示这一次真的认领到了（此时 state 已进 Began）。 */
- (BOOL)ownClaimNow {
    if (self.state != UIGestureRecognizerStatePossible) { return NO; }
    if (_ownSummoned) { return NO; }
    _ownSummoned = YES;
    _ownSummonedAt = CACurrentMediaTime();
    [_ownBail invalidate];
    _ownBail = nil;
    self.state = UIGestureRecognizerStateBegan;
    [_ownHold invalidate];
    _ownHold = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                target:self
                                              selector:@selector(ownHoldFired)
                                              userInfo:nil
                                               repeats:NO];
    return YES;
}

/// 认领后 3s 手指还没抬（或 ended 没派进来）→ 强制收尾，绝不让识别器卡在 Began。
- (void)ownHoldFired {
    _ownHold = nil;
    if (self.state == UIGestureRecognizerStateBegan
        || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateCancelled;
    }
}

/// 放行（failed）：触摸原样还回去，App 该收什么收什么。
/// V0.3.13（AevonOwnGateV313）：原因四分类 + 坐标 + 同类限流 6 条（见 AevonOwnPassCount）。
- (void)ownPass:(const char *)why bucket:(int)bucket detail:(NSString *)detail {
    [_ownBail invalidate];
    _ownBail = nil;
    /* V0.3.29（AevonOwnSwallowV329）：放行 = 这根手指不归我们，身份立即作废，
     * 否则 Swift 侧下一次召唤会绑到一根已经被还回去的手指上。 */
    gAevonOwnTouchID = 0;
    /* V0.3.30（AevonEarlyBindV330）：放行同时**撤销预绑**，把还在扣着的那根手指
     * 立刻还给 App。不撤的后果很具体：点击（无 moved）会一直扣到 4s 超时，
     * 右缘 15pt 内的点击变成「按下去半秒没反应」。
     * 传 0 让 Swift 侧用它自己记的那个 tid 判（这里 `gAevonOwnTouchID` 刚被清掉）。 */
    AevonGripPreBindCancel(0);
    /* V0.3.28（AevonSysAssertV328）：手指不归我们了，断言立刻还回去。
     * 少还一次 = 用户在这段时间里右滑返回失灵，所以这里是「放行」这条路上唯一的收尾点。 */
    AevonGripAssertRelease();
    if (self.state == UIGestureRecognizerStatePossible) {
        self.state = UIGestureRecognizerStateFailed;
        AevonOwnPassCount(why, bucket, detail);
    }
}

/// 0.1.9 复发的闸门：0.28s 内没达到阈值就当成「不是呼盘手势」，立刻放行。
/// V0.3.11：从「固定 0.28s」改成「滚动 0.28s + 总上限 0.9s」—— 手指只要还在动就算数，
/// 慢速滑动不会被误放行；但无论如何 0.9s 必放，绝不会把触摸扣到抬手之后。
- (void)ownBailFired {
    _ownBail = nil;
    NSString *d = [NSString stringWithFormat:
                   @"0.28s 内未达阈值（本手势 moved 共 %d 帧）→ 放行（AevonNoStuckV309 防扣死）",
                   _ownMovedFrames];
    [self ownPass:"pass" bucket:AevonOwnPassBail detail:d];
}

- (void)ownBailRearm {
    [_ownBail invalidate];
    _ownBail = nil;
    /* V0.3.28（AevonSysAssertV328）：顺带做断言超时检查。
     * 这个方法是自建腿里唯一的周期性回调（0.28s 一拍、总上限 0.9s），
     * 把它当 ticker 比自己开一个定时器省 —— 少一个 NSTimer 就少一条泄漏路径。 */
    AevonGripAssertTick();
    CFTimeInterval left = 0.9 - (CACurrentMediaTime() - _ownStartStamp);
    if (left <= 0.02) { return; }
    NSTimeInterval span = left < 0.28 ? left : 0.28;
    _ownBail = [NSTimer scheduledTimerWithTimeInterval:span
                                                target:self
                                              selector:@selector(ownBailFired)
                                              userInfo:nil
                                               repeats:NO];
}

/* ---------------------------------------------------------------------------
 * V0.3.16（AevonOwnLiftV316）：召唤成功后**保持 Began 直到抬手**。
 *
 * 0.3.15 及以前，两个召唤点都在 `AevonGripOwnSummon(...)` 之后紧跟一句
 * `self.state = UIGestureRecognizerStateEnded;`。后果是致命的：
 * 识别器一进 Ended，UIKit 立刻 `-reset`，**这根手指此后再没有任何帧派给它** ——
 * 于是 `-touchesEnded:` 永远不会被调用，「手指什么时候离开屏幕」这个信息
 * 在结构上就丢了。
 *
 * Aevon(93) 实测 64 次呼盘把代价量出来了：
 *   · 48 次靠全局通道的 ended 收起（531~1356ms，随用户抬手时机变化，正常）；
 *   · 16 次靠看门狗收起，时长 **恒定 1003~1008ms** —— 那就是「手指早已离屏，
 *     圆盘还钉在屏上 1 秒」的全部来源。
 *
 * Stheno 的 `SCArcGestureRecognizer` 结构上就是活到抬手：ivar `__trackingActive`
 * 标记一次追踪会话、`__resetHandler` 在 `-reset` 里回调给 coordinator 的
 * `sc_finishTracking` → `sc_dismissAnimated:`。本版对齐它：识别器自己就是
 * 「抬手」的权威来源，不再需要任何静默推断。
 * ------------------------------------------------------------------------- */
- (void)ownSummonAtPoint:(CGPoint)p {
    _ownSummoned = YES;
    _ownSummonedAt = CACurrentMediaTime();
    /* V0.3.29（AevonDeskPanGuardV329）：桌面翻页 pan 的强制失败窗口从这一刻起算。
     * 桌面那条 `UIScrollViewPanGestureRecognizer` 在我们 `began` 之后十几毫秒才
     * `began`（Aevon(101)/(102) 两份日志同构），所以窗口要覆盖到召唤之后的一小段。 */
    gAevonOwnSummonAtGuard = CACurrentMediaTime();
    /* V0.3.28（AevonSysAssertV328）：跟踪开始 → 压住系统手势（Stheno 第 ④ 层）。
     *
     * 时机选在「确定要召盘」这一刻，不是落指那一刻：落指时只是扣住手指、还不确定
     * 用户要干什么，提前压系统会让一次普通的右缘点击也让系统手势失效。
     * 失败（私有接口缺失 / 抛异常）返回 NULL，功能照常，只少一层保护。 */
    AevonGripAssertAcquire("AevonArcMenuGesture");
    [_ownBail invalidate];
    _ownBail = nil;
    [_ownHold invalidate];
    _ownHold = nil;
    self.state = UIGestureRecognizerStateBegan;
    AevonGripOwnSummon((double)p.x, (double)p.y,
                       (double)_ownStart.x, (double)_ownStart.y);
    /* 这里**故意不再置 Ended**（见上方注释）：UIKit 会继续把 moved / ended 派进来。 */
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    /* V0.3.16（AevonOwnLiftV316）：召唤过的手指还压在屏上时，**后落下的手指不参与**
     * 自建腿判定。以前召唤即 Ended、UIKit 立刻 reset，所以不存在这个问题；现在识别器
     * 活到抬手，第二根手指的 began 会派进来把 _ownStart / _ownSummoned 覆盖掉，
     * 召唤那根手指抬手时就发不出终点信号（圆盘又回到僵 1 秒）。 */
    /* V0.3.28（AevonSummonTTLV328）：加 2.5s 上限。`_ownSummoned` 本应只由 -reset 清，
     * 但识别器被系统摘掉 / Ended 没派进来时 reset 不会来，标记就永久粘住，
     * 之后每一次落指都在这一行被吞掉 —— 用户看到的是「圆盘突然彻底没反应」，
     * 日志看到的是「有 began、无 hold」。超时后强制让位，成本只是极少见的误判一次。 */
    if (_ownSummoned && CACurrentMediaTime() - _ownSummonedAt < 2.5) { return; }
    if (_ownSummoned) { _ownSummoned = NO; }
    UITouch *t = touches.anyObject;
    CGPoint p = (t != nil) ? [t locationInView:nil] : CGPointZero;
    [self ownBeginAtPoint:p touch:t tid:(uintptr_t)(__bridge void *)t];
}

/* V0.3.32（AevonHeldBeginV332）：落指判据本体 —— **两个入口共用同一份**。
 *
 * 为什么必须有外部入口：Aevon(105) 定档「落指扣住」之后，began 那一帧不再投递，
 * UIKit 也就不会把 began 派进这个识别器 —— 判据却没有少，只是驱动它的人从 UIKit
 * 变成了 `AevonTouchHook.m`。判据本体一个字不动，只把「坐标打哪来」参数化。
 *
 * `tid` 由调用方给：UIKit 入口直接取 `UITouch` 指针；外部入口取吞层遍历
 * `[event allTouches]` 时算出来的指针。两边必须是同一批实例，0.3.29/0.3.30 已实证。 */
- (BOOL)ownBeginAtPoint:(CGPoint)p touch:(UITouch *)t tid:(uintptr_t)tid {
    /* V0.3.28（AevonSummonTTLV328）：同 `-touchesBegan:` 的 TTL 守卫，外部入口也要过 ——
     * 圆盘还开着的时候不许第二根手指把簿记顶掉。 */
    if (_ownSummoned && CACurrentMediaTime() - _ownSummonedAt < 2.5) { return NO; }
    if (_ownSummoned) { _ownSummoned = NO; }
    /* 落点判据在**落指那一刻**做 —— 这才是自建腿相对「借识别器」的本质优势：
     * 0.3.8 只能在达阈值之后用后置几何否决，那时 App 已经跟了 8pt 了。
     *
     * V0.3.28（AevonEdgeBandOnly328）：两段式改成**一条贴边带**，回到 Stheno 的单层模型。
     *   1 = 带内（离右缘 ≤ GripZoneW，默认 15pt）→ 扣住，位移到 8pt 就召唤，**不看方向**；
     *   0 = 带外 → 立刻放行，一个字节都不碰。
     * 依据 Aevon(101) 的 49 次 hold：落点 84% 集中在 12~15pt、0~6pt 一次都没有；
     * 5 次被 22° 锥判成斜滑放掉的样本，第 2 帧反而更斜（dx=-47 dy=28），
     * 说明方向判据在这个落点带上只会误杀。旧的两段式还带来「扣住又放行 → 翻页」。 */
    int level = AevonGripOwnHitLevel((double)p.x, (double)p.y);
    if (level == 0) {
        CGSize scr = [UIScreen mainScreen].bounds.size;
        NSString *d = [NSString stringWithFormat:
                       @"落点不在右缘呼出区 x=%.0f y=%.0f（屏 %.0fx%.0f）→ 放行"
                       "（侧滑返回/边缘滚动不受影响）", p.x, p.y, scr.width, scr.height];
        [self ownPass:"pass" bucket:AevonOwnPassBand detail:d];
        return NO;
    }
    /* V0.3.18（AevonSceneGateV318）：控制中心 / 通知中心 / 锁屏（含「解锁了但还没上滑
     * 进桌面」）里**不接管这根手指**。
     *
     * 为什么必须在落指这一刻判、并且主动 Failed：`ownSummonAtPoint:` 一旦执行就已经把
     * `_ownSummoned` 置 YES、识别器抬进 Began，那时再拒绝呼盘，这根手指会一直被扣到
     * 抬手 —— 在控制中心里右缘左滑会变成「划不动」，App 与系统都收不到帧。
     * 所以这道闸的语义不是「不呼盘」，而是「这根手指根本不归我们」：判到浮层就
     * `ownPass:` → Failed，UIKit 立刻把被 delay 的触摸补发给系统，用户该滑什么滑什么。
     *
     * 判在 `level == 0` 之后：落点本来就在带外的手指（绝大多数）不必付这次窗口表扫描
     * 和一次 prefs 读取。 */
    if (AevonGripSystemOverlayBlocked() != 0) {
        [self ownPass:"pass" bucket:AevonOwnPassOverlay
               detail:@"系统浮层在屏（控制中心/通知中心/锁屏）→ 不接管，触摸原样还给系统"];
        return NO;
    }
    _ownStart = p;
    _ownHit = p;
    _ownTouch = t;
    /* V0.3.29（AevonOwnSwallowV329）：把这根手指的身份递给 Swift。
     * 只在 `level == 1`（带内）之后写入，带外的落指在上一段已经 ownPass 走了。 */
    gAevonOwnTouchID = (uintptr_t)(__bridge void *)t;
    /* V0.3.32（AevonHeldBeginV332）：外部入口没有 `UITouch`（began 被吞层扣住、没投递），
     * 身份只能由调用方递进来。两个来源都是 `[event allTouches]` 里的同一批实例。 */
    if (tid != 0) { gAevonOwnTouchID = tid; }
    /* V0.3.30（AevonEarlyBindV330）：身份一写下来就**立刻**请求预绑，不等召唤。
     *
     * 这是 Aevon(103) 定位出来的唯一漏点，而且它是**结构性**的，不是时延问题：
     *   10:59:56.011  SB sendEvent began      ← 这一帧必然投给 App（圆盘还没开）
     *   10:59:56.016  自建腿 hold
     *   10:59:56.053  首帧 moved 位移 23pt     ← 这一帧也投给了 App
     *   10:59:56.054  summon
     *   10:59:56.072  已绑全局吞层             ← 吞层从这里才生效
     * 吞层判据挂在 SB `-sendEvent:` 里，而自建识别器是在**同一次** `sendEvent:` 的
     * 内部才拿到这根手指并做出判定 —— 判定永远晚于本函数顶部的吞层询问。所以
     * 「began + 首帧 moved」必然先到 App，之后所有帧才被吞。
     *
     * 36 次召唤的首帧位移中位 18pt、最大 49pt（Aevon(103)），App 拿到的是
     * 「began + 一个 18~49pt 的高速横向帧 + 再无后续」：ScrollView 会拿这一帧算惯性，
     * 抖音会拿它判横滑。0.3.28 里 App 拿到的是完整跟随手势（跟着手指走），
     * 这一版变成「被甩一下」—— 这就是「更严重」的机构原因。
     *
     * 预绑在 began 就设，下一帧 moved 的 `sendEvent:` 询问就能命中，漏的只剩
     * began 这一帧（零位移）。点击不受影响：点击没有 moved 帧，没东西被吞，
     * `-ownPass:` 会立刻取消预绑，ended 照常送达（延迟与旧版同为 0.28s）。
     *
     * 位置不能提前：带外落指与系统浮层落指在上面两段已经 ownPass 走了。 */
    gAevonOwnSwallowFrames = 0;
    AevonGripOwnPreBind((double)p.x, (double)p.y);
    _ownSummoned = NO;
    _ownMovedFrames = 0;
    _ownFeedFrames = 0;
    _ownStartStamp = CACurrentMediaTime();
    /* V0.3.28（AevonYieldGuardV328）：记下「本手势真的被自建腿接管了」的时刻。
     * 借腿（systemLegSummon）用它判断要不要拦系统腿 —— 只有这个窗口内才拦。 */
    AevonGripOwnStampHold();
    [_ownBail invalidate];
    _ownBail = [NSTimer scheduledTimerWithTimeInterval:0.28
                                                target:self
                                              selector:@selector(ownBailFired)
                                              userInfo:nil
                                               repeats:NO];
    CGSize scr2 = [UIScreen mainScreen].bounds.size;
    /* V0.3.15（AevonOwnLogAsciiV315）：`%s` 只传纯 ASCII —— 原来这里塞的是中文 C 字符串，
     * `stringWithFormat:` 的 `%s` 按非 UTF-8 解释，写进日志就成了
     * 「ËæπÁºòÂÄôÈÄâÔºåËµ∞‰∏•Ê†ºÂà§ÊçÆ」这种二次编码乱码，level 1 / level 2 分不出来，
     * 整篇日志的判据价值掉一半（Aevon(92) 就是这样）。中文一律走 @"…" + %@。 */
    NSString *hd = [NSString stringWithFormat:
                    @"落点 x=%.0f y=%.0f（离右缘 %.0fpt）→ 扣住触摸，"
                    "位移达 8pt 即召唤、不看方向（App 此时收不到 began）",
                    p.x, p.y, scr2.width - p.x];
    AevonGripOwnLog("hold", hd.UTF8String);
    return YES;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    /* V0.3.17（AevonOwnFeedV317）：召唤成功之后，这个识别器仍然持有这根手指 ——
     * 它收到的每一帧 moved 直接喂给圆盘，圆盘不再依赖 SB 全局通道。
     *
     * 顺序不能反：先判 `_ownSummoned`（召唤后仍要喂），再判状态（Possible 才做判据）。
     * 只认 `_ownTouch` —— 别的手指即便落到识别器上报的集合里，也不许拿它的坐标去
     * 挪圆盘的指针（那会导致「手指 A 抬手、判定用的是手指 B 的位置」）。
     * 热路径：只读一个坐标、过一次 C 函数调用，不 hitTest、不读 prefs。 */
    if (_ownSummoned) {
        if (_ownTouch != nil && t != _ownTouch) { return; }
        if (t != nil) {
            CGPoint q = [t locationInView:nil];
            _ownFeedFrames++;
            AevonGripOwnMove((double)q.x, (double)q.y);
        }
        return;
    }
    if (self.state != UIGestureRecognizerStatePossible) { return; }
    [self ownJudgeMove:((t != nil) ? [t locationInView:nil] : CGPointZero)];
}

/* V0.3.31（AevonSwallowFeedV331）：位移判据本体 —— 两个入口共用同一份。
 *
 * 为什么要拆出来：0.3.30 把「开始吞」提前到落指之后，吞层在 SB `-sendEvent:` 顶部
 * 丢掉整条 `UIEvent`，而**自建识别器自己也在那条事件链里** —— 它一帧 moved 都收不到，
 * 于是永远判不出 8pt。Aevon(104) 的证据是闭合的：
 *   · 31 次自建腿 hold，自建腿召唤 **0 次**（0.3.29 是 36 次）；
 *   · 前 6 次 hold 的结局全部是「0.28s 内未达阈值（本手势 moved 共 0 帧）→ 放行」；
 *   · `本轮识别器喂 N 帧` 一条都没打出来（识别器被 ownPass 掉，连 ended 都收不到）；
 *   · hold → 圆盘出现时差 31 次全部 ≥ 0.285s，下限恰好是 ownPass 的 0.28s 墙。
 * 圆盘最后是靠系统 `_UIPendingEdgeSwipeGestureRecognizer` 呼出来的（21/21），
 * 走「收养」分支（只喂不吞），所以 App 拿到剩余整段滑动 = 用户说的「带动操作」。
 *
 * 结论（本轮更正的一条长期结论）：**吞层的粒度是整条 UIEvent，它饿死的不只是 App，
 * 还有我们自己那只识别器。** 0.3.29 之所以没饿死，是因为它的绑定发生在召唤之后，
 * 8pt 早就判完了 —— 不是「吞层不饿死识别器」。 */
- (void)ownJudgeMove:(CGPoint)p {
    CGFloat dx = p.x - _ownStart.x;
    CGFloat dy = p.y - _ownStart.y;
    /* V0.3.11（AevonOwnLegTypeV311）：每个手势只打第一条 moved —— 这是「注册到底生效没有」
     * 唯一可靠的判据。0.3.10 的 38 次 hold 全部 0.28s 超时放行、一条 moved 都没有，
     * 说明当时那只识别器压根不在系统手势会话里（只是挂在宿主视图上旁听）。 */
    _ownMovedFrames++;
    if (_ownMovedFrames == 1) {
        NSString *line = [NSString stringWithFormat:
                          @"首帧 moved dx=%.0f dy=%.0f（注册生效 → 系统在派移动帧）", dx, dy];
        AevonGripOwnLog("move", line.UTF8String);
    }
    /* V0.3.13（AevonOwnGateV313）：**先判呼盘、再判纵向**，顺序不能反。
     *
     * ⛔ 真实呼盘是「向左抖一下」，dy 常有 10~15pt 的自然漂移；若先判纵向，
     * dx=-10/dy=-13 这种就会被当成滚动放掉 —— 那是把功能判死。
     *
     * V0.3.14（AevonEdgePadV314）：分两条判据。
     *   · 贴边落点（level 1）：上面的宽松判据原样保留 —— 落点本来就压在右缘，
     *     左滑 8pt 就是明确意图，不必再额外刁难；
     *   · 边缘候选（level 2）：落点离右缘 5~40pt，可能是抖音进度条、也可能是想呼盘
     *     但落偏的手指。所以只认近似纯水平的左滑，并且一旦看清「不是左滑」
     *     （右移 / 纵向 ≥12）立刻还回去，不等 0.28s 闸。
     *
     * V0.3.15（AevonStrictAngleV315）：严格判据从「绝对 |dy| ≤ 6」改成**角度式**。
     * 依据 Aevon(92) 日志的 6 次 strict 放行：
     *   · dx=-99 dy=13（离右缘 9pt）—— 角度只有 7.5°，明明是明确的大左滑，却被
     *     「|dy|=13 > 6」判成「不纯水平」放掉了 —— 用户会觉得「明明划了很长却呼不出来」；
     *   · dx=-34 dy=13（离右缘 37pt）—— 角度 21°，这个才是真该放行的进度条拖动。
     * 一个绝对阈值同时要判这两件事是判不了的：短滑的 ±6pt 是抖动，长滑的 13pt 才是方向。
     * 现在两条取或：短滑看绝对量（|dy| ≤ 6，样本太短角度不可靠），长滑看锥形
     * （|dy| ≤ |dx| × 0.25 ≈ 14°）。上面那两例分别是「认」和「放」，恰好都对了。 */
    /* V0.3.28（AevonEdgeBandOnly328）：判据只剩一条 —— **位移量**，方向完全不参与。
     *
     * 这是把 Stheno 的模型搬过来：它的 `sc_beginTrackingAtPoint:` 只判起点在不在
     * 触发区（`sc_triggerMatchAtPoint:`），方向交给后续 `sc_handleArcPan:`，
     * 从来没有「首帧角度不够水平就一票否决」这一层。
     *
     * 我们过去五版都在加严方向判据（|dy|≤6 → 14° 锥 → 22° 锥 → 桌面取消锥角），
     * 每版都只是把切点挪一点。Aevon(101) 的 49 次 hold 给出定论：
     *   84% 的落点集中在离右缘 12~15pt，其中 5 次被 22° 锥放掉，而续判日志显示
     *   它们第 2 帧**更斜**（dx 从 -30 变 -47、dy 从 15 变 28）—— 这些不是「判早了
     *   的呼盘」，是用户本来就斜着滑。方向判据在这个落点带上只能误杀，救不了任何人。
     *
     * 为什么可以不看方向：带内只有离右缘 ≤15pt 的手指，这一圈本来就是系统
     * `UIScreenEdgePanGestureRecognizer` 自己的边缘手势区（Aevon(101) 实测它认领了
     * 离右缘 17pt 的落点、edges=15），App 的滚动内容在这里本来就抢不到手势。
     * 带外的手指在 `touchesBegan` 就已经 `ownPass:` 了，压根进不到这个函数。
     *
     * 8pt 是 0.3.4 以来一直在用的召唤阈值，这里不改数值、只去掉「必须向左」这个前提。
     * 右滑（出屏方向）与纵向滑现在都会召唤 —— 这是本版的已知代价，已写进交付说明。 */
    double dist = hypot((double)dx, (double)dy);
    if (dist >= 8.0) {
        if (_ownMovedFrames <= 2) {
            NSString *d = [NSString stringWithFormat:
                           @"带内位移达阈值 dx=%.0f dy=%.0f 位移=%.0fpt（落点离右缘 %.0fpt）"
                           @"→ 召唤（AevonEdgeBandOnlyV328 不看方向）",
                           dx, dy, dist,
                           [UIScreen mainScreen].bounds.size.width - _ownHit.x];
            AevonGripOwnLog("summon", d.UTF8String);
        }
        [self ownSummonAtPoint:p];
        return;
    }
    /* 有移动但还没到阈值：把闸往后滚（总上限 0.9s），避免慢速滑动被误放行。 */
    [self ownBailRearm];
}

/* V0.3.31（AevonSwallowFeedV331）：吞层回喂 —— 这一帧被 `-sendEvent:` 丢掉了，但判定
 * 不能少这一帧，否则就是 0.3.30 那个「召唤归零 + 圆盘两秒后才出」。
 *
 * 只判位移、**不喂盘**：召唤成功之后的帧由吞层经 `AevonGlobalTouchPhase` 喂给圆盘
 * （0.3.29 已验证的 `source:"global"` 通道），这里再喂一次会让跟手抖一帧。
 * `_ownSummoned` 早退是必须的 —— 召唤后吞层仍在回喂，不挡会重复走判据、重复打 summon 日志。 */
- (void)ownExternalMove:(CGPoint)p {
    if (_ownSummoned) { return; }
    if (self.state != UIGestureRecognizerStatePossible) { return; }
    [self ownJudgeMove:p];
}

/* V0.3.32（AevonHeldBeginV332）：吞层扣住 began 之后的三件收尾事。
 *
 * 这一段的前提很干净：这根手指**从头到尾没进过 UIKit 的触摸序列**（began 被扣住、
 * moved 被吞、ended 也被吞），所以 `-touchesEnded:` / `-touchesCancelled:` / `-reset`
 * 一条都不会来。判据照旧、喂盘照旧（走全局通道），缺的只是「谁来收尾」。 */

- (int)ownSummonedInt {
    return _ownSummoned ? 1 : 0;
}

/// 回放前的「退出本轮」：把自建腿从这根手指上摘干净，之后它的帧一路正常投递。
///
/// ⛔ 这里必须同时撤销预绑（Swift 侧 `preBindTid/globalTouchID/ownsTouch` 一起清），
/// 否则回放之后吞层还在吞 moved —— 那正是 0.3.3 铁律说的「began 放行、中途改吞」，
/// 后果是 App 收不到终止帧、`UIScrollView` 触摸延迟队列永久挂起、全 App 卡屏。
- (void)ownDisarm {
    [_ownBail invalidate];
    _ownBail = nil;
    [_ownHold invalidate];
    _ownHold = nil;
    if (self.state == UIGestureRecognizerStatePossible) {
        self.state = UIGestureRecognizerStateFailed;
    }
    AevonGripPreBindCancel(0);
    gAevonOwnTouchID = 0;
    _ownMovedFrames = 0;
    _ownSummoned = NO;
    _ownSummonedAt = 0;
    _ownTouch = nil;
}

/// 抬手帧被吞掉时的收尾：把 lift 信号照常发出去，然后**自己清场**。
///
/// 清场不能省：`_ownSummoned` 本应由 `-reset` 清，而这根手指从没进过 UIKit 的触摸序列，
/// `-reset` 永远不会来 —— 不清就是「呼完一次盘，两秒半内怎么划都没反应」
///（2.5s TTL 守卫会把这些落指全部挡掉）。
- (void)ownExternalEndAtPoint:(CGPoint)p {
    [_ownBail invalidate];
    _ownBail = nil;
    [_ownHold invalidate];
    _ownHold = nil;
    if (_ownSummoned) {
        NSString *feed = [NSString stringWithFormat:
                          @"本轮识别器喂 %d 帧｜吞层实丢 %lu 帧（实丢 >0 = 吞层与回喂在跑，"
                          @"前半段 0 是正常的：moved 全被吞了）",
                          _ownFeedFrames, (unsigned long)gAevonOwnSwallowFrames];
        AevonGripOwnLog("lift", feed.UTF8String);
        self.state = UIGestureRecognizerStateEnded;
        AevonGripOwnLift((double)p.x, (double)p.y, 0);
    }
    _ownSummoned = NO;
    _ownSummonedAt = 0;
    _ownTouch = nil;
    gAevonOwnTouchID = 0;
    _ownMovedFrames = 0;
    _ownFeedFrames = 0;
    _ownStartStamp = 0;
    _ownStart = CGPointZero;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    /* V0.3.16（AevonOwnLiftV316）：召唤过的手指，抬手就是圆盘的**终点信号**。
     * 以前这条路不存在（召唤即 Ended），圆盘只能靠看门狗，固定多停 1 秒。
     * 只认召唤那根手指（_ownTouch）；别的手指抬起一律忽略 —— 否则会拿别人的落点
     * 去判「选中哪个图标」，也会把别人的抬手当成圆盘的终点。
     * 顺序：先判「是不是我这根」再清定时器，别的手指抬起不许把我们自己的闸清掉。 */
    if (_ownSummoned) {
        if (_ownTouch != nil && ![touches containsObject:_ownTouch]) { return; }
        [_ownBail invalidate];
        _ownBail = nil;
        [_ownHold invalidate];
        _ownHold = nil;
        UITouch *t0 = touches.anyObject;
        CGPoint p0 = (t0 != nil) ? [t0 locationInView:nil] : _ownStart;
        /* V0.3.17（AevonOwnFeedV317）：把本轮喂了几帧写进日志 —— 这是「喂料通道到底
         * 有没有在跑」的唯一直接判据。
         * V0.3.31（AevonSwallowFeedV331）：本版判据换成后半段「吞层实丢」。
         *   吞层全吞 moved 之后识别器自己一帧都收不到，前半段恒为 0 是**正常**的；
         *   权威判据是 `吞层实丢 M 帧`：M > 0 = 吞层 + 回喂这条路真的在跑，
         *   M = 0 = 一帧都没拦住（预绑没命中或抬手被提前放行），下次直接看这个数。 */
        NSString *feed = [NSString stringWithFormat:
                          @"本轮识别器喂 %d 帧｜吞层实丢 %lu 帧（实丢 >0 = 吞层与回喂在跑，"
                          @"前半段 0 是正常的：moved 全被吞了）",
                          _ownFeedFrames, (unsigned long)gAevonOwnSwallowFrames];
        AevonGripOwnLog("lift", feed.UTF8String);
        self.state = UIGestureRecognizerStateEnded;
        AevonGripOwnLift((double)p0.x, (double)p0.y, 0);
        return;
    }
    [_ownBail invalidate];
    _ownBail = nil;
    [_ownHold invalidate];
    _ownHold = nil;
    if (self.state == UIGestureRecognizerStatePossible) {
        self.state = UIGestureRecognizerStateFailed;
        UITouch *t = touches.anyObject;
        CGPoint p = (t != nil) ? [t locationInView:nil] : _ownStart;
        NSString *d = [NSString stringWithFormat:
                       @"点击（没左滑）→ 放行，App 收得到这一下（落点 x=%.0f y=%.0f）", p.x, p.y];
        AevonOwnPassCount("tap", AevonOwnPassTap, d);
    } else if (self.state == UIGestureRecognizerStateBegan
               || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    /* V0.3.16（AevonOwnLiftV316）：被系统摘链（其它识别器抢走 / App 切后台）对
     * **这根手指**来说等同于离屏 —— 它不会再有任何帧了。圆盘那条通道（0.2.18）
     * 严守「取消 ≠ 抬手」，因为那说的是「通道不投了、手指还压着」；而这里是
     * 识别器级的事实：UIKit 已经不再给这根 touch 派任何帧，留着只会再僵 1 秒。
     * 第三个参数传 1，日志里能与正常抬手区分开。
     * 同 touchesEnded：先判「是不是我这根」再清定时器（认领路还有 3s 兜底闸要用）。 */
    if (_ownSummoned) {
        if (_ownTouch != nil && ![touches containsObject:_ownTouch]) { return; }
        [_ownBail invalidate];
        _ownBail = nil;
        [_ownHold invalidate];
        _ownHold = nil;
        UITouch *t0 = touches.anyObject;
        CGPoint p0 = (t0 != nil) ? [t0 locationInView:nil] : _ownStart;
        self.state = UIGestureRecognizerStateCancelled;
        AevonGripOwnLift((double)p0.x, (double)p0.y, 1);
        return;
    }
    [_ownBail invalidate];
    _ownBail = nil;
    [_ownHold invalidate];
    _ownHold = nil;
    self.state = UIGestureRecognizerStateCancelled;
}

@end

#pragma mark - V0.3.12：连带认领

/* Aevon(90) 唯一一句实测「只有第一次呼盘时 App 不跟手，后面都跟」，把机制讲通了：
 * 自建腿在 0.3.11 里一次都没成功识别过（0 自建呼盘、0 moved），而 UIKit 对
 * 「永远 failed 的识别器」会撤掉触摸延迟资格 —— 第一根手指被扣住，之后系统就直接
 * 把 began 派给 App 了。所以这里补的不是参数，是「让自建腿真的赢一次」。
 *
 * 调用点：Swift 的系统腿在**达阈值且守卫全过、真的要呼盘**的那一刻调进来。
 * 安全性：只有「自建腿正 hold 着这根手指」（state == Possible 且落点在带内）才会认领成功；
 * 带外落指早就 failed 了，这里返回 NO，一个字节都不动。 */
void AevonGripOwnLegClaim(void) {
    if (!gAevonOwnLegEnabled || gAevonOwnGesture == nil) { return; }
    AevonOwnLegGesture *g = (AevonOwnLegGesture *)gAevonOwnGesture;
    if (![g ownClaimNow]) { return; }
    gAevonOwnClaims++;
    NSString *line = [NSString stringWithFormat:
                      @"已认领这根手指（累计 %d 次）：自建腿进 Began，App 侧触摸被 cancel；"
                      @"它终于「识别成功」一次 → UIKit 下次仍会给它触摸延迟资格", gAevonOwnClaims];
    AevonGripOwnLog("claim", line.UTF8String);
}

#pragma mark - V0.3.12：ivar 形状取证（只读已知对象，不做全类表枚举）

/* 0.3.11 已经证明：KVC 那五个 key 全不中，取证钩子也永远等不到（系统在注入前就注册完了）。
 * 剩下唯一没试过的取证面就是**对象自己的 ivar** —— 类型值要么挂在管理器的容器里
 * （「类型号 → 识别器」的映射），要么直接挂在那只边沿识别器身上。
 * 这里只对**别人递给我的那个对象**做 class_copyIvarList（认识类名，不扫类表），
 * 读取一律走 object_getIvar + 类型编码只认 '@'，与 AevonSceneHook 的既有做法一致。 */
static void AevonOwnDumpIvars(id obj, NSString *tag) {
    if (obj == nil || tag.length == 0) { return; }
    Class root = object_getClass(obj);
    NSMutableString *shape = [NSMutableString string];
    int total = 0;
    for (Class c = root; c != Nil && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        if (ivars == NULL) { continue; }
        for (unsigned int i = 0; i < count && total < 44; i++) {
            const char *n = ivar_getName(ivars[i]);
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            if (n == NULL) { continue; }
            total++;
            [shape appendFormat:@" %s:%s", n, enc != NULL ? enc : "?"];
        }
        free(ivars);
        if (total >= 44) { break; }
    }
    NSString *head = [NSString stringWithFormat:@"%@（%s）ivar 形状 %d 个：%@",
                      tag, class_getName(root), total, shape];
    AevonGripOwnLog("ivars", head.UTF8String);

    /* 第二段：只读名字里带 gesture/type/recogn 的对象型 ivar，看容器里有没有「类型号 → 识别器」。
     * 限量 6 个字段、容器最多 8 条 —— SpringBoard 的主线程不能被日志拖住。 */
    int probed = 0;
    for (Class c = root; c != Nil && c != [NSObject class] && probed < 6;
         c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(c, &count);
        if (ivars == NULL) { continue; }
        for (unsigned int i = 0; i < count && probed < 6; i++) {
            const char *n = ivar_getName(ivars[i]);
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            if (n == NULL || enc == NULL || enc[0] != '@') { continue; }
            NSString *name = [NSString stringWithUTF8String:n];
            NSString *low = name.lowercaseString;
            if ([low rangeOfString:@"gesture"].location == NSNotFound
                && [low rangeOfString:@"type"].location == NSNotFound
                && [low rangeOfString:@"recogn"].location == NSNotFound) { continue; }
            @try {
                id v = object_getIvar(obj, ivars[i]);
                if (v == nil) { continue; }
                probed++;
                NSString *desc = [NSString stringWithFormat:@"%@ → <%s>",
                                  name, class_getName(object_getClass(v))];
                if ([v isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *d = (NSDictionary *)v;
                    NSMutableString *kv = [NSMutableString string];
                    int k = 0;
                    for (id key in d) {
                        if (k++ >= 8) { break; }
                        id val = d[key];
                        [kv appendFormat:@" %@→<%s>", key,
                         val != nil ? class_getName(object_getClass(val)) : "nil"];
                    }
                    desc = [desc stringByAppendingFormat:@" count=%lu%@",
                            (unsigned long)d.count, kv];
                } else if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]]) {
                    NSArray *arr = [v isKindOfClass:[NSSet class]]
                                 ? [(NSSet *)v allObjects] : (NSArray *)v;
                    NSMutableString *kv = [NSMutableString string];
                    int k = 0;
                    for (id e in arr) {
                        if (k++ >= 8) { break; }
                        [kv appendFormat:@" <%s>",
                         e != nil ? class_getName(object_getClass(e)) : "nil"];
                    }
                    desc = [desc stringByAppendingFormat:@" count=%lu%@",
                            (unsigned long)arr.count, kv];
                } else if ([v isKindOfClass:[NSNumber class]]) {
                    desc = [desc stringByAppendingFormat:@" value=%lld",
                            [(NSNumber *)v longLongValue]];
                }
                AevonGripOwnLog("ivars", desc.UTF8String);
            } @catch (NSException *exception) {
            }
        }
        free(ivars);
    }
}

#pragma mark - 系统手势管理器取证（白名单，不枚举）

/// 只对**已知方法名**做探测 —— 0.2.72 的 SIGTRAP 就是全类表枚举炸的，
/// 这里一次全类表枚举都没有（连那个 API 名都不写：注释也会命中 CI 的防回退断言）。
static void AevonOwnProbeSels(Class cls, NSString *tag) {
    if (cls == Nil) { return; }
    /* V0.3.10：装配改成「每 2s 重试一次」，取证只打一轮 —— 不然 15 次重试会刷 15 行。
     * V0.3.12：改成按 tag 去重（见 gAevonOwnCensusSeen 的说明）。 */
    if (tag.length == 0) { return; }
    if (gAevonOwnCensusSeen == nil) { gAevonOwnCensusSeen = [NSMutableSet set]; }
    if ([gAevonOwnCensusSeen containsObject:tag]) { return; }
    [gAevonOwnCensusSeen addObject:tag];
    gAevonOwnCensusLogged = YES;
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
    /* ⓪ V0.3.12（AevonOwnUIKitMgrV312）：UIKitCore 的 `_UISystemGestureManager`（带下划线）。
     *
     * 这是 0.3.10 的正误订正：`addGestureRecognizer:toDisplayWithIdentity:` 的宿主是
     * UIKit 私有类，不是 SBSystemGestureManager / SBMainDisplaySystemGestureManager ——
     * 0.3.10 查错了类，于是「17.3.1 上没有这个方法」这个结论本身是错的，0.3.11 还据此
     * 把它从候选表里删了。这条路的价值：**不需要手势类型值**，第二参是公开 API
     * 就能拿到的 FBSDisplayIdentity。 */
    if (!gAevonOwnUIKitMgrTried) {
        gAevonOwnUIKitMgrTried = YES;
        Class uic = NSClassFromString(@"_UISystemGestureManager");
        if (uic != Nil) {
            AevonOwnProbeSels(uic, @"_UISystemGestureManager");
            for (NSString *s in @[@"sharedInstance", @"sharedManager"]) {
                SEL sel = NSSelectorFromString(s);
                if (![uic respondsToSelector:sel]) { continue; }
                id inst = ((id (*)(id, SEL))objc_msgSend)(uic, sel);
                if (inst != nil) { found = inst; break; }
            }
        } else {
            AevonGripOwnLog("census", "_UISystemGestureManager 类不存在（UIKitCore 已加载但没这个类）");
        }
    }
    /* ① SB 侧单例：17.3.1 上类存在，但此前普查「无候选方法」——
     *    所以这里先取证再取实例，两个白名单单例名都试。 */
    Class sbm = NSClassFromString(@"SBSystemGestureManager");
    if (sbm != Nil) {
        AevonOwnProbeSels(sbm, @"SBSystemGestureManager");
        for (NSString *s in @[@"sharedInstance", @"sharedSystemGestureManager"]) {
            SEL sel = NSSelectorFromString(s);
            if ([sbm respondsToSelector:sel]) {
                id inst = ((id (*)(id, SEL))objc_msgSend)(sbm, sel);
                if (inst != nil) { found = found != nil ? found : inst; break; }
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

/// V0.3.11：`AevonOwnDisplayIdentity` 随 0.3.10 的 `toDisplayWithIdentity` 一起退役 ——
/// 真正要用的第二个参数是「手势类型值」，不是 display identity。留着它只会多一个
/// 无调用者的 static 函数（编译器每条都报 unused）。

/* V0.3.11（AevonOwnLegTypeV311）：注册 API 是 **census 实测的真名**
 * `addGestureRecognizer:withType:`（`v32@0:8@16Q24`，两个参数：识别器 + 类型值），
 * SBSystemGestureManager 与 SBMainDisplaySystemGestureManager 上都有。
 *
 * 0.3.10 之所以注册不上：候选里放的是从 ScreenCore strings 推断出来的
 * `addGestureRecognizer:toDisplayWithIdentity:` —— 那个名字在 17.3.1 上**根本不存在**，
 * 而唯一存在的 `addGestureRecognizer:withType:` 恰好不在候选表里（0.3.9 有、0.3.10 丢了）。
 *
 * 类型值不猜：由 AevonOwnProbeGestureType / AevonOwnInstallTypeHook 从系统自己那只
 * 边沿识别器上读出来（见 gAevonOwnGestureType 的说明）。
 */
/// 类型值偏好：右缘用的 `_UIPendingEdgeSwipe` 优先，其次任何 EdgeSwipe，再次任何 Edge 类。
static long long AevonOwnBestGestureType(void) {
    if (gAevonOwnGestureType >= 0) { return gAevonOwnGestureType; }
    if (gAevonOwnTypeByClass.count == 0) { return -1; }
    NSArray<NSString *> *prefer = @[@"_UIPendingEdgeSwipeGestureRecognizer",
                                    @"EdgeSwipe", @"ScreenEdgePan", @"Edge"];
    for (NSString *key in prefer) {
        for (NSString *cls in gAevonOwnTypeByClass) {
            BOOL hit = [key hasPrefix:@"_"] ? [cls isEqualToString:key] : ([cls rangeOfString:key].location != NSNotFound);
            if (!hit) { continue; }
            long long v = gAevonOwnTypeByClass[cls].longLongValue;
            if (v >= 0) {
                gAevonOwnGestureType = v;
                NSString *line = [NSString stringWithFormat:@"选定类型值 %lld（来源 %@）", v, cls];
                AevonGripOwnLog("type", line.UTF8String);
                return v;
            }
        }
    }
    return -1;
}

/* 前置声明：ProbeGestureType 在 KVC 全不命中时要装取证钩子，而钩子定义在它下面。 */
static void AevonOwnInstallTypeHook(void);

/// 类型值一到手就立刻重试一次装配 —— kick 的 15 次预算（约 30s）可能已经用完，
/// 那种情况下「后续才拿到类型值」不能让整条腿永久放弃。这里把预算清零再来一轮。
static void AevonOwnOnTypeAcquired(void) {
    if (!gAevonOwnLegEnabled || gAevonOwnRegistered) { return; }
    gAevonOwnArmTries = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        AevonGripOwnLegKick();
    });
}

/// 从一只**系统自己的**边沿识别器上把类型值读出来（每类只读一次，读不到就装取证钩子）。
static void AevonOwnProbeGestureType(id recog, const char *cn) {
    if (recog == nil || cn == NULL) { return; }
    NSString *cls = [NSString stringWithUTF8String:cn];
    if (cls.length == 0) { return; }
    if (gAevonOwnTypeByClass == nil) { gAevonOwnTypeByClass = [NSMutableDictionary dictionary]; }
    if (gAevonOwnTypeByClass[cls] != nil) { return; }
    /* 只对边沿族读 —— 底部上滑/侧滑返回的类型值不是我们要的，别污染 */
    if (!AevonGripIsEdgeClass(cn)) { return; }
    for (NSString *k in @[@"gestureType", @"_gestureType", @"systemGestureType",
                         @"_systemGestureType", @"type"]) {
        @try {
            id v = [recog valueForKey:k];
            if (v == nil) { continue; }
            if (![v isKindOfClass:[NSNumber class]]) { continue; }
            long long n = [(NSNumber *)v longLongValue];
            gAevonOwnTypeByClass[cls] = @(n);
            NSString *line = [NSString stringWithFormat:@"%@ 的 %@ = %lld（KVC 实测）", cls, k, n];
            AevonGripOwnLog("type", line.UTF8String);
            AevonOwnOnTypeAcquired();
            return;
        } @catch (NSException *exception) {
        }
    }
    /* 五个 key 全不命中 → 装一次性取证钩子，抄系统自己传给 addGestureRecognizer:withType: 的值 */
    AevonOwnInstallTypeHook();
}

/// 取证钩子：只转发 + 记录，不改任何行为（签名 census 实测 v32@0:8@16Q24）。
static void AevonOwnAddWithType(id self, SEL _cmd, id g, unsigned long long type) {
    if (gAevonOrigAddWithType != NULL) {
        ((void (*)(id, SEL, id, unsigned long long))gAevonOrigAddWithType)(self, _cmd, g, type);
    }
    @try {
        const char *cn = g != nil ? class_getName(object_getClass(g)) : "nil";
        if (cn != NULL && AevonGripIsEdgeClass(cn)) {
            NSString *cls = [NSString stringWithUTF8String:cn];
            if (gAevonOwnTypeByClass == nil) { gAevonOwnTypeByClass = [NSMutableDictionary dictionary]; }
            if (gAevonOwnTypeByClass[cls] == nil) {
                gAevonOwnTypeByClass[cls] = @((long long)type);
                NSString *line = [NSString stringWithFormat:
                                  @"%@ 由系统以类型值 %llu 加入（钩子实测）", cls, type];
                AevonGripOwnLog("type", line.UTF8String);
                AevonOwnOnTypeAcquired();
            }
        }
    } @catch (NSException *exception) {
    }
}

static void AevonOwnInstallTypeHook(void) {
    if (gAevonOwnTypeHooked) { return; }
    gAevonOwnTypeHooked = YES;
    /* 不枚举类表（0.2.72 SIGTRAP 铁律）：只对两个已知类名取方法，签名必须严格匹配
     * 「返回 void + 2 个参数」，任何一项不符一律不装。 */
    SEL sel = NSSelectorFromString(@"addGestureRecognizer:withType:");
    for (NSString *name in @[@"SBSystemGestureManager", @"SBMainDisplaySystemGestureManager"]) {
        Class c = NSClassFromString(name);
        if (c == Nil) { continue; }
        Method m = class_getInstanceMethod(c, sel);
        if (m == NULL) { continue; }
        const char *enc = method_getTypeEncoding(m);
        if (enc == NULL || enc[0] != 'v' || AevonGripEncArgCount(enc) != 2) { continue; }
        IMP old = method_setImplementation(m, (IMP)AevonOwnAddWithType);
        if (old == NULL || old == (IMP)AevonOwnAddWithType) { continue; }
        gAevonOrigAddWithType = old;
        AevonGripOwnLog("typehook", "已装类型值取证钩子（只转发 + 记录，不改行为）");
        return;   // 两个类共用同一份 Method（子类继承），装一次就够
    }
}

/// 注册：签名必须「返回 void + 恰好 2 个参数」，类型值必须已实测到手，否则不调。
static BOOL AevonOwnTryRegister(id mgr, UIGestureRecognizer *g) {
    if (mgr == nil || g == nil) { return NO; }
    /* ⓪ V0.3.12（AevonOwnUIKitMgrV312）：UIKit 私有管理器的真名
     * `addGestureRecognizer:toDisplayWithIdentity:`（census 实测 v32@0:8@16@24）。
     * 它不需要手势类型值 —— 第二参是 FBSDisplayIdentity，公开 API 就能拿。
     * 0.3.10 之所以失败，是因为这个选择子被拿去问 SB 的两个类（宿主不对）。 */
    SEL selDisp = NSSelectorFromString(@"addGestureRecognizer:toDisplayWithIdentity:");
    if ([mgr respondsToSelector:selDisp]) {
        Method dm = class_getInstanceMethod([mgr class], selDisp);
        const char *denc = dm != NULL ? method_getTypeEncoding(dm) : NULL;
        if (denc != NULL && denc[0] == 'v' && AevonGripEncArgCount(denc) == 2) {
            id identity = nil;
            @try {
                identity = [[UIScreen mainScreen] valueForKeyPath:@"displayConfiguration.identity"];
            } @catch (NSException *exception) {
            }
            if (identity != nil) {
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(mgr, selDisp, g, identity);
                    NSString *line = [NSString stringWithFormat:
                                      @"已用 addGestureRecognizer:toDisplayWithIdentity: 注册进 %s"
                                      @"（不需要类型值；display identity 取自 UIScreen）",
                                      class_getName([mgr class])];
                    AevonGripOwnLog("register", line.UTF8String);
                    return YES;
                } @catch (NSException *exception) {
                    NSString *line = [NSString stringWithFormat:
                                      @"toDisplayWithIdentity: 抛异常 %@ → 换下一路",
                                      exception.name];
                    AevonGripOwnLog("register", line.UTF8String);
                }
            } else {
                AevonGripOwnLog("register", "displayConfiguration.identity 取不到 → 换下一路");
            }
        }
    }
    /* ①两参真名：addGestureRecognizer:withType:（census 实测，两边管理器都有） */
    SEL sel2 = NSSelectorFromString(@"addGestureRecognizer:withType:");
    if ([mgr respondsToSelector:sel2]) {
        Method m = class_getInstanceMethod([mgr class], sel2);
        if (m != NULL) {
            const char *enc = method_getTypeEncoding(m);
            if (enc == NULL || enc[0] != 'v' || AevonGripEncArgCount(enc) != 2) {
                NSString *line = [NSString stringWithFormat:
                                  @"addGestureRecognizer:withType: 签名不符（%s）→ 不调",
                                  enc ? enc : "?"];
                AevonGripOwnLog("register", line.UTF8String);
            } else {
                long long type = AevonOwnBestGestureType();
                if (type < 0) {
                    /* 类型值还没取到 —— 绝不猜常量，等 kick 下一轮（取到后自动重试）。 */
                    if (!gAevonOwnTypeProbeLogged) {
                        gAevonOwnTypeProbeLogged = YES;
                        AevonGripOwnLog("register", "类型值尚未取到（KVC/钩子都没命中）→ 本轮不注册，"
                                                    "继续借识别器腿，等下一轮重试");
                    }
                    return NO;
                }
                @try {
                    ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)
                        (mgr, sel2, g, (unsigned long long)type);
                    NSString *line = [NSString stringWithFormat:
                                      @"已用 addGestureRecognizer:withType: 注册进系统手势管理器"
                                      @"（拿到仲裁身份；类型值 %lld 来自系统实测）", type];
                    AevonGripOwnLog("register", line.UTF8String);
                    return YES;
                } @catch (NSException *exception) {
                    NSString *line = [NSString stringWithFormat:
                                      @"addGestureRecognizer:withType: 抛异常 %@ → 换下一个",
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
    /* ①管理器注册 —— 不依赖宿主视图，这是拿仲裁身份的唯一正路。
     * V0.3.12：0.3.11 这里的 `if (gAevonOwnGesture != nil) return YES;` 是个死结 ——
     * 探针一开就 attach 成功，从此再也不尝试注册，永远停在退路上。现在改成：
     * 已经有旁听识别器也继续试着「升级」成正路，升级成功再把旧的那只摘掉。 */
    if (!gAevonOwnManagerTried) {
        gAevonOwnManager = AevonOwnLookupManager();
        gAevonOwnManagerTried = YES;
    }
    if (gAevonOwnManager != nil) {
        if (!gAevonOwnIvarLogged) {
            gAevonOwnIvarLogged = YES;
            AevonOwnDumpIvars(gAevonOwnManager, @"管理器");
        }
        AevonOwnLegGesture *fresh = [[AevonOwnLegGesture alloc] init];
        if (AevonOwnTryRegister(gAevonOwnManager, fresh)) {
            UIGestureRecognizer *old = (UIGestureRecognizer *)gAevonOwnGesture;
            if (old != nil) {
                UIView *v = old.view;
                if (v != nil) { [v removeGestureRecognizer:old]; }
                old.enabled = NO;
            }
            gAevonOwnGesture = fresh;
            gAevonOwnRegistered = YES;
            return YES;
        }
    }
    if (gAevonOwnGesture != nil) { return YES; }
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
    /* V0.3.21（AevonPrefsGateV321）：**状态没变就什么都不做**。
     *
     * 用户 Aevon(96) 实测：拖阻尼滑条时这个函数 96 秒里被调了 202 次
     *（间隔 16~17ms = 每帧一次，因为每帧写一次偏好就会广播一次 prefschanged）。
     * 每次都无条件刷一条「已启用 → 立即开始装配」并 dispatch 一次 Kick ——
     * 而 Kick 进门第一句就是 `if (gAevonOwnRegistered) return;`，实际什么都没做。
     * 202 条日志全是噪声，还让「真装配」在日志里彻底看不出来。
     *
     * 现在：已经启用（on && was）只同步取证开关就返回。probeOn 单独变化也要吸收，
     * 否则改 GripHookProbe 会走进下面的装配分支。 */
    if (on && was) {
        gAevonOwnLegProbeOn = probeOn;
        return;
    }
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

/* V0.3.13（AevonHandleHideV313）：给 Swift 的 int 版就绪判据。
 * BOOL 的跨语言返回 ABI（ObjC 的 signed char / bool vs Swift Bool）不保证一致，
 * 用 int 直接把这个不确定消掉 —— 把手隐藏的 fail-open 与借腿让路都靠它。
 *
 * ⛔ 必须同时要求 `gAevonOwnRegistered`，不能只看识别器对象在不在：
 * `AevonOwnAttachTo` 那条「挂宿主旁听」的退路也会把 `gAevonOwnGesture` 赋上，
 * 而 0.3.11 实测旁听拿不到任何 moved 帧（38 hold / 0 moved）——它根本不会呼盘。
 * 若把它算成「就绪」，借腿就会被让路掉，结果是**完全没有呼盘入口**。 */
int AevonGripOwnLegReadyInt(void) {
    return (gAevonOwnGesture != nil && gAevonOwnRegistered) ? 1 : 0;
}

int AevonGripSystemLegReadyInt(void) {
    return gAevonLegEnabled ? 1 : 0;
}

/* V0.3.11（AevonOwnSuppressV311）：自建腿呼盘成功后 0.35s 内，系统腿不再重复呼盘。
 * 两条腿同时活着是刻意的（任何一条失效功能不丢），但同一次手势会有两只识别器
 * 在 20ms 内先后达阈值 —— 之前靠「圆盘已开」拦掉第二条，日志里会多一条
 * 「达阈值但被拦 原因=圆盘已开」。改成自建腿主动让路，日志更干净，也避免
 * 圆盘刚收起时第二条腿又把窗开开。 */
void AevonGripOwnStampSummon(void) {
    gAevonOwnSummonStamp = CACurrentMediaTime();
}

/// 距上一次自建腿真正呼盘的秒数；从没呼过返回一个很大的数。
double AevonGripOwnSummonAge(void) {
    if (gAevonOwnSummonStamp <= 0) { return 9999.0; }
    return CACurrentMediaTime() - gAevonOwnSummonStamp;
}

/* V0.3.28（AevonYieldGuardV328）：距「本手势被自建腿接管」的秒数。
 * 借腿（`systemLegSummon`）用它决定要不要拦系统腿：只有 0.15s 内才拦。
 * 这个窗口之外，说明这颗手指自建腿没要（落点在带外），系统腿必须放它过去。 */
void AevonGripOwnStampHold(void) {
    gAevonOwnHoldStamp = CACurrentMediaTime();
}

double AevonGripOwnHoldAge(void) {
    if (gAevonOwnHoldStamp <= 0) { return 9999.0; }
    return CACurrentMediaTime() - gAevonOwnHoldStamp;
}

/* V0.3.29（AevonOwnSwallowV329）：自建腿当前那根手指的 `UITouch` 指针身份。
 *
 * 返回的是 SpringBoard `sendEvent:` 里 `[event allTouches]` 的同一批对象之一 ——
 * 识别器的 `-touchesBegan:` 收到的就是同一批实例，所以 Swift 侧拿它去和
 * `AevonGlobalTouchPhase` 报上来的 `touchID` 比指针相等，能精确对上。
 * 返回 0 = 当前没有自建腿手指（已经放行 / 已 reset / 从未接管）。
 *
 * 对不上时不会误伤：Swift 侧只是在 `shouldSwallowGlobalTouch` 里少一个命中，
 * 行为退回 0.3.28（手指照旧漏给下层），不会多吞别人的手指。 */
uintptr_t AevonGripOwnTouchID(void) {
    return gAevonOwnTouchID;
}

/* V0.3.29（AevonOwnSwallowV329）：把这根手指移交给全局吞层。
 * Swift 侧在 `presentRing(source:"ownleg")` 里读完身份、绑好吞层之后调用一次。 */
void AevonGripOwnHandoff(void) {
    if (gAevonOwnGesture == nil) { return; }
    AevonOwnLegGesture *g = (AevonOwnLegGesture *)gAevonOwnGesture;
    [g ownHandoff];
}

/* V0.3.31（AevonSwallowFeedV331）：吞层回喂入口 —— 由 `AevonTouchHook.m` 在**真的丢弃**
 * 一帧 moved 之后调用一次（判定为吞、且已经决定 `return` 之前）。
 *
 * 身份校验不能省：`gAevonOwnTouchID` 是「自建腿当前扣着的那根手指」，只有它才该被回喂。
 * 别的手指（第二根、浮窗拖拽那根）进了吞层分支时，用它去推 `_ownStart` 会让圆盘
 * 跟着错的手指走 —— 0.3.17 的 `_ownTouch` 单指纪律就是为这件事写的。 */
void AevonGripOwnExternalMove(uintptr_t tid, double x, double y) {
    if (tid == 0 || tid != gAevonOwnTouchID) { return; }
    if (gAevonOwnGesture == nil) { return; }
    AevonOwnLegGesture *g = (AevonOwnLegGesture *)gAevonOwnGesture;
    [g ownExternalMove:CGPointMake((CGFloat)x, (CGFloat)y)];
}

#pragma mark - V0.3.32（AevonHeldBeginV332）：落指扣住 / 回放

/* Aevon(105) 把 0.3.31 的残留泄漏定死在一个具体位置上：**App 拿到的只剩 began 与 ended 两帧，
 * 而 ended 带的是手指抬起那一刻的终点坐标。**
 *
 *   12:28:20.432  SB sendEvent 右缘 began (425,750)        ← 这一帧必然投给 App
 *   12:28:20.462  自建腿 summon（位移 20pt）                ← 下一帧起全吞
 *   12:28:20.479  预绑转正                                  ← 吞层生效
 *   12:28:21.240  lift：吞层实丢 94 帧                       ← 中间一帧都没漏
 *
 * 也就是说 App 看到的是「按下(425,750) → 抬起(≈330,690)、中间零帧」。零 moved 骗不过
 * 任何滚动视图，但**起止坐标本身就是一次横滑**：抖音的左滑进博主主页判据取的就是它。
 * 桌面之所以不犯，是因为 B 项（`AevonGripDeskPanShouldFail`）把桌面那只 pan 直接判了失败。
 *
 * 要彻底消掉，只能让 App **一帧都拿不到** —— began 也不给。但落指那一刻我们还不知道
 * 用户要点击还是呼盘，所以这里做「扣住 + 短窗决策」：
 *   · 扣住 began（不调原 sendEvent），同时把这一帧外部喂给自建腿；
 *   · 55ms 内判出召唤 → 这段 began 永不回放，之后所有帧（含 ended）一律丢弃；
 *   · 55ms 内没判出      → 原样回放这段 began，并让自建腿退出本轮（绝不半路改吞）。
 * 点击与纵向滚动因此完全不受影响，代价只是带内起手多等 ≤55ms（与
 * `UIScrollView.delaysContentTouches` 同一量级）。
 *
 * 返回 1 = 这根手指归自建腿（调用方继续扣住）；0 = 不归我们（照常投递这一帧）。 */
int AevonGripOwnExternalBegin(uintptr_t tid, double x, double y) {
    if (!gAevonOwnLegEnabled || gAevonOwnGesture == nil) { return 0; }
    AevonOwnLegGesture *g = (AevonOwnLegGesture *)gAevonOwnGesture;
    @try {
        return [g ownBeginAtPoint:CGPointMake((CGFloat)x, (CGFloat)y)
                            touch:nil
                              tid:tid] ? 1 : 0;
    } @catch (NSException *exception) {
        return 0;
    }
}

/// 回放前退出本轮（见 `-ownDisarm` 的注释）。
void AevonGripOwnDisarm(void) {
    if (gAevonOwnGesture == nil) { return; }
    AevonOwnLegGesture *g = (AevonOwnLegGesture *)gAevonOwnGesture;
    @try {
        [g ownDisarm];
    } @catch (NSException *exception) {
    }
}

/// 抬手帧被吞掉时的外部收尾（UIKit 不会派 ended 进来）。
void AevonGripOwnExternalEnd(double x, double y) {
    if (gAevonOwnGesture == nil) { return; }
    AevonOwnLegGesture *g = (AevonOwnLegGesture *)gAevonOwnGesture;
    @try {
        [g ownExternalEndAtPoint:CGPointMake((CGFloat)x, (CGFloat)y)];
    } @catch (NSException *exception) {
    }
}

/// 吞层每帧问一次：判出召唤没有。1 = 已召唤（扣住的 began 永不回放）。
int AevonGripOwnSummonedFlag(void) {
    if (gAevonOwnGesture == nil) { return 0; }
    AevonOwnLegGesture *g = (AevonOwnLegGesture *)gAevonOwnGesture;
    @try {
        return [g ownSummonedInt];
    } @catch (NSException *exception) {
        return 0;
    }
}

/// 给 `AevonTouchHook.m` 打日志用（`AevonGripOwnLog` 是文件内 static）。
void AevonGripOwnNote(const char *tag, const char *detail) {
    AevonGripOwnLog(tag, detail);
}

#pragma mark - V0.3.30（AevonEarlyBindV330）：落指预绑

/* 落指那一刻就把这根手指交给全局吞层，**不等召唤**。
 *
 * 漏点结构性地存在于 `presentRing` 里：吞层判据挂在 SB `-sendEvent:`，而自建识别器
 * 是在同一次 `sendEvent:` 内部才判定「要不要召唤」。于是每一次召唤都必然先把
 * 「began + 首帧 moved」投给 App，之后才被吞。Aevon(103) 的 36 次召唤里，首帧位移
 * 中位 18pt、最大 49pt，App 拿到的是一个高速横向帧后彻底静止 —— ScrollView 拿它算
 * 惯性、抖音拿它判横滑，用户看到的就是「呼出圆盘时 App 内被带动」。
 *
 * 预绑把「开始吞」的时机从召唤提前到落指：下一帧 moved 的 `sendEvent:` 询问就能命中，
 * 漏的只剩 began 这一帧（零位移，对 ScrollView / pan 都不产生位移量）。
 *
 * 与 0.3.29 真正的绑定不冲突：召唤时 `presentRing` 发现 `globalTouchID` 已经等于
 * 这根手指，只做「转正」（把 `ownSwallowBound` 置真、续期吞窗口），不重绑。
 *
 * 点击安全：点击没有 moved 帧，预绑期间一个帧都没吞掉；`-ownPass:` 立刻撤销预绑，
 * ended 照常送达 —— 与旧版同为 0.28s 延迟，行为不变。
 * 失败一律 fail-open：Swift 侧任何 guard 不成立就什么都不做，退回 0.3.29。 */
void AevonGripOwnPreBind(double x, double y) {
    uintptr_t tid = gAevonOwnTouchID;
    if (tid == 0) { return; }
    AevonGripPreBindTouch(tid, x, y);
}

/* 撤销预绑。tid 传 0 = 「用 Swift 侧自己记的那个」（`-ownPass:` 里身份刚被清掉）。
 * 只撤销预绑，不动 0.3.29 已经转正的真实绑定 —— 那一份由自己的 6 个归还点管。 */
void AevonGripPreBindCancel(uintptr_t tid) {
    AevonGripPreBindClear(tid);
}

/* V0.3.30：SB `sendEvent:` 每真的丢弃一次事件就 +1（由 AevonTouchHook.m 调用）。
 * 抬手时打进 lift 日志 —— 这是「吞层到底有没有在吞」唯一的直接判据。 */
void AevonGripOwnSwallowTick(void) {
    gAevonOwnSwallowFrames += 1;
}

uintptr_t AevonGripOwnSwallowFrames(void) {
    return gAevonOwnSwallowFrames;
}

/* V0.3.29（AevonDeskPanGuardV329）：桌面翻页 pan 是否该被强制判失败。
 *
 * 只治桌面这件事：Aevon(101)/(102) 两份日志里，`AevonOwnLegGesture → began`
 * 之后 17~39ms 必有 `UIScrollViewPanGestureRecognizer → began` —— 我们的识别器
 * 挂 `_UISystemGestureManager`（系统手势环境），SB 的桌面滚动在这个环境之外，
 * 两边不共享仲裁，所以「我们成功了」并不等于「它失败了」。
 *
 * 判据（全部满足才动手，任何一条不满足就 fail-open 什么都不做）：
 *   ① 自建腿在最近 1.2s 内真的召唤过（`gAevonOwnSummonAtGuard`）；
 *   ② 这个识别器是 `UIScrollViewPanGestureRecognizer` 或其子类；
 *   ③ 它的宿主视图在**桌面**子树里（沿 superview 链找 HomeScreen / Icon / Folder）；
 *   ④ 它当前的点在右缘 40pt 内（我们的带是 15pt，留 25pt 余量给手指继续左滑）。
 * 只碰 SB 自己的桌面滚动 —— App 进程里的滚动根本不在这里，抖音那边由 Swift 的
 * 全局吞层负责。 */
static BOOL AevonGripDeskPanShouldFail(id recog) {
    @try {
        if (gAevonOwnSummonAtGuard <= 0) { return NO; }
        if (CACurrentMediaTime() - gAevonOwnSummonAtGuard > 1.2) { return NO; }
        if (![recog isKindOfClass:[UIGestureRecognizer class]]) { return NO; }
        NSString *cn = NSStringFromClass([recog class]);
        if ([cn rangeOfString:@"UIScrollViewPanGestureRecognizer"].location == NSNotFound) { return NO; }
        UIGestureRecognizer *g = (UIGestureRecognizer *)recog;
        UIView *v = [g view];
        BOOL onDesk = NO;
        for (UIView *cur = v; cur != nil; cur = [cur superview]) {
            NSString *vn = NSStringFromClass([cur class]);
            if ([vn rangeOfString:@"HomeScreen"].location != NSNotFound
                || [vn rangeOfString:@"Icon"].location != NSNotFound
                || [vn rangeOfString:@"Folder"].location != NSNotFound) { onDesk = YES; break; }
        }
        if (!onDesk) { return NO; }
        CGPoint p = [g locationInView:nil];
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        if (p.x < sw - 40.0) { return NO; }
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

/* V0.3.32（AevonSysLegRevokeV332）：系统边缘手势腿在 Began 阶段就吊销。
 *
 * Aevon(105) 的抖音段（22 次落指，落点 x=414~426）里，`_UIPendingEdgeSwipeGestureRecognizer`
 * **22/22 全部认领过右缘 began**。它的 `延迟began=否`，也就是说它在我们扣住 moved
 * 之前就已经进了 Began —— 系统后端（App 的交互式边缘手势通道）收到过「开始了」，
 * 之后所有 moved 被吞、它再也收不到帧，那段「已经开始」的交互就悬在半空。
 * 0.3.29 的借腿让路只在「达阈值」时拦它，拦不到 Began 这一下。
 *
 * 判据（全部满足才动手，任何一条不满足就 fail-open）：
 *   ① 自建腿最近 1.2s 内真的召唤过（`gAevonOwnSummonAtGuard`）；
 *   ② 类名含 `_UIPendingEdgeSwipe` 或 `UIScreenEdgePanGestureRecognizer`
 *      （`SBFluidSwitcherScreenEdgePanGestureRecognizer` 不含 `UI` 前缀，不会被误伤）；
 *   ③ 它当前的点在右缘 40pt 内。
 * 只在 SpringBoard 里生效：`gAevonOwnSummonAtGuard` 只在 SB 的召唤路径里写，
 * App 进程里恒为 0 —— 不会吊销注入 App 自己的边缘手势。 */
static BOOL AevonGripSysLegShouldFail(id recog) {
    @try {
        if (gAevonOwnSummonAtGuard <= 0) { return NO; }
        if (CACurrentMediaTime() - gAevonOwnSummonAtGuard > 1.2) { return NO; }
        if (![recog isKindOfClass:[UIGestureRecognizer class]]) { return NO; }
        NSString *cn = NSStringFromClass([recog class]);
        if ([cn rangeOfString:@"_UIPendingEdgeSwipe"].location == NSNotFound
            && [cn rangeOfString:@"UIScreenEdgePanGestureRecognizer"].location == NSNotFound) {
            return NO;
        }
        UIGestureRecognizer *g = (UIGestureRecognizer *)recog;
        CGPoint p = [g locationInView:nil];
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        if (p.x < sw - 40.0) { return NO; }
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

/// 被吊销的留痕（0.5s 限流）。出现这一行 = 系统腿确实被我们摁住了。
static void AevonGripSysLegRevokeNote(id recog) {
    static CFTimeInterval lastAt = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastAt < 0.5) { return; }
    lastAt = now;
    NSString *cn = @"?";
    @try { cn = NSStringFromClass([recog class]); } @catch (NSException *exception) { }
    NSString *line = [NSString stringWithFormat:
                      @"系统边缘手势腿 Began 即吊销 类=%@（自建腿刚召唤，右缘 40pt 内）"
                      @"（AevonSysLegRevokeV332）", cn];
    AevonGripOwnLog("sysleg", line.UTF8String);
}

/* V0.3.29（AevonDeskPanGuardV329）：桌面 pan 被强制判失败的留痕（0.5s 限流）。
 * 有这一行就说明守卫真的打中了；一次都没有 = 判据没命中桌面那只识别器，
 * 需要回头收窄/放宽 ②③④ 三个条件，而不是继续猜。 */
static void AevonGripDeskPanGuardNote(void) {
    static CFTimeInterval lastAt = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastAt < 0.5) { return; }
    lastAt = now;
    AevonGripOwnLog("deskpan",
                    "桌面翻页 pan 已强制判失败（自建腿刚召唤，右缘 40pt 内）"
                    "（AevonDeskPanGuardV329）");
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

/* V0.3.11（AevonOwnLegTypeV311）：0.3.10 的注册名是从 strings 推的、根本不存在的
 * `addGestureRecognizer:toDisplayWithIdentity:`；真名是 **census 实测**的
 * `addGestureRecognizer:withType:`（v32@0:8@16Q24，SBSystemGestureManager 与
 * SBMainDisplaySystemGestureManager 都有）。第二个参数「手势类型」不写常量：
 * 优先从系统自己那只边沿识别器上 KVC 读，读不到就钩一次同名方法抄系统传的值。
 * 配套三处：①moved 首帧探针（判注册到底生效没有）；②闸从固定 0.28s 改成
 * 滚动 0.28s + 总上限 0.9s（慢速滑动不再被误放行）；③自建腿呼盘后 0.35s 内
 * 系统腿让路（AevonOwnSuppressV311），日志不再出现成对的「达阈值但被拦」。 */
__attribute__((used)) static const char AevonOwnLegTypeV311Marker[] = "AevonOwnLegTypeV311";
__attribute__((used)) static const char AevonOwnSuppressV311Marker[] = "AevonOwnSuppressV311";

/* V0.3.12（AevonOwnClaimV312 / AevonOwnIvarV312 / AevonOwnUIKitMgrV312）：
 *
 * Aevon(90) 一句话把 0.3.11 判了：「只有第一次呼出圆盘时 app 没有跟着操作，后面的都跟」。
 * 结论：hold 本身**能**扣住 App（第一次证明了），但那之后 UIKit 不再给延迟 ——
 * 因为这只识别器从来一次都没成功识别过（0 自建呼盘 / 0 moved），UIKit 对「永远 failed
 * 的识别器」会撤销 delaysTouchesBegan 的资格。三个改动：
 *   ① 连带认领（AevonOwnClaimV312）—— 借腿达阈值真要呼盘的那一刻，自建腿同步进 Began，
 *      既认领这根手指（cancel App 触摸），也让它「真的识别成功」一次；
 *   ② 修 0.3.10 查错类（AevonOwnUIKitMgrV312）—— toDisplayWithIdentity: 的宿主是
 *      UIKit 的 `_UISystemGestureManager`，不是 SB 的两个管理器类；这条路不需要类型值；
 *   ③ ivar 形状取证（AevonOwnIvarV312）—— KVC 五 key 全 miss、钩子也等不到，
 *      剩下唯一没读过的取证面就是对象自己的 ivar（「类型号 → 识别器」的容器）。 */
__attribute__((used)) static const char AevonOwnClaimV312Marker[] = "AevonOwnClaimV312";
__attribute__((used)) static const char AevonOwnIvarV312Marker[] = "AevonOwnIvarV312";
__attribute__((used)) static const char AevonOwnUIKitMgrV312Marker[] = "AevonOwnUIKitMgrV312";

/* V0.3.13（AevonGripZoneV313 / AevonHandleHideV313 / AevonOwnGateV313）：
 *
 * Aevon(91) 把 0.3.12 判成功了：「开启后很小的几率触发 app 内操作，关闭后 100% 触发」。
 * 日志与之逐条吻合：开关打开的 55 秒里 27 次呼盘 **27/27 全走自建腿**，
 * 关掉的 7 秒里 3 次 **3/3 全走借腿**；28 次 hold **全部有结局**，
 * 纵向闸 0 次、0.28s 超时闸 0 次 —— 逻辑层零漏洞，唯一漏出口是 24pt 那条窄边。
 * 四个改动：
 *   ① 触发区换成「右缘底部 屏宽25% × 屏高30%」百分比矩形（AevonGripZoneV313）；
 *   ② 把手可整体隐藏，默认隐藏（AevonHandleHideV313）—— Stheno 同款无显形边缘；
 *   ③ 纵向判据提前到首帧、且排在呼盘判据之后（AevonOwnGateV313）；
 *   ④ 借腿降为纯兜底 + App 侧吞带退役（AevonAppBandRetireV313，在 App 侧 dylib）。 */
__attribute__((used)) static const char AevonGripZoneV313Marker[] = "AevonGripZoneV313";
__attribute__((used)) static const char AevonHandleHideV313Marker[] = "AevonHandleHideV313";
__attribute__((used)) static const char AevonOwnGateV313Marker[] = "AevonOwnGateV313";

/* V0.3.14（AevonEdgePadV314）：触发区从「屏宽 25% 矩形」收回「贴边窄带 + 暂扣段」。
 *
 * 用户 Aevon(93)：「只要手指贴着右侧底部 30% 高度中向左滑动时触发，而不要任何宽度」。
 * 0.3.13 那 107pt 宽的好处是「零落偏」，坏处是抖音底部进度条、右下角按钮全在里面；
 * 本版把宽度交给用户按 pt 调（默认 5），落偏靠 padRect 的暂扣段兜：
 *   · bandRect（默认 5pt）：贴边落点 → 宽松判据，左滑 8pt 就呼盘；
 *   · padRect（+35pt）：边缘候选 → 先扣一帧，只有近似纯水平左滑才认，否则立刻还回去。
 * 两段式让「贴边就触发」和「右下角横向拖动不受影响」同时成立。 */
__attribute__((used)) static const char AevonEdgePadV314Marker[] = "AevonEdgePadV314";

/* V0.3.15（AevonGripHardcodeV315）：默认开启的呼出手势开关全部写进代码、设置页不再显示。
 * 具体三条：GripOwnLeg（自建识别器腿）恒开、GripSystemYield（把手让路）恒开、
 * GripHookProbe（取证深度）与 GripScope（右缘整条）UI 移除（代码仍读，默认 false）。
 * 依据：这三条在 0.3.7 / 0.3.10 / 0.3.12 都已实证转正，留开关只剩「把唯一通路关掉
 * 然后以为插件坏了」这一个用途。GripHandleHidden 反过来从二级页提到一级页 ——
 * 它是用户真的会来回拨的（想看见边、想看不见边），留在二级页找不到。 */
__attribute__((used)) static const char AevonGripHardcodeV315Marker[] = "AevonGripHardcodeV315";
__attribute__((used)) static const char AevonHandleTopV315Marker[] = "AevonHandleTopV315";
__attribute__((used)) static const char AevonSliderLiveV315Marker[] = "AevonSliderLiveV315";
__attribute__((used)) static const char AevonZoneH35V315Marker[] = "AevonZoneH35V315";
__attribute__((used)) static const char AevonStrictAngleV315Marker[] = "AevonStrictAngleV315";
__attribute__((used)) static const char AevonOwnLogAsciiV315Marker[] = "AevonOwnLogAsciiV315";

/* V0.3.16（AevonOwnLiftV316）：自建识别器腿活到抬手。
 * 依据 Aevon(93) 桌面段 64 次呼盘：48 次抬手即收（531~1356ms），16 次僵在看门狗上
 * 且时长恒定 1003~1008ms。根因是召唤点紧跟的 `state = Ended` 让 UIKit 立刻 -reset，
 * 这根手指此后再没有任何帧派给识别器 → 「抬手」信息结构性丢失。
 * 本版：召唤成功后保持 Began；touchesEnded / touchesCancelled 在 _ownSummoned 时
 * 调 AevonGripOwnLift → 圆盘走「权威抬手」通道当场收起，不再等 1 秒看门狗。
 * Stheno 同构：SCArcGestureRecognizer（__trackingActive + __resetHandler）
 * → SCArcGestureCoordinator -sc_finishTracking → -sc_dismissAnimated:。 */
__attribute__((used)) static const char AevonOwnLiftV316Marker[] = "AevonOwnLiftV316";

/* V0.3.17（AevonOwnFeedV317）：自建识别器腿**每帧喂盘**。
 * 依据 Aevon(94) 桌面段 28 次展开：11 次被 1.0s 看门狗收、16 次「抬手未选中」、
 * 只有 1 次真的选中。那 11 次的「最后落点」与「呼盘那一刻的落点」逐条相等
 * （383/392/408/415/410/404…）—— 圆盘从展开到被收，一条移动帧都没收到，
 * 所以既没有划过动画、也没有高亮，抬手自然判成「盘外」。
 *
 * 圆盘原先唯一活着的喂料方是 SB `sendEvent` 的全局通道，它有两道必杀：
 *   ① 每次展开后的前 0.12 秒被 `claimPointer` 的交换闸挡住（9 次成功交接全部
 *      落在 120/123/124/128ms，正好是 `pointerHandoffInterval`）；
 *   ② 任何一帧 `.cancelled` 都会把 `globalTouchID` 清零，而 `appEdgePointerAdopted`
 *      只在圆盘收起时才清 → 本周期内不许重新收养 → 之后每一帧都被静默 `return`。
 * 本版让持有这根手指的识别器直接把坐标喂给圆盘（`AevonGripOwnMove`），
 * 两条都不再成立。Stheno 同构：`-sc_handleArcPan:` → `-sc_pointForGestureRecognizer:`
 * → `-sc_updateSelectionAtPoint:`，它的圆盘从不经过任何旁路通道。 */
__attribute__((used)) static const char AevonOwnFeedV317Marker[] = "AevonOwnFeedV317";

/* V0.3.20（AevonKeyframeHoverV320）：划过动画从「每图标一条弹簧」整块换成**定长关键帧**。
 * 用户 Aevon(96)：「动画依旧不流畅，感觉像是丢帧一样，手指划过时弹起来了，然后手指继续
 * 划到下一个时，上一个还在空中」。两条根因都在旧的弹簧模型里：
 *   ① 余韵按队列下标取振幅，而划过间隔只有 72~100ms、弹簧沉降要 0.34~0.63s
 *      ⇒ 永远走不到目标就被改目标，身后形成永不落地的人形扇；
 *   ② 60 次/秒的 `finishAnimation(at: .current)` 每次都要取呈现值（渲染服务器往返）。
 * 现在：`rise`（200ms 抖动+挤压）/ `land`（250ms 触地压扁+一记余弹）两条定长关键帧，
 * 中途改目标用关键帧解析求值接住，不碰 `presentation()`。 */
__attribute__((used)) static const char AevonKeyframeHoverV320Marker[] = "AevonKeyframeHoverV320";

/* V0.3.20（AevonSquashStretchV320）：Q 弹的物理来源是 animate__rubberBand 那种**非等比**
 * 挤压（scaleX 1.34 / scaleY 1.22 交替反向、sx·sy 从 1.34 爬到 1.69 = 1.30²，体积守恒），
 * 而不是等比放大 —— 等比只会「变大」，永远不会「弹」。抬升轨道则借 animate__shakeY
 * 的衰减抖动（16.0 → 9.2 → 13.6 → 10.6 → 12.5 → 12.0）。 */
__attribute__((used)) static const char AevonSquashStretchV320Marker[] = "AevonSquashStretchV320";

/* V0.3.20（AevonShadowPathV320）：21 个图标一直有阴影，而 `shadowPath` 从来没设过 ——
 * Core Animation 每帧都要对整层 alpha 做卷积生成阴影；划过还把 `shadowRadius` 从 6 改到
 * 10，等于模糊核每帧重算。再加上 `iconView` 的 `cornerRadius + clipsToBounds` 又各挂一个
 * 圆角 mask 图层（而 `AevonAppIcon.image` 早就把圆角烘进位图了，这层 mask 是白花的）。
 * 这是「丢帧」的 GPU 侧那一半：21 个图标 × 2 个离屏通道 × 120Hz。 */
__attribute__((used)) static const char AevonShadowPathV320Marker[] = "AevonShadowPathV320";

/* V0.3.20（AevonFrameProbeV320）：展开期间挂一条只读 CADisplayLink，收起时打一条
 * 「平均 fps / 最大帧间隔 / >16.7ms 的帧数」。前三版判断流畅度全靠手感描述，
 * 这版起有硬指标 —— 下一轮不用再猜「丢帧」是渲染慢还是事件少。 */
__attribute__((used)) static const char AevonFrameProbeV320Marker[] = "AevonFrameProbeV320";

/* V0.3.21（AevonHoverJumpV321）：划过动画的波形从「高频小幅抖动」换成**一次单峰起跳**。
 * 用户 Aevon(97)：「这次滑动时的动画还可以，但是图标只在原地抖动，而不是向上跳起然后回落」。
 * 帧率那一半已经满分（119.8fps / 4083 帧 / 最大间隔 35.9ms / >16.7ms 只有 2 帧），
 * 所以剩下的是时间尺度与波形：
 *   ① 34.09 秒 494 次划过 ⇒ 平均 **69ms** 一个切换，而 0.3.20 的 rise+land = 450ms
 *      ⇒ 每个图标的动画平均只播到 15% 就被改目标；
 *   ② lift 轨道 48ms 就到顶，之后 152ms 困在 9.2~16 之间 12Hz 往复，末态还停在 12pt
 *      —— 没有「离地 → 触地」的对比，读到的就是原地抖；
 *   ③ **`CATransform3DConcat(T, S)` 把平移量乘了 sy**，而 sy 在 1.12~1.38 之间同频振荡
 *      ⇒ 垂直位置被叠了一层更大的抖动。已改成 `Concat(S, T)`，lift 就是 pt 原值。
 * 新波形：7 帧 / 90ms，峰值 32pt 在 34ms，66ms 触地（早于 69ms 的切换节奏），
 * 落定不抬起（hoverLift = 0）+ 放大 1.18。 */
__attribute__((used)) static const char AevonHoverJumpV321Marker[] = "AevonHoverJumpV321";

/* V0.3.21（AevonRingIcon35V321）：图标 40 → 35pt，环距与基准一起收（弧间距 46 → 42、
 * 内圈基准 62 → 60、径向步进 44 → 39、自适应系数 0.78 → 0.83）。
 * 21 个 App（8/13）实测：半径 62/106 → 60/99、图标 38 → 35、最外缘 126 → 116.5。
 * 内圈 60 是物理下限：圆心半径 24 + 图标半径 17.5 + 18pt 间隙 = 59.5，再小会压到中心盘。 */
__attribute__((used)) static const char AevonRingIcon35V321Marker[] = "AevonRingIcon35V321";

/* V0.3.21（AevonPrefsGateV321）：设置变更回调的**三处变更门控**。
 * 用户 Aevon(96)：拖阻尼滑条时 `自建腿 enable` 96 秒里被打了 **202 次**（间隔 16~17ms，
 * 即每帧一次）。那条链是「每次写偏好 → Darwin 通知 → 整条刷新」：
 *   ① `AevonGripOwnLegEnable(true, …)` 无条件打日志 + 排一次 Kick（装配早就完成了）；
 *   ② `AevonRingStore.refreshFromSettings()` 每帧**写一次快照 UserDefaults**（跨进程写盘）；
 *   ③ `AevonRingGrip.refreshFromPrefs()` 每帧 `setNeedsLayout + layoutIfNeeded` 同步布局。
 * 现在三处都先比「值有没有变」，没变就一个字节都不动。 */
__attribute__((used)) static const char AevonPrefsGateV321Marker[] = "AevonPrefsGateV321";

/* V0.3.22（AevonGifHoverV322）：划过动画按用户提供的 Stheno 屏幕录制重做。
 *
 * 录屏 295×639 = iPhone 15 Pro（393pt）的 1/4 ⇒ **1 GIF px = 1.333 pt**。量一个被
 * 手指压住的图标（32pt）：峰值抬升 61pt = 1.9×，缩放 32 → 40pt = 1.25×，**全程等比、
 * 无过冲**；升起 100ms（归一化 17%→2% / 33%→22% / 50%→50% / 83%→93% = easeInOut），
 * 回落 235ms（同样 easeInOut），**跳上去就一直停在空中，离开才慢慢沉**。
 *
 * 0.3.21 错在把稳态压回地面：34ms 冲到顶、66ms 就回地面 = 4 帧，眼睛只读得到「抖」。
 * 本版 `hoverLift` 0 → 46pt（1.31×：我们环的径向间隙只有 39pt，1.9× 会横穿外圈）、
 * `hoverScale` 1.18 → 1.25、三张关键帧表全部单调、全部 easeInOut、过冲归零。 */
__attribute__((used)) static const char AevonGifHoverV322Marker[] = "AevonGifHoverV322";

/* V0.3.22（AevonGifHaloV322）：图标脚下那圈**白色柔光底盘**。
 * 录屏里每个图标都有，被压住的更亮 —— 它是「图标跳出来」的主要读感来源。
 * 用预渲染的径向渐变位图（96×96 全类共享一份），不用 shadow：
 * shadow 的模糊核会跟着 `layer.transform` 每帧重算，等于把 0.3.20 刚按下去的
 * GPU 开销又开回来。抬起的图标同时 `zPosition = 1000` 画在邻居上面。 */
__attribute__((used)) static const char AevonGifHaloV322Marker[] = "AevonGifHaloV322";

/* V0.3.23（AevonRingUnfoldV323）：圆盘「从一点长成一个圆」—— 进度驱动的径向展开。
 *
 * 用户给的 Stheno 录屏逐帧量出来的事实：整簇图标**先叠在同一个点上**，然后一起
 * 向外铺开、边铺边长大，铺开全程「间距 ÷ 图标尺寸」几乎不变 —— 也就是最终布局的
 * 一个等比缩小版在持续放大。所以半径与图标缩放**共用同一个标量 s**，21 个图标
 * 之间没有任何相位差（0.3.22 之前是「同时弹射 + 按 index 错峰 0.018s」，不是这个形态）。
 *
 * 进度 = max(时间曲线, 拖动曲线)：手指划得快长得快（用户要的「跟手」），
 * 手指停住也会在 0.55s 内自己长完，永远不会卡在半个盘上。
 * 曲线是 smoothstep（两端导数为 0），没有过冲 —— 21 个图标同时过冲会让盘面「嗡」一下。 */
__attribute__((used)) static const char AevonRingUnfoldV323Marker[] = "AevonRingUnfoldV323";

/* V0.3.23（AevonRingIcon40V323）：图标 35 → **40pt**，环径整套跟着放。
 * 弧间距 42 → 46、内圈基准 60 → 64、径向步进 39 → 44、自适应系数 0.83 → 0.86。
 * 21 个 App（8/13）实测：半径 60/99 → **64/108**，最外缘 116.5 → 128。
 * 内圈 64 是物理下限（圆心盘 39 + 半图标 20 + 5pt 间隙），再小 40pt 图标会压到中心盘。 */
__attribute__((used)) static const char AevonRingIcon40V323Marker[] = "AevonRingIcon40V323";

/* V0.3.23（AevonHubPanelV323）：中心盘与外圈图标**刻意做成两种东西**。
 * 用户：「中心的面板图标和外圈的图标存在一些差异」。
 * 外圈 = 40pt 原生 App 图标 + 白晕 + 逐图标阴影；中心 = 玻璃面板（两层同心盘、
 * 连续圆角、更亮底面）+ 52pt 34% 圆角的方形按钮 —— 没有白晕、没有图标阴影，
 * 不会被误读成「第 22 个 App」。 */
__attribute__((used)) static const char AevonHubPanelV323Marker[] = "AevonHubPanelV323";

/* V0.3.18（AevonSceneGateV318）：控制中心 / 通知中心 / 锁屏里不接管右缘手指。
 * 用户 2026-10-30：「在控制中心，通知中心，锁屏解锁后没有上滑进入桌面时都可以触发圆盘，
 * 应该修改为不能通过手势触发圆盘」。根因是 `presentRing` 的守卫里根本没有「当前在不在
 * 桌面」这一条，而自建腿是系统级识别器、全局生效。
 * 本版把闸放在**落指那一刻**（`-touchesBegan:`），判到浮层就 `ownPass:` → Failed：
 * 语义不是「不呼盘」，而是「这根手指根本不归我们」，UIKit 立刻把被 delay 的触摸补发给
 * 系统 —— 否则手指会被扣到抬手，控制中心里右缘左滑变成「划不动」。
 * 判据复用 0.2.78 让位那套窗口栈（Aevon(50) 实锤）：ControlCenterWindow(1080) /
 * CoverSheetWindow(1050)，门槛 `!isHidden && alpha > 0.5`。Stheno 的 `_SBFZStackParticipant`
 * 用的是切换器身份仲裁，本版不走那条（0.2.81 已判定它在 iOS 17 上不可靠）。 */
__attribute__((used)) static const char AevonSceneGateV318Marker[] = "AevonSceneGateV318";

/* V0.3.18（AevonSpringUnifyV318）：圆盘弹簧统一到 (response, dampingFraction)。
 * 用户 2026-10-30：「圆盘中图标的动画……为什么我感觉没有 Stheno 的动画流畅」。
 * Stheno 的二进制里 4 处引用 `SwiftUI.Animation.spring(response:dampingFraction:blendDuration:)`，
 * 参数存在 `SettingEnv.__dampingFraction`（设置页有 DampingFractionControlView 滑条）
 * —— 即「一套 SwiftUI 弹簧 + 一个全局阻尼值」。而 Aevon 之前同一个盘上跑五种弹法，
 * 阻尼比 0.34 / 0.55 / 0.676 / 0.78 各弹各的，划过还用的是 iOS 7 的老
 * `usingSpringWithDamping`（duration 语义与 response 不是一个物理量）。
 * 本版：AevonSpring 按 ω0 = 2π/response、k = ω0²、c = 2ζω0 换算成 UIKit 物理参数，
 * 五处共用一条 ζ 谱；划过改成单个 UIViewPropertyAnimator + 停在当前值重发（连续弹道）。 */
__attribute__((used)) static const char AevonSpringUnifyV318Marker[] = "AevonSpringUnifyV318";

/* ── V0.3.24（用户 Aevon(98) 三项：底边穿透 / 回桌面模糊 / 双黑窗）──────────────
 * 本版把「底边双击关闭」整体换成**上滑关闭终止手势**。理由不是手感，是竞态：
 * 双击第 2 击一落指就 close()，而 close 第一拍把存活心跳写 0；同一根手指由
 * backboardd **异步双投**给 App 进程，App 侧要看心跳才整根丢弃 —— 谁先到决定吞不吞，
 * 所以「有概率触发 App 内操作」。上滑把关窗推到**抬手**，手指存续期间浮窗一直活着。
 * Stheno 对照：`SCFloatingContainerView.__bottomLikeTouchRegions` 挂
 * `sc_addTerminationGestureToRegion:`，判据 `sc_shouldCloseForBottomUpwardFlick:`；
 * 移动在 `__allEdgeTouchRegions` —— 底边本来就不承担移动。 */

/* V0.3.24（AevonBottomFlickV324）：底边上滑 = 关闭（落指只登记候选，抬手才执行）。
 * 判据两条必居其一：位移 ≥40pt，或 24pt / 180ms 的快甩；方向占优 ×1.2。
 * 视图侧另有速度 700pt/s 兜底（UIPanGestureRecognizer 才有 velocity，全局通道没有）。 */
__attribute__((used)) static const char AevonBottomFlickV324Marker[] = "AevonBottomFlickV324";

/* V0.3.24（AevonSharpCacheGateV324）：**缓存帧入库闸** + 历史清晰基线 + 撤帧门槛改绝对量。
 * 用户报「回桌面时悬浮窗的内容会从定格模糊变为清晰的实时画面」。三处实证：
 *   ①`scheduleSnapshotRecapture` 直接写缓存，只过「8×8 明暗差」和「五点不全黑」，
 *     没有清晰度校验 —— 0.6s 定时很容易落在转场/降级瞬间，抓到系统低清表面；
 *   ②`installDarkFreeze` 的撤帧门槛是 `base × 0.72`，base 取**当次盖帧图**的清晰度：
 *     盖帧图模糊 → base 低 → 门槛跟着低 → 早撤 → 露出仍在重排的画面（自洽陷阱）；
 *   ③缓存与现场都取不到时直接不盖帧，用户全程看系统低清快照。
 * 现在：入库过 `sharpBaseline × 0.85` 的闸；基线取同窗历史**最大值**（模糊帧抬不高它）；
 * 撤帧门槛 `max(base × 0.72, baseline × 0.75)`，base 不可信时直接用 `baseline × 0.75`。
 * Stheno 对照：`SCStartupCoverView` 的封面是启动图，天然不会模糊 —— Aevon 没有 owned
 * 场景，抹不掉系统低清这一层，能做的是「用可信的清晰定格盖住它」。 */
__attribute__((used)) static const char AevonSharpCacheGateV324Marker[] = "AevonSharpCacheGateV324";

/* V0.3.24（AevonSharpPrimeV324）：开窗定稿那一拍**强制抓一张可信帧**（alpha=0 用户无感），
 * 抓不到就 0.4s 重试、上限 3 次 —— 保证盖帧永远不会因为「没有可用图」而缺席。 */
__attribute__((used)) static const char AevonSharpPrimeV324Marker[] = "AevonSharpPrimeV324";

/* V0.3.24（AevonOpenSingleFlightV324）：**开窗单飞**。open() 从入口到
 * `currentView = windowView` 之间隔着 asyncAfter 与场景准备，这段里 currentBundleID
 * 仍是旧值/nil；再触发一次开窗（圆盘连点两个图标 / 呼盘后立刻再呼 / 图标双击）就会
 * 两次都走到建视图那一拍 —— 后者覆盖 currentView，前者变野窗。用单调 token 让后到者
 * 作废先到者，所有异步节点首句对 token。Stheno 对照：`sc_evictOldestSessionForIncomingWindowIfNeeded`。 */
__attribute__((used)) static const char AevonOpenSingleFlightV324Marker[] = "AevonOpenSingleFlightV324";

/* V0.3.24（AevonOpenDedupV324）：开窗清扫的判据从「currentView / dockedViews 名单」
 * 改成**按 bundleID**。旧写法的致命处是拿状态做真相源 —— 野窗之所以是野窗，恰恰因为
 * currentView 已经漂移（指向后来那扇），用漂移后的名单清扫等于保护错对象、留下真野窗。
 * 只有「同目标 App 在 host 上不止一扇」才算重复（单扇主窗不动，保持「已在浮窗里 → 置顶」）。 */
__attribute__((used)) static const char AevonOpenDedupV324Marker[] = "AevonOpenDedupV324";

/* V0.3.24（AevonSceneOwnedV324）：**同一 FBScene 在本进程只允许一个呈现者**。
 * 这是「两个黑屏主悬浮窗」的结构性堵口：两个 presenter 呈现同一个 FBScene 时谁都拿不到
 * 远程层，两扇一起黑。`AevonSceneHost.init` 现在先抢占用，抢不到直接返回 nil（fail-closed），
 * 第二扇窗根本建不出来；失败路径与 invalidate 都会释放，30s 不续期可被接管。
 * Stheno 对照：`__sessionsByBundleID` / `__hostingScenePointers` / `__hostingSceneIdentifiers`
 * 三张表 + `sc_sessionForBundleIdentifier:` —— 它的「一个场景一个会话」是**表约束**，不是时序运气。 */
__attribute__((used)) static const char AevonSceneOwnedV324Marker[] = "AevonSceneOwnedV324";

/* V0.3.24（AevonPresenterRebuildV324）：presenter 自动重建（救单窗黑屏的最后一档）。
 * 已有的救援只有「重申前台」与「定格自愈」，两者都假定 presenter 还活着。但远程层连接
 * 断了以后写多少次 fg 都不会有画面（cs 恒 ≠2）—— 只能手动关开。这一档直接换一个 presenter，
 * 每窗上限 1 次，且只在「曾经有过画面」时触发（首次加载慢不算死）。
 * Stheno 对照：`sc_failSession:error:` / `sc_finalizeSession:` —— 会话失败有明确收尾。 */
__attribute__((used)) static const char AevonPresenterRebuildV324Marker[] = "AevonPresenterRebuildV324";

/* V0.3.25（AevonBottomSplitV325）：**底边 = 移动 + 长按后上甩关闭**（用户 Aevon(99)
 * 「底部不能移动有点不适应，上滑关闭又总误触，有没有两全其美的方法」）。
 * Stheno 实证（ScreenCore.dylib）：
 *   · 偏好键 `ScreenCore.Split.BottomMoveClose` —— 底边本来就是「移动 + 关闭」共存；
 *   · `sc_addTerminationGestureToRegion:` @0x34cf4 = UILongPressGestureRecognizer，
 *     `setMinimumPressDuration: 0.4`、`setAllowableMovement: 12` —— 一动（>12pt）长按
 *     立刻 fail，pan 拿回移动权，于是「移动」和「关闭」不需要二选一；
 *   · `sc_shouldCloseForBottomUpwardFlick:` @0x38444 判据：translation.y ≤ −24、
 *     −velocity.y ≥ 260pt/s（`splitBottomSwipeUpCloseVelocity` 默认）、|vx|×1.35 ≤ −vy。
 * 0.3.24 的 10pt / 40pt / 700·s⁻¹ 全部退役（Aevon(98) 日志 21 次触底里 13 次
 * 在 10~17pt 就成立 = 误触主体）。 */
__attribute__((used)) static const char AevonBottomSplitV325Marker[] = "AevonBottomSplitV325";
__attribute__((used)) static const char AevonTermHoldV325Marker[] = "AevonTermHoldV325";
__attribute__((used)) static const char AevonTermLiftV325Marker[] = "AevonTermLiftV325";
__attribute__((used)) static const char AevonTermVelV325Marker[] = "AevonTermVelV325";

/* V0.3.25（AevonNoFreezeV325）：**B3 —— 回桌面完全不盖定格帧，完全按 Stheno。**
 * Stheno 从不抓实时截图盖帧：它只有 `SCStartupCoverView`（UIImageView + 启动图/最后
 * 显示图），内容就绪判据 `sc_hostedContentIsReadyInHostView:`（layer 子树有 CALayerHost、
 * 宽高 >1pt、KVC `contextId` 非 0、KVC `hasBeenCommitted` == YES）连续 2 拍成立才
 * `sc_revealHostedContentForHostView:` 揭示一次；之后回桌面不盖任何东西。
 * 我们那套定格帧是黑屏兜底，但同时是「先模糊 → 再变清晰」的唯一来源（Aevon(98)
 * 日志 20:41:32 实测 `可信首帧（清晰度 1）`：空白帧被当基准 → 闸门塌到 1 → 盖上去
 * 就是一张糊图，0.9s 后撤掉才是实时画面）。用户定档：整条停用。
 * 代价（已告知）：回桌面那 0.3~0.5s 窗内没有画面。 */
__attribute__((used)) static const char AevonNoFreezeV325Marker[] = "AevonNoFreezeV325";

/* V0.3.26（AevonTermFollowV326 / AevonTermWinVelV326）：底边关闭预备态改成「跟手 + 窗口测速」。
 *
 * Aevon(99) 实测 25 次长按成立只关掉 5 次（20%）。失败样本的速度清一色
 * 83 / 104 / **125** pt/s（125 = 10pt ÷ 0.08s 的量化痕迹），而上移却有 260~404pt ——
 * 两个独立病灶：① 测速只取最后一对采样，抬手前 30~80ms 一减速就判死；
 * ② 长按成立后窗口一动不动，用户推 400pt 屏幕上什么都没发生。
 * 现在：8 帧环形缓冲取 ≤100ms 首尾两点测速（与视图侧同源），窗口跟手上移 0.55 倍，
 * 松手不过判据就弹回；出口从 1 条（24pt/260）扩到 3 条（+48pt/200、+120pt 大位移）。 */
__attribute__((used)) static const char AevonTermFollowV326Marker[] = "AevonTermFollowV326";
__attribute__((used)) static const char AevonTermWinVelV326Marker[] = "AevonTermWinVelV326";

/* V0.3.26（AevonHomeLooseV326 / AevonNoMidPassV326）：桌面呼盘单独一套判据。
 *
 * Aevon(99) 6 分钟 132 次右缘落指：成功 121 次首帧角度中位 **13°**，
 * 失败 8 次是 20°~42°（中位 27°）—— L2 的 14° 锥正好切在自然滑动分布的中位上。
 * 而「误触桌面翻页」不是没扣住，是**扣住后又半截还回去**：began 已
 * `delaysTouchesBegan` 扣住手指，中途 `ownPass:` 时 UIKit 把整段滑动补投给
 * SpringBoard → 翻页。桌面没有横向滚动内容可抢，所以首帧横向占优即呼盘（取消锥角），
 * 灰带一律扣到抬手，绝不半截补投。App 内保持原判据不变。 */
__attribute__((used)) static const char AevonHomeLooseV326Marker[] = "AevonHomeLooseV326";
__attribute__((used)) static const char AevonNoMidPassV326Marker[] = "AevonNoMidPassV326";

/* V0.3.28（AevonEdgeBandOnly328 / AevonNoConeV328 / AevonYieldGuardV328 / AevonSummonTTLV328）：
 *
 * 用户 Aevon(100)/(101) 两轮诉求：「桌面和全屏 app 中手势触发并不是 100% 成功」。
 * Aevon(101) 的 49 次自建腿 hold 把根因钉死：
 *   · 落点 84% 集中在离右缘 12~15pt，**0~6pt 一次都没有** —— 手指中心落不进最后 6pt；
 *   · 带内 5 次被 22° 锥判成「斜滑」放掉，而续判日志显示第 2 帧更斜（dx -30 → -47）；
 *   · 6 次「系统腿被拦 + 自建腿无 hold」= 两头空（判据是静态的「已注册」）。
 * 四条改动：
 *   ① 触发带 15pt 单层，带外一个字节都不碰（AevonEdgeBandOnlyV328，padRect 已删）；
 *   ② 方向判据整体退役，带内只看位移 ≥8pt（AevonNoConeV328）；
 *   ③ 借腿让路判据改成「本手势真的接管了」（AevonYieldGuardV328）；
 *   ④ `_ownSummoned` 加 2.5s 上限（AevonSummonTTLV328）。
 *
 * 哲学来自 Stheno 的 `SCArcGestureCoordinator -sc_canBeginAtPoint:`：
 * 它只判起点在不在触发区，方向交给后续 `-sc_handleArcPan:`，没有一票否决这一层。 */
__attribute__((used)) static const char AevonEdgeBandOnlyV328Marker[] = "AevonEdgeBandOnlyV328";
__attribute__((used)) static const char AevonNoConeV328Marker[] = "AevonNoConeV328";
__attribute__((used)) static const char AevonYieldGuardV328Marker[] = "AevonYieldGuardV328";
__attribute__((used)) static const char AevonSummonTTLV328Marker[] = "AevonSummonTTLV328";

/* V0.3.29（AevonOwnSwallowV329 / AevonOwnTouchBindV329 / AevonDeskPanGuardV329）：
 *
 * 用户 Aevon(102) 两条反馈：「桌面触发圆盘手势时百分百触发桌面滑动」、
 * 「抖音中触发手势时因为贴边，大几率会触发抖音的左滑进入视频博主主页」。
 *
 * 定量（Aevon(102) 2,019 行）：92 次 hold → 92 次召唤（**100%**，0.3.27 是 86%），
 * 分布 桌面 40 / 抖音 37 / QQ 12 / 设置 2 / 微信 1。也就是说 #1 的触发率已经修好，
 * 现在暴露的是「召唤 ≠ 压住」。
 *
 * 根因不是 0.3.28 新引入的：Aevon(101)（0.3.27）日志里时序完全一致 ——
 * `AevonOwnLegGesture → began` 之后 20~39ms，必有 `UIScrollViewPanGestureRecognizer
 * → began`。我们的识别器挂 `_UISystemGestureManager`（系统手势环境），SB 的桌面滚动
 * 在这个环境之外，两边不共享仲裁，所以「我们成功了」不等于「它失败了」。
 *
 * 而在 `presentRing:` 里 `ringSource` 被无条件写成 `"global"`，于是自建腿的手指在
 * 下一帧被全局通道的「收养」分支接走，那个分支的语义是「只登记喂盘、不吞」——
 * 依据是 0.2.7 的「把手是真实控件、命中天然路由」，而 0.3.13 起 `yieldMode` 让
 * `hitTest` 一律返回 nil，这个前提早就不存在了。手指就这样裸奔到桌面和 App。
 *
 * 两条改动：
 *   ① 自建腿召唤后把这根手指**真的绑进全局吞层**（AevonOwnSwallowV329 +
 *      AevonOwnTouchBindV329）：ObjC 递 `UITouch` 指针身份，Swift 侧
 *      `ownsTouch = true` 让 `sendEvent:` 整条事件丢弃 —— 桌面和 App 从下一帧起
 *      都收不到（抖音没被注入，这是唯一杠杆）；
 *   ② 桌面再加一层与吞层无关的兜底（AevonDeskPanGuardV329）：自建腿刚召唤的
 *      1.2s 内，桌面子树里的 `UIScrollViewPanGestureRecognizer` 想进 Began 一律
 *      降成 Failed。吞层若因任何原因没命中，桌面这条仍然成立。 */
__attribute__((used)) static const char AevonOwnSwallowV329Marker[] = "AevonOwnSwallowV329";
__attribute__((used)) static const char AevonOwnTouchBindV329Marker[] = "AevonOwnTouchBindV329";
__attribute__((used)) static const char AevonDeskPanGuardV329Marker[] = "AevonDeskPanGuardV329";

/* V0.3.30（AevonEarlyBindV330 / AevonPreBindCancelV330 / AevonSwallowTickV330）：
 *
 * 用户 Aevon(103)：「修复没有效果，甚至更加严重了，现在设置、QQ、抖音全屏时呼出
 * 圆盘手势都会带动 app 内操作」。
 *
 * 定量（Aevon(103) 1,239 行）：63 次 hold → 36 次召唤 → **36 次绑定成功**（0 次
 * 「身份为空」），抬手帧 37 次全部从全局通道回来 → 0.3.29 的「识别器 UITouch 与
 * SB sendEvent 是同一批实例」这条假设**成立**，绑定真的绑上了。桌面 pan 被吊销 21 次，
 * 桌面翻页已经压住。也就是说 A/B 两项都在执行，变差的另有其因。
 *
 * 真因是**结构性的漏帧**，不是时延：
 *   10:59:56.011  SB sendEvent began      ← 必投 App（圆盘还没开）
 *   10:59:56.016  自建腿 hold
 *   10:59:56.053  首帧 moved 位移 23pt     ← 也投给了 App
 *   10:59:56.054  summon
 *   10:59:56.072  已绑全局吞层             ← 吞层从这里才生效
 * 吞层判据挂在 SB `-sendEvent:`，而自建识别器是在**同一次** `sendEvent:` 内部才做出
 * 判定 —— 判定永远晚于本函数顶部的吞层询问。36 次召唤的首帧位移中位 18pt、最大 49pt，
 * App 拿到的是「began + 一个 18~49pt 的高速横向帧 + 再无后续」：ScrollView 拿这一帧
 * 算惯性、抖音拿它判横滑。0.3.28 里 App 拿到的是完整跟随手势（跟着手指走），
 * 0.3.29 变成「被甩一下」—— 这就是「更严重」。
 *
 * 另一条：0.3.29 连抬手帧也吞（`if ownsTouch { return true }`），App 留下「有 began
 * 无终止帧」的孤儿触摸。这条教训 0.2.57 就写在 `zombieSeal` 分支的注释里了
 *（「ended/cancelled 放行，孤儿 ended 对 UIKit 无害，吞了反而留脏簿记」），新路径没照抄。
 *
 * 三处改动：
 *   ① 落指预绑（AevonEarlyBindV330）：`-touchesBegan:` 写完身份立刻请求预绑，
 *      下一帧 moved 的询问就能命中，漏的只剩 began 那一帧（零位移）。召唤时只做
 *      「转正」，不重绑。点击不受影响 —— 点击没有 moved 帧，`-ownPass:` 立刻撤销预绑。
 *   ② 抬手帧放行（AevonPreBindCancelV330）：预绑手指的 ended/cancelled 一律不吞，
 *      消掉孤儿触摸；圆盘照样收到抬手（钩子对结束帧是「先询问再上报」）。
 *   ③ 吞帧计数（AevonSwallowTickV330）：绑定日志只能证明「绑上了」，证不出
 *      「真的吞掉过一帧」。计数在 `-touchesBegan:` 归零、SB 丢弃分支累加、抬手打进
 *      lift 日志 —— 0 = 吞层一帧都没拦住，下次一眼可辨。 */
__attribute__((used)) static const char AevonEarlyBindV330Marker[] = "AevonEarlyBindV330";
__attribute__((used)) static const char AevonPreBindCancelV330Marker[] = "AevonPreBindCancelV330";
__attribute__((used)) static const char AevonSwallowTickV330Marker[] = "AevonSwallowTickV330";

/* V0.3.31（Aevon(104)「全屏还是被带动 + 圆盘两秒后才出现」）：吞层回喂。
 * 吞层丢掉一帧 moved 的同时把它转手喂给自建识别器 —— App 拿不到位移，判据也不缺帧。
 * Aevon(104) 定量：31 次 hold、**0 次**自建腿召唤、21 次全部系统腿呼盘、圆盘时差下限
 * 恰为 ownPass 的 0.28s ⇒「吞层的粒度是整条 UIEvent，它把识别器自己也饿死了」。 */
__attribute__((used)) static const char AevonSwallowFeedV331Marker[] = "AevonSwallowFeedV331";

/* V0.3.32（Aevon(105)「抖音中触发圆盘时还是会让抖音页面左滑」）：**落指扣住**。
 *
 * 0.3.31 把 moved 全堵住了（吞层实丢 42~220 帧、中位 97），但 App 手里还剩两帧：
 * began(落点) 与 ended(**终点**)。零 moved 骗不过滚动视图，可「起止坐标差 ~100pt」
 * 本身就是一次横滑 —— 抖音左滑进博主主页就是靠它判的。
 *
 * 这一版让 App **一帧都拿不到**：began 先扣住不投递（同时外部喂给自建腿），
 * 55ms 内判出召唤 → 这段 began 永不回放、之后所有帧（含 ended）一律丢弃；
 * 没判出 → 原样回放 + 自建腿退出本轮（绝不半路改吞）。点击与纵向滚动因此不受影响。
 * 同时把系统边缘手势腿的吊销点从「达阈值」提前到 **Began**。 */
__attribute__((used)) static const char AevonHeldBeginV332Marker[] = "AevonHeldBeginV332";
__attribute__((used)) static const char AevonHeldReplayV332Marker[] = "AevonHeldReplayV332";
__attribute__((used)) static const char AevonSysLegRevokeV332Marker[] = "AevonSysLegRevokeV332";

/* V0.3.27（Aevon(100) #1「桌面和全屏 app 中手势触发并不是 100% 成功」）：
 * App 内锥角 14° → 22°（可配，`AevonGripCone327`），并在首帧判不出横向时再看 2 帧
 * （`AevonGripWidenOff327` 可关）。桌面判据一律不动。 */
__attribute__((used)) static const char AevonGripConeV327Marker[] = "AevonGripConeV327";
__attribute__((used)) static const char AevonGripWidenV327Marker[] = "AevonGripWidenV327";
