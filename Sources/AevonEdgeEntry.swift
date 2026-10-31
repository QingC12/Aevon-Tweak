import UIKit

/// 全局触摸通道（V0.0.23 建立）：浮窗手势状态机 + 圆盘指针喂料。
///
/// **0.2.51（AevonGripOnlyV251）大裁剪** —— 用户 Aevon(26) 定档：
/// 「移除现在的所有圆盘触发手势代码和开关，只保留新添加的圆盘把手」。
/// 本文件里所有为「边缘手势呼盘」服务的机制全部移除：
///   · 可见手势条（`AevonEdgeStripView`）与触发区几何（`AevonTriggerZone`）及其设置轮询；
///   · 右缘接管带（`AevonRightEdge` / bandHold 扣移动帧 / 按下即接管）；
///   · 桌面热区观察呼盘（贴边横拉判向，AevonDeskZoneObserve 一族）；
///   · 系统手势管线通道（AevonSystemGestureV104 / AevonSysEdgeV213 / SysEdgeShim，文件已删）；
///   · App 侧右缘识别器与全部判向通知桥（rightedgetrigger / began / fail / appready，
///     App 侧 AevonAppTakeoverGesture 一并删除）；
///   · 三指急救 / 死手开关（它们救护的对象「接管带吞死系统手势」已不存在）。
/// 依据：PullOver 逆向定论 ——「空白盲带没有中间态，唯一干净的路是放一个真实控件」。
/// 呼盘入口只剩 `AevonRingGrip`（可见把手，命中区外扩、把手外一律不拦）；
/// 把手是真实控件，hitTest 天然赢，不需要任何吞摸 / 判向 / 补投。
///
/// 现在只剩三件事：
///   ① **浮窗手势状态机**（V0.0.41）：窗外边条 / 角块落指即拖、缩放、底边双击关闭、
///      左右缘**轻点** = 停靠 / 装回（0.2.51，AevonDockTapV251，用户 Aevon(26) #1）；
///   ② **圆盘指针喂料**：把手呼盘后那根手指的 moved / ended 由这里继续喂圆盘
///      （滑到图标上松手 = 开窗，松在别处 = 收起）；
///   ③ **圆盘状态位**：共享内存 notify bit + Darwin 广播（留给下一轮「重新制作
///      触发圆盘的功能」复用）。
enum AevonEdgeEntry {
    private static var globalInstalled = false
    private static var prefsObserverInstalled = false
    private static var picker: AevonAppPickerView?
    private static var globalLastLogAt: CFTimeInterval = 0

    // MARK: - 圆盘指针状态（喂料 / 收养 / 自愈）

    private static var ringSource = ""
    private static var globalTouchID: UInt = 0
    private static var globalStart: CGPoint = .zero
    private static var globalFired = false
    private static var ownsTouch = false
    private static var swallowDeadline: CFTimeInterval = 0
    private static let swallowLimit: CFTimeInterval = 12
    private static var ringExtraTouchID: UInt = 0
    private static var ringExtraDeadline: CFTimeInterval = 0
    private static var appEdgePointerAdopted = false
    /// 最近一次边缘触摸的位置（窗口坐标），圆盘唤出时从这里接手那根手指
    private static var lastTouchPoint: CGPoint = .zero
    private static var lastTouchAt: CFTimeInterval = 0
    private static var globalOwnedAt: CFTimeInterval = 0
    private static var globalOwnedForTouch: UInt = 0
    private static let globalOwnHardLimit: CFTimeInterval = 12
    private static let healIdleWindow: CFTimeInterval = 1.5
    /// V0.3.29（AevonOwnSwallowV329）：当前这根被吞的手指是否是**自建腿召唤来的**。
    /// 为真时：`remoteMoved` 走权威通道（保住 0.3.17 的跟手质量），
    /// 并且「收养」分支不许把它降级成「只喂不吞」。
    private static var ownSwallowBound = false
    /// V0.3.30（AevonEarlyBindV330）：落指预绑的手指身份。
    ///
    /// 0.3.29 只在 `presentRing` 里绑，而 `presentRing` 是自建识别器判定成功之后才调的 ——
    /// 吞层判据挂在 SB `-sendEvent:`，识别器是在同一次 `sendEvent:` 内部才判定的，
    /// 于是「began + 首帧 moved」必然先投给 App。Aevon(103) 量出来首帧位移中位 18pt、
    /// 最大 49pt，App 拿到的是一个高速横向帧后彻底静止（ScrollView 拿它算惯性、
    /// 抖音拿它判横滑）—— 这就是「呼出圆盘时 App 内被带动」的全部来源。
    ///
    /// 预绑把「开始吞」从召唤提前到落指：下一帧 moved 的询问就能命中，漏的只剩
    /// began 这一帧（零位移）。召唤时只做「转正」，不重绑。
    /// 0 = 当前没有预绑。由 ended / cancelled / `-ownPass:` 三条路清掉。
    private static var preBindTid: UInt = 0
    /// 预绑的起始时刻（只用于日志与超时兜底）。
    private static var preBindAt: CFTimeInterval = 0
    /// 预绑失效上限：超过它还没等到召唤 / 抬手，就当没预绑（fail-open）。
    private static let earlyBindLimit: CFTimeInterval = 4
    /// 预绑日志限流计数（同类只打前 6 条，与 `AevonOwnPassCount` 同风格）。
    private static var preBindLogCount = 0
    private static var lastHealLogAt: CFTimeInterval = 0
    /// V0.2.55（AevonGripHealV255）：吞咽日志节流
    private static var lastSwallowLogAt: CFTimeInterval = 0
    /// V0.2.86（AevonRingMissLogV286）：圆盘展开中「手指没被吞」的上一次日志时刻（节流用）
    private static var lastRingMissLogAt: CFTimeInterval = 0
    /// V0.2.56（AevonDedupBeganV256）：重投 began 静默消费的节流日志
    private static var lastDedupLogAt: CFTimeInterval = 0
    // V0.2.57（AevonZombieSealV257）：被吞过 began 的触摸「终身封印」状态。
    private static var zombieSealID: UInt = 0
    private static var zombieSealUntil: CFTimeInterval = 0
    // V0.2.58（AevonGripFeedCleanV258）：把手收养指纹 —— began 已投递过 UIKit 的那根。
    // Aevon(32) 定论：把手是真实控件，滑动呼盘那根手指的 began 在圆盘展开前就已
    // 投递 UIKit；旧逻辑却把它的 moved / ended 全吞（圆盘展开期吞 + 抬手帧也吞）
    // = 每次滑动呼盘给 UIKit 留一根「有 began 无 ended」的在途触摸，把手 pan
    // 识别器收不到收尾帧。0.2.49 结构干净的根本原因：呼盘走纯 sendEvent 通道，
    // began 也吞，整根触摸对 UIKit 不可见。这根手指的触摸窗口在 begin 时刻就
    // 绑定入口窗口（UIKit 规则永不改绑），moved/ended 投递只可能到达把手自己的
    // 识别器，物理上不可能漏给桌面 / App —— 全程放行是零风险补全。
    private static var gripAdoptedTouchID: UInt = 0
    /// V0.2.8（AevonSelectionCoolV208）：圆盘选中开窗后 1.5 秒冷静期（防双呼）
    private static var selectionCoolUntil: CFTimeInterval = 0
    private static var lastTriggerAt: CFTimeInterval = 0
    private static let pressLimit: CFTimeInterval = 4

    // MARK: - 浮窗手势状态机（V0.0.41，AevonFloatGlobalV41）

    private static var floatTouchID: UInt = 0
    private static var floatWindow: AevonWindowView?
    private static var floatGrab: AevonFloatGrab?
    private static var floatDeadline: CFTimeInterval = 0
    private static let floatDragLimit: CFTimeInterval = 30
    /// V0.2.55（AevonGripHealV255）：最后一次浮窗拖拽 moved 的时刻。
    /// 抬手帧万一没送到（sendEvent 链路任何一环丢帧），floatTouchID 会带着 30 秒
    /// deadline 残留 —— 而 touchID 就是 UITouch 指针，UIKit 的触摸槽位会复用地址，
    /// 同一根手指的下一次滑动会被误判成「拖拽中」整段吞掉（began 放行、moved 全吞
    /// = pan 死、点按活的经典形态）。这里记录 moved 时刻，自愈检查里 2 秒没动静
    /// 就强制清场（Aevon(29) 手势失效的头号可自愈嫌疑）。
    private static var lastFloatMovedAt: CFTimeInterval = 0
    /// V0.2.21（AevonFloatBarHoldV221）：边条「落指即拖」的延迟与误触半径
    private static var floatBarPending = false
    private static var floatBarHoldPoint: CGPoint = .zero
    private static var floatBarHoldDeadline: CFTimeInterval = 0
    private static let floatBarHoldDelay: CFTimeInterval = 0
    private static let floatBarHoldRadius: CGFloat = 18
    /// V0.3.25（AevonBottomSplitV325）：底边「移动 + 长按后上甩关闭」的状态。
    ///
    /// Stheno 实证（ScreenCore.dylib `sc_addTerminationGestureToRegion:` 0x34cf4 /
    /// `sc_shouldCloseForBottomUpwardFlick:` 0x38444）：底边属于
    /// `ScreenCore.Split.BottomMoveClose` —— **移动和关闭共存**；关闭手势是
    /// UILongPressGestureRecognizer（0.4s / 12pt），手一动就 fail 让 pan 拿回移动权。
    /// 全局通道拿不到 UIGestureRecognizer 的 velocity，速度用「最后一段位移 / 耗时」换算。
    private static var floatTermCandidate = false
    private static var floatTermArmed = false
    private static var floatTermBeganAt: CFTimeInterval = 0
    private static var floatTermPoint: CGPoint = .zero
    private static var floatTermLastPoint: CGPoint = .zero
    private static var floatTermLastAt: CFTimeInterval = 0
    private static let floatTermHold: CFTimeInterval = 0.4
    private static let floatTermSlop: CGFloat = 12
    private static let floatTermLift: CGFloat = 24
    private static let floatTermVelocity: CGFloat = 260
    private static let floatTermCone: CGFloat = 1.35
    /* V0.3.26（AevonTermWinVelV326 / AevonTermFollowV326，用户 Aevon(99) #1）：
     * 与视图侧 `AevonWindowView.terminationWindowVelocity()` 同源 —— 8 帧环形缓冲、
     * 取 ≤100ms 首尾两点算速度，替掉「最后一对采样」。0.3.25 那套的量化痕迹是
     * 125pt/s（= 10pt ÷ 0.08s）反复出现 8 次：手指在抬手前减速就被判死。
     * 另外三条出口（跟手短距快甩 48pt/200、大位移慢推 120pt）与视图侧完全一致。 */
    private static let floatTermFollowLift: CGFloat = 48
    private static let floatTermFollowVelocity: CGFloat = 200
    private static let floatTermBigLift: CGFloat = 120
    private static let floatTermWindow: CFTimeInterval = 0.10
    private static let floatTermWindowFrames = 8
    private static var floatTermTrack: [(CFTimeInterval, CGPoint)] = []

    /* V0.3.24（AevonBottomFlickV324）：双击候选三件套（floatLastTapAt / floatLastTapPoint
     * / floatLastTapWindow）与两个常量（floatDoubleTapGap / floatDoubleTapRadius）整体退役。
     * 底边双击 = 关闭浮窗的最后一个读取点（抬手分支）已随上滑关闭删除，这三件套
     * 从此没有任何读取者 —— 留着只会让后来者以为双击还在。 */
    /* V0.3.24（AevonBottomFlickV324）：floatBeganPoint 一并退役 —— 它唯一的读取者是
     * 「原地轻点才登记双击第一击」（moved <= 8），那段已随双击语义删除。 */

    // V0.2.60（AevonDockTapOnlyV260，用户 Aevon(34) #2）：停靠小窗「点一下装回」的
    // 全局兜底候选。停靠态我们不再接管、不再吞（四周边条手柄已在小窗侧摘除），
    // UIKit 的 dockTap 是主路；但全屏 App 之上 UIKit 未必收得到这根触摸，
    // 所以这里同时记一笔：没移动就抬手 = 装回，动了就作废（不做任何拖动语义）。
    private static var dockTapCandidateID: UInt = 0
    private static var dockTapCandidatePoint: CGPoint = .zero
    private static weak var dockTapCandidateWindow: AevonWindowView?

    // V0.2.60（AevonGripSwipeGlobalV260，用户 Aevon(34) #3）：把手滑动呼盘的全局通道。
    // Aevon(34)：「圆盘触发条只能在桌面触发，无法在全屏 App 中被触发」。
    // 根因是结构性的：把手是**视图**，而全屏 App 时触摸根本不进我们的视图树
    //（「全屏 App 时视图层收不到窗外的触摸」正是全局通道存在的原因）。
    // 所以把手滑动必须在 sendEvent 这条总入口上也判一次 —— 和浮窗边条同一条通路。
    // 纪律：只观察、不吞（铁律：不在别人的触摸上做吞咽），呼盘后由圆盘自己接管。
    private static var gripSwipeTouchID: UInt = 0
    /* V0.3.3（AevonGripIntentRetireV303，用户 Aevon(81)「不是只有抖音会卡屏，是所有的
     * 应用都会卡屏。触发圆盘手势、滑动手势条但不要让圆盘出现（滑动距离短时），然后
     * 全屏应用必然会卡住，无法操作」）：**AevonGripIntentV297 整条退役**（标记
     * AevonGripIntentV297 收容进本段说明与 V0.3.3 日志串里）。
     *
     * 0.2.97 那次「左滑意图吞咽」是**方向性错误**，也是 0.2.97~0.3.2 十一版卡屏的真凶：
     * 落指时 began 已经真实投给 App（backboardd 双投，见 0.2.63 注释），只吞后面的
     * moved/ended = App 拿到一根**永远不结束的 UITouch**。UIScrollView 的触摸延迟队列
     * 会一直等这根手指收尾 → 后续所有触摸被 delay → 整个 App 无响应（= 用户看到的卡屏）。
     * 抖音没被注入，它吃的正是这条；注入的 App 吃的是 App 侧那条（AevonRingSwallow2V271）。
     *
     * 铁律（V0.3.3 定档）：**一根手指的归属只在 began 那一帧决定，整根一致。**
     * 任何「began 放行、中途改吞」的写法都必然制造死锁，一律禁止。 */
    /// V0.2.63（AevonGripBusyV263）→ **V0.2.87（AevonGripBusyRetireV287）整条退役**：
    /// 「把手占用」广播（AevonNotifySetGripBusy）让被覆盖进程关交互 —— 0.2.86 已把
    /// App 侧接收链退役（AevonGripRetireV286：0.6→2.5s 续排 99 次占 3 次真解除=纯亏），
    /// SB 侧广播成了没人消费的废发，还唤醒一串旧库常驻进程白关一轮交互。
    /// 圆盘覆盖 App 的机制不变：bit39 共享内存状态位（AevonRingSwallow 通道）。
    private static var gripSwipeStart: CGPoint = .zero
    private static var lastGripSwipeLogAt: CFTimeInterval = 0

