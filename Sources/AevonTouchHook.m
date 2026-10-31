#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/*
 * 全局触摸通道（V0.0.23 建立，V0.0.24 增加「接管期丢弃」）。
 *
 * 为什么必须下沉到这一层：
 *   Aevon(16) 日志的证据是「右侧白条可见、但 App 前台整场零『手势区收到触摸』」，
 *   而同一时刻悬浮球（同一个容器里的兄弟视图）点击是好的 —— 说明容器本身在 App 画面里，
 *   只是 `SBDeviceApplicationSceneViewController.view` 的命中测试把靠右边缘的触摸
 *   直接交给了 App 画面，我们的手势条永远排不上队。
 *   继续在视图层调几何 / 调层级都无解，只能从事件总入口拿。
 *
 * V0.0.24 为什么还要「丢弃」：
 *   Aevon(17) 用户反馈「圆盘能呼出了，但滑圆盘时前台 App 跟着一起动」。
 *   原因就是上面那条：这根手指的事件**同时**被 App 收了 —— 我们从旁路过看得到坐标，
 *   但事件本身照旧投递给 App，于是 App 跟着滚屏 / 翻页。
 *   所以当圆盘由全局通道唤起、并且还压着这根手指时，Swift 侧会告诉这里「这根 touch 要吞」，
 *   这一条事件就不再调用原实现（App 收不到），圆盘靠全局通道自己完成旋转 / 选定 / 开窗。
 *
 * V0.3.32 为什么还要「扣住 began」：
 *   0.3.31 把 moved 全吞了（实丢 42~220 帧），App 手里只剩 began 与 ended 两帧；
 *   而 ended 带的是抬手那一刻的**终点坐标**。零 moved 骗不过滚动视图，但「按下(425,750)
 *   → 抬起(≈330,690)」这一对本身就是一次横滑 —— 抖音左滑进博主主页就是靠它判的。
 *   要彻底消掉只能让 App 一帧都拿不到，于是 began 也先扣住，窗口内判出召唤就永不回放。
 *
 * V0.3.33 为什么把窗口从 55ms 提到 110ms：
 *   Aevon(106) 的 42 次 hold 里，29 次完美（App 零帧，吞层实丢中位 97 帧）、13 次回放。
 *   把 41 次真实滑动的「落指 → 首帧位移帧」排开，是干净的两群：
 *     · 完美群 7~55ms（中位 23ms）；
 *     · 回放群 57~100ms（中位 77ms）—— 全是「落指后手停了 60~100ms 才开始动」的慢起手。
 *   55ms 这道墙正好落在两群中间，把这 13 次误判成点击回放，其中 12 次在回放后 9~46ms
 *   就召唤了：那些轮的 `吞层实丢` 恒为 1（只有 began 一条），后续 71~197 个 moved 帧
 *   全部投给了 App = 完整滑动泄漏。真点击全程只有 1 次，所以抬高窗口的代价接近零：
 *   点击走 `heldAbort`（抬手即回放），根本不经过这个窗口。
 *   再加一档「已见到位移帧 → 再等 60ms」，专门兜「110ms 时已在滑但还没到 8pt」的极端慢手。
 *
 * 安全设计（任何一条不成立就退回原样）：
 *   · 只在圆盘「由全局通道唤起」且「那根手指还没抬起」时丢弃，最多 12 秒（Swift 侧兜底）；
 *   · 圆盘一收起立刻解除（AevonEdgeEntry.ringDidDismiss）；
 *   · 一条事件里只要有任何一个触摸不属于那根手指，就整体照常投递（宁可不吞，也不能误伤）；
 *   · 全程 @try/@catch，任何异常都不外抛；找不到方法时静默跳过并返回 NO；
 *   · 扣住窗口 110ms（+60ms 延长一档），右上方 y ≤ 140 的区域（控制中心下拉）一律不扣。
 */

