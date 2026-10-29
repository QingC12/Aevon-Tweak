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

/// V0.2.91（AevonHomeFreezeV291）：**回桌面过渡哨** —— 抓「缩放动画的第一帧」。
///
/// Aevon(60) 视频逐帧实锤「回桌面时浮窗由虚到实 / 消失约 1s 再弹回」的真时序：
/// 容器（含浮窗面板）在 App 全屏时物理上挂在 App 场景视图里（V0.0.22 压屏需要），
/// 上滑回桌面的缩放动画里**面板跟着 App 卡片一起缩**，而「场景消失」布防事件
/// （appSceneDisappeared → noteForegroundSceneLost）要等场景真被收走才来 ——
/// 动画都跑完了。0.2.90 的根级冻结帧在布防那拍是装上了（17:08:24.191 日志实锤），
/// 但用户看到的「缩小消失 → 弹回」发生在布防**之前**。
///
/// 修法 = Stheno 式「过渡是一等公民」：用 CADisplayLink 盯住 App 场景视图的
/// 窗口几何（tick-to-tick 比较，不用绝对基线 —— S2 改画布后场景视图可能恒为
/// 画布尺寸，绝对基线会永久误报），几何一变（连续两拍偏离 >2pt）判定过渡开始：
/// **第一帧**就把容器拉回窗口根 + 对浮窗装根级冻结帧。面板从此不再跟着缩放，
/// 用户看到的是「画面停住原地」，动画结束布防照旧（幂等）。
///
/// 纪律：
///  · 只在浮窗开着且容器挂在场景视图里时运行（每帧只做一次 rect 换算，无树遍历、
///    无 hitTest）；
///  · 开窗后 1.0s 内不触发（开窗自身的画布布局抖动不是过渡）；
///  · 触发一次即停（布防链接管后续），场景重新出现（appSceneAppeared）时再布哨。
final class AevonTransitionSentry: NSObject {
    static let shared = AevonTransitionSentry()
    private var link: CADisplayLink?
    private var lastRect: CGRect = .zero
    private var deviationTicks = 0
    private var armedAt: CFTimeInterval = 0
    /// 开窗时刻（开窗自身抖动的豁免窗）。由 WindowManager 在 open 成功后刷新。
    var lastOpenAt: CFTimeInterval = 0

    func arm() {
        guard link == nil else { return }
        lastRect = .zero
        deviationTicks = 0
        armedAt = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func disarm() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard let sceneView = AevonEntryHost.appSceneView,
              sceneView.window != nil,
              AevonEntryHost.container?.superview === sceneView else {
            disarm()
            return
        }
        // 开窗豁免窗：1.0s 内的几何变化是开窗自身的画布布局，不是过渡
        if CACurrentMediaTime() - lastOpenAt < 1.0 { return }
        let rect = sceneView.convert(sceneView.bounds, to: nil)
        defer { lastRect = rect }
        if lastRect.isEmpty { return }   // 首拍只记基线
        let dx = max(abs(rect.minX - lastRect.minX), abs(rect.minY - lastRect.minY))
        let dw = max(abs(rect.width - lastRect.width), abs(rect.height - lastRect.height))
        let moved = dx > 2 || dw > 2
        let transformed = !sceneView.transform.isIdentity
        guard moved || transformed else {
            deviationTicks = 0
            return
        }
        deviationTicks += 1
        guard deviationTicks >= 2 else { return }   // 连续两拍才认（防单帧毛刺）
        disarm()
        AevonLog.warn("[入口] 回桌面过渡哨命中：场景视图几何连续 \(deviationTicks) 拍变化"
            + "（\(Int(lastRect.width))x\(Int(lastRect.height)) → \(Int(rect.width))x\(Int(rect.height))，"
            + "transform=\(transformed ? "非恒等" : "恒等")）→ 容器立即归位 + 根级冻结帧"
            + "（AevonHomeFreezeV291）")
        AevonEntryHost.attachToWindowRoot(reason: "回桌面过渡哨（缩放动画第一帧）")
        AevonWindowManager.noteTransitionFreeze()
        // 误报还原网：+1.5s 后场景还在屏、几何已稳、容器仍在窗口根 → 判误报
        //（如控制中心半拉时 App 视图轻微位移），把容器搬回场景视图恢复常态。
        // 真回桌面的场景此刻已被收走（appSceneView == nil），还原网自然不命中；
        // 误报期间装的冻结帧由看门在 cs=2 时自撤（removeDarkFreeze）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let sv = AevonEntryHost.appSceneView, sv.window != nil else { return }
            let r = sv.convert(sv.bounds, to: nil)
            let screen = UIScreen.main.bounds
            let settled = abs(r.width - screen.width) < 2 && abs(r.height - screen.height) < 2
                && sv.transform.isIdentity
            guard settled, let box = AevonEntryHost.container, box.superview !== sv else { return }
            AevonEntryHost.reattachToSceneView()
            AevonLog.info("[入口] 回桌面过渡哨误报还原：场景仍在屏且几何稳定 → 容器搬回场景视图"
                + "（AevonHomeFreezeV291）")
        }
    }
}

