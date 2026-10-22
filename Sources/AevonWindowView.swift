import UIKit

/// 缩放热区（V0.0.36）：带方向标记的透明视图，挂在浮窗四边 / 四角。
final class AevonEdgeHandleView: UIView {
    /// 这个手柄负责哪些边（角手柄是两个边的组合）
    var edges: UIRectEdge = []
}

/// 单个 App 的浮窗外壳：标题栏（拖动 / 双击放大）+ 内容（App 场景，整体缩放）+ 四周缩放热区。
///
/// V0.0.9：App 场景按整屏尺寸渲染，浮窗只对承载容器做等比缩放。
/// V0.0.11：内容区宽高比锁定屏幕比例（修掉两侧黑边）＋ 手柄锁比例（修掉细长条）。
/// V0.0.12：修缩放卡顿 —— 手势期间只改外壳自己的 `layer.transform`，内部图层树一个属性都不动；
///          抬手那一下才提交真实 frame，并且关掉手势期间的圆角裁剪（避免离屏合成）。
/// V0.0.13：可用性 —— ①窗口大小/位置按 App 记住，下次开窗还原；
///          ②双击标题栏在「小窗 / 大窗」两档之间切换；③触摸时把窗口提到最前（多窗重叠时）。
/// V0.0.14：分屏 —— ①支持以吸附槽位（左半屏 / 右半屏 / 顶部放大）创建；
///          ②拖动标题栏到屏幕边缘松手自动吸附；③对外暴露 `snap(to:)` 供分屏流程调用。
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
    private static let titleBarHeightValue: CGFloat = 40

    /// 全局唯一的偏好域，和设置面板共用
    private static let prefsSuite = "com.Aevon"

    private var titleBarHeight: CGFloat { AevonWindowView.titleBarHeightValue }

    private let contentClip = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    /// 右下角的视觉提示圆点（真正的缩放手势在四周 8 向热区上，V0.0.36）
    private let cornerDot = UIView()
    private let hintLabel = UILabel()

    private var moveOriginFrame: CGRect = .zero
    private var moveOriginPoint: CGPoint = .zero
    private var resizeOriginFrame: CGRect = .zero
    private var resizeOriginPoint: CGPoint = .zero
    /// 本次缩放抓的是哪几条边（V0.0.36 四周 8 向手势）
    private var resizeOriginEdges: UIRectEdge = []
    /// 缩放锚点（unit 坐标）：对边/对角的固定点，缩放时它不动
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
        // V0.0.36（AevonFloatPrefV36）：默认宽度 / 顶部位置可在设置「细节调整」里改。
        // FloatWindowWidth = 屏宽百分比（30~95，默认 66）；FloatWindowY = 屏高百分比（2~60，默认 10）。
        let widthPct = max(30.0, min(95.0, AevonPrefs.double("FloatWindowWidth", default: 66.0)))
        let yPct = max(2.0, min(60.0, AevonPrefs.double("FloatWindowY", default: 10.0)))
        let preferred = screen.width * widthPct / 100.0
        let maxByHeight = screen.height * 0.72 * aspect
        let defaultContentWidth = max(AevonWindowView.minContentWidth,
                                      min(preferred, maxByHeight))
        let defaultFrame = CGRect(x: (screen.width - defaultContentWidth) / 2.0,
                                  y: max(24, screen.height * yPct / 100.0),
                                  width: defaultContentWidth,
                                  height: defaultContentWidth / aspect + AevonWindowView.titleBarHeightValue)

        // 分屏时用吸附槽位算位置，否则恢复这个 App 上次的窗口大小与位置
        var sizeSource = "默认尺寸"
        let restored: CGRect
        if slot != .free {
            restored = AevonSnap.frame(for: slot)
            currentSlot = slot
            sizeSource = "吸附\(AevonSnap.describe(slot))"
        } else {
            let memorized = AevonWindowView.rememberedFrame(bundleID: bundleID, fallback: defaultFrame)
            restored = memorized
            if memorized != defaultFrame { sizeSource = "已恢复上次尺寸" }
        }

        let width = restored.width
        let contentHeight = restored.height - titleBarHeight
        frame = restored

        backgroundColor = UIColor(white: 0.12, alpha: 1.0)
        layer.cornerRadius = AevonWindowView.cornerRadius
        clipsToBounds = true

        // 标题栏
        let titleBar = UIView(frame: CGRect(x: 0, y: 0, width: width, height: titleBarHeight))
        titleBar.backgroundColor = UIColor(white: 0.20, alpha: 1.0)
        titleBar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        addSubview(titleBar)

        titleLabel.frame = CGRect(x: 12, y: 0, width: width - 60, height: titleBarHeight)
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.autoresizingMask = [.flexibleWidth]
        titleBar.addSubview(titleLabel)

        closeButton.frame = CGRect(x: width - 44, y: 0, width: 44, height: titleBarHeight)
        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.autoresizingMask = [.flexibleLeftMargin]
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        titleBar.addSubview(closeButton)

        // 内容区。比例锁定后画面正好铺满，不需要裁剪 ——
        // 少一层 clipsToBounds 就少一次离屏合成，缩放更顺。
        contentClip.frame = CGRect(x: 0, y: titleBarHeight, width: width, height: contentHeight)
        contentClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentClip.clipsToBounds = false
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

        // V0.0.36（AevonEdgeResizeV36）：四周 8 向缩放热区（四边 + 三角，右上角留给关闭按钮）
        installEdgeResizeHandles(width: width, height: restored.height)

        // 右下角保留一颗淡淡的圆点，提示「这个窗口可以缩放」
        cornerDot.frame = CGRect(x: width - 34, y: restored.height - 34, width: 28, height: 28)
        cornerDot.backgroundColor = UIColor.white.withAlphaComponent(0.30)
        cornerDot.layer.cornerRadius = 14
        cornerDot.isUserInteractionEnabled = false
        cornerDot.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        addSubview(cornerDot)

        // 手势：标题栏拖动 / 双击切换大小档；缩放全在边缘热区上
        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        titleBar.addGestureRecognizer(move)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTitleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        titleBar.addGestureRecognizer(doubleTap)

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)"
            + "（比例锁定屏幕 \(String(format: "%.3f", aspect))，"
            + "内容 \(Int(width))x\(Int(contentHeight))，"
            + "\(sizeSource)）")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 缩放进行中不允许布局（手势只会改 transform，走到这里说明有外部触发，
        // 一旦在这里改内部几何就又退回到卡顿的老路，直接跳过）
        if isLiveResizing { return }

        let clipFrame = CGRect(x: 0,
                               y: titleBarHeight,
                               width: bounds.width,
                               height: max(0, bounds.height - titleBarHeight))
        if contentClip.frame != clipFrame {
            contentClip.frame = clipFrame
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
    /// 尺寸与系数都没变化时直接返回，避免无意义的图层重建。
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

    // MARK: - 拖动

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
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

    // MARK: - 四周 8 向缩放（V0.0.36，AevonEdgeResizeV36）

    /// 安装四周缩放热区：四个角（左上 / 左下 / 右下）+ 四条边。
    /// 右上角**故意不放**手柄 —— 那里是关闭按钮的地盘，热区放上去会抢 ✕ 的点击。
    /// 手柄全部在窗口内部（clipsToBounds 之内），拖边 = 沿该边缩放，拖角 = 双向等比。
    private func installEdgeResizeHandles(width: CGFloat, height: CGFloat) {
        let c: CGFloat = 40      // 角手柄边长
        let b: CGFloat = 14      // 边手柄厚度
        let closeGuard: CGFloat = 44  // 顶部热区给关闭按钮让出的宽度
        let handles: [(UIRectEdge, CGRect, UIView.AutoresizingMask)] = [
            ([.top, .left],     CGRect(x: 0, y: 0, width: c, height: c),
             []),
            ([.bottom, .left],  CGRect(x: 0, y: height - c, width: c, height: c),
             [.flexibleTopMargin]),
            ([.bottom, .right], CGRect(x: width - c, y: height - c, width: c, height: c),
             [.flexibleLeftMargin, .flexibleTopMargin]),
            ([.top],            CGRect(x: c, y: 0, width: max(0, width - c - closeGuard), height: b),
             [.flexibleWidth]),
            ([.bottom],         CGRect(x: c, y: height - b, width: max(0, width - 2 * c), height: b),
             [.flexibleWidth, .flexibleTopMargin]),
            ([.left],           CGRect(x: 0, y: c, width: b, height: max(0, height - 2 * c)),
             []),
            ([.right],          CGRect(x: width - b, y: c, width: b, height: max(0, height - 2 * c)),
             [.flexibleLeftMargin]),
        ]
        for (edges, rect, mask) in handles {
            guard rect.width > 0, rect.height > 0 else { continue }
            let handle = AevonEdgeHandleView(frame: rect)
            handle.edges = edges
            handle.backgroundColor = .clear
            if !mask.isEmpty { handle.autoresizingMask = mask }
            addSubview(handle)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleEdgeResize(_:)))
            handle.addGestureRecognizer(pan)
        }
    }

    /// 边缘热区的统一手势入口。
    ///
    /// 缩放锚点 = 对边 / 对角的固定点（拖右边 → 左边不动），手势期间只改
    /// 外层 `transform`（V0.0.12 的零布局思路），抬手才提交真实 frame。
    @objc private func handleEdgeResize(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? AevonEdgeHandleView, superview != nil else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            resizeOriginFrame = frame
            resizeOriginPoint = point
            resizeOriginEdges = handle.edges
            // 锚点取「不动的那些边」的交点：拖右 → 锚在左（x=0）；拖左 → 锚在右（x=1）；
            // 只拖上下 → x 居中；y 同理。
            let ax: CGFloat = handle.edges.contains(.left) ? 1.0
                : (handle.edges.contains(.right) ? 0.0 : 0.5)
            let ay: CGFloat = handle.edges.contains(.top) ? 1.0
                : (handle.edges.contains(.bottom) ? 0.0 : 0.5)
            beginLiveResize(anchor: CGPoint(x: ax, y: ay))

        case .changed:
            let dx = point.x - resizeOriginPoint.x
            let dy = point.y - resizeOriginPoint.y
            let horizontal = resizeOriginEdges.contains(.left) || resizeOriginEdges.contains(.right)
            let vertical = resizeOriginEdges.contains(.top) || resizeOriginEdges.contains(.bottom)
            let width = clampedEdgeWidth(dx: dx, dy: dy,
                                         base: resizeOriginFrame,
                                         horizontal: horizontal, vertical: vertical)
            let factor = max(0.05, width / max(1, resizeOriginFrame.width))
            // 只动外层矩阵，内部的 App 画面图层树完全不碰
            transform = CGAffineTransform(scaleX: factor, y: factor)

        case .ended, .cancelled, .failed:
            finishEdgeResize()

        default:
            break
        }
    }

    /// 只有「宽度」一个自由度：高度 = 宽度 ÷ 屏幕比例 + 标题栏。
    /// 横向边按 dx（拖左边缘时反向），纵向边按 dy（拖顶边时反向）；
    /// 角手柄横竖都在动，取变化更明显的那个方向，斜拖也跟手，拖不出细长条。
    private func clampedEdgeWidth(dx: CGFloat, dy: CGFloat, base: CGRect,
                                  horizontal: Bool, vertical: Bool) -> CGFloat {
        let aspect = AevonWindowView.contentAspect
        let screen = UIScreen.main.bounds
        let originContentHeight = max(1, base.height - titleBarHeight)

        var width: CGFloat? = nil
        if horizontal {
            let signed = resizeOriginEdges.contains(.left) ? -dx : dx
            width = base.width + signed
        }
        if vertical {
            let signed = resizeOriginEdges.contains(.top) ? -dy : dy
            let widthFromY = (originContentHeight + signed) * aspect
            width = width.map { current in
                abs(dx) >= abs(dy) ? current : widthFromY
            } ?? widthFromY
        }
        var result = width ?? base.width
        // 上限：内容区不超屏高 92%，宽度不超屏宽 95%
        let maxWidth = max(AevonWindowView.minContentWidth,
                           min(screen.width * 0.95, (screen.height * 0.92 - titleBarHeight) * aspect))
        result = max(AevonWindowView.minContentWidth, min(result, maxWidth))
        return result
    }

    /// 进入「实时缩放」：锚点挪到固定点，关掉圆角裁剪，内部一个属性都不动。
    private func beginLiveResize(anchor: CGPoint) {
        isLiveResizing = true
        resizeAnchor = anchor
        // 改锚点后必须立刻补位置，否则窗口会跳：position = 固定点在父视图的坐标
        let fixed = CGPoint(x: frame.origin.x + anchor.x * frame.width,
                            y: frame.origin.y + anchor.y * frame.height)
        layer.anchorPoint = anchor
        layer.position = fixed
        layer.cornerRadius = 0
        clipsToBounds = false             // 圆角 + 裁剪 + 缩放会走离屏合成
        contentClip.clipsToBounds = false
    }

    /// 抬手：把矩阵换成真实 frame，只在这一下做一次完整布局。
    private func finishEdgeResize() {
        guard isLiveResizing else { return }
        let factor = max(0.05, transform.a)
        isLiveResizing = false

        let anchor = resizeAnchor
        transform = .identity
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.cornerRadius = AevonWindowView.cornerRadius
        clipsToBounds = true

        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect
        var width = max(AevonWindowView.minContentWidth,
                        min(resizeOriginFrame.width * factor, screen.width * 0.95))
        width = min(width, (screen.height * 0.92 - titleBarHeight) * aspect)
        let height = width / aspect + titleBarHeight

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
        AevonLog.info("[窗口] 缩放到 \(Int(width))x\(Int(height))（内容 \(Int(width))x\(Int(height - titleBarHeight))）（AevonEdgeResizeV36）")
    }

    // MARK: - 双击标题栏：小窗 / 大窗 两档

    @objc private func handleTitleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard !isLiveResizing, gesture.state == .ended else { return }
        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect

        let smallWidth = max(AevonWindowView.minContentWidth,
                             min(screen.width * 0.62, screen.height * 0.66 * aspect))
        let bigWidth = min(screen.width * 0.94, screen.height * 0.88 * aspect)
        let threshold = (smallWidth + bigWidth) / 2.0
        let target = bounds.width < threshold ? bigWidth : smallWidth
        let targetHeight = target / aspect + titleBarHeight

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
        guard target.width >= AevonSnap.minContentWidth, target.height > titleBarHeight else { return }

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
        AevonLog.info("[窗口] 吸附到\(AevonSnap.describe(slot)) \(Int(target.width))x\(Int(target.height))（内容 \(Int(target.width))x\(Int(target.height - titleBarHeight))）")
    }

    /// 把窗口提到最前（面板里的「已开窗口」点名称时用）。
    func bringToFront() {
        guard let superview = superview else { return }
        superview.bringSubviewToFront(self)
    }

    // MARK: - 按设置应用默认几何（V0.0.36，AevonFloatPrefV36）

    /// 把窗口挪到设置里的「浮窗默认宽度 / 顶部位置」。只对自由位置的窗口有意义。
    /// 返回是否真的动了。
    @discardableResult
    func applyDefaultGeometry() -> Bool {
        guard !isLiveResizing else { return false }
        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect
        let widthPct = max(30.0, min(95.0, AevonPrefs.double("FloatWindowWidth", default: 66.0)))
        let yPct = max(2.0, min(60.0, AevonPrefs.double("FloatWindowY", default: 10.0)))
        let width = max(AevonWindowView.minContentWidth,
                        min(screen.width * widthPct / 100.0,
                            (screen.height * 0.92 - titleBarHeight) * aspect))
        let height = width / aspect + titleBarHeight
        let target = CGRect(x: (screen.width - width) / 2.0,
                            y: max(24, screen.height * yPct / 100.0),
                            width: width,
                            height: height)
        guard abs(target.minX - frame.minX) > 0.5
            || abs(target.minY - frame.minY) > 0.5
            || abs(target.width - frame.width) > 0.5 else { return false }
        UIView.animate(withDuration: 0.22,
                       delay: 0,
                       options: [.beginFromCurrentState, .curveEaseOut]) {
            self.frame = target
        } completion: { _ in
            self.setNeedsLayout()
            self.persistFrame()
        }
        return true
    }

    // MARK: - 窗口尺寸记忆

    private static func frameKey(_ bundleID: String) -> String {
        return "WindowFrame." + bundleID
    }

    /// 读上次的窗口位置与宽度；数据不合理就直接用默认值。
    private static func rememberedFrame(bundleID: String, fallback: CGRect) -> CGRect {
        guard let store = UserDefaults(suiteName: prefsSuite),
              let raw = store.array(forKey: frameKey(bundleID)) as? [Double],
              raw.count >= 3 else { return fallback }

        let screen = UIScreen.main.bounds
        let aspect = contentAspect
        let x = CGFloat(raw[0]), y = CGFloat(raw[1]), width = CGFloat(raw[2])
        guard width >= minContentWidth, width <= screen.width * 0.95 else { return fallback }

        let height = width / aspect + titleBarHeightValue
        let clampedX = max(0, min(x, screen.width - 60))
        let clampedY = max(0, min(y, screen.height - 60))
        return CGRect(x: clampedX, y: clampedY, width: width, height: height)
    }

    private func persistFrame() {
        guard !isLiveResizing, transform.isIdentity else { return }
        guard let store = UserDefaults(suiteName: AevonWindowView.prefsSuite) else { return }
        store.set([Double(frame.minX), Double(frame.minY), Double(frame.width)],
                  forKey: AevonWindowView.frameKey(bundleID))
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
