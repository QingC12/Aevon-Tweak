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
    private static var lastHealLogAt: CFTimeInterval = 0
    /// V0.2.55（AevonGripHealV255）：吞咽日志节流
    private static var lastSwallowLogAt: CFTimeInterval = 0
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
    /// V0.2.21（AevonFloatBottomDblCloseV221）：底边双击候选
    private static var floatLastTapAt: CFTimeInterval = 0
    private static var floatLastTapPoint: CGPoint = .zero
    private static weak var floatLastTapWindow: AevonWindowView?
    /// V0.2.61（AevonDblTapGuardV261，用户 Aevon(35) #4「底边双击容易误触」）：
    /// 两击间隔按用户要求放宽到 0.45 秒（原来 0.34），同时把**两击位置半径收到 16pt**
    /// （原来 26pt —— 底边条才 44pt 高，26pt 半径等于半个条子都算同一点）。
    /// 真正解决误触的是下面那条：拖完 / 缩完松手不再算「第一击」。
    private static let floatDoubleTapGap: CFTimeInterval = 0.45
    private static let floatDoubleTapRadius: CGFloat = 16
    /// V0.2.61（AevonDblTapGuardV261，用户 Aevon(35) #4）：这一根浮窗手势的落点。
    /// 抬手时算位移，用来区分「原地轻点」和「拖完/缩完松手」。
    private static var floatBeganPoint: CGPoint = .zero

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
    /// V0.2.63（AevonGripBusyV263）：当前是否已广播「把手占用」（抬手 / 取消时撤销）
    private static var gripBusyActive = false
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

    static func handleGlobal(phase: UITouch.Phase, point: CGPoint, touchID: UInt) {
        guard AevonPrefs.bool("Enabled", default: true) else { return }
        let screen = UIScreen.main.bounds
        switch phase {
        case .began:
            // V0.2.57（AevonTouchProbeV257）：失效瞬间探针，每根 began 触发（3 秒节流）。
            AevonEntryHost.touchTriggeredProbeIfDue()
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
                // V0.2.63（AevonGripBusyV263，用户 Aevon(37) #7）：一落指就广播「把手占用」，
                // 让被覆盖的全屏 App 立刻把自己的窗口交互关掉 —— UIKit 会把这根手指整根取消，
                // App 内的左滑 / 长按根本没机会开始。这条通道与坐标无关，
                // 不再像 0.2.61/0.2.62 那样「判定矩形没命中就一根都没吞」。
                AevonNotifySetGripBusy(true)
                gripBusyActive = true
                AevonLog.info("[圆盘] 手指落在把手上 (\(Int(point.x)),\(Int(point.y))) → 广播「把手占用」，"
                    + "被覆盖的 App 立刻停收触摸（AevonGripBusyV263）")
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
            // V0.2.60（AevonGripSwipeGlobalV260）：把手左滑 ≥14pt（纵向抖动 ≤40pt）→ 呼盘。
            // 与视图层 pan 同一条判据；两边都命中时圆盘已展开，第二次调用直接跳过。
            if gripSwipeTouchID != 0, touchID == gripSwipeTouchID {
                let dx = point.x - gripSwipeStart.x
                let dy = point.y - gripSwipeStart.y
                if dx < -14, abs(dy) < 40 {
                    gripSwipeTouchID = 0
                    if AevonRingMenu.presented == nil {
                        lastTouchPoint = point
                        AevonLog.info("[圆盘] 把手左滑 \(Int(dx))pt → 呼出圆盘（全局通道，全屏 App 也生效）"
                            + "（AevonGripSwipeGlobalV260）")
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
            if touchID != globalTouchID, AevonRingMenu.isPresented, ringSource == "global",
               !appEdgePointerAdopted, touchID != ringExtraTouchID {
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
                ring.remoteMoved(to: point, source: "global")
                return
            }

        case .ended:
            // V0.2.60（AevonGripSwipeGlobalV260）：抬手即清把手观察态
            if gripSwipeTouchID != 0, touchID == gripSwipeTouchID { gripSwipeTouchID = 0 }
            // V0.2.63（AevonGripBusyV263）：抬手 → 撤销「把手占用」，App 侧恢复交互。
            if gripBusyActive {
                gripBusyActive = false
                AevonNotifySetGripBusy(false)
            }
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
                    swallowDeadline = 0
                    globalOwnedAt = 0
                    gripAdoptedTouchID = 0
                }
            }
            if handleFloatGestureEnded(point: point, touchID: touchID, cancelled: false) { return }
            if touchID == ringExtraTouchID {
                ringExtraTouchID = 0
                ringExtraDeadline = 0
                return
            }
            // 同 moved —— 未登记的手指在圆盘展开期间抬手，也要收养后送达 remoteEnded。
            if touchID != globalTouchID, AevonRingMenu.isPresented, ringSource == "global",
               !appEdgePointerAdopted, touchID != ringExtraTouchID {
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

        case .cancelled:
            if gripSwipeTouchID != 0, touchID == gripSwipeTouchID { gripSwipeTouchID = 0 }
            // V0.2.63（AevonGripBusyV263）：取消同样撤销「把手占用」（fail-open）。
            if gripBusyActive {
                gripBusyActive = false
                AevonNotifySetGripBusy(false)
            }
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
                    swallowDeadline = 0
                    globalOwnedAt = 0
                    gripAdoptedTouchID = 0
                }
            }
            if handleFloatGestureEnded(point: point, touchID: touchID, cancelled: true) { return }
            if touchID == ringExtraTouchID {
                ringExtraTouchID = 0
                ringExtraDeadline = 0
                return
            }
            guard touchID == globalTouchID else { return }
            AevonRingMenu.presented?.remoteCancelled(source: "global")
            globalTouchID = 0
            globalFired = false
            ownsTouch = false

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

    /// `AevonTouchHook.m` 逐帧询问：这根触摸要不要吞掉（不投递给 App）。
    ///
    /// 0.2.51 只剩两类正当吞咽：
    ///   · **浮窗拖拽**（V0.0.41）：手柄在浮窗外侧，落点是 App 内容，不吞会连带拖动 App；
    ///   · **圆盘指针**（V0.0.29 / V0.2.14）：圆盘开着时这根手指不该穿透到桌面 / App。
    /// 其余历史路径（热区整指、右缘接管带、扣移动帧）已随呼盘手势一起删除。
    static func shouldSwallowGlobalTouch(_ touchID: UInt, phase: Int) -> Bool {
        guard AevonPrefs.bool("Enabled", default: true) else { return false }
        guard touchID != 0 else { return false }
        healGlobalTakeoverIfNeeded()
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
        guard globalTouchID != 0, touchID == globalTouchID else { return false }
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
        // V0.2.21（AevonFloatBottomDblCloseV221）：底边双击 = 关闭浮窗。
        if case .bar(.bottom) = hit.grab,
           now - floatLastTapAt <= floatDoubleTapGap,
           floatLastTapWindow === hit.window,
           hypot(point.x - floatLastTapPoint.x,
                 point.y - floatLastTapPoint.y) <= floatDoubleTapRadius {
            floatLastTapAt = 0
            floatLastTapWindow = nil
            floatTouchID = touchID
            floatWindow = hit.window
            floatGrab = nil
            floatDeadline = now + floatDragLimit
            // V0.2.56（AevonDblTapHealV256）：底边双击是最高频关法（Aevon(30) 两次关窗
            // 都是它），这根手指的 ended 若丢帧，floatTouchID 会带 30 秒 deadline 残留
            // —— 0.2.55 的自愈条件是 lastFloatMovedAt > 0 才生效，这条路径原来没设锚点
            // = 残留 30 秒且自愈完全不触发，同槽位新手指被整段吞（pan 死、点按活）。
            lastFloatMovedAt = now
            AevonLog.info("[窗口] 底边双击 → 关闭浮窗（全局通道，自愈锚点已登记）"
                + "（AevonFloatBottomDblCloseV221 AevonDblTapHealV256 AevonDblTapGuardV261）")
            AevonWindowManager.close(bundleID: hit.window.bundleID)
            return true
        }

        floatTouchID = touchID
        floatWindow = hit.window
        floatGrab = hit.grab
        floatDeadline = now + floatDragLimit
        lastFloatMovedAt = now   // V0.2.55：began 也算一次「在场」，丢 ended 时自愈才有锚
        // V0.2.61（AevonDblTapGuardV261，用户 Aevon(35) #4）：记住落点，抬手时算位移。
        // 底边双击的「第一击」只认真正的原地轻点 —— 拖完/缩完再点一下不算。
        floatBeganPoint = point
        switch hit.grab {
        case .bar:
            // V0.2.27（AevonFloatEdgeGripV227）：落指即拖（延迟 0）——
            // 手指一动（首个 .moved）立即 grabBegin；原地不动 = 轻点：
            //   左/右边条轻点 = 停靠该侧（0.2.51，AevonDockTapV251，用户 Aevon(26) #1）；
            //   底边轻点 = 记双击候选。
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

    /// 抬手 / 取消。返回 true = 已消费，调用方 return。
    private static func handleFloatGestureEnded(point: CGPoint, touchID: UInt,
                                               cancelled: Bool) -> Bool {
        guard floatTouchID != 0, touchID == floatTouchID else { return false }
        let win = floatWindow
        if floatBarPending {
            floatBarPending = false
            // 边条上的轻点（没有拖动）：左右缘 = 停靠 / 装回（AevonDockTapV251）；
            // 底边 = 记双击候选（底边双击 = 关闭）。
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
                    floatLastTapAt = CACurrentMediaTime()
                    floatLastTapPoint = point
                    floatLastTapWindow = win
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
            if let grab = floatGrab, win != nil {
                switch grab {
                case .bar, .corner:
                    // V0.2.61（AevonDblTapGuardV261，用户 Aevon(35) #4）：只有**原地轻点**
                    // 才登记「双击第一击」。0.2.60 及以前是「任何一次拖拽/缩放松手」都登记 ——
                    // 于是「拖一下窗，再点一下底边」就被当成双击直接关窗，这才是误触的真凶。
                    let moved = hypot(point.x - floatBeganPoint.x, point.y - floatBeganPoint.y)
                    if moved <= 8 {
                        floatLastTapAt = CACurrentMediaTime()
                        floatLastTapPoint = point
                        floatLastTapWindow = win
                    } else {
                        floatLastTapAt = 0
                        floatLastTapWindow = nil
                    }
                }
            }
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
        // V0.0.34（AevonNotifyRingBitV34）：圆盘状态写进 notify(3) 共享内存。
        AevonNotifySetRing(1)
        AevonLog.info("[圆盘] 指针已交给圆盘（来源 \(source)；把手是真实控件，命中无需吞摸；"
            + "V0.2.72 SBSwallow 已重新焊死，盘上覆盖走 App 侧 bit39）"
            + "（AevonRingSwallowV24 AevonGripOnlyV251 AevonSBSwallowSealV272）")
    }

    /// 圆盘收起：立刻解除接管，把事件通道还给系统。
    static func ringDidDismiss() {
        ringSource = ""
        appEdgePointerAdopted = false
        swallowDeadline = 0
        globalTouchID = 0
        globalFired = false
        ownsTouch = false
        globalOwnedAt = 0
        ringExtraTouchID = 0
        ringExtraDeadline = 0
        gripAdoptedTouchID = 0
        AevonNotifySetRing(0)
        // V0.2.51（AevonGripOnlyV251）：ringopen/ringclose Darwin 广播已随 App 侧
        // 识别器退役 —— 监听方全部删除，圆盘状态只走 notify(3) 共享内存位。
    }

    /// V0.2.8（AevonSelectionCoolV208）：圆盘选中开窗 → 记 1.5 秒冷静期。
    static func noteSelectionCooldown() {
        selectionCoolUntil = CACurrentMediaTime() + 1.5
    }
    static func isSelectionCoolingDown() -> Bool {
        return CACurrentMediaTime() < selectionCoolUntil
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
    static func hostRootView() -> UIView? {
        return AevonEntryHost.activeRoot
    }
}

// MARK: - C 入口（供 AevonTouchHook.m 调用）

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
    }
}

/// V0.1.2（AevonGuardCleanupV102）：Guard 回执计数与 handler 已随 Guard 移除。
/// 历史 CI 校验串（AevonGuardAckV35）由 AevonAssertionShim.m 的 used 常量收容。