    /// 手势条已删除（0.2.51），入口可用性 = 全局通道已装（浮窗手势依赖它）。
    static var isVisible: Bool { return globalInstalled }

    /// V0.2.57（AevonTouchProbeV257）：探针取证用状态快照（纯位标志，无几何）。
    static var forensicStateText: String {
        let sealed = zombieSealID != 0 && CACurrentMediaTime() <= zombieSealUntil
        return "拖拽=\(floatGestureActive ? 1 : 0)/待定=\(floatBarPending ? 1 : 0)"
            + "/圆盘=\(AevonRingMenu.isPresented ? 1 : 0)/全局=\(globalTouchID != 0 ? 1 : 0)"
            + "/封印=\(sealed ? 1 : 0)/收养=\(gripAdoptedTouchID != 0 ? 1 : 0)"
    }

    /// 圆盘指针最近位置（AevonRingMenu 悬停高亮等要用）。
    static var currentPointerPoint: CGPoint { return lastTouchPoint }

    // MARK: - 安装

    /// 安装全局触摸通道（幂等）。这是浮窗手势与圆盘喂料的唯一基础设施。
    static func installGlobalTouch() -> Bool {
        if globalInstalled { return true }
        guard AevonPrefs.bool("Enabled", default: true) else { return false }
        // V0.0.26：设置变更通知（圆盘 App 列表 / 顺序改动即时刷新）
        if !prefsObserverInstalled {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            nil,
                                            aevonPrefsChangedHandler,
                                            "com.aevon.prefschanged" as CFString,
                                            nil,
                                            .deliverImmediately)
            prefsObserverInstalled = true
            AevonLog.info("[边缘] 已监听设置变更通知（prefschanged）（AevonPrefsLiveV26 AevonGuardCleanupV102）")
        }
        let ok = AevonTouchHookInstall()
        globalInstalled = ok
        if ok {
            AevonLog.info("[边缘] 全局触摸通道已安装（浮窗手势 + 圆盘指针喂料；呼盘只剩把手通道）（AevonGlobalTouchV23 AevonGripOnlyV251）")
            // 圆盘的默认内容：首次使用时用应用列表预填，保证呼出不是空盘
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                AevonRingStore.seedIfNeeded(from: AevonAppList.userApps())
            }
        } else {
            AevonLog.warn("[边缘] 全局触摸通道不可用，浮窗窗外手势将不可用")
        }
        return ok
    }

    // MARK: - 全局触摸分发（由 AevonTouchHook.m 在 sendEvent 里回调）

    // ── V0.2.82（AevonYieldTouchGuardV282）：活动触点计数 ────────────────────
    //
    // Aevon(55) 两次崩溃（SIGSEGV=11，SpringBoard 直接退出）都发生在「浮窗让位」之后
    // 0.28 / 0.53 秒。让位 = 把浮窗 `view.isHidden = true`，而 UIKit 在窗口被隐藏的
    // 那一刻会**立刻 cancel 该窗口上的所有触摸，并把对应 UITouch 从事件簿记里摘掉**；
    // 我们的 `AevonHookSendEvent` 还握着同一个 UITouch 指针，下一帧读 `touch.phase` /
    // `[touch locationInView:nil]` 就是 use-after-free —— 与崩溃栈
    // （帧1 = sendEvent 钩子、帧3-10 = 紧随其后的 Swift 判定）完全吻合。
    //
    // ObjC 层没法判断一个 UITouch 是不是已经失效（判据本身就要读它），所以从源头拦：
    // **手指还在屏上就不让位**，等它抬起来，下一次 0.25 秒巡检再让。
    // 计数丢帧（cancel 可能丢）靠「2 秒没有任何帧 → 清零」自愈，不会卡死让位。
    private static var activeTouchCount = 0
    private static var lastTouchFrameAt: CFTimeInterval = 0

    static func noteTouchFrame(phase: UITouch.Phase) {
        let now = CACurrentMediaTime()
        if lastTouchFrameAt > 0, now - lastTouchFrameAt > 2.0 {
            activeTouchCount = 0
        }
        lastTouchFrameAt = now
        switch phase {
        case .began: activeTouchCount += 1
        case .ended, .cancelled: activeTouchCount = max(0, activeTouchCount - 1)
        default: break
        }
    }

    /// 屏上还有手指（或 0.25 秒内刚有过触摸帧）。让位巡检据此延后。
    static var hasActiveTouches: Bool {
        if activeTouchCount > 0 { return true }
        return CACurrentMediaTime() - lastTouchFrameAt < 0.25
    }

    /// V0.3.2（AevonTouchRouteV302，用户 Aevon(80)「先查抖音卡屏是哪个版本出现的问题」+
    /// 定档「本轮构建一版纯探针」）：**右缘触摸路由探针（只观察，零行为改变）**。
    ///
    /// 为什么必须先探这一刀：0.2.85 的笔记当天就查明抖音没被注入（`__RESTRICT` 挡 dyld），
    /// 但 0.2.86~0.3.1 共 11 个版本的所有修法都建立在一个**从未被验证的假设**上——
    /// 「发往未注入 App 的触摸能在 SpringBoard 侧被看到并吞掉」。假设若为假，所有修法
    /// 无论怎么调都必然无效；假设若为真，卡屏可以在 SB sendEvent 里用一条几何判据拦掉。
    ///
    /// 判读（下一份日志）：
    ///   · 抖音全屏时滑右缘，出现本行 → SB 层看得到这根手指 → 最好结果：在 sendEvent
    ///     里按几何吞掉 began，不牺牲点击、不需要注入；
    ///   · 一行都没有 → 触摸由 HID 直投 App scene、根本不过 SB sendEvent →
    ///     必须下沉到 `BKSHIDEventDeliveryManager`（本轮类普查正在找的落点）。
    private static var lastRouteProbeAt: CFTimeInterval = 0
    private static func touchRouteProbe(point: CGPoint) {
        let screen = UIScreen.main.bounds
        // 只看右缘带（把手在右缘，呼盘也起于右缘；其它触摸与本问题无关）
        guard point.x >= screen.width - 60 else { return }
        let now = CACurrentMediaTime()
        if now - lastRouteProbeAt < 0.4 { return }
        lastRouteProbeAt = now
        let bid = AevonEntryHost.currentForegroundBundleID
        let float = AevonWindowManager.openBundleID
        AevonLog.info("[触摸路由] SB sendEvent 看到右缘 began (\(Int(point.x)),\(Int(point.y)))"
            + " 前台=\(bid.isEmpty ? "无" : bid)"
            + " 浮窗=\(float ?? "无")"
            + " 圆盘=\(AevonRingMenu.presented == nil ? "关" : "开")（AevonTouchRouteV302）")
    }

    static func handleGlobal(phase: UITouch.Phase, point: CGPoint, touchID: UInt) {
        guard AevonPrefs.bool("Enabled", default: true) else { return }
        let screen = UIScreen.main.bounds
        switch phase {
        case .began:
            // V0.2.57（AevonTouchProbeV257）：失效瞬间探针，每根 began 触发（3 秒节流）。
            AevonEntryHost.touchTriggeredProbeIfDue()
            // V0.3.2（AevonTouchRouteV302）：右缘触摸路由探针（只观察，零行为改变）。
            touchRouteProbe(point: point)
            // V0.2.57（AevonZombieSealV257）：已封印触摸的重投 began 一并静默消费
            //（UIKit 不应看到它的任何帧，见 sealZombieTouch 注释）。
            if touchID == zombieSealID, CACurrentMediaTime() <= zombieSealUntil { return }
            // V0.2.56（AevonDedupBeganV256）：浮窗拖拽已认领的手指，重投的 began 静默消费。
            // Aevon(30) 真机日志实锤同一根手指 3ms 内两条 began（14.969「落指即拖」→
            // 14.972 又一条同点 began 走了交回分支）——重投让 handleFloatGestureBegan
            // 返回 false，走进「交回浮窗（不接管、不吞）」分支，而 shouldSwallow 又把
            // 同一帧吞掉：日志承诺与管线行为自相矛盾，SB 的触摸簿记拿到说不清的序列。
            // 统一口径：认领中的手指，began 一律与首条同命运（吞），不再走交回分支。
            if floatGestureActive, touchID == floatTouchID {
                let now = CACurrentMediaTime()
                // AevonStaleShieldV256：1.5 秒没有 moved 续期 = 抬手帧已丢的残留状态
                //（槽位地址复用会让新手指被当成旧手指整段吞）→ 先清场，再按新触摸判定。
                if lastFloatMovedAt > 0, now - lastFloatMovedAt > 1.5 {
                    AevonLog.warn("[自愈] 浮窗拖拽残留（began 盾 1.5s，touchID=\(floatTouchID)）→ 清场重判"
                        + "（AevonStaleShieldV256）")
                    clearFloatGesture()
                } else {
                    // 静默消费，但要可观测（重投频率本身就是证据）
                    if now - lastDedupLogAt > 2.0 {
                        lastDedupLogAt = now
                        AevonLog.info("[边缘] 浮窗拖拽手指重投 began → 静默消费（AevonDedupBeganV256）")
                    }
                    return
                }
            }
            // 圆盘展开期间：整屏触摸归圆盘（AevonRingFullSwallowV102）。
            // 原指针还压着 → 新手指只登记「额外吞掉」；原指针已抬起 → 新触摸接管为当前指针。
            if let ring = AevonRingMenu.presented {
                if ring.isPointerActive {
                    ringExtraTouchID = touchID
                    ringExtraDeadline = CACurrentMediaTime() + swallowLimit
                    return
                }
                globalTouchID = touchID
                globalStart = point
                globalFired = true
                lastTouchPoint = point
                ownsTouch = true
                ringSource = "global"
                swallowDeadline = CACurrentMediaTime() + swallowLimit
                gripAdoptedTouchID = 0
                ring.beginRemoteTracking(at: point, source: "global")
                return
            }
            // V0.2.66（AevonFloatGripFirstV266，用户 Aevon(39) #2 #4 #7）：浮窗手势
            // **提到把手认领之前**。原来把手认领在前 —— 浮窗贴近屏幕右缘时，浮窗的
            // 边条/右下角与把手命中区（右缘竖条外扩 40pt）重叠，落点先被判成「落在
            // 把手上」→ 认领 + 广播占用后直接 return，浮窗自己的边条点击 / 缩放手势
            // 完全收不到（=「移到边缘后吸附点击失效」「缩放时呼出圆盘」两个死因同根）。
            // 现在落点在浮窗上就先走浮窗手势；浮窗手势不要这个点（返回 false）再回落
            // 到把手认领。全屏 App 里没有浮窗，呼盘把手通道不受影响。
            if AevonEntryHost.pointHitsFloatingWindow(at: point) {
                if handleFloatGestureBegan(point: point, touchID: touchID) { return }
            }
            // V0.2.60（AevonGripSwipeGlobalV260）：把手命中区上的触摸**先认领**——
            // 只登记观察，不吞、不接管（把手是真实控件，桌面 / 全屏 App 两条路都靠它）。
            // 全屏 App 时视图层收不到触摸，只有这条总入口能看到 → 把手才「到处都能用」。
            if AevonRingMenu.presented == nil, AevonRingGrip.hitTestScreenPoint(point) {
                gripSwipeTouchID = touchID
                gripSwipeStart = point
                // 顺带把指针位置记准：呼盘时圆盘从这个点接手指（全屏 App 里
                // 视图层那条路收不到触摸，这里是唯一能记到真实落点的通道）。
                lastTouchPoint = point
                /* V0.2.77（AevonGripBusyLateV277，用户 Aevon(49) #2「抖音全屏打开时右侧
                 * 评论按钮无法点击，卸载 Aevon 后就正常」）：0.2.63 起「一落指就广播
                 * 把手占用」——广播的代价是让被覆盖的 App 把这根手指整根 cancel。
                 * 而把手命中区是右缘 45×92pt（GripY 默认 30% → 心点 y≈652），正好压在
                 * 抖音右栏「评论/收藏」那一竖排上：每次点按钮都先被 cancel，按钮永远
                 * 收不到 touchUp = 「必须精准点到边上才有概率触发」。
                 * 现在改成**延迟广播**：落指只登记候选，确认是呼盘手势（左滑 ≥6pt）
                 * 才广播占用并 cancel App —— 点击（位移 < 6pt 就抬手）全程不受影响。
                 * 代价：左滑起手那 6pt 里 App 可能已开始跟手，随后被 cancel（几 pt 抖动），
                 * 相比「右栏按钮整体失灵」低两个量级。 */
                AevonLog.info("[圆盘] 手指落在把手上 (\(Int(point.x)),\(Int(point.y))) → 只登记候选，"
                    + "左滑 ≥6pt 呼盘（点击放行）；占用广播已退役（AevonGripBusyV263 AevonGripBusyLateV277"
                    + " AevonGripRetireV286 AevonGripBusyRetireV287）")
                return
            }
            // V0.2.9（AevonFloatPassV209）：落在浮窗上的触摸整个交回浮窗。
            // V0.2.66：浮窗手势已在上面先试过（AevonFloatGripFirstV266），这里只兜
            // 「浮窗手势不接管的内容区」—— 不吞、不判向，也绝不让下面的把手认领抢走。
            if AevonEntryHost.pointHitsFloatingWindow(at: point) {
                lastTouchPoint = point
                let nowFloat = CACurrentMediaTime()
                if nowFloat - globalLastLogAt > 2.0 {
                    globalLastLogAt = nowFloat
                    AevonLog.info("[边缘] 触摸落在浮窗上 (x=\(Int(point.x)), y=\(Int(point.y))) → 整个交回浮窗（不接管、不吞、不判向）（AevonFloatPassV209 AevonFloatStandDownV209 AevonFloatGripFirstV266）")
                }
                return
            }
            // 0.2.51：除浮窗与圆盘外一律不拦（呼盘只有把手，把手自己 hitTest 赢）。
            break

        case .moved:
            // V0.2.99（AevonGripThreshV299，用户 Aevon(76)「无法呼出圆盘」）：呼盘阈值
            // -14→-8pt。Aevon(76) 日志实锤：39 次候选仅 9 次呼出（23%），21 次被意图
            // 吞咽拦下——用户滑动幅度集中在 -6~-13pt，-14pt 阈值之外全没收。降阈值后
            // 主力滑动区间全部可呼出。
            // 纵向抖动容忍 ≤40pt 不变。
            // V0.3.3（AevonGripIntentRetireV303）：原 dx<-6 的「意图吞咽」分支整段删除
            //（理由见 gripSwipeTouchID 声明处）。短滑**一律全放行**：App 收到完整
            // began→moved→ended，手势簿记正常收尾，结构上不再可能死锁。
            // 代价（已知并接受）：未达阈值的半截左滑会留在 App 里（抖音可能误暂停 /
            // 半进博主主页）。这是「完全不能用」与「偶发误触发」之间的取舍，用户定档
            // 先消灭卡屏。
            // V0.3.6（AevonGripYieldDeepV306）：让路模式下即使 gripSwipeTouchID 还有
            // 残留（开关是在呼盘手势进行中打开的），这半截手指也不再呼盘 —— 右缘归系统腿。
            if !AevonRingGrip.yieldActive,
               gripSwipeTouchID != 0, touchID == gripSwipeTouchID {
                let dx = point.x - gripSwipeStart.x
                let dy = point.y - gripSwipeStart.y
                /* V0.2.87（AevonGripBusyRetireV287）：原「左滑 ≥6pt 才广播占用」整段删除
                 *（AevonNotifySetGripBusy(true)），理由见 124 行注释。 */
                if dx < -8, abs(dy) < 40 {
                    gripSwipeTouchID = 0
                    if AevonRingMenu.presented == nil {
                        lastTouchPoint = point
                        AevonLog.info("[圆盘] 把手左滑 \(Int(dx))pt → 呼出圆盘（全局通道，全屏 App 也生效；0.2.99 阈值 14→8pt）"
                            + "（AevonGripSwipeGlobalV260 AevonGripThreshV299）")
                        presentRing(source: "ringgrip")
                    }
                } else if hypot(dx, dy) > 60 {
                    gripSwipeTouchID = 0
                }
            }
            // V0.2.60（AevonDockTapOnlyV260）：停靠小窗上的手指一动就作废「点一下装回」候选
            if dockTapCandidateID != 0, touchID == dockTapCandidateID,
               hypot(point.x - dockTapCandidatePoint.x,
                     point.y - dockTapCandidatePoint.y) > 12 {
                dockTapCandidateID = 0
                dockTapCandidateWindow = nil
            }
            if handleFloatGestureMoved(point: point, touchID: touchID) { return }
            if touchID == ringExtraTouchID {
                if CACurrentMediaTime() <= ringExtraDeadline {
                    ringExtraDeadline = CACurrentMediaTime() + swallowLimit
                }
                return
            }
            // V0.2.7（AevonEdgeAdoptV207）：把手呼盘的那根手指 SB 侧没登记过
            // globalTouchID（它起手在把手上）→ 收养它继续喂圆盘。
            // 只登记观察，不开 ownsTouch（把手是真实控件，App 那份由 hitTest 天然路由）。
            // V0.3.29：`!ownsTouch` —— 已经被自建腿绑进吞层的手指**不许**再走这条路。
            // 这条分支会把指纹塞进 `gripAdoptedTouchID`，而那是「只喂不吞」的唯一钥匙；
            // Aevon(102) 的桌面翻页 / 抖音进博主页就是被这条分支解锁的。
            if touchID != globalTouchID, AevonRingMenu.isPresented, ringSource == "global",
               !ownsTouch, !appEdgePointerAdopted, touchID != ringExtraTouchID {
                appEdgePointerAdopted = true
                globalTouchID = touchID
                globalStart = point
                globalFired = true
                lastTouchPoint = point
                gripAdoptedTouchID = touchID
                AevonLog.info("[圆盘] 收养把手手指（只登记喂圆盘、不吞）→ 继续喂圆盘"
                    + "（AevonEdgeAdoptV207 AevonGripOnlyV251 AevonGripFeedCleanV258）")
            }
            guard touchID == globalTouchID else { return }
            lastTouchPoint = point
            lastTouchAt = CACurrentMediaTime()
            if ownsTouch { swallowDeadline = CACurrentMediaTime() + pressLimit }
            if let ring = AevonRingMenu.presented {
                if ringSource == "global" {
                    swallowDeadline = CACurrentMediaTime() + swallowLimit
                }
                ring.remoteMoved(to: point, source: "global", authoritative: ownSwallowBound)
                return
            }

        case .ended:
            // V0.2.60（AevonGripSwipeGlobalV260）：抬手即清把手观察态
            if gripSwipeTouchID != 0, touchID == gripSwipeTouchID { gripSwipeTouchID = 0 }
            // V0.2.87（AevonGripBusyRetireV287）：原「抬手撤销占用广播」整段删除。
            // V0.2.60（AevonDockTapOnlyV260）：停靠小窗「点一下装回」的全局兜底。
            // 没移动就抬手 = 装回（UIKit 的 dockTap 是主路，这条只是全屏 App 的保险；
            // restoreDocked 自己幂等，晚到的那一次会因「已不在停靠列」直接返回）。
            if dockTapCandidateID != 0, touchID == dockTapCandidateID {
                let win = dockTapCandidateWindow
                let moved = hypot(point.x - dockTapCandidatePoint.x,
                                  point.y - dockTapCandidatePoint.y) > 12
                dockTapCandidateID = 0
                dockTapCandidateWindow = nil
                if !moved, let win = win, win.isDocked {
                    AevonLog.info("[停靠] 小窗轻点（全局兜底）→ 装回主窗（AevonDockTapOnlyV260）")
                    AevonWindowManager.restoreDocked(bundleID: win.bundleID)
                    return
                }
            }
            // V0.2.12（AevonEndAlwaysCleanV212）：抬手必然归还，defer 兜底。
            let endedHeldGlobal = (globalTouchID != 0 && touchID == globalTouchID)
            defer {
                if endedHeldGlobal {
                    globalTouchID = 0
                    globalFired = false
                    ownsTouch = false
                    if ownSwallowBound { AevonGripAssertReleaseBridge() }   // V0.3.29：吞层接手后识别器收不到 ended、reset 也不会来 → 断言必须在这里还
                    ownSwallowBound = false   // V0.3.29：绑吞层标记随归属一起归还
                    swallowDeadline = 0
                    globalOwnedAt = 0
                    gripAdoptedTouchID = 0
                    preBindTid = 0            // V0.3.30：预绑随抬手一起作废（指针会被复用）
                    preBindAt = 0
                }
            }
            if handleFloatGestureEnded(point: point, touchID: touchID, cancelled: false) { return }
            if touchID == ringExtraTouchID {
                /* V0.2.89（AevonRingOrphanEndV289）：不清登记直接 return —— 原来清零后
                 * shouldSwallow 对本帧 return false = 放行一根「有 ended 没 began」的
                 * 孤儿帧（began 在圆盘展开时被吞）→ 手势簿记污染。保留登记、收窄
                 * 0.2 秒吞咽窗口：本帧继续吞，之后自然过期（手指已抬）。 */
                ringExtraDeadline = CACurrentMediaTime() + 0.2
                return
            }
            // 同 moved —— 未登记的手指在圆盘展开期间抬手，也要收养后送达 remoteEnded。
            // V0.3.29：同样加 `!ownsTouch`（理由见 moved 分支）。
            if touchID != globalTouchID, AevonRingMenu.isPresented, ringSource == "global",
               !ownsTouch, !appEdgePointerAdopted, touchID != ringExtraTouchID {
                appEdgePointerAdopted = true
                globalTouchID = touchID
                globalFired = true
                lastTouchPoint = point
                gripAdoptedTouchID = touchID
                AevonLog.info("[圆盘] 收养把手手指（抬手）→ 圆盘收起"
                    + "（AevonEdgeAdoptV207 AevonGripFeedCleanV258）")
            }
            guard touchID == globalTouchID else { return }
            if let ring = AevonRingMenu.presented {
                ring.remoteEnded(at: point, source: "global")
            }
            globalTouchID = 0
            globalFired = false
            ownsTouch = false
            if ownSwallowBound { AevonGripAssertReleaseBridge() }   // V0.3.29：吞层接手后识别器收不到 ended、reset 也不会来 → 断言必须在这里还
            ownSwallowBound = false   // V0.3.29：绑吞层标记随归属一起归还

        case .cancelled:
            if gripSwipeTouchID != 0, touchID == gripSwipeTouchID { gripSwipeTouchID = 0 }
            // V0.2.87（AevonGripBusyRetireV287）：原「取消撤销占用广播」整段删除。
            if dockTapCandidateID != 0, touchID == dockTapCandidateID {
                dockTapCandidateID = 0
                dockTapCandidateWindow = nil
            }
            let cancelledHeldGlobal = (globalTouchID != 0 && touchID == globalTouchID)
            defer {
                if cancelledHeldGlobal {
                    globalTouchID = 0
                    globalFired = false
                    ownsTouch = false
                    if ownSwallowBound { AevonGripAssertReleaseBridge() }   // V0.3.29：吞层接手后识别器收不到 ended、reset 也不会来 → 断言必须在这里还
                    ownSwallowBound = false   // V0.3.29：绑吞层标记随归属一起归还
                    swallowDeadline = 0
                    globalOwnedAt = 0
                    gripAdoptedTouchID = 0
                    preBindTid = 0            // V0.3.30：预绑随取消一起作废
                    preBindAt = 0
                }
            }
            if handleFloatGestureEnded(point: point, touchID: touchID, cancelled: true) { return }
            if touchID == ringExtraTouchID {
                // V0.2.89（AevonRingOrphanEndV289）：同 ended —— 保留登记防孤儿帧，
                // 收窄 0.2 秒窗口自然过期。
                ringExtraDeadline = CACurrentMediaTime() + 0.2
                return
            }
            guard touchID == globalTouchID else { return }
            AevonRingMenu.presented?.remoteCancelled(source: "global")
            globalTouchID = 0
            globalFired = false
            ownsTouch = false
            if ownSwallowBound { AevonGripAssertReleaseBridge() }   // V0.3.29：吞层接手后识别器收不到 ended、reset 也不会来 → 断言必须在这里还
            ownSwallowBound = false   // V0.3.29：绑吞层标记随归属一起归还

        default:
            break
        }
        _ = screen // 保留局部命名与旧版一致（日志几何用）
    }

    // MARK: - 接管自愈（AevonSwallowSelfHealV212）

    /// 全系统触摸的必经之路上做巡检：圆盘已不在场还挂着的接管 → 立刻归还。
    private static func healGlobalTakeoverIfNeeded() {
        let now = CACurrentMediaTime()
        // V0.2.55（AevonGripHealV255）：浮窗拖拽状态残留自愈 ——
        // 2 秒没有 moved 续期却仍 active = 抬手帧丢了，强制清场。
        // （touchID 是 UITouch 指针，槽位地址复用会让新手指被误吞。）
        if floatGestureActive, lastFloatMovedAt > 0,
           now - lastFloatMovedAt > 2.0 {
            AevonLog.warn("[自愈] 浮窗拖拽状态残留（2 秒无移动，touchID=\(floatTouchID)）→ 强制清场"
                + "（AevonGripHealV255）")
            sealZombieTouch(floatTouchID)
            clearFloatGesture()
        }
        let holding = (ownsTouch || globalTouchID != 0)
        if holding {
            if globalTouchID != globalOwnedForTouch || globalOwnedAt == 0 {
                globalOwnedForTouch = globalTouchID
                globalOwnedAt = now
            }
        } else {
            globalOwnedForTouch = 0
            globalOwnedAt = 0
        }
        guard holding, globalOwnedAt > 0 else { return }
        var reason = ""
        if !AevonRingMenu.isPresented, now - globalOwnedAt > healIdleWindow {
            reason = "圆盘已收起且接管超过 \(String(format: "%.1f", healIdleWindow)) 秒"
        } else if now - globalOwnedAt > globalOwnHardLimit, !AevonRingMenu.isPresented {
            reason = "收归超过 \(Int(globalOwnHardLimit)) 秒"
        }
        guard !reason.isEmpty else { return }
        let heldID = globalTouchID
        ownsTouch = false
        if ownSwallowBound { AevonGripAssertReleaseBridge() }   // V0.3.29：吞层接手后识别器收不到 ended、reset 也不会来 → 断言必须在这里还
        ownSwallowBound = false   // V0.3.29：绑吞层标记随归属一起归还
        globalTouchID = 0
        globalFired = false
        swallowDeadline = 0
        globalOwnedAt = 0
        globalOwnedForTouch = 0
        if now - lastHealLogAt > 1.0 {
            lastHealLogAt = now
            AevonLog.warn("[自愈] 接管状态未正常归还（\(reason)）→ 立刻把手指还给系统：ownsTouch=0 globalTouchID=\(heldID) → 0（AevonSwallowSelfHealV212）")
        }
    }

    // MARK: - V0.3.30（AevonEarlyBindV330）：落指预绑

    /// 落指那一刻就把这根手指交给全局吞层 —— 不等召唤。
    ///
    /// 见 `preBindTid` 的注释：漏帧是**结构性**的，不是时延调参能解决的。
    /// 这里做的决定全部可逆且 fail-open —— 任何一条 guard 不成立就什么都不做，
    /// 行为完全退回 0.3.29。
    static func ownLegPreBind(tid: UInt, x: CGFloat, y: CGFloat) {
        guard tid != 0 else { return }
        guard AevonPrefs.bool("Enabled", default: true) else { return }
        guard AevonPrefs.bool("EarlySwallow", default: true) else { return }
        /* 圆盘已经开着：这根手指归圆盘自己的指针通道管，不许抢。
         * 浮窗拖拽中：那根手指归 `floatTouchID`，同样不许抢（`shouldSwallow` 里
         * 浮窗分支排在全局通道之前，抢了也只会让簿记更乱）。 */
        guard AevonRingMenu.presented == nil else { return }
        guard !floatGestureActive else { return }
        let now = CACurrentMediaTime()
        preBindTid = tid
        preBindAt = now
        globalTouchID = tid
        globalStart = CGPoint(x: x, y: y)
        globalFired = false
        ownsTouch = true
        /* 预绑**不等于**转正：`ownSwallowBound` 保持假，喂盘仍走非权威通道，
         * 直到真的召唤才置真。这样「预绑了但其实是一次点击」不会污染跟手判据。 */
        ownSwallowBound = false
        /* `gripAdoptedTouchID` 是「只喂不吞」的唯一钥匙，预绑期间必须为空，
         * 否则 `shouldSwallowGlobalTouch` 第一条就放行（0.3.29 的教训）。 */
        gripAdoptedTouchID = 0
        appEdgePointerAdopted = false
        globalOwnedForTouch = tid
        globalOwnedAt = now
        swallowDeadline = now + earlyBindLimit
        guard preBindLogCount < 6 else { return }
        preBindLogCount += 1
        AevonLog.info("[圆盘] 落指预绑 touchID=\(tid)（离右缘 \(Int(UIScreen.main.bounds.width - x))pt）"
            + " → 从下一帧 moved 起就吞，App 拿不到位移"
            + "（AevonEarlyBindV330）")
    }

    /// 撤销预绑：把还在扣着的手指立刻还给 App。
    ///
    /// `tid == 0` = 调用方（`-ownPass:`）已经把身份清掉了，用我们自己记的那个。
    /// 只清预绑那一份簿记；0.3.29 转正之后的真实绑定由它自己的 6 个归还点管，
    /// 两个状态混在一起清会让「召唤成功但盘还在」时手指突然漏给 App。
    static func ownLegPreBindCancel(tid: UInt) {
        let want = (tid != 0) ? tid : preBindTid
        guard want != 0, want == preBindTid else { return }
        preBindTid = 0
        preBindAt = 0
        guard globalTouchID == want else { return }
        globalTouchID = 0
        globalFired = false
        ownsTouch = false
        swallowDeadline = 0
        globalOwnedAt = 0
        globalOwnedForTouch = 0
        gripAdoptedTouchID = 0
    }

    /// 预绑超时兜底：4 秒还没等到召唤 / 抬手就把预绑放掉（fail-open）。
    private static func expirePreBindIfNeeded() {
        guard preBindTid != 0, preBindAt > 0 else { return }
        guard CACurrentMediaTime() - preBindAt > earlyBindLimit else { return }
        /* 已经召唤成功（`ownSwallowBound`）= 这是真实绑定，不许在这里放掉；
         * 只把计时续上，让「抬手帧放行」那条规则一直有效到抬手。 */
        if ownSwallowBound { preBindAt = CACurrentMediaTime(); return }
        ownLegPreBindCancel(tid: preBindTid)
    }

    /// `AevonTouchHook.m` 逐帧询问：这根触摸要不要吞掉（不投递给 App）。
    ///
    /// 0.2.51 只剩两类正当吞咽：
    ///   · **浮窗拖拽**（V0.0.41）：手柄在浮窗外侧，落点是 App 内容，不吞会连带拖动 App；
    ///   · **圆盘指针**（V0.0.29 / V0.2.14）：圆盘开着时这根手指不该穿透到桌面 / App。
    /// 其余历史路径（热区整指、右缘接管带、扣移动帧）已随呼盘手势一起删除。
    static func shouldSwallowGlobalTouch(_ touchID: UInt, phase: Int) -> Bool {
        guard AevonPrefs.bool("Enabled", default: true) else { return false }
        guard touchID != 0 else { return false }
        expirePreBindIfNeeded()
        healGlobalTakeoverIfNeeded()
        /* V0.3.30（AevonEarlyBindV330）：预绑手指的**抬手帧一律放行**。
         *
         * 0.3.29 把 ended 也吞了（末尾 `if ownsTouch { return true }`），于是 App 手里
         * 留着「有 began 无终止帧」的孤儿触摸 —— 这正是 0.2.57 时代已经写下来的教训，
         * `zombieSeal` 分支的注释就摆在这里（「ended/cancelled 放行，孤儿 ended 对
         * UIKit 无害，吞了反而留脏簿记」），新路径没照抄它。
         *
         * 放行不会让圆盘收不到抬手：`AevonTouchHook.m` 对结束帧是「先询问再上报」，
         * 我们返回 false 之后 `AevonGlobalTouchPhase` 照样把这一帧喂给圆盘。
         *
         * 安全性：预绑期间 moved 全被吞，App 累计位移恒为 0 —— 抬手帧即便送达，
         * 对方看到的也只是「原地按了一下」，不产生任何滚动或翻页。 */
        if preBindTid != 0, touchID == preBindTid, phase == 3 || phase == 4 {
            return false
        }
        // V0.2.57（AevonZombieSealV257）：封印期触摸的 began/moved 一律吞到抬手；
        // ended/cancelled 放行 —— 孤儿 ended 对 UIKit 无害（没见过 began 就被忽略），
        // 而经重投副本见过 began 的那一路恰好需要这帧 ended 收尾，吞了反而留脏簿记。
        if zombieSealID != 0, touchID == zombieSealID {
            if CACurrentMediaTime() > zombieSealUntil {
                zombieSealID = 0
                zombieSealUntil = 0
            } else if phase == 3 || phase == 4 {
                zombieSealID = 0
                zombieSealUntil = 0
            } else {
                return true
            }
        }
        // V0.3.3（AevonGripIntentRetireV303）：原「把手左滑意图吞咽」整段删除。
        // 那一段是「began 放行、中途改吞」，制造了一根永不结束的 UITouch →
        // UIScrollView 触摸延迟队列永久挂起 → 全 App 卡屏（用户 Aevon(81) 实锤复现
        // 方式：滑动手势条但滑动距离短、圆盘不出现 → 全屏应用必然卡住）。
        // 铁律：一根手指的归属只在 began 那一帧决定，整根一致。
        // V0.2.58（AevonGripFeedCleanV258）：把手收养指纹全程放行 ——
        // began 已投递 UIKit 的触摸，剩下的帧必须补全投递，绝不再半路吞。
        // 这根手指的触摸窗口恒为入口窗口，投递只到把手识别器，不可能误伤系统。
        if gripAdoptedTouchID != 0, touchID == gripAdoptedTouchID { return false }
        // V0.0.41（AevonFloatGlobalV41）：浮窗拖拽期间这根手指完全归浮窗。
        if floatGestureActive, touchID == floatTouchID,
           CACurrentMediaTime() <= floatDeadline {
            // V0.2.55（AevonGripHealV255）：吞咽可观测 —— Aevon(29) 的「tap 活 pan 死」
            // 如果真是吞咽泄漏，日志会直接说。
            let now = CACurrentMediaTime()
            if now - lastSwallowLogAt > 2.0 {
                lastSwallowLogAt = now
                AevonLog.warn("[边缘] 吞掉触摸 \(touchID)（浮窗拖拽中，剩 \(String(format: "%.1f", floatDeadline - now))s）"
                    + "（AevonGripHealV255）")
            }
            return true
        }
        // V0.0.29：圆盘展开期间被吞掉的「额外手指」
        if touchID == ringExtraTouchID {
            return CACurrentMediaTime() <= ringExtraDeadline
        }
        // V0.0.29 / V0.2.14：圆盘展开期间登记的指针（把手呼盘收养的那根）。
        if AevonRingMenu.isPresented, ringSource == "global",
           touchID == globalTouchID, CACurrentMediaTime() <= swallowDeadline {
            return true
        }
        guard globalTouchID != 0, touchID == globalTouchID else {
            /* V0.2.86（AevonRingMissLogV286）—— **抖音那条链的诊断哨**。
             *
             * Aevon(59)「抖音中滑动圆盘时会让视频暂停播放，并且会滑动到视频博主主页卡住」。
             * 0.2.84 已确认 `AevonApp.dylib` **根本没被注入抖音进程**（App 侧日志里 20 多个
             * 进程都有，独独没有 com.ss.iphone.ugc.Aweme，连启动那句「scene 探针已挂」
             * 都没有，最可能是抖音 __RESTRICT 段挡了 dyld 插入），所以「把手占用广播」
             * 对抖音是空的 —— 唯一能挡住那根手指的只剩这条 SB 侧吞层。
             *
             * 这条日志就是在回答「吞层到底漏没漏」：圆盘已经展开、却有一根手指走到
             * 「不是我的手指」这个出口 → 它会被投给抖音，落指 = 暂停、横滑 = 进主页。
             * 下一份日志里只要出现这一行，就说明要动的是吞层判据（不是 App 侧）；
             * 一次都不出现，说明手指压根没到 SpringBoard 的 sendEvent（另有一条链要查）。 */
            if AevonRingMenu.isPresented, phase == 0 {
                let nowMiss = CACurrentMediaTime()
                if nowMiss - lastRingMissLogAt > 1.0 {
                    lastRingMissLogAt = nowMiss
                    AevonLog.warn("[边缘] 圆盘展开中却有手指未被吞 \(touchID) → 会漏给下层 App"
                        + "（globalTouchID=\(globalTouchID) ringSource=\(ringSource) ownsTouch=\(ownsTouch)"
                        + " 剩余=\(String(format: "%.1f", swallowDeadline - nowMiss))s）"
                        + "（AevonRingMissLogV286）")
                }
            }
            return false
        }
        guard CACurrentMediaTime() <= swallowDeadline else { return false }
        if ownsTouch { return true }
        guard AevonRingMenu.isPresented, ringSource == "global" else { return false }
        return true
    }

    // MARK: - 浮窗手势状态机（V0.0.41，AevonFloatGlobalV41）

    private static var floatGestureActive: Bool { return floatTouchID != 0 }

    /// 按下：命中浮窗外侧手柄 / ✕ 就整段接管这根手指。
    private static func handleFloatGestureBegan(point: CGPoint, touchID: UInt) -> Bool {
        if floatTouchID != 0 {
            let now0 = CACurrentMediaTime()
            // V0.2.56（AevonStaleShieldV256）：残留盾提前到接管判定 —— 1.5 秒没有 moved
            // 续期的拖拽状态 = 抬手帧已丢（shouldSwallow 里的自愈是 2 秒，这里更早拦）。
            // 清场后按新触摸正常判定，槽位地址复用的新手指能被重新接管而不是当残影吞。
            if lastFloatMovedAt > 0, now0 - lastFloatMovedAt > 1.5 {
                AevonLog.warn("[自愈] 浮窗拖拽残留（接管盾 1.5s，touchID=\(floatTouchID)）→ 清场重判"
                    + "（AevonStaleShieldV256）")
                sealZombieTouch(floatTouchID)
                clearFloatGesture()
            } else if now0 > floatDeadline {
                sealZombieTouch(floatTouchID)
                clearFloatGesture()
            } else {
                return false
            }
        }
        guard AevonRingMenu.presented == nil else { return false }
        // V0.2.61（AevonDockTapFixV261，用户 Aevon(35) #6 重点）：停靠小窗在 0.2.60 里
        // 摘掉了四周边条手柄，而 `grabFloatingWindow` 只认手柄命中 —— 于是点小窗时
        // 这里恒返回 nil，全局通道连「这一下点在小窗上」都不知道，自然也不会装回。
        // 先按**窗口 frame** 单独判一次停靠态（不依赖任何子视图 / 命中测试）。
        if let docked = AevonEntryHost.dockedWindow(atScreenPoint: point) {
            dockTapCandidateID = touchID
            dockTapCandidatePoint = point
            dockTapCandidateWindow = docked
            AevonLog.info("[停靠] 全局通道记下小窗轻点候选（\(Int(point.x)),\(Int(point.y))）"
                + "→ 抬手未移动即装回（AevonDockTapFixV261）")
            return false
        }
        guard let hit = AevonEntryHost.grabFloatingWindow(atScreenPoint: point) else {
            return false
        }

        let now = CACurrentMediaTime()
        // V0.2.60（AevonDockTapOnlyV260）：停靠小窗只有一个手势语义 —— 点它 = 装回。
        // 这里**不接管、不吞**（连 floatTouchID 都不登记）：让小窗侧那个 dockTap
        // 拿到整根触摸；同时记一笔全局兜底候选，全屏 App 之上 UIKit 收不到时由
        // handleGlobal 的 ended 分支把这次点击补上。
        if hit.window.isDocked {
            dockTapCandidateID = touchID
            dockTapCandidatePoint = point
            dockTapCandidateWindow = hit.window
            return false
        }
        /* V0.3.24（AevonBottomFlickV324，用户定档「悬浮窗底部手势条上滑关闭，类似系统的
         * 上滑返回桌面」）：底边双击关闭整条退役，改「上滑 = 关闭」终止手势。
         *
         * 为什么必须换掉双击（结构问题，调参数救不了）：
         *   第 2 击一落指，本函数就判定双击成立并立刻 `AevonWindowManager.close()`，
         *   而 close 第 1 拍就把存活心跳写 0（publishFloatFrame(.zero)）。同一次落指由
         *   backboardd **异步双投**给 App 进程，App 侧要看 `AevonFloatAlive()` 才整根丢弃
         *   —— 两个进程谁先到决定吞不吞，所以「有概率触发 App 内操作」。
         *
         * 上滑关闭把时序反过来：落指只登记候选，**关窗推迟到抬手**。整根手指存续期间
         * 浮窗一直活着，App 侧判据（矩形 + 心跳）全程有效；抬手帧走完才关窗，不存在
         * 「窗已经没了、这根手指还在」的窗口。语义也对齐 Stheno：底边属于
         * `__bottomLikeTouchRegions`，挂 `sc_addTerminationGestureToRegion:`，判据
         * `sc_shouldCloseForBottomUpwardFlick:`；移动在 `__allEdgeTouchRegions`，
         * 所以底边不再承担移动（移动仍由左右边条负责）。
         *
         * 历史标记 AevonFloatBottomDblCloseV221 / AevonDblTapHealV256 / AevonDblTapGuardV261
         * 在抬手日志串里保底（二进制断言不落空）。 */
        /* V0.3.25（AevonBottomSplitV325，用户 Aevon(99)「底部要能移动，又要能关」）：
         * 底边不再独占「上滑关闭」，回到 Stheno 的 `ScreenCore.Split.BottomMoveClose`
         * 结构 —— **落指即拖（移动） + 按住 0.4s 不动进关闭预备态**。
         * 这里只登记长按候选，移动交给下面的统一 `.bar` 路径（与左右边条同一条）。 */
        if case .bar(.bottom) = hit.grab {
            floatTermCandidate = true
            floatTermArmed = false
            floatTermBeganAt = now
            floatTermPoint = point
            floatTermLastPoint = point
            floatTermLastAt = now
            floatTermTrack = [(now, point)]
            AevonLog.info("[窗口] 底边落指（\(Int(point.x)),\(Int(point.y))）→ 可移动；"
                + "按住 0.4s 不动后上甩 \(Int(AevonEdgeEntry.floatTermLift))pt 才关闭，"
                + "推过 \(Int(AevonEdgeEntry.floatTermBigLift))pt 也算"
                + "（AevonBottomSplitV325 AevonTermFollowV326）")
        } else {
            floatTermCandidate = false
            floatTermArmed = false
            floatTermTrack.removeAll(keepingCapacity: true)
        }

        floatTouchID = touchID
        floatWindow = hit.window
        floatGrab = hit.grab
        floatDeadline = now + floatDragLimit
        lastFloatMovedAt = now   // V0.2.55：began 也算一次「在场」，丢 ended 时自愈才有锚
        switch hit.grab {
        case .bar:
            // V0.2.27（AevonFloatEdgeGripV227）：落指即拖（延迟 0）——
            // 手指一动（首个 .moved）立即 grabBegin；原地不动 = 轻点：
            //   左/右边条轻点 = 停靠该侧（0.2.51，AevonDockTapV251，用户 Aevon(26) #1）；
            //   底边轻点 = 无动作（0.3.24 起底边只有上滑关闭，AevonBottomFlickV324）。
            floatBarPending = true
            floatBarHoldPoint = point
            floatBarHoldDeadline = now + floatBarHoldDelay
            AevonLog.info("[窗口] 全局通道按住边条，落指即拖 \(Int(point.x)),\(Int(point.y))（AevonFloatBarHoldV221 AevonFloatEdgeGripV227）")
        case .corner:
            hit.window.grabBegin(hit.grab, at: hit.layerPoint)
            AevonLog.info("[窗口] 全局通道开始拖动（缩放）\(Int(point.x)),\(Int(point.y))（AevonFloatGlobalV41）")
        }
        return true
    }

    /// 拖动中。返回 true = 已消费，调用方 return。
    private static func handleFloatGestureMoved(point: CGPoint, touchID: UInt) -> Bool {
        guard floatTouchID != 0, touchID == floatTouchID else { return false }
        guard let win = floatWindow else {
            clearFloatGesture()
            return false
        }
        let now = CACurrentMediaTime()
        guard now <= floatDeadline else {
            win.grabCancel()
            sealZombieTouch(touchID)
            clearFloatGesture()
            return false
        }
        lastFloatMovedAt = now
        /* V0.3.25（AevonBottomSplitV325）：底边长按预备态。
         * 0.4s 内累计位移 ≤12pt 才成立（Stheno `setMinimumPressDuration: 0.4` /
         * `setAllowableMovement: 12` 同参数）；成立即回位并**停止移动**，此后只判上甩。
         * 一动（>12pt）就不成立 —— pan 继续移动窗口，这就是「移动与关闭共存」。 */
        if floatTermCandidate, !floatTermArmed {
            let held = now - floatTermBeganAt
            let moved = hypot(point.x - floatTermPoint.x, point.y - floatTermPoint.y)
            if held >= AevonEdgeEntry.floatTermHold, moved <= AevonEdgeEntry.floatTermSlop {
                floatTermArmed = true
                // V0.3.26（AevonTermFollowV326）：不再只是 grabCancel 回位 —— 进预备态后
                // 让窗口跟着手指上移（0.55 倍），用户能看见「正在准备关闭」。
                // beginTerminationFollow 内部先 grabCancel（回位），再接管跟手。
                if !win.beginTerminationFollow() { win.grabCancel() }
                floatTermTrack = [(now, floatTermPoint)]
                AevonLog.info("[窗口] 底边长按成立（全局通道 0.4s / ≤12pt）→ 关闭预备态："
                    + "上移 \(Int(AevonEdgeEntry.floatTermLift))pt 且速度 "
                    + "\(Int(AevonEdgeEntry.floatTermVelocity))pt/s 以上才关；"
                    + "推过 \(Int(AevonEdgeEntry.floatTermBigLift))pt 也算"
                    + "（AevonBottomSplitV325 AevonTermFollowV326）")
            }
        }
        if floatTermArmed {
            floatTermLastPoint = point
            floatTermLastAt = now
            floatTermTrack.append((now, point))
            while floatTermTrack.count > AevonEdgeEntry.floatTermWindowFrames {
                floatTermTrack.removeFirst()
            }
            // 跟手上移（两腿共用窗口级 API，先到者独占，防双倍位移）
            win.updateTerminationFollow(upward: max(0, floatTermPoint.y - point.y))
            floatDeadline = now + floatDragLimit
            return true
        }
        if floatBarPending {
            if now >= floatBarHoldDeadline {
                floatBarPending = false
                guard let grab = floatGrab, case .bar = grab else {
                    sealZombieTouch(touchID)
                    clearFloatGesture()
                    return false
                }
                win.grabBegin(grab, at: AevonEntryHost.floatLayerPoint(fromScreen: point))
                AevonLog.info("[窗口] 落指即拖 → 开始移动（全局通道）（AevonFloatEdgeGripV227）")
            } else if hypot(point.x - floatBarHoldPoint.x,
                            point.y - floatBarHoldPoint.y) > floatBarHoldRadius {
                floatBarPending = false
                sealZombieTouch(touchID)
                clearFloatGesture()
                AevonLog.info("[窗口] 边条按住未达时长即移动 → 放弃接管（AevonFloatBarHoldV221）")
                return false
            } else {
                floatDeadline = now + floatDragLimit
                return true
            }
        }
        floatDeadline = now + floatDragLimit
        win.grabUpdate(to: AevonEntryHost.floatLayerPoint(fromScreen: point))
        return true
    }

    /// 窗口测速（V0.3.26 AevonTermWinVelV326）：取最近 ≤100ms 内首尾两点做 Δ。
    /// 与视图侧 `AevonWindowView.terminationWindowVelocity()` 同源；样本不足 → 返回 .zero
    /// （判据自然不成立，绝不误关）。
    private static func floatTermWindowVelocity(final: CGPoint, at now: CFTimeInterval) -> CGPoint {
        floatTermTrack.append((now, final))
        while floatTermTrack.count > floatTermWindowFrames { floatTermTrack.removeFirst() }
        guard let last = floatTermTrack.last else { return .zero }
        var first = last
        for sample in floatTermTrack.reversed() {
            if last.0 - sample.0 > floatTermWindow { break }
            first = sample
        }
        let dt = last.0 - first.0
        guard dt >= 0.008 else { return .zero }
        return CGPoint(x: (last.1.x - first.1.x) / dt, y: (last.1.y - first.1.y) / dt)
    }

    /// 抬手 / 取消。返回 true = 已消费，调用方 return。
    private static func handleFloatGestureEnded(point: CGPoint, touchID: UInt,
                                               cancelled: Bool) -> Bool {
        guard floatTouchID != 0, touchID == floatTouchID else { return false }
        let win = floatWindow
        /* V0.3.25（AevonBottomSplitV325）：底边在**抬手**收口。
         * 三种结局：①没进预备态 = 普通移动，走下面的 grabEnd；
         * ②进了预备态但没上甩 = 回位、不关窗；③进了预备态且命中判据 = 关窗。
         * 判据与视图侧 `terminationShouldClose` 同源（Stheno `sc_shouldCloseForBottomUpwardFlick:`）：
         * 上移 ≥24pt、上滑速度 ≥260pt/s、|vx| × 1.35 ≤ 上滑速度。 */
        if floatTermCandidate {
            let now = CACurrentMediaTime()
            let upward = floatTermPoint.y - point.y
            let dragX = floatTermPoint.x - point.x
            let velocity = floatTermWindowVelocity(final: point, at: now)
            let rise = -velocity.y
            let vx = velocity.x
            let frames = floatTermTrack.count
            let armed = floatTermArmed
            floatTermCandidate = false
            floatTermArmed = false
            if armed {
                clearFloatGesture()
                /* V0.3.26（AevonTermWinVelV326）：三条出口，方向锥对三条都生效 ——
                 *   ① Stheno 原式：上移 ≥24 且窗口测速 ≥260；
                 *   ② 跟手后短距快甩：上移 ≥48 且 ≥200；
                 *   ③ 大位移慢推：上移 ≥120 且方向对（不看速度）。
                 * 0.3.25 只有 ①，实测 25 次才关掉 5 次。 */
                let coneOK = rise > 0 && abs(vx) * AevonEdgeEntry.floatTermCone <= rise
                let fire = !cancelled
                    && upward >= AevonEdgeEntry.floatTermLift
                    && (coneOK
                        && (rise >= AevonEdgeEntry.floatTermVelocity
                            || (upward >= AevonEdgeEntry.floatTermFollowLift
                                && rise >= AevonEdgeEntry.floatTermFollowVelocity))
                        || (upward >= AevonEdgeEntry.floatTermBigLift
                            && abs(dragX) * AevonEdgeEntry.floatTermCone <= upward))
                // 关窗路径不需要回位（窗要没了）；未关则弹回长按成立时的几何
                win?.endTerminationFollow(restore: !fire)
                if fire, let w = win {
                    AevonLog.info("[窗口] 底边上甩 → 关闭浮窗（上移 \(Int(upward))pt / "
                        + "速度 \(Int(rise))pt/s / 横向 \(Int(dragX))pt / 窗口测速 \(frames) 帧）"
                        + "（AevonBottomSplitV325 AevonTermFollowV326；收容 AevonFloatBottomDblCloseV221"
                        + " AevonDblTapHealV256 AevonDblTapGuardV261）")
                    AevonWindowManager.close(bundleID: w.bundleID)
                } else {
                    AevonLog.info("[窗口] 底边长按后未达上甩判据 → 不关窗（上移 \(Int(upward))pt"
                        + " / 速度 \(Int(rise))pt/s / 横向 \(Int(dragX))pt）"
                        + "（AevonBottomSplitV325 AevonTermFollowV326）")
                    win?.grabCancel()
                }
                return true
            }
            // 没进预备态：这次是普通移动/轻点，落回下面的通用收口
        }
        if floatBarPending {
            floatBarPending = false
            /* 边条上的轻点（没有拖动）：左右缘 = 停靠 / 装回（AevonDockTapV251）；
             * 底边轻点 = 无动作（V0.3.25 起底边既能移动也能关闭，但轻点本身不承载语义）。 */
            if !cancelled, let grab = floatGrab, case .bar(let edges) = grab, win != nil {
                if edges == .left || edges == .right {
                    let side: AevonDockSide = edges == .left ? .left : .right
                    if win!.isDocked {
                        AevonWindowManager.restoreDocked(bundleID: win!.bundleID)
                    } else {
                        AevonLog.info("[窗口] 边条轻点 → 吸附停靠到屏幕\(side.title)侧（AevonDockTapV251）")
                        _ = AevonWindowManager.dockCurrent(side: side)
                    }
                } else {
                    AevonLog.info("[窗口] 底边轻点无动作（底边可移动、按住 0.4s 后上甩才关闭）"
                        + "（AevonBottomSplitV325）")
                }
            }
            clearFloatGesture()
            return true
        }
        let layerPoint = AevonEntryHost.floatLayerPoint(fromScreen: point)
        if cancelled {
            win?.grabCancel()
        } else {
            win?.grabEnd(at: layerPoint, commit: true)
            /* V0.3.24（AevonBottomFlickV324）：双击候选登记整体退役。
             * 0.2.61（AevonDblTapGuardV261）往这里写过「原地轻点才登记双击第一击」，
             * 那是为了给底边双击服务；双击语义已换成上滑关闭，写入没有任何读取者，
             * 留着只会让后来者以为双击还在。 */
        }
        clearFloatGesture()
        return true
    }

    private static func clearFloatGesture() {
        floatTouchID = 0
        floatWindow = nil
        floatGrab = nil
        floatDeadline = 0
        floatBarPending = false
        floatBarHoldDeadline = 0
        lastFloatMovedAt = 0
        // V0.3.25（AevonBottomSplitV325）：底边长按/预备态随手势一起清（丢 ended 时不残留）
        // V0.3.26（AevonTermWinVelV326）：测速环形缓冲一并清空
        floatTermCandidate = false
        floatTermArmed = false
        floatTermBeganAt = 0
        floatTermTrack.removeAll(keepingCapacity: true)
    }

    /// V0.2.57（AevonZombieSealV257）：把一根「began 已被本通道吞掉」的触摸封印到抬手。
    ///
    /// 协议（AevonTouchHook.m）：began/moved 先上报再询问、ended 先询问再上报，
    /// 吞咽 = 整条事件不投递。于是只要吞过某根手指的 began，UIKit 就**永远没见过它**；
    /// 此时任何中途弃管（放弃接管 / 30s 超时 / 残留盾清场 / 关窗强制解除）都会让
    /// 后续帧以「孤儿」身份转发给 UIKit —— 有 began 没簿记的帧序列污染手势环境
    ///（识别器全部健康但 pan 死、点按活的头号嫌疑；Aevon(31) 探针全健康反向证实
    /// 杀手不在识别器层）。封印后：该指针的 began/moved 一律吞到 ended 为止，
    /// 绝不漏孤儿帧；ended/cancelled 放行（无害且能替重投副本收尾）。硬上限 30 秒。
    private static func sealZombieTouch(_ touchID: UInt) {
        guard touchID != 0 else { return }
        zombieSealID = touchID
        zombieSealUntil = CACurrentMediaTime() + 30
        AevonLog.warn("[边缘] 触摸 \(touchID) 的 began 已被吞、现在中途弃管 → 封印到抬手，不再漏孤儿帧给 UIKit"
            + "（AevonZombieSealV257）")
    }

    /// V0.2.56（AevonCloseDisarmV256）：浮窗生命周期收尾（关窗 / 关停靠小窗）强制解除
    /// 全局通道的拖拽吞咽状态 —— 窗口没了，残留的 floatTouchID 只剩「误吞同槽位
    /// 新触摸」一种结局（UITouch 槽位地址复用已被 Aevon(30) 日志实锤：同一地址
    /// 64441673984 在 2.4 秒内被两次登记为不同的手指）。幂等，无状态时零开销。
    static func forceDisarmFloatGesture(reason: String) {
        guard floatGestureActive || floatBarPending else { return }
        let held = floatTouchID
        sealZombieTouch(held)
        clearFloatGesture()
        AevonLog.warn("[边缘] \(reason) → 强制解除拖拽吞咽状态（touchID=\(held)）"
            + "（AevonCloseDisarmV256）")
    }

    // MARK: - 圆盘呼出 / 收起

    /// 呼出圆盘（0.2.51 起唯一调用方 = AevonRingGrip 可见把手）。
    static func presentRing(source: String) {
        guard let root = AevonEntryHost.activeRoot else {
            AevonLog.warn("[圆盘] 入口窗口不可用，无法呼出")
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastTriggerAt > 0.6, !AevonRingMenu.isPresented else { return }
        lastTriggerAt = now
        AevonEntryHost.raise(reason: "呼出圆盘")
        AevonRingMenu.present(in: root)
        // V0.2.60（AevonGripSwipeGlobalV260）：全局通道那条路没有 `onSummon`，
        // 收起把手的动作必须放在这里统一做，否则圆盘张开时右缘还挂着一条竖条。
        //（圆盘收起时 AevonRingMenu 会把它放回来，两处配套。）
        AevonRingGrip.setVisible(false)
        // 唤出圆盘的那根手指还没离开屏幕 —— 把它的位置交给圆盘，后续移动就是旋转。
        let pointerSource = (source == "appedge") ? "global" : source
        AevonRingMenu.presented?.beginRemoteTracking(at: lastTouchPoint, source: pointerSource)

        ringSource = "global"
        swallowDeadline = CACurrentMediaTime() + swallowLimit
        // V0.2.72（AevonSBSwallowSealV272）：SBSwallow **重新焊死**（回退 0.2.71 转正）。
        // Aevon(44) 实锤：转正后圆盘内触摸走进本函数的接管分支（0.2.70 前恒 false 的
        // 死代码），在 SB 进程 main queue 上 swift_dynamicCast SIGTRAP = SpringBoard
        // 注销（用户感知「点录屏图标自动注销」）。按 0.2.12 原判：SB 侧吞路径对
        // 稳定性风险不可控 —— 盘上滑动的 App 侧覆盖改由 AevonAppSide.m 的 bit39
        // 全吞（纯 ObjC @try 包裹，无 dynamicCast）承担；无注入 App（抖音）场景
        // 本轮放弃覆盖，等崩溃面切除后另寻 ObjC 通道。
        if AevonPrefs.bool("SBSwallow", default: false),
           globalTouchID != 0, now - lastTouchAt < 0.6 {
            ownsTouch = true
            globalOwnedForTouch = globalTouchID
            globalOwnedAt = now
        }
        /* V0.3.29（AevonOwnSwallowV329）：自建腿召唤 → 把这根手指**真的**绑进吞层。
         *
         * 必须放在上面那段之后，且不受 `SBSwallow` 开关约束 —— 那个开关管的是
         * 「圆盘内的触摸怎么走」，而这里要解决的是「召唤那根手指被下层吃掉了」。
         *
         * Aevon(102) 的 40 次桌面召唤全部伴随桌面翻页、37 次抖音召唤大概率进博主页，
         * 根因就是这根手指从头到尾没被吞：`presentRing` 把 `ringSource` 写成
         * "global" 之后，下一帧「收养」分支会把它标成 `gripAdoptedTouchID`，
         * 而 `shouldSwallowGlobalTouch` 对收养指纹的第一条就是 `return false`。
         *
         * 指针身份由 ObjC 侧在 `-touchesBegan:` 里记下（和 `sendEvent:` 收到的是
         * 同一批 `UITouch` 实例），所以这里的相等判断是精确的。取不到就什么都不做，
         * 行为退回 0.3.28 —— 只是少一层保护，不会误吞别人的手指。 */
        if source == "ownleg", AevonPrefs.bool("OwnSwallow", default: true) {
            let tid = AevonGripOwnTouchIDBridge()
            if tid != 0 {
                /* V0.3.30（AevonEarlyBindV330）：落指预绑过的话，这里只做「转正」。
                 * 转正 = 把 `ownSwallowBound` 置真（喂盘走权威通道）+ 把吞窗口从
                 * 4 秒续到 12 秒，簿记已经是这一根，不需要重绑。 */
                let prebound = (globalTouchID == tid && ownsTouch)
                globalTouchID = tid
                globalStart = lastTouchPoint
                globalFired = true
                ownsTouch = true
                ownSwallowBound = true
                gripAdoptedTouchID = 0      // 清掉收养指纹：它就是「不吞」的唯一钥匙
                appEdgePointerAdopted = false
                globalOwnedForTouch = tid
                globalOwnedAt = now
                swallowDeadline = now + swallowLimit
                /* 抬手帧要放行的那根手指就是它 —— 转正之后也要继续记住，
                 * 否则 App 会留着「有 began 无终止帧」的孤儿触摸。 */
                preBindTid = tid
                preBindAt = now
                if prebound {
                    AevonLog.info("[圆盘] 预绑转正 touchID=\(tid)"
                        + " → 整根手指全程被吞，App 只拿到落指那一帧（零位移）"
                        + "（AevonEarlyBindV330 AevonOwnSwallowV329）")
                } else {
                    AevonLog.info("[圆盘] 自建腿手指已绑全局吞层 touchID=\(tid)"
                        + " → 桌面/App 从下一帧起收不到这根手指"
                        + "（AevonOwnSwallowV329 AevonOwnTouchBindV329）")
                }
                /* 移交自建腿簿记：只作废手指身份（防吞层回喂重复判据）。
                 * V0.3.31（AevonSwallowFeedV331）：不再清 `_ownSummoned` —— 抬手帧是放行的，
                 * 识别器收得到 ended、`-reset` 照样会来，保留标记才能打出
                 * `吞层实丢 N 帧` 这条唯一的吞层判据（0.3.29/0.3.30 就是在这里丢的）。 */
                AevonGripOwnHandoffBridge()
            } else {
                AevonLog.warn("[圆盘] 自建腿手指身份为空（ObjC 侧已 reset）→ 本轮不绑吞层，"
                    + "手指照旧漏给下层（AevonOwnTouchBindV329）")
            }
        }
        // V0.0.34（AevonNotifyRingBitV34）：圆盘状态写进 notify(3) 共享内存。
        AevonNotifySetRing(1)
        AevonLog.info("[圆盘] 指针已交给圆盘（来源 \(source)；把手是真实控件，命中无需吞摸；"
            + "V0.2.72 SBSwallow 已重新焊死，盘上覆盖走 App 侧 bit39）"
            + "（AevonRingSwallowV24 AevonGripOnlyV251 AevonSBSwallowSealV272）")
    }

    // MARK: - V0.3.4（AevonGripSystemLegV304）：系统识别器腿

    /// 系统腿回调（由 AevonGripHook.m 在系统边沿识别器的动作里调用）。
    ///
    /// 这条腿与把手腿的本质区别：**触摸归属不变**。识别器是系统自己的，我们只是给它
    /// 外挂了一个 target；App 那边收到的序列由系统按它本来的 cancel 语义处理，我不从
    /// sendEvent 里扣任何一帧 —— 这是 Stheno「一根手指都不碰」的同构做法。
    static func systemLegSummon(x: CGFloat, y: CGFloat, startX: CGFloat,
                                startY: CGFloat, cls: String) {
        guard AevonPrefs.bool("Enabled", default: true) else {
            legBlocked(cls: cls, reason: "总开关关")
            return
        }
        guard AevonRingMenu.presented == nil else {
            legBlocked(cls: cls, reason: "圆盘已开")
            return
        }
        /* V0.3.18（AevonSceneGateV318）：借腿是兜底通道（自建腿就绪时不呼盘），但只要它
         * 还活着，就同样不许在控制中心 / 通知中心 / 锁屏里呼盘 —— 判据与自建腿共用
         * `AevonRingGrip.systemOverlayBlockingRing()`，两边不许各写一套。 */
        let overlayLeg = AevonRingGrip.systemOverlayBlockingRing()
        if !overlayLeg.isEmpty {
            legBlocked(cls: cls, reason: "系统浮层在屏（\(overlayLeg)）→ 不呼盘")
            return
        }
        /* V0.3.13（AevonOwnGateV313）：自建腿已注册 → 借腿**整条退为兜底**，不再呼盘。
         *
         * 依据 Aevon(91)：开关打开的 55 秒里 27 次呼盘 **27 次全走自建腿**，
         * 关掉的 7 秒里 3 次 **3 次全走借腿** —— 两只腿的能力差异已经不需要再共存验证。
         * 而那 29 条「达阈值但被拦 原因=圆盘已开」说明借腿每次都在自建腿之后到，
         * 纯粹白算一遍：先跟踪 changed、算满 8pt、再发现圆盘已经开。
         *
         * 保留（不删）的理由：自建腿注册依赖 `_UISystemGestureManager`，万一某次
         * respring 后注册没成，`AevonGripOwnLegReady()` 立刻变 NO，借腿自动全部接回来 ——
         * 这就是它作为「兜底」的全部职责。 */
        /* V0.3.28（AevonYieldGuardV328）：判据从「自建腿识别器已注册」（静态事实）
         * 改成「**本手势**自建腿真的接管了」（0.15s 内打出过 hold）。
         *
         * Aevon(101) 里 6 次出现「系统腿认领 → 达阈值但被拦 原因=自建腿已注册 →
         * 自建腿 hold 一行都没有」= 两头空：我们拦住了系统腿，自己又没接这根手指，
         * 用户感知就是「完全没反应」。带外的落指本来就该原样交给系统，
         * 拦住它没有任何收益。 */
        let holdAge = AevonGripOwnHoldAgeBridge()
        if holdAge < 0.15 {
            legBlocked(cls: cls, reason: "自建腿本手势已接管（\(Int(holdAge * 1000))ms 前 hold）")
            return
        }
        // V0.3.11（AevonOwnSuppressV311）：同一次手势里，自建腿已经在 0.35s 内呼过盘了。
        // 以前靠「圆盘已开」拦第二条，会多打一条「达阈值但被拦」；自建腿接管后这里主动让路。
        let ownAge = AevonGripOwnSummonAge()
        if ownAge < 0.35 {
            legBlocked(cls: cls, reason: "自建腿已抢先（\(Int(ownAge * 1000))ms 前）")
            return
        }
        // V0.3.6（AevonGripYieldDeepV306）：右缘判据改用 **began 落点**，不再用当前点。
        // Aevon(84) 日志实锤 7 条「达阈值但被拦 原因=不在右缘 24pt 内」：左滑 20pt 后
        // 手指已从 x=420 滑到 x=400，而 400 < 430-24=406 → 自己把自己否决。呼盘手势
        // 天然向左位移，用当前点判右缘等于「滑得越到位越不被认」。startX<=0 兜底用当前点。
        let edgeRef = startX > 0 ? startX : x
        let screen = UIScreen.main.bounds
        /* V0.3.8（AevonGripZoneV308）：触发范围从「右缘 24pt + y 不限」收成**一条带**。
         *
         * 用户 Aevon(86)：换成系统手势后「整个右侧都会触发圆盘，还会和左滑返回插件冲突」。
         * 现场数据：68 次呼盘起点 x 406~425（全在右缘），但落点 y 从 381 一直铺到 722 ——
         * 判据里根本没有 y，所以右缘任意高度左滑都会呼盘。
         * 现在横向取 GripWidth、纵向取 GripY/GripLen 算出的把手带（含上下余量）。
         * 带外的右缘左滑不再被我们截胡，归还给侧滑返回插件。 */
        let band = AevonRingGrip.bandRect(screenW: screen.width, screenH: screen.height)
        guard band.width > 0 else {
            legBlocked(cls: cls, reason: "屏幕尺寸异常")
            return
        }
        /* V0.3.28（AevonEdgeBandOnly328）：暂扣段已整体取消，借腿与自建腿共用**同一条**
         * `bandRect`。以前借腿用 `padRect`（band+35pt）把「落点偏内」的手指捞回来，
         * 但自建腿在 0.3.28 之后已经接管到 15pt、带外一律不碰 —— 借腿如果还伸到 44pt，
         * 就又变成「带外那颗手指被两边抢」。一条几何、两个消费方，谁都不许自己加宽。
         * 用当前 x 会自杀（左滑天然向左），所以一律用 began 起点。 */
        guard edgeRef >= band.minX else {
            legBlocked(cls: cls, reason: "不在右缘 \(Int(band.width))pt 内（起点x=\(Int(edgeRef)) 当前x=\(Int(x))）")
            return
        }
        if !AevonRingGrip.scopeFullEdge {
            let yRef = startY > 0 ? startY : y
            guard yRef >= band.minY && yRef <= band.maxY else {
                legBlocked(cls: cls, reason: "不在底部区内（起点y=\(Int(yRef)) 区=\(Int(band.minY))~\(Int(band.maxY))，GripScope 关着）")
                return
            }
        }
        guard CACurrentMediaTime() - lastTriggerAt > 0.6 else {
            /* V0.3.5（AevonGripYieldV305）：0.6s 节流拦下要记账 —— Aevon(83) 日志里
             * 60 次呼盘只有 3 次走系统腿，无法判断是「没认领」「没到阈值」还是
             * 「到了却被节流吞掉」。不记账就永远只能猜。 */
            legBlocked(cls: cls, reason: "0.6s 节流")
            return
        }
        let point = CGPoint(x: x, y: y)
        lastTouchPoint = point
        // V0.3.12（AevonOwnClaimV312）：呼盘之前先「连带认领」这根手指。
        // 自建腿此刻正 hold 着它（落点在带内才 hold），认领 = 让它进 Began、
        // 把 App 已派发的触摸 cancel 掉，并且让它真的「识别成功」一次 ——
        // Aevon(90) 里「只有第一次不跟手」的根因就是它从没成功过，UIKit 撤了延迟资格。
        AevonGripOwnLegClaimBridge()
        AevonLog.info("[圆盘] 系统识别器腿呼盘（\(cls)，右缘起点 x=\(Int(edgeRef)) → 左滑 8pt）"
            + "：骑系统边沿手势，不从 App 投递链里扣手指"
            + "（AevonGripSystemLegV304 AevonGripLegTagV304 AevonGripYieldDeepV306）")
        presentRing(source: "system")
    }

    // MARK: - V0.3.9（AevonGripOwnLegV309）：自建识别器腿

    /// V0.3.14（AevonEdgePadV314）：自建腿的落点预判分成两段，返回值即「接管等级」。
    ///
    /// `0` = 不接管（立刻 failed 放行）；`1` = 贴边落点（宽松判据）；`2` = 边缘候选
    /// （暂扣，首帧 moved 走严格判据）。ObJC 侧按返回值决定 `_ownStrict`。
    ///
    /// 为什么不再是一个 Bool：0.3.13 把触发区做成 25%（≈107pt）宽，一口气吃掉了
    /// 抖音底部进度条与右下角按钮。收到 5pt 后又会把「落点偏内 10~30pt」的呼盘全漏掉。
    /// 两段式把这两个矛盾同时解掉 —— 贴边照旧宽松，偏内先扣一帧再看方向。
    static func ownLegHitLevel(x: CGFloat, y: CGFloat) -> Int32 {
        guard AevonPrefs.bool("Enabled", default: true) else { return 0 }
        // V0.3.15（AevonGripHardcodeV315）：自建腿**恒开**，原来这里读 GripOwnLeg 的
        // guard 已删除（设置页也不再显示该开关）。历史依据见 AevonBootstrap 里的注释：
        // 0.3.12 实测 27/27 全走这条腿，它就是「App 不跟手」的唯一来源。
        guard AevonRingMenu.presented == nil else { return 0 }
        let screen = UIScreen.main.bounds
        let core = AevonRingGrip.bandRect(screenW: screen.width, screenH: screen.height)
        guard core.width > 0, core.height > 0 else { return 0 }
        let inBandY = AevonRingGrip.scopeFullEdge || (y >= core.minY && y <= core.maxY)
        guard inBandY else { return 0 }
        /* V0.3.28（AevonEdgeBandOnly328）：只剩 0 / 1 两档。
         *
         * 原来的 level 2（暂扣区）= 「落点在带外先扣住，首帧用严格判据决定」。
         * Aevon(101) 的 49 次 hold 里 41 次落在 12~15pt、5 次被 22° 锥放掉，
         * 而续判日志证明那 5 次第 2 帧更斜（dx=-47 dy=28），续判一帧都救不回来 ——
         * 扣住它们只是让 UIKit 在放行时把整段补投给 SpringBoard（= 翻页）。
         * 现在带外一个字节都不碰，`_ownStrict` 也随之退役。 */
        return (x >= core.minX) ? 1 : 0
    }

    /// 兼容入口（`AevonGripOwnBandHit` 仍然只回 0/1）：给「贴边落点」这一档用。
    static func ownLegBandHit(x: CGFloat, y: CGFloat) -> Bool {
        return ownLegHitLevel(x: x, y: y) == 1
    }

    /// 自建腿呼盘 —— ObjC 侧在 `touchesMoved` 达到阈值那一刻调用。
    ///
    /// 与 `systemLegSummon` 的差别只在记账文案，机制上完全不同：那一条是「借别人赢下的
    /// 仲裁」，触摸的 began 早已派发给 App；这一条是「自己的识别器赢下仲裁」，落指第一帧
    /// 就被扣住，App 连 began 都收不到 —— 也就是「呼盘时 App 一像素都不跟」。
    static func ownLegSummon(x: CGFloat, y: CGFloat, startX: CGFloat, startY: CGFloat) {
        guard AevonPrefs.bool("Enabled", default: true) else {
            ownLegBlocked("总开关关")
            return
        }
        guard AevonRingMenu.presented == nil else {
            ownLegBlocked("圆盘已开")
            return
        }
        /* V0.3.18（AevonSceneGateV318）：系统浮层兜底闸。
         *
         * 主闸在 ObjC 侧 `-touchesBegan:`（那里判到浮层就直接 Failed、把手指原样还回去）。
         * 这里只是兜底：落指时还没有浮层、达阈值之前那 0.28 秒里用户把控制中心拉了出来
         * —— 极罕见，但一旦发生，圆盘会盖在控制中心上面（用户报的就是这个观感）。
         *
         * ⚠️ 走到这里说明 `_ownSummoned` 已经是 YES、这根手指已经扣住了，拒绝呼盘不会
         * 自动还回去；它会在抬手时由 `AevonGripOwnLift` 正常收尾。所以**这道闸不能
         * 取代主闸**，只是补一个时间窗。 */
        let overlay = AevonRingGrip.systemOverlayBlockingRing()
        if !overlay.isEmpty {
            ownLegBlocked("系统浮层在屏（\(overlay)）→ 不呼盘")
            return
        }
        guard CACurrentMediaTime() - lastTriggerAt > 0.6 else {
            ownLegBlocked("0.6s 节流")
            return
        }
        let point = CGPoint(x: x, y: y)
        lastTouchPoint = point
        // V0.3.11：真的呼盘了才盖时间戳 —— 只在守卫全过之后盖，
        // 这样「自建腿想呼但被拦」不会白占 0.35s 抑制窗、把系统腿也拖下水。
        AevonGripOwnStampSummon()
        AevonLog.info("[圆盘] 自建识别器腿呼盘（右缘起点 x=\(Int(startX))"
            + " → 左滑 \(Int(max(0, startX - x)))pt）："
            + "触摸从落指第一帧就被扣住，App 收不到 began"
            + "（AevonGripOwnLegV309）")
        /* V0.3.17（AevonOwnFeedV317）：来源名从 `"system"` 改成 `"ownleg"`。
         * `"system"` 这个字符串从 0.1.13 起就没有活着的喂料方（见 `claimPointer`
         * 上方的账），绑上去等于开局先认一个哑巴当指针 —— 0.12 秒盲区就是从这来的。
         * `"ownleg"` 是**真的有喂料方**的名字（`ownLegMove`），所以第一帧 moved
         * 就能直接对上，不必等交换闸。 */
        presentRing(source: "ownleg")
    }

    /// V0.3.16（AevonOwnLiftV316）：自建腿抬手 —— **圆盘的权威终点信号**。
    ///
    /// 为什么这条是权威的：它来自**召唤那根手指所属的识别器**，不是任何一条喂料通道。
    /// 一根手指只属于一个识别器，所以「这条抬手是这根手指的抬手」不需要推理，
    /// 也就不该再过 `claimPointer` 的 0.12s 通道交换闸（那道闸是给「两根手指换车道」
    /// 用的，抬手帧套上去只会被静默吞掉 —— Aevon(93) 那 16 次僵住就是这么来的）。
    ///
    /// `cancelled = true` 也按抬手处理：对这根 touch 而言，被系统摘链意味着
    /// UIKit 不会再给它派任何帧，和离屏等价。这与 0.2.18「取消 ≠ 抬手」不冲突 ——
    /// 那条讲的是「喂料通道不投了、手指还压着」，讲的是通道，不是识别器。
    /// V0.3.17（AevonOwnFeedV317）：自建腿每帧喂盘 —— ObjC 侧 `-touchesMoved:` 里调用。
    ///
    /// `authoritative: true` 的含义与 `remoteLift` 完全一致：坐标来自**持有这根手指的
    /// 识别器**，与手指一对一，不需要「原通道已静默」的旁证，因此不过 `claimPointer`
    /// 的 0.12 秒交换闸。圆盘已经收起时 `presented` 为 nil，这只是一次空调用。
    static func ownLegMove(x: CGFloat, y: CGFloat) {
        guard let ring = AevonRingMenu.presented else { return }
        ring.remoteMoved(to: CGPoint(x: x, y: y), source: "ownleg", authoritative: true)
    }

    static func ownLegLift(x: CGFloat, y: CGFloat, cancelled: Bool) {
        guard let ring = AevonRingMenu.presented else { return }
        ring.remoteLift(at: CGPoint(x: x, y: y), source: "ownleg")
        if cancelled {
            AevonLog.info("[圆盘] 自建腿被摘链 (x=\(Int(x)),y=\(Int(y))) → 按抬手处理，当场收起"
                + "（AevonOwnLiftV316）")
        } else {
            AevonLog.info("[圆盘] 自建腿抬手 (x=\(Int(x)),y=\(Int(y))) → 当场收起，"
                + "不再等 1.0s 静默看门狗（AevonOwnLiftV316）")
        }
    }

    /// 自建腿放行/被拦的记账（限流 1s：`touchesBegan` 是触摸热路径，不许刷日志）。
    private static var ownLegLastLogAt: CFTimeInterval = 0
    static func ownLegBlocked(_ reason: String) {
        let now = CACurrentMediaTime()
        guard now - ownLegLastLogAt > 1.0 else { return }
        ownLegLastLogAt = now
        AevonLog.info("[圆盘] 自建识别器腿放行/被拦：\(reason)（AevonGripOwnLegV309）")
    }

    /// V0.3.4（AevonGripProbe5V304）：实例级探针。
    ///
    /// V0.3.5（AevonGripYieldV305）修正限流口径：0.3.4 用的是「每类最多 6 条」，
    /// Aevon(83) 日志里 18 条（3 类 × 6）在前 20 秒就打满、之后全程静默 ——
    /// 恰好把「把手区内到底认领没有」这个决定架构的未知量永久遮住。
    /// 改成**按时间**限流：同一个类 2s 内最多 1 条，全局上限 240 条（约 20KB 日志）。
    private static var legProbeCounts: [String: Int] = [:]
    private static var legProbeLastAt: [String: CFTimeInterval] = [:]
    private static var legProbeTotal = 0

    /// V0.3.5：探针开关的 5 秒缓存。
    ///
    /// `AevonGripLegOutcome` 由 ObjC 侧在**每根手指结束**时调用，而 `AevonPrefs.bool`
    /// 走 CFPreferencesCopyAppValue = 跨进程查询。直接读 = 把 IPC 塞进触摸热路径
    /// （0.2.82 那条教训同源：热路径不许做重活）。这里 5 秒窗口缓存一次，代价归零。
    private static var legProbeFlagCached = false
    private static var legProbeFlagAt: CFTimeInterval = 0

    private static func legProbeOn() -> Bool {
        let now = CACurrentMediaTime()
        if now - legProbeFlagAt > 5.0 {
            legProbeFlagAt = now
            AevonPrefs.synchronize()
            legProbeFlagCached = AevonPrefs.bool("GripHookProbe", default: false)
        }
        return legProbeFlagCached
    }

    /// 探针/结局日志共用的一道闸：同类 2s 一条 + 全局 240 条。
    private static func legLogAllowed(_ cls: String) -> Bool {
        if legProbeTotal >= 240 { return false }
        let now = CACurrentMediaTime()
        if now - legProbeLastAt[cls, default: 0] < 2.0 { return false }
        legProbeLastAt[cls] = now
        legProbeTotal += 1
        legProbeCounts[cls, default: 0] += 1
        return true
    }

    static func legProbe(cls: String, x: CGFloat, y: CGFloat, edges: Double,
                         delays: Bool, cancels: Bool, viewCls: String) {
        guard legLogAllowed(cls) else { return }
        let edgeText: String
        if edges < 0 {
            edgeText = "非公有Edge类"
        } else {
            edgeText = "edges=\(Int(edges))"
        }
        AevonLog.info("[GripHook] 系统腿认领右缘 began 类=\(cls) 落点=(\(Int(x)),\(Int(y)))"
            + " \(edgeText) 延迟began=\(delays ? "是" : "否")"
            + " 识别时cancel=\(cancels ? "是" : "否") 宿主=\(viewCls)"
            + "（AevonGripProbe5V304 AevonGripYieldV305）")
    }

    /// V0.3.5（AevonGripLegOutcomeV305）：系统腿「认领了但没呼盘」的结局记账。
    ///
    /// 三种走不到呼盘的路径要能分开：
    ///   · kind=1 未达阈值就结束 —— 认领成功、changed 帧也到了，但最大位移不到 8pt
    ///     （= 用户只是轻点/短划，本来就不该呼盘，属正常）
    ///   · kind=2 位移超 60pt 放弃 —— 是别的动作（上下滑/斜划），也正常
    ///   · kind=3 被守卫拦下 —— 达阈值了但被圆盘已开/节流/边界拦掉，**这是要修的**
    static func legOutcome(cls: String, kind: Int, maxDx: Double, frames: Int) {
        guard legProbeOn() else { return }
        guard legLogAllowed(cls) else { return }
        let what: String
        switch kind {
        case 1: what = "未达阈值就结束"
        case 2: what = "位移超 60pt 放弃"
        default: what = "认领后无有效 changed"
        }
        AevonLog.info("[GripHook] 系统腿认领结局 类=\(cls) \(what)"
            + " 最大dx=\(Int(maxDx))pt changed帧=\(frames)（AevonGripLegOutcomeV305）")
    }

    /// V0.3.5（AevonGripYieldV305）：呼盘被守卫拦下的记账（达阈值但没响 = 最可疑的一类）。
    static func legBlocked(cls: String, reason: String) {
        guard legProbeOn() else { return }
        guard legLogAllowed(cls + "#blocked") else { return }
        AevonLog.warn("[GripHook] 系统腿达阈值但被拦 类=\(cls) 原因=\(reason)"
            + "（AevonGripYieldV305）")
    }

    /// 圆盘收起：立刻解除接管，把事件通道还给系统。
    static func ringDidDismiss() {
        ringSource = ""
        appEdgePointerAdopted = false
        swallowDeadline = 0
        globalTouchID = 0
        globalFired = false
        ownsTouch = false
        if ownSwallowBound { AevonGripAssertReleaseBridge() }   // V0.3.29：吞层接手后识别器收不到 ended、reset 也不会来 → 断言必须在这里还
        ownSwallowBound = false   // V0.3.29：绑吞层标记随归属一起归还
        globalOwnedAt = 0
        /* V0.2.89（AevonRingOrphanEndV289）：额外手指（圆盘展开期登记吞掉的那根）
         * began 已被吞，登记不能跟着圆盘一起清 —— 清了它，剩余 moved/ended 帧立刻
         * 放行 = App 收到「有 ended 没 began」的孤儿帧，手势簿记被污染（正是
         * 「孤儿帧污染手势环境」的镜像面，抖音全屏呼盘后手势僵死的头号嫌疑）。
         * 保留登记、把吞咽窗口收窄到 0.5 秒自然过期：手指此刻最多还在屏上收尾，
         * 过期后不会再有帧；同槽位 ID 复用最多误吞半秒内的 began（fail 方向 =
         * 偶发多点失效，可接受）。 */
        if ringExtraTouchID != 0 {
            ringExtraDeadline = CACurrentMediaTime() + 0.5
            AevonLog.info("[圆盘] 收起：额外手指登记保留 0.5s（防孤儿 ended 污染手势簿记"
                + " AevonRingOrphanEndV289）")
        }
        gripAdoptedTouchID = 0
        AevonNotifySetRing(0)
        // V0.2.51（AevonGripOnlyV251）：ringopen/ringclose Darwin 广播已随 App 侧
        // 识别器退役 —— 监听方全部删除，圆盘状态只走 notify(3) 共享内存位。
    }

    /// V0.2.8（AevonSelectionCoolV208）：圆盘选中开窗 → 记 1.5 秒冷静期。
    static func noteSelectionCooldown() {
        selectionCoolUntil = CACurrentMediaTime() + 1.5
    }
    // MARK: - 应用面板

    /// 打开完整应用面板（V0.0.30 起只有单窗模式）。
    static func openPanel() {
        guard let root = AevonEntryHost.activeRoot else {
            AevonLog.warn("[面板] 入口窗口不可用，无法打开面板")
            return
        }
        if let existing = picker {
            existing.removeFromSuperview()
            picker = nil
            return
        }
        let apps = AevonAppList.userApps(forceReload: true)
        let panel = AevonAppPickerView(apps: apps) {
            AevonEdgeEntry.picker = nil
        }
        panel.frame = root.bounds
        root.addSubview(panel)
        picker = panel
    }

    /// 供其它入口复用同一套面板。
}

