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

/// 浮窗上被按住的位置（V0.0.44，AevonSthenoGestureV44）。
///
/// 全局触摸通道拿不到 `UIPanGestureRecognizer`，只能拿到坐标，所以命中结果用这个
/// 枚举交给浮窗自己决定「这次拖动是移动 / 缩放 / 关闭」。
enum AevonFloatGrab {
    /// 左右侧条：拖动 = 移动窗口；轻点 = 停靠到该侧变小窗 / 已停靠则还原主窗
    case side(UIRectEdge)
    /// 下方角块 → 从对角缩放
    case corner(UIRectEdge)
    /// 底边条：拖动 = 移动窗口；双击 = 关闭浮窗
    case bottom
}

/// 单个 App 的浮窗外壳：纯内容（无标题栏）+ 右上悬浮 ✕ + 贴窗外边缘的手势区。
///
/// V0.0.9：App 场景按整屏尺寸渲染，浮窗只对承载容器做等比缩放。
/// V0.0.11：内容区宽高比锁定屏幕比例。
/// V0.0.12：手势期间只改外壳 `layer.transform`，抬手才提交真实 frame。
/// V0.0.13：窗口大小/位置记忆 + 双击切换大小档。
/// V0.0.14：拖到屏幕边缘自动吸附（左半屏 / 右半屏 / 顶部放大）。
/// V0.0.36：四周 8 向缩放（当时在窗内）。
/// V0.0.37（AevonSthenoEdgeBarV37）：按 Stheno 逆向证据重做手势体系 ——
///   手势区域**只在浮窗边缘外侧**（EdgeBarControlView / GestureIntroduction
///   「浮窗手势区域为边缘外侧…」），窗内 100% 留给 App 内容：
///     · 拖四条**边条**（外侧）＝ 移动窗口；
///     · 拖四个**外角块** ＝ 缩放（对角锚定，比例锁定）；
///     · 双击任意边条 ＝ 小窗 / 大窗切换；
///     · 右上角悬浮 ✕ ＝ 关闭；
///     · 拖到屏幕边缘松手仍自动吸附。
///   顶部标题栏（拖动条 + 关闭钮）整条移除（用户要求）。
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
/// V0.0.42（AevonSthenoDockV42 / AevonFloatLookV42）：按 Stheno 主浮窗的模型重做观感与几何 ——
///   · 圆角随内容缩放同比（取其 `_displayCornerRadius` * radiusLast 的思路），加投影 + 细描边；
///   · 停靠（吸附）只靠边、不改尺寸（对应 Stheno leftPecent/rightPecent/heightPecent）；
///   · 四边恒定留 `AevonSnap.edgeInset`（= 外角块 34pt），窗口永远抓得到缩放手柄。
///   Aevon(35) 日志里 `吸附到顶部放大 407x884`（屏 430x932）导致四角出屏、再也缩放不了。
/// V0.0.43（AevonSthenoGestureV43）：用户按 Stheno 实机观感重定义手势与几何 ——
///   · 顶部（顶边条 + 两个上角块 + 右上 ✕）全部移除，顶部不再有任何手势区；
///   · 左右**侧条**：长按 / 直接拖 = 移动；**轻点 = 吸附到该侧并变成小窗**；
///   · **底边条：双击 = 关闭浮窗**（原 ✕ 的替代出口）；
///   · 只保留两个**下角块**做缩放；
///   · 贴边距离 34pt → 5pt；默认窗宽 70% → 55%；停靠尺寸固定为 50% 屏宽的小窗。
///   关键：窗口贴到屏幕边上时，外侧手柄会整条滑出屏外（5pt 只剩 5pt 可点），
///   所以 `layoutGestureHandles()` 会按「该边离屏边多远」把对应手柄改挂到窗**内侧**，
///   保证任何位置都抓得到 —— 否则一贴边就再也拖不回来。
/// V0.0.44（AevonSthenoGestureV44）：
///   · 内容可视区去掉顶部状态栏那条空白（宿主不画状态栏 → 窗口顶部一大块空白、
///     整体变成竖长条，Aevon(37) 的观感问题）；
///   · 缩放改成每帧直接改 frame（AevonLiveResizeV44）—— 不再用 transform，
///     缩放过程圆角始终保留、画面全程实时，不再有「贴图快照 → 突然跳实时」的卡顿；
///   · 轻点已停靠的侧条 = 还原主悬浮窗（AevonDockRestoreV44）；
///   · 底边条加宽到 30pt，拖动 = 移动，双击 = 关闭；
///   · 浮窗之间自动避让（AevonDockAvoidV44），停靠小窗不再压住主窗的手势条；
///   · 四周加一圈 0.9pt / 白色 34% 的描边（AevonFloatEdgeGlowV44），深色背景也看得清边界。
final class AevonWindowView: UIView {
    let bundleID: String
    private let sceneHost: AevonSceneHost

