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
    /// 右上角悬浮 ✕ → 关闭
    case close
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
final class AevonWindowView: UIView {
    let bundleID: String
    private let sceneHost: AevonSceneHost

    /// 屏幕宽高比（宽 ÷ 高）。内容区始终锁定这个比例。
    static let contentAspect: CGFloat = {
        let size = UIScreen.main.bounds.size
        guard size.width > 0, size.height > 0 else { return 9.0 / 19.5 }
        return size.width / size.height
    }()

    private static let minContentWidth: CGFloat = 150
    /// 外侧手势区厚度（边条）与外角块边长（pt）。Stheno 的 edgeWidth 同位概念。
    static let barThickness: CGFloat = 18
    static let cornerSize: CGFloat = 34

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

    /// 全局唯一的偏好域，和设置面板共用
    private static let prefsSuite = "com.Aevon"
    /// Stheno 式全局几何记忆键（medusaFrameLast 对应物）
    private static let frameMemoryKey = "MedusaFrameLast"

    private let contentClip = UIView()
    private let closeButton = UIButton(type: .system)
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
    /// 上一次真正应用过的内容区尺寸与缩放系数（缓存，用来跳过无变化的布局）
    private var lastClipSize: CGSize = .zero
    private var lastAppliedScale: CGFloat = 0

    /// 当前吸附槽位（自由位置 / 左半屏 / 右半屏 / 顶部放大）
    private(set) var currentSlot: AevonSnapSlot = .free

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

        frame = CGRect(x: restored.minX, y: restored.minY,
                       width: restored.width, height: restored.height)

        backgroundColor = .clear
        // V0.0.37：窗口本体不裁剪 —— 外侧手势区要伸到 frame 外面；
        // 圆角裁剪由 contentClip 负责。
        clipsToBounds = false