// MARK: - C 入口（供 AevonTouchHook.m 调用）

/// V0.2.99（AevonGripProbeV299）：SBGrabberTongue 探测回调（供 AevonGripHook.m 调用）。
/// phase：-1=类探测失败 / -2=安装成功 / -3=安装异常；0~3 = touches began/moved/ended/cancelled；
/// V0.3.0（AevonGripProbe2V300）：10~16 = setState: 状态变迁（possible/began/changed/
/// ended/cancelled/failed/recognized），20~26 = _setState: 同表。
/// 只观察打日志（不改任何触摸行为），为呼出手势判据取真机数据。
@_cdecl("AevonGripProbeTouch")
public func AevonGripProbeTouch(_ phase: Int, _ x: CGFloat, _ y: CGFloat) {
    switch phase {
    case -1:
        AevonLog.warn("[GripHook] SBGrabberTongue 类探测失败（iOS/环境差异）→ 本版放弃，呼出走把手通道"
            + "（AevonGripProbeV299）")
    case -2:
        AevonLog.info("[GripHook] 探测钩子已装（touches 四相 + setState:/_setState: + 四类手势入口 + 全局识别器状态机，只观察）"
            + "（AevonGripProbeV299 AevonGripProbe2V300 AevonGripProbe3V301）")
    case -3:
        AevonLog.warn("[GripHook] 探测钩子安装异常 → fail-open（AevonGripProbeV299）")
    case 10...16, 20...26:
        let states = ["possible", "began", "changed", "ended", "cancelled", "failed", "recognized"]
        let st = states[(phase % 10) < states.count ? phase % 10 : 0]
        let via = phase >= 20 ? "_setState:" : "setState:"
        AevonLog.info("[GripHook] 识别器状态变迁 via \(via) → \(st)（AevonGripProbe2V300）")
    default:
        let name = ["began", "moved", "ended", "cancelled"][min(max(phase, 0), 3)]
        AevonLog.info("[GripHook] 抓手舌触摸 \(name) \(Int(x)),\(Int(y))（AevonGripProbeV299）")
    }
}

