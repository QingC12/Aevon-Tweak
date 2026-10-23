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
    /// V0.0.50（AevonDockPassThroughV50）：`ignoringDocked = true` 时**跳过停靠小窗**。
    /// 停靠列贴右边缘，必然压在「呼出圆盘」的热区上；热区判定如果还被它拦住，
    /// 用户在停靠列覆盖的那一段就永远划不出圆盘（用户 Aevon(43) 说的手势冲突）。
    static func pointHitsFloatingWindow(at point: CGPoint, ignoringDocked: Bool = false) -> Bool {
        let margin = AevonWindowView.maxHandleMargin
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return false }
        for win in layer.subviews where !win.isHidden && win.alpha > 0.01 {
            if ignoringDocked, let w = win as? AevonWindowView, w.isDocked { continue }
            if win.frame.insetBy(dx: -margin, dy: -margin).contains(point) { return true }
        }
        return false
    }

    /// V0.0.58（AevonCardVisPanV58）→ V0.0.59：设置里改了「完整显示内容」后
    /// 让所有浮窗立即重排 —— 内容管线打脏之外，主窗场景还要按新比例
    /// 重新排版（真重排：比例变了场景逻辑尺寸必须跟着变）。
    static func refreshContentLayoutForPrefs() {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return }
        for view in layer.subviews {
            guard let win = view as? AevonWindowView else { continue }
            win.invalidateContentLayout()
            win.applySceneResize(reason: "内容模式变更")
        }
    }

    /// 已停靠小窗的占位矩形（V0.0.44，AevonDockAvoidV44）。
    ///
    /// 用户 Aevon(37)：停靠小窗会压在主窗的手势条上，主窗就拖不动了。
    /// 这里把每个「已停靠」的窗按其 frame 外扩手势厚度后返回，别人改动几何时先避让。
    static func dockedObstacles(excluding window: AevonWindowView?) -> [CGRect] {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return [] }
        let margin = AevonWindowView.maxHandleMargin
        var rects: [CGRect] = []
        for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
            guard let win = view as? AevonWindowView else { continue }
            if win === window { continue }
            guard win.isDocked else { continue }
            rects.append(win.frame.insetBy(dx: -margin, dy: -margin))
        }
        return rects
    }

    /// 同侧已停靠的小窗（V0.0.48，AevonDockColumnV48），按当前纵向位置从上到下。
    ///
    /// 停靠列是「同侧一列」的模型：左侧一列、右侧一列，互不干扰。
    /// 新窗落点 = 这一列的第 `count` 格（见 `AevonSnap.dockColumnY`）。
    static func dockedPeers(side: AevonSnapSlot,
                            excluding window: AevonWindowView?) -> [AevonWindowView] {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return [] }
        var list: [AevonWindowView] = []
        for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
            guard let win = view as? AevonWindowView else { continue }
            if win === window { continue }
            guard win.isDocked, win.currentSlot == side else { continue }
            list.append(win)
        }
        // V0.0.54（AevonDockOrderV54）：与重排同口径 —— 按进入列的时间戳，
        // 不按动画中的坐标（否则新窗的「第几格」会在快速连点时算错）。
        return list.sorted { lhs, rhs in
            if abs(lhs.dockSeq - rhs.dockSeq) > 0.000_1 {
                return lhs.dockSeq < rhs.dockSeq
            }
            return lhs.frame.minY < rhs.frame.minY
        }
    }

    /// 当前浮窗总数（含停靠小窗）。用于「有浮窗时禁止系统空闲锁屏」。
    static var floatingWindowCount: Int {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return 0 }
        var count = 0
        for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
            if view is AevonWindowView { count += 1 }
        }
        return count
    }

    /// 只允许一个主悬浮窗（V0.0.51，AevonSingleMainV51）。
    ///
    /// 用户 Aevon(44) 第 2 条：「点击小窗还原成主悬浮窗时，它会依次堆叠在一起，
    /// 我建议只能有一个主悬浮窗；主悬浮窗打开时，再次点击停靠小窗或者操作圆盘选中图标时，
    /// 主悬浮窗的应用自动吸附停靠」。
    ///
    /// 堆叠的真正原因：所有新窗 / 还原窗都恢复**同一份**全局几何记忆
    /// （日志里全是 `58,164 266x560`），于是几个主窗逐点重合，视觉上就是"叠在一起"。
    /// 现在把「除自己之外的所有自由态窗」全部自动吸附成停靠小窗 ——
    /// 街上永远只有一个主窗，且旧的自动让位，不需要用户手动整理。
    @discardableResult
    static func demoteMainWindows(except keep: AevonWindowView?) -> Int {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return 0 }
        var demoted = 0
        for view in layer.subviews {
            guard let win = view as? AevonWindowView else { continue }
            if win === keep { continue }
            guard !win.isHidden, win.alpha > 0.01, !win.isDocked else { continue }
            // V0.0.53（AevonDockKeepSideV53）：**优先回到它上一次停靠的那一列**。
            // 上一版这里直接用 `slot(for: frame) ?? .right` 按当前位置猜 ——
            // 一个从右侧列还原出来、被拖到屏幕中部的窗会被判成右侧，而一个停在左边的窗
            // 会被判成左侧，于是用户看到 Aevon(46) 第 4 条的「自动吸附到另一侧、原侧缺口」。
            // 只有从未停靠过的新窗，才按离哪边近来猜。
            let preferred: AevonSnapSlot = (win.lastDockSide != .free)
                ? win.lastDockSide
                : (AevonSnap.slot(for: win.frame) ?? .right)
            // 那一列已满 5 个就换另一侧 —— 否则 `snap` 会拒绝停靠，窗又留在自由态，
            // 屏幕上就还是两个主窗（Aevon(46) 第 5 条）。
            var slot = preferred
            if dockedPeers(side: slot, excluding: win).count >= AevonSnap.dockMaxCount {
                slot = (slot == .left) ? .right : .left
            }
            // force：正在做还原动画的窗也必须当场收掉，否则屏上会有两个主窗（第 5 条）
            win.snap(to: slot, force: true)
            demoted += 1
        }
        if demoted > 0 {
            // 两侧都重排：被降级的窗可能落回另一侧，那一列也要把空缺补上
            relayoutAllDockedColumns()
            AevonLog.info("[窗口] 只允许一个主悬浮窗：\(demoted) 个旧主窗已自动吸附成停靠小窗"
                + "（回到各自上一次停靠的那一侧，两侧列都已重排）"
                + "（AevonSingleMainV51 AevonDockKeepSideV53 AevonDockForceV53）")
        }
        return demoted
    }

    /// 左右两侧的停靠列一起重排（V0.0.53）。
    ///
    /// Aevon(46) 第 4 条：「有概率自动吸附到另一侧，同时左/右侧的停靠小窗会有一个缺口」——
    /// 缺口就是因为只重排了「被还原那一侧」，而 demote 把某个窗挪到了对面，
    /// 对面那一列既没补位也没对齐。现在任何一次增减都两侧一起重排。
    static func relayoutAllDockedColumns() {
        relayoutDockedColumn(side: .left)
        relayoutDockedColumn(side: .right)
    }

    /// 把「左右两侧各有几个停靠小窗」同步给 App 侧的 AevonGuard
    /// （V0.0.54，AevonGuardDockZoneV54）。
    ///
    /// Aevon(47) 第 5 条：「快速点击停靠的小窗轮换时，依旧会触发应用内的点击」。
    /// 只靠 bit48（按下写 / 抬手清）挡不住 —— 它和 backboardd 直投 App 的那份存在时序竞态。
    /// 停靠列几何是固定的，所以这里只传数量：Guard 自己算出每一格的矩形，
    /// 手指落上去就吞，与触摸时序彻底无关。
    private static var lastDockStateRight = -1
    private static var lastDockStateLeft = -1

    static func syncDockStateToGuard(reason: String) {
        var left = 0
        var right = 0
        if let layer = floatLayer, !layer.subviews.isEmpty {
            for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
                guard let win = view as? AevonWindowView, win.isDocked else { continue }
                if win.currentSlot == .left { left += 1 }
                else if win.currentSlot == .right { right += 1 }
            }
        }
        AevonNotifySetDockState(Int32(right), Int32(left))
        // V0.0.56：停靠列一变，主窗集合也跟着变（还原会多出一个主窗 / 降级会少一个），
        // 顺手把主窗矩形同步过去（内部有节流）。
        syncFloatRectToGuard()
        guard right != lastDockStateRight || left != lastDockStateLeft else { return }
        lastDockStateRight = right
        lastDockStateLeft = left
        AevonLog.info("[窗口] 停靠列已同步给 Guard：右 \(right) 格 / 左 \(left) 格"
            + "（按固定槽位几何吞摸，快速连点也不会点到 App）（\(reason)）"
            + "（AevonGuardDockZoneV54）")
    }

    /// 把「主悬浮窗（含外侧手势区）的矩形」同步给 App 侧的 AevonGuard
    /// （V0.0.56，AevonGuardFloatRectV56）。
    ///
    /// Aevon(50) 第 2 / 5 条：全屏 App 里双击浮窗底边关闭、快速连点停靠小窗切换主窗，
    /// App 都会吃到一次点击。bit48 只有 350ms 宽（双击间隔 0.36s 正好错过），
    /// 停靠格几何又不覆盖主窗本体 —— 所以主窗矩形必须单独下发。
    /// Guard 命中就吞，与触摸时序彻底无关。
    private static var lastGuardFloatRect: CGRect = .zero
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
                // 停靠小窗有独立的槽位几何（Guard 自己算），这里只发主窗
                guard let win = view as? AevonWindowView, !win.isDocked else { continue }
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

    /// 重排某一侧的整列停靠小窗（V0.0.50，AevonDockTop5V50）。
    ///
    /// 用户 Aevon(43)：「第一个小窗在屏幕右上角、距离顶部 10% 处，然后向下依次类推，
    /// 总数量只有 5 个，当其中一个被还原成主悬浮窗时，下面的自动补空缺（这里需要有动画）」。
    /// 槽位算法见 `AevonSnap.dockColumnYs`（顶部 10% 锚点、固定 5 格），
    /// 落位动画走 `setDockedY` —— 只改 y 的短弹簧，**带**过渡，不是瞬移。
    /// 还原时调用方会先把被还原窗的 `currentSlot` 置回 `.free`，于是它不再进这一列，
    /// 下面的窗依次上移一格把空缺补上。
    static func relayoutDockedColumn(side: AevonSnapSlot) {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return }
        var column: [AevonWindowView] = []
        for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
            guard let win = view as? AevonWindowView else { continue }
            guard win.isDocked, win.currentSlot == side else { continue }
            column.append(win)
        }
        // V0.0.49（AevonDockColumnFillV49）：原来这里要求 `count > 1`，
        // 于是「三个小窗还原中间那个」之后若只剩一个就不重排，它孤零零留在原位。
        // 现在剩一个也要重排 —— 它会回到第 1 格（顶部 10%）。
        // 这一侧已经空了：**也要**同步给 Guard —— 否则它会一直以为那几格还停着窗，
        // 把 App 的触摸白白吞掉（停靠小窗全还原后点不动 App 的经典坑）。
        guard !column.isEmpty else {
            syncDockStateToGuard(reason: "该侧已无停靠小窗")
            return
        }
        // V0.0.54（AevonDockOrderV54）：「快速点 2/3/4 位置的停靠小窗会出现缺口，
        // 1 秒内又自动补齐」（Aevon(47) 第 6 条）。
        // 原来按 `frame.minY` 排 —— 停靠动画要 0.42s，快速连点时拿到的是**动画中间值**，
        // 刚被降到第 4 格的窗还飘在屏幕中间就被排到队尾，于是每格错位 = 缺口；
        // 动画结束 `pendingDockY` 再补一次才对齐，就是那个「1 秒后自己好了」。
        // 现在按进入这一列的时间戳排，与画面位置彻底解耦，一次就落对。
        column.sort { lhs, rhs in
            if abs(lhs.dockSeq - rhs.dockSeq) > 0.000_1 {
                return lhs.dockSeq < rhs.dockSeq
            }
            return lhs.frame.minY < rhs.frame.minY
        }
        // V0.0.53（AevonDockSlotFitV53）：槽位高度用**目标尺寸** `dockSize.height`。
        // 上一版取 `column[0].frame.height` —— 若第一个窗的缩放动画还没跑完，
        // 拿到的是它在半路的尺寸，于是后面每一格都按错的高度累加，
        // 排完就出现「中间空一格」的缺口（用户 Aevon(46) 第 4 条）。
        let height = AevonSnap.dockSize.height
        let ys = AevonSnap.dockColumnYs(count: column.count, height: height)
        guard ys.count == column.count else { return }
        for (index, win) in column.enumerated() {
            win.setDockedY(ys[index])
        }
        AevonLog.info("[窗口] 停靠列已重排：\(column.count) 个小窗，顶部 10% 锚点向下、"
            + "下方自动补位（\(ys.map { Int($0) })，尺寸 \(Int(AevonSnap.dockSize.width))x\(Int(height))"
            + "，按进入顺序排序、不再按动画中间坐标（AevonDockTop5V50 AevonDockFillAnimV50 "
            + "AevonDockSlotFitV53 AevonDockOrderV54）")
        // 列变化 = 哪几格被停靠小窗占着变了 → 立刻告诉 Guard，它按固定槽位几何吞摸
        syncDockStateToGuard(reason: "停靠列重排后")
        scheduleDockSettle()
    }

    /* MARK: - 停靠列「落地校验」（V0.0.57，AevonDockSettleV57） */

    /// 停靠列的自愈校验：一次切换里会连着触发好几次重排（自己离开列 / 别的窗被降级 /
    /// 动画结束补做），任何一次被 `isAnimatingGeometry` 挡下、或者系统在动画中间
    /// 又改了一次 frame，都可能留下「某一格偏了十几 pt」的缺口。
    /// 用户在 Aevon(51) 第 3 条里看到的断层就是它。
    ///
    /// 做法：最后一次重排后 0.62 秒（覆盖 0.42s 缩放 + 0.36s 补位两段动画），
    /// 对着最终槽位再核一遍，偏了就补一次很短的动画对齐。**幂等**，正常情况什么都不做。
    private static var dockSettleToken = 0

    private static func scheduleDockSettle() {
        dockSettleToken += 1
        let token = dockSettleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            guard token == dockSettleToken else { return }
            settleDockedColumns()
        }
    }

    private static func settleDockedColumns() {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return }
        var fixed = 0
        let height = AevonSnap.dockSize.height
        for side in [AevonSnapSlot.left, AevonSnapSlot.right] {
            var column: [AevonWindowView] = []
            for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
                guard let win = view as? AevonWindowView else { continue }
                guard win.isDocked, win.currentSlot == side else { continue }
                column.append(win)
            }
            guard !column.isEmpty else { continue }
            column.sort { lhs, rhs in
                if abs(lhs.dockSeq - rhs.dockSeq) > 0.000_1 { return lhs.dockSeq < rhs.dockSeq }
                return lhs.frame.minY < rhs.frame.minY
            }
            let ys = AevonSnap.dockColumnYs(count: column.count, height: height)
            guard ys.count == column.count else { continue }
            for (index, win) in column.enumerated() where abs(win.frame.minY - ys[index]) > 1.0 {
                win.setDockedY(ys[index])
                fixed += 1
            }
        }
        if fixed > 0 {
            AevonLog.info("[窗口] 停靠列落地校验：\(fixed) 个小窗的槽位有偏差，已对齐到固定格"
                + "（第一个变第五个 / 快速连点时不再留缺口）（AevonDockSettleV57）")
        }
    }

    /// 已停靠小窗的**原始**矩形（不外扩）。
    ///
    /// V0.0.46（AevonDockStackV46）：竖向堆叠要用它，不能用外扩版 ——
    /// 外扩 30pt 之后两个 293pt 高的小窗在 932pt 屏上就摆不下了
    /// （候选位全被判超界，回退成重叠），而停靠态的侧条本来就在窗内，不需要留这份余量。
    static func dockedFrames(excluding window: AevonWindowView?) -> [CGRect] {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return [] }
        var rects: [CGRect] = []
        for view in layer.subviews where !view.isHidden && view.alpha > 0.01 {
            guard let win = view as? AevonWindowView else { continue }
            if win === window { continue }
            guard win.isDocked else { continue }
            rects.append(win.frame)
        }
        return rects
    }

    /// 某个窗刚改变停靠状态：通知其它窗重新避让一次（V0.0.44，AevonDockAvoidV44）。
    static func avoidDockedWindow(_ window: AevonWindowView) {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return }
        for view in layer.subviews {
            guard let win = view as? AevonWindowView, win !== window else { continue }
            win.avoidDockedWindows()
        }
    }

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
        if let identity = identity, !identity.isEmpty {
            appSceneIdentity = identity
        }
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

