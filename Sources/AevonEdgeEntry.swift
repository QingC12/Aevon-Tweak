import UIKit
import QuartzCore

/// 屏幕右侧边缘的手势条。
///
/// 逆向证据（Stheno.dylib）：`_showEgdeGesture` / `_edgeWidth` / `_effectEdge` /
/// `EdgeGestureShape` / `EgdeGestureView`（原文拼写如此）/ `EdgeBarControlView`，
/// 本地化文案 `EBCI = 触发边::开启可调节`、`GestureIntroduction = <<<浮窗手势区域为边缘外侧…>>>`。
/// 即：Stheno 用一个贴着屏幕边缘、比整条边窄的手势区域来唤起界面，宽度可调、触发边可选。
///
/// 演进记录：
///   · V0.0.17：弃用 `UIScreenEdgePanGestureRecognizer`，改自己接管原始触摸；
///   · V0.0.18：**挂载位置从「独立窗口」改为「统一入口窗口」**（见 `AevonEntryHost`）。
///     独立窗口版本在桌面裸态和 App 前台收不到任何触摸（日志里零 `收到触摸`），
///     而同一时刻悬浮球窗口的点击一直是好的 —— 所以直接搬家到那个可用容器里。
///     同时几何改为「按父视图 bounds 落位 + layoutSubviews 自愈」，
///     杜绝「挂上去的时候父视图还是零尺寸、子视图永远落在 bounds 之外」这种死角。
final class AevonEdgeStripView: UIView {
    /// 热区宽度。太宽会抢掉 App 自己靠右边缘的手势，34pt 是「好呼出」与「少误触」的折中。
    static let hitWidth: CGFloat = 34
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

    /// 右侧条带（逻辑坐标），供触摸探针判断「事件落在条带里」
    static func bandRect(in bounds: CGRect) -> CGRect {
        return CGRect(x: bounds.maxX - hitWidth,
                      y: bounds.midY,
                      width: hitWidth,
                      height: bounds.height - bounds.midY)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 父视图尺寸变化时保持「贴右边缘 + 占下半屏」
        autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin, .flexibleHeight]

