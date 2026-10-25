import UIKit
import QuartzCore

/// V0.1.5（AevonSystemGestureV105）：把「右缘左滑呼圆盘」交给 SpringBoard 的**系统手势管线**。
///
/// 为什么 0.1.0~0.1.4 都治不好「抖音跟着动」：
///   前台 App 的触摸由 backboardd 直投 App 进程，我们在 SpringBoard 侧
///   `UIApplication -sendEvent:` 里丢事件只影响「我们这一份」，App 那份照旧 ——
///   于是圆盘展开的同时，抖音的进度条 / 翻页也在一起走。0.1.4 试图找
///   `_UISystemGestureWindow` 挂识别器，结果归档(14) 日志把 SB 的窗口全列了一遍：
///   `SBStatusBarWindow / SBHomeScreenWindow / SBWindow / SBCoverSheetWindow /
///   SBControlCenterWindow / SBMainSwitcherWindow / SBSystemApertureWindow / …`
///   —— **根本没有 SystemGesture 窗口**，那条路从前提上就不成立。
///
/// 真正的机制（本轮实证，来自同仓库另一件真机插件 ScreenCore 的逆向资料
/// `analysis/screencore/classdump_ScreenCore.txt` + `strings_ScreenCore.txt`）：
///   系统手势由 `SBMainDisplaySystemGestureManager` 统一登记，调用
///   ```
///   -addGestureRecognizer:toDisplayWithIdentity:
///   ```
///   （ScreenCore 的 `SCArcGestureCoordinator` 里就是这两个名字：
///    ivar `_systemGestureManager` / `_systemDisplayIdentity` /
///    `_usesSystemGesturePipeline`，方法 `-sc_registerSystemGestureRecognizer:`）。
///   一旦识别器进了这条管线，触摸在**落下那一刻**就归 SpringBoard 的识别环境，
///   App 那一份被延后 / 取消 —— 这才是「控制中心下拉、底部上滑在全屏 App 上
///   一样生效而 App 毫无反应」的原因。
///
/// 本版做法（最小、可一键关）：
///   1. 在入口容器最上层放一条**全屏透明带视图**（`AevonGestureBandView`），
///      只有「右缘 20pt、App 前台、不在热区、不在浮窗上」时才参与命中测试；
///   2. 在这条带上挂一个 `UIPanGestureRecognizer`，只认「向左横扫」；
///   3. 把它登记进系统手势管线（`addGestureRecognizer:toDisplayWithIdentity:`）。
///
/// 兜底（任何一步失败都不影响开机与正常使用）：
///   · 管线登记失败 → 只记日志，右缘仍走 0.1.3 的「延迟接管」老通道（功能不丢）；
///   · 设置里关掉「右侧边缘左滑呼出圆盘」→ 整条带立刻失效（命中测试直接返回 false）。
///
/// 代价（必然取舍，别当 bug）：进了系统手势管线的这根手指，App 那边收不到，
/// 所以带内（最外侧 20pt）的轻点也不会传给 App。抖音的点赞 / 评论按钮图标中心在 30pt 开外，
/// 正常点击仍有效，只有贴边缘那一条细缝点不到。
final class AevonGestureBandView: UIView {
    /// 右缘带宽度（pt）。宁可窄：带越宽，带内点不到的东西越多。
    static let bandWidth: CGFloat = 20

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return AevonSystemGestureV105.shared.acceptsTouch(at: point)
    }

    override func hitTest(_ screenPoint: CGPoint, with event: UIEvent?) -> UIView? {
        return point(inside: screenPoint, with: event) ? self : nil
    }
}

final class AevonSystemGestureV105: NSObject, UIGestureRecognizerDelegate {
    static let shared = AevonSystemGestureV105()

