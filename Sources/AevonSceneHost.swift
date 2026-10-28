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

    /// V0.2.43（AevonMainCanvasGuardV243）：S2 防回弹三拍复查挪进承载器。
    ///
    /// 0.2.42 真机日志实锤（Aevon(18) 10:23:14 / 10:24:03 两处）：关窗时 invalidate
    /// 已把主场景还原成 430x932，但开窗时排下的 +2.5s 复查闭包还在跑，读回发现
    /// 「不是画布尺寸」→ 当回弹处理 → **又写回 272x454**。结果 App 退出浮窗后
    /// 主场景仍停在浮窗画布上（再全屏打开只剩一小块）。
    /// 修法：复查闭包由承载器持有，`invalidated`（关窗/切换 App）即全部作废。

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
    /// V0.2.51（AevonDouyinWarmupV251）：画布预热期截止时刻（0 = 无预热）。
    /// 预热期内复查**不补写** —— App 正按整屏画布做第一遍排版（模拟「全屏打开一次」），
    /// 提前补写小画布会把预热拆了（Aevon(26) #4：抖音不经全屏先开一次、直接浮窗打开会断层）。
    private let canvasWarmupDeadline: CFTimeInterval

    init?(scene: AnyObject, sceneID: String, bundleID: String,
          isSelfBuilt: Bool = false, mainResized: Bool = false,
          canvasWarmupDelay: TimeInterval = 0) {
        self.isSelfBuilt = isSelfBuilt
        self.mainResized = mainResized
        self.canvasWarmupDeadline = canvasWarmupDelay > 0 ? CACurrentMediaTime() + canvasWarmupDelay : 0
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
            // V0.2.43（AevonContentTreeV243）：抖音「右侧点赞 / 头像栏不显示」的取证。
            // 只读：画布尺寸 vs 一级子视图尺寸。子视图比画布宽 = 该 App 仍按
            // UIScreen 全屏尺寸排版，右侧内容必然落在画布外被裁（缩放倍数治不了它，
            // 只能把画布宽度提到接近屏宽 —— ContentCanvasScale 的 1.58 档）。
            let canvas = container.bounds.size
            let views = presentationView.subviews.prefix(4).map { sub -> String in
                "\(AevonRuntime.className(sub) ?? "?")=\(Int(sub.frame.width))x\(Int(sub.frame.height))"
            }
            let overflow = presentationView.subviews.contains { $0.frame.width > canvas.width + 1 }
            let line = "[场景] 画布/视图核对：画布 \(Int(canvas.width))x\(Int(canvas.height))"
                + " 一级子视图 [\(views.joined(separator: " "))]"
                + " 画布/窗宽比 \(String(format: "%.2f", AevonWindowView.canvasScale))（常量档）"
                + "\(overflow ? " 超宽=是（按 UIScreen 排版，右侧会被裁）" : " 超宽=否")"
            if overflow {
                AevonLog.warn(line + "（AevonContentTreeV243）")
            } else {
                AevonLog.info(line + "（AevonContentTreeV243）")
            }
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
        let screen = UIScreen.main.bounds.size
        // V0.2.42（AevonMainSceneResizeV242）：S2 必须还原主场景画布 ——
        // 否则关窗后 App 再被全屏打开只有浮窗那么大（系统不会替我们改回来）。
        //
        // V0.2.48（AevonCanvasFixedV248）：Aevon(23)「关浮窗后再全屏打开 App 会黑屏
        // （设置 App 出现过）」。原因是一次「430x932 → 422x723 → 430x932」的尺寸往返
        // 里，App 可能把最后一次布局结果缓存住，还原那一笔读回虽然是 430x932，
        // App 端却还停在浮窗尺寸上 → 全屏是黑的。
        // 这里加**有界抖动复位**：先还原，再 +0.15s 写 (w-1)x(h-1)，+0.4s 写回 (w)x(h)。
        // 两次尺寸都不同 → App 一定会重新走一遍布局；总写入 3 次（有界，不碰 deactivationReasons）。
        if mainResized {
            let ok = AevonMainSceneSetFrame(scene, Double(screen.width), Double(screen.height))
            AevonLog.info("[场景] 主场景画布已还原 \(Int(screen.width))x\(Int(screen.height))"
                + "（\(ok ? "已提交" : "失败")，读回 \(AevonMainSceneFrameState(scene) ?? "")）"
                + "（AevonMainSceneResizeV242）")
            for (delay, dx, dy) in [(0.15, -1.0, -1.0), (0.40, 0.0, 0.0)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [scene] in
                    _ = AevonMainSceneSetFrame(scene, Double(screen.width) + dx, Double(screen.height) + dy)
                    if dx == 0 {
                        AevonLog.info("[场景] 主场景抖动复位收尾 \(Int(screen.width))x\(Int(screen.height))"
                            + "（读回 \(AevonMainSceneFrameState(scene) ?? "")）"
                            + "（AevonCanvasFixedV248 AevonMainCanvasRestoreV248）")
                    }
                }
            }
        }
        teardownPresenter()
        // V0.2.28（AevonSelfSceneV228）：自建场景必须 destroyScene 收尾，
        // 否则 respring 后 FBSceneManager 里残留同名场景（创建前会先销毁遗留，但别依赖它）。
        //
        // V0.2.48：销毁前**先把自建场景画布还原成整屏**，等 0.35 秒让 App 完成一次
        // 「回到大尺寸」的重排，再销毁 —— Aevon(23) 报的「关闭浮窗后全屏打开抖音，
        // 画面断层（有时 1 秒后自己好、有时不好）」就是这里缺的那一步：
        // 视频渲染层带着 422x723 的布局状态被销毁，App 回到主场景后没有触发重算。
        if isSelfBuilt {
            let restored = AevonSelfSceneResize(scene, Double(screen.width), Double(screen.height))
            AevonLog.info("[场景] 自建场景关窗前先还原整屏画布 \(Int(screen.width))x\(Int(screen.height))"
                + "（\(restored ? "已提交" : "失败")，0.35s 后销毁）（AevonCanvasFixedV248 AevonSelfSceneRestoreV248）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [scene] in
                let destroyed = AevonSelfSceneDestroy(scene)
                AevonLog.info("[场景] 自建场景已销毁（\(destroyed ? "成功" : "失败")）（AevonSelfSceneV228）")
            }
        }
        AevonLog.info("[场景] 已释放 presenter（\(bundleID)）")
    }

    /// V0.2.28（AevonSelfSceneV228）：改自建场景画布 = 真重排
    /// （updateSettingsWithBlock 内 frame = 0,0,w×h，App 随之重新布局）。
    /// 仅 isSelfBuilt 时有效；调用时机 = 缩放抬手提交真实 frame 后（一次一调，天然单飞）。
    /// V0.2.42（AevonMainSceneResizeV242）：S2（主场景改画布）走同一条路 ——
    /// 只写 frame，不写前台状态。
    /// V0.2.60（AevonWarmupGateV260）：**预热期内主场景画布一次都不许提前改**。
    ///
    /// Aevon(34) 第 4 条：「打开抖音大概率断层（下半部分黑屏），必须多次重开或全屏
    /// 打开一次并关后台卡片才恢复」。查 Aevon(34) 日志实锤预热形同虚设：
    ///   51.513 画布预热：先按整屏画布渲染一拍，1.0 秒后切浮窗画布
    ///   51.523 主场景画布已改 430x737（10 毫秒后就把整屏改掉了）
    /// 10ms 那一条来自窗口首次 `layoutSubviews → applyContentLayout` 的写画布，
    /// 它绕过了预热意图 —— App 从没按整屏排过版，「先全屏开一次」这一步等于没做，
    /// 于是抖音仍会断层。现在预热期内这一路写入直接拒绝（返回 false，调用方不记账），
    /// 真正切画布只由预热的 +1.0s 那一拍做。
    @discardableResult
    func resizeCanvasTo(width: CGFloat, height: CGFloat) -> Bool {
        guard !invalidated else { return false }
        if isSelfBuilt {
            let ok = AevonSelfSceneResize(scene, Double(width), Double(height))
            AevonLog.info("[场景] 画布已改 \(Int(width))x\(Int(height))（\(ok ? "已提交" : "失败")）（AevonSelfSceneV228）")
            return ok
        }
        if mainResized {
            if CACurrentMediaTime() < canvasWarmupDeadline {
                AevonLog.info("[场景] 画布写入让位：预热期内保持整屏画布，\(Int(width))x\(Int(height))"
                    + " 等预热切换（AevonDouyinWarmupV251 AevonWarmupGateV260）")
                return false
            }
            let ok = AevonMainSceneSetFrame(scene, Double(width), Double(height))
            AevonLog.info("[场景] 主场景画布已改 \(Int(width))x\(Int(height))（\(ok ? "已提交" : "失败")，"
                + "读回 \(AevonMainSceneFrameState(scene) ?? "")）（AevonMainSceneResizeV242）")
            return ok
        }
        return false
    }

    /// V0.2.60（AevonDouyinHealV260）：断层自愈（只读判定 + 一次补踢）。
    ///
    /// 判据：呈现视图里第一层宿主视图（`_UISceneLayerHostContainerView`）的实际尺寸
    /// 比画布还大 → App 仍按整屏在排版，浮窗里就是「上面正常、下面一条黑」。
    /// 这时再踢一次「-1pt → 写回」，逼它按新画布重排一遍。
    /// 纪律：一次开窗只补踢一次，`invalidated` 之后一律不动。
    private var healKicked = false
    func healStaleLayoutIfNeeded(width: CGFloat, height: CGFloat, tag: String) {
        guard !invalidated, !healKicked, width > 2, height > 2 else { return }
        let host = presentationView.subviews.first?.frame.size ?? .zero
        guard host.width > 2, host.height > 2 else { return }
        let stale = host.height > height + 8 || host.width > width + 8
        guard stale else {
            AevonLog.info("[场景] 断层自查：内容宿主 \(Int(host.width))x\(Int(host.height)) 已贴合画布"
                + " \(Int(width))x\(Int(height))，无需补踢（AevonDouyinHealV260）")
            return
        }
        healKicked = true
        AevonLog.warn("[场景] 断层自愈：内容宿主 \(Int(host.width))x\(Int(host.height)) 仍按整屏排版"
            + "（画布 \(Int(width))x\(Int(height))）→ 再踢一次重排（\(tag)）（AevonDouyinHealV260）")
        kickRelayout(width: width, height: height, tag: "断层自愈 \(tag)")
    }

    /// V0.2.61（AevonDouyinRepairV261，用户 Aevon(35) #9）：抖音断层**修不好**的第二条路。
    ///
    /// 0.2.60 的预热闸门 + 断层自愈只解决「画布被提前写掉」，但 Aevon(35) 实测抖音仍然
    /// 断层，而内容宿主尺寸完全贴合画布（日志「内容宿主 430x737 已贴合画布」）—— 说明
    /// 抖音是**按旧尺寸排好了版、只是不再重算**。用户给了一条可复现的解法：
    /// 「手动打开抖音，画面正常时再用悬浮窗打开就是真重排」。这一版把这条解法搬进代码：
    /// 画布先回到整屏 → 0.32 秒后写回浮窗画布 → 再踢一次重排。抖音因此会像「刚从全屏
    /// 退下来」那样重算一遍布局。
    /// 纪律：一次开窗只做一次；`invalidated` 之后一个字节都不写。
    private var seamRepaired = false
    func bounceFullscreenThenBack(width: CGFloat, height: CGFloat, tag: String) {
        guard !invalidated, !seamRepaired, mainResized, width > 2, height > 2 else { return }
        seamRepaired = true
        let screen = UIScreen.main.bounds.size
        guard screen.width > 2, screen.height > 200 else { return }
        let fullOK = AevonMainSceneSetFrame(scene, Double(screen.width), Double(screen.height))
        AevonLog.warn("[场景] 断层修复：先把画布放回整屏 \(Int(screen.width))x\(Int(screen.height))"
            + "（\(fullOK ? "已提交" : "失败")，模拟「全屏打开一次」），0.18s 后写回 "
            + "\(Int(width))x\(Int(height))（\(tag)）（AevonDouyinRepairV261）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, !self.invalidated else { return }
            let backOK = AevonMainSceneSetFrame(self.scene, Double(width), Double(height))
            AevonLog.warn("[场景] 断层修复：画布已写回 \(Int(width))x\(Int(height))"
                + "（\(backOK ? "已提交" : "失败")）→ 再踢一次重排"
                + "（\(tag)）（AevonDouyinRepairV261）")
            self.kickRelayout(width: width, height: height, tag: "断层修复 \(tag)")
        }
    }

    /// V0.2.49（AevonRelayoutKickV249）：**强制 App 走一遍完整重排**。
    ///
    /// Aevon(24) 两条同源反馈：
    ///   ｜「悬浮窗打开抖音时，需要等待 1.5 秒或者上滑一下视频才能完整真重排」
    ///   ｜「再次打开浮窗时，抖音有概率出现断层」
    ///
    /// 成因：`settings.frame` 写下去之后，App 的 window 尺寸确实变了，但**它自己不
    /// 一定立刻重排** —— 抖音这类视图层级深的 App 往往要等下一次滚动 / 视频换帧才
    /// 把新尺寸吃进布局。所以「画布改了」≠「重排完成」，中间那 1.5 秒就是空白期。
    ///
    /// 这里的做法是 **有界微扰**：先写 (w-1, h-1)，220ms 后写回 (w, h)。
    /// 两次尺寸不同 → 系统一定会再发一次 size change → App 必须再布局一遍，
    /// 而这一遍用的就是正确的画布 + 正确的 UIScreen（App 侧 0.2.49 起把 UIScreen
    /// 报成画布尺寸，见 AevonAppScreenFitV249）→ 真重排在开窗后 ~0.6 秒内完成。
    ///
    /// 纪律：**总共 2 次写入，只在开窗时一次**。绝不循环、绝不在关窗后写。
    func kickRelayout(width: CGFloat, height: CGFloat, tag: String) {
        guard !invalidated, width > 2, height > 2 else { return }
        // V0.2.62（AevonKickFastV262，用户 Aevon(36) #1「要等 1~2 秒才打开」）：
        // 起手 0.45 → 0.20 秒。0.45 是为了让过 0.35s 那一拍防回弹复查，但那一拍只
        // 认「读回值 ≠ 目标」才补写，微扰窗口和它错开 0.15s 已足够；0.45 等于让用户
        // 白等半秒才看到内容排好。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self, !self.invalidated else { return }
            _ = self.writeCanvas(width - 1, height - 1)
            AevonLog.info("[场景] 强制重排：先写 \((Int(width - 1)))x\((Int(height - 1)))"
                + "（\(tag)，让 App 收到一次尺寸变化）（AevonRelayoutKickV249）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.invalidated else { return }
                _ = self.writeCanvas(width, height)
                AevonLog.info("[场景] 强制重排：写回 \(Int(width))x\(Int(height))"
                    + "（\(tag)，App 这一遍布局用的就是最终画布）（AevonRelayoutKickV249）")
            }
        }
    }

    /// 只写画布（自建场景 / 主场景两档口径不变），不写任何前台状态。
    @discardableResult
    private func writeCanvas(_ width: CGFloat, _ height: CGFloat) -> Bool {
        if isSelfBuilt {
            return AevonSelfSceneResize(scene, Double(width), Double(height))
        }
        if mainResized {
            return AevonMainSceneSetFrame(scene, Double(width), Double(height))
        }
        return false
    }

    /// V0.2.43（AevonMainCanvasGuardV243）：S2 防回弹复查（0.35 / 1.2 / 2.5 三拍）。
    /// 与 0.2.42 的差别只有一处关键：闭包由承载器持有，`invalidated` 后一律不写。
    /// 0.2.42 那版把三拍排在 WindowManager 里、捕获裸 scene，关窗后仍在跑：
    /// 读回 430x932 ≠ 画布 → 判「被回弹」→ 又写回 272x454（真机日志两处置实）。
    func verifyMainCanvasKeep(width: CGFloat, height: CGFloat, delay: TimeInterval) {
        guard mainResized else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.invalidated else { return }
            let state = AevonMainSceneFrameState(self.scene) ?? ""
            let expected = "frame=\(Int(width))x\(Int(height))"
            let kept = state.contains(expected)
            if !kept {
                // V0.2.51（AevonDouyinWarmupV251）：预热期内画布仍是整屏 = 正常，
                // 绝不提前补写小画布（App 的整屏第一遍排版还没做完）。
                if CACurrentMediaTime() < self.canvasWarmupDeadline {
                    AevonLog.info("[场景] 主场景画布复查（+\(delay)s）：\(state)（预热期内，不补写）（AevonDouyinWarmupV251）")
                    return
                }
                _ = AevonMainSceneSetFrame(self.scene, Double(width), Double(height))
            }
            AevonLog.info("[场景] 主场景画布复查（+\(delay)s）：\(state)"
                + "（\(kept ? "仍在画布" : "被回弹已补写")）（AevonMainSceneResizeV242 AevonMainCanvasGuardV243）")
        }
    }

    // MARK: - 回桌面黑屏守卫（V0.2.47，AevonDarkGuardV247）

    /// 只读：App 的 `contentState`（2 = 已就绪在画；0/1 = 准备中或已被回收；-1 = 取不到）。
    ///
    /// 为什么用它当「还在不在画」的判据：0.2.42 起的日志里每一条主场景读回串都带
    /// `cs=`，实测「开窗瞬间 1 → 首帧后 2」，与「画面出来没有」一一对应；而
    /// `settings.foreground` 在主场景上**恒读 0**（哪怕内容正常在画，见 0.2.46 日志
    /// `读回 frame=429x735 fg=0 cs=2`），所以 foreground 不能当判据。
    var contentStateNow: Int {
        guard !invalidated else { return -1 }
        return Int(AevonSceneContentState(scene))
    }

    /// 只读：远程表面数量（-1 = 取不到）。与 contentState 交叉判读，只进日志。
    var layerCountNow: Int {
        guard !invalidated else { return -1 }
        return Int(AevonSceneLayerCount(scene))
    }

    /// 内容是否还在画。**nil = 信号不可用 → 调用方 fail-open**（绝不当成黑屏处理）。
    var contentLooksRendering: Bool? {
        let cs = contentStateNow
        guard cs >= 0 else { return nil }
        return cs == 2
    }

    /// 一行状态串（fg / cs / layers），给守卫日志做前后对照。
    func stateSummary() -> String {
        guard !invalidated else { return "已释放" }
        var fg = "?"
        if let settings = AevonRuntime.send(scene, Selector(("settings"))),
           let value = AevonRuntime.bool(settings, key: "foreground") {
            fg = value ? "1" : "0"
        }
        return "fg=\(fg) cs=\(contentStateNow) layers=\(layerCountNow)"
    }

    /// 重申浮窗里这个场景的前台。
    ///
    /// 两档口径刻意分开（归档(14) SIGTRAP 教训：主场景的 deactivation 状态机绝不碰）：
    ///   · 自建场景 → `AevonSelfSceneReassertForeground`（foreground=YES + deactivationReasons=0，
    ///     LiveContainer #942 同款）；
    ///   · 主场景（S2）→ 只写 foreground=YES（`AevonSceneHelper.setForeground`），
    ///     不碰 deactivationReasons，与 0.1.5 以来的前台补偿完全同一条写入。
    @discardableResult
    func reassertForegroundForFloat() -> Bool {
        guard !invalidated else { return false }
        if isSelfBuilt {
            return AevonSelfSceneReassertForeground(scene)
        }
        AevonSceneHelper.setForeground(scene, true)
        return true
    }

    /// V0.2.50（AevonDockColumnV250）：停靠小窗不转发触摸。
    ///
    /// 停靠窗的点击语义只有一个 ——「把这个 App 装回主窗」。如果内容层还开着交互，
    /// UIKit 会通过 presenter 把这根手指原样转发进 App 进程（历史上就是这条把抖音
    /// 点跑了：点停靠小窗等于点了 App 里的那个位置）。关掉交互后，命中只会落在
    /// 我们自己的边条手柄上，语义可控。
    func setContentInteraction(_ enabled: Bool) {
        guard !invalidated else { return }
        container.isUserInteractionEnabled = enabled
        presentationView.isUserInteractionEnabled = enabled
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