        // 一条很淡的竖线当作"这里有东西"的提示，不喧宾夺主
        indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.20)
        indicator.layer.cornerRadius = 1.5
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)
        layoutIndicator()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        holdTimer?.invalidate()
    }

    /// 按父视图 bounds 重新落位（幂等）。父视图还没布局时直接返回，等 layoutSubviews 再来一次。
    func layoutInParent() {
        guard let parent = superview else { return }
        let bounds = parent.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        frame = AevonEdgeStripView.bandRect(in: bounds)
        layoutIndicator()
    }

    private func layoutIndicator() {
        indicator.frame = CGRect(x: bounds.width - 3,
                                 y: (bounds.height - 96) / 2,
                                 width: 3,
                                 height: 96)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutIndicator()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // 挂上去 / 重新挂上去时校正一次几何，避免父视图当时还没布局
        layoutInParent()
        indicator.alpha = 0
        UIView.animate(withDuration: 0.6, delay: 1.2, options: [.curveEaseOut]) {
            self.indicator.alpha = 1
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
        AevonLog.info("[边缘] 手势条命中（\(reason)）")
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
enum AevonEdgeEntry {
    private static var strip: AevonEdgeStripView?
    private static var picker: AevonAppPickerView?
    private static var lastProbeLogAt: CFTimeInterval = 0
    private static var loggedDisabled = false

    /// 窗口层兜底判定的状态
    private static var probeStart: CGPoint?
    private static var lastTriggerAt: CFTimeInterval = 0
    private static var loggedProbeBegan = false

    /// 手势条是否已挂上（不代表手势一定能触发，触发靠系统触摸分发）
    static var isVisible: Bool { return strip != nil }

    static func install(attempt: Int, reason: String) {
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        guard AevonPrefs.bool("EdgeGestureEnabled", default: true) else {
            if !loggedDisabled {
                loggedDisabled = true
                AevonLog.info("[边缘] 开关已关闭，不创建手势条")
            }
            return
        }
        if let existing = strip {
            // 已存在：只做一次几何自愈，不重复创建
            existing.layoutInParent()
            return
        }
        guard let root = AevonEntryHost.ensureInstalled(attempt: attempt, reason: reason) else { return }

        let view = AevonEdgeStripView(frame: .zero)
        view.onTrigger = { attemptTrigger("手势条") }
        root.addSubview(view)
        view.layoutInParent()

        strip = view
        let rootBounds = root.bounds
        AevonLog.info("[边缘] 手势条已挂到入口窗口（\(Int(view.frame.width))x\(Int(view.frame.height))，原点 \(Int(view.frame.minX)),\(Int(view.frame.minY))，根视图 \(Int(rootBounds.width))x\(Int(rootBounds.height))，触发=左滑≥\(Int(AevonEdgeStripView.swipeDistance))pt 或 长按\(Int(AevonEdgeStripView.holdDuration * 1000))ms）（AevonEdgeTouch）")

        // 圆盘的默认内容：首次使用时用应用列表预填，保证呼出不是空盘
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AevonRingStore.seedIfNeeded(from: AevonAppList.userApps())
        }
    }

    /// 尺寸 / 屏幕变化后重新落位。
    static func refreshLayoutIfNeeded() {
        strip?.layoutInParent()
    }

    /// 统一触发入口（手势条与窗口层兜底都走这里），带 0.6 秒去重，
    /// 避免「手势条判一次 + 窗口兜底再判一次」把圆盘开了又关。
    static func attemptTrigger(_ reason: String) {
        let now = CACurrentMediaTime()
        guard now - lastTriggerAt > 0.6 else { return }
        guard !AevonRingMenu.isPresented else { return }
        lastTriggerAt = now
        AevonLog.info("[边缘] 触发（\(reason)），呼出圆盘")
        presentRing()
    }

    /// 触摸探针 + 窗口层兜底判定。
    ///
    /// 两件事：
    ///  1. **诊断**：事件到达入口窗口时记一笔（只记右侧条带内、限流），
    ///     下次日志若「有窗口事件、没有手势区收到触摸」，就说明是命中/图层问题。
    ///  2. **兜底**：直接在窗口层做一次左滑判定。`sendEvent` 只要窗口收到事件就会调用，
    ///     不经过 hitTest —— 哪怕手势条因为任何原因命中不到，手势照样能用。
    static func attachProbe(to window: AevonEntryWindow) {
        window.eventProbe = { point, phase in
            guard AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return }
            let band = AevonEdgeStripView.bandRect(in: UIScreen.main.bounds)
            // 上下左右各放宽一点，手指刚压上去的抖动不算出界
            let slack = band.insetBy(dx: -10, dy: -8)
            let inside = slack.contains(point)

            switch phase {
            case .began:
                probeStart = inside ? point : nil
                // 关键诊断：任何落点都记一次（限流），用来判断触摸到底有没有进我们的窗口
                let now = CACurrentMediaTime()
                if now - lastProbeLogAt > 3.0 {
                    lastProbeLogAt = now
                    AevonLog.info("[边缘] 入口窗口收到触摸 (x=\(Int(point.x)), y=\(Int(point.y))，条带内=\(inside ? "是" : "否")，条带 \(Int(band.minX))~\(Int(band.maxX)) x \(Int(band.minY))~\(Int(band.maxY)))")
                }
                if inside, !loggedProbeBegan {
                    loggedProbeBegan = true
                    AevonLog.info("[边缘] 窗口层已接管边缘触摸（兜底判定生效）")
                }
            case .moved:
                guard inside, let start = probeStart else { return }
                let dx = point.x - start.x
                let dy = point.y - start.y
                if dx <= -AevonEdgeStripView.swipeDistance, abs(dx) >= abs(dy) * 0.7 {
                    attemptTrigger("窗口层左滑 \(Int(dx))pt")
                }
            default:
                probeStart = nil
            }
        }
    }

    /// 呼出圆盘。
    static func presentRing() {
        guard let root = AevonEntryHost.rootView else {
            AevonLog.warn("[圆盘] 入口窗口不可用，无法呼出")
            return
        }
        AevonRingMenu.present(in: root)
    }

    /// 圆盘展开期间关掉边缘手势条（避免它继续吃掉圆盘上的滑动），收起时恢复。
    static func setStripInteraction(_ enabled: Bool) {
        strip?.isUserInteractionEnabled = enabled
    }

    /// 打开完整应用面板。
    static func openPanel(preferRingEditing: Bool = false) {
        guard let root = AevonEntryHost.rootView else {
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
        // 面板全屏覆盖，把备用悬浮球提到最上层，保持「点球收起」的手感
        AevonBubble.shared.bringBallToFront()
    }

    /// 供悬浮球（备用入口）复用同一套面板。
    static func hostRootView() -> UIView? {
        return AevonEntryHost.rootView
    }
}