    private var recognizer: UIPanGestureRecognizer?
    private weak var bandView: AevonGestureBandView?
    /// 是否已成功登记进系统手势管线（只有它为真，右缘才真的「App 收不到」）
    private var pipelineRegistered = false
    /// 当前归本通道的那根手指（`AevonTouchHook.m` 上报的 touchID 就是 UITouch 指针）
    private var touchPointer: UInt = 0
    private var pendingPointer: UInt = 0
    private var pointerDeadline: CFTimeInterval = 0
    private var lastLogAt: CFTimeInterval = 0
    private var installedLogged = false
    /// V0.1.8：识别器在触摸流里被问过多少次（`shouldReceiveTouch` 次数）。
    /// 只要它真的挂进了系统手势环境，右缘落下时这里必然 > 0。
    private var pipelineTouchCount = 0
    /// V0.1.8：反证计数 —— 全局通道在右缘看到触摸，但识别器一次都没被问过。
    private var pipelineMissCount = 0
    /// V0.1.8：被「判据」拒收时的限频日志时间戳（区分「没进触摸流」与「进了但被我们拒」）。
    private var rejectLogAt: CFTimeInterval = 0

    /// 通道是否在生效（带视图已挂上 + 开关打开）。
    static var isInstalled: Bool {
        let channel = shared
        return channel.bandView != nil && AevonPrefs.bool("EdgeGestureEnabled", default: true)
    }

    /// 系统手势管线是否已经接管右缘。全局 sendEvent 通道据此让路，
    /// 避免同一根手指被「管线」和「延迟接管」各算一次。
    static var ownsBand: Bool {
        let channel = shared
        return channel.bandView != nil && channel.pipelineRegistered
            && AevonPrefs.bool("EdgeGestureEnabled", default: true)
    }

    /// 这根触摸是否已经归系统手势管线。
    static func isHandling(touchID: UInt) -> Bool {
        let channel = shared
        guard ownsBand else { return false }
        guard channel.touchPointer != 0, channel.touchPointer == touchID else { return false }
        guard CACurrentMediaTime() <= channel.pointerDeadline else { return false }
        return true
    }

    // MARK: - 安装

    /// 装带视图 + 识别器 + 管线登记。入口容器还没就绪时自动重试（最多 12 秒）。
    func install(attempt: Int = 0) {
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        guard AevonPrefs.bool("EdgeGestureEnabled", default: true) else {
            AevonLog.info("[手势] 右侧边缘呼出已关闭，不安装系统手势管线（AevonSystemGestureV105）")
            return
        }
        if bandView != nil { return }

        let band = AevonGestureBandView(frame: .zero)
        band.backgroundColor = .clear
        band.isOpaque = false
        guard AevonEntryHost.attachOverlay(band) else {
            if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.install(attempt: attempt + 1)
                }
            } else {
                AevonLog.warn("[手势] 入口容器始终未就绪，右缘保持 0.1.3 老通道（AevonSystemGestureV105）")
            }
            return
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        band.addGestureRecognizer(pan)

        bandView = band
        recognizer = pan
        pipelineRegistered = AevonSystemGestureV105.registerWithSystemGesturePipeline(pan)

