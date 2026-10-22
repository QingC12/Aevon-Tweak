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
        guard let scene = AevonHostWindow.firstWindowScene() else {
            AevonLog.info("[入口] 暂无前台场景，1.5 秒后重试（第 \(attempt) 次，\(reason)）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                _ = ensureInstalled(attempt: attempt + 1, reason: reason)
            }
            return nil
        }

        let host = AevonEntryWindow(windowScene: scene)
        host.frame = UIScreen.main.bounds
        host.backgroundColor = .clear
        // 与「已验证可收触摸」的悬浮球窗口完全一致的层级（alert − 1 = 1999）
        host.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)

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

        let bounds = controller.view.bounds
        AevonLog.info("[入口] 统一窗口已创建（level=\(Int(host.windowLevel.rawValue))，scene=\(scene.activationState.rawValue)，根视图 \(Int(bounds.width))x\(Int(bounds.height))，原因=\(reason)）（AevonEntryHost）")
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
}
