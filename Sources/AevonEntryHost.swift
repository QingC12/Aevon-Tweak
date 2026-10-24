import UIKit

/// 入口窗口的根视图：命中自身时返回 nil，让触摸穿透到下层。
///
/// V0.0.27：原 `AevonBubbleRootView`（备用悬浮球）已被删除，这里保留一个等价的
/// 穿透根视图，入口窗口仍需要一个命中测试可穿透的根视图承载容器。
final class AevonEntryRootView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === self ? nil : hit
    }
}

/// 入口窗口的根控制器（只负责给出上面那个穿透视图）。
final class AevonEntryRootController: UIViewController {
    override func loadView() {
        let root = AevonEntryRootView()
        root.backgroundColor = .clear
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view = root
    }
}

/// 入口窗口（全局唯一）。
///
/// V0.0.18 的结构性调整，依据是 V0.0.17 的真机日志：
///   · `[悬浮球] 点击，打开应用选择面板` 在整个会话里出现多次 → 悬浮球所在窗口的触摸一直是好的；
///   · `[边缘] 手势区收到触摸` 只有 2 次，且两次都紧跟在「悬浮球面板已打开」之后；
///     桌面裸态和 App 前台时整场零触发（连一行「收到触摸」都没有，说明触摸压根没进视图）。
///   两个窗口层级相同、场景相同、根视图类相同，却一个能收触摸一个收不到。
///   继续猜「第二个窗口为什么收不到」性价比太低 —— 直接**只保留一个窗口**。
///
/// 顺带消掉两个衍生问题：
///   · 同级窗口互相遮挡（以前悬浮球面板会压住手势条 / 圆盘）；
///   · 不再需要靠「创建顺序」和「重设 level」来抢层级。
final class AevonEntryWindow: AevonPassthroughWindow {
    /// 触摸探针：既可诊断（事件有没有到窗口这一层），
    /// 也能当**不依赖命中测试的兜底触发**——只要窗口收到事件，就一定能判定手势。
    var eventProbe: ((_ point: CGPoint, _ phase: UITouch.Phase) -> Void)?

    override func sendEvent(_ event: UIEvent) {
        if let touch = event.allTouches?.first, let probe = eventProbe {
            probe(touch.location(in: self), touch.phase)
        }
        super.sendEvent(event)
    }
}

/// 浮窗层（V0.0.36，AevonFloatInEntryV36）：入口容器里的专属子视图，只承载浮窗外壳。
///
/// 为什么要有它：旧架构浮窗挂在独立宿主窗口（level 9,999,990）上，而 App 前台时
/// 画面在 `SBDeviceApplicationSceneViewController.view` 里（不是窗口），层级压不过，
/// 浮窗在全屏 App 里直接消失。现在浮窗跟着入口容器一起搬家，App 前台照样可见。
///
/// 单独一层而不是直接塞容器，是为了层级秩序：浮窗永远在容器最底部，
/// 手势条 / 圆盘 / 面板等入口控件（后加入容器）永远在浮窗之上。
/// 命中自身返回 nil：没点到浮窗时触摸穿透到下层（App / 桌面）。
final class AevonWindowLayerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === self ? nil : hit
    }
}

/// 唯一入口容器（V0.0.22）。
///
/// 手势条、悬浮球、圆盘、应用面板全部挂在这**一个**视图里，而它本身可以被整体搬家：
///   · 桌面 / 无 App 前台时，挂在入口窗口的根视图上（V0.0.15–V0.0.20 验证过触摸可用）；
///   · App 进前台时，挂到 `SBDeviceApplicationSceneViewController.view` 上
///     （SpringBoard 把 App 画面就放在这个视图里，只有它是真正的「App 画面容器」，
///     窗口层级压不过它；Stheno 的逆向数据里同样只有一个
///     `SBDeviceApplicationSceneViewControllerHook`，走的就是这条路）。
/// 搬家只是 `removeFromSuperview` + `addSubview`，容器内的子视图（含已展开的圆盘）全都不受影响。
///
/// 命中自身返回 nil：没点到入口控件时触摸原样穿透到 App / 系统。
final class AevonEntryContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === self ? nil : hit
    }
}

/// 入口宿主：创建唯一窗口 + 唯一容器，并负责把容器搬到「当前最高的画面容器」上。
enum AevonEntryHost {
    private static var window: AevonEntryWindow?
    private static var container: AevonEntryContainerView?
    /// 浮窗层（V0.0.36）：容器内专门承载浮窗外壳的子视图，永远在入口控件之下。
    private static var floatLayer: AevonWindowLayerView?
    /// 当前 App 场景的容器视图（弱引用；App 关掉后自动失效）
    static private(set) weak var appSceneView: UIView?

    /// 当前全屏前台场景的标识（V0.0.59，AevonFrontmostCloseV59）。
    ///
    /// 由 `AevonSceneVCDidAppear` 从 `SBDeviceApplicationSceneViewController` 上探测
    /// （scene / representedScene → identifier）。用它判断「浮窗的 App 是不是就是
    /// 当前全屏前台的那个 App」—— 是的话关窗绝不能把场景睡掉，否则前台 App 被设为
    /// 后台：画面停在最后一帧、触摸不再投递 = 用户说的「关掉浮窗后屏幕无法滑动」。
    static private(set) var appSceneIdentity: String?

