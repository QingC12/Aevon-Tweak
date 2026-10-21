import UIKit

/// 单个 App 的浮窗外壳：标题栏（拖动）+ 内容（App 场景，整体缩放）+ 缩放手柄。
///
/// V0.0.9 改动：App 场景按整屏尺寸渲染，浮窗只对承载容器做**等比缩放**。
/// 以前直接把容器铺满内容区，等于要求系统把整屏画面塞进一个小框，
/// 结果是外壳有、里面空。
final class AevonWindowView: UIView {
    let bundleID: String
    private let sceneHost: AevonSceneHost

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

    init(sceneHost: AevonSceneHost, bundleID: String, title: String) {
        self.bundleID = bundleID
        self.sceneHost = sceneHost
        super.init(frame: CGRect.zero)

        let screen = UIScreen.main.bounds
        let width = screen.width * 0.78
        let height = screen.height * 0.60
        frame = CGRect(x: (screen.width - width) / 2.0,
                       y: screen.height * 0.12,
                       width: width,
                       height: height)

        backgroundColor = UIColor(white: 0.12, alpha: 1.0)
        layer.cornerRadius = 12
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

        // 内容区（裁剪 + 等比缩放）
        contentClip.frame = CGRect(x: 0, y: titleBarHeight, width: width, height: height - titleBarHeight)
        contentClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentClip.clipsToBounds = true
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

        // 缩放手柄
        let handleSize: CGFloat = 28
        resizeHandle.frame = CGRect(x: width - handleSize - 6,
                                    y: height - handleSize - 6,
                                    width: handleSize,
                                    height: handleSize)
        resizeHandle.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        resizeHandle.layer.cornerRadius = handleSize / 2
        resizeHandle.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        addSubview(resizeHandle)

        // 手势
        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        titleBar.addGestureRecognizer(move)
        let resize = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        resizeHandle.addGestureRecognizer(resize)

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)（内容按屏幕等比缩放）")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentClip.frame = CGRect(x: 0,
                                   y: titleBarHeight,
                                   width: bounds.width,
                                   height: max(0, bounds.height - titleBarHeight))
        applyContentScale()
    }

    /// 把整屏尺寸的容器等比缩放并居中放进内容区。
    private func applyContentScale() {
        let screen = UIScreen.main.bounds.size
        guard screen.width > 0, screen.height > 0, contentClip.bounds.width > 0, contentClip.bounds.height > 0 else { return }

        let scale = min(contentClip.bounds.width / screen.width,
                        contentClip.bounds.height / screen.height)
        let container = sceneHost.container

        container.layer.anchorPoint = .zero
        container.transform = CGAffineTransform(scaleX: scale, y: scale)
        container.bounds = CGRect(origin: .zero, size: screen)
        container.layer.position = CGPoint(x: (contentClip.bounds.width - screen.width * scale) / 2.0,
                                           y: (contentClip.bounds.height - screen.height * scale) / 2.0)
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
            var newFrame = moveOriginFrame.offsetBy(dx: dx, dy: dy)
            let screen = UIScreen.main.bounds
            newFrame.origin.x = max(0, min(newFrame.origin.x, screen.width - 60))
            newFrame.origin.y = max(0, min(newFrame.origin.y, screen.height - 60))
            frame = newFrame
        default:
            break
        }
    }

    // MARK: - 缩放

    @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            resizeOriginFrame = frame
            resizeOriginPoint = point
        case .changed:
            let dx = point.x - resizeOriginPoint.x
            let dy = point.y - resizeOriginPoint.y
            let screen = UIScreen.main.bounds
            var width = resizeOriginFrame.width + dx
            var height = resizeOriginFrame.height + dy
            width = max(220, min(width, screen.width - resizeOriginFrame.origin.x - 8))
            height = max(180, min(height, screen.height - resizeOriginFrame.origin.y - 8))
            frame = CGRect(x: resizeOriginFrame.origin.x,
                           y: resizeOriginFrame.origin.y,
                           width: width,
                           height: height)
        default:
            break
        }
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
