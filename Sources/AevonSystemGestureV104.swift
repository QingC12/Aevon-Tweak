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

    override func pointInside(_ point: CGPoint, withEvent event: UIEvent?) -> Bool {
        return AevonSystemGestureV105.shared.acceptsTouch(at: point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return pointInside(point, withEvent: event) ? self : nil
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
            AevonLog.info("[手势] 已登记进系统手势管线（带=右缘 \(Int(AevonGestureBandView.bandWidth))pt × 全屏高，只认向左横扫；App 收不到这条触摸）（AevonSystemGestureV105）")
        } else {
            AevonLog.warn("[手势] 系统手势管线登记失败（管理器/方法不存在），右缘继续走 0.1.3 延迟接管老通道（AevonSystemGestureV105 AevonBandDeferV103）")
        }
    }

    /// 把识别器登记进 SpringBoard 的系统手势管线。
    ///
    /// 依据（同仓库 ScreenCore 逆向资料，真机可用）：
    ///   `SBMainDisplaySystemGestureManager -addGestureRecognizer:toDisplayWithIdentity:`
    ///   displayIdentity 取 `FBDisplayManager.sharedInstance.mainConfiguration.identity`。
    /// 全部按「存在性检查 → 调用 → 失败静默」处理，取不到就返回 false，绝不硬赌。
    private static func registerWithSystemGesturePipeline(_ recognizer: UIGestureRecognizer) -> Bool {
        let identity = mainDisplayIdentity()
        // 不同系统版本上取管理器的类方法名不一样（sharedInstance / mainDisplayManager / …），
        // 逐个试，全部取不到才放弃。
        var managers: [AnyObject] = []
        for className in ["SBMainDisplaySystemGestureManager", "SBSystemGestureManager"] {
            for factory in ["sharedInstance", "mainDisplayManager", "sharedManager"] {
                if let manager = AevonRuntime.sendClass(className, Selector((factory))),
                   !managers.contains(where: { $0 === manager }) {
                    managers.append(manager)
                }
            }
        }
        for manager in managers {
            let twoArg = Selector(("addGestureRecognizer:toDisplayWithIdentity:"))
            if let identity = identity, manager.responds(to: twoArg) {
                callVoid(manager, twoArg, first: recognizer, second: identity)
                AevonLog.info("[手势] 已向 \(AevonRuntime.className(manager) ?? "?") 登记识别器（带 displayIdentity）（AevonSystemGestureV105）")
                return true
            }
            let oneArg = Selector(("addGestureRecognizer:"))
            if manager.responds(to: oneArg) {
                callVoid(manager, oneArg, first: recognizer, second: nil)
                AevonLog.info("[手势] 已向 \(AevonRuntime.className(manager) ?? "?") 登记识别器（无 displayIdentity 重载）（AevonSystemGestureV105）")
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

    /// 主屏 displayIdentity（`FBDisplayManager.mainConfiguration.identity`）。
    private static func mainDisplayIdentity() -> AnyObject? {
        guard let manager = AevonRuntime.sendClass("FBDisplayManager", Selector(("sharedInstance"))) else {
            return nil
        }
        guard let configuration = AevonRuntime.send(manager, Selector(("mainConfiguration"))) else {
            return nil
        }
        return AevonRuntime.send(configuration, Selector(("identity")))
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
        let point = touch.location(in: nil)
        guard acceptsTouch(at: point) else { return false }
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