extension AevonEntryHost {
    /// V0.2.91（AevonHomeFreezeV291）：过渡哨误报还原专用 —— 把容器搬回场景视图。
    static func reattachToSceneView() {
        guard let sv = appSceneView, isUsableHost(sv) else { return }
        attach(to: sv, reason: "过渡哨误报还原")
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
    // V0.2.91（AevonHomeFreezeV291）：internal 化 —— 回桌面过渡哨要读这两个引用。
    static var container: AevonEntryContainerView?
    /// 浮窗层（V0.0.36）：容器内专门承载浮窗外壳的子视图，永远在入口控件之下。
    private static var floatLayer: AevonWindowLayerView?
    /// 当前 App 场景的容器视图（弱引用；App 关掉后自动失效）
    // V0.2.91（AevonHomeFreezeV291）：internal 化 —— 回桌面过渡哨要读这个引用。
    static weak var appSceneView: UIView?

    /// 浮窗外壳的统一挂载点（V0.0.36）：浮窗层优先，容器兜底。
    static var floatHost: UIView? { return floatLayer ?? container }

    /// V0.1.5（AevonSystemGestureV105）：把视图挂到入口容器最上层。
    ///
    /// 挂在**容器**里而不是窗口：容器会搬进 App 画面容器
    /// （`SBDeviceApplicationSceneViewController.view`），带子跟着走，全屏 App 上一样在。
    /// 容器还没创建时返回 false，调用方自己重试。
    static func attachOverlay(_ view: UIView) -> Bool {
        guard let container = container else { return false }
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        return true
    }

    /// 该点是否落在某个已开浮窗上（V0.0.36 引入，V0.0.37 扩展到外侧手势区）。
    /// 入口探针据此区分「摸浮窗」与「摸边缘热区」：浮窗和入口共用一个窗口之后，
    /// 不加这道判断，浮窗压住热区时拖浮窗就会误呼圆盘。
    /// V0.0.37（AevonSthenoEdgeBarV37）：手势区伸到浮窗外侧 barThickness pt，
    /// 判定矩形同步外扩，防止拖边条 / 缩放时被当成热区触摸接管。
    static func pointHitsFloatingWindow(at point: CGPoint) -> Bool {
        let margin = AevonWindowView.barThickness
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return false }
        for win in layer.subviews where !win.isHidden && win.alpha > 0.01 {
            if win.frame.insetBy(dx: -margin, dy: -margin).contains(point) { return true }
        }
        return false
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

    /// V0.2.61（AevonDockTapFixV261，用户 Aevon(35) #6）：屏幕点落在哪个**停靠小窗**里。
    ///
    /// 停靠态四周边条手柄已摘除（0.2.60），`grab(at:)` 只看手柄 frame → 恒返回 nil，
    /// 全局通道因此完全不知道这一下点在小窗上。这里给停靠态一条独立的 frame 判定，
    /// 不依赖任何子视图与命中测试。
    static func dockedWindow(atScreenPoint point: CGPoint) -> AevonWindowView? {
        guard let layer = floatLayer, !layer.subviews.isEmpty else { return nil }
        let layerPoint = floatLayerPoint(fromScreen: point)
        for view in layer.subviews.reversed() {
            guard let win = view as? AevonWindowView else { continue }
            guard win.isDocked, !win.isHidden, win.alpha > 0.01 else { continue }
            if win.frame.contains(layerPoint) { return win }
        }
        return nil
    }

    /// 屏幕（窗口）坐标 → 浮窗层坐标。浮窗层全屏且 origin 为 0，正常是恒等变换，
    /// 但容器被搬进 App 场景视图后坐标系由系统决定，统一走 convert 才不会偏。
    static func floatLayerPoint(fromScreen point: CGPoint) -> CGPoint {
        guard let layer = floatLayer else { return point }
        return layer.convert(point, from: nil)
    }

    /// 入口视图的统一挂载点（圆盘 / 面板都往这里加）
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

    /// V0.1.14（AevonHostAuditV114）：**只读**宿主审计快照，专供探针 P7-2。
    ///
    /// 要回答的问题是「我们自己的窗口还在，为什么右缘的触摸轮不到我们」：
    ///   · 入口窗口本身在不在窗口栈里、层级多少、右缘点上 `hitTest` 返回什么；
    ///   · 容器现在挂在谁的下面、在兄弟里的序号（这决定它和 App 画面谁先被命中）；
    ///   · App 画面容器是不是就是容器的父视图。
    /// 全部只读：不 addSubview、不改 frame、不发任何会改状态的消息。
    static var debugHostSnapshot: String {
        func rectText(_ rect: CGRect) -> String {
            return "(\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.size.width)),\(Int(rect.size.height)))"
        }
        var lines: [String] = []
        if let win = window {
            let sceneName = win.windowScene.map { AevonSafeClassName($0) ?? "?" } ?? "无场景"
            lines.append("入口窗口 \(AevonSafeClassName(win) ?? "?") level=\(Int(win.windowLevel.rawValue)) hidden=\(win.isHidden ? 1 : 0) alpha=\(String(format: "%.2f", win.alpha)) frame=\(rectText(win.frame)) 交互=\(win.isUserInteractionEnabled ? 1 : 0) 场景=\(sceneName)")
            for (label, point) in [("右缘中部", CGPoint(x: 424, y: 400)), ("热区内", CGPoint(x: 424, y: 750))] {
                let local = win.convert(point, from: nil)
                let hit = win.hitTest(local, with: nil)
                let hitName = hit.map { AevonSafeClassName($0) ?? "?" } ?? "nil（穿透）"
                var chain = "—"
                if let hit = hit {
                    chain = AevonViewHostChain(hit, 4) ?? "?"
                }
                lines.append("入口窗口命中 \(label)(\(Int(point.x)),\(Int(point.y))) → \(hitName) 链=\(chain)")
            }
        } else {
            lines.append("入口窗口 未创建")
        }
        if let box = container, let host = box.superview {
            let index = host.subviews.firstIndex(of: box) ?? -1
            var names: [String] = []
            for (offset, sibling) in host.subviews.prefix(8).enumerated() {
                names.append("\(offset):\(AevonSafeClassName(sibling) ?? "?")")
            }
            lines.append("容器 \(AevonSafeClassName(box) ?? "?") frame=\(rectText(box.frame)) 父=\(AevonSafeClassName(host) ?? "?") 序号=\(index)/\(host.subviews.count) 前几个兄弟=\(names.joined(separator: " "))")
            let appName = appSceneView.map { AevonSafeClassName($0) ?? "?" } ?? "无"
            lines.append("App 画面容器=\(appName) 与容器父视图同体=\((appSceneView != nil && appSceneView === host) ? "是" : "否")")
            lines.append("容器宿主链=\(AevonViewHostChain(box, 6) ?? "?")")
        } else {
            lines.append("容器 未挂载（桌面态或尚未创建）")
        }
        return lines.joined(separator: "\n")
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
        guard AevonPrefs.bool("Enabled", default: true) else { return nil }
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
        startWatchdog()
        // V0.2.78（AevonOverlayYieldV278）：系统浮层让位巡检（控制中心/通知中心/切换器）
        startOverlayWatch()
        // V0.2.50（AevonRingGripV250）：圆盘的可见把手挂到容器最上层 ——
        // 容器会随全屏 App 搬进画面容器，所以桌面 / 全屏 App 里都摸得到。
        AevonRingGrip.installIfNeeded(force: true)

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
            // V0.2.60（AevonGripFrontV260）：容器里后加的子视图会压住把手，顺手顶回来
            AevonRingGrip.installIfNeeded()
            return
        }
        let from = box.superview.map { AevonRuntime.className($0) ?? "\(type(of: $0))" } ?? "无"
        box.removeFromSuperview()
        box.frame = host.bounds
        host.addSubview(box)
        host.bringSubviewToFront(box)
        // V0.2.60（AevonGripFrontV260）：搬完家把把手顶到容器最上层（全屏 App 里
        // 只有这一个视图是我们的命中面，被浮窗层 / 圆盘压住就等于「把手消失」）
        AevonRingGrip.installIfNeeded()
        // 父视图换了，手势条按新 bounds 重新落位
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
    ///
    /// V0.1.6（AevonFullscreenCloseV106）：多了 `sceneIdentifier`。同一个场景被系统
    /// 拿去全屏呈现之后，我们浮窗里那个 presenter 就拿不到画面了（用户看到的是黑窗），
    /// 所以要在这里认出来「全屏进来的是浮窗里那个 App」，然后把浮窗关掉。
    static func appSceneAppeared(_ view: UIView, sceneIdentifier: String?, reason: String) {
        guard container != nil else { return }
        // App 切换器里的小卡片、分屏窄条、被推到后台的场景容器都不接管，
        // 只认「真的铺满整屏、并且确实在窗口里显示着」的那一个。
        guard coversScreen(view) else { return }
        if let identifier = sceneIdentifier {
            AevonWindowManager.handleFullscreenSceneAppeared(sceneIdentifier: identifier)
            // V0.2.5（AevonAppProbeWideV205）：sceneIdentifier 形如
            // "<bundleID>-<UUID>"。解析出 bundleID 交给日志桥做动态监听 ——
            // 沙盒 App 写不了 /var/mobile/Aevon.log，只会写自己 bundleID 的域。
            if let bundleID = extractBundleID(from: identifier) {
                AevonAppSideBridge.noteDomain(bundleID)
                // V0.2.7（AevonAppBlindDiagV207）：记录前台 App，供右缘诊断行点名
                currentForegroundBundleID = bundleID
            }
        }
        appSceneView = view
        attach(to: view, reason: reason)
        // V0.2.91（AevonHomeFreezeV291）：App 场景在场 = 容器挂在场景视图里 =
        // 回桌面缩放动画会把面板一起缩 → 布过渡哨（浮窗没开时哨兵 tick 首拍自撤）。
        AevonTransitionSentry.shared.arm()
        // 场景出现后系统会继续往这个 view 里塞内容，延后再顶一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard appSceneView === view, coversScreen(view) else { return }
            attach(to: view, reason: "\(reason)（延后重顶）")
            /* V0.2.65（AevonFullscreenRetryV265，用户 Aevon(38) #6「浮窗打开设置时，
             * 在桌面点击设置全屏打开时全屏黑屏，但浮窗显示设置内容（并没有自动关闭浮窗）」）：
             *
             * 第一次回调时场景视图往往还没铺满（`coversScreen` 为假）→ 直接 return，
             * `handleFullscreenSceneAppeared` **一次都没被调用**（Aevon(38) 整篇日志
             * 没有一条「自动关闭浮窗」）。0.25 秒后视图铺满了，这里补一次同样的交接判定，
             * 浮窗才会真的让位。 */
            if let identifier = sceneIdentifier {
                AevonLog.info("[入口] 全屏画面延后补判（\(identifier)）：交接判定补一次，"
                    + "浮窗该让位就让位（AevonFullscreenRetryV265）")
                AevonWindowManager.handleFullscreenSceneAppeared(sceneIdentifier: identifier)
            }
        }
    }