/// V0.3.1（AevonGripProbe3V301，用户 Aevon(79) #3「一次部署多个手势类探针」）：
/// 广度探测回调（供 AevonGripHook.m 调用）。`kind`：
/// - "recog"     全局 UIGestureRecognizer 状态变迁（cls = 识别器类名，state = 状态）
/// - "pull"      SBGrabberTongue._handlePullGesture:（Stheno 主通道）
/// - "sysgesture" SBReachabilityGestureRecognizer 手势入口
/// - "systouch"  SBSystemGestureManager 触摸入口
/// - "install"/"skip" 安装结果（cls 里带方法名与原因）
/// 只观察打日志，不改任何触摸/手势行为。
/// V0.3.4（AevonGripSystemLegV304）：系统识别器腿的呼盘回调（供 AevonGripHook.m 调用）。
/// 只在系统边沿识别器自己的 changed 帧过阈值时进来，调用点在主队列异步段里，
/// 不会嵌在 UIKit 手势状态机内部开窗。
@_cdecl("AevonGripSystemSummon")
public func AevonGripSystemSummon(_ x: Double, _ y: Double, _ startX: Double,
                                  _ startY: Double,
                                  _ cls: UnsafePointer<CChar>?) {
    let name = cls.map { String(cString: $0) } ?? "edge"
    AevonEdgeEntry.systemLegSummon(x: CGFloat(x), y: CGFloat(y),
                                   startX: CGFloat(startX), startY: CGFloat(startY),
                                   cls: name)
}