    /// 浮窗外壳的统一挂载点（V0.0.36）：浮窗层优先，容器兜底。
    static var floatHost: UIView? { return floatLayer ?? container }

    /// 该点是否落在某个已开浮窗上（V0.0.36 引入，V0.0.37 扩展到外侧手势区）。
    /// 入口探针据此区分「摸浮窗」与「摸边缘热区」：浮窗和入口共用一个窗口之后，
    /// 不加这道判断，浮窗压住热区时拖浮窗就会误呼圆盘。
    /// V0.0.37（AevonSthenoEdgeBarV37）：手势区伸到浮窗外侧 barThickness pt，
    /// 判定矩形同步外扩，防止拖边条 / 缩放时被当成热区触摸接管。
    ///
    /// V0.0.90：`ignoringDocked` 参数已随停靠小窗移除（不再有停靠小窗压热区的问题）。
    static func pointHitsFloatingWindow(at point: CGPoint) -> Bool {
        let margin = AevonWindowView.maxHandleMargin
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return false }
        for win in layer.subviews where !win.isHidden && win.alpha > 0.01 {
            if win.frame.insetBy(dx: -margin, dy: -margin).contains(point) { return true }
        }
        return false
    }

    /// 当前浮窗总数。用于「有浮窗时禁止系统空闲锁屏」。
    static var floatingWindowCount: Int {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return 0 }
        var count = 0
        for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
            if view is AevonWindowView { count += 1 }
        }
        return count
    }

    /// 把「主悬浮窗（含外侧手势区）的矩形」同步给 App 侧的 AevonGuard
    /// （V0.0.56，AevonGuardFloatRectV56）。
    ///
    /// Aevon(50) 第 2 条：全屏 App 里双击浮窗底边关闭，App 会吃到一次点击。
    /// bit48 只有 350ms 宽（双击间隔 0.36s 正好错过）—— 所以底边环带必须单独下发。
    /// Guard 命中就吞，与触摸时序彻底无关。
    ///
    /// V0.0.90：停靠列同步（AevonGuardDockZoneV54 的「每侧几个停靠小窗」）
    /// 已随停靠小窗移除 —— 不再有停靠格几何，Guard 只用主窗环带 + 整窗矩形。
    private static var lastGuardFloatRect: CGRect = .zero
    /// V0.0.82：上一次标记为「浮窗主人」的 App（用于撤销，避免留着旧主人不还原）
    private static var lastFloatOwners: Set<String> = []
    private static var lastOwnerBundle: String = ""
    private static var lastFloatWinRect: CGRect = .zero
    private static var guardFloatRectAt: CFTimeInterval = 0
    private static var guardFloatRectPending = false

    static func syncFloatRectToGuard() {
        // 拖动 / 动画期会调用得很密，节流到 ~8Hz，且保证最后一次一定写到
        let now = CACurrentMediaTime()
        if now - guardFloatRectAt < 0.12 {
            if !guardFloatRectPending {
                guardFloatRectPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    guardFloatRectPending = false
                    syncFloatRectToGuard()
                }
            }
            return
        }
        guardFloatRectAt = now

        var union = CGRect.null
        if let layer = floatLayer, !layer.subviews.isEmpty {
            for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
                // V0.0.90：不再有停靠小窗的独立槽位几何，这里覆盖所有浮窗
                guard let win = view as? AevonWindowView else { continue }
                /* V0.0.56 关键取舍：**只下发「底边手势环带」，不是整个窗口**。
                 *
                 * 一开始想的是把整个窗口矩形都交给 Guard 常驻吞，但浮窗里的内容
                 * 本身也是一条真实的 App 触摸（经 presenter 转发进 App 进程的
                 * `UIApplication -sendEvent:`）—— 整窗吞会把浮窗内容也一起吞掉，
                 * 抖音在浮窗里就完全点不动了。
                 * 而漏点击真正发生的地方只有底边条：它挂在窗口**下方**
                 * （`layoutGestureHandles` 里 barY = h），双击间隔 0.36s 又刚好越过
                 * bit48 的 350ms 放行窗口。所以只需要把这一条环带常驻吞：
                 * 窗内 12pt（手指压边时的落点）+ 窗外整条 barThickness。 */
                let bandHeight = 12 + AevonWindowView.bottomBarThickness + AevonWindowView.barHitSlop
                let band = CGRect(x: win.frame.minX,
                                  y: win.frame.maxY - 12,
                                  width: win.frame.width,
                                  height: bandHeight)
                union = union.union(band)
            }
        }
        /* V0.0.82（AevonScrollHealV82）：另发一条「**整窗**矩形」给 Guard，
         * 用途只有一个 —— 判断「这根手指是不是按在浮窗上」，从而在抬手时把
         * 被 App 自己滚走的偏移还原回去。
         *
         * 为什么必须和上面那条环带分开：环带是「该吞的窄条」，整窗是「用户可以
         * 正常操作的大块」，两者语义相反，混用就会出现 V81 那种
         * 「要么吞掉内容、要么整窗锁死」的二选一。
         * Aevon(74) 100% 复现的「浮窗里滑一下 → 全屏设置滚到最底 + 底部空白」
         * 正是靠这条通道修的（触摸同时投给 SB 与前台 App，App 那份没人管）。 */
        var winUnion = CGRect.null
        var owners: Set<String> = []
        if let layer = floatLayer, !layer.subviews.isEmpty {
            for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
                guard let win = view as? AevonWindowView else { continue }
                winUnion = winUnion.union(win.frame)
                owners.insert(win.bundleID)
            }
        }
        if winUnion.isNull {
            AevonNotifySetFloatWindowRect(0, 0, 0, 0)
            if lastFloatWinRect != .zero {
                lastFloatWinRect = .zero
                AevonLog.info("[窗口] 浮窗整窗矩形已清空（Guard 侧不再拦「浮窗上的触摸」，恢复全屏 App 输入）"
                    + "（AevonRectGateV83）")
            }
        } else {
            AevonNotifySetFloatWindowRect(Double(winUnion.minX), Double(winUnion.minY),
                                          Double(winUnion.width), Double(winUnion.height))
            /* V0.0.83（AevonRectGateV83）：这条矩形是「背后 App 不许收触摸」的范围。
             * 值和上一版不同（V0.0.82 只用来做滚动还原，实测帮了倒忙），
             * 现在 Guard 用它做**源头阻断** —— 落点在窗内的触摸对非主人 App 整条丢弃。 */
            let snapped = CGRect(x: winUnion.minX.rounded(), y: winUnion.minY.rounded(),
                                 width: winUnion.width.rounded(), height: winUnion.height.rounded())
            if snapped != lastFloatWinRect {
                lastFloatWinRect = snapped
                AevonLog.info("[窗口] 浮窗整窗矩形已下发给 Guard：\(Int(snapped.width))x\(Int(snapped.height))"
                    + " 位置 \(Int(snapped.minX)),\(Int(snapped.minY))"
                    + "（落在浮窗范围内的触摸不再投给背后的全屏 App —— 浮窗里滑动不会把 App 带走）"
                    + "（AevonRectGateV83）")
            }
        }
        /* V0.0.82：主人标记 —— 误滚还原要放过「浮窗里那个 App」（它自己滚动是正当的），
         * 只还原背后那个全屏 App。这里把主人集合的增删都补上（含撤销）。 */
        for bid in owners where !lastFloatOwners.contains(bid) {
            AevonNotifySetFloatOwner(bid, 1)
            /* V0.0.83：主人标记必须写明（V0.0.82 实测 Guard 侧认成了「非主人」，
             * 于是把浮窗里那个 App 自己的滚动也还原了 —— 日志里 BatteryInfo 0,952 → 0,873）。 */
            AevonLog.info("[窗口] 浮窗主人标记：\(bid)=是（该 App 在浮窗里，它自己的滚动是正当的，"
                + "Guard 不拦它的触摸、也不还原它的滚动）（AevonFloatOwnerV83）")
        }
        for bid in lastFloatOwners where !owners.contains(bid) {
            AevonNotifySetFloatOwner(bid, 0)
            AevonLog.info("[窗口] 浮窗主人标记：\(bid)=否（不再是浮窗内容，恢复按「浮窗整窗矩形」拦触摸）"
                + "（AevonFloatOwnerV83）")
        }
        /* V0.0.83（AevonFloatOwnerV83）：全局指纹通道 —— 我们本来就只有单主窗，
         * 所以「当前浮窗主人」永远只有一个值；Guard 用整数比对，不依赖 per-bundle token。
         * 传空串 = 没有主窗，清掉标记（之后 Guard 不再认主人）。 */
        let ownerBundle = owners.first ?? ""
        if ownerBundle != lastOwnerBundle {
            lastOwnerBundle = ownerBundle
            AevonNotifySetFloatOwnerBundle(ownerBundle)
            AevonLog.info("[窗口] 浮窗主人指纹已下发：\(ownerBundle.isEmpty ? "（无，清空）" : ownerBundle)"
                + "（Guard 侧据此放过「浮窗里那个 App」，只拦背后全屏 App 的触摸）（AevonFloatOwnerV83）")
        }
        lastFloatOwners = owners

        let rect = union.isNull ? CGRect.zero : union
        if rect == lastGuardFloatRect { return }
        lastGuardFloatRect = rect
        if rect.isEmpty {
            AevonNotifySetFloatRect(0, 0, 0, 0)
            AevonLog.info("[窗口] 已清空主窗矩形（没有主悬浮窗了，App 恢复全屏触摸）"
                + "（AevonGuardFloatRectV56）")
            return
        }
        AevonNotifySetFloatRect(Double(rect.minX), Double(rect.minY),
                                Double(rect.width), Double(rect.height))
        AevonLog.info("[窗口] 主窗矩形已下发给 Guard：\(Int(rect.width))x\(Int(rect.height))"
            + " 位置 \(Int(rect.minX)),\(Int(rect.minY))"
            + "（浮窗盖住的区域 App 不再收到触摸，双击/连点都不会漏）（AevonGuardFloatRectV56）")
    }

    /* V0.0.80（AevonAllClosedResetV80）：最后一个浮窗关掉之后的彻底复位。
     *
     * Aevon(72) 第 2 条：「关闭所有悬浮窗后全屏触摸会出现问题，无法触摸，
     * 必须回桌面再次打开全屏应用，或者清除后台卡片重新打开才恢复」。
     *
     * 关窗本身已经把「主窗矩形」清给 Guard 了，但另外三样东西没清：
     *   ① SB 侧全局通道的接管状态（`ownsTouch` / `floatTouchID` / bit48）；
     *   ② App 侧 Guard 手里可能还留着的「浮窗手势期」时间戳；
     *   ③ 前台场景的 foreground 标记 —— 关窗收尾那次 sleep/wake 回弹若被打断，
     *      场景会停在「前台但不呈现」的状态，触摸不投递。
     * 这里一次性把三样都处理掉，并在 1 秒后再校验一次前台场景。 */
    static func onAllWindowsClosed() {
        lastGuardFloatRect = .null          /* 强制重发一次「清零」包 */
        syncFloatRectToGuard()
        AevonEdgeEntry.resetGlobalTouchState(reason: "全部浮窗已关闭")
        AevonLog.info("[窗口] 已关闭全部浮窗：全局吞摸已复位 / 主窗矩形已清零 / "
            + "1 秒后校验前台场景（AevonAllClosedResetV80）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            reassertFrontmost(reason: "全部浮窗关闭后 1 秒")
        }
    }

    /// 校验「当前全屏前台场景」是不是真的还在前台；被误判成后台就强制拉回来。
    ///
    /// 症状对应：关掉浮窗后画面还在（停在最后一帧）但整屏点不动，切回桌面再进一次才好。
    /// 根因是 `FBScene.settings.foreground == false` —— 场景不呈现、输入不路由。
    static func reassertFrontmost(reason: String) {
        guard let identity = appSceneIdentity, !identity.isEmpty else { return }
        guard let scene = AevonSceneHelper.scene(for: identity) else {
            /* 找不到场景 = 这条自愈路径本身失效（正常情况应该有），
             * 记一行限频日志，下一轮能看出是不是 `scene(for:)` 在 iOS 17 上取不到。 */
            let now = CACurrentMediaTime()
            if now - lastHealMissLogAt > 30 {
                lastHealMissLogAt = now
                AevonLog.warn("[自愈] 有前台标识但取不到 scene 对象，无法校验前台状态"
                    + "（\(identity)，\(reason)，AevonFrontHealV80）")
            }
            return
        }
        guard let foreground = AevonSceneHelper.isForeground(scene) else { return }
        guard foreground == false else { return }
        AevonSceneHelper.setForeground(scene, true)
        AevonLog.warn("[自愈] 全屏前台场景被误判为后台 → 已强制拉回前台"
            + "（\(identity)，\(reason)，AevonFrontHealV80）")
    }

    private static var lastHealMissLogAt: CFTimeInterval = 0

    // V0.0.90：停靠列重排 / 落地校验 / 停靠矩形收集 / 停靠避让通知
    // 已随「停靠小窗回退到最初版本」整体移除 —— 不再有停靠列与停靠小窗。

    /// 屏幕点 → 命中的浮窗与抓取目标（V0.0.41，AevonFloatGlobalV41）。
    ///
    /// 全屏 App 时视图层收不到窗外的触摸（see `AevonWindowView.grab`），
    /// 所以由全局触摸通道在事件总入口查询这张表，再直接驱动浮窗。
    /// 返回的第三个值是该点换算到浮窗层坐标的结果，后续 update / end 复用同一坐标系。
    static func grabFloatingWindow(atScreenPoint point: CGPoint)
        -> (window: AevonWindowView, grab: AevonFloatGrab, layerPoint: CGPoint)? {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return nil }
        let layerPoint = self.floatLayerPoint(fromScreen: point)
        // 后加入的在上面：从后往前找，命中最上层那个窗
        for view in layer.subviews.reversed() where !view.isHidden && view.alpha > 0.01 {
            guard let win = view as? AevonWindowView else { continue }
            if let grab = win.grab(at: layerPoint) {
                return (win, grab, layerPoint)
            }
        }
        return nil
    }

    /// 屏幕（窗口）坐标 → 浮窗层坐标。浮窗层全屏且 origin 为 0，正常是恒等变换，
    /// 但容器被搬进 App 场景视图后坐标系由系统决定，统一走 convert 才不会偏。
    static func floatLayerPoint(fromScreen point: CGPoint) -> CGPoint {
        guard let layer = floatLayer else { return point }
        return layer.convert(point, from: nil)
    }

    /// 入口视图的统一挂载点（手势条 / 悬浮球 / 圆盘 / 面板都往这里加）
    static var activeRoot: UIView? { return container }
    /// 历史别名，语义同 `activeRoot`
    static var rootView: UIView? { return container }
    static var isInstalled: Bool { return container != nil }
    static var currentHostView: UIView? { return container?.superview }

    /// 容器当前是否挂在「全屏 App 画面容器」里（= App 在前台，画面压在我们的窗口之上）。
    ///
    /// V0.0.25 用它决定边缘触摸要不要从 App 手里接管：
    /// 只有 App 前台时才有「同一次滑动既转圆盘又滚 App」的问题；
    /// 桌面绝不能接管，否则热区范围内的桌面图标会点不动。
    static var mountedInAppScene: Bool {
        guard let box = container, let host = box.superview else { return false }
        guard let appView = appSceneView else { return false }
        return host === appView
    }

    // MARK: - 创建

    /// 确保入口窗口与容器存在（幂等）。成功返回容器，失败返回 nil（并在稍后重试）。
    ///
    /// V0.0.39（AevonBootShieldV39）：整条创建链路加 ObjC 异常保护 + 逐段面包屑日志。
    /// V0.0.38 真机（Aevon(32)）在本函数窗口内 SIGSEGV 且日志断流，无法定位 —— 现在：
    ///   · 每走完一段就落一行日志，崩溃时最后一行就是病灶段；
    ///   · UIKit 抛 NSException 时捕获并降级（场景窗口 → 无场景窗口 → 放弃重试），
    ///     绝不再把异常抛回系统带走 SpringBoard（自动注销问题）。
    @discardableResult
    static func ensureInstalled(attempt: Int = 1, reason: String) -> UIView? {
        if let existing = container { return existing }
        guard AevonPrefs.bool("Enabled", default: false) else { return nil }
        guard attempt <= 12 else {
            AevonLog.warn("[入口] 多次尝试仍没有可用场景，放弃本次创建（\(reason)）")
            return nil
        }
        guard let scene = AevonHostWindow.firstWindowScene() else {
            AevonLog.info("[入口] 暂无可用场景，1.5 秒后重试（第 \(attempt) 次，\(reason)）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                _ = ensureInstalled(attempt: attempt + 1, reason: reason)
            }
            return nil
        }

        AevonLog.info("[入口] ① 场景已选定（\(type(of: scene))），开始创建窗口（\(reason)）（AevonBootShieldV39）")

        // —— ② 窗口对象：场景窗口优先，抛异常降级为无场景窗口（两者都不行就放弃本次） ——
        var createdWindow: AevonEntryWindow?
        var createdController: AevonEntryRootController?
        var exName: NSString?
        var exReason: NSString?

        var built = AevonTryExecute({
            let host = AevonEntryWindow(windowScene: scene)
            host.frame = UIScreen.main.bounds
            host.backgroundColor = .clear
            // V0.0.19 起入口窗口层级 = 1e7。桌面 / 回桌面场景靠它；
            // App 前台时它会被 App 画面容器压住，改由容器搬家解决（见类注释）。
            host.windowLevel = AevonWindowLevels.entry
            let controller = AevonEntryRootController()
            host.rootViewController = controller
            host.isHidden = false
            // 立刻走一次布局：保证根视图 bounds 不是 0
            host.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            createdWindow = host
            createdController = controller
        }, &exName, &exReason)

        if !built {
            AevonLog.warn("[入口] ② 场景窗口创建抛异常（\(exName ?? "未知"): \(exReason ?? "无")），降级为无场景窗口重试（AevonBootShieldV39）")
            createdWindow = nil
            createdController = nil
            exName = nil
            exReason = nil
            built = AevonTryExecute({
                let host = AevonEntryWindow(frame: UIScreen.main.bounds)
                host.frame = UIScreen.main.bounds
                host.backgroundColor = .clear
                host.windowLevel = AevonWindowLevels.entry
                let controller = AevonEntryRootController()
                host.rootViewController = controller
                host.isHidden = false
                host.layoutIfNeeded()
                controller.view.layoutIfNeeded()
                createdWindow = host
                createdController = controller
            }, &exName, &exReason)
            if !built {
                AevonLog.warn("[入口] ② 无场景窗口也抛异常（\(exName ?? "未知"): \(exReason ?? "无")），放弃本次创建（AevonBootShieldV39）")
                return nil
            }
        }

        guard let host = createdWindow, let controller = createdController else { return nil }
        AevonLog.info("[入口] ② 窗口对象已创建（level=\(Int(AevonWindowLevels.entry.rawValue))，场景窗口=\(host.windowScene != nil ? "是" : "否")）")

        // —— ③ 容器 + 浮窗层 ——
        var createdBox: AevonEntryContainerView?
        var createdFloatLayer: AevonWindowLayerView?
        let boxesBuilt = AevonTryExecute({
            let box = AevonEntryContainerView(frame: controller.view.bounds)
            box.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            box.backgroundColor = .clear
            box.isUserInteractionEnabled = true
            controller.view.addSubview(box)

            // V0.0.36（AevonFloatInEntryV36）：容器最底部放浮窗层。
            // 之后手势条 / 圆盘 / 面板 add 进容器都在它上面，层级秩序天然成立。
            let floatView = AevonWindowLayerView(frame: box.bounds)
            floatView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            floatView.backgroundColor = .clear
            floatView.isUserInteractionEnabled = true
            box.addSubview(floatView)
            createdBox = box
            createdFloatLayer = floatView
        }, &exName, &exReason)
        guard boxesBuilt, let box = createdBox, let floatView = createdFloatLayer else {
            AevonLog.warn("[入口] ③ 容器/浮窗层创建抛异常（\(exName ?? "未知"): \(exReason ?? "无")），放弃本次创建（AevonBootShieldV39）")
            return nil
        }
        AevonLog.info("[入口] ③ 容器与浮窗层已就位")

        window = host
        container = box
        floatLayer = floatView
        AevonEdgeEntry.attachProbe(to: host)
        startWatchdog()

        let bounds = box.bounds
        AevonLog.info("[入口] ④ 入口窗口与容器已创建（level=\(Int(host.windowLevel.rawValue))，场景 \(type(of: scene))，容器 \(Int(bounds.width))x\(Int(bounds.height))，浮窗层已就位，原因=\(reason)）（AevonEntryHost AevonSingleContainerV22 AevonFloatInEntryV36 AevonBootShieldV39）")

        // 万一创建时已经有 App 场景在场（热启动 / 重新初始化），优先挂上去
        if let sceneView = appSceneView, isUsableHost(sceneView) {
            attach(to: sceneView, reason: "创建时已有 App 场景")
        }
        return box
    }

    // MARK: - 容器搬家

    /// 把容器挂到指定宿主视图上（幂等）。
    private static func attach(to host: UIView, reason: String) {
        guard let box = container else { return }
        guard isUsableHost(host) else { return }
        if box.superview === host {
            host.bringSubviewToFront(box)
            return
        }
        let from = box.superview.map { AevonRuntime.className($0) ?? "\(type(of: $0))" } ?? "无"
        box.removeFromSuperview()
        box.frame = host.bounds
        host.addSubview(box)
        host.bringSubviewToFront(box)
        // 父视图换了，手势条按新 bounds 重新落位
        AevonEdgeEntry.refreshLayoutIfNeeded()
        AevonLog.info("[入口] 容器已搬家 \(from) → \(AevonRuntime.className(host) ?? "\(type(of: host))")（\(Int(host.bounds.width))x\(Int(host.bounds.height))，原因=\(reason)）")
    }

    /// 宿主视图是否可用：有尺寸、在窗口里、没有被隐藏。
    private static func isUsableHost(_ view: UIView) -> Bool {
        guard view.bounds.width > 1, view.bounds.height > 1 else { return false }
        guard view.window != nil else { return false }
        guard !view.isHidden, view.alpha > 0.01 else { return false }
        return true
    }

    /// App 场景出现（由 `AevonSceneHook` 从 `SBDeviceApplicationSceneViewController` 转发）。
    ///
    /// 这是 V0.0.22 解决「全屏 App 里看不到触发条」的关键：
    /// SpringBoard 的前台 App 画面不是 UIWindow，而是挂在这个控制器的 view 里，
    /// 窗口层级对它无效；把容器直接塞进同一个 view 才能压在上面。
    static func appSceneAppeared(_ view: UIView, reason: String, identity: String? = nil) {
        guard container != nil else { return }
        // App 切换器里的小卡片、分屏窄条、被推到后台的场景容器都不接管，
        // 只认「真的铺满整屏、并且确实在窗口里显示着」的那一个。
        guard coversScreen(view) else { return }
        appSceneView = view
        // V0.0.59（AevonFrontmostCloseV59）：记下全屏前台场景的标识
        // V0.0.62：探测失败（nil）时清空 —— 宁可回退到无条件休眠（老行为），
        // 也不能拿上一个 App 的标识误判「关的是前台自己」。
        appSceneIdentity = (identity?.isEmpty == false) ? identity : nil
        attach(to: view, reason: reason)
        // 场景出现后系统会继续往这个 view 里塞内容，延后再顶一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard appSceneView === view, coversScreen(view) else { return }
            attach(to: view, reason: "\(reason)（延后重顶）")
        }
    }

    /// 当前 App 画面是否**仍然真的铺满整屏**（V0.0.54，AevonSwitcherHideV54）。
    ///
    /// 上滑进后台卡片视图时，系统不会让 `SBDeviceApplicationSceneViewController`
    /// `viewDidDisappear`，只是把它 transform 缩小 —— 容器跟着缩小就成了卡片上那一小块浮窗。
    /// 这个判定给 `AevonSwitcherGuard` 用：false = 该把浮窗藏起来。
    static func appSceneCoversScreen() -> Bool {
        guard let view = appSceneView else { return true }
        return coversScreen(view)
    }

    /// 宿主是否真的铺满整屏并且正在显示（用于区分 App 画面容器与切换器卡片 / 后台场景）。
    private static func coversScreen(_ view: UIView) -> Bool {
        guard isUsableHost(view) else { return false }
        guard let window = view.window, !window.isHidden, window.alpha > 0.01 else { return false }
        let screen = UIScreen.main.bounds
        let rect = view.convert(view.bounds, to: window)
        guard rect.width >= screen.width - 2, rect.height >= screen.height - 2 else { return false }
        guard rect.minY <= 1, rect.minY + rect.height >= screen.height - 1 else { return false }
        return true
    }

    /// App 场景消失：把容器搬回入口窗口，保证桌面上入口照旧。
    static func appSceneDisappeared(_ view: UIView) {
        guard appSceneView === view else { return }
        appSceneView = nil
        appSceneIdentity = nil
        attachToWindowRoot(reason: "App 场景消失")
    }

    /// App 画面还剩多少高度（占屏高的比例）。上滑回家过程中这个值会一路变小。
    static func appSceneVisibleHeightRatio() -> CGFloat {
        guard let view = appSceneView, let window = view.window else { return 1 }
        let rect = view.convert(view.bounds, to: window)
        let screenHeight = max(1, UIScreen.main.bounds.height)
        return max(0, min(1, rect.height / screenHeight))
    }

    /// 把容器从「正在缩小的 App 画面」里搬回桌面窗口（V0.0.55，AevonOverlayPolicyV55）。
    ///
    /// 用户 Aevon(48) 第 1 条：上滑回家时小窗消失、回到桌面又出现。
    /// 根因是容器挂在 App 画面里，画面被系统带着缩小 / 淡出，容器只能跟着走。
    /// 现在在画面明显缩小（不到半屏）时立刻搬回桌面窗口 ——
    /// 容器在两个宿主里都是整屏坐标系、尺寸相同，所以画面**完全不动**，
    /// 只是不再跟着 App 卡片一起缩。
    static func detachFromAppScene(reason: String) {
        guard container != nil, appSceneView != nil, mountedInAppScene else { return }
        attachToWindowRoot(reason: reason)
        AevonLog.info("[入口] App 画面正在缩小，浮窗已留在桌面层（\(reason)）（AevonOverlayPolicyV55）")
    }

    /// 画面恢复整屏（用户取消了上滑 / 又切回该 App）→ 把容器搬回 App 画面。
    static func reattachAppSceneIfPossible() {
        guard container != nil, !mountedInAppScene else { return }
        guard let view = appSceneView, isUsableHost(view), coversScreen(view) else { return }
        attach(to: view, reason: "App 画面恢复整屏")
    }

    /// 搬回入口窗口根视图。
    private static func attachToWindowRoot(reason: String) {
        guard let host = window?.rootViewController?.view else { return }
        if host.bounds.width < 1 { host.frame = UIScreen.main.bounds }
        attach(to: host, reason: reason)
    }

    // MARK: - 布局 / 层级

    /// 场景变化 / 尺寸变化后重新落位（幂等，可随时调用）。
    static func refreshLayout(reason: String) {
        guard let box = container else { return }
        box.layoutIfNeeded()
        AevonEdgeEntry.refreshLayoutIfNeeded()
        let bounds = box.bounds
        if bounds.width < 1 || bounds.height < 1 {
            AevonLog.warn("[入口] 容器尺寸异常（\(Int(bounds.width))x\(Int(bounds.height))，\(reason)）")
        }
    }

    /// 把入口重新顶到最上层（V0.0.19 起每次 App 激活 / 回桌面都会调）。
    static func raise(reason: String) {
        guard let host = window else { return }
        if !AevonHostWindow.isAcceptableScene(host.windowScene) {
            if let scene = AevonHostWindow.preferredScene() {
                host.windowScene = scene
                host.windowLevel = AevonWindowLevels.entry
                AevonLog.info("[入口] 窗口场景已重挂 → \(type(of: scene))（\(reason)）")
            }
        }
        let before = host.windowLevel.rawValue
        host.windowLevel = AevonWindowLevels.entry
        if host.isHidden { host.isHidden = false }
        if before != AevonWindowLevels.entry.rawValue {
            AevonLog.info("[入口] 层级已重设 \(Int(before)) → \(Int(host.windowLevel.rawValue))（\(reason)）")
        }
        // 容器挂在哪一级决定「看不看得见」：优先 App 场景容器，其次窗口根视图
        if let sceneView = appSceneView, isUsableHost(sceneView) {
            attach(to: sceneView, reason: reason)
        } else {
            attachToWindowRoot(reason: reason)
        }
    }

    // MARK: - 看门狗

    /// 场景看门狗（V0.0.20 引入，V0.0.21 收紧，V0.0.22 只做「容器归位」）。
    ///
    /// V0.0.20 每 2 秒按场景打分把窗口搬一次，结果搬进了
    /// `SBSystemApertureCurtainWindowScene`（灵动岛帘幕场景）——该场景不参与触摸命中，
    /// 整版边缘手势全废。现在**不再搬窗口**，只在必要时把容器顶到最前 / 搬回窗口。
    private static var watchdog: Timer?
    private static var tickCount = 0

    static func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { _ in watchdogTick() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        AevonLog.info("[入口] 看门狗已启动（每 3 秒核对容器挂载点，每 30 秒打一次窗口栈）（AevonSceneWatch）")
    }

    private static func watchdogTick() {
        guard let host = window, let box = container else { return }
        tickCount += 1

        // 场景不合格（被搬进 Aperture 等场景）才纠正一次，正常时不动
        if !AevonHostWindow.isAcceptableScene(host.windowScene),
           let target = AevonHostWindow.preferredScene() {
            host.windowScene = target
            host.windowLevel = AevonWindowLevels.entry
            host.isHidden = false
            AevonLog.warn("[入口] 场景不合格，已纠正 → \(type(of: target))（AevonSceneFix AevonSceneWhiteListV21）")
        }

        // 容器归位：App 场景还在就贴着它，否则回窗口根视图
        if let sceneView = appSceneView, isUsableHost(sceneView) {
            if box.superview !== sceneView { attach(to: sceneView, reason: "周期归位") }
        } else {
            if appSceneView != nil { appSceneView = nil }
            let rootView = host.rootViewController?.view
            // 三种情况都要搬回窗口：没有父视图 / 父视图已经不在窗口里 / 父视图不是窗口根视图
            if box.superview == nil || box.window == nil || (rootView != nil && box.superview !== rootView) {
                attachToWindowRoot(reason: "周期归位")
            }
        }

        // 入口视图按最新配置重新落位（V0.0.25：设置里改了热区位置/宽高要立即生效，
        // 不能等下次注销 —— 这里每 3 秒对一次，代价可以忽略）
        AevonEdgeEntry.refreshLayoutIfNeeded()

        /* V0.0.80（AevonAllClosedResetV80）：无浮窗期的触摸自愈。
         *
         * 一个浮窗都没有的时候，SB 侧不该有任何触摸接管状态残留。
         * 每 3 秒便宜地对一次：真有残留才清（`resetGlobalTouchState` 内部只在
         * 「确实有状态」时写日志），顺手校验前台场景有没有被误判成后台。
         * 这是 Aevon(72)「关掉所有浮窗后全屏点不动」的最后一道兜底。 */
        if !AevonWindowManager.hasAnyWindow {
            AevonEdgeEntry.resetGlobalTouchState(reason: "看门狗：当前没有浮窗")
            if tickCount % 2 == 0 { reassertFrontmost(reason: "看门狗周期校验") }
        }
        /* V0.0.81（AevonAppGateV81）：整窗触摸门的兜底复位 —— 关窗路径万一被打断
         * （异常 / 崩溃 / 用户连点），残留的「关门」会让那个 App 永远点不动。 */
        AevonSceneHelper.clearStaleAppGates()

        // 前 3 分钟每 30 秒打一次栈（够用户打开 App 验证一轮）
        if tickCount <= 60, tickCount % 10 == 0 {
            dumpWindowStack("周期")
        }
    }

    /// 窗口栈诊断：把当前所有场景的窗口按层级打出来，外加容器的挂载点。
    static func dumpWindowStack(_ tag: String) {
        var parts: [String] = []
        var index = 0
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            var items: [String] = []
            let sorted = scene.windows.sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
            for w in sorted.suffix(8) {
                items.append("\(Int(w.windowLevel.rawValue)):\(type(of: w))\(w.isHidden ? "(h)" : "")")
            }
            let mine = (scene === window?.windowScene) ? "*" : ""
            parts.append("#\(index)\(mine)\(type(of: scene))<\(scene.session.role.rawValue)>状态\(scene.activationState.rawValue)·\(scene.windows.count)窗[\(items.joined(separator: " "))]")
            index += 1
        }
        if parts.isEmpty { parts.append("没有任何 UIWindowScene") }
        let hostState = window.map { w -> String in
            let layerText = w.layer.superlayer == nil ? "无" : "有"
            return "入口窗口\(Int(w.windowLevel.rawValue))/隐藏\(w.isHidden ? 1 : 0)/透明度\(Int(w.alpha * 100))/场景\(w.windowScene == nil ? "无" : "有")/渲染层\(layerText)"
        } ?? "入口窗口不存在"
        let mount = container?.superview.map { AevonRuntime.className($0) ?? "\(type(of: $0))" } ?? "无"
        let size = container?.bounds.size ?? .zero
        AevonLog.info("[诊断] 窗口栈（\(tag)）：\(hostState) | 容器挂载=\(mount) \(Int(size.width))x\(Int(size.height)) | \(parts.joined(separator: " | "))")
    }
}

