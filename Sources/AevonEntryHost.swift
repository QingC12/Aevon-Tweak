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

/// 入口窗口宿主：创建 / 复用唯一窗口，对外只暴露根视图。
enum AevonEntryHost {
    private static var window: AevonEntryWindow?

    static var rootView: UIView? { return window?.rootViewController?.view }
    static var isInstalled: Bool { return window != nil }

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

    /// 场景看门狗（V0.0.20）。
    ///
    /// 每 2 秒对比一次「当前挂着的场景」与「打分最高的场景」：
    ///   · 不一致就把窗口搬过去（`windowScene` 可以在运行中改，子视图全部保留）；
    ///   · 每 10 秒打一次窗口栈（只在前 5 分钟），保证「App 前台时到底有几个场景、
    ///     我们的窗口还在不在、有没有更高的窗口」一定能在日志里看到。
    private static var watchdog: Timer?
    private static var tickCount = 0

    static func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in watchdogTick() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        AevonLog.info("[入口] 场景看门狗已启动（每 2 秒核对场景，每 10 秒打一次窗口栈）（AevonSceneWatch）")
    }

    private static func watchdogTick() {
        guard let host = window else { return }
        tickCount += 1

        if let preferred = AevonHostWindow.preferredScene() {
            let currentScore = host.windowScene.map { AevonHostWindow.sceneScore($0) } ?? Int.min
            let preferredScore = AevonHostWindow.sceneScore(preferred)
            // 只有「明显更好」才搬家，避免多个场景同分时来回抖动
            if preferred !== host.windowScene, preferredScore > currentScore {
                host.windowScene = preferred
                host.windowLevel = AevonWindowLevels.entry
                host.isHidden = false
                AevonLog.info("[入口] 场景切换 → \(type(of: preferred))（角色 \(preferred.session.role)，状态 \(preferred.activationState.rawValue)，得分 \(currentScore) → \(preferredScore)）")
                dumpWindowStack("场景切换")
                return
            }
        }

        // 前 5 分钟每 10 秒打一次栈：用户一般会在这段时间里打开 App 验证
        if tickCount <= 150, tickCount % 5 == 0 {
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
        // 场景自愈：SpringBoard 的场景偶尔会掉到 unattached/background（V0.0.18 日志里
        // 就是 scene=0）。窗口挂在不活跃的场景上时不会参与合成，全屏 App 下自然看不见。
        // 这里在有前台场景时重新挂一次。
        let state = host.windowScene?.activationState
        if state == nil || state == .unattached || state == .background {
            if let scene = AevonHostWindow.preferredScene(), scene !== host.windowScene {
                host.windowScene = scene
                AevonLog.info("[入口] 窗口场景已重挂（\(reason)）")
            }
        }
        let before = host.windowLevel.rawValue
        host.windowLevel = AevonWindowLevels.entry
        if host.isHidden { host.isHidden = false }
        if before != AevonWindowLevels.entry.rawValue {
            AevonLog.info("[入口] 层级已重设 \(Int(before)) → \(Int(host.windowLevel.rawValue))（\(reason)）")
        }
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
            parts.append("#\(index)\(mine)\(type(of: scene))<\(scene.session.role)>状态\(scene.activationState.rawValue)·\(scene.windows.count)窗[\(items.joined(separator: " "))]")
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
