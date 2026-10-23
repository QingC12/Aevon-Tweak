import Foundation
import UIKit

/// 单个 App 场景的承载器（V0.0.10 重写）。
///
/// V0.0.9 的做法是错的，两处都被真机日志证明：
/// 1. 自己 alloc 系统的场景层宿主容器（LayerHostContainerView）再逐个建宿主视图。
///    这个类不会「要求 App 渲染」——客户端从来没收到呈现请求，场景的图层列表
///    永远是空的，所以浮窗只有外壳、里面全黑（日志：约 3 秒没收到任何图层）。
/// 2. 拿不到图层时又去 alloc 呈现管理器（PresentationManager）兜底，初始化失败后那个
///    对象被直接释放，它内部的呈现者持有者（ScenePresenterOwner）没 invalidate，dealloc 抛
///    `NSInternalInconsistencyException ... must be invalidated before it can be deallocated`，
///    在 SpringBoard 里就是自动注销（crash.log 的调用栈底部正是 Timer → 这段兜底）。
///
/// 正确路径（iOS 15–17，参考 LiveContainer / MilkyWay 的做法）：
///   scene.uiPresentationManager
///     → createPresenterWithIdentifier:           申请一个呈现者
///     → modifyPresentationContext: appearanceStyle = 2（只要内容，不要系统装饰）
///     → activate                                  这一步才会让 App 真正开始渲染
///     → presentationView                          把这张视图塞进浮窗
/// 关闭时必须 deactivate + invalidate，否则下次释放就是上面那条异常。
///
/// 上述私有调用全部走 `AevonPresenterShim`（ObjC，@try/@catch），异常不会冒到系统。
final class AevonSceneHost {
    let scene: AnyObject
    let sceneID: String
    let bundleID: String

    /// 屏幕尺寸的普通容器；浮窗只对它做等比缩放，不改它的尺寸。
    let container: UIView

    /// 首次检测到画面时回调一次（用于隐藏「等待画面」提示）。
    var onFirstContent: (() -> Void)?

    private(set) var hasContent = false

    private var presenter: AnyObject?
    private let presentationView: UIView
    private var probeTimer: Timer?
    private var ticks = 0
    private var invalidated = false

    /// 用户是否允许浮窗内容接收触摸（设置里的 TouchEnabled）
    private let contentInteractiveByPref: Bool

    /// 开关内容的触摸（V0.0.55，AevonDockNoTouchV55）。
    ///
    /// 用户 Aevon(48) 第 4 条：「快速点击停靠小窗切换到主悬浮窗时，依旧会触发 app 内点击操作」。
    ///
    /// 根因不是 Guard 没吞（SB 侧那条全局通道确实吞掉了自己那一份），
    /// 而是浮窗里的内容本身就是一个**真的场景视图** —— 手指压在它上面时，
    /// UIKit 会把触摸通过 presenter 的 UI 连接转发进 App 进程，App 收到
    /// 「按下 + 抬起」就自己合成了一次点击（抖音于是暂停）。
    ///
    /// 停靠小窗根本不需要和内容交互（它的唯一操作是「轻点还原」），
    /// 所以停靠态直接把内容的触摸关掉，从源头断掉转发。
    func setContentInteraction(_ enabled: Bool) {
        guard contentInteractiveByPref else { return }
        container.isUserInteractionEnabled = enabled
        presentationView.isUserInteractionEnabled = enabled
    }

    // MARK: - 自适应尺寸（V0.0.55，AevonAdaptiveContentV55）

    /// 已经生效的场景尺寸（0 = 还没改成功，仍按整屏处理）
    private(set) var adaptiveContentSize: CGSize = .zero
    private var lastRequestedSize: CGSize = .zero
    private var lastRequestAt: CFTimeInterval = 0

    var isAdaptiveContent: Bool { adaptiveContentSize.width > 1 }

    /// 内容来源尺寸：自适应成功 = 场景尺寸，否则 = 整屏尺寸。
    var sourceSize: CGSize {
        isAdaptiveContent ? adaptiveContentSize : UIScreen.main.bounds.size
    }