    /// V0.2.5 起从场景标识解析 bundleID（V0.2.6 修正，AevonAppProbeWideV205）。
    /// Aevon(92) 实证场景标识有两种形态：
    ///   ① "sceneID:com.apple.mobilesafari-<UUID>"（UUID = 8-4-4-4-12 十六进制）；
    ///   ② "sceneID:org.coolstar.SileoStore-default"（浮窗拉起的 App 场景）。
    /// 0.2.5 只处理了 UUID 形态且没剥 "sceneID:" 前缀，导致监听域变成脏值
    /// 「sceneID:com.apple.mobilesafari」；解析失败返回 nil（不影响主流程）。
    static func extractBundleID(from sceneIdentifier: String) -> String? {
        var s = sceneIdentifier
        if s.hasPrefix("sceneID:") { s = String(s.dropFirst("sceneID:".count)) }
        // 形态一：<bundleID>-<UUID> —— 去掉尾部 37 个字符（1 个连字符 + 36 位 UUID）
        if s.range(of: "-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                   options: .regularExpression) != nil {
            if s.count > 37 { return String(s.dropLast(37)) }
            return nil
        }
        // 形态二：<bundleID>-default
        if s.hasSuffix("-default") { return String(s.dropLast("-default".count)) }
        return nil
    }

