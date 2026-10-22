import UIKit

/// 入口窗口（全局唯一）。
///
/// V0.0.18 的结构性调整，依据是 V0.0.17 的真机日志：
///   · `[悬浮球] 点击，打开应用选择面板` 在整个会话里出现多次 → 悬浮球所在窗口的触摸一直是好的；
///   · `[边缘] 手势区收到触摸` 只有 2 次，且两次都紧跟在「悬浮球面板已打开」之后；
///     桌面裸态和 App 前台时整场零触发（连一行「收到触摸」都没有，说明触摸压根没进视图）。
///   两个窗口层级相同（alert − 1）、场景相同、根视图类相同，却一个能收触摸一个收不到。
///   继续猜「第二个窗口为什么收不到」性价比太低 —— 直接**只保留一个窗口**：
///   悬浮球、边缘手势条、应用面板、圆盘全部挂进这同一个已经验证可用的容器。
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

/// 场景根视图上的覆盖层（V0.0.21）。
///
/// 它不属于任何 UIWindow，直接作为 `SBWindowSceneViewController.view` 的子视图，
/// 靠 `bringSubviewToFront` 压在全屏 App 的容器之上 —— 这是唯一能盖住 App 的办法
/// （窗口层级对「兄弟视图」无效，见 `AevonHostWindow.sceneRootView` 的说明）。
/// 命中自身返回 nil，其余触摸照常穿透，不会影响系统与 App。
final class AevonOverlayRootView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === self ? nil : hit
    }
}

/// 入口窗口宿主：创建 / 复用唯一窗口，对外只暴露根视图。
enum AevonEntryHost {
    private static var window: AevonEntryWindow?
    /// 场景根视图上的覆盖层（弱引用：它由 scene 根视图持有，被回收时自动失效）
    private static weak var overlay: AevonOverlayRootView?

    /// 窗口自己的根视图（永远存在，用来兜底）
    static var rootView: UIView? { return window?.rootViewController?.view }
    static var isInstalled: Bool { return window != nil }

    /// 当前有效的覆盖层（父视图还在才算数）
    static var overlayView: UIView? {
        guard let overlay = overlay, overlay.superview != nil else { return nil }
        return overlay
    }

    /// 入口视图的统一挂载点：有覆盖层就用覆盖层（能压住全屏 App），否则退回窗口根视图。
    static var activeRoot: UIView? {
        if let view = overlayView { return view }
        return window?.rootViewController?.view
    }

    /// 把覆盖层挂到当前场景的根视图上并顶到最前（幂等，随时可调）。
    @discardableResult
    static func ensureOverlay(reason: String) -> UIView? {
        guard let win = window else { return nil }
        let scene = win.windowScene ?? AevonHostWindow.preferredScene()
        guard let root = AevonHostWindow.sceneRootView(scene) else { return nil }

        if let existing = overlay, existing.superview === root {
            // 已经在正确的位置：只需要重新顶到最前（App 切换时容器可能被重新添加）
            root.bringSubviewToFront(existing)
            return existing
        }

        let view = overlay ?? AevonOverlayRootView(frame: root.bounds)
        if view.superview !== root { view.removeFromSuperview() }
        view.frame = root.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        root.addSubview(view)
        root.bringSubviewToFront(view)

        let old = window?.rootViewController?.view
        let moved = reparentEntries(from: old, to: view)
        overlay = view
        AevonLog.info("[入口] 覆盖层已挂到场景根视图（\(Int(root.bounds.width))x\(Int(root.bounds.height))，父类 \(type(of: root))，搬入 \(moved) 个入口视图，原因=\(reason)）（AevonSceneOverlayV21）")
        AevonEdgeEntry.refreshLayoutIfNeeded()
        AevonBubble.shared.refreshLayoutIfNeeded()
        return view
    }

    /// 把窗口根视图里的入口子视图整体搬到覆盖层（或反向搬回）。
    @discardableResult
    private static func reparentEntries(from old: UIView?, to new: UIView) -> Int {
        guard let old = old, old !== new else { return 0 }
        var count = 0
        for sub in old.subviews {
            sub.removeFromSuperview()
            new.addSubview(sub)
            count += 1
        }
        return count
    }

    /// 确保入口窗口存在（幂等）。成功返回根视图，失败返回 nil（并在稍后重试）。
    @discardableResult
    static func ensureInstalled(attempt: Int = 1, reason: String) -> UIView? {
        if let root = rootView { return root }
        guard AevonPrefs.bool("Enabled", default: false) else { return nil }
        guard attempt <= 12 else {
            AevonLog.warn("[入口] 多次尝试仍没有可用场景，放弃本次创建（\(reason)）")
            return nil
        }
        guard let scene = AevonHostWindow.preferredScene() ?? AevonHostWindow.firstWindowScene() else {
            AevonLog.info("[入口] 暂无前台场景，1.5 秒后重试（第 \(attempt) 次，\(reason)）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                _ = ensureInstalled(attempt: attempt + 1, reason: reason)
            }
            return nil
        }

        let host = AevonEntryWindow(windowScene: scene)
        host.frame = UIScreen.main.bounds
        host.backgroundColor = .clear
        // V0.0.19：层级从 alert − 1（1999）直接抬到 1e7。
        // V0.0.18 日志证明「桌面能呼出、全屏 App 里连触发条都不可见」——
        // 前台 App 的画面在窗口树上压着 1999，所以整层被盖住。
        host.windowLevel = AevonWindowLevels.entry

        // 根视图是 AevonBubbleRootView：命中自身返回 nil，未命中即穿透到下层
        let controller = AevonBubbleController()
        host.rootViewController = controller
        host.isHidden = false
        // 立刻走一次布局：保证根视图 bounds 不是 0。
        // 子视图落在父视图 bounds 之外时 hitTest 直接返回 nil，触摸永远进不来 ——
        // 顺手把这个可能性彻底排除掉。
        host.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        window = host
        AevonEdgeEntry.attachProbe(to: host)
        startWatchdog()

        let bounds = controller.view.bounds
        AevonLog.info("[入口] 统一窗口已创建（level=\(Int(host.windowLevel.rawValue))，scene=\(scene.activationState.rawValue)，根视图 \(Int(bounds.width))x\(Int(bounds.height))，原因=\(reason)）（AevonEntryHost AevonLevel1e7）")
        // 立刻尝试挂场景覆盖层（能盖住全屏 App 的那一层）
        if let view = ensureOverlay(reason: reason) { return view }
        return controller.view
    }

