import UIKit

/// 屏幕右侧边缘的手势条。
///
/// 逆向证据（Stheno.dylib）：`_showEgdeGesture` / `_edgeWidth` / `_effectEdge` /
/// `EdgeGestureShape` / `EgdeGestureView`（原文拼写如此）/ `EdgeBarControlView`，
/// 本地化文案 `EBCI = 触发边::开启可调节`、`GestureIntroduction = <<<浮窗手势区域为边缘外侧…>>>`。
/// 即：Stheno 用一个贴着屏幕边缘、比整条边窄的手势区域来唤起界面，宽度可调、触发边可选。
///
/// 本实现：贴右边、只覆盖下半屏的一段透明条，上面挂 `UIScreenEdgePanGestureRecognizer`，
/// 向左滑即呼出圆盘。条的宽度写死 22pt（热区太宽会抢掉 App 自己的返回手势）。
final class AevonEdgeStripView: UIView {
    static let hitWidth: CGFloat = 22

    var onTrigger: (() -> Void)?
    private let indicator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        // 一条很淡的竖线当作"这里有东西"的提示，不喧宾夺主
        indicator.frame = CGRect(x: frame.width - 3, y: (frame.height - 96) / 2, width: 3, height: 96)
        indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.20)
        indicator.layer.cornerRadius = 1.5
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)

        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        pan.edges = .right
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 提示条随窗口出现淡入，避免整块黑条突兀
        if window != nil {
            indicator.alpha = 0
            UIView.animate(withDuration: 0.6, delay: 1.2, options: [.curveEaseOut]) {
                self.indicator.alpha = 1
            }
        }
    }

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: self)
            if translation.x < -6 {
                indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.55)
            }
        case .ended:
            indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.20)
            let translation = gesture.translation(in: self)
            // 向左滑超过 34pt 才认为是"呼出"，避免误触
            guard translation.x <= -34 else { return }
            AevonLog.info("[边缘] 右侧边缘左滑 \(Int(translation.x))pt，呼出圆盘")
            onTrigger?()
        case .cancelled, .failed:
            indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.20)
        default:
            break
        }
    }
}

/// 边缘手势入口：替代桌面悬浮球。
///
/// 与悬浮球共用同一套「穿透窗口」结构（未命中的触摸直接交给下层），
/// 只是把那个 54pt 的圆球换成贴着右边缘的一条窄手势区。
enum AevonEdgeEntry {
    private static var window: AevonPassthroughWindow?
    private static var strip: AevonEdgeStripView?
    private static var picker: AevonAppPickerView?

    static var isVisible: Bool { return window != nil }

    static func install(attempt: Int, reason: String) {
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        guard AevonPrefs.bool("EdgeGestureEnabled", default: true) else {
            AevonLog.info("[边缘] 开关已关闭，不创建手势区")
            return
        }
        if window != nil { return }
        guard attempt <= 12 else {
            AevonLog.warn("[边缘] 多次尝试仍没有可用场景，放弃本次创建（原因：\(reason)）")
            return
        }
        guard let scene = AevonHostWindow.firstWindowScene() else {
            AevonLog.info("[边缘] 暂无前台场景，1.5 秒后重试（第 \(attempt) 次，\(reason)）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                install(attempt: attempt + 1, reason: reason)
            }
            return
        }

        let host = AevonPassthroughWindow(windowScene: scene)
        host.frame = UIScreen.main.bounds
        host.backgroundColor = .clear
        host.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)

        let root = AevonBubbleController()
        host.rootViewController = root
        host.isHidden = false

        let screen = UIScreen.main.bounds
        let stripHeight = screen.height * 0.5
        let stripView = AevonEdgeStripView(frame: CGRect(x: screen.width - AevonEdgeStripView.hitWidth,
                                                         y: screen.height - stripHeight,
                                                         width: AevonEdgeStripView.hitWidth,
                                                         height: stripHeight))
        stripView.onTrigger = {
            presentRing()
        }
        root.view.addSubview(stripView)

        window = host
        strip = stripView
        AevonLog.info("[边缘] 手势区已创建（右边下半屏 \(Int(AevonEdgeStripView.hitWidth))x\(Int(stripHeight))，level=\(host.windowLevel.rawValue)）")

        // 圆盘的默认内容：首次使用时用应用列表预填，保证呼出不是空盘
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AevonRingStore.seedIfNeeded(from: AevonAppList.userApps())
        }
    }

    /// 呼出圆盘。
    static func presentRing() {
        guard let root = window?.rootViewController?.view else {
            AevonLog.warn("[圆盘] 入口窗口不可用，无法呼出")
            return
        }
        AevonRingMenu.present(in: root)
    }

    /// 打开完整应用面板。
    static func openPanel(preferRingEditing: Bool = false) {
        guard let root = window?.rootViewController?.view else {
            AevonLog.warn("[面板] 入口窗口不可用，无法打开面板")
            return
        }
        if let existing = picker {
            existing.removeFromSuperview()
            picker = nil
            return
        }
        let apps = AevonAppList.userApps(forceReload: true)
        let panel = AevonAppPickerView(apps: apps,
                                       initialMode: preferRingEditing ? 2 : 0) {
            AevonEdgeEntry.picker = nil
        }
        panel.frame = root.bounds
        root.addSubview(panel)
        picker = panel
    }

    /// 供悬浮球（旧入口，默认关闭）复用同一套面板。
    static func hostRootView() -> UIView? {
        return window?.rootViewController?.view
    }
}