extern void AevonGlobalTouchPhase(NSInteger phase, uintptr_t touchID, CGFloat x, CGFloat y);
// V0.1.12（AevonBandHoldMovedV112）：多带一个阶段。
//
// 为什么要带阶段：右缘起手窗（20~46pt）以前是「began 照给 App、等看清方向才吞」，
// 于是 App 在判定期里已经吃到 6pt 横向位移，偶发的快速/斜向起手会让它自己的横滑手势成立
// —— 这就是「偶尔触发抖音进度条」。新策略是「began 照给 App，但移动帧先扣住」：
// 方向不明时移动帧不投递（App 累计位移始终为 0，横滑手势立不起来），
// 一旦看清是纵向滚动 / 向右扫就立刻放行（App 拿到后续移动帧照样能滚，只晚一两帧），
// 看清是向左横扫就整根接管。抬手帧必须放行，否则 App 那边会留下没有任何后续的孤儿 touch。
// 所以判定函数必须知道这是哪一阶段 —— 只凭 touchID 分不出 began / moved / ended。
extern BOOL AevonGlobalTouchShouldSwallow(uintptr_t touchID, NSInteger phase);
// V0.3.30（AevonEarlyBindV330）：吞帧计数 —— 每真的丢弃一次事件就 +1。
//
// 为什么要它：0.3.29 的日志能证明「绑定成功 36/36」，却**证不出吞层真的吞掉过一帧** ——
// 绑定与吞帧之间没有可观测点。Aevon(103) 就卡在这里：现象变差，日志一片绿。
// 计数由自建腿在 `-touchesBegan:` 归零、抬手时打进 lift 日志，一次就能分清
// 「绑定白做了」和「绑定生效但晚了一帧」。
extern void AevonGripOwnSwallowTick(void);

// V0.3.31（AevonSwallowFeedV331）：吞层回喂 —— 这一帧被丢弃，同时转手喂给自建识别器。
// 没有它，`-sendEvent:` 的丢弃会把自建识别器也一起饿死（Aevon(104)：31 次 hold、
// 0 次自建腿召唤、圆盘时差下限恰为 ownPass 的 0.28s），圆盘最后靠系统腿呼出、
// 走「收养」分支（只喂不吞），App 就拿到了剩余整段滑动。
extern void AevonGripOwnExternalMove(uintptr_t tid, double x, double y);

// V0.3.32（AevonHeldBeginV332）：扣住 began 之后的三件事 —— 外部喂落指、退出本轮、外部收尾。
extern int  AevonGripOwnExternalBegin(uintptr_t tid, double x, double y);
extern void AevonGripOwnDisarm(void);
extern void AevonGripOwnExternalEnd(double x, double y);
extern int  AevonGripOwnSummonedFlag(void);
extern void AevonGripOwnNote(const char *tag, const char *detail);

static IMP AevonOrigSendEvent = NULL;
static BOOL AevonTouchHookInstalled = NO;
static BOOL AevonTouchHookFailed = NO;

/* ---------------------------------------------------------------------------
 * V0.3.32（AevonHeldBeginV332）：落指扣住状态。
 *
 * `gAevonHeldEvent` 是**强引用**：扣住期间这条 `UIEvent` 必须活着，窗口到点后可能要用它
 * 调原 `sendEvent:` 回放。回放失败（event 已失效 / UIKit 抛异常）时只放弃这一次点击，
 * 绝不向 SpringBoard 冒泡 —— 那样是 SIGABRT。
 *
 * 三个状态：
 *   扣住中（HeldEvent != nil, !Committed）→ 等窗口超时，或等判出召唤；
 *   已召唤（Committed = YES, HeldEvent = nil）→ 这根手指的所有帧全丢，含 ended；
 *   已回放（HeldEvent = nil, Committed = NO）→ 一切照旧，App 该收什么收什么。
 * ------------------------------------------------------------------------- */
static __unsafe_unretained UIApplication *gAevonHeldApp = nil;
static UIEvent *gAevonHeldEvent = nil;
static uintptr_t gAevonHeldTid = 0;
static CGPoint gAevonHeldPoint = {0, 0};
static CFTimeInterval gAevonHeldAt = 0;
static BOOL gAevonHeldCommitted = NO;
static NSUInteger gAevonHeldDropped = 0;