    /// 把 App 场景改成窗口内容区大小，让 App 自己重排（Stheno 同款机制）。
    ///
    /// 用户 Aevon(48) 第 2 条：小胖屏比例对了，但内容还是不显示底栏。
    /// 前几版一直是「整屏画面缩放着显示」——按宽度铺满就必然裁掉底部（底栏没了），
    /// 按高度装下就必然左右留黑边（Aevon(45) 已否掉）。两头堵死的根源是：
    /// **画面尺寸压根没变过**。Stheno 的做法（逆向数据：`FBSMutableSceneSettings` +
    /// `setFrame:` + `updateSettings:withTransitionContext:completion:`）是把场景改小，
    /// App 于是真的按这个尺寸排版 —— 底栏、顶栏、右侧工具栏自然全在。
    ///
    /// 只在主窗（非停靠态）请求，且 0.3 秒限频 + 1.5pt 容差，避免拖动时疯狂重排。
    /// - Returns: 当前是否处于自适应状态
    @discardableResult
    func updateAdaptiveSize(_ size: CGSize) -> Bool {
        guard AevonPrefs.bool("AdaptiveContent", default: true) else { return false }
        guard !invalidated, size.width > 40, size.height > 40 else { return false }
        if abs(size.width - lastRequestedSize.width) < 1.5,
           abs(size.height - lastRequestedSize.height) < 1.5 {
            return isAdaptiveContent
        }
        let now = CACurrentMediaTime()
        if now - lastRequestAt < 0.3 { return isAdaptiveContent }
        lastRequestAt = now
        lastRequestedSize = size

        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        let ok = AevonSceneHelper.applyAdaptiveFrame(scene: scene, sceneID: sceneID, size: rounded)
        if ok {
            if !isAdaptiveContent || abs(adaptiveContentSize.width - rounded.width) > 0.5 {
                AevonLog.info("[场景] 内容自适应已生效：场景改为 \(Int(rounded.width))x\(Int(rounded.height))"
                    + "，App 按窗口尺寸重排（顶栏/底栏/右侧工具栏完整，无黑边不裁切）"
                    + "；同时已把窗口尺寸下发给 App 进程，由 Guard 改 keyWindow 让 App 真正重排"
                    + "（AevonAdaptiveContentV55 AevonAdaptiveWindowV56）")
            }
            adaptiveContentSize = rounded
            /* V0.0.56（AevonAdaptiveWindowV56）：把目标尺寸也下发给 App 进程的 Guard。
             *
             * Aevon(50) 第 4 条：只改场景 frame 只裁了**渲染视口**（scene layer 被裁到
             * 267x458），App 的 UIWindow 仍是整屏 430x932 → 内容按整屏排版、
             * 视口只露出左边 62%，于是「字体变大、画面被剪裁、抖音右侧工具栏不显示」。
             * Guard 注入在 App 进程里，读到尺寸就改 keyWindow.frame，App 才会真正重排。 */
            AevonNotifySetWindowSize(Double(rounded.width), Double(rounded.height))
        } else {
            if !isAdaptiveContent {
                AevonLog.info("[场景] 内容自适应未生效（本机场景设置不支持 frame），"
                    + "继续用整屏缩放（AevonAdaptiveContentV55）")
            }
        }
        return ok
    }

    /// 关窗时把场景尺寸还原成整屏，避免这个 App 下次前台打开只有一小块。
    func resetAdaptiveSize() {
        // V0.0.56：无论当前是否自适应，都下发一次「恢复整屏」——
        // 万一 Guard 那边已经改了窗口尺寸而这边状态对不上，也要让它还原。
        AevonNotifySetWindowSize(0, 0)
        guard isAdaptiveContent else { return }
        adaptiveContentSize = .zero
        lastRequestedSize = .zero
        AevonSceneHelper.restoreSceneFrame(scene: scene, sceneID: sceneID)
        AevonLog.info("[场景] 已把 \(bundleID) 的场景尺寸还原为整屏（AevonAdaptiveContentV55）")
    }

