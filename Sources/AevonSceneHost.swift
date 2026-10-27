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
///     → modifyPresentationContext:               appearanceStyle = 2（只要内容）+
///                                                resizesHostedContext = YES
///                                                （V0.2.25，App 场景随浮窗尺寸原生重排，
///                                                 PullOver-X 呈现上下文同款）
///     → activate                                  这一步才会让 App 真正开始渲染
///     → presentationView                          把这张视图塞进浮窗
/// 关闭时必须 deactivate + invalidate，否则下次释放就是上面那条异常。
///
/// 上述私有调用全部走 `AevonPresenterShim`（ObjC，@try/@catch），异常不会冒到系统。
final class AevonSceneHost {
    let scene: AnyObject
    let sceneID: String
    let bundleID: String
    /// V0.2.28（AevonSelfSceneV228）：true = 自建场景（P1 自建场景路线）。
    /// 自建场景上 settings 写入是受支持通路（画布可改 = 真重排），关闭时要 destroyScene。
    let isSelfBuilt: Bool

    /// V0.2.42（AevonMainSceneResizeV242）：true = 走 S2（主场景改画布）。
    /// 主场景是系统自己的场景，画布改动可能被 FrontBoard 回弹，关闭时必须还原
    /// 到全屏尺寸（否则 App 之后全屏打开只有浮窗那么大）。
    let mainResized: Bool

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
    /// V0.2.32（AevonForegroundProbeV232）：假首帧只记一次，避免刷屏
    private var fakeAliveLogged = false

    init?(scene: AnyObject, sceneID: String, bundleID: String,
          isSelfBuilt: Bool = false, mainResized: Bool = false) {
        self.isSelfBuilt = isSelfBuilt
        self.mainResized = mainResized
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
        // V0.2.17（AevonFloatTouchAlwaysV217）：原先那个「浮窗内可触摸」开关撤掉了 ——
        // 关掉它等于把浮窗变成一张截图，没有第二种用法；这里恒为开。
        let interactive = true   // AevonFloatTouchAlwaysV217
        host.isUserInteractionEnabled = interactive
        host.clipsToBounds = true
        view.frame = host.bounds
        view.autoresizingMask = [UIView.AutoresizingMask.flexibleWidth,
                                 UIView.AutoresizingMask.flexibleHeight]
        view.isUserInteractionEnabled = interactive
        host.addSubview(view)
        self.container = host

        AevonLog.info("[场景] presenter 已激活（presenter=\(AevonRuntime.className(presenter) ?? "?")，视图=\(AevonRuntime.className(view) ?? "?")，场景 \(sceneID)，触摸=\(interactive ? "开" : "关")\(isSelfBuilt ? "，自建场景（AevonSelfSceneV228）" : "")）")

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

        if !hasContent && contentLooksAlive() && !contentReallyAlive() && !fakeAliveLogged {
            fakeAliveLogged = true
            let probe = isSelfBuilt ? (AevonSelfSceneDebugState(scene) as String) : "-"
            AevonLog.warn("[场景] 表面结构就绪但 App 内容未渲染（结构性假首帧，继续探测取证）：\(probe)（AevonForegroundProbeV232）")
        }

        if !hasContent && contentLooksAlive() && contentReallyAlive() {
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

    /// V0.2.32（AevonForegroundProbeV232，0.2.31 真机实锤）：结构性子视图创建即存在
    /// （抖音 4ms 就「首帧已到达」是假首帧——远程表面容器 ≠ App 真画了），
    /// 自建场景必须再过 round8 判据：contentState==2 或 layerManager.layers>0。
    /// 主场景承载（0.2.27 全屏接管形态）保持原判定不变。
    private func contentReallyAlive() -> Bool {
        guard isSelfBuilt else { return true }
        return AevonSelfSceneContentAlive(scene)
    }

    // MARK: - 诊断

    private func logDiagnostics(_ tag: String) {
        let settings = AevonRuntime.send(scene, Selector(("settings")))
        let foreground = settings.flatMap { AevonRuntime.bool($0, key: "foreground") }
        let active = AevonRuntime.bool(scene, key: "isActive")
        let running = AevonAppInfo.isRunning(bundleID: bundleID)
        let subviews = presentationView.subviews.count
        let sublayers = presentationView.layer.sublayers?.count ?? 0
        // V0.2.32（AevonForegroundProbeV232）：自建场景加只读取证串
        // （fg/cs/layers/dr/idle，round8 判据全上），下轮日志直接判断黑在哪一层。
        let probe = isSelfBuilt ? " " + (AevonSelfSceneDebugState(scene) as String) : ""
        AevonLog.warn("[诊断] \(tag)无画面：foreground=\(foreground.map { String($0) } ?? "?")"
            + " isActive=\(active.map { String($0) } ?? "?")"
            + " 进程运行=\(running)"
            + " 呈现视图子视图=\(subviews) 子图层=\(sublayers)"
            + " 视图尺寸=\(Int(presentationView.bounds.width))x\(Int(presentationView.bounds.height))\(probe)")
    }

    // MARK: - 释放

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        onFirstContent = nil
        // V0.2.42（AevonMainSceneResizeV242）：S2 必须还原主场景画布 ——
        // 否则关窗后 App 再被全屏打开只有浮窗那么大（系统不会替我们改回来）。
        if mainResized {
            let screen = UIScreen.main.bounds.size
            let ok = AevonMainSceneSetFrame(scene, Double(screen.width), Double(screen.height))
            AevonLog.info("[场景] 主场景画布已还原 \(Int(screen.width))x\(Int(screen.height))"
                + "（\(ok ? "已提交" : "失败")，读回 \(AevonMainSceneFrameState(scene) ?? "")）（AevonMainSceneResizeV242）")
        }
        teardownPresenter()
        // V0.2.28（AevonSelfSceneV228）：自建场景必须 destroyScene 收尾，
        // 否则 respring 后 FBSceneManager 里残留同名场景（创建前会先销毁遗留，但别依赖它）。
        if isSelfBuilt {
            let destroyed = AevonSelfSceneDestroy(scene)
            AevonLog.info("[场景] 自建场景已销毁（\(destroyed ? "成功" : "失败")）（AevonSelfSceneV228）")
        }
        AevonLog.info("[场景] 已释放 presenter（\(bundleID)）")
    }

    /// V0.2.28（AevonSelfSceneV228）：改自建场景画布 = 真重排
    /// （updateSettingsWithBlock 内 frame = 0,0,w×h，App 随之重新布局）。
    /// 仅 isSelfBuilt 时有效；调用时机 = 缩放抬手提交真实 frame 后（一次一调，天然单飞）。
    /// V0.2.42（AevonMainSceneResizeV242）：S2（主场景改画布）走同一条路 ——
    /// 只写 frame，不写前台状态。
    func resizeCanvasTo(width: CGFloat, height: CGFloat) {
        guard !invalidated else { return }
        if isSelfBuilt {
            let ok = AevonSelfSceneResize(scene, Double(width), Double(height))
            AevonLog.info("[场景] 画布已改 \(Int(width))x\(Int(height))（\(ok ? "已提交" : "失败")）（AevonSelfSceneV228）")
        } else if mainResized {
            let ok = AevonMainSceneSetFrame(scene, Double(width), Double(height))
            AevonLog.info("[场景] 主场景画布已改 \(Int(width))x\(Int(height))（\(ok ? "已提交" : "失败")，"
                + "读回 \(AevonMainSceneFrameState(scene) ?? "")）（AevonMainSceneResizeV242）")
        }
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