/* V0.3.33（AevonHeldSawMoveV333）：扣住期间有没有见到过被吞的位移帧。
 * 这是「慢起手」与「点击」唯一可观测的分界线 —— 抬手的 `heldAbort` 不看它，
 * 只有窗口到点时才用它决定「再等一档」还是「回放」。 */
static BOOL gAevonHeldSawMove = NO;
static BOOL gAevonHeldExtended = NO;

/// 扣住窗口。110ms ≈ 7 帧 @60Hz：Aevon(106) 实测「落指 → 首帧位移帧」P100 = 100ms
///（完美群中位 23ms、回放群中位 77ms），110ms 覆盖到 P100 且留 10ms 余量。
/// 真人最短的一次点击（~60~120ms）不受影响 —— 抬手走 `heldAbort`，根本不等这个窗口。
static const double kAevonHeldWindow = 0.110;

/// 延长档（AevonHeldExtendV333）：窗口到点但本手势已有位移帧 → 再等这么久判 8pt。
/// 最多延一次，总上限 170ms；到点仍未召唤照样回放，绝不无限扣住。
static const double kAevonHeldExtend = 0.060;

/* CI 标记（V0.3.33）：单独一条纯 ASCII 串，不夹在任何中文里 ——
 * 中文 `@"…"` 是 UTF-16、注释永不进二进制，只有纯 ASCII 的 C 串才必然落进 `__cstring`。 */
__attribute__((used, unused)) static const char AevonHeldWindowV333[] = "AevonHeldWindowV333";
__attribute__((used, unused)) static const char AevonHeldExtendV333[] = "AevonHeldExtendV333";
__attribute__((used, unused)) static const char AevonHeldSawMoveV333[] = "AevonHeldSawMoveV333";

static void AevonHeldResetState(void) {
    gAevonHeldEvent = nil;
    gAevonHeldTid = 0;
    gAevonHeldCommitted = NO;
    gAevonHeldDropped = 0;
    gAevonHeldSawMove = NO;
    gAevonHeldExtended = NO;
}

/// 把扣住的那条 began 原样回放给 UIKit，并让自建腿退出本轮。
/// 回放失败只放弃这一次点击，绝不向 SpringBoard 冒泡（那里抛异常就是 SIGABRT）。
static void AevonHeldReplayNow(const char *why) {
    UIEvent *event = gAevonHeldEvent;
    __unsafe_unretained UIApplication *app = gAevonHeldApp;
    gAevonHeldEvent = nil;
    gAevonHeldTid = 0;
    gAevonHeldDropped = 0;
    if (event == nil) { return; }
    @try {
        AevonGripOwnDisarm();
        if (AevonOrigSendEvent != NULL && app != nil) {
            ((void (*)(id, SEL, UIEvent *))AevonOrigSendEvent)(app, @selector(sendEvent:), event);
            AevonGripOwnNote("held", why);
        }
    } @catch (NSException *exception) {
        AevonGripOwnNote("held", "回放失败（异常）→ 放弃这根手指，绝不崩 SpringBoard"
                                 "（AevonHeldReplayV332）");
    }
}

/// 窗口到点：还没判出召唤 = 不是呼盘手势（点击 / 纵向滚动 / 起手太靠内）→ 原样回放。
///
/// 回放前必须 `AevonGripOwnDisarm()`：让自建腿彻底退出这根手指，之后它的帧一路正常投递。
/// 不退出就是 0.3.3 铁律说的「began 放行、中途改吞」—— App 收不到终止帧，
/// `UIScrollView` 的触摸延迟队列永久挂起，整个 App 卡屏。
static void AevonHeldTimerFired(void) {
    if (gAevonHeldEvent == nil || gAevonHeldCommitted) { return; }
    /* V0.3.33（AevonHeldExtendV333）：窗口到点但**已经见到位移帧** → 这是慢起手，不是点击。
     * 再给一档，最多一次。Aevon(106) 的 13 次回放里 12 次在回放后 9~46ms 就召唤了，
     * 全部属于这一类；这一档把它们从「回放」挪回「判出召唤」。 */
    if (gAevonHeldSawMove && !gAevonHeldExtended) {
        gAevonHeldExtended = YES;
        AevonGripOwnNote("held", "窗口到点但已有位移帧 → 再等 60ms 判 8pt"
                                 "（AevonHeldWindowV333 AevonHeldExtendV333"
                                 " AevonHeldSawMoveV333）");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kAevonHeldExtend * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AevonHeldTimerFired();
        });
        return;
    }
    AevonHeldReplayNow("窗口内未召唤 → 已回放 began（App 照常收到这一下）"
                       "（AevonHeldReplayV332）");
}