    /// 内容可视区宽高比 = 屏宽 ÷（屏高 − 顶部状态栏空白）。见 `AevonSnap.aspect`。
    ///
    /// V0.0.44：不再用整屏比例。宿主不画状态栏，那条 59pt 在浮窗里是纯空白，
    /// 算进高度会把窗口拉成细长条（Aevon(37) 用户反馈「顶部空白很大」）。
    static var contentAspect: CGFloat { return AevonSnap.aspect }

    private static let minContentWidth: CGFloat = 150
    /// 左右侧条厚度（手势区）。Stheno 的 edgeWidth 同位概念。
    static let barThickness: CGFloat = 20
    /// 底边条厚度 V0.0.44：用户要求加宽底部手势热区（原 18pt 太窄不好按）
    static let bottomBarThickness: CGFloat = 30
    /// 外角块边长
    static let cornerSize: CGFloat = 36
    /// 命中判定外扩距离（取所有手柄里最大的那个厚度）
    static var maxHandleMargin: CGFloat { return max(barThickness, bottomBarThickness, cornerSize) }

    /// 设备屏幕圆角（Stheno 读了 `_displayCornerRadius`，这里同源）。
    /// iPhone 15 Pro Max ≈ 55pt；取不到时用 55 兜底（比小圆角更接近真机观感）。
    ///
    /// 注意：这个 getter 返回的是 CGFloat 而不是对象，`perform` 会把标量当指针返回，
    /// 所以只能走 KVC（KVC 按属性类型编码包装成 NSNumber），并且先查 responds(to:)。
    static let deviceCornerRadius: CGFloat = {
        let screen = UIScreen.main
        let key = "_displayCornerRadius"
        if screen.responds(to: NSSelectorFromString(key)),
           let number = screen.value(forKey: key) as? NSNumber,
           number.doubleValue > 1, number.doubleValue < 200 {
            return CGFloat(number.doubleValue)
        }
        return 55
    }()

    /// 浮窗圆角（V0.0.42，AevonFloatLookV42）。
    ///
    /// Stheno 的浮窗圆角随内容缩放同比变化（逆向键 `_radius` / `radiusLast` 与其
    /// `_displayCornerRadius` 同现）—— 内容缩小多少，圆角就缩小多少，视觉上才和
    /// 设备本身的圆角「同族」。写死 12pt 会让小窗看起来像方盒子。
    static func cornerRadius(forWidth width: CGFloat) -> CGFloat {
        let screen = UIScreen.main.bounds
        let screenWidth = max(1, screen.width)
        let scale = max(0.2, min(1.0, width / screenWidth))
        return max(14, min(deviceCornerRadius * scale * 0.75, 36))
    }

    /// 统一套圆角（V0.0.44）：拖动中每帧也会走这里，尺寸一变圆角立刻同步，
    /// 不会再出现「缩放时直角、抬手才圆」。
    static func applyRadius(to clip: UIView, width: CGFloat) {
        let radius = cornerRadius(forWidth: width)
        if abs(clip.layer.cornerRadius - radius) > 0.2 {
            clip.layer.cornerRadius = radius
        }
    }

    /// 投影浓度（拖动期间会被临时清零，抬手恢复）
    static let shadowOpacity: Float = 0.42

    /// 全局唯一的偏好域，和设置面板共用
    private static let prefsSuite = "com.Aevon"
    /// Stheno 式全局几何记忆键（medusaFrameLast 对应物）
    private static let frameMemoryKey = "MedusaFrameLast"

    private let contentClip = UIView()
    private let hintLabel = UILabel()