    init?(scene: AnyObject, sceneID: String, bundleID: String) {
        // presenter 标识必须唯一：系统的 SpringBoard 自己也在为这个场景建 presenter，
        // 用同一个 id 会撞车。
        let identifier = "Aevon-\(bundleID)-\(UUID().uuidString.prefix(8))"
        // 垫片返回 ObjC id，桥接过来是 Any；统一按 AnyObject 持有
        guard let created = AevonPresenterCreate(scene, identifier) as AnyObject? else {
            AevonLog.warn("[场景] 无法为 \(bundleID) 创建 presenter（uiPresentationManager 不可用）")
            return nil
        }
        let presenter: AnyObject = created
        guard let view = AevonPresenterView(presenter) as? UIView else {
            AevonPresenterDestroy(presenter)
            AevonLog.warn("[场景] presenter 没有 presentationView，放弃承载")
            return nil
        }

        self.scene = scene
        self.sceneID = sceneID
        self.bundleID = bundleID
        self.presenter = presenter
        self.presentationView = view

        let host = UIView(frame: UIScreen.main.bounds)
        host.backgroundColor = .clear
        // V0.0.13：浮窗里的 App 要能直接点。
        // 以前这里硬关掉交互，等于只能看画面。presentationView 的触摸会由 UIKit
        // 通过 presenter 的 UI 连接转发进 App 进程，不需要我们自己造触摸事件。
        // 开关默认开，若怀疑触摸引发异常可在 设置 → Aevon 关掉。
        let interactive = AevonPrefs.bool("TouchEnabled", default: true)
        self.contentInteractiveByPref = interactive
        host.isUserInteractionEnabled = interactive
        host.clipsToBounds = true
        view.frame = host.bounds
        view.autoresizingMask = [UIView.AutoresizingMask.flexibleWidth,
                                 UIView.AutoresizingMask.flexibleHeight]
        view.isUserInteractionEnabled = interactive
        host.addSubview(view)
        self.container = host

        AevonLog.info("[场景] presenter 已激活（presenter=\(AevonRuntime.className(presenter) ?? "?")，视图=\(AevonRuntime.className(view) ?? "?")，场景 \(sceneID)，触摸=\(interactive ? "开" : "关")）")

        // 激活 presenter 之后再把场景推一次前台：只有场景处于前台，App 才会持续渲染。
        AevonSceneHelper.setForeground(scene, true)
    }

    deinit {
        if !invalidated {
            teardownPresenter()
        }
    }

    // MARK: - 首帧探测

    func startSyncing() {
        guard probeTimer == nil, !invalidated else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.probe()
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
        probe()
    }

    private func probe() {
        guard !invalidated else { return }
        ticks += 1

        if !hasContent && contentLooksAlive() {
            hasContent = true
            // 记下呈现视图与首个子视图的实际尺寸：两者比例不一致就说明系统在内部留边
            // （letterbox），那是浮窗缩放怎么调都消不掉的黑边，只能靠场景尺寸解决。
            let outer = presentationView.bounds.size
            let inner = presentationView.subviews.first?.frame.size ?? .zero
            AevonLog.info("[场景] 首帧已到达（第 \(ticks) 次探测，子视图 \(presentationView.subviews.count) 个，"
                + "呈现视图 \(Int(outer.width))x\(Int(outer.height))，"
                + "首个子视图 \(Int(inner.width))x\(Int(inner.height))）")
            onFirstContent?()
        }

        if hasContent {
            if ticks >= 2 { stopProbing() }
            return
        }

        switch ticks {
        case 4:
            logDiagnostics("2 秒")
        case 8:
            logDiagnostics("4 秒")
            // 兜底：再恢复一次进程执行并推前台（suspended 拉起的 App 偶尔会漏恢复）
            if let pid = AevonAppInfo.pid(bundleID: bundleID) {
                AevonAssertionShim.resumePID(Int32(pid))
            }
            AevonSceneHelper.setForeground(scene, true)
        case 16:
            logDiagnostics("8 秒")
            stopProbing()
        default:
            break
        }
    }

    private func stopProbing() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    /// presentationView 里只要有子视图或子图层，就认为画面已经出来了。
    private func contentLooksAlive() -> Bool {
        if !presentationView.subviews.isEmpty { return true }
        if let sublayers = presentationView.layer.sublayers, !sublayers.isEmpty { return true }
        return false
    }

    // MARK: - 诊断

    private func logDiagnostics(_ tag: String) {
        let settings = AevonRuntime.send(scene, Selector(("settings")))
        let foreground = settings.flatMap { AevonRuntime.bool($0, key: "foreground") }
        let active = AevonRuntime.bool(scene, key: "isActive")
        let running = AevonAppInfo.isRunning(bundleID: bundleID)
        let subviews = presentationView.subviews.count
        let sublayers = presentationView.layer.sublayers?.count ?? 0
        AevonLog.warn("[诊断] \(tag)无画面：foreground=\(foreground.map { String($0) } ?? "?")"
            + " isActive=\(active.map { String($0) } ?? "?")"
            + " 进程运行=\(running)"
            + " 呈现视图子视图=\(subviews) 子图层=\(sublayers)"
            + " 视图尺寸=\(Int(presentationView.bounds.width))x\(Int(presentationView.bounds.height))")
    }

    // MARK: - 释放

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        onFirstContent = nil
        teardownPresenter()
        AevonLog.info("[场景] 已释放 presenter（\(bundleID)）")
    }

    private func teardownPresenter() {
        stopProbing()
        hasContent = false

        // 先摘视图，再 deactivate + invalidate（顺序错了会留下悬挂的呈现者）
        presentationView.removeFromSuperview()

        if let presenter = presenter {
            AevonPresenterDestroy(presenter)
            self.presenter = nil
        }
    }
}