/// 从 `SBDeviceApplicationSceneViewController` 上多策略探测它承载的场景标识
/// （V0.0.59，AevonFrontmostCloseV59）。拿不到返回 nil（只影响关窗休眠的精确性，
/// 不影响任何显示功能）。
private func aevonSceneIdentity(fromVC vc: UIViewController) -> String? {
    for name in ["scene", "representedScene", "hostScene", "_scene"] {
        let sel = Selector((name))
        guard vc.responds(to: sel), let scene = AevonRuntime.send(vc, sel) else { continue }
        for key in ["identifier", "persistentIdentifier"] {
            if let id = AevonRuntime.send(scene, Selector((key))) as? String, !id.isEmpty {
                return id
            }
        }
        for ivar in ["_identifier", "_persistentIdentifier", "_sceneIdentifier"] {
            if let id = AevonRuntime.ivarString(scene, ivar), !id.isEmpty { return id }
        }
    }
    for ivar in ["_sceneIdentifier", "_sceneID"] {
        if let id = AevonRuntime.ivarString(vc, ivar), !id.isEmpty { return id }
    }
    return nil
}

/// App 画面容器出现：把它交给宿主，容器会搬进去，从而压在全屏 App 之上。
@_cdecl("AevonSceneVCDidAppear")
public func AevonSceneVCDidAppear(_ vc: UIViewController) {
    guard vc.isViewLoaded else { return }
    let view = vc.view!
    let identity = aevonSceneIdentity(fromVC: vc)
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