    /// V0.0.43：手势区只剩「左右侧条 + 底边条 + 两个下角块」。各自持有引用，
    /// 因为贴边时要按「离屏边多远」把它们从窗外挪到窗内（`layoutGestureHandles`）。
    private let leftBar = AevonEdgeHandleView(frame: .zero)
    private let rightBar = AevonEdgeHandleView(frame: .zero)
    private let bottomBar = AevonEdgeHandleView(frame: .zero)
    private let bottomLeftCorner = AevonEdgeHandleView(frame: .zero)
    private let bottomRightCorner = AevonEdgeHandleView(frame: .zero)
    private var gestureHandles: [AevonEdgeHandleView] {
        return [leftBar, rightBar, bottomBar, bottomLeftCorner, bottomRightCorner]
    }

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
    /// 上一次真正应用过的内容区尺寸与缩放系数（缓存，用来跳过无变化的布局）
    private var lastClipSize: CGSize = .zero
    private var lastAppliedScale: CGFloat = 0
    private var lastTopInset: CGFloat = 0

    /// 当前吸附槽位（自由位置 / 靠左 / 靠右 / 靠顶）
    private(set) var currentSlot: AevonSnapSlot = .free

    /// 停靠成小窗之前的几何（V0.0.44）：轻点已停靠的小窗时用它还原主悬浮窗
    private var preDockFrame: CGRect?

    /// 是否处于停靠状态（被别的浮窗当作「要避让的障碍」）
    var isDocked: Bool { return currentSlot != .free }

    init(sceneHost: AevonSceneHost, bundleID: String, title: String, slot: AevonSnapSlot = .free) {
        self.bundleID = bundleID
        self.sceneHost = sceneHost
        super.init(frame: CGRect.zero)

        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect

        // 分屏时用吸附槽位算位置；否则恢复 Stheno 式全局记忆（medusaFrameLast 方案）
        var sizeSource = "默认尺寸"
        let restored: CGRect
        if slot != .free {
            restored = AevonSnap.frame(for: slot, from: AevonWindowView.defaultFrame())
            currentSlot = slot
            sizeSource = "吸附\(AevonSnap.describe(slot))"
        } else {
            let fallback = AevonWindowView.defaultFrame()
            let remembered = AevonWindowView.rememberedFrame(fallback: fallback)
            restored = AevonSnap.clamped(remembered)
            if remembered != fallback { sizeSource = "已恢复上次几何（全局记忆）" }
        }

        // V0.0.44：新开的窗别压住已停靠的小窗（会盖住对方的手势条）
        let placed = AevonSnap.avoid(restored, obstacles: AevonEntryHost.dockedObstacles(excluding: nil))
        frame = CGRect(x: placed.minX, y: placed.minY,
                       width: placed.width, height: placed.height)

        backgroundColor = .clear
        // V0.0.37：窗口本体不裁剪 —— 外侧手势区要伸到 frame 外面；
        // 圆角裁剪由 contentClip 负责。
        clipsToBounds = false

        // V0.0.42（AevonFloatLookV42）：Stheno 观感 —— 投影 + 细描边 + 随缩放同比的圆角。
        // 投影走 shadowPath（每次 layout 更新），比让系统按 alpha 逐帧算便宜得多。
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = AevonWindowView.shadowOpacity
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 8)

