import UIKit

/// 缩放 / 移动手柄（V0.0.37）：带方向标记的透明视图。
/// 挂在浮窗**外侧**（Stheno 同款：手势区域为边缘外侧，绝不占窗内触摸）。
final class AevonEdgeHandleView: UIView {
    /// 这个手柄负责哪些边（角手柄是两个边的组合 → 缩放；单边条 → 移动）
    var edges: UIRectEdge = []
    /// 角手柄（横竖两边都有）= 缩放，单边条 = 移动
    var isCorner: Bool {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        return horizontal && vertical
    }
}

/// 浮窗上被按住的位置（V0.0.41，AevonFloatGlobalV41）。
///
/// 全局触摸通道拿不到 `UIPanGestureRecognizer`，只能拿到坐标，所以命中结果用这个
/// 枚举交给浮窗自己决定「这次拖动是移动 / 缩放 / 关闭」。
enum AevonFloatGrab {
    /// 外侧边条 → 移动窗口
    case bar(UIRectEdge)
    /// 外角块 → 从对角缩放
    case corner(UIRectEdge)
}

/// 单个 App 的浮窗外壳：纯内容（无标题栏）+ 右上悬浮 ✕ + 贴窗外边缘的手势区。
///
/// V0.0.9：App 场景按整屏尺寸渲染，浮窗只对承载容器做等比缩放。
/// V0.0.11：内容区宽高比锁定屏幕比例。
/// V0.0.12：手势期间只改外壳 `layer.transform`，抬手才提交真实 frame。
/// V0.0.13：窗口大小/位置记忆（V0.1.1 起双击改为「顶部双击恢复默认几何」）。
/// V0.0.14：拖到屏幕边缘自动吸附（左半屏 / 右半屏；顶部放大已随 V0.1.1 移除）。
/// V0.0.36：四周 8 向缩放（当时在窗内）。
/// V0.0.37（AevonSthenoEdgeBarV37）：按 Stheno 逆向证据重做手势体系 ——
///   手势区域**只在浮窗边缘外侧**（EdgeBarControlView / GestureIntroduction
///   「浮窗手势区域为边缘外侧…」），窗内 100% 留给 App 内容：
///     · 拖四条**边条**（外侧）＝ 移动窗口；
///     · 拖四个**外角块** ＝ 缩放（对角锚定，比例锁定）；
///     · **顶部边条双击** ＝ 恢复默认大小与位置（V0.1.1，双击放大/换档已移除）；
///     · 右上角悬浮 ✕ ＝ 关闭；
///     · 拖到屏幕左右边缘松手自动吸附半屏。
///   顶部标题栏（拖动条 + 关闭钮）整条移除（用户要求）。
/// V0.2.21（AevonFloat53V221，用户定档）：主悬浮窗 5:3 + 手势重做 ——
///   · 内容区比例**固定 5:3**（不再锁屏幕比例）；App 画面按 **min** 等比缩放居中
///     （letterbox：整块内容连顶栏/底栏一起完整可见，绝不裁切）；
///   · 手势全部在窗外：
///       底部 + 左右三条边条 = **长按 0.3s 后拖动**移动窗口；
///       左下 / 右下外角块 = 缩放（比例锁 5:3，锚点 = 不动的对边/顶边）；
///       **底部边条双击 = 关闭浮窗**；右上悬浮 ✕ 保留；
///       顶部不再有任何手势（顶部双击恢复默认已随本版移除）。
/// V0.0.37（AevonMedusaFrameV37）：几何记忆改用 Stheno 的方案 ——
///   全局一份 `MedusaFrameLast`（left/top/width 三个屏幕百分比，对应 Stheno 的
///   medusaFrameLast / _leftPecentLast 体系），所有浮窗共享上次位置与大小；
///   不再按 App 分别记忆。
/// V0.0.41（AevonFloatGlobalV41）：手势不再只靠手柄上的 `UIPanGestureRecognizer`。
///   Aevon(34) 真机：桌面拖动/缩放正常、全屏 App 里完全无效 —— 同一个视图层代码，
///   差别只在事件来源。全屏 App 时 `SBDeviceApplicationSceneViewController.view`
///   的命中测试不把窗外的点交给我们（V0.0.23 已确认的黑洞），pan 永远不 begun。
///   现在把手柄的**命中判定 + 位移计算**拆成 `grab(at:)` / `grabBegin` / `grabUpdate`
///   / `grabEnd`，由全局触摸通道（`UIApplication -sendEvent:`）直接驱动；
///   pan 仍保留，作为该通道不可用时的桌面兜底（通道接管时会吞掉事件，不会双触发）。
final class AevonWindowView: UIView {
    let bundleID: String
    /// V0.2.28（AevonSelfSceneV228）：可变 —— 自建场景 8 秒无首帧时整体换成主场景承载。
    private var sceneHost: AevonSceneHost
    /// 自建场景回退看门狗（8 秒无首帧 → 换主场景，单场景 App 可能拒绝连接第二个场景）
    private var selfSceneFallbackTimer: Timer?

    /// 内容区宽高比（宽 ÷ 高）。V0.2.22（AevonFloat53PortraitV222）：5:3 = 高5:宽3（竖窗）。
    /// Aevon(106) 用户纠偏：0.2.21 曾按「宽:高」做成 1.667 横长条，实为竖窗 0.6。
    static let contentAspect: CGFloat = 3.0 / 5.0

    private static let minContentWidth: CGFloat = 240
    private static let cornerRadius: CGFloat = 12
    /// 外侧手势区厚度（边条）与外角块边长（pt）。Stheno 的 edgeWidth 同位概念。
    /// V0.2.23（AevonFloatWideGripV223）：Aevon(107) 反馈「不容易触发」，18/34 → 26/44。
    /// V0.2.26（AevonFloatSthenoEdgeV226）：26 → 30 —— 对齐 Stheno edgeWidth 默认值
    /// （GestureBorderWidth，其默认 30pt 用户可调；我们取默认起步）。
    static let barThickness: CGFloat = 30
    static let cornerSize: CGFloat = 44
    /// V0.2.24（AevonFloatGripOverlapV224）：手柄向窗内压边宽度（pt）——
    /// 边线两侧都算手势区，瞄准边缘的指尖不再滑进 App 内容。
    static let gripOverlap: CGFloat = 10

