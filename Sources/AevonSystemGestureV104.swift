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
    /// 起手窗（pt，V0.1.10 / AevonSystemGestureV110）。
    ///
    /// Aevon(77) 日志把「偶尔触发抖音」的坐标抓到了：真正想呼圆盘的那几次，手指落点是
    /// **x=386 / 391 / 397 / 402**（距右缘 28~44pt），而 0.1.9 的接管窗口只有外侧 20pt（x≥410），
    /// 于是这些触摸既没被热区接（热区 x≥412）、也没被系统手势带接 → 整条交给抖音，抖音就动了。
    /// 所以「观察 / 起手」的横向窗口放到 44pt，但**视图命中仍只 20pt**：
    /// 命中决定系统把哪些触摸判给本条带（关系到带内轻点能不能传给 App），
    /// 而识别器早已在整屏触摸流里（日志 15 条任意坐标的「判据拒收」即证），
    /// 放宽观察窗不会多抢一个点击，只会让「落点偏了 20pt」的左扫也能被我们接住。
    static let beginSlack: CGFloat = 44

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
    /// 判向日志限频（V0.1.9 起接手 lastLogAt 的职责；右缘命中已改为每次必记）。
    private var beginLogAt: CFTimeInterval = 0
    private var installedLogged = false
    /// V0.1.8：识别器在触摸流里被问过多少次（`shouldReceiveTouch` 次数）。
    /// 只要它真的挂进了系统手势环境，右缘落下时这里必然 > 0。
    private var pipelineTouchCount = 0
    /// V0.1.8：反证计数 —— 全局通道在右缘看到触摸，但识别器一次都没被问过。
    private var pipelineMissCount = 0
    /// V0.1.8：被「判据」拒收时的限频日志时间戳（区分「没进触摸流」与「进了但被我们拒」）。
    private var rejectLogAt: CFTimeInterval = 0
    /// V0.1.10：这一根手指的落点。判向只看「落点是否在起手窗内」，
    /// 不看 began 那一刻的位置 —— 因为那时手指已经滑进来 6~8pt 了，拿它判会把贴边起步的算成带外。
    private var pendingStart: CGPoint = .zero
    private var hasPendingStart = false
    /// V0.1.11（AevonBandTrackV111）：跟踪采样令牌 + 放弃计数。
    /// Aevon(78) 里「起手窗接收了一根手指、却既没判向也没 began」是唯一的异常样本，
    /// 光看日志分不清是「用户只是点了一下」还是「识别器根本没在跟踪这根手指」。
    /// 所以每次接收后 0.3s 回采一次 `recognizer.state`：still `possible` = 没跟；`failed` = 跟了但放弃。
    private var trackToken = 0
    private var abandonedInWindow = 0

    /// V0.1.13（AevonPipelineStandDownV113）：识别器是否允许接收触摸。**恒 false。**
    ///
    /// 为什么停手（Aevon(80) 复盘，机制链条完整闭合）：
    ///   ① 本类把 `delaysTouchesBegan` 设成 true（0.1.9 为了让 App 别在识别器 began 前先动手）；
    ///   ② 于是它一旦 `shouldReceiveTouch` 返回 true，App 的 began 就被**扣在 UIKit 手势环境里**；
    ///   ③ 而 `gestureRecognizerShouldBegin` 在「老通道正持有这根手指」时直接返回 false（防双呼）；
    ///   ④ 识别器必然 failed → UIKit 把被扣住的 began 连同**其后的全部移动**一次性补投给 App；
    ///   ⑤ 这次补投发生在手势环境内部，`UIApplication -sendEvent:` 根本看不到，吞不掉。
    /// 于是「圆盘出来了、抖音进度条也动」。热区之所以一直干净（20/20），正因为它在
    /// shouldReceiveTouch 就被拒（日志：「原因=落在热区」），从未进过这条延迟缓冲。
    /// 它 0.1.8~0.1.12 五版接管次数为 0，留着只剩第 ④ 条副作用 —— 整条停手。
    ///
    /// 写成变量而不是在方法里直接 `return false`：那样 Swift 会报
    /// `code after 'return' will never be executed`，而 Theos 带 -Werror，警告即断构建；
    /// 也不至于把下面那段取证代码整片删掉，历史串一条都不用动。
    static let pipelineAllowed = false

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
        // V0.1.9（AevonSystemGestureV109）—— 「抖音前一两次不动、后面又动」的正解就在这两行。
        //
        // 0.1.5~0.1.8 一直把这两个开关设成 false（当时的理由是「别干扰 App」），
        // 结果识别器虽然真进了系统手势环境、也确实收到了触摸，但**App 那一份触摸照样完整收到**：
        // UIPan 要位移才 began，而在它 began 之前的几十毫秒里，App 已经拿到了 began 和位移，
        // 抖音的横滑手势就成立了 —— 于是圆盘出来、进度条也一起走。
        // 这也解释了「前一两次不动、后面又动」：前几次落在右下角热区（那条是完全接管，
        // App 连 began 都收不到），后面落在热区外走系统手势通道，App 就有机会先动手。
        //
        // 现在改成 true：
        //   · delaysTouchesBegan —— 判定期内先扣住 App 的 began，等我们决定收不收；
        //   · cancelsTouchesInView —— 我们收下之后，把 App 那条触摸整条取消。
        // 代价（必然取舍）：右缘 20pt 带内的触摸会先延迟几十毫秒才轮到 App；
        // 判定不是左扫就立刻 failed 还给它，轻点/竖滑基本无感。
        pan.delaysTouchesBegan = true
        pan.cancelsTouchesInView = true
        pan.delaysTouchesEnded = true
        pan.delegate = self
        band.addGestureRecognizer(pan)

        bandView = band
        recognizer = pan
        pipelineRegistered = AevonSystemGestureV105.registerWithSystemGesturePipeline(pan)

        if installedLogged { return }
        installedLogged = true
        if pipelineRegistered {
            AevonLog.info("[手势] 已登记进系统手势管线，但本版**停手不接收任何触摸**（避免它扣住 App 的 began 再整段补投；右缘统一由全局通道负责）（AevonSystemGestureV105 AevonSystemGestureV106 AevonSystemGestureV110 AevonPipelineStandDownV113）")
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
        return commonGatesOK() && insideHardBand(point)
    }

    /// V0.1.10：观察/起手窗的判据 —— 与命中判据共用前置闸门，只是横向窗口更宽。
    /// 说明：命中（point(inside:)）仍走 `acceptsTouch` 的 20pt，避免把带内轻点让给本条带；
    /// 这里宽出来的部分只用于「愿不愿意看这根触摸」。
    func observesTouch(at point: CGPoint) -> Bool {
        return commonGatesOK() && insideStartWindow(point)
    }

    /// 前置闸门（命中与观察共用）：开关、App 前台、圆盘未开、避开热区与浮窗。
    private func commonGatesOK() -> Bool {
        guard AevonPrefs.bool("Enabled", default: false),
              AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return false }
        // 只在全屏 App 前台时接管：桌面有自己的热区语义，不能被这条带盖住右侧图标
        guard AevonEntryHost.mountedInAppScene else { return false }
        // 圆盘已经开着：后续触摸归圆盘自己的通道
        guard AevonRingMenu.presented == nil else { return false }
        return true
    }

    /// 外侧 20pt：系统判归属于本条带的那一缝（带内轻点不传 App，故收窄）。
    private func insideHardBand(_ point: CGPoint) -> Bool {
        let screen = UIScreen.main.bounds
        guard point.x >= screen.width - AevonGestureBandView.bandWidth else { return false }
        // 底部热区是老入口，优先级更高（按住即接管 + 左滑呼出都在那儿）
        guard !AevonTriggerZone.rect(in: screen).contains(point) else { return false }
        // 浮窗（含外侧手柄）压住的地方交给浮窗，否则贴边浮窗拖不动
        guard !AevonEntryHost.pointHitsFloatingWindow(at: point) else { return false }
        return true
    }

    /// 外侧 44pt：可接管的落点范围（V0.1.10）。真机实测落点散布 28~44pt，20pt 的窗口漏掉一半。
    private func insideStartWindow(_ point: CGPoint) -> Bool {
        let screen = UIScreen.main.bounds
        guard point.x >= screen.width - AevonGestureBandView.beginSlack else { return false }
        guard !AevonTriggerZone.rect(in: screen).contains(point) else { return false }
        guard !AevonEntryHost.pointHitsFloatingWindow(at: point) else { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // V0.1.13（AevonPipelineStandDownV113）：**一律不接**。
        // 详见 `pipelineAllowed` 的长注释 —— 它接了就会扣押 App 的 began，
        // 而它自己又必然被 shouldBegin 否决 → UIKit 把整段移动补投给 App。
        // 不接 = 不进延迟缓冲 = 没有第 ④ 条。管线登记与全部取证串保留，只是不再参与触摸流。
        guard AevonSystemGestureV105.pipelineAllowed else { return false }
        // V0.1.8：先计数再判条件 —— 我们要的证据是「识别器有没有进触摸流」，
        // 而不是「这一次它有没有同意接收」。两个问题不能混为一个。
        pipelineTouchCount += 1
        let point = touch.location(in: nil)
        // V0.1.9：右缘附近的触摸无论收不收都必须留证据 —— 「右缘到底有没有进识别器」
        // 是这条通道存亡的唯一判据，上一版就是因为只记拒收总数、看不出坐标分布才绕了一圈。
        let nearRightEdge = point.x >= UIScreen.main.bounds.width - AevonGestureBandView.beginSlack - 8
        // V0.1.10：判向看落点，落点在这里记。
        guard observesTouch(at: point) else {
            let now = CACurrentMediaTime()
            if nearRightEdge {
                let zone = AevonTriggerZone.rect(in: UIScreen.main.bounds).contains(point)
                let floating = AevonEntryHost.pointHitsFloatingWindow(at: point)
                let ringOpen = AevonRingMenu.presented != nil
                // V0.1.11：把真正的那一条原因列出来。
                // Aevon(78) 里 8 条「距右缘 8pt 起手窗外」其实是被**热区**挡的（热区优先级更高），
                // 文案写错了，等于自己给自己制造了一个假线索。
                var why: [String] = []
                if !AevonPrefs.bool("Enabled", default: false) { why.append("插件未启用") }
                if !AevonPrefs.bool("EdgeGestureEnabled", default: true) { why.append("右缘呼出已关") }
                if !AevonEntryHost.mountedInAppScene { why.append("App 非前台") }
                if ringOpen { why.append("圆盘开着") }
                if zone { why.append("落在热区（老入口优先）") }
                if floating { why.append("浮窗压住") }
                if point.x < UIScreen.main.bounds.width - AevonGestureBandView.beginSlack { why.append("起手窗外") }
                AevonLog.warn("[手势] 右缘触摸被拒 (x=\(Int(point.x)), y=\(Int(point.y))，距右缘 \(Int(UIScreen.main.bounds.width - point.x))pt，原因=\(why.isEmpty ? "未知" : why.joined(separator: "+"))，热区=\(zone)，浮窗=\(floating)，圆盘=\(ringOpen))（AevonSystemGestureV110 AevonBandTrackV111）")
            } else if now - rejectLogAt > 2.0 {
                rejectLogAt = now
                AevonLog.info("[手势] 识别器已收到触摸但判据拒收 (x=\(Int(point.x)), y=\(Int(point.y))，App前台=\(AevonEntryHost.mountedInAppScene)，圆盘开着=\(AevonRingMenu.presented != nil))（AevonSystemGestureV108）")
            }
            return false
        }
        pendingStart = point
        hasPendingStart = true
        touchPointer = 0
        pendingPointer = UInt(bitPattern: Unmanaged.passUnretained(touch).toOpaque())
        pointerDeadline = CACurrentMediaTime() + 12
        // V0.1.9：右缘命中**每次必记**，不再限频。
        // 上一版用 1.5 秒窗限频，结果最关键的那几次右缘触摸被自己的日志窗口藏掉了 ——
        // 取证纪律：事件发生时必记，宁可多几行，也不许让证据消失。
        // V0.1.10：连带记「距右缘多少 pt」，20pt 内是接管缝、20~44pt 是新增的起手窗。
        let inset = Int(UIScreen.main.bounds.width - point.x)
        let tier = inset <= Int(AevonGestureBandView.bandWidth) ? "接管缝" : "起手窗"
        AevonLog.info("[手势] 系统手势管线拿到右缘触摸 (x=\(Int(point.x)), y=\(Int(point.y))，距右缘 \(inset)pt，落在\(tier))（AevonSystemGestureV105 AevonSystemGestureV110）")
        scheduleTrackSample(inset: CGFloat(inset), tier: tier)
        return true
    }

    /// V0.1.11：0.3 秒后回采识别器状态，用来分辨「没跟踪」与「跟了但放弃」。
    ///
    /// 判读方法（AevonBandTrackV111）：
    ///   · `possible` —— 手指还在屏上、识别器一直没到起手阈值 → **它没在跟这根手指**
    ///     （说明登记进管线只让它「被问要不要」，真正跟踪仍要求视图命中）；
    ///   · `failed` —— 跟了、但判据放弃（方向不符 / 轻点）→ 管线是好的，问题只在几何窗口；
    ///   · `began` / `changed` —— 正常接管。
    private func scheduleTrackSample(inset: CGFloat, tier: String) {
        trackToken &+= 1
        let token = trackToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self = self, self.trackToken == token, let pan = self.recognizer else { return }
            let state: String
            switch pan.state {
            case .possible: state = "possible（在跟，未到起手阈值）"
            case .began: state = "began（已接管）"
            case .changed: state = "changed（已接管）"
            case .failed: state = "failed（跟了但放弃）"
            case .ended: state = "ended（已结束）"
            case .cancelled: state = "cancelled"
            @unknown default: state = "unknown"
            }
            if pan.state == .failed { self.abandonedInWindow += 1 }
            AevonLog.info("[手势跟踪] 0.30s 采样：识别器状态=\(state)，起手距右缘 \(Int(inset))pt，落在\(tier)，管线已登记=\(self.pipelineRegistered)，累计放弃 \(self.abandonedInWindow) 次（AevonBandTrackV111）")
        }
    }

    /// 只认从右缘起手的向左横扫：上下滑（刷抖音信息流）与轻点都在这一步直接失败。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 没进系统手势管线时这条带只做「视图层观察」，不参与呼出 ——
        // 否则会和 0.1.3 的延迟接管老通道各呼一次圆盘。
        guard pipelineRegistered else { return false }
        // V0.1.12（AevonBandHoldMovedV112）：右缘呼出已独家交给全局通道（它扣移动帧，纯 SB 侧确定生效）。
        // 管线这边只保留「延迟 App began」的附带作用 —— 它若也 begin，就会各呼一次圆盘。
        guard !AevonEdgeEntry.isBandHoldingTouch else { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let translation = pan.translation(in: nil)
        // V0.1.10：必须从右缘起手（落点在 44pt 内）。不看这一刻的位置 ——
        // 手指滑进来以后 x 必然变小，拿它判会把「贴边起手」误判成带外。
        let inset = hasPendingStart ? UIScreen.main.bounds.width - pendingStart.x : 999
        let fromEdge = inset <= AevonGestureBandView.beginSlack
        // 判据：向左、位移 ≥6pt、横纵比 ≥1.2（斜着刷信息流不算）。阈值从 8 收到 6，
        // 是为了比 App 自己的横滑手势（一般 10pt 起）更早 began，把拦截点往前挪。
        let directionOK = translation.x <= -6 && abs(translation.x) >= abs(translation.y) * 1.2
        let allowed = fromEdge && directionOK
        let now = CACurrentMediaTime()
        if now - beginLogAt > 0.4 {
            beginLogAt = now
            AevonLog.info("[手势] 判向 dx=\(Int(translation.x)) dy=\(Int(translation.y)) 起手距右缘 \(Int(inset))pt → \(allowed ? "收归圆盘" : (fromEdge ? "还给 App（方向不符）" : "还给 App（起手在带外）"))（AevonSystemGestureV110）")
        }
        if !allowed { hasPendingStart = false }
        return allowed
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
        // V0.1.13（AevonPipelineStandDownV113）：识别器已停手，它本来就不再接收触摸，
        // 「登记成功却拿不到触摸」这条反证失去意义 —— 留在这里会把下一份日志搅浑。
        guard AevonSystemGestureV105.pipelineAllowed else { return }
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
            AevonLog.info("[手势] 识别器 began (x=\(Int(point.x)), y=\(Int(point.y)), 起手距右缘 \(hasPendingStart ? Int(UIScreen.main.bounds.width - pendingStart.x) : -1)pt) → 呼出圆盘（AevonSystemGestureV109 AevonSystemGestureV110）")
            AevonEdgeEntry.triggerFromSystemGesture(point: point)
        case .changed:
            AevonRingMenu.presented?.remoteMoved(to: point, source: "systemgesture")
        case .ended:
            AevonRingMenu.presented?.remoteEnded(at: point, source: "systemgesture")
            touchPointer = 0
            pendingPointer = 0
            hasPendingStart = false
        case .cancelled, .failed:
            AevonRingMenu.presented?.remoteCancelled(source: "systemgesture")
            touchPointer = 0
            pendingPointer = 0
            hasPendingStart = false
        default:
            break
        }
    }
}
