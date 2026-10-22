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
    private static let cornerRadius: CGFloat = 12
    /// 外侧手势区厚度（边条）与外角块边长（pt）。Stheno 的 edgeWidth 同位概念。
    static let barThickness: CGFloat = 18
    static let cornerSize: CGFloat = 34

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
            restored = AevonSnap.frame(for: slot)
            currentSlot = slot
            sizeSource = "吸附\(AevonSnap.describe(slot))"
        } else {
            restored = AevonWindowView.rememberedFrame(fallback: AevonWindowView.defaultFrame())
            if restored != AevonWindowView.defaultFrame() { sizeSource = "已恢复上次几何（全局记忆）" }
        }

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
            DispatchQueue.main.async {
                self?.hintLabel.isHidden = true
            }
        }

        // 右上角悬浮 ✕（Stheno 无标题栏方案的关闭出口）
        closeButton.frame = CGRect(x: restored.width - 40, y: 6, width: 30, height: 30)
        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        closeButton.backgroundColor = UIColor(white: 0.10, alpha: 0.55)
        closeButton.layer.cornerRadius = 15
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

    /// 无记忆时的默认几何：宽 66% 屏宽，顶边 10% 屏高，水平居中。
    private static func defaultFrame() -> CGRect {
        let screen = UIScreen.main.bounds
        let aspect = contentAspect
        let width = max(minContentWidth, min(screen.width * 0.66,
                                             (screen.height * 0.92) * aspect))
        let height = width / aspect
        return CGRect(x: (screen.width - width) / 2.0,
                      y: max(24, screen.height * 0.10),
                      width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 缩放进行中不允许布局（手势只会改 transform，走到这里说明有外部触发，
        // 一旦在这里改内部几何就又退回到卡顿的老路，直接跳过）
        if isLiveResizing { return }

        if contentClip.frame != bounds {
            contentClip.frame = bounds
        }
        applyContentScale()
    }

    /// 触摸落在本窗口时把自己提到最前（多窗重叠时点哪个哪个在上）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, let superview = superview, superview.subviews.last !== self {
            superview.bringSubviewToFront(self)
        }
        return hit
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

    // MARK: - 边条移动

    @objc private func handleBarMove(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            moveOriginFrame = frame
            moveOriginPoint = point
        case .changed:
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
        case .ended, .cancelled, .failed:
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
            let dx = point.x - resizeOriginPoint.x
            let dy = point.y - resizeOriginPoint.y
            let width = clampedCornerWidth(dx: dx, dy: dy, base: resizeOriginFrame, edges: edges)
            let factor = max(0.05, width / max(1, resizeOriginFrame.width))
            // 只动外层矩阵，内部的 App 画面图层树完全不碰
            transform = CGAffineTransform(scaleX: factor, y: factor)

        case .ended, .cancelled, .failed:
            finishEdgeResize()

        default:
            break
        }
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
    private func finishEdgeResize() {
        guard isLiveResizing else { return }
        let factor = max(0.05, transform.a)
        isLiveResizing = false

        let anchor = resizeAnchor
        transform = .identity
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentClip.layer.cornerRadius = AevonWindowView.cornerRadius
        contentClip.clipsToBounds = true

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
        AevonLog.info("[窗口] 缩放到 \(Int(width))x\(Int(height))（AevonEdgeResizeV37）")
    }

    // MARK: - 双击边条：小窗 / 大窗 两档

    @objc private func handleBarDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard !isLiveResizing, gesture.state == .ended else { return }
        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect

        let smallWidth = max(AevonWindowView.minContentWidth,
                             min(screen.width * 0.62, screen.height * 0.66 * aspect))
        let bigWidth = min(screen.width * 0.94, screen.height * 0.88 * aspect)
        let threshold = (smallWidth + bigWidth) / 2.0
        let target = bounds.width < threshold ? bigWidth : smallWidth
        let targetHeight = target / aspect

        // 以当前中心为基准缩放，再夹回屏幕内
        var newFrame = CGRect(x: 0, y: 0, width: target, height: targetHeight)
        newFrame.origin.x = max(8, min(frame.midX - target / 2.0, screen.width - target - 8))
        newFrame.origin.y = max(24, min(frame.midY - targetHeight / 2.0, screen.height - targetHeight - 8))
        frame = newFrame
        setNeedsLayout()
        persistFrame()
        AevonLog.info("[窗口] 双击切换尺寸 \(Int(target))x\(Int(targetHeight))")
    }

    // MARK: - 吸附

    /// 吸附到指定槽位。分屏流程（选两个 App 自动并排）和拖动吸附都走这里。
    func snap(to slot: AevonSnapSlot) {
        guard slot != .free, !isLiveResizing else { return }
        let target = AevonSnap.frame(for: slot)
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
        UIView.animate(withDuration: 0.22,
                       delay: 0,
                       options: [UIView.AnimationOptions.beginFromCurrentState, .curveEaseOut]) {
            self.frame = target
        } completion: { _ in
            self.setNeedsLayout()
            self.persistFrame()
        }
        AevonLog.info("[窗口] 吸附到\(AevonSnap.describe(slot)) \(Int(target.width))x\(Int(target.height))")
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
        // 必须先 invalidate 承载容器再拆视图，否则容器 dealloc 会抛
        // NSInternalInconsistencyException: Must be invalidated before deallocating
        sceneHost.onFirstContent = nil
        sceneHost.invalidate()
        sceneHost.container.removeFromSuperview()
        removeFromSuperview()
    }
}
