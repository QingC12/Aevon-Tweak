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

    // MARK: - 真 resize（V0.0.59，AevonTrueResizeV59）

    /// V0.0.57 曾把这条路线整条停用（只改 frame = 只裁渲染视口）。
    /// V0.0.59 按 Mango 实证补齐 displayConfiguration + `setResizesHostedContext:`
    /// 三路杠杆重开 —— 且加了**探测自证**：场景写完之后，呈现视图里 App 的实际
    /// 画布尺寸若没有跟着变成目标尺寸（App 真的重排了），5 秒内自动回退到
    /// 整屏等比缩放（V58 形态），最坏情况 = 上一版行为，绝不会更糟。
    ///
    /// 「场景已按我们的请求改小」的目标尺寸（App 应当按它排版）。
    private(set) var adaptiveContentSize: CGSize = .zero

    /// 探测确认：App 的画布真的变成了 adaptiveContentSize（重排成功）。
    private(set) var contentReflowConfirmed = false

    var isAdaptiveContent: Bool { adaptiveContentSize != .zero && contentReflowConfirmed }

    /// 内容来源尺寸：确认重排后 = 场景逻辑尺寸（scale=1 原生显示）；
    /// 未确认 / 回退 = 整屏（V58 等比缩放路径）。
    var sourceSize: CGSize {
        if isAdaptiveContent { return adaptiveContentSize }
        return UIScreen.main.bounds.size
    }

    /// 请求场景按指定逻辑尺寸重排。bits=0 表示垫片层完全失败。
    func updateAdaptiveSize(_ size: CGSize, reason: String) {
        guard size.width > 1, size.height > 1 else { return }
        let bits = AevonSceneHelper.applyDisplaySize(scene: scene, sceneID: sceneID,
                                                     size: size, floatMode: true)
        if bits == 0 {
            AevonLog.warn("[场景] 真重排请求被垫片拒绝（\(reason)，AevonTrueResizeV59）")
            return
        }
        // V0.0.60（AevonReflowGateV60）硬闸门：displayConfiguration 没写进
        // settings（0x10 未置位）= App 进程拿不到小窗显示配置，**绝不会重排**。
        // 垫片此时也已整单放弃（没写 frame、没推 diff），场景保持整屏 ——
        // 这里直接回退 V58 整屏等比缩放，绝不进入 1:1 分支。
        // （V0.0.59 的「内容放大 + 显示不全」= 探测假阳性 + 只推 frame 的组合：
        //   presentationView 首子视图是我们自己的承载容器，永远等于目标尺寸，
        //   第 1 次探测就假确认，于是 1:1 分支吃到了 430x932 的整屏画面。）
        guard bits & 0x10 != 0 else {
            adaptiveContentSize = .zero
            contentReflowConfirmed = false
            reflowChecking = false
            AevonLog.warn("[场景] displayConfiguration 未能写入场景（\(reason)，"
                + "\(AevonSceneHelper.describeApplyBits(bits, target: size))，"
                + "诊断 \(AevonSceneHelper.displayConfigDiag())）"
                + "—— 场景保持整屏，回退整屏等比缩放（AevonTrueResizeV60）")
            onReflowChanged?()
            return
        }
        adaptiveContentSize = size
        contentReflowConfirmed = false
        reflowCheckTicks = 0
        reflowCheckTarget = size
        reflowChecking = true
        // 探测定时器可能早已停止（首帧确认后就停了）：重启它，确认/回退后自然再停。
        startSyncing()
        AevonLog.info("[场景] 真重排请求已下发（\(AevonSceneHelper.describeApplyBits(bits, target: size))"
            + "，\(reason)，等探测确认，AevonTrueResizeV59）")
        // V0.0.64：首次下发时带出 scene 方法表诊断（找 setResizesHostedContext: 的
        // 正确调用对象 —— Stheno 实锤该选择子存在，但我们手里的 FBScene 不响应）。
        if bits & 0x20 == 0 {
            AevonLog.warn("[场景] 托管上下文开关未被 scene 接受（\(AevonSceneHelper.sceneMethodDiag())"
                + "，AevonReflowAppGateV64）")
        }
    }

    /// 关窗 / 还原：场景恢复整屏（帧+显示配置一起还原）。
    func resetAdaptiveSize() {
        guard adaptiveContentSize != .zero || AevonSceneHelper.adaptiveFrame(for: sceneID) != nil else {
            AevonNotifySetWindowSize(0, 0)
            return
        }
        adaptiveContentSize = .zero
        contentReflowConfirmed = false
        reflowChecking = false
        AevonSceneHelper.restoreSceneFrame(scene: scene, sceneID: sceneID)
        AevonNotifySetWindowSize(0, 0)
    }

    /// 探测状态（probe 每 0.5s 一次）
    private var reflowChecking = false
    private var reflowCheckTicks = 0
    private var reflowCheckTarget: CGSize = .zero

    /// probe 里调用：确认 App 画布是否真的变成了目标尺寸。
    /// 确认 → contentReflowConfirmed = true（内容管线切 1:1 原生）；
    /// 10 次探测（5 秒）仍未确认 → 自动回退整屏等比缩放（V58 形态）。
    ///
    /// V0.0.64（AevonReflowAppGateV64）终审结论：**SB 侧没有任何信号能证明
    /// App 进程真的重排了。** presentationView 的子树 frame 全部由系统按我们
    /// 写入的 settings 直接设置（恒等于目标）——V59/V60 的「首子视图 ≈ 目标 +
    /// 无超尺寸视图」两道检查都是假阳性；V63 dc ivar 直写成功 + diff 下发 +
    /// 回读一致，App 进程照样没重排（画面放大 = 整屏画面被 1:1 塞进小窗）。
    /// 远程场景事后改 dc 只影响 SB 侧布局（Stheno/TrollOpen/Mango 三家逆向
    /// 交叉印证：真重排必须 App 进程内动手）。
    /// 所以：确认门 = **App 进程证据**（本版证据源尚未建立，开关恒关），
    /// 关着的时候内容恒走整屏等比缩放（V58 形态）——绝不再放大。
    private static let appProcessConfirmEnabled =
        AevonPrefs.bool("AppProcessReflowConfirm", default: false)

    /// 画布证据（每轮探测第 1 次采样，落日志供下一版判断）。
    private var evidenceLogged = false

    private func checkReflow() {
        guard reflowChecking, adaptiveContentSize != .zero else { return }
        reflowCheckTicks += 1
        let inner = presentationView.subviews.first?.frame.size ?? .zero
        let target = reflowCheckTarget
        // 证据采样（不参与判定）：子树里超过目标一圈的视图 = App 仍按整屏渲染的
        // 残留痕迹（如果 App 真重排了，这类视图应消失）。只在第 1 次落日志。
        var oversizedDesc = "无"
        var queue = presentationView.subviews
        var visited = 0
        while visited < 64, let view = queue.popLast() {
            visited += 1
            if view.frame.width > target.width + 20 || view.frame.height > target.height + 20 {
                oversizedDesc = "\(AevonRuntime.className(view) ?? "?") \(Int(view.frame.width))x\(Int(view.frame.height))"
                break
            }
            queue.append(contentsOf: view.subviews)
        }
        if !evidenceLogged {
            evidenceLogged = true
            AevonLog.info("[场景] 画布证据收集：首子=\(presentationView.subviews.first.map { AevonRuntime.className($0) } ?? "?")"
                + " \(Int(inner.width))x\(Int(inner.height))，超尺寸视图=\(oversizedDesc)"
                + "（SB 侧信号不作为确认依据，AevonReflowAppGateV64）")
        }
        let innerOK = inner.width > 1 && abs(inner.width - target.width) <= 2
            && abs(inner.height - target.height) <= 2
        // 确认门：只有 App 进程证据通道建立（开关打开）时才允许确认。
        // 本版恒关 —— innerOK 只说明系统把 SB 侧 frame 设成了目标，不代表
        // App 进程重排（V59/V60/V63 三版真机实证），绝不据此切 1:1。
        if innerOK && Self.appProcessConfirmEnabled {
            contentReflowConfirmed = true
            reflowChecking = false
            AevonLog.info("[场景] App 已按小窗尺寸重新排版（画布 \(Int(inner.width))"
                + "x\(Int(inner.height)) ≈ 目标 \(Int(target.width))x\(Int(target.height))"
                + "，顶栏/底栏/右侧工具栏原生在场，内容 1:1 显示）（AevonReflowCheckV59）")
            onReflowChanged?()
            return
        }
        if reflowCheckTicks >= 10 {
            reflowChecking = false
            adaptiveContentSize = .zero
            contentReflowConfirmed = false
            AevonLog.warn("[场景] 5 秒内未确认 App 重排（画布 \(Int(inner.width))x\(Int(inner.height))"
                + " ≠ 目标 \(Int(target.width))x\(Int(target.height))），自动回退整屏等比缩放"
                + "（场景拒绝真 resize：帧+显示配置+托管开关三路都未让 App 重排）（AevonReflowCheckV59）")
            onReflowChanged?()
        }
    }

    /// 重排状态翻转时回调（窗口视图据此重算内容管线）。
    var onReflowChanged: (() -> Void)?

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

        // V0.0.59（AevonReflowCheckV59）：真重排确认走这里 —— 每 0.5s 看一眼
        // App 的画布有没有真的变成目标尺寸，确认或超时回退都会翻转状态。
        checkReflow()

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
            // V0.0.59：重排确认期内不能停探测（确认/回退后这里自然变 false）
            if reflowChecking { return }
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
        onReflowChanged = nil
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