    /// V0.2.7（AevonAppBlindDiagV207）：最近一次确认「铺满整屏」的前台 App bundleID。
    /// 给右缘诊断用：global 兜底呼盘时若该 App 的 App 侧毫无起手痕迹，日志点名它。
    static var currentForegroundBundleID = ""

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
        currentForegroundBundleID = ""   // V0.2.7（AevonAppBlindDiagV207）：回桌面即清
        AevonTransitionSentry.shared.disarm()   // V0.2.91（AevonHomeFreezeV291）：过渡已由布防链接管
        attachToWindowRoot(reason: "App 场景消失")
        // V0.2.47（AevonDarkGuardV247）：全屏 App 画面离场 = 回桌面 / 切 App。
        //
        // 这一刻浮窗里那个 App 的场景也会被系统一起置后台，远程表面随即被回收
        // （0.2.46 真机：浮窗整块变黑，必须关掉重开）。开窗时的前台补偿只补 8 次
        // （约 7 秒），过了就没人管 —— 这就是「有概率」的由来。这里让浮窗重新布防。
        AevonWindowManager.noteForegroundSceneLost()
    }

    /// 搬回入口窗口根视图。
    /// V0.2.66（AevonGripFastV266）：改为 internal —— 回桌面布防（noteForegroundSceneLost）
    /// 也要叫它：SB 主屏不是「App 场景消失」，容器经常还挂在离场 App 的画面视图里，
    /// 右缘把手跟着一起不可见 / 不可摸（用户 Aevon(39) #6「从全屏 App 回桌面，触发条
    /// 要等 1 秒左右才出现」）。布防那拍（桌面出现前 0.1s）主动搬回窗口根，把手即时就位。
    static func attachToWindowRoot(reason: String) {
        guard let host = window?.rootViewController?.view else { return }
        if host.bounds.width < 1 { host.frame = UIScreen.main.bounds }
        attach(to: host, reason: reason)
    }

    // MARK: - 布局 / 层级

    /// 场景变化 / 尺寸变化后重新落位（幂等，可随时调用）。
    static func refreshLayout(reason: String) {
        guard let box = container else { return }
        box.layoutIfNeeded()
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

    // MARK: - 系统浮层巡检（V0.2.78，AevonOverlayYieldV278）
    //
    // 用户 Aevon(50) #1：下拉控制中心时浮窗还在、按钮点不到。
    // 依据（Aevon(50) 窗口栈实锤）：`1080:SBControlCenterWindow` vs 我们
    // `10000000:AevonEntryWindow` —— 我们高近一万倍，视觉与触摸都压在控制中心之上。
    // 开源对照（MilkyWayReborn）：它把宿主窗口放 `UIWindowLevelAlert - 1`，系统浮层自然在上，
    // 从不跟系统抢层级；我们 level 动不得（牵一发动全身），改为**浮层在屏即让位**。
    private static var overlayWatch: Timer?
    private static var overlayHitName = ""
    private static var yieldGuardLogged = false
    /// V0.2.82（AevonYieldTouchGuardV282）：触点闸门的日志节流。
    private static var yieldTouchLogAt: CFTimeInterval = 0

    static func startOverlayWatch() {
        guard overlayWatch == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in overlayWatchTick() }
        RunLoop.main.add(timer, forMode: .common)
        overlayWatch = timer
        AevonLog.info("[窗口] 系统浮层巡检已启动（0.25 秒一拍，只读窗口表；"
            + "只对控制中心/通知中心让位，切换器不再参与；"
            + "开窗事务进行中不新开让位）"
            + "（AevonOverlayYieldV278 AevonNoSwitcherYieldV281 AevonYieldGuardV280）")
    }

    /// V0.2.81（AevonNoSwitcherYieldV281）：**切换器不再参与让位**。
    ///
    /// 0.2.78 把 `SBMainSwitcherWindow` 放进「在屏即让位」之后，Aevon(52)/(54) 两轮日志
    /// 都拍到同一幕（这就是用户说的「闪一下 / 打开不显示」）：
    ///     11:51:15.292  显窗时机 = 画布定稿回调（窗刚显形）
    ///     11:51:15.294  开窗入场：淡入
    ///     11:51:15.329  命中系统浮层 SBMainSwitcherWindow（在屏）→ 浮窗与把手让位
    ///     11:51:15.351……19.832   窗不可见（4.48 秒）
    ///     11:51:19.832  系统浮层让位 关：1 扇浮窗恢复显示
    /// 窗口只露了 35 毫秒就消失、4.5 秒后又回来 —— 一次完整的「闪」。
    ///
    /// 根因是 iOS 17 的窗口结构：**前台 App 的场景视图 `SBDeviceApplicationSceneView`
    /// 就挂在 `SBMainSwitcherWindow` 下面**，所以「该窗口在屏」等于「有 App 在前台」，
    /// 与「切换器被呼出」完全是两件事。0.2.80 加过一层「子树里必须真有切换器视图」的
    /// 二级判据，但 Aevon(54) 证明它依旧命中（切换器窗口的常驻子视图里就有匹配到
    /// 关键字的容器），也就是说这个信号在 iOS 17 上不可靠。
    ///
    /// 结论：**只让位给 0.2.78 用户真正要求的那两个**（控制中心 / 通知中心）。
    /// 切换器打开时浮窗保持在最上层 —— 这是 0.2.77 及之前的行为，用户从未因此报过问题，
    /// 而「打开浮窗后被藏 4.5 秒」是每轮都报。两害相权，取不藏。
    private static let overlayClassHints = [
        "ControlCenterWindow",   // 控制中心（1080）
        "CoverSheetWindow",      // 通知中心 / 锁屏（1050）
    ]

    /// 单个窗口是否算「系统浮层在屏」。
    private static func overlayWindowPresent(_ window: UIWindow) -> Bool {
        guard !window.isHidden, window.alpha > 0.5 else { return false }
        let name = String(describing: type(of: window))
        // 控制中心 / 通知中心：窗口出现即算（它们收起时 alpha 极低，已被上面挡掉）
        return overlayClassHints.contains(where: { name.contains($0) })
    }

    private static func overlayWatchTick() {
        // 没浮窗时不用盯（省电、也避免无意义的日志）
        guard AevonWindowManager.hasAnyWindow else {
            if AevonWindowManager.isOverlayYielded { AevonWindowManager.setSystemOverlayYield(false) }
            return
        }
        // V0.2.80（AevonYieldGuardV280）：开窗事务进行中一律不许让位 ——
        // Aevon(52) 11:08:41.691 就是「开窗第 0.4 秒被让位隐藏」，
        // 窗刚出现 0.17 秒就没了，3.5 秒后才恢复 = 用户说的「闪一下 + 打开不显示」。
        // 注意：只挡「新开让位」，已经让位的不阻断恢复（否则控制中心收起后窗不再回来）。
        var hit = ""
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows {
                // alpha 门槛取 0.5：CoverSheet 这类窗口常年存在，只是收起时 alpha 极低，
                // 用 0.5 才不会把「常驻但不可见」误判成「在屏」（0.2.70 键盘误报同款教训）。
                guard overlayWindowPresent(w) else { continue }
                hit = String(describing: type(of: w))
                break
            }
            if !hit.isEmpty { break }
        }
        let present = !hit.isEmpty
        /* V0.2.82（AevonYieldTouchGuardV282）：手指还在屏上时绝不让位。
         * 让位会让 UIKit 当场 cancel 这根手指并把 UITouch 摘掉，sendEvent 钩子手里的
         * 指针随之失效 —— Aevon(55) 两次 SIGSEGV 都紧跟让位 0.28 / 0.53 秒。
         * 推迟一拍对用户没有可见差别（他手指还按着，本来也点不到窗）。 */
        if present, AevonEdgeEntry.hasActiveTouches {
            let nowT = CACurrentMediaTime()
            if nowT - yieldTouchLogAt > 2.0 {
                yieldTouchLogAt = nowT
                AevonLog.info("[窗口] 命中 \(hit) 但手指还在屏上 → 本轮不让位，等抬手后再让"
                    + "（AevonYieldTouchGuardV282）")
            }
            return
        }
        if present, AevonSwitchCoordinator.shared.hasActive {
            if !yieldGuardLogged {
                yieldGuardLogged = true
                AevonLog.info("[窗口] 开窗事务进行中 → 不新开让位（命中 \(hit)，本轮跳过）"
                    + "（AevonYieldGuardV280）")
            }
            return
        }
        yieldGuardLogged = false
        if present, overlayHitName != hit {
            overlayHitName = hit
        }
        if AevonWindowManager.isOverlayYielded != present {
            /* V0.2.85（AevonYieldCrumbV285）：**让位前先落一条面包屑**。
             * Aevon(57) 崩溃点 2 的最后一条日志是「系统浮层让位 开」，而那条是在
             * `setSystemOverlayYield` **之后**才打的 —— 也就是说崩在让位内部时，
             * 日志里只剩「命中 … 但手指还在屏上」，根本分不清是让位崩的还是让位后崩的。
             * 现在拆成「开始 → 完成」两条，下一份日志能直接定位到哪一侧。 */
            if present {
                AevonLog.info("[窗口] 让位开始（命中 \(hit)，浮窗 \(AevonWindowManager.allWindows.count) 扇）"
                    + "（AevonYieldCrumbV285）")
            }
            AevonWindowManager.setSystemOverlayYield(present)
            if present {
                AevonLog.info("[窗口] 命中系统浮层 \(hit)（在屏）→ 浮窗与把手让位完成"
                    + "（AevonOverlayYieldV278 AevonYieldCrumbV285）")
            } else {
                AevonLog.info("[窗口] 系统浮层已收起 → 浮窗与把手恢复"
                    + "（AevonOverlayYieldV278）")
            }
        }
    }

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

        // 前 3 分钟每 30 秒打一次栈（够用户打开 App 验证一轮）
        if tickCount <= 60, tickCount % 10 == 0 {
            dumpWindowStack("周期")
        }
    }

    /// 窗口栈诊断：把当前所有场景的窗口按层级打出来，外加容器的挂载点。
    ///
    /// V0.1.6（AevonWinDumpFullV106）：这里原来是 `sorted.suffix(8)` —— 只印最高层 8 个。
    /// APP 场景稳定有 15 个窗口，剩下 7 个**从来没被打印过**，0.1.4 因此断言
    /// 「系统上没有 SystemGesture 窗口」。用被截断的证据去否定机制是错的，
    /// 现在改成全列（真正的逐行全景在 `AevonProbeV106.dumpWindowPanorama()`）。
    static func dumpWindowStack(_ tag: String) {
        var parts: [String] = []
        var index = 0
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            var items: [String] = []
            let sorted = scene.windows.sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
            for w in sorted {
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

    // MARK: - 失效瞬间探针（V0.2.57，AevonTouchProbeV257）

    /// 0.2.56 探针是 30 秒周期采样：Aevon(31) 全程只采到一次、且采样时刻一切健康
    /// —— 失效瞬间再次错过。触发端改为**每根 began 触发**（3 秒节流）：手势失效时
    /// 用户仍在触屏（点按可用），began 必达全局通道 → 取证必中失效瞬间。
    /// 输出 = 状态位 + 入口窗口四点命中与浮窗命中判定（链路级）+ 周期探针三路（识别器级）。
    private static var lastTouchProbeAt: CFTimeInterval = 0
    static func touchTriggeredProbeIfDue() {
        guard AevonPrefs.bool("GestureProbe", default: true) else { return }
        let now = CACurrentMediaTime()
        guard now - lastTouchProbeAt >= 3.0 else { return }
        lastTouchProbeAt = now
        /* V0.2.82（AevonProbeHitRetireV282，Aevon(55)「打开悬浮窗时依旧会闪，并且还会
         * 伴随着自动注销」）：**触摸热路径上的全部 hitTest 退役**。
         *
         * Aevon(55) 的崩溃栈（SIGSEGV=11，SpringBoard 直接被带走，Aevon.crash.log.old）：
         *     1   Aevon.dylib  AevonTouchHookInstall +15516   ← -[UIApplication sendEvent:] 钩子
         *     3-10 Aevon.dylib （AevonEdgeEntry 那一片：+134756…+169048）
         *     17  libdispatch  _dispatch_main_queue_callback_4CF
         * 两次崩溃都落在「开窗完成 / 让位」之后 0.3~0.5 秒，即**每根手指 began 都会走**的链上。
         *
         * 这条链上唯一在遍历**系统窗口视图树**的就是本函数：4 次入口窗口 hitTest，
         * 再加对 SBHomeScreenWindow / SBMainSwitcherWindow 各一次 hitTest。
         * hitTest 根本不是只读操作 —— 它递归调用每个子视图的 point(inside:with:)，
         * SpringBoard 的私有视图会在这条路径上做惰性初始化与断言，正是「点一下就注销」
         * 的经典形态（与 0.2.72「全类表遍历只扫不调也会死」同一类事故）。
         *
         * 它要回答的「手势为什么突然失效」0.2.73 已经定档（不在 Aevon 吞咽层）；
         * 兄弟探针 dumpGestureRecognizerProbe 0.2.81 已删。这里保留**纯字段读取**的摘要
         *（状态位 / 浮窗层子视图数 / 容器挂载点），不再对任何视图调用 hitTest。 */
        let layerCount = floatLayer?.subviews.count ?? 0
        let mount = container?.superview.map { AevonRuntime.className($0) ?? "\(type(of: $0))" } ?? "无"
        AevonLog.info("[诊断] 失效瞬间探针（只读版，零 hitTest）：\(AevonEdgeEntry.forensicStateText)"
            + " | 浮窗层子视图=\(layerCount) 容器挂载=\(mount)"
            + "（AevonTouchProbeV257 AevonProbeHostHitV273 AevonProbeHitRetireV282）")
        // V0.2.81（AevonDeadCodeV281）：此处原本还会调 dumpGestureRecognizerProbe ——
        // Aevon(54) 实测它每根手指都遍历 SB 所有窗口的整棵视图树列举 UIGestureRecognizer
        //（日志里 [SBFluidSwitcherTouchPassThroughScrollView]=112 / [SBIconScrollView]=93
        //  两行噪声都出自它），而它当初要查的「pan 突然失效」已在 0.2.73 定档
        //（不在 Aevon 吞咽层）→ 整段移除。
        // V0.2.82（AevonProbeHitRetireV282）：连本函数里的 hitTest 也一并退役（见上）。
    }
}

// MARK: - C 入口（供 AevonSceneHook.m 调用）

/// App 画面容器出现：把它交给宿主，容器会搬进去，从而压在全屏 App 之上。
///
/// `sceneIdentifier` 是 C 字符串（由 ObjC 侧从 sceneHandle 反查得到），
/// 指针只在本次回调内有效 —— 必须**立刻**拷贝成 Swift String 再异步派发，
/// 否则等主队列轮到我们时那块内存可能已经释放了。
@_cdecl("AevonSceneVCDidAppear")
public func AevonSceneVCDidAppear(_ vc: UIViewController, _ sceneIdentifier: UnsafePointer<CChar>?) {
    guard vc.isViewLoaded else { return }
    let view = vc.view!
    let identifier = sceneIdentifier.map { String(cString: $0) }
    DispatchQueue.main.async {
        AevonEntryHost.appSceneAppeared(view,
                                        sceneIdentifier: identifier,
                                        reason: "App 画面进入（AevonSceneVCHookV22）")
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
