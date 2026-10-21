import UIKit

/// 悬浮球根视图：命中自身时返回 nil，让触摸穿透到下层窗口。
final class AevonBubbleRootView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === self ? nil : hit
    }
}

final class AevonBubbleController: UIViewController {
    override func loadView() {
        let root = AevonBubbleRootView()
        root.backgroundColor = .clear
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view = root
    }
}

/// 悬浮球入口：不依赖任何系统 hook 的唯一切入点。
///
/// 为什么改成悬浮球：
///   V0.0.6 通过 hook `SBIconView -applicationShortcutItems` 往长按菜单里塞一项，
///   实测长按图标约 220ms 后 SpringBoard 直接收到 SIGBUS 退出（日志停在
///   「SBIconView applicationShortcutItems 首次调用」）。伪造 SpringBoard 的
///   快捷菜单项要依赖未公开类的内部约束，代价是把整个桌面拖下水。
///   悬浮球只是「我们自己窗口里的一个按钮」，系统路径上零改动。
final class AevonBubble {
    static let shared = AevonBubble()
    private init() {}

    private var window: AevonPassthroughWindow?
    private var ball: UIButton?
    private var picker: AevonAppPickerView?
    private var panStart: CGPoint = .zero
    private var ballOrigin: CGPoint = .zero

    var isVisible: Bool { window != nil }

    // MARK: - 创建

    func install(attempt: Int, reason: String) {
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        guard AevonPrefs.bool("BubbleEnabled", default: true) else {
            AevonLog.info("[悬浮球] 开关已关闭，不创建")
            return
        }
        if window != nil { return }
        guard attempt <= 12 else {
            AevonLog.warn("[悬浮球] 多次尝试仍没有可用场景，放弃本次创建（原因：\(reason)）")
            return
        }
        guard let scene = AevonHostWindow.firstWindowScene() else {
            AevonLog.info("[悬浮球] 暂无前台场景，1.5 秒后重试（第 \(attempt) 次，\(reason)）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.install(attempt: attempt + 1, reason: reason)
            }
            return
        }

        let host = AevonPassthroughWindow(windowScene: scene)
        host.frame = UIScreen.main.bounds
        host.backgroundColor = .clear
        // 比普通窗口高、比系统弹窗低（UIWindowLevelAlert = 2000）
        host.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)

        let root = AevonBubbleController()
        host.rootViewController = root
        host.isHidden = false

        let size: CGFloat = 54
        let screen = UIScreen.main.bounds
        let button = UIButton(type: .custom)
        button.frame = CGRect(x: screen.width - size - 12,
                              y: screen.height * 0.28,
                              width: size,
                              height: size)
        button.setTitle("A", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        button.backgroundColor = UIColor(red: 0.10, green: 0.48, blue: 0.95, alpha: 0.92)
        button.layer.cornerRadius = size / 2
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.addTarget(self, action: #selector(ballTapped), for: .touchUpInside)
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(ballPanned(_:))))

        root.view.addSubview(button)

        window = host
        ball = button
        AevonLog.info("[悬浮球] 已创建（level=\(host.windowLevel.rawValue)，scene=\(scene.activationState.rawValue)，原因=\(reason)）")
    }

    // MARK: - 交互

    @objc private func ballTapped() {
        AevonLog.info("[悬浮球] 点击，打开应用选择面板")
        guard let root = window?.rootViewController else { return }
        if let existing = picker {
            existing.removeFromSuperview()
            picker = nil
            return
        }
        let apps = AevonAppList.userApps(forceReload: true)
        let panel = AevonAppPickerView(apps: apps) { [weak self] in
            self?.picker = nil
        }
        panel.frame = root.view.bounds
        root.view.addSubview(panel)
        picker = panel
    }

    @objc private func ballPanned(_ gesture: UIPanGestureRecognizer) {
        guard let button = ball, let superview = button.superview else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            panStart = point
            ballOrigin = button.frame.origin
        case .changed:
            var frame = button.frame
            frame.origin.x = ballOrigin.x + (point.x - panStart.x)
            frame.origin.y = ballOrigin.y + (point.y - panStart.y)
            frame.origin.x = min(max(4, frame.origin.x), superview.bounds.width - frame.width - 4)
            frame.origin.y = min(max(50, frame.origin.y), superview.bounds.height - frame.height - 40)
            button.frame = frame
        default:
            break
        }
    }
}
