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

/// 备用入口：一个可以拖动的小圆球。
///
/// V0.0.18：不再自己建窗口，改为挂在 `AevonEntryHost` 的统一入口窗口里
/// （那个窗口的触摸在真机上一直是好的，边缘手势条也搬进去了）。
///
/// 为什么当初改成悬浮球（历史原因，保留说明）：
///   V0.0.6 通过 hook `SBIconView -applicationShortcutItems` 往长按菜单里塞一项，
///   实测长按图标约 220ms 后 SpringBoard 直接收到 SIGBUS 退出。桌面快捷菜单这条路
///   依赖未公开类的内部约束，代价是把整个桌面拖下水，所以入口一律走「自己的窗口 + 自己的视图」。
final class AevonBubble {
    static let shared = AevonBubble()
    private init() {}

    private var ball: UIButton?
    private var picker: AevonAppPickerView?
    private var panStart: CGPoint = .zero
    private var ballOrigin: CGPoint = .zero
    private var loggedDisabled = false

    var isVisible: Bool { return ball != nil }

    // MARK: - 创建

    func install(attempt: Int, reason: String) {
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        guard AevonPrefs.bool("BubbleEnabled", default: false) else {
            if !loggedDisabled {
                loggedDisabled = true
                AevonLog.info("[悬浮球] 开关已关闭，不创建（备用入口）")
            }
            return
        }
        if ball != nil { return }
        guard let root = AevonEntryHost.ensureInstalled(attempt: attempt, reason: reason) else { return }

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

        root.addSubview(button)
        ball = button
        AevonLog.info("[悬浮球] 已挂到入口窗口（level=\(Int(root.window?.windowLevel.rawValue ?? 0))，原因=\(reason)）")
    }

    /// 把球提到最上层（面板 / 圆盘都是全屏视图，会把球盖住）。
    func bringBallToFront() {
        guard let button = ball, let parent = button.superview else { return }
        parent.bringSubviewToFront(button)
    }

    /// 尺寸变化后校正球的位置（保持在屏内）。
    func refreshLayoutIfNeeded() {
        guard let button = ball, let parent = button.superview else { return }
        let bounds = parent.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        var frame = button.frame
        frame.origin.x = min(max(4, frame.origin.x), bounds.width - frame.width - 4)
        frame.origin.y = min(max(50, frame.origin.y), bounds.height - frame.height - 40)
        button.frame = frame
    }

    // MARK: - 交互

    @objc private func ballTapped() {
        AevonLog.info("[悬浮球] 点击，打开应用选择面板")
        guard let root = AevonEntryHost.activeRoot else { return }
        if let existing = picker {
            existing.removeFromSuperview()
            picker = nil
            return
        }
        let apps = AevonAppList.userApps(forceReload: true)
        let panel = AevonAppPickerView(apps: apps) { [weak self] in
            self?.picker = nil
        }
        panel.frame = root.bounds
        root.addSubview(panel)
        picker = panel
        bringBallToFront()
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
