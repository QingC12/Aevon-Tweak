import UIKit

/// 单个 App 的浮窗外壳：标题栏（拖动）+ 内容（App 场景，整体缩放）+ 缩放手柄。
///
/// V0.0.9：App 场景按整屏尺寸渲染，浮窗只对承载容器做等比缩放。
/// V0.0.11：内容区宽高比锁定屏幕比例（修掉两侧黑边）＋ 手柄锁比例（修掉细长条）。
/// V0.0.12（本版）：修「缩放卡顿」。
///
/// 卡顿的根因：以前每次 `frame` 变化都会走一遍 layout，然后在 `layoutSubviews` 里
/// 重新给内层承载容器设 `bounds / transform / anchorPoint / position`。
/// 那个容器里装的是 App 的跨进程画面（`_UIScenePresentationView` → CAHostLayer），
/// 它的几何每变一次，Core Animation 都要和渲染服务器同步一遍、把整屏内容重新采样，
/// 一个手势 60 帧就是 60 次 IPC + 60 次整屏重采样，必然卡。
///
/// 现在的做法（和系统级浮窗同一个思路）：
/// * 手势期间**只改外壳自己的 layer.transform**，内部图层树一个属性都不动，
///   所以只是外层的矩阵参与合成，GPU 一次变换就够；
/// * 锚点临时挪到左上角，缩放时左上角不动，视觉上就是「拉右下角」；
/// * 手势期间把圆角裁剪关掉（圆角 + 裁剪 + 缩放子层会触发离屏合成），
///   结束后再恢复，只在抬起手指那一下做一次真正的 layout；
/// * `applyContentScale` 带缓存，尺寸和系数没变就直接返回，
///   应用自己在刷新画面时频繁触发的图层更新也不会变成无意义的布局。
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

    private let titleBarHeight: CGFloat = 40
    private let contentClip = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let resizeHandle = UIView()
    private let hintLabel = UILabel()

    private var moveOriginFrame: CGRect = .zero
    private var moveOriginPoint: CGPoint = .zero
    private var resizeOriginFrame: CGRect = .zero
    private var resizeOriginPoint: CGPoint = .zero

    /// 手势进行中（此时只允许改 transform，不允许改 frame）
    private var isLiveResizing = false
    /// 上一次真正应用过的内容区尺寸与缩放系数（缓存，用来跳过无变化的布局）
    private var lastClipSize: CGSize = .zero
    private var lastAppliedScale: CGFloat = 0

    init(sceneHost: AevonSceneHost, bundleID: String, title: String) {
        self.bundleID = bundleID
        self.sceneHost = sceneHost
        super.init(frame: CGRect.zero)

        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect
        // 默认宽度取屏宽 66%，并保证加上标题栏后不超屏高 72%
        let preferred = screen.width * 0.66
        let maxByHeight = screen.height * 0.72 * aspect
        let contentWidth = max(AevonWindowView.minContentWidth, min(preferred, maxByHeight))
        let contentHeight = contentWidth / aspect
        let width = contentWidth
        let height = contentHeight + titleBarHeight
        frame = CGRect(x: (screen.width - width) / 2.0,
                       y: max(60, screen.height * 0.10),
                       width: width,
                       height: height)

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

        // 缩放手柄：视觉圆点 28pt，触摸热区 44pt（热区留在窗口内，否则被裁剪后点不到）
        let dotSize: CGFloat = 28
        let touchSize: CGFloat = 44
        resizeHandle.frame = CGRect(x: width - touchSize - 2,
                                    y: height - touchSize - 2,
                                    width: touchSize,
                                    height: touchSize)
        resizeHandle.backgroundColor = .clear
        resizeHandle.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        let dot = UIView(frame: CGRect(x: touchSize - dotSize - 6,
                                       y: touchSize - dotSize - 6,
                                       width: dotSize,
                                       height: dotSize))
        dot.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        dot.layer.cornerRadius = dotSize / 2
        dot.isUserInteractionEnabled = false
        resizeHandle.addSubview(dot)
        addSubview(resizeHandle)

        // 手势
        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        titleBar.addGestureRecognizer(move)
        let resize = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        resizeHandle.addGestureRecognizer(resize)

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)"
            + "（比例锁定屏幕 \(String(format: "%.3f", aspect))，"
            + "内容 \(Int(contentWidth))x\(Int(contentHeight))）")
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
        default:
            break
        }
    }

    // MARK: - 缩放（锁定宽高比，手势期间只改矩阵）

    @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            resizeOriginFrame = frame
            resizeOriginPoint = point
            beginLiveResize()

        case .changed:
            let dx = point.x - resizeOriginPoint.x
            let dy = point.y - resizeOriginPoint.y
            let width = clampedContentWidth(dx: dx, dy: dy, base: resizeOriginFrame)
            let factor = max(0.05, width / max(1, resizeOriginFrame.width))
            // 关键：只动外层矩阵，内部的 App 画面图层树完全不碰
            transform = CGAffineTransform(scaleX: factor, y: factor)

        case .ended, .cancelled, .failed:
            finishLiveResize()

        default:
            break
        }
    }

    /// 手柄只有「宽度」一个自由度：高度 = 宽度 ÷ 屏幕比例 + 标题栏。
    /// 拖动方向取 |dx| 与 |dy| 里大的那个来定，斜着拖也跟手，但拖不出细长条。
    private func clampedContentWidth(dx: CGFloat, dy: CGFloat, base: CGRect) -> CGFloat {
        let aspect = AevonWindowView.contentAspect
        let screen = UIScreen.main.bounds
        let originContentHeight = max(1, base.height - titleBarHeight)

        let widthFromX = base.width + dx
        let widthFromY = (originContentHeight + dy) * aspect
        var width = abs(dx) >= abs(dy) ? widthFromX : widthFromY

        // 上限：不超出屏幕右侧、也不超出屏幕底部
        let maxByScreenWidth = screen.width - base.minX - 8
        let maxByScreenHeight = (screen.height - base.minY - 8 - titleBarHeight) * aspect
        let maxWidth = max(AevonWindowView.minContentWidth,
                           min(maxByScreenWidth, maxByScreenHeight))
        width = max(AevonWindowView.minContentWidth, min(width, maxWidth))
        return width
    }

    /// 进入「实时缩放」：锚点挪到左上角，关掉圆角裁剪，内部一个属性都不动。
    private func beginLiveResize() {
        isLiveResizing = true
        let topLeft = frame.origin
        layer.anchorPoint = .zero
        layer.position = topLeft          // 改锚点后必须立刻补位置，否则会跳
        layer.cornerRadius = 0
        clipsToBounds = false             // 圆角 + 裁剪 + 缩放会走离屏合成
        contentClip.clipsToBounds = false
    }

    /// 抬手：把矩阵换成真实 frame，只在这一下做一次完整布局。
    private func finishLiveResize() {
        guard isLiveResizing else { return }
        isLiveResizing = false

        let factor = max(0.05, transform.a)
        transform = .identity
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.cornerRadius = AevonWindowView.cornerRadius
        clipsToBounds = true

        let width = max(AevonWindowView.minContentWidth, resizeOriginFrame.width * factor)
        let height = width / AevonWindowView.contentAspect + titleBarHeight
        frame = CGRect(x: resizeOriginFrame.minX,
                       y: resizeOriginFrame.minY,
                       width: width,
                       height: height)
        setNeedsLayout()
        AevonLog.info("[窗口] 缩放到 \(Int(width))x\(Int(height))（内容 \(Int(width))x\(Int(height - titleBarHeight))）")
    }

    // MARK: - 关闭

    @objc private func closeTapped() {
        AevonWindowManager.close(bundleID: bundleID)
    }

    func teardown() {
        // 必须先 invalidate 承载容器再拆视图，否则容器 dealloc 会抛
        // NSInternalInconsistencyException: Must be invalidated before deallocating
        sceneHost.onFirstContent = nil
        sceneHost.invalidate()
        sceneHost.container.removeFromSuperview()
        removeFromSuperview()
    }
}
