import UIKit

/// 单个 App 的浮窗外壳：标题栏（拖动 + 关闭）+ 内容（App 场景）+ 缩放手柄。
final class AevonWindowView: UIView {
    let bundleID: String

    private let titleBarHeight: CGFloat = 40
    private let contentView: UIView
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let resizeHandle = UIView()

    private var moveOriginFrame: CGRect = .zero
    private var moveOriginPoint: CGPoint = .zero
    private var resizeOriginFrame: CGRect = .zero
    private var resizeOriginPoint: CGPoint = .zero

    init(contentView: UIView, bundleID: String, title: String) {
        self.bundleID = bundleID
        self.contentView = contentView
        super.init(frame: CGRect.zero)

        let screen = UIScreen.main.bounds
        let width = screen.width * 0.78
        let height = screen.height * 0.60
        frame = CGRect(x: (screen.width - width) / 2.0,
                       y: screen.height * 0.15,
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

        titleLabel.frame = CGRect(x: 12, y: 0, width: width - 80, height: titleBarHeight)
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

        // 内容（App 场景）
        contentView.frame = CGRect(x: 0, y: titleBarHeight, width: width, height: height - titleBarHeight)
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentView)

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

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        contentView.removeFromSuperview()
        removeFromSuperview()
    }
}
