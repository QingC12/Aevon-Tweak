import UIKit

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
    /// 当前 App 场景的容器视图（弱引用；App 关掉后自动失效）
    private static weak var appSceneView: UIView?

    /// 入口视图的统一挂载点（手势条 / 悬浮球 / 圆盘 / 面板都往这里加）
    static var activeRoot: UIView? { return container }
    /// 历史别名，语义同 `activeRoot`
    static var rootView: UIView? { return container }
    static var isInstalled: Bool { return container != nil }
    static var currentHostView: UIView? { return container?.superview }

    // MARK: - 创建

    /// 确保入口窗口与容器存在（幂等）。成功返回容器，失败返回 nil（并在稍后重试）。
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

        let host = AevonEntryWindow(windowScene: scene)
        host.frame = UIScreen.main.bounds
        host.backgroundColor = .clear
        // V0.0.19 起入口窗口层级 = 1e7。桌面 / 回桌面场景靠它；
        // App 前台时它会被 App 画面容器压住，改由容器搬家解决（见类注释）。
        host.windowLevel = AevonWindowLevels.entry

        // 根视图命中自身返回 nil：未命中即穿透到下层
        let controller = AevonBubbleController()
        host.rootViewController = controller
        host.isHidden = false
        // 立刻走一次布局：保证根视图 bounds 不是 0
        host.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        let box = AevonEntryContainerView(frame: controller.view.bounds)
        box.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.backgroundColor = .clear
        box.isUserInteractionEnabled = true
        controller.view.addSubview(box)

        window = host
        container = box
        AevonEdgeEntry.attachProbe(to: host)
        startWatchdog()

        let bounds = box.bounds
        AevonLog.info("[入口] 入口窗口与容器已创建（level=\(Int(host.windowLevel.rawValue))，场景 \(type(of: scene))，容器 \(Int(bounds.width))x\(Int(bounds.height))，原因=\(reason)）（AevonEntryHost AevonSingleContainerV22）")

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
        // 父视图换了，手势条 / 悬浮球按新 bounds 重新落位
        AevonEdgeEntry.refreshLayoutIfNeeded()
        AevonBubble.shared.refreshLayoutIfNeeded()
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
    static func appSceneAppeared(_ view: UIView, reason: String) {
        guard container != nil else { return }
        // App 切换器里的小卡片、分屏窄条、被推到后台的场景容器都不接管，
        // 只认「真的铺满整屏、并且确实在窗口里显示着」的那一个。
        guard coversScreen(view) else { return }
        appSceneView = view
        attach(to: view, reason: reason)
        // 场景出现后系统会继续往这个 view 里塞内容，延后再顶一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard appSceneView === view, coversScreen(view) else { return }
            attach(to: view, reason: "\(reason)（延后重顶）")
        }
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
        attachToWindowRoot(reason: "App 场景消失")
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
        AevonBubble.shared.refreshLayoutIfNeeded()
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

/// App 画面容器出现：把它交给宿主，容器会搬进去，从而压在全屏 App 之上。
@_cdecl("AevonSceneVCDidAppear")
public func AevonSceneVCDidAppear(_ vc: UIViewController) {
    guard vc.isViewLoaded else { return }
    let view = vc.view!
    DispatchQueue.main.async {
        AevonEntryHost.appSceneAppeared(view, reason: "App 画面进入（AevonSceneVCHookV22）")
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