/// V0.3.4（AevonGripProbe5V304）：实例级探针回调（只在 GripHookProbe 打开时被调用）。
@_cdecl("AevonGripLegProbe")
public func AevonGripLegProbe(_ cls: UnsafePointer<CChar>?, _ x: Double, _ y: Double,
                              _ edges: Double, _ delays: Int32, _ cancels: Int32,
                              _ viewCls: UnsafePointer<CChar>?) {
    let name = cls.map { String(cString: $0) } ?? "edge"
    let view = viewCls.map { String(cString: $0) } ?? "nil"
    AevonEdgeEntry.legProbe(cls: name, x: CGFloat(x), y: CGFloat(y), edges: edges,
                            delays: delays != 0, cancels: cancels != 0, viewCls: view)
}

/// V0.3.5（AevonGripLegOutcomeV305）：系统腿「认领了但没走到呼盘」的结局回调。
@_cdecl("AevonGripLegOutcome")
public func AevonGripLegOutcome(_ cls: UnsafePointer<CChar>?, _ kind: Int32,
                                _ maxDx: Double, _ frames: Int32) {
    let name = cls.map { String(cString: $0) } ?? "edge"
    AevonEdgeEntry.legOutcome(cls: name, kind: Int(kind), maxDx: maxDx, frames: Int(frames))
}

