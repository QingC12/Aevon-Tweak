import UIKit
import QuartzCore

/// 屏幕右侧边缘的手势条。
///
/// 逆向证据（Stheno.dylib）：`_showEgdeGesture` / `_edgeWidth` / `_effectEdge` /
/// `EdgeGestureShape` / `EgdeGestureView`（原文拼写如此）/ `EdgeBarControlView`，
/// 本地化文案 `EBCI = 触发边::开启可调节`、`GestureIntroduction = <<<浮窗手势区域为边缘外侧…>>>`。
/// 即：Stheno 用一个贴着屏幕边缘、比整条边窄的手势区域来唤起界面，宽度可调、触发边可选。
///
/// V0.0.17 改动（**重要**）：不再使用 `UIScreenEdgePanGestureRecognizer`。
/// V0.0.16 的日志里整场会话没有一条 `[边缘] 右侧边缘左滑`，说明系统边缘手势识别器
/// 根本没被唤起到 —— 屏幕边缘手势是系统与第三方「左滑返回」类插件争抢最激烈的地方，
/// 只要同方向有别的识别器先认领，我们的 `.right` 边缘识别器就永远停在 `.possible`。
/// 现在改成**自己接管原始触摸**（`touchesBegan/Moved/Ended`）：
///   · 左滑 ≥ `swipeDistance`（横向占优）→ 触发；
///   · 原地按住 ≥ `holdDuration` → 触发（备用路径，不依赖任何滑动，几乎不可能被抢）；
///   · 每次触摸都写日志，便于从日志判断「触摸有没有到达这一层」。
final class AevonEdgeStripView: UIView {
    /// 热区宽度。太宽会抢掉 App 自己靠右边缘的手势，22~26 是折中值。
    static let hitWidth: CGFloat = 26
    /// 判定为「呼出」的横向位移
    static let swipeDistance: CGFloat = 30
    /// 长按触发时长（秒）
    static let holdDuration: TimeInterval = 0.42

    var onTrigger: (() -> Void)?

    private let indicator = UIView()
    private var touchStart: CGPoint = .zero
    private var touchBeganAt: CFTimeInterval = 0
    private var fired = false
    private var holdTimer: Timer?
    private var lastTouchLogAt: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        // 一条很淡的竖线当作"这里有东西"的提示，不喧宾夺主
        indicator.frame = CGRect(x: frame.width - 3, y: (frame.height - 96) / 2, width: 3, height: 96)
        indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.20)
        indicator.layer.cornerRadius = 1.5
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        holdTimer?.invalidate()
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

    // MARK: - 触摸（不使用手势识别器）

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), isUserInteractionEnabled else { return }
        touchStart = point
        touchBeganAt = CACurrentMediaTime()
        fired = false

        let now = CACurrentMediaTime()
        if now - lastTouchLogAt > 0.8 {
            lastTouchLogAt = now
            AevonLog.info("[边缘] 手势区收到触摸 (条内 x=\(Int(point.x)), y=\(Int(point.y))，条宽 \(Int(bounds.width))，高 \(Int(bounds.height)))")
        }

        UIView.animate(withDuration: 0.12) {
            self.indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.55)
        }
        scheduleHold()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !fired else { return }
        let dx = point.x - touchStart.x
        let dy = point.y - touchStart.y
        // 横向位移占优且足够大，才当作「向左滑呼出」，避免纵向滑动误触
        if dx <= -AevonEdgeStripView.swipeDistance, abs(dx) >= abs(dy) * 0.7 {
            fire(reason: "左滑 \(Int(dx))pt")
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelHold()
        restoreIndicator()
        guard !fired else { return }
        let point = touches.first?.location(in: self) ?? touchStart
        let dx = point.x - touchStart.x
        let dy = point.y - touchStart.y
        let duration = Int((CACurrentMediaTime() - touchBeganAt) * 1000)
        AevonLog.info("[边缘] 手势区触摸结束未触发（dx=\(Int(dx)), dy=\(Int(dy)), 持续 \(duration)ms，阈值：左滑 \(-Int(AevonEdgeStripView.swipeDistance))pt 或长按 \(Int(AevonEdgeStripView.holdDuration * 1000))ms）")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelHold()
        restoreIndicator()
    }

    // MARK: - 触发

    private func scheduleHold() {
        cancelHold()
        let timer = Timer(timeInterval: AevonEdgeStripView.holdDuration, repeats: false) { [weak self] _ in
            guard let self = self, !self.fired else { return }
            self.fire(reason: "边缘长按 \(Int(AevonEdgeStripView.holdDuration * 1000))ms")
        }
        // 手指按住时 RunLoop 处于 tracking 模式，必须挂到 common modes 才会触发
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func fire(reason: String) {
        guard !fired else { return }
        fired = true
        cancelHold()
        AevonLog.info("[边缘] 触发（\(reason)），呼出圆盘")
        indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.85)
        onTrigger?()
    }

    private func restoreIndicator() {
        UIView.animate(withDuration: 0.2) {
            self.indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.20)
        }
    }
}

/// 边缘手势入口：圆盘的主入口。
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
        // 比普通窗口高、比系统弹窗低（UIWindowLevelAlert = 2000）
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
        AevonLog.info("[边缘] 手势区已创建（右边下半屏 \(Int(AevonEdgeStripView.hitWidth))x\(Int(stripHeight))，level=\(host.windowLevel.rawValue)，触发=左滑≥\(Int(AevonEdgeStripView.swipeDistance))pt 或 长按\(Int(AevonEdgeStripView.holdDuration * 1000))ms）（AevonEdgeTouch）")

        // 圆盘的默认内容：首次使用时用应用列表预填，保证呼出不是空盘
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AevonRingStore.seedIfNeeded(from: AevonAppList.userApps())
        }
    }

    /// 呼出圆盘。
    static func presentRing() {
        guard let host = window, let root = host.rootViewController?.view else {
            AevonLog.warn("[圆盘] 入口窗口不可用，无法呼出")
            return
        }
        // 把入口窗口提到最前，避免被同级的悬浮球窗口挡住导致点了没反应
        host.isHidden = false
        host.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        AevonRingMenu.present(in: root)
    }

    /// 圆盘展开期间关掉边缘手势条（避免它继续吃掉圆盘上的滑动），收起时恢复。
    static func setStripInteraction(_ enabled: Bool) {
        strip?.isUserInteractionEnabled = enabled
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

    /// 供悬浮球（备用入口）复用同一套面板。
    static func hostRootView() -> UIView? {
        return window?.rootViewController?.view
    }
}