static void AevonHookSendEvent(id self, SEL _cmd, UIEvent *event) {
    // CI 标记（V0.0.24）：C 函数符号名只在 LC_SYMTAB，macOS 的 strings 默认不扫符号表，
    // 所以这里放一条必然留在 __cstring 里的 ASCII 字面量，供构建后校验
    // 「接管期丢弃」这段逻辑确实编进了产物。这个分支永远不会成立。
    NSString *AevonTouchSwallowHookV24 = @"AevonTouchSwallowHookV24";
    if ([AevonTouchSwallowHookV24 isEqualToString:@""]) { return; }

    BOOL swallow = NO;
    uintptr_t fedTid = 0;
    CGPoint fedPoint = CGPointZero;
    BOOL heldRelease = NO;
    BOOL heldAbort = NO;
    CGPoint releasePoint = CGPointZero;

    /* 已召唤状态卡住超过 3s（抬手帧被系统吞掉 / App 被切走）→ 自己松绑，
     * 否则后面每一次右缘落指都不再走扣住这条路，行为静默退回 0.3.31。 */
    if (gAevonHeldCommitted && gAevonHeldAt > 0 && CACurrentMediaTime() - gAevonHeldAt > 3.0) {
        AevonHeldResetState();
    }

    @try {
        NSSet<UITouch *> *touches = [event allTouches];
        if (touches.count > 0) {
            /* ── ① 落指扣住（V0.3.32）──
             * 单指 began、落点在右缘 40pt 内、y > 140（右上角控制中心下拉绝不扣）时，
             * 先问自建腿「这根手指归不归你」。归 → 这一帧不投递，留到窗口后再决定。 */
            if (gAevonHeldEvent == nil && !gAevonHeldCommitted && touches.count == 1) {
                UITouch *only = [touches anyObject];
                if (only.phase == UITouchPhaseBegan) {
                    CGPoint p = [only locationInView:nil];
                    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
                    if (p.y > 140.0 && p.x >= sw - 40.0) {
                        uintptr_t tid = (uintptr_t)(__bridge void *)only;
                        int claimed = 0;
                        @try {
                            claimed = AevonGripOwnExternalBegin(tid, (double)p.x, (double)p.y);
                        } @catch (NSException *exception) {
                            claimed = 0;
                        }
                        if (claimed) {
                            gAevonHeldApp = [UIApplication sharedApplication];
                            gAevonHeldEvent = event;
                            gAevonHeldTid = tid;
                            gAevonHeldPoint = p;
                            gAevonHeldAt = CACurrentMediaTime();
                            gAevonHeldCommitted = NO;
                            gAevonHeldDropped = 0;
                            gAevonHeldSawMove = NO;
                            gAevonHeldExtended = NO;
                            /* Swift 侧（圆盘指针 / 吞层簿记）照样要看到这一帧，
                             * 看不到的只有 App —— 这正是本版和 0.3.31 的全部差别。 */
                            AevonGlobalTouchPhase((NSInteger)only.phase, tid, p.x, p.y);
                            AevonGlobalTouchShouldSwallow(tid, (NSInteger)only.phase);
                            /* 这一帧同样没投给 App，计入「吞层实丢」，让 lift 日志的
                             * 数字等于「App 一共少看见几帧」。 */
                            AevonGripOwnSwallowTick();
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                         (int64_t)(kAevonHeldWindow * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                AevonHeldTimerFired();
                            });
                            return;
                        }
                    }
                }
            }

            NSInteger active = 0;
            NSInteger swallowCount = 0;
            for (UITouch *touch in touches) {
                UITouchPhase phase = touch.phase;
                if (phase != UITouchPhaseBegan && phase != UITouchPhaseMoved &&
                    phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled) {
                    continue;
                }
                active += 1;
                uintptr_t touchID = (uintptr_t)(__bridge void *)touch;
                // `locationInView:nil` 返回触摸所在窗口的坐标（窗口全屏，等价屏幕坐标）
                CGPoint point = [touch locationInView:nil];
                /* V0.3.32：已判出召唤的那根手指 —— 连抬手帧也一起丢。
                 * 0.3.30 起抬手帧是显式放行的，泄漏就是从这一帧的终点坐标来的。 */
                BOOL forceHeld = (gAevonHeldCommitted && gAevonHeldTid != 0 && touchID == gAevonHeldTid);
                /*
                 * 顺序很重要（V0.0.25）：
                 *   · began / moved —— **先上报再询问**。Swift 侧要在 begun 时就登记
                 *     「这根手指归我」，紧接着的询问才会对 began 这一帧也返回 YES，
                 *     这样 App 连 began 都收不到，前台 App 不会再跟着滑。
                 *   · ended / cancelled —— **先询问再上报**。上报会把「归我」状态清掉，
                 *     先问才能把这一次抬手也挡在 App 外面（不会留下孤儿 ended）。
                 */
                BOOL isRelease = (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled);
                if (isRelease) {
                    if (forceHeld || AevonGlobalTouchShouldSwallow(touchID, (NSInteger)phase)) {
                        swallowCount += 1;
                    }
                    AevonGlobalTouchPhase((NSInteger)phase, touchID, point.x, point.y);
                    if (forceHeld) { heldRelease = YES; releasePoint = point; }
                    /* 还没判出就抬了（快速点击）→ 立刻回放扣住的 began，再把这条 ended
                     * 正常投递。不回放 = 带内点击凭空消失；顺序也不能反（先 ended 后
                     * began 就是一条孤儿）。 */
                    if (!forceHeld && gAevonHeldEvent != nil && !gAevonHeldCommitted
                        && gAevonHeldTid != 0 && touchID == gAevonHeldTid) {
                        heldAbort = YES;
                    }
                } else {
                    AevonGlobalTouchPhase((NSInteger)phase, touchID, point.x, point.y);
                    if (forceHeld || AevonGlobalTouchShouldSwallow(touchID, (NSInteger)phase)) {
                        swallowCount += 1;
                        /* V0.3.31（AevonSwallowFeedV331）：这一帧即将从投递链上消失，
                         * 只有位移帧需要回喂（began 已被识别器收到，ended 不参与判据）。 */
                        if (phase == UITouchPhaseMoved) { fedTid = touchID; fedPoint = point; }
                        /* V0.3.33：见位移帧 → 窗口到点改走延长档。
                         * 不并进上一行：那行的字面量是 V0.3.31 的 CI 锚点。 */
                        if (phase == UITouchPhaseMoved && gAevonHeldEvent != nil
                            && !gAevonHeldCommitted) {
                            gAevonHeldSawMove = YES;
                        }
                    }
                }
            }
            // 整条事件的所有活动触摸都属于「被圆盘接管的那根手指」才丢弃；
            // 只要混进了别的手指就原样投递，绝不误伤其他触摸。
            if (active > 0 && swallowCount >= active) { swallow = YES; }
        }
    } @catch (NSException *exception) {
        // 私有路径出错绝不影响 SpringBoard
        swallow = NO;
    }
    /* 快速点击（窗口内就抬了）：先按原顺序把扣住的 began 补投，再照常投递这条 ended。
     * 两条都到齐，App 看到的是一次完整的点击 —— 这是「扣住 began」必须付的代价里
     * 唯一不能妥协的那一条。 */
    if (heldAbort) {
        AevonHeldReplayNow("落指窗口内抬了（点击）→ 已回放 began，点击照常送达"
                           "（AevonHeldReplayV332）");
        if (AevonOrigSendEvent) {
            ((void (*)(id, SEL, UIEvent *))AevonOrigSendEvent)(self, _cmd, event);
        }
        return;
    }
    if (swallow) {
        /* V0.3.30（AevonEarlyBindV330）：真的丢弃了才 +1（判断之外不计数）。 */
        AevonGripOwnSwallowTick();
        /* V0.3.31（AevonSwallowFeedV331）：丢掉的这一帧转手喂给自建识别器。
         * 必须在 `return` 之前、且只在真的丢时喂 —— 没丢时识别器会自己从 UIKit 收到，
         * 这里再喂一次就是重复计位移（8pt 会被提前判成 4pt 达到）。
         * ⛔ 必须自己包 `@try`：这一段在上一层的 @try 之外，回喂会走到
         * `ownSummonAtPoint:` → 私有断言接口 / 识别器 state 变更，抛 NSException
         * 在 SpringBoard 里就是 SIGABRT。回喂失败只丢一次判定，不能拖垮进程。 */
        if (fedTid != 0) {
            @try {
                AevonGripOwnExternalMove(fedTid, (double)fedPoint.x, (double)fedPoint.y);
            } @catch (NSException *exception) {
                // 回喂失败 = 这一帧判据丢了，下次同构手势照常；绝不向 SpringBoard 冒泡
            }
        }
        /* V0.3.32：扣住的那条 began 要不要回放，就在这一刻定。
         * 判出召唤 → 永不回放（App 连落指帧都没见过，起止坐标差这条泄漏彻底消失）。 */
        if (gAevonHeldEvent != nil && !gAevonHeldCommitted) {
            int summoned = 0;
            @try { summoned = AevonGripOwnSummonedFlag(); } @catch (NSException *exception) { summoned = 0; }
            if (summoned) {
                gAevonHeldCommitted = YES;
                gAevonHeldEvent = nil;      // 强引用放掉：这段 began 从此不存在
                AevonGripOwnNote("held", "判出召唤 → 扣住的 began 永不回放，App 全程零帧"
                                         "（AevonHeldBeginV332）");
            }
        }
        if (heldRelease) {
            /* 已召唤手指的抬手帧：外部收尾（lift 信号 + 清自建腿簿记），然后整个丢弃。
             * 这根手指从头到尾没进过 UIKit 的触摸序列，`-reset` 不会来 —— 不清场就是
             * 「呼完一次盘，两秒半内怎么划都没反应」。 */
            @try {
                AevonGripOwnExternalEnd((double)releasePoint.x, (double)releasePoint.y);
            } @catch (NSException *exception) {
            }
            AevonGripOwnNote("held", "抬手帧一并丢弃：App 全程未见这根手指"
                                     "（AevonHeldBeginV332）");
            AevonHeldResetState();
        }
        return;
    }
    if (AevonOrigSendEvent) {
        ((void (*)(id, SEL, UIEvent *))AevonOrigSendEvent)(self, _cmd, event);
    }
}