        // V0.0.42（AevonFloatLookV42）：Stheno 观感 —— 投影 + 细描边 + 随缩放同比的圆角。
        // 投影走 shadowPath（每次 layout 更新），比让系统按 alpha 逐帧算便宜得多。
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.42
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 8)

        // 内容区（全高，无标题栏）。圆角 + 裁剪都在这一层。
        contentClip.frame = bounds
        contentClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentClip.clipsToBounds = true
        contentClip.layer.cornerRadius = AevonWindowView.cornerRadius(forWidth: restored.width)
        contentClip.layer.cornerCurve = .continuous
        contentClip.layer.borderWidth = 0.5
        contentClip.layer.borderColor = UIColor(white: 1.0, alpha: 0.14).cgColor
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

        // 右上角悬浮 ✕（Stheno 无标题栏方案的关闭出口）
        // V0.0.42：缩小到 26pt 并加投影，避免压住圆角弧；位置随宽度自动贴右上。
        closeButton.frame = CGRect(x: restored.width - 36, y: 10, width: 26, height: 26)
        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(UIColor(white: 1.0, alpha: 0.92), for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        closeButton.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
        closeButton.layer.cornerRadius = 13
        closeButton.layer.borderWidth = 0.5
        closeButton.layer.borderColor = UIColor(white: 1.0, alpha: 0.18).cgColor
        closeButton.layer.shadowColor = UIColor.black.cgColor
        closeButton.layer.shadowOpacity = 0.35
        closeButton.layer.shadowRadius = 4
        closeButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        closeButton.autoresizingMask = [.flexibleLeftMargin]
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        // V0.0.37（AevonSthenoEdgeBarV37）：外侧边缘手势区（四边条 + 四角块，全部在窗外）
        installOutsideGestureHandles(width: restored.width, height: restored.height)

        // 双击任意手柄 = 小窗 / 大窗切换（原「双击标题栏」的替代出口）
        for handle in subviews.compactMap({ $0 as? AevonEdgeHandleView }) {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleBarDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            handle.addGestureRecognizer(doubleTap)
        }

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)"
            + "（无标题栏 + 外侧手势区，比例锁定屏幕 \(String(format: "%.3f", aspect))，"
            + "内容 \(Int(restored.width))x\(Int(restored.height))，"
            + "\(sizeSource)）（AevonSthenoEdgeBarV37）")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 无记忆时的默认几何（V0.0.42，Stheno 观感）：宽 70% 屏宽、顶边 10% 屏高、水平居中，
    /// 并且一定落在安全区内（四角手柄全部可抓）。
    private static func defaultFrame() -> CGRect {
        let screen = UIScreen.main.bounds
        return AevonSnap.fitted(width: screen.width * 0.70)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 缩放进行中不允许布局（手势只会改 transform，走到这里说明有外部触发，
        // 一旦在这里改内部几何就又退回到卡顿的老路，直接跳过）
        if isLiveResizing { return }

        if contentClip.frame != bounds {
            contentClip.frame = bounds
        }
        // 圆角随尺寸走（Stheno radiusLast 体系），投影路径同步更新
        let radius = AevonWindowView.cornerRadius(forWidth: bounds.width)
        if abs(contentClip.layer.cornerRadius - radius) > 0.3 {
            contentClip.layer.cornerRadius = radius
        }
        updateShadowPath()
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

    /// 把整屏尺寸的容器等比铺满内容区。
    ///
    /// 用 max 而不是 min：内容区比例已经锁定成屏幕比例，两者理论相等，
    /// 取较大的一边可以吃掉浮点误差，绝不会在两侧露出底色（黑边）。
    private func applyContentScale() {
        let screen = UIScreen.main.bounds.size
        guard screen.width > 0, screen.height > 0,
              contentClip.bounds.width > 0, contentClip.bounds.height > 0 else { return }

        let scale = max(contentClip.bounds.width / screen.width,
                        contentClip.bounds.height / screen.height)

        let clipSize = contentClip.bounds.size
        if abs(clipSize.width - lastClipSize.width) < 0.01,
           abs(clipSize.height - lastClipSize.height) < 0.01,
           abs(scale - lastAppliedScale) < 0.0001 {
            return
        }
        lastClipSize = clipSize
        lastAppliedScale = scale

        let container = sceneHost.container
        container.layer.anchorPoint = .zero
        container.bounds = CGRect(origin: .zero, size: screen)
        container.transform = CGAffineTransform(scaleX: scale, y: scale)
        container.layer.position = CGPoint(x: (clipSize.width - screen.width * scale) / 2.0,
                                           y: (clipSize.height - screen.height * scale) / 2.0)
    }

    // MARK: - 外侧手势区（V0.0.37，AevonSthenoEdgeBarV37）

    /// 手柄全部挂在窗口 frame **外面**（Stheno：手势区域为边缘外侧）：
    ///   · 四条边条（单边 → 拖动 = 移动窗口）；
    ///   · 四个外角块（双边 → 拖动 = 从对角缩放）。
    /// 窗内一个点都不占，App 内容的点击 / 滑动完全不受影响。
    /// 注意：窗口本体 clipsToBounds = false，frame 外的子视图照常参与命中测试。
    private func installOutsideGestureHandles(width: CGFloat, height: CGFloat) {
        let b = AevonWindowView.barThickness
        let c = AevonWindowView.cornerSize
        let handles: [(UIRectEdge, CGRect, UIView.AutoresizingMask)] = [
            // 四个外角块（缩放）
            ([.top, .left],     CGRect(x: -c, y: -c, width: c, height: c), []),
            ([.top, .right],    CGRect(x: width, y: -c, width: c, height: c),
             [.flexibleLeftMargin]),
            ([.bottom, .left],  CGRect(x: -c, y: height, width: c, height: c),
             [.flexibleTopMargin]),
            ([.bottom, .right], CGRect(x: width, y: height, width: c, height: c),
             [.flexibleLeftMargin, .flexibleTopMargin]),
            // 四条边条（移动）
            ([.top],            CGRect(x: c, y: -b, width: max(0, width - 2 * c), height: b),
             [.flexibleWidth]),
            ([.bottom],         CGRect(x: c, y: height, width: max(0, width - 2 * c), height: b),
             [.flexibleWidth, .flexibleTopMargin]),
            ([.left],           CGRect(x: -b, y: c, width: b, height: max(0, height - 2 * c)),
             [.flexibleHeight]),
            ([.right],          CGRect(x: width, y: c, width: b, height: max(0, height - 2 * c)),
             [.flexibleLeftMargin, .flexibleHeight]),
        ]
        for (edges, rect, mask) in handles {
            guard rect.width > 0, rect.height > 0 else { continue }
            let handle = AevonEdgeHandleView(frame: rect)
            handle.edges = edges
            handle.backgroundColor = .clear
            if !mask.isEmpty { handle.autoresizingMask = mask }
            addSubview(handle)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOutsidePan(_:)))
            handle.addGestureRecognizer(pan)
        }
    }

    /// 外侧手势的统一入口：角块 → 缩放；边条 → 移动。
    @objc private func handleOutsidePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? AevonEdgeHandleView else { return }
        if handle.isCorner {
            handleCornerResize(gesture, edges: handle.edges)
        } else {
            handleBarMove(gesture)
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

        // ✕ 先判：它压在窗内右上，若被边条帧盖住会误判成拖动
        if !closeButton.isHidden, closeButton.alpha > 0.01,
           closeButton.frame.insetBy(dx: -8, dy: -8).contains(local) {
            return .close
        }
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
        case .close:
            activeGrab = grab
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
        case .close:
            break
        }
    }

    /// 抬手。`commit` = false 表示这段拖拽被取消（不落盘几何、不关窗）。
    func grabEnd(at layerPoint: CGPoint, commit: Bool) {
        guard let grab = activeGrab else { return }
        activeGrab = nil
        switch grab {
        case .bar:
            applyBarMove(to: layerPoint)
            if commit, AevonPrefs.bool("SnapEnabled", default: true),
               let slot = AevonSnap.slot(for: frame) {
                snap(to: slot)
                return
            }
            persistFrame()
        case .corner(let edges):
            applyCornerResize(to: layerPoint, edges: edges)
            finishEdgeResize()
        case .close:
            guard commit, let parent = superview else { return }
            let local = convert(layerPoint, from: parent)
            if !closeButton.isHidden,
               closeButton.frame.insetBy(dx: -8, dy: -8).contains(local) {
                closeTapped()
            }
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
                transform = .identity
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                contentClip.layer.cornerRadius = AevonWindowView.cornerRadius(forWidth: resizeOriginFrame.width)
                contentClip.clipsToBounds = true
                frame = AevonSnap.clamped(resizeOriginFrame)
                setNeedsLayout()
            }
        case .close:
            break
        }
    }

    /// 小窗 / 大窗切换（原「双击边条」，现在也可由全局通道触发）。
    ///
    /// V0.0.42：两档都受安全区约束 —— 大档以前算到 94% 屏宽（378x820），
    /// 四个角块全在屏幕外，双击之后就再也缩放不回来（Aevon(35) 日志）。
    func cycleSize() {
        guard !isLiveResizing else { return }
        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect

        let smallWidth = max(AevonWindowView.minContentWidth,
                             min(screen.width * 0.60, AevonSnap.maxWidth,
                                 screen.height * 0.66 * aspect))
        let bigWidth = max(smallWidth,
                           min(screen.width * 0.86, AevonSnap.maxWidth,
                               screen.height * 0.86 * aspect))
        let threshold = (smallWidth + bigWidth) / 2.0
        let target = bounds.width < threshold ? bigWidth : smallWidth

        let targetHeight = AevonSnap.height(forWidth: target)
        var newFrame = CGRect(x: 0, y: 0, width: target, height: targetHeight)
        newFrame.origin.x = frame.midX - target / 2.0
        newFrame.origin.y = frame.midY - targetHeight / 2.0
        frame = AevonSnap.clamped(newFrame)
        setNeedsLayout()
        persistFrame()
        AevonLog.info("[窗口] 双击切换尺寸 \(Int(target))x\(Int(targetHeight))")
    }

    // MARK: - 边条移动

    @objc private func handleBarMove(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            moveOriginFrame = frame
            moveOriginPoint = point
        case .changed:
            applyBarMove(to: point)
        case .ended, .cancelled, .failed:
            applyBarMove(to: point)
            // 松手时若贴着屏幕边缘，就吸附成左半屏 / 右半屏 / 顶部放大。
            if gesture.state == .ended,
               AevonPrefs.bool("SnapEnabled", default: true),
               let slot = AevonSnap.slot(for: frame) {
                snap(to: slot)
                return
            }
            persistFrame()
        default:
            break
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

    /// 进入「实时缩放」：锚点挪到固定点，关掉内容区裁剪，内部一个属性都不动。
    private func beginLiveResize(anchor: CGPoint) {
        isLiveResizing = true
        resizeAnchor = anchor
        // 改锚点后必须立刻补位置，否则窗口会跳：position = 固定点在父视图的坐标
        let fixed = CGPoint(x: frame.origin.x + anchor.x * frame.width,
                            y: frame.origin.y + anchor.y * frame.height)
        layer.anchorPoint = anchor
        layer.position = fixed
        contentClip.layer.cornerRadius = 0
        contentClip.clipsToBounds = false  // 圆角 + 裁剪 + 缩放会走离屏合成
    }

    /// 抬手：把矩阵换成真实 frame，只在这一下做一次完整布局。
    ///
    /// V0.0.42：尺寸上限改走 `AevonSnap`（安全区内），origin 一律 `clamped` ——
    /// 以前的 `60 - width / screen.width - 60` 允许窗口贴到屏幕最边上，
    /// 外角块直接滑出屏外，就再也抓不到缩放手柄了。
    private func finishEdgeResize() {
        guard isLiveResizing else { return }
        let factor = max(0.05, transform.a)
        isLiveResizing = false

        let anchor = resizeAnchor
        transform = .identity
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentClip.clipsToBounds = true

        let width = max(AevonWindowView.minContentWidth,
                        min(resizeOriginFrame.width * factor, AevonSnap.maxWidth))
        let height = AevonSnap.height(forWidth: width)

        // 固定点 = 原始 frame 里锚点对应的那一点；新 frame 以它为基准反推 origin
        let fixed = CGPoint(x: resizeOriginFrame.minX + anchor.x * resizeOriginFrame.width,
                            y: resizeOriginFrame.minY + anchor.y * resizeOriginFrame.height)
        let origin = CGPoint(x: fixed.x - anchor.x * width,
                             y: fixed.y - anchor.y * height)
        frame = AevonSnap.clamped(CGRect(origin: origin, size: CGSize(width: width, height: height)))
        contentClip.layer.cornerRadius = AevonWindowView.cornerRadius(forWidth: frame.width)
        setNeedsLayout()
        persistFrame()
        AevonLog.info("[窗口] 缩放到 \(Int(frame.width))x\(Int(frame.height))"
            + "（贴边已避让，圆角 \(Int(contentClip.layer.cornerRadius))）（AevonEdgeResizeV37 AevonSthenoDockV42）")
    }

    // MARK: - 双击边条：小窗 / 大窗 两档

    @objc private func handleBarDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard !isLiveResizing, gesture.state == .ended else { return }
        cycleSize()
    }

    // MARK: - 吸附

    /// 吸附到指定槽位（V0.0.42：Stheno 式停靠 —— 只靠边，不改尺寸）。
    func snap(to slot: AevonSnapSlot) {
        guard slot != .free, !isLiveResizing else { return }
        let target = AevonSnap.frame(for: slot, from: frame)
        guard target.width >= AevonSnap.minContentWidth, target.height > 0 else { return }

        // 目标与当前几乎一致就不折腾了（拖动松手时已经贴在位置上的情况）
        if abs(target.minX - frame.minX) < 0.5,
           abs(target.minY - frame.minY) < 0.5,
           abs(target.width - frame.width) < 0.5 {
            currentSlot = slot
            persistFrame()
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
        }
        AevonLog.info("[窗口] 停靠到\(AevonSnap.describe(slot)) \(Int(target.minX)),\(Int(target.minY)) "
            + "\(Int(target.width))x\(Int(target.height))（尺寸不变 · 贴边留 \(Int(AevonSnap.edgeInset))pt）（AevonSthenoDockV42）")
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
        // V0.0.42：宽度上限改走安全区（旧记忆里可能存着 94% 那种巨窗，读出来也要收回来）
        let width = max(minContentWidth,
                        min(screen.width * CGFloat(raw[2]) / 100.0, AevonSnap.maxWidth))
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

    @objc private func closeTapped() {
        AevonWindowManager.close(bundleID: bundleID)
    }

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