/// V0.3.9（AevonGripOwnLegV309）：自建腿的落点预判。
/// 用 Int32 而不是 Bool —— C 的 BOOL 在各架构下宽度不同，这里不留类型擦边球。
@_cdecl("AevonGripOwnBandHit")
public func AevonGripOwnBandHit(_ x: Double, _ y: Double) -> Int32 {
    return AevonEdgeEntry.ownLegBandHit(x: CGFloat(x), y: CGFloat(y)) ? 1 : 0
}

/// V0.3.28（AevonEdgeBandOnlyV328）：两档落点判定 —— 0 不接管（带外，一个字节都不碰）/
/// 1 带内（扣住，位移到 8pt 就召唤，不看方向）。0.3.14 的「2 = 暂扣候选」已删除。
@_cdecl("AevonGripOwnHitLevel")
public func AevonGripOwnHitLevel(_ x: Double, _ y: Double) -> Int32 {
    return AevonEdgeEntry.ownLegHitLevel(x: CGFloat(x), y: CGFloat(y))
}

/// V0.3.9（AevonGripOwnLegV309）：自建腿呼盘。
@_cdecl("AevonGripOwnSummon")
public func AevonGripOwnSummon(_ x: Double, _ y: Double,
                               _ startX: Double, _ startY: Double) {
    AevonEdgeEntry.ownLegSummon(x: CGFloat(x), y: CGFloat(y),
                                startX: CGFloat(startX), startY: CGFloat(startY))
}