// MARK: - C 入口（供 AevonSceneHook.m 调用）

// V0.0.59 的 Swift 字符串键探测（aevonSceneIdentity(fromVC:)）已删除：
// FBScene.identifier 是 FBSceneIdentity 对象而非 NSString，`as? String` 恒失败，
// 「前台场景=无」= 关窗修复从未生效（Aevon(55) 日志实锤）。
// V0.0.62 起由 hook 层 AevonSceneBundleIDFromVC 深挖传入（AevonFrontmostIDV62）。

/// App 画面容器出现：把它交给宿主，容器会搬进去，从而压在全屏 App 之上。
/// V0.0.62（AevonFrontmostIDV62）：bundleID 由 hook 层深挖传入（FBScene.identifier
/// 是对象不是字符串，Swift 侧字符串探测恒失败 → 关窗修复从未生效）。
@_cdecl("AevonSceneVCDidAppear")
public func AevonSceneVCDidAppear(_ vc: UIViewController, _ bundleID: NSString?) {
    guard vc.isViewLoaded else { return }
    let view = vc.view!
    let identity = bundleID as String?
    DispatchQueue.main.async {
        AevonEntryHost.appSceneAppeared(view, reason: "App 画面进入（AevonSceneVCHookV22）",
                                        identity: identity)
    }
}

/// App 画面容器消失：容器搬回入口窗口，桌面上照旧可用。
@_cdecl("AevonSceneVCDidDisappear")
public func AevonSceneVCDidDisappear(_ vc: UIViewController) {
    guard vc.isViewLoaded else { return }
    let view = vc.view!
    DispatchQueue.main.async {
        AevonEntryHost.appSceneDisappeared(view)
    }
}