        if installedLogged { return }
        installedLogged = true
        if pipelineRegistered {
            AevonLog.info("[手势] 已登记进系统手势管线（带=右缘 \(Int(AevonGestureBandView.bandWidth))pt × 全屏高，只认向左横扫；App 收不到这条触摸）（AevonSystemGestureV105 AevonSystemGestureV106）")
        } else {
            AevonLog.warn("[手势] 系统手势管线登记失败（已知类名与工厂名都不匹配，不代表管线不存在；真实类名见下方 [探针] 行），右缘继续走 0.1.3 延迟接管老通道（AevonSystemGestureV105 AevonSystemGestureV106 AevonBandDeferV103）")
        }
    }

    /// 把识别器登记进 SpringBoard 的系统手势管线。
    ///
    /// V0.1.8（AevonSystemGestureV108）—— 真名由真机探针给出，不再靠猜：
    ///   Aevon(75) 日志 P1 行把三个管理器一次列清：
    ///     _UISystemGestureManager.sharedInstance          → [two:1 one:0 acq:0]
    ///     SBMainDisplaySystemGestureManager.sharedInstance→ [two:0 one:0 acq:1]
    ///     SBSystemGestureManager.mainDisplayManager       → [two:0 one:0 acq:1]
    ///   也就是：**SpringBoard 自己那两个管理器都不支持两参登记**，唯一支持
    ///   `addGestureRecognizer:toDisplayWithIdentity:` 的是 UIKit 私有的
    ///   `_UISystemGestureManager`。0.1.5~0.1.7 三版都在 SB 的那两个类上找方法，
    ///   所以每版都稳稳地打「登记失败」—— 不是管线不存在，是敲错了门。
    ///   Stheno（ScreenCore）用的正是这个类：strings 里
    ///   `_UISystemGestureManager` / `displayIdentity` /
    ///   `addGestureRecognizer:toDisplayWithIdentity:` /
    ///   `removeGestureRecognizer:fromDisplayWithIdentity:` 四条紧挨在一起。
    ///
    /// displayIdentity 首选 `FBDisplayManager.mainConfiguration.identity`，
    /// 取不到再退到 `UIWindowScene.displayIdentity`（ScreenCore 走的就是窗口场景这条路）。
    /// 全部按「存在性检查 → 调用 → 失败静默」处理，取不到就返回 false，绝不硬赌。
    private static func registerWithSystemGesturePipeline(_ recognizer: UIGestureRecognizer) -> Bool {
        let identity = mainDisplayIdentity()
        if identity == nil {
            AevonLog.warn("[手势] 取不到主屏 displayIdentity（FBDisplayManager.mainConfiguration 路径不通），只能试单参重载（AevonSystemGestureV106）")
        }
        // 顺序即优先级：`_UISystemGestureManager` 实测支持两参登记（two:1），排第一；
        // SB 的两个管理器留在后面只作兜底（它们可能支持 acquire 系列的别的登记口）。
        var managers: [AnyObject] = []
        for className in ["_UISystemGestureManager", "SBMainDisplaySystemGestureManager", "SBSystemGestureManager"] {
            for factory in ["sharedInstance", "mainDisplayManager", "sharedManager"] {
                if let manager = AevonRuntime.sendClass(className, Selector((factory))),
                   !managers.contains(where: { $0 === manager }) {
                    managers.append(manager)
                }
            }
        }
        // V0.1.6（AevonSystemGestureV106）：硬编码类名全落空时**不再断言「不存在」**。
        // 系统手势（控制中心、底部上滑）在真机上一直好使，说明这条管线必然在本进程里活着，
        // 只是 iOS 17 的类名/工厂名和我们记忆里的不一样。交给探针按类表 + ivar 去挖。
        if managers.isEmpty {
            let scanned = AevonProbeV107.resolveManagers()
            AevonLog.info("[手势] 硬编码类名取不到管理器，类表扫描得 \(scanned.count) 个候选（AevonSystemGestureV106 AevonObjCProbeV107）")
            managers = scanned
        }
        for manager in managers {
            let twoArg = Selector(("addGestureRecognizer:toDisplayWithIdentity:"))
            if let identity = identity, manager.responds(to: twoArg) {
                callVoid(manager, twoArg, first: recognizer, second: identity)
                AevonLog.info("[手势] 已向 \(AevonRuntime.className(manager) ?? "?") 登记识别器（带 displayIdentity）（AevonSystemGestureV106）")
                AevonLog.info("[手势] 系统手势管线登记成功：\(AevonRuntime.className(manager) ?? "?") × \(AevonRuntime.className(identity) ?? "?")（AevonSystemGestureV108）")
                return true
            }
            let oneArg = Selector(("addGestureRecognizer:"))
            if manager.responds(to: oneArg) {
                callVoid(manager, oneArg, first: recognizer, second: nil)
                AevonLog.info("[手势] 已向 \(AevonRuntime.className(manager) ?? "?") 登记识别器（无 displayIdentity 重载）（AevonSystemGestureV106）")
                return true
            }
        }
        return false
    }

    /// 按 **void 返回** 调用一个 1~2 参数的方法。
    ///
    /// 为什么不直接用 `performSelector`：这两个登记方法在私有头文件里的返回类型
    /// 不确定（可能 void 也可能 BOOL）。`performSelector` 会把返回值当对象指针接管，
    /// 一旦实际是 BOOL/void，拿到的就是寄存器里的垃圾地址，retain 时直接崩。
    /// 这里按 void 取实现，返回值一律丢弃 —— 与真实签名不符也不会出错。
    private static func callVoid(_ target: AnyObject,
                                 _ selector: Selector,
                                 first: AnyObject,
                                 second: AnyObject?) {
        guard let object = target as? NSObject, object.responds(to: selector) else { return }
        guard let method = class_getInstanceMethod(object_getClass(target), selector) else { return }
        if let second = second {
            typealias Fn2 = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
            let fn = unsafeBitCast(method_getImplementation(method), to: Fn2.self)
            fn(target, selector, first, second)
        } else {
            typealias Fn1 = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            let fn = unsafeBitCast(method_getImplementation(method), to: Fn1.self)
            fn(target, selector, first)
        }
    }

    /// 主屏 displayIdentity。
    ///
    /// 首选 FrontBoard 的 `FBDisplayManager.sharedInstance.mainConfiguration.identity`
    /// （Aevon(75) 日志里这条没报「取不到」，说明 17.3.1 上通）；
    /// 取不到再按 ScreenCore 的路子退到窗口场景的 `displayIdentity`，
    /// 最后退到 `UIScreen._displayIdentity`。三条都是对象 getter，可安全用 perform。
    private static func mainDisplayIdentity() -> AnyObject? {
        if let manager = AevonRuntime.sendClass("FBDisplayManager", Selector(("sharedInstance"))),
           let configuration = AevonRuntime.send(manager, Selector(("mainConfiguration"))),
           let identity = AevonRuntime.send(configuration, Selector(("identity"))) {
            return identity
        }
        // 兜底一：ScreenCore 用的就是窗口场景上的 displayIdentity
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for name in ["displayIdentity", "_displayIdentity"] {
                if let identity = AevonRuntime.send(windowScene, Selector((name))) {
                    return identity
                }
            }
            if let screen = AevonRuntime.send(windowScene, Selector(("screen"))),
               let identity = AevonRuntime.send(screen, Selector(("_displayIdentity"))) {
                return identity
            }
        }
        // 兜底二：主屏自己的私有 identity
        if let identity = AevonRuntime.send(UIScreen.main, Selector(("_displayIdentity"))) {
            return identity
        }
        return nil
    }

    // MARK: - 命中条件

    /// 带视图的 `pointInside` 判据：只有这一小块参与命中测试，其余全屏放行。
    func acceptsTouch(at point: CGPoint) -> Bool {
        guard AevonPrefs.bool("Enabled", default: false),
              AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return false }
        // 只在全屏 App 前台时接管：桌面有自己的热区语义，不能被这条带盖住右侧图标
        guard AevonEntryHost.mountedInAppScene else { return false }
        // 圆盘已经开着：后续触摸归圆盘自己的通道
        guard AevonRingMenu.presented == nil else { return false }

        let screen = UIScreen.main.bounds
        guard point.x >= screen.width - AevonGestureBandView.bandWidth else { return false }
        // 底部热区是老入口，优先级更高（按住即接管 + 左滑呼出都在那儿）
        guard !AevonTriggerZone.rect(in: screen).contains(point) else { return false }
        // 浮窗（含外侧手柄）压住的地方交给浮窗，否则贴边浮窗拖不动
        guard !AevonEntryHost.pointHitsFloatingWindow(at: point) else { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // V0.1.8：先计数再判条件 —— 我们要的证据是「识别器有没有进触摸流」，
        // 而不是「这一次它有没有同意接收」。两个问题不能混为一个。
        pipelineTouchCount += 1
        let point = touch.location(in: nil)
        guard acceptsTouch(at: point) else {
            // 进了触摸流却被我们自己的判据拒 —— 与「根本没进触摸流」是两件事，
            // 日志里必须能分开，否则下一轮又只能猜。
            let now = CACurrentMediaTime()
            if now - rejectLogAt > 2.0 {
                rejectLogAt = now
                AevonLog.info("[手势] 识别器已收到触摸但判据拒收 (x=\(Int(point.x)), y=\(Int(point.y))，App前台=\(AevonEntryHost.mountedInAppScene)，圆盘开着=\(AevonRingMenu.presented != nil))（AevonSystemGestureV108）")
            }
            return false
        }
        touchPointer = 0
        pendingPointer = UInt(bitPattern: Unmanaged.passUnretained(touch).toOpaque())
        pointerDeadline = CACurrentMediaTime() + 12
        let now = CACurrentMediaTime()
        if now - lastLogAt > 1.5 {
            lastLogAt = now
            AevonLog.info("[手势] 系统手势管线拿到右缘触摸 (x=\(Int(point.x)), y=\(Int(point.y)))（AevonSystemGestureV105）")
        }
        return true
    }

    /// 只认向左横扫：上下滑（刷抖音信息流）与轻点都在这一步直接失败。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 没进系统手势管线时这条带只做「视图层观察」，不参与呼出 ——
        // 否则会和 0.1.3 的延迟接管老通道各呼一次圆盘。
        guard pipelineRegistered else { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let translation = pan.translation(in: nil)
        guard translation.x < 0, abs(translation.x) > abs(translation.y) else { return false }
        return true
    }

    /// 与系统其他手势共存：右缘手势不与系统手势互相排斥（否则容易把便捷访问 / 多任务手势挤掉）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    // MARK: - 管线有效性反证（V0.1.8）

    /// 全局通道在右缘看到了一次触摸。
    ///
    /// 若此时识别器从没被 `shouldReceiveTouch` 问过，说明它「登记成功了，却没进触摸流」——
    /// 系统手势环境不认这个识别器。反证两次就自动降级到 0.1.3 的延迟接管老通道：
    /// 宁可回到旧行为（圆盘照常呼出、抖音仍会跟动），也不能让右缘呼出变成哑巴。
    /// 这条判据只在「识别器一次都没被问过」时成立，所以系统手势真生效时不会误降级。
    func noteBandTouchSeenByGlobalChannel(at point: CGPoint) {
        guard pipelineRegistered, pipelineTouchCount == 0 else { return }
        pipelineMissCount += 1
        if pipelineMissCount == 1 || pipelineMissCount % 5 == 0 {
            AevonLog.warn("[手势] 管线已登记但右缘触摸没进识别器 (x=\(Int(point.x)), y=\(Int(point.y))，反证 \(pipelineMissCount) 次)（AevonSystemGestureV108）")
        }
        if pipelineMissCount >= 2 {
            pipelineRegistered = false
            AevonLog.warn("[手势] 系统手势管线登记成功却拿不到触摸，已回退 0.1.3 延迟接管（圆盘仍可呼出；抖音跟手本版未解决）（AevonSystemGestureV108 AevonBandDeferV103）")
        }
    }

    // MARK: - 手势分发

    @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: nil)
        switch gesture.state {
        case .began:
            touchPointer = pendingPointer
            pointerDeadline = CACurrentMediaTime() + 12
            AevonEdgeEntry.triggerFromSystemGesture(point: point)
        case .changed:
            AevonRingMenu.presented?.remoteMoved(to: point, source: "systemgesture")
        case .ended:
            AevonRingMenu.presented?.remoteEnded(at: point, source: "systemgesture")
            touchPointer = 0
            pendingPointer = 0
        case .cancelled, .failed:
            AevonRingMenu.presented?.remoteCancelled(source: "systemgesture")
            touchPointer = 0
            pendingPointer = 0
        default:
            break
        }
    }
}