/// V0.3.16（AevonOwnLiftV316）：自建腿抬手 —— 召唤成功那根手指的终点信号。
/// `cancelled` 用 Int32 传（C 的 BOOL 宽度随架构变，不留类型擦边球）。
@_cdecl("AevonGripOwnLift")
public func AevonGripOwnLift(_ x: Double, _ y: Double, _ cancelled: Int32) {
    AevonEdgeEntry.ownLegLift(x: CGFloat(x), y: CGFloat(y), cancelled: cancelled != 0)
}

/// V0.3.17（AevonOwnFeedV317）：自建腿**每帧**喂盘。
///
/// 与 `AevonGripOwnSummon` / `AevonGripOwnLift` 是同一根手指的三段：起（召唤）、
/// 中（每帧坐标）、终（抬手）。以前「中」这一段缺着，圆盘只能等 SB 全局通道；
/// 而全局通道在每次展开后的前 0.12 秒必盲、被 `.cancelled` 打死之后本周期不许复活
/// —— Aevon(94) 的 11 次「一条移动帧都没收到」就是这么来的。
@_cdecl("AevonGripOwnMove")
public func AevonGripOwnMove(_ x: Double, _ y: Double) {
    AevonEdgeEntry.ownLegMove(x: CGFloat(x), y: CGFloat(y))
}