    /// 全局唯一的偏好域，和设置面板共用
    private static let prefsSuite = "com.Aevon"
    /// Stheno 式全局几何记忆键（medusaFrameLast 对应物）
    private static let frameMemoryKey = "MedusaFrameLast"

    private let contentClip = UIView()
    private let hintLabel = UILabel()

    private var moveOriginFrame: CGRect = .zero
    private var moveOriginPoint: CGPoint = .zero
    private var resizeOriginFrame: CGRect = .zero
    private var resizeOriginPoint: CGPoint = .zero
    /// 本次缩放抓的是哪几条边（角块 = 两边组合）
    private var resizeOriginEdges: UIRectEdge = []
    /// 缩放锚点（unit 坐标）：对角固定点，缩放时它不动
    private var resizeAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)

    /// 手势进行中（此时只允许改 transform，不允许改 frame）
    private var isLiveResizing = false
    /// 边条拖动进行中（V0.2.21 建；V0.2.27 起落指即拖，AevonFloatEdgeGripV227）
    private var isBarHoldMoving = false
    /// V0.2.43（AevonCanvasScaleV243）：最近一次提交给场景的画布尺寸（去重，
    /// 避免每次 layoutSubviews 都跨进程写一遍 settings.frame）
    private var appliedCanvasSize: CGSize = .zero

    init(sceneHost: AevonSceneHost, bundleID: String, title: String) {
        self.bundleID = bundleID
        self.sceneHost = sceneHost
        super.init(frame: CGRect.zero)

        // V0.1.5（AevonNoSnapV105）：左右吸附与左右分屏一起移除 ——
        // 单窗模式下不存在并排，吸附只会让窗在松手瞬间突然变形。
        // 几何一律走 Stheno 式全局记忆（medusaFrameLast 方案）。
        var sizeSource = "默认尺寸"
        let restored = AevonWindowView.rememberedFrame(fallback: AevonWindowView.defaultFrame())
        if restored != AevonWindowView.defaultFrame() { sizeSource = "已恢复上次几何（全局记忆）" }

        frame = CGRect(x: restored.minX, y: restored.minY,
                       width: restored.width, height: restored.height)

        backgroundColor = .clear
        // V0.0.37：窗口本体不裁剪 —— 外侧手势区要伸到 frame 外面；
        // 圆角裁剪由 contentClip 负责。
        clipsToBounds = false

        // 内容区（全高，无标题栏）。圆角 + 裁剪都在这一层。
        contentClip.frame = bounds
        contentClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentClip.clipsToBounds = true
        contentClip.layer.cornerRadius = AevonWindowView.cornerRadius
        contentClip.backgroundColor = UIColor(white: 0.18, alpha: 1.0)
        addSubview(contentClip)

        contentClip.addSubview(sceneHost.container)

        // 等待画面提示（拿到第一帧后自动消失）
        hintLabel.frame = contentClip.bounds
        hintLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.textColor = UIColor(white: 0.85, alpha: 1.0)
        hintLabel.font = UIFont.systemFont(ofSize: 13)
        hintLabel.text = "正在等待 App 画面…\n若一直停在这里，请把 /var/mobile/Aevon.log 发给开发者"
        contentClip.addSubview(hintLabel)

        sceneHost.onFirstContent = { [weak self] in
            self?.handleFirstContent()
        }

        // V0.2.28（AevonSelfSceneV228）：自建场景看门狗 —— 单场景 App 可能拒绝连接
        // 第二个场景（FrontBoardAppLauncher known issue），8 秒无首帧自动回退主场景承载。
        if sceneHost.isSelfBuilt {
            let timer = Timer(timeInterval: 8.0, repeats: false) { [weak self] _ in
                self?.fallbackToPrimarySceneIfEmpty()
            }
            RunLoop.main.add(timer, forMode: .common)
            selfSceneFallbackTimer = timer
        }

        // V0.2.24（AevonFloatTopBarV223 退休）：顶部留白栏整体移除 —— Aevon(108) 实测
        // 它盖住内容造成显示异常。顶部不再有任何覆盖物。

        // V0.0.37（AevonSthenoEdgeBarV37）：外侧边缘手势区（V0.2.27 起 = 左/右/底三条边条
        // 落指即拖 + 底部两角块，顶边条删除）
        installOutsideGestureHandles(width: restored.width, height: restored.height)

        // V0.2.26（AevonPiPProbeV226）：真重排路线 P0 探测（只读，一次一进程）
        AevonWindowView.probeSceneRoutesOnce()

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)"
            + "（外侧手势区，内容比例 5:3 = 宽3:高5 竖窗（AevonFloat53V221 AevonFloat53PortraitV222），"
            + "内容=整屏场景呈现（AevonFloatSceneLayoutV224 AevonFloatHostedResizeV225，"
            + "真重排唯一通路=自建场景路线，P0 探测 AevonPiPProbeV226），"
            + "手势区=左/右/底全宽 30/44+压边10 落指即拖（AevonFloatWideGripV223"
            + " AevonFloatGripOverlapV224 AevonFloatSthenoEdgeV226 AevonFloatEdgeGripV227，顶边条已删），"
            + "缩放快照冻结+空闲预抓缓存（AevonFloatSnapResizeV226 AevonFloatSnapCacheV227）"
            + "全程圆角（AevonFloatRoundResizeV224），"
            + "内容 \(Int(restored.width))x\(Int(restored.height))，"
            + "\(sizeSource)）（AevonSthenoEdgeBarV37）")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 真重排路线 P0 探测（V0.2.26，AevonPiPProbeV226）

    /// Aevon(1) 定案：SB 侧「事后改场景尺寸」路线已被 0.0.x 档案三重实锤排除
    /// （V63：dc ivar 直写全链成功 App 仍不重排；V64：FBScene 无 resizesHosted 选择子；
    /// V87：SBDeviceApplicationSceneEntity 5 个候选 init 全 nil）。
    /// 剩余唯一通路 = **创建时烙定画布**（Stheno 在用的 FBSceneManager
    /// `_createSceneWithDefinition:settings:...` 族）或 PiP handle（TrollOpen
    /// `__pipSceneHandle` / PullOverX video-hosted 轨道）。本探测只读、一次一进程，
    /// 为下轮 P1 立项钉运行时判据 —— 不改变任何现有行为。
    private static var didProbeSceneRoutes = false
    private static func probeSceneRoutesOnce() {
        guard !didProbeSceneRoutes else { return }
        didProbeSceneRoutes = true
        let exception = AevonShieldRun {
            var parts: [String] = []
            let fbMethods = AevonMethodNamesForClass("FBSceneManager") ?? []
            let createWithSettings =
                "_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:"
            parts.append("FBSceneManager._createScene(带settings)=\(fbMethods.contains(createWithSettings) ? "响应" : "无")")
            parts.append("createSceneWithDefinition:initialParameters:=\(fbMethods.contains("createSceneWithDefinition:initialParameters:") ? "响应" : "无")")
            let sbVCMethods = AevonMethodNamesForClass("SBDeviceApplicationSceneViewController") ?? []
            parts.append("SceneVC.setSceneResizesHostedContext:=\(sbVCMethods.contains("setSceneResizesHostedContext:") ? "响应" : "无")")
            for name in ["FBSceneHostManager", "SBDeviceApplicationSceneHandle",
                         "FBSSceneParameters", "FBSMutableSceneDefinition"] {
                var exists = false
                AevonShieldRun { exists = NSClassFromString(name) != nil }
                parts.append("\(name)=\(exists ? "类在" : "无")")
            }
            AevonLog.info("[场景] 路线探测：\(parts.joined(separator: " "))（AevonPiPProbeV226）")
        }
        if let exception = exception {
            AevonLog.warn("[场景] 路线探测异常：\(exception)（AevonPiPProbeV226）")
        }
    }

    /// 无记忆时的默认几何：宽 62% 屏宽（5:3 竖窗 → 高约 48% 屏高），顶边 10% 屏高，水平居中。
    private static func defaultFrame() -> CGRect {
        let screen = UIScreen.main.bounds
        let aspect = contentAspect
        let width = max(minContentWidth, min(screen.width * 0.62,
                                             (screen.height * 0.92) * aspect))
        let height = width / aspect
        return CGRect(x: (screen.width - width) / 2.0,
                      y: max(24, screen.height * 0.10),
                      width: width, height: height)
    }

    /// V0.2.28（AevonSelfSceneV228）：自建场景的画布尺寸 = 开窗时的内容区尺寸
    /// （恢复几何或默认）。开窗瞬间用它烙定场景画布。
    static func plannedContentSize() -> CGSize {
        let restored = rememberedFrame(fallback: defaultFrame())
        return CGSize(width: restored.width, height: restored.height)
    }

    /// V0.2.43（AevonCanvasScaleV243）：内容画布倍数。
    ///
    /// 0.2.42 真机（Aevon(18)）定论：S2 主场景改画布 = **真重排成立**（所有 App 都重排了），
    /// 但画布 = 窗口尺寸时 App 的逻辑宽度只有 272pt —— 比任何一台 iPhone 都窄，
    /// 而字号是固定 pt 值 → 用户看到的就是「文字比全屏大、显示的内容变少」。
    ///
    /// 解法：把**逻辑画布放大 k 倍**，呈现时再把整套内容缩回 1/k。
    /// 同一块窗口面积里因此塞得下 k 倍宽的排版，字号等比变小、内容变多。
    ///   k = 1.00 → 字号与全屏一致（0.2.42 形态）
    ///   k = 1.30 → 标准（默认，逻辑宽 ≈354pt，接近 iPhone SE 的 375）
    ///   k = 1.58 → 逻辑宽正好占满屏宽 430（抖音这类按 UIScreen 排满画面的 App 最友好）
    /// 上限由屏宽夹住（画布宽绝不超屏宽），5:3 比例不变 → 无变形、无黑边、无 letterbox。
    static var canvasScale: CGFloat {
        // 设置 App 是另一个进程：CFPreferences 在本进程有缓存，不失效就读到旧值。
        // 这里是布局热路径（App 每帧都会间接走到），所以 0.5s 节流 —— 拖滑杆后
        // 最迟半秒生效，代价是每半秒一次 IPC，远低于「每次布局都 synchronize」。
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCanvasScaleSync >= 0.5 {
            lastCanvasScaleSync = now
            AevonPrefs.synchronize()
        }
        let raw = AevonPrefs.double("ContentCanvasScale", default: 1.30)
        let clamped = max(1.0, min(1.60, CGFloat(raw)))
        // 量化到 0.05：滑杆产生的 1.2837 不进日志、不进画布
        return (clamped * 20).rounded() / 20
    }

    /// 画布倍数偏好的最后一次 CFPreferences 失效时刻（V0.2.43）
    private static var lastCanvasScaleSync: TimeInterval = 0

    /// 窗口内容尺寸 → 场景画布尺寸（等比放大 k 倍，宽高比不变，宽不超屏宽）。
    static func canvasSize(for windowSize: CGSize) -> CGSize {
        guard windowSize.width > 1, windowSize.height > 1 else { return windowSize }
        let screen = UIScreen.main.bounds.size
        var width = min(windowSize.width * canvasScale, screen.width)
        var height = width / contentAspect
        if height > screen.height {
            // 极端（窗口已经很高 + 大倍数）：按屏高反推，仍保持 5:3
            height = screen.height
            width = height * contentAspect
        }
        let rounded = floor(width)
        return CGSize(width: rounded, height: rounded / contentAspect)
    }

    /// 首帧到达（主场景 / 自建场景共用）。
    private func handleFirstContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hintLabel.isHidden = true
            // V0.2.28：自建场景等到首帧 = 真重排成立的硬证据，看门狗使命完成
            if self.sceneHost.isSelfBuilt {
                self.selfSceneFallbackTimer?.invalidate()
                self.selfSceneFallbackTimer = nil
            }
            // V0.2.27（AevonFloatSnapCacheV227）：首帧到达后空闲预抓快照，
            // 之后的缩放手势落指即用缓存图（零同步渲染）
            self.scheduleSnapshotRecapture()
        }
    }

    /// V0.2.28（AevonSelfSceneFallbackV228）：自建场景 8 秒无首帧 →
    /// 销毁自建场景，换成主场景全屏接管承载（0.2.27 形态）—— 绝不黑屏。
    private func fallbackToPrimarySceneIfEmpty() {
        selfSceneFallbackTimer = nil
        let host = sceneHost
        guard host.isSelfBuilt, !host.hasContent else { return }
        AevonLog.warn("[场景] 自建场景 8 秒无首帧 → 回退全屏接管路径（AevonSelfSceneFallbackV228）")
        guard let primary = AevonSceneHelper.scene(for: bundleID),
              let newHost = AevonSceneHost(scene: primary,
                                           sceneID: (AevonRuntime.send(primary, Selector(("identifier"))) as? String) ?? "",
                                           bundleID: bundleID) else {
            AevonLog.warn("[场景] 回退失败：主场景或承载不可用，保持现状（AevonSelfSceneFallbackV228）")
            return
        }
        let old = sceneHost
        sceneHost = newHost
        // V0.2.32（AevonSelfSceneFGV232）：自建场景随之销毁，保活登记同步注销
        //（保活目标会自动落回主场景，回到 0.2.27 全屏接管形态）。
        AevonSceneHelper.unregisterSelfScene(bundleID)
        old.container.removeFromSuperview()
        old.invalidate()   // 含自建场景 destroyScene
        contentClip.insertSubview(newHost.container, belowSubview: hintLabel)
        newHost.onFirstContent = { [weak self] in self?.handleFirstContent() }
        applyContentLayout()
        newHost.startSyncing()
        AevonLog.info("[场景] 已切换到主场景承载（回退完成）（AevonSelfSceneFallbackV228）")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 缩放进行中不允许布局（手势只会改 transform，走到这里说明有外部触发，
        // 一旦在这里改内部几何就又退回到卡顿的老路，直接跳过）
        if isLiveResizing { return }

        if contentClip.frame != bounds {
            contentClip.frame = bounds
        }
        applyContentLayout()
    }

    /// 触摸落在本窗口时把自己提到最前（多窗重叠时点哪个哪个在上）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, let superview = superview, superview.subviews.last !== self {
            superview.bringSubviewToFront(self)
        }
        return hit
    }

    /// V0.0.38（AevonOutsideHitV38）：外侧手势区的命中修复。
    ///
    /// UIKit 的 pointInside 只认 bounds 内的点 —— 边条 / 外角块的 frame 全在窗外，
    /// 显示没问题（clipsToBounds = false），但触摸永远命中不到（V0.0.37 真机复现：
    /// 窗内 ✕ 正常、窗外移动 / 缩放手势全失效）。这里把命中区扩成
    /// 「窗口 bounds ∪ 所有手柄 frame」；手柄之外仍不拦，底下 App 的触摸照常穿透。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        for handle in subviews where handle is AevonEdgeHandleView {
            if !handle.isHidden, handle.alpha > 0.01, handle.frame.contains(point) {
                return true
            }
        }
        return false
    }

    /// 把 App 场景容器**原生铺进**内容区（V0.2.24，AevonFloatSceneLayoutV224）。
    ///
    /// Aevon(108) 用户定档：不要等比缩放的内容 ——「那不是真正的 5:3 窗口内容」。
    /// 采用 PullOverX 的方案（applyPreferredSceneFrame / videoAppliedHostedFrameSize 体系，
    /// 其偏好文案「选中的应用始终保持原始比例，不改变卡片尺寸」反向证明默认行为）：
    /// **App 场景本身的尺寸 = 浮窗尺寸**，App 按原生 5:3 重新布局，无 transform、
    /// 无拉伸、无裁切、无黑边 —— 窗口里看到的就是一个真正的 5:3 窗口内容。
    /// 顺带消掉逐帧矩阵提交（0.2.23 移动/缩放卡顿的渲染侧根源）。
    ///
    /// V0.2.25（AevonFloatHostedResizeV225）：0.2.24 缺了最后一环 —— 呈现上下文没开
    /// resizesHostedContext，App 场景收到不到新尺寸（Aevon(109) 日志：呈现视图 430x932），
    /// 内容仍是全屏渲染被裁。开关已在 AevonPresenterShim 补设（PullOver-X 同款），
    /// 这里改容器 bounds → presentationView（flexible autoresizing）→ App 原生重排全链路才通。
    ///
    /// V0.2.26（AevonPiPProbeV226）定论修订：V225 的「开关补上就通」判断**被实锤推翻**
    /// —— Aevon(1) 日志呈现视图仍 430x932，且 0.0.x 档案（V63/V64/V87）早已证明
    /// SB 侧事后改场景尺寸不触发 App 重排（resizesHostedContext 的调用对象是 scene
    /// settings，只在自建场景上有效）。当前内容形态 = 整屏渲染顶左裁切（诚实标注），
    /// 真重排唯一通路 = 自建场景路线（P0 探测见 probeSceneRoutesOnce）。
    /// 本函数保持容器 bounds = 窗口尺寸：呈现视图几何跟窗，缩放快照（V226）以此为基。
    ///
    /// V0.2.43（AevonCanvasScaleV243）：容器不再是「窗口尺寸」，而是**画布尺寸**。
    /// 画布 = 窗口 × k（见 canvasSize(for:)），再把容器整体 scale(1/k) 缩回窗口大小：
    /// App 按 k 倍宽的逻辑画布排版（字变小、内容变多），合成时等比缩小铺满窗口。
    /// 因为画布与窗口同为 5:3，1/k 缩放正好 1:1 贴合 —— 不拉伸、不留边。
    /// 触摸不受影响：UIKit 命中测试会按 transform 逆变换回画布坐标再转发给 App 进程。
    /// （这里对容器施加的是**静态**矩阵，不是逐帧改的窗口矩阵，不触发 0.2.23 的卡顿路径。）
    private func applyContentLayout() {
        guard contentClip.bounds.width > 0, contentClip.bounds.height > 0 else { return }
        let container = sceneHost.container
        let canvas = AevonWindowView.canvasSize(for: contentClip.bounds.size)
        let k = canvas.width / contentClip.bounds.width
        let target = CGRect(origin: .zero, size: canvas)
        let shrink = CGAffineTransform(scaleX: 1.0 / k, y: 1.0 / k)
        if container.bounds.size != target.size || container.transform != shrink {
            container.transform = .identity
            container.bounds = target
            container.layer.anchorPoint = .zero
            container.layer.position = .zero
            container.transform = shrink
        }
        // 画布变了（首次布局 / 滑杆改了倍数 / 缩放手势提交）→ 场景跟着改画布，
        // App 才会按新尺寸真正重排（而不是被拉伸）。
        if canvas != appliedCanvasSize {
            appliedCanvasSize = canvas
            sceneHost.resizeCanvasTo(width: canvas.width, height: canvas.height)
        }
    }

    // MARK: - 外侧手势区（V0.0.37，AevonSthenoEdgeBarV37）

    /// 手势全部挂在窗口 frame **外面**（Stheno：手势区域为边缘外侧），
    /// 窗内一个点都不占，App 内容的点击 / 滑动完全不受影响。
    /// 注意：窗口本体 clipsToBounds = false，frame 外的子视图照常参与命中测试。
    ///
    /// V0.2.21（AevonFloat53V221）手势位：角块 + 边条；V0.2.24 压边 10pt。
    ///
    /// V0.2.26（AevonFloatSthenoEdgeV226）：热区布置照抄 Stheno —— 竖屏顶/底两条全宽边条。
    ///
    /// V0.2.27（AevonFloatEdgeGripV227）：Aevon(1).(1) 用户定档再改 ——
    /// ① 顶边条**删除**（顶部不要任何手势）；② 左右两侧补回类似顶部的边条；
    /// ③ 移动手势**落指即拖**：不再长按 0.3s，指尖在热区里一动窗口就跟着走
    ///    （pan 识别器约 10pt 位移即 began，等效落指接管）。
    /// 功能保留我们自己的：边条拖动 = 移动、底边双击 = 关闭、角块 = 缩放。
    private func installOutsideGestureHandles(width: CGFloat, height: CGFloat) {
        let b = AevonWindowView.barThickness
        let c = AevonWindowView.cornerSize
        let o = AevonWindowView.gripOverlap
        let handles: [(UIRectEdge, CGRect, UIView.AutoresizingMask)] = [
            // 两个下角块（缩放）：窗外 c + 向窗内压边 o。
            ([.bottom, .left],  CGRect(x: -c, y: height - o, width: c + o, height: c + o),
             [.flexibleTopMargin]),
            ([.bottom, .right], CGRect(x: width - o, y: height - o, width: c + o, height: c + o),
             [.flexibleLeftMargin, .flexibleTopMargin]),
            // 底边条（落指即拖移动 + 双击关闭）：全宽铺进两角块之间
            ([.bottom],         CGRect(x: o, y: height - o, width: max(0, width - 2 * o), height: b + o),
             [.flexibleWidth, .flexibleTopMargin]),
            // 左 / 右边条（落指即拖移动）：V0.2.27 新增（用户定档：顶部删除、左右补回）。
            // 高度止于角块上缘（height - c），与角块不重叠。
            ([.left],           CGRect(x: -b, y: 0, width: b + o, height: max(0, height - c)),
             [.flexibleHeight]),
            ([.right],          CGRect(x: width - o, y: 0, width: b + o, height: max(0, height - c)),
             [.flexibleLeftMargin, .flexibleHeight]),
        ]
        for (edges, rect, mask) in handles {
            guard rect.width > 0, rect.height > 0 else { continue }
            let handle = AevonEdgeHandleView(frame: rect)
            handle.edges = edges
            handle.backgroundColor = .clear
            if !mask.isEmpty { handle.autoresizingMask = mask }
            addSubview(handle)
            // V0.2.27（AevonFloatEdgeGripV227）：角块与边条统一走 pan ——
            // 边条不再用 UILongPressGestureRecognizer（0.3s 长按版已退休，
            // 标记 AevonFloatBarLongPressV221 收容在 AevonAssertionShim.m）。
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOutsidePan(_:)))
            handle.addGestureRecognizer(pan)
            if edges == .bottom {
                // 底边双击 = 关闭浮窗（V0.2.21，AevonFloatBottomDblCloseV221）。
                // 与落指即拖共存：pan 需要约 10pt 位移才 began，双击原地点两下不会触发拖动。
                let doubleTap = UITapGestureRecognizer(target: self,
                                                       action: #selector(handleBottomDoubleTap(_:)))
                doubleTap.numberOfTapsRequired = 2
                handle.addGestureRecognizer(doubleTap)
            }
        }
    }

    /// 外侧手势的统一入口：角块 → 缩放；边条 → 落指即拖移动（V0.2.27）。
    @objc private func handleOutsidePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? AevonEdgeHandleView else { return }
        if handle.isCorner {
            handleCornerResize(gesture, edges: handle.edges)
        } else {
            handleBarPan(gesture)
        }
    }

    /// 边条拖动 = 移动窗口（V0.2.27 落指即拖，AevonFloatEdgeGripV227）。
    /// pan .began（约 10pt 位移）即接管，之后 .changed 连续跟手，与全局通道共用 applyBarMove。
    @objc private func handleBarPan(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            isBarHoldMoving = true
            moveOriginFrame = frame
            moveOriginPoint = point
            AevonLog.info("[窗口] 边条落指即拖 → 移动（AevonFloatEdgeGripV227）")
        case .changed:
            guard isBarHoldMoving else { break }
            applyBarMove(to: point)
        case .ended, .cancelled, .failed:
            guard isBarHoldMoving else { break }
            isBarHoldMoving = false
            applyBarMove(to: point)
            persistFrame()
        default:
            break
        }
    }

    // MARK: - 全局触摸驱动（V0.0.41，AevonFloatGlobalV41）

    /// 当前正被全局通道拖着的手柄（nil = 没在拖）
    private(set) var activeGrab: AevonFloatGrab?

    /// 命中判定。`layerPoint` 是**浮窗层（屏幕）坐标**。
    ///
    /// 为什么命中判定要能被外面调用：Aevon(34) 真机证据是「桌面上浮窗手势正常、
    /// 全屏 App 里完全无效」—— 同一个视图层代码，差别只在事件来源。全屏 App 时
    /// `SBDeviceApplicationSceneViewController.view` 的命中测试根本不把窗外的点交给我们
    /// （V0.0.23 就已确认这个黑洞，圆盘正是靠 `UIApplication -sendEvent:` 才活下来的），
    /// 于是手柄的 pan 永远不 begun。既然事件总入口可靠，命中判定就得从这里也能走。
    func grab(at layerPoint: CGPoint) -> AevonFloatGrab? {
        guard let parent = superview else { return nil }
        let local = convert(layerPoint, from: parent)

        for handle in subviews.compactMap({ $0 as? AevonEdgeHandleView }) {
            guard !handle.isHidden, handle.alpha > 0.01 else { continue }
            if handle.frame.contains(local) {
                return handle.isCorner ? .corner(handle.edges) : .bar(handle.edges)
            }
        }
        return nil
    }

    /// 开始一段外部驱动的拖拽。`layerPoint` = 浮窗层（屏幕）坐标。
    func grabBegin(_ grab: AevonFloatGrab, at layerPoint: CGPoint) {
        guard let parent = superview else { return }
        switch grab {
        case .bar:
            activeGrab = grab
            moveOriginFrame = frame
            moveOriginPoint = layerPoint
        case .corner(let edges):
            activeGrab = grab
            resizeOriginFrame = frame
            resizeOriginPoint = layerPoint
            resizeOriginEdges = edges
            // 锚点取「不动的那些边」的交点：拖右 → 锚在左（x=0）；拖左 → 锚在右（x=1）
            let ax: CGFloat = edges.contains(.left) ? 1.0
                : (edges.contains(.right) ? 0.0 : 0.5)
            let ay: CGFloat = edges.contains(.top) ? 1.0
                : (edges.contains(.bottom) ? 0.0 : 0.5)
            beginLiveResize(anchor: CGPoint(x: ax, y: ay))
        }
        parent.bringSubviewToFront(self)
    }

    /// 拖动中。`layerPoint` = 浮窗层（屏幕）坐标。
    func grabUpdate(to layerPoint: CGPoint) {
        guard let grab = activeGrab else { return }
        switch grab {
        case .bar:
            applyBarMove(to: layerPoint)
        case .corner(let edges):
            applyCornerResize(to: layerPoint, edges: edges)
        }
    }

    /// 抬手。`commit` = false 表示这段拖拽被取消（不落盘几何、不关窗）。
    func grabEnd(at layerPoint: CGPoint, commit: Bool) {
        guard let grab = activeGrab else { return }
        activeGrab = nil
        switch grab {
        case .bar:
            applyBarMove(to: layerPoint)
            // V0.1.5（AevonNoSnapV105）：贴边吸附已移除，松手就是松手，几何原样落盘。
            persistFrame()
        case .corner(let edges):
            applyCornerResize(to: layerPoint, edges: edges)
            finishEdgeResize()
        }
    }

    /// 取消当前拖拽（超时 / 系统打断）：缩放退回原几何，移动不落盘。
    func grabCancel() {
        guard let grab = activeGrab else { return }
        activeGrab = nil
        switch grab {
        case .bar:
            frame = moveOriginFrame
        case .corner:
            if isLiveResizing {
                isLiveResizing = false
                removeResizeSnapshot()
                transform = .identity
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                frame = resizeOriginFrame
                setNeedsLayout()
            }
        }
    }

    /// 底边双击 = 关闭浮窗（V0.2.21，AevonFloatBottomDblCloseV221）。
    /// 原「顶部双击恢复默认大小与位置」随顶部手势区一起移除（0.2.21 用户定档；
    /// 其 CI 历史串 AevonRestoreDefaultV101 收容在 AevonAssertionShim.m）。
    @objc private func handleBottomDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !isLiveResizing, !isBarHoldMoving else { return }
        guard let handle = gesture.view as? AevonEdgeHandleView,
              handle.edges == .bottom else { return }
        AevonLog.info("[窗口] 底边双击 → 关闭浮窗（AevonFloatBottomDblCloseV221）")
        closeTapped()
    }

    // MARK: - 边条移动

    /// 移动的纯计算部分（V0.0.41 拆出来）：长按拖动与全局通道共用同一套夹边逻辑。
    private func applyBarMove(to point: CGPoint) {
        let dx = point.x - moveOriginPoint.x
        let dy = point.y - moveOriginPoint.y
        let screen = UIScreen.main.bounds
        var center = CGPoint(x: moveOriginFrame.midX + dx, y: moveOriginFrame.midY + dy)
        // 至少留 60pt 在屏幕内，避免拖丢
        let halfW = moveOriginFrame.width / 2.0
        let halfH = moveOriginFrame.height / 2.0
        center.x = max(60 - halfW, min(center.x, screen.width - 60 + halfW))
        center.y = max(60 - halfH, min(center.y, screen.height - 60 + halfH))
        // 只改 center：bounds 不变，UIKit 不会触发 layoutSubviews
        self.center = center
    }

    // MARK: - 外角缩放（V0.0.36 起，V0.0.37 移到窗外角块）

    /// 外角块的缩放手势。
    ///
    /// 缩放锚点 = 对角的固定点（拖右下角 → 左上角不动），手势期间只改
    /// 外层 `transform`（V0.0.12 的零布局思路），抬手才提交真实 frame。
    private func handleCornerResize(_ gesture: UIPanGestureRecognizer, edges: UIRectEdge) {
        guard superview != nil else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            resizeOriginFrame = frame
            resizeOriginPoint = point
            resizeOriginEdges = edges
            // 锚点取「不动的那些边」的交点：拖右 → 锚在左（x=0）；拖左 → 锚在右（x=1）；
            // 只拖上下 → x 居中；y 同理。
            let ax: CGFloat = edges.contains(.left) ? 1.0
                : (edges.contains(.right) ? 0.0 : 0.5)
            let ay: CGFloat = edges.contains(.top) ? 1.0
                : (edges.contains(.bottom) ? 0.0 : 0.5)
            beginLiveResize(anchor: CGPoint(x: ax, y: ay))

        case .changed:
            applyCornerResize(to: point, edges: edges)

        case .ended, .cancelled, .failed:
            finishEdgeResize()

        default:
            break
        }
    }

    /// 缩放的纯计算部分（V0.0.41 拆出来）：只动外层矩阵，pan 与全局通道共用。
    private func applyCornerResize(to point: CGPoint, edges: UIRectEdge) {
        let dx = point.x - resizeOriginPoint.x
        let dy = point.y - resizeOriginPoint.y
        let width = clampedCornerWidth(dx: dx, dy: dy, base: resizeOriginFrame, edges: edges)
        let factor = max(0.05, width / max(1, resizeOriginFrame.width))
        // 只动外层矩阵，内部的 App 画面图层树完全不碰
        transform = CGAffineTransform(scaleX: factor, y: factor)
    }

    /// 只有「宽度」一个自由度：高度 = 宽度 × 5/3（高:宽 = 5:3，AevonFloat53V221）。
    /// 横向按 dx（拖左角反向），纵向按 dy（拖顶角反向）；
    /// 角块横竖都在动，取变化更明显的那个方向，斜拖也跟手，拖不出细长条。
    private func clampedCornerWidth(dx: CGFloat, dy: CGFloat, base: CGRect,
                                    edges: UIRectEdge) -> CGFloat {
        let aspect = AevonWindowView.contentAspect
        let screen = UIScreen.main.bounds

        var width: CGFloat? = nil
        if edges.contains(.left) || edges.contains(.right) {
            let signed = edges.contains(.left) ? -dx : dx
            width = base.width + signed
        }
        if edges.contains(.top) || edges.contains(.bottom) {
            let signed = edges.contains(.top) ? -dy : dy
            let widthFromY = (base.height + signed) * aspect
            width = width.map { current in
                abs(dx) >= abs(dy) ? current : widthFromY
            } ?? widthFromY
        }
        var result = width ?? base.width
        // 上限：不超屏高 92%，宽度不超屏宽 95%
        let maxWidth = max(AevonWindowView.minContentWidth,
                           min(screen.width * 0.95, screen.height * 0.92 * aspect))
        result = max(AevonWindowView.minContentWidth, min(result, maxWidth))
        return result
    }

    /// 进入「实时缩放」：锚点挪到固定点，内部一个属性都不动。
    /// V0.2.24（AevonFloatRoundResizeV224）：Aevon(108) 反馈缩放中四角变直角 ——
    /// 不再临时关圆角/裁剪（圆角全程保持，场景原生布局后离屏合成成本也可控）。
    /// V0.2.26（AevonFloatSnapResizeV226）：Aevon(1) 反馈缩放依旧卡顿 ——
    /// 实时内容是跨进程远程图层（整屏 430×932@3x），每帧都被圆角掩膜重采样，
    /// 这是卡顿的根源。手势开始时把当前画面冻结成一张静态图接管显示
    /// （PullOverX freezeVideoFrameForInteraction / setInteractiveRenderingPerformanceMode
    /// 同款），抬手恢复真实内容 —— 逐帧成本从「远程大表面+掩膜」降为「一张本地小图」。
    private func beginLiveResize(anchor: CGPoint) {
        isLiveResizing = true
        resizeAnchor = anchor
        installResizeSnapshot()
        // 改锚点后必须立刻补位置，否则窗口会跳：position = 固定点在父视图的坐标
        let fixed = CGPoint(x: frame.origin.x + anchor.x * frame.width,
                            y: frame.origin.y + anchor.y * frame.height)
        layer.anchorPoint = anchor
        layer.position = fixed
    }

    // MARK: - 缩放快照冻结（V0.2.26，AevonFloatSnapResizeV226；V0.2.27 缓存化 AevonFloatSnapCacheV227）

    private var resizeSnapshotView: UIImageView?
    /// 空闲时预抓的内容快照（V0.2.27，AevonFloatSnapCacheV227）
    private var cachedSnapshotImage: UIImage?
    private var snapshotRecaptureWork: DispatchWorkItem?

    /// 抓一帧内容区当前画面，并校验非空（远程表面抓取可能得到全透明图 —— 4×4 采样 alpha）。
    /// 只在空闲路径调用；缩放手势 .began 上绝不做同步渲染。
    private func captureSnapshotImage() -> UIImage? {
        let bounds = contentClip.bounds
        guard bounds.width > 1, bounds.height > 1, !isLiveResizing else { return nil }
        var image: UIImage?
        let exception = AevonShieldRun { [weak self] in
            guard let self else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = self.contentClip.layer.contentsScale
            let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
            image = renderer.image { ctx in
                self.contentClip.layer.render(in: ctx.cgContext)
            }
        }
        guard exception == nil, let image, image.size.width > 1, let cg = image.cgImage else { return nil }
        // 有效性校验：缩到 4×4 读 alpha，全透明 = 抓取失败（返回 nil，调用方走兜底）
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        if let ctx = CGContext(data: &pixels, width: 4, height: 4, bitsPerComponent: 8,
                               bytesPerRow: 4 * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            var maxAlpha: UInt8 = 0
            for i in stride(from: 3, to: pixels.count, by: 4) { maxAlpha = max(maxAlpha, pixels[i]) }
            if maxAlpha <= 8 { return nil }
        }
        return image
    }

    /// 空闲时预抓快照进缓存（窗口创建后首帧、每次缩放提交后各一次）。
    private func scheduleSnapshotRecapture(after delay: TimeInterval = 0.6) {
        snapshotRecaptureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isLiveResizing, !self.isBarHoldMoving,
                  self.hintLabel.isHidden else { return }
            self.cachedSnapshotImage = self.captureSnapshotImage()
        }
        snapshotRecaptureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 缩放开始时把当前画面冻结成静态图盖在最上层。
    ///
    /// V0.2.27（AevonFloatSnapCacheV227）：0.2.26 的两处残余卡顿都在这里修 ——
    /// ① 手势 .began 上同步 layer.render 整屏 430×932@3x（主线程几百毫秒的起手顿挫）
    ///    → 改为**空闲时预抓进缓存**，落指时直接用图，零同步渲染；
    /// ② 快照盖在上面但 contentClip（远程大表面 + 圆角掩膜）仍在逐帧合成，GPU 没省
    ///    → 快照有效时**隐藏 contentClip**，逐帧合成从远程大表面降为一张本地小图。
    /// 兜底：缓存未就绪才现场抓一帧（0.2.26 行为）；抓不到（全透明/异常）→ 不盖快照
    /// 也不隐藏实时内容，行为退回 0.2.25，绝不黑屏。
    private func installResizeSnapshot() {
        guard resizeSnapshotView == nil else { return }
        let bounds = contentClip.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        var image = cachedSnapshotImage
        if image == nil { image = captureSnapshotImage() }
        guard let image else { return }
        let snapshot = UIImageView(image: image)
        snapshot.frame = contentClip.frame
        snapshot.contentMode = .scaleToFill
        snapshot.layer.cornerRadius = AevonWindowView.cornerRadius
        snapshot.layer.masksToBounds = true
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        addSubview(snapshot)
        resizeSnapshotView = snapshot
        contentClip.isHidden = true
    }

    private func removeResizeSnapshot() {
        contentClip.isHidden = false
        resizeSnapshotView?.removeFromSuperview()
        resizeSnapshotView = nil
    }

    /// 抬手：把矩阵换成真实 frame，只在这一下做一次完整布局。
    private func finishEdgeResize() {
        guard isLiveResizing else { return }
        let factor = max(0.05, transform.a)
        isLiveResizing = false
        removeResizeSnapshot()

        let anchor = resizeAnchor
        transform = .identity
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect
        var width = max(AevonWindowView.minContentWidth,
                        min(resizeOriginFrame.width * factor, screen.width * 0.95))
        width = min(width, screen.height * 0.92 * aspect)
        let height = width / aspect

        // 固定点 = 原始 frame 里锚点对应的那一点；新 frame 以它为基准反推 origin
        let fixed = CGPoint(x: resizeOriginFrame.minX + anchor.x * resizeOriginFrame.width,
                            y: resizeOriginFrame.minY + anchor.y * resizeOriginFrame.height)
        var origin = CGPoint(x: fixed.x - anchor.x * width,
                             y: fixed.y - anchor.y * height)
        // 夹回屏幕：窗口至少留 60pt 在屏内，顶部至少 24pt 可见
        origin.x = max(60 - width, min(origin.x, screen.width - 60))
        origin.y = max(24 - height + 60, min(origin.y, screen.height - 60))
        frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        setNeedsLayout()
        persistFrame()
        // V0.2.28（AevonSelfSceneV228）：自建场景 → 提交新画布 = App 按新尺寸真重排
        // （这是缩放的根治：不再是整屏渲染缩放，而是 App 原生布局到新尺寸）。
        // V0.2.43（AevonCanvasScaleV243）：窗口尺寸 × k = 场景画布；主场景（S2）与
        // 自建场景走同一条提交路径。先记下已提交的画布，layoutSubviews 不再重复写。
        let canvas = AevonWindowView.canvasSize(for: CGSize(width: width, height: height))
        appliedCanvasSize = canvas
        sceneHost.resizeCanvasTo(width: canvas.width, height: canvas.height)
        // V0.2.27（AevonFloatSnapCacheV227）：尺寸已提交，旧快照作废，空闲后重抓
        cachedSnapshotImage = nil
        scheduleSnapshotRecapture(after: 0.8)
        AevonLog.info("[窗口] 缩放到 \(Int(width))x\(Int(height))（AevonEdgeResizeV37）")
    }

    // MARK: - 顶层置顶

    /// 把窗口提到最前（面板里的「已开窗口」点名称时用）。
    func bringToFront() {
        guard let superview = superview else { return }
        superview.bringSubviewToFront(self)
    }

    // MARK: - 窗口几何记忆（V0.0.37，AevonMedusaFrameV37）

    /// Stheno 方案：全局一份几何记忆（对应其 medusaFrameLast / _leftPecentLast 体系），
    /// 存屏幕百分比（left / top / width），换机型 / 旋转后依然成立。
    /// 所有浮窗共享 —— 下一个开的窗就是上一个关的窗的位置与大小。
    private static func rememberedFrame(fallback: CGRect) -> CGRect {
        guard let store = UserDefaults(suiteName: prefsSuite),
              let raw = store.array(forKey: frameMemoryKey) as? [Double],
              raw.count >= 3 else { return fallback }

        let screen = UIScreen.main.bounds
        let aspect = contentAspect
        let width = max(minContentWidth,
                        min(screen.width * CGFloat(raw[2]) / 100.0, screen.width * 0.95))
        let height = width / aspect
        let x = max(0, min(screen.width * CGFloat(raw[0]) / 100.0, screen.width - 60))
        let y = max(0, min(screen.height * CGFloat(raw[1]) / 100.0, max(0, screen.height - 60)))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func persistFrame() {
        guard !isLiveResizing, transform.isIdentity else { return }
        guard let store = UserDefaults(suiteName: AevonWindowView.prefsSuite) else { return }
        let screen = UIScreen.main.bounds
        guard screen.width > 1, screen.height > 1, frame.width > 1 else { return }
        let xp = Double(frame.minX / screen.width * 100.0)
        let yp = Double(frame.minY / screen.height * 100.0)
        let wp = Double(frame.width / screen.width * 100.0)
        store.set([xp, yp, wp], forKey: AevonWindowView.frameMemoryKey)
    }

    // MARK: - 关闭

    @objc private func closeTapped() {
        AevonWindowManager.close(bundleID: bundleID)
    }

    func teardown() {
        // 关窗前把最终位置记下来
        persistFrame()
        selfSceneFallbackTimer?.invalidate()
        selfSceneFallbackTimer = nil
        // 必须先 invalidate 承载容器再拆视图，否则容器 dealloc 会抛
        // NSInternalInconsistencyException: Must be invalidated before deallocating
        sceneHost.onFirstContent = nil
        sceneHost.invalidate()
        sceneHost.container.removeFromSuperview()
        removeFromSuperview()
    }
}