        // 内容区（全高，无标题栏）。圆角 + 裁剪都在这一层。
        contentClip.frame = bounds
        contentClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentClip.clipsToBounds = true
        contentClip.layer.cornerRadius = AevonWindowView.cornerRadius(forWidth: restored.width)
        contentClip.layer.cornerCurve = .continuous
        // V0.0.44（AevonFloatEdgeGlowV44）：四周一圈浅白描边。
        // 用户 Aevon(37)：深色模式下浮窗和背景糊在一起，看不清边界 —— 太亮又刺眼，
        // 所以是 0.9pt、白色 34% 透明度，比 V0.0.43 的 0.5pt/14% 明显但不抢眼。
        contentClip.layer.borderWidth = 0.9
        contentClip.layer.borderColor = UIColor(white: 1.0, alpha: 0.34).cgColor
        contentClip.backgroundColor = UIColor(white: 0.10, alpha: 1.0)
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
            DispatchQueue.main.async {
                self?.hintLabel.isHidden = true
            }
        }

        // V0.0.43（AevonSthenoGestureV43）：顶部 ✕ 已移除（用户要求），
        // 关闭浮窗改成「底边手势区双击」。这里只装手势区，不加任何窗内控件 ——
        // 窗内 100% 留给 App 内容。
        installGestureHandles()
        layoutGestureHandles()

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)"
            + "（无标题栏，侧条长按移动/轻点停靠或还原、底边拖动移动/双击关闭、下角缩放，"
            + "内容比例 \(String(format: "%.3f", aspect))（已去掉顶部状态栏空白），"
            + "内容 \(Int(restored.width))x\(Int(restored.height))，"
            + "\(sizeSource)）（AevonSthenoGestureV44）")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 无记忆时的默认几何（V0.0.43）：走 `AevonSnap.defaultFrame()` —— 屏宽 55%。
    private static func defaultFrame() -> CGRect {
        return AevonSnap.defaultFrame()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // V0.0.44：缩放改成「实时改 frame」，所以这里必须照常布局 ——
        // 以前缩放期间直接 return，正是「缩放中四角变直角、抬手才跳回圆角」的来源。
        if contentClip.frame != bounds {
            contentClip.frame = bounds
        }
        // 几何一变就重算手势区位置（贴边时改挂到窗内）
        layoutGestureHandles()
        // 圆角随尺寸走（Stheno radiusLast 体系）
        let radius = AevonWindowView.cornerRadius(forWidth: bounds.width)
        if abs(contentClip.layer.cornerRadius - radius) > 0.3 {
            contentClip.layer.cornerRadius = radius
        }
        // 拖动 / 缩放期间不做投影路径（每帧重建 bezier 是纯粹的浪费，且会被离屏合成）
        if !isLiveResizing {
            updateShadowPath()
        }
        applyContentScale()
    }

    /// 投影路径与圆角矩形严格一致，避免系统按 alpha 逐帧重算（滚动 App 画面时开销很大）
    private func updateShadowPath() {
        let radius = contentClip.layer.cornerRadius
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
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

    /// 把整屏尺寸的容器等比铺满内容区，并把顶部状态栏那条空白裁掉。
    ///
    /// V0.0.44（AevonSthenoDockV44）：`scale` 只由宽度决定，场景整体上移
    /// `visualTopInset * scale` —— 宿主 App 不画状态栏，那块在浮窗里是纯空白，
    /// 上移之后窗口顶部就是 App 真正的第一行内容（用户 Aevon(37) 的核心抱怨）。
    private func applyContentScale() {
        let screen = UIScreen.main.bounds.size
        guard screen.width > 0, screen.height > 0,
              contentClip.bounds.width > 0, contentClip.bounds.height > 0 else { return }

        let scale = contentClip.bounds.width / screen.width
        let topInset = AevonSnap.visualTopInset

        let clipSize = contentClip.bounds.size
        if abs(clipSize.width - lastClipSize.width) < 0.01,
           abs(clipSize.height - lastClipSize.height) < 0.01,
           abs(scale - lastAppliedScale) < 0.0001,
           abs(topInset - lastTopInset) < 0.5 {
            return
        }
        lastClipSize = clipSize
        lastAppliedScale = scale
        lastTopInset = topInset

        let container = sceneHost.container
        container.layer.anchorPoint = .zero
        container.bounds = CGRect(origin: .zero, size: screen)
        container.transform = CGAffineTransform(scaleX: scale, y: scale)
        container.layer.position = CGPoint(x: 0, y: -topInset * scale)
    }

    // MARK: - 手势区（V0.0.43，AevonSthenoGestureV43）

    /// 建立五个手势区并挂上（位置由 `layoutGestureHandles` 每次布局重算）：
    ///   · 左右侧条 → 长按/拖动 = 移动，轻点 = 停靠到该侧并变小窗；
    ///   · 底边条   → 双击 = 关闭浮窗；
    ///   · 两个下角块 → 拖动 = 对角缩放（顶部两个角块与顶边条按用户要求删除）。
    /// 全部不挂 `UIGestureRecognizer`：手势统一由全局触摸通道驱动
    /// （全屏 App 里视图层的识别器根本收不到窗外触摸，Aevon(34) 已确证）。
    private func installGestureHandles() {
        let specs: [(AevonEdgeHandleView, UIRectEdge)] = [
            (leftBar, [.left]),
            (rightBar, [.right]),
            (bottomBar, [.bottom]),
            (bottomLeftCorner, [.bottom, .left]),
            (bottomRightCorner, [.bottom, .right]),
        ]
        for (handle, edges) in specs {
            handle.edges = edges
            handle.backgroundColor = .clear
            addSubview(handle)
        }
    }

    /// 按窗口当前离屏幕四边多远，决定每个手势区挂在窗外还是窗内。
    ///
    /// 为什么必须动态：贴边距离现在只有 5pt，外侧条（18pt 宽）会整条滑出屏外 ——
    /// 窗口一旦贴到左边，左手就再也点不到它（V0.0.42 用户正是卡在「贴边后无法缩放」）。
    /// 规则很简单：某条边离屏边不足一个条宽，就把这条边的手柄改挂到窗**内侧**。
    private func layoutGestureHandles() {
        let b = AevonWindowView.barThickness
        let bb = AevonWindowView.bottomBarThickness
        let c = AevonWindowView.cornerSize
        let w = bounds.width
        let h = bounds.height
        guard w > 1, h > 1 else { return }
        let screen = UIScreen.main.bounds
        // frame 就是浮窗层坐标（= 屏幕坐标），直接算到屏边的距离
        let gapLeft = frame.minX
        let gapRight = screen.width - frame.maxX
        let gapBottom = screen.height - frame.maxY

        let sideInsetL: CGFloat = gapLeft < b ? 0 : -b
        let sideInsetR: CGFloat = gapRight < b ? w - b : w
        // 下角块是否也要挪进窗内（取决于横向/纵向是否贴边）
        let cornerInsetL: CGFloat = gapLeft < c ? 0 : -c
        let cornerInsetR: CGFloat = gapRight < c ? w - c : w
        let cornerY: CGFloat = gapBottom < c ? h - c : h

        // 侧条在底部给底边条留出整条空间（避免两套手势帧重叠）
        let sideHeight = max(40, h - bb)
        leftBar.frame = CGRect(x: sideInsetL, y: 0, width: b, height: sideHeight)
        rightBar.frame = CGRect(x: sideInsetR, y: 0, width: b, height: sideHeight)
        bottomLeftCorner.frame = CGRect(x: cornerInsetL, y: cornerY, width: c, height: c)
        bottomRightCorner.frame = CGRect(x: cornerInsetR, y: cornerY, width: c, height: c)

        // 底边条夹在两个下角块之间，厚度用 bottomBarThickness（用户要求加宽）
        let barLeft: CGFloat = gapLeft < c ? c : 0
        let barRight: CGFloat = gapRight < c ? w - c : w
        let barY: CGFloat = gapBottom < bb ? h - bb : h
        bottomBar.frame = CGRect(x: barLeft, y: barY,
                                 width: max(40, barRight - barLeft), height: bb)
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
        // 命中顺序：角块 → 底边条 → 左右侧条。角块最具体，先判；
        // 侧条帧比底边条长，放最后才不会把底边条整条吃掉。
        let order: [AevonEdgeHandleView] = [bottomLeftCorner, bottomRightCorner,
                                            bottomBar, leftBar, rightBar]
        for handle in order {
            guard !handle.isHidden, handle.alpha > 0.01 else { continue }
            guard handle.frame.contains(local) else { continue }
            if handle.isCorner { return .corner(handle.edges) }
            if handle === bottomBar { return .bottom }
            return .side(handle.edges)
        }
        return nil
    }

    /// 开始一段外部驱动的拖拽。`layerPoint` = 浮窗层（屏幕）坐标。
    func grabBegin(_ grab: AevonFloatGrab, at layerPoint: CGPoint) {
        guard let parent = superview else { return }
        activeGrab = grab
        switch grab {
        case .side, .bottom:
            // 只记基准，不动几何：要「越过阈值」才真正开始移动，
            // 轻点（侧条=停靠 / 底边=双击关闭）由全局通道判定后回调。
            moveOriginFrame = frame
            moveOriginPoint = layerPoint
        case .corner(let edges):
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

    /// 侧条 / 底边条越过了「算拖动」的阈值：把基准点重设到当前位置。
    /// 不重设的话第一帧就会把窗口瞬移一个阈值距离（10pt），手感发跳。
    func rebaseGrab(at layerPoint: CGPoint) {
        guard let grab = activeGrab else { return }
        switch grab {
        case .side, .bottom:
            moveOriginFrame = frame
            moveOriginPoint = layerPoint
        case .corner:
            break
        }
    }

    /// 拖动中。`layerPoint` = 浮窗层（屏幕）坐标。
    func grabUpdate(to layerPoint: CGPoint) {
        guard let grab = activeGrab else { return }
        switch grab {
        case .side, .bottom:
            applyBarMove(to: layerPoint)
        case .corner(let edges):
            applyCornerResize(to: layerPoint, edges: edges)
        }
    }

    /// 抬手。`commit` = false 表示这段拖拽被取消（不落盘几何）。
    func grabEnd(at layerPoint: CGPoint, commit: Bool) {
        guard let grab = activeGrab else { return }
        activeGrab = nil
        switch grab {
        case .side:
            applyBarMove(to: layerPoint)
            if commit, AevonPrefs.bool("SnapEnabled", default: true),
               let slot = AevonSnap.slot(for: frame) {
                snap(to: slot)
                return
            }
            persistFrame()
        case .corner:
            finishEdgeResize()
        case .bottom:
            // 底边拖动 = 移动（用户 Aevon(37) 的新交互），贴底不再自动吸附
            applyBarMove(to: layerPoint)
            persistFrame()
        }
    }

    /// 取消当前拖拽（超时 / 系统打断 / 侧条其实只是轻点）：几何退回原样，不落盘。
    func grabCancel() {
        guard let grab = activeGrab else { return }
        activeGrab = nil
        switch grab {
        case .side, .bottom:
            frame = moveOriginFrame
        case .corner:
            if isLiveResizing {
                isLiveResizing = false
                layer.shadowOpacity = AevonWindowView.shadowOpacity
                frame = AevonSnap.clamped(resizeOriginFrame)
                AevonWindowView.applyRadius(to: contentClip, width: frame.width)
                setNeedsLayout()
            }
        }
    }

    /// 移动的纯计算部分（V0.0.41 拆出来）：pan 手势与全局通道共用同一套夹边逻辑。
    ///
    /// V0.0.42（AevonSthenoDockV42）：夹边距离从原来的 60pt 改成 `AevonSnap.edgeInset`
    /// —— 拖到屏幕边上时窗口自动停在内侧，四个外角块始终留在屏内可抓。
    private func applyBarMove(to point: CGPoint) {
        let dx = point.x - moveOriginPoint.x
        let dy = point.y - moveOriginPoint.y
        let screen = UIScreen.main.bounds
        var center = CGPoint(x: moveOriginFrame.midX + dx, y: moveOriginFrame.midY + dy)
        let halfW = moveOriginFrame.width / 2.0
        let halfH = moveOriginFrame.height / 2.0
        let inset = AevonSnap.edgeInset

        let minX = inset + halfW
        let maxX = screen.width - inset - halfW
        center.x = maxX >= minX ? min(max(center.x, minX), maxX) : screen.width / 2.0

        let minY = inset + halfH
        let maxY = screen.height - inset - halfH
        center.y = maxY >= minY ? min(max(center.y, minY), maxY) : screen.height / 2.0

        // 只改 center：bounds 不变，UIKit 不会触发 layoutSubviews，
        // 所以手势区的内外位置要手动跟着重算（贴边时侧条要挪进窗内）
        self.center = center
        // V0.0.44：别压住已停靠的小窗 —— 它会盖住本窗的手势条，本窗就再也拖不动了
        let avoided = AevonSnap.avoid(frame, obstacles: AevonEntryHost.dockedObstacles(excluding: self))
        if abs(avoided.minX - frame.minX) > 0.5 || abs(avoided.minY - frame.minY) > 0.5 {
            self.frame = avoided
        }
        layoutGestureHandles()
    }

    // MARK: - 下角块缩放（V0.0.36 起，V0.0.37 移到窗外角块，V0.0.43 只保留下角）

    /// 缩放的纯计算部分：**每帧直接改 frame**，不再用 transform。
    ///
    /// V0.0.44（AevonLiveResizeV44）：V0.0.12 起的「只改 transform、抬手才提交 frame」
    /// 在真机上有两个副作用（Aevon(37) 用户反馈）：
    ///   · 缩放期间视图被离屏栅格化，画面先变成一张「贴图快照」，抬手那一刻才跳回实时；
    ///   · 抬手时 transform→identity + 新 frame + 圆角重设，一次性大重排看起来就是卡一下。
    /// 现在每帧直接改 frame：圆角、内容比例、描边全部同步，画面全程实时，四角始终是圆的。
    private func applyCornerResize(to point: CGPoint, edges: UIRectEdge) {
        let dx = point.x - resizeOriginPoint.x
        let dy = point.y - resizeOriginPoint.y
        let width = clampedCornerWidth(dx: dx, dy: dy, base: resizeOriginFrame, edges: edges)
        let height = AevonSnap.height(forWidth: width)

        // 固定点 = 原始 frame 里锚点对应的那一点；新 frame 以它为基准反推 origin
        let anchor = resizeAnchor
        let fixed = CGPoint(x: resizeOriginFrame.minX + anchor.x * resizeOriginFrame.width,
                            y: resizeOriginFrame.minY + anchor.y * resizeOriginFrame.height)
        var target = CGRect(x: fixed.x - anchor.x * width,
                            y: fixed.y - anchor.y * height,
                            width: width, height: height)
        target = AevonSnap.clamped(target)
        target = AevonSnap.avoid(target, obstacles: AevonEntryHost.dockedObstacles(excluding: self))
        frame = target
        AevonWindowView.applyRadius(to: contentClip, width: target.width)
    }

    /// 只有「宽度」一个自由度：高度 = 宽度 ÷ 屏幕比例。
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

    /// 进入「实时缩放」：只做两件事 —— 记锚点、暂时关投影，圆角与裁剪一律保留。
    private func beginLiveResize(anchor: CGPoint) {
        isLiveResizing = true
        resizeAnchor = anchor
        // 缩放期间关投影：带投影的活体场景在几何持续变化时会被离屏合成
        layer.shadowOpacity = 0
        // V0.0.44：圆角全程保留。以前这里把 cornerRadius 清 0 并关掉裁剪，
        // 于是「缩放中四角是直角、抬手才跳回圆角」——Aevon(37) 的第一个问题。
        contentClip.clipsToBounds = true
        AevonWindowView.applyRadius(to: contentClip, width: frame.width)
    }

    /// 抬手：收尾（几何已经在拖动过程中实时提交过，这里只做避让校正与落盘）。
    private func finishEdgeResize() {
        guard isLiveResizing else { return }
        isLiveResizing = false
        layer.shadowOpacity = AevonWindowView.shadowOpacity
        frame = AevonSnap.clamped(AevonSnap.avoid(frame,
                                                  obstacles: AevonEntryHost.dockedObstacles(excluding: self)))
        AevonWindowView.applyRadius(to: contentClip, width: frame.width)
        setNeedsLayout()
        persistFrame()
        AevonLog.info("[窗口] 缩放到 \(Int(frame.width))x\(Int(frame.height))"
            + "（圆角 \(Int(contentClip.layer.cornerRadius)) · 全程实时渲染）（AevonLiveResizeV44）")
    }

    // MARK: - 停靠 / 吸附

    /// 停靠到某一侧（V0.0.43：贴边 5pt + 换成停靠档小尺寸）。
    ///
    /// 两个入口共用：
    ///   · 拖侧条贴边松手 → 自动吸附（`grabEnd` 里按 `AevonSnap.slot(for:)` 判定）；
    ///   · 轻点左右侧条 → 直接停靠到那一侧（用户在 Aevon(36) 指定的新交互）。
    ///
    /// V0.0.44（AevonDockRestoreV44）：轻点已停靠在同一侧的小窗 = 还原成主悬浮窗，
    /// 不再需要「先拖动再缩放」才能变大（Aevon(37) 的第二个问题）。
    func snap(to slot: AevonSnapSlot) {
        guard slot != .free, !isLiveResizing else { return }
        var target = AevonSnap.frame(for: slot, from: frame)
        target = AevonSnap.avoid(target, obstacles: AevonEntryHost.dockedObstacles(excluding: self))
        guard target.width >= AevonSnap.minContentWidth, target.height > 0 else { return }

        // 目标与当前几乎一致就不折腾了（拖动松手时已经贴在位置上的情况）
        if abs(target.minX - frame.minX) < 0.5,
           abs(target.minY - frame.minY) < 0.5,
           abs(target.width - frame.width) < 0.5 {
            currentSlot = slot
            persistFrame()
            AevonEntryHost.avoidDockedWindow(self)
            return
        }

        currentSlot = slot
        UIView.animate(withDuration: 0.24,
                       delay: 0,
                       options: [UIView.AnimationOptions.beginFromCurrentState, .curveEaseOut]) {
            self.frame = target
        } completion: { _ in
            self.setNeedsLayout()
            self.persistFrame()
            // 小窗落下后通知其它窗让开，别压住别人的手势条
            AevonEntryHost.avoidDockedWindow(self)
        }
        AevonLog.info("[窗口] 停靠到\(AevonSnap.describe(slot)) \(Int(target.minX)),\(Int(target.minY)) "
            + "\(Int(target.width))x\(Int(target.height))"
            + "（贴边 \(Int(AevonSnap.edgeInset))pt · 停靠小窗）（AevonSthenoDockV44）")
    }

    /// 当前是不是停靠小窗（宽度等于停靠档）
    private var isDockedSize: Bool {
        return abs(bounds.width - AevonSnap.dockWidth) < 3
    }

    /// 轻点侧条（V0.0.44）：
    ///   · 未停靠 / 停靠在另一侧 → 贴到该侧并变小窗；
    ///   · **已停靠在同一侧 → 还原成主悬浮窗**（轻点即放大，不用再拖再缩）。
    func dock(to slot: AevonSnapSlot) {
        guard slot == .left || slot == .right else { return }
        if currentSlot == slot, isDockedSize {
            restoreMainWindow()
            return
        }
        // 只在「从自由状态进来」时记下原几何；已停靠时切换另一侧不能覆盖它，
        // 否则还原时会把小窗尺寸当成主窗尺寸。
        if !isDocked { preDockFrame = frame }
        snap(to: slot)
    }

    /// 还原成主悬浮窗尺寸，位置优先回到停靠前那一块。
    func restoreMainWindow() {
        let screen = UIScreen.main.bounds
        var target: CGRect
        if let previous = preDockFrame, previous.width > AevonSnap.minContentWidth {
            target = previous
        } else {
            target = AevonWindowView.defaultFrame()
        }
        // 停靠在左侧就保持贴左、右侧就保持贴右（用户的心智位置不变），但换成主窗尺寸
        if currentSlot == .left {
            target.origin.x = AevonSnap.edgeInset
        } else if currentSlot == .right {
            target.origin.x = screen.width - AevonSnap.edgeInset - target.width
        }
        target = AevonSnap.clamped(target)
        target = AevonSnap.avoid(target, obstacles: AevonEntryHost.dockedObstacles(excluding: self))

        preDockFrame = nil
        currentSlot = .free
        UIView.animate(withDuration: 0.26,
                       delay: 0,
                       options: [UIView.AnimationOptions.beginFromCurrentState, .curveEaseOut]) {
            self.frame = target
        } completion: { _ in
            self.setNeedsLayout()
            self.persistFrame()
        }
        AevonLog.info("[窗口] 轻点已停靠小窗 → 还原主悬浮窗 \(Int(target.width))x\(Int(target.height))"
            + "（AevonDockRestoreV44）")
    }

    /// 关闭自己（底边条双击时由全局通道调用）。
    func closeSelf() {
        AevonWindowManager.close(bundleID: bundleID)
    }

    /// 别的窗刚停靠 → 本窗主动让开（V0.0.44，AevonDockAvoidV44）。
    ///
    /// 只靠「移动时避让」不够：小窗是**后**停靠的，落下来就可能压住本窗的手势条。
    /// 所以停靠动作完成后由 `AevonEntryHost` 挨个通知其它窗重排一次。
    func avoidDockedWindows() {
        guard !isLiveResizing else { return }
        let avoided = AevonSnap.avoid(frame, obstacles: AevonEntryHost.dockedObstacles(excluding: self))
        guard abs(avoided.minX - frame.minX) > 0.5 || abs(avoided.minY - frame.minY) > 0.5 else { return }
        UIView.animate(withDuration: 0.24,
                       delay: 0,
                       options: [UIView.AnimationOptions.beginFromCurrentState, .curveEaseOut]) {
            self.frame = avoided
        } completion: { _ in
            self.setNeedsLayout()
            self.persistFrame()
        }
        AevonLog.info("[窗口] \(bundleID) 自动避让停靠小窗 → "
            + "\(Int(avoided.minX)),\(Int(avoided.minY))（AevonDockAvoidV44）")
    }

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
        // V0.0.43：旧版本可能存着 66%~94% 的巨窗，读出来按 maxRestoredRatio 收回
        let cap = screen.width * AevonSnap.maxRestoredRatio
        let width = max(minContentWidth,
                        min(screen.width * CGFloat(raw[2]) / 100.0, cap, AevonSnap.maxWidth))
        let height = AevonSnap.height(forWidth: width)
        let x = screen.width * CGFloat(raw[0]) / 100.0
        let y = screen.height * CGFloat(raw[1]) / 100.0
        return AevonSnap.clamped(CGRect(x: x, y: y, width: width, height: height))
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

    func teardown() {
        // 关窗前把最终位置记下来
        persistFrame()
        // 必须先 invalidate 承载容器再拆视图，否则容器 dealloc 会抛
        // NSInternalInconsistencyException: Must be invalidated before deallocating
        sceneHost.onFirstContent = nil
        sceneHost.invalidate()
        sceneHost.container.removeFromSuperview()
        removeFromSuperview()
    }
}