    /// 场景变化 / 尺寸变化后重新落位（幂等，可随时调用）。
    static func refreshLayout(reason: String) {
        guard let root = rootView else { return }
        root.layoutIfNeeded()
        AevonEdgeEntry.refreshLayoutIfNeeded()
        AevonBubble.shared.refreshLayoutIfNeeded()
        let bounds = root.bounds
        if bounds.width < 1 || bounds.height < 1 {
            AevonLog.warn("[入口] 根视图尺寸异常（\(Int(bounds.width))x\(Int(bounds.height))，\(reason)）")
        }
    }

    /// 场景看门狗（V0.0.20 引入，V0.0.21 收紧）。
    ///
    /// **V0.0.21 修正**：V0.0.20 每 2 秒按场景打分把窗口搬一次，
    /// 结果搬进了 `SBSystemApertureCurtainWindowScene`（灵动岛帘幕场景）——
    /// 该场景不参与触摸命中，整版边缘手势全废（真机日志 Aevon(14)：
    /// 桌面上只有悬浮球能点，右边缘零事件）。
    /// 现在只在「当前场景角色不合格」时才纠正，正常运行时一个字节都不动。
    private static var watchdog: Timer?
    private static var tickCount = 0

    static func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { _ in watchdogTick() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        AevonLog.info("[入口] 场景看门狗已启动（每 3 秒核对角色，每 30 秒打一次窗口栈，只在场景不合格时纠正）（AevonSceneWatch）")
    }

    private static func watchdogTick() {
        guard let host = window else { return }
        tickCount += 1

        // 每轮都把覆盖层重新顶到最前（App 切前台时它的容器会被重新添加，可能盖住我们）
        ensureOverlay(reason: "周期")

        // 只纠正「角色不合格 / 场景掉了」的情况
        if !AevonHostWindow.isAcceptableScene(host.windowScene) {
            if let target = AevonHostWindow.preferredScene() {
                let from = host.windowScene.map { "\(type(of: $0))<\($0.session.role.rawValue)>" } ?? "无"
                host.windowScene = target
                host.windowLevel = AevonWindowLevels.entry
                host.isHidden = false
                AevonLog.warn("[入口] 场景不合格，已纠正 \(from) → \(type(of: target))<\(target.session.role.rawValue)>（AevonSceneFix AevonSceneWhiteListV21）")
                dumpWindowStack("场景纠正")
                return
            }
        }

        // 前 3 分钟每 30 秒打一次栈（够用户打开 App 验证一轮）
        if tickCount <= 60, tickCount % 10 == 0 {
            dumpWindowStack("周期")
        }
    }

    /// 把入口窗口重新顶到最上层（V0.0.19）。
    ///
    /// 依据：桌面可用、全屏 App 不可见 —— 除了层级被压，还有第二种可能：
    /// App 进入前台后 SpringBoard 又建了更高的窗口。所以每次「有 App 激活 / 回到桌面」
    /// 都重设一次层级与可见性，代价近乎为零，却能把这类时序问题抹平。
    static func raise(reason: String) {
        guard let host = window else { return }
        // 场景自愈（V0.0.21 收紧）：只有「角色不合格 / 场景掉了」才重挂。
        // 旧实现只要状态不是 foregroundActive 就重挂，在场景切换瞬间容易踩到正在销毁的场景。
        if !AevonHostWindow.isAcceptableScene(host.windowScene) {
            if let scene = AevonHostWindow.preferredScene() {
                host.windowScene = scene
                AevonLog.info("[入口] 窗口场景已重挂 → \(type(of: scene))<\(scene.session.role.rawValue)>（\(reason)）")
            }
        }
        let before = host.windowLevel.rawValue
        host.windowLevel = AevonWindowLevels.entry
        if host.isHidden { host.isHidden = false }
        if before != AevonWindowLevels.entry.rawValue {
            AevonLog.info("[入口] 层级已重设 \(Int(before)) → \(Int(host.windowLevel.rawValue))（\(reason)）")
        }
        // V0.0.21：真正决定「App 前台看不看得见」的是场景根视图上的覆盖层，窗口层级只是兜底
        ensureOverlay(reason: reason)
    }

    /// 窗口栈诊断（V0.0.19）：把当前所有场景的窗口按层级打出来。
    ///
    /// 下一版如果 App 前台仍然看不到触发条，这份栈就能直接告诉我们
    /// 「有没有比 1e7 更高的窗口」「App 画面到底挂在哪一级」「我们的窗口还在不在」，
    /// 不用再靠猜。
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
        AevonLog.info("[诊断] 窗口栈（\(tag)）：\(hostState) | \(parts.joined(separator: " | "))")
    }
}
