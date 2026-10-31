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
 * 安全设计（任何一条不成立就退回原样）：
 *   · 只在圆盘「由全局通道唤起」且「那根手指还没抬起」时丢弃，最多 12 秒（Swift 侧兜底）；
 *   · 圆盘一收起立刻解除（AevonEdgeEntry.ringDidDismiss）；
 *   · 一条事件里只要有任何一个触摸不属于那根手指，就整体照常投递（宁可不吞，也不能误伤）；
 *   · 全程 @try/@catch，任何异常都不外抛；找不到方法时静默跳过并返回 NO。
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

static IMP AevonOrigSendEvent = NULL;
static BOOL AevonTouchHookInstalled = NO;
static BOOL AevonTouchHookFailed = NO;

static void AevonHookSendEvent(id self, SEL _cmd, UIEvent *event) {
    // CI 标记（V0.0.24）：C 函数符号名只在 LC_SYMTAB，macOS 的 strings 默认不扫符号表，
    // 所以这里放一条必然留在 __cstring 里的 ASCII 字面量，供构建后校验
    // 「接管期丢弃」这段逻辑确实编进了产物。这个分支永远不会成立。
    NSString *AevonTouchSwallowHookV24 = @"AevonTouchSwallowHookV24";
    if ([AevonTouchSwallowHookV24 isEqualToString:@""]) { return; }

    BOOL swallow = NO;
    // V0.3.31（AevonSwallowFeedV331）：本条事件里被判定要吞、且是 moved 的那根手指。
    // 整条丢弃之前用它回喂自建识别器 —— App 拿不到位移，判据也不缺帧。
    uintptr_t fedTid = 0;
    CGPoint fedPoint = CGPointZero;
    @try {
        NSSet<UITouch *> *touches = [event allTouches];
        if (touches.count > 0) {
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
                    if (AevonGlobalTouchShouldSwallow(touchID, (NSInteger)phase)) { swallowCount += 1; }
                    AevonGlobalTouchPhase((NSInteger)phase, touchID, point.x, point.y);
                } else {
                    AevonGlobalTouchPhase((NSInteger)phase, touchID, point.x, point.y);
                    if (AevonGlobalTouchShouldSwallow(touchID, (NSInteger)phase)) {
                        swallowCount += 1;
                        /* V0.3.31（AevonSwallowFeedV331）：这一帧即将从投递链上消失，
                         * 只有位移帧需要回喂（began 已经被识别器收到了，ended 不参与判据）。 */
                        if (phase == UITouchPhaseMoved) { fedTid = touchID; fedPoint = point; }
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