/// V0.3.30（AevonEarlyBindV330）：落指预绑 —— 由 `-touchesBegan:` 在写完身份之后立刻调用。
///
/// 早于召唤就设，是因为漏帧是结构性的：吞层判据在 SB `-sendEvent:`，识别器在**同一次**
/// `sendEvent:` 内部才判定，于是「began + 首帧 moved」必然先投给 App。Aevon(103) 的
/// 36 次召唤首帧位移中位 18pt、最大 49pt —— App 拿到一个高速横向帧后彻底静止，
/// ScrollView 拿它算惯性、抖音拿它判横滑，这就是「呼盘时 App 内被带动」的全部来源。
@_cdecl("AevonGripPreBindTouch")
public func AevonGripPreBindTouch(_ tid: UInt, _ x: Double, _ y: Double) {
    AevonEdgeEntry.ownLegPreBind(tid: tid, x: CGFloat(x), y: CGFloat(y))
}

/// V0.3.30（AevonEarlyBindV330）：撤销预绑 —— `-ownPass:` 在放行那一刻调用。
/// `tid == 0` 表示调用方已把身份清掉，用 Swift 侧自己记的那一个。
@_cdecl("AevonGripPreBindClear")
public func AevonGripPreBindClear(_ tid: UInt) {
    AevonEdgeEntry.ownLegPreBindCancel(tid: tid)
}

/// V0.3.18（AevonSceneGateV318）：系统浮层闸 —— 控制中心 / 通知中心 / 锁屏（含解锁后
/// 还没上滑进桌面）里不许呼盘。返回 1 = 有浮层在屏，自建腿**必须立刻放行这根手指**。
///
/// 用 Int32 而不是 Bool：C 的 BOOL 在各架构下宽度不同（与 `AevonGripOwnBandHit` 同一条口径）。
@_cdecl("AevonGripSystemOverlayBlocked")
public func AevonGripSystemOverlayBlocked() -> Int32 {
    return AevonRingGrip.systemOverlayBlockingRing().isEmpty ? 0 : 1
}

/// V0.3.26（AevonHomeLooseV326）：桌面判定，给 ObjC 自建腿用。返回 1 = 前台无 App。
///
/// 读 `AevonEntryHost.currentForegroundBundleID` —— 那是场景钩子已经维护好的缓存值
/// （`appSceneDisappeared` 里清空），热路径上只是一次内存读，不查窗口表、不读 prefs。
/// 桌面上没有横向滚动内容可抢，只有翻页，所以判据可以比 App 内宽得多。
@_cdecl("AevonGripHomeScreenNow")
public func AevonGripHomeScreenNow() -> Int32 {
    return AevonEntryHost.currentForegroundBundleID.isEmpty ? 1 : 0
}

/// V0.3.9（AevonGripOwnLegV309）：自建腿的取证/结局日志桥（类普查、挂载、放行原因）。
@_cdecl("AevonGripOwnLog")
public func AevonGripOwnLog(_ kind: UnsafePointer<CChar>?,
                            _ detail: UnsafePointer<CChar>?) {
    let k = kind.map { String(cString: $0) } ?? "?"
    let d = detail.map { String(cString: $0) } ?? ""
    AevonLog.info("[GripHook] 自建腿 \(k)：\(d)（AevonGripOwnLegV309）")
}

@_cdecl("AevonGripProbeEvent")
public func AevonGripProbeEvent(_ kind: UnsafePointer<CChar>?,
                                _ cls: UnsafePointer<CChar>?,
                                _ state: Int) {
    let k = kind.map { String(cString: $0) } ?? "?"
    let c = cls.map { String(cString: $0) } ?? "?"
    switch k {
    case "recog":
        let names = ["possible", "began", "changed", "ended", "cancelled", "failed"]
        let st = (state >= 0 && state < names.count) ? names[state] : "\(state)"
        AevonLog.info("[GripHook] 识别器 \(c) → \(st)（AevonGripProbe3V301）")
    case "install":
        AevonLog.info("[GripHook] 已装 \(c)（AevonGripProbe3V301）")
    case "skip":
        AevonLog.info("[GripHook] 跳过 \(c)（AevonGripProbe3V301）")
    case "census":
        // V0.3.2（AevonGripProbe4V302）：事件投递链类普查结果 —— 类存在性 + 候选方法签名参数数
        AevonLog.info("[GripHook] 类普查 \(c)（AevonGripProbe4V302）")
    default:
        AevonLog.info("[GripHook] \(k) 命中 \(c)（AevonGripProbe3V301）")
    }
}

/// 全局触摸回调。`phase` 是 `UITouchPhase` 的原始值：
/// 0 = began，1 = moved，3 = ended，4 = cancelled（2 = stationary 不会传进来）。
@_cdecl("AevonGlobalTouchPhase")
public func AevonGlobalTouchPhase(_ phase: Int, _ touchID: UInt, _ x: CGFloat, _ y: CGFloat) {
    let mapped: UITouch.Phase
    switch phase {
    case 0: mapped = .began
    case 1: mapped = .moved
    case 3: mapped = .ended
    case 4: mapped = .cancelled
    default: return
    }
    // V0.2.82（AevonYieldTouchGuardV282）：每帧都记一笔「手指还在不在屏上」。
    // 让位巡检要用它拦住「触摸进行中把窗 isHidden」这条崩溃面，见 noteTouchFrame。
    AevonEdgeEntry.noteTouchFrame(phase: mapped)
    AevonEdgeEntry.handleGlobal(phase: mapped, point: CGPoint(x: x, y: y), touchID: touchID)
}

/// V0.0.24：事件是否丢弃（不投递给 App）的判定入口，供 `AevonTouchHook.m` 调用。
@_cdecl("AevonGlobalTouchShouldSwallow")
public func AevonGlobalTouchShouldSwallow(_ touchID: UInt, _ phase: Int) -> Bool {
    return AevonEdgeEntry.shouldSwallowGlobalTouch(touchID, phase: phase)
}

/// V0.0.26：设置页写完偏好后的 Darwin 通知回调。
///
/// 设置 App 与 SpringBoard 是两个进程，写完 `com.Aevon` 后 SpringBoard 的
/// CFPreferences 缓存不会自动失效 —— 这里先 synchronize，再回主线程刷新。
private func aevonPrefsChangedHandler(_ center: CFNotificationCenter?,
                                      _ observer: UnsafeMutableRawPointer?,
                                      _ name: CFNotificationName?,
                                      _ object: UnsafeRawPointer?,
                                      _ userInfo: CFDictionary?) {
    AevonPrefs.synchronize()
    DispatchQueue.main.async {
        // 设置里可能刚改过圆盘 App 列表 / 顺序 —— V0.0.31：带快照防漂移地刷新
        AevonRingStore.refreshFromSettings()
        // V0.2.59（AevonGripCustomV259）：把手位置 / 长度滑条改动 → 竖条实时重排
        AevonRingGrip.refreshFromPrefs()
        // V0.3.15（AevonGripHardcodeV315）：自建识别器腿**恒开**，不再读设置页。
        // 用户 Aevon(93) 定档：默认开启的呼出手势开关写进代码、不再给开关。
        // 0.3.12 已经证明这条腿是「App 不跟手」的唯一来源（Aevon(91) 27/27 全走它），
        // 留个开关等于留个「把唯一通路关掉然后以为插件坏了」的入口。
        // 第二参 GripHookProbe 仍读偏好 —— 它只控制取证深度，设置页已不再显示。
        AevonGripOwnLegEnable(true,
                              AevonPrefs.bool("GripHookProbe", default: false))
    }
}

/// V0.1.2（AevonGuardCleanupV102）：Guard 回执计数与 handler 已随 Guard 移除。
/// 历史 CI 校验串（AevonGuardAckV35）由 AevonAssertionShim.m 的 used 常量收容。

/// V0.3.12（AevonOwnClaimV312）：ObjC 侧「连带认领」入口（AevonGripHook.m 里的
/// `void AevonGripOwnLegClaim(void)`）。借腿真的赢下仲裁、要呼盘的那一刻调进来。
/// 为什么不从 ObjC 侧自己调：`AevonGripSystemSummon` 之后 Swift 里还有总开关/圆盘已开/
/// 自建腿抢先/带外/节流五道守卫 —— ObjC 不知道最终有没有真呼盘，只有这里知道。
@_silgen_name("AevonGripOwnLegClaim")
private func AevonGripOwnLegClaimBridge()

/// V0.3.13（AevonOwnGateV313）：自建腿是否已注册（ObjC 侧 `int AevonGripOwnLegReadyInt(void)`）。
/// 借腿看到它返回非 0 就整条退为兜底 —— 这是 Aevon(91)「27/27 全走自建腿」的直接结论。
/// V0.3.28（AevonYieldGuardV328）：距「本手势被自建腿接管」的秒数（ObjC 侧
/// `double AevonGripOwnHoldAge(void)`，无记录返回 9999）。
@_silgen_name("AevonGripOwnHoldAge")
private func AevonGripOwnHoldAgeBridge() -> Double

@_silgen_name("AevonGripOwnLegReadyInt")
private func AevonGripOwnLegReadyBridge() -> Int32

/// V0.3.29（AevonOwnTouchBindV329）：自建腿当前那根手指的 `UITouch` 指针身份
/// （ObjC 侧 `uintptr_t AevonGripOwnTouchID(void)`）。
///
/// 和 `AevonGlobalTouchPhase` 报上来的 `touchID` 是同一批对象 —— 识别器的
/// `-touchesBegan:` 与 `sendEvent:` 的 `[event allTouches]` 拿到的是同一批 `UITouch`
/// 实例，所以直接比指针相等就能精确对上。返回 0 = ObjC 侧已放行/已 reset。
@_silgen_name("AevonGripOwnTouchID")
private func AevonGripOwnTouchIDBridge() -> UInt

/// V0.3.29（AevonOwnSwallowV329）：把手指移交全局吞层后，清掉自建腿那侧的簿记
/// （ObjC 侧 `void AevonGripOwnHandoff(void)`，只清 `_ownSummoned`/`_ownTouch`/定时器，
/// **不改识别器 state** —— 改 state 会让 UIKit 把延迟中的触摸补投给下层）。
@_silgen_name("AevonGripOwnHandoff")
private func AevonGripOwnHandoffBridge()

/// V0.3.29（AevonOwnSwallowV329）：显式归还系统手势禁用断言
/// （ObjC 侧 `void AevonGripAssertRelease(void)`，内部幂等 + 全 `@try`）。
///
/// 为什么要从 Swift 主动还：手指被全局吞层接走之后，自建识别器收不到 `ended`、
/// 因此 `-reset` 也不会来，而 `ownBailRearm` 这个 ticker 同样靠 moved 驱动 ——
/// 三条自动归还路径同时失效。少了这一句，用户呼一次盘就会失去右滑返回，
/// 直到 respring 才恢复。
@_silgen_name("AevonGripAssertRelease")
private func AevonGripAssertReleaseBridge()