/// 找到「真正自己实现了 sendEvent:」的那个类：SpringBoard 的 app 类是 UIApplication 的子类，
/// 只改父类可能与子类实现无关，所以沿继承链往上找第一个自有实现。
static Class AevonFindSendEventOwner(Class start) {
    Class current = start;
    while (current != Nil && current != [NSObject class]) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        BOOL found = NO;
        if (methods != NULL) {
            for (unsigned int i = 0; i < count; i++) {
                if (method_getName(methods[i]) == @selector(sendEvent:)) { found = YES; break; }
            }
            free(methods);
        }
        if (found) { return current; }
        current = class_getSuperclass(current);
    }
    return Nil;
}

BOOL AevonTouchHookInstall(void) {
    if (AevonTouchHookInstalled) { return YES; }
    if (AevonTouchHookFailed) { return NO; }
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) { AevonTouchHookFailed = YES; return NO; }
        Class owner = AevonFindSendEventOwner(object_getClass(app));
        if (owner == Nil) { owner = [UIApplication class]; }
        Method method = class_getInstanceMethod(owner, @selector(sendEvent:));
        if (method == NULL) { AevonTouchHookFailed = YES; return NO; }
        AevonOrigSendEvent = method_setImplementation(method, (IMP)AevonHookSendEvent);
        AevonTouchHookInstalled = (AevonOrigSendEvent != NULL);
        return AevonTouchHookInstalled;
    } @catch (NSException *exception) {
        AevonTouchHookFailed = YES;
        return NO;
    }
}
