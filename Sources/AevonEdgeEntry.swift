import UIKit
import QuartzCore

/// 圆盘触发热区（V0.0.25）。
///
/// 用户可在 设置 → Aevon → 「圆盘触发区域」调整三项：
///   · `RingTriggerY`      热区**中心**在屏幕高度的百分比（0~100，默认 75，正好是圆盘圆心）
///   · `RingTriggerWidth`  热区横向宽度（pt，从右边缘往左，默认 48）
///   · `RingTriggerHeight` 热区纵向高度（pt，默认 320）
///
/// **三个入口通道（手势条视图 / 入口窗口探针 / 全局 sendEvent 通道）都只认这个矩形**，
/// 保证「设置里调的那块区域」就是实际能呼出的区域 —— V0.0.24 的问题是全局通道用了
/// 固定的「右 60pt × 下半屏 70%」，结果右侧一大片都能划出圆盘。
enum AevonTriggerZone {
    static let defaultCenterRatio: Double = 75
    static let defaultWidth: Double = 48
    static let defaultHeight: Double = 320

    static var centerRatio: CGFloat {
        let value = AevonPrefs.double("RingTriggerY", default: defaultCenterRatio)
        return CGFloat(min(max(value, 0), 100)) / 100
    }

    static var width: CGFloat {
        let value = AevonPrefs.double("RingTriggerWidth", default: defaultWidth)
        return CGFloat(min(max(value, 18), 140))
    }

    static var height: CGFloat {
        let value = AevonPrefs.double("RingTriggerHeight", default: defaultHeight)
        return CGFloat(min(max(value, 80), 900))
    }

    /// 屏幕坐标下的热区（贴右边缘；纵向以 centerRatio 为中心，并夹紧在屏内）
    static func rect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 1, bounds.height > 1 else { return .zero }
        let w = min(width, bounds.width)
        let h = min(height, bounds.height)
        let centerY = bounds.height * centerRatio
        let y = min(max(centerY - h / 2, 0), bounds.height - h)
        return CGRect(x: bounds.maxX - w, y: y, width: w, height: h)
    }

    /// 日志用的一行摘要
    static func summary(in bounds: CGRect) -> String {
        let r = rect(in: bounds)
        return "位置 \(Int(centerRatio * 100))% · 宽 \(Int(r.width))pt · 高 \(Int(r.height))pt（区 x \(Int(r.minX))~\(Int(r.maxX)) y \(Int(r.minY))~\(Int(r.maxY))）"
    }

    /// 当前配置的指纹。设置里改了任意一项，指纹就变，SpringBoard 侧据此重排触发条。
    static func signature() -> String {
        return "\(Int((centerRatio * 100).rounded()))|\(Int(width.rounded()))|\(Int(height.rounded()))"
    }
}

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
///   · V0.0.21：热区 34 → 44pt（贴最边缘 20pt 会被 SpringBoard 的系统手势门控吞掉，
///     往里挪一点反而更容易命中）；同时补一条手势识别器通道做兜底。
final class AevonEdgeStripView: UIView {
    /// 判定为「呼出」的横向位移
    static let swipeDistance: CGFloat = 30
    /// 长按触发时长（秒）
    static let holdDuration: TimeInterval = 0.42

    var onTrigger: (() -> Void)?
    /// 触摸流（窗口坐标 + 相位）：圆盘呼出后，这根手指还没松手，
    /// 后续的移动 / 抬起都由这里转给圆盘，实现「图标跟手旋转 + 停住松手开窗」。
    var onTouch: ((_ point: CGPoint, _ phase: UITouch.Phase) -> Void)?

    private let indicator = UIView()
    private var touchStart: CGPoint = .zero
    private var touchBeganAt: CFTimeInterval = 0
    private var fired = false
    private var holdTimer: Timer?
    private var lastTouchLogAt: CFTimeInterval = 0

    /// V0.0.26：触发条颜色跟着系统深浅色走。
    ///
    /// 之前固定用白色 34% —— 白底 App（设置、备忘录、大多数浅色界面）上几乎看不见。
    /// 现在：深色系统 → 灰白；浅色系统 → 黑灰。按下时再提亮一档，仍然遵守同一套明暗。
    private var isDarkAppearance: Bool {
        switch traitCollection.userInterfaceStyle {
        case .dark: return true
        case .light: return false
        default:
            // 入口视图挂在 App 画面容器上，个别时机 trait 还没继承下来，退回全局外观
            return UITraitCollection.current.userInterfaceStyle != .light
        }
    }

    /// 静息态颜色
    private var idleColor: UIColor {
        return isDarkAppearance
            ? UIColor(white: 0.93, alpha: 0.42)
            : UIColor(white: 0.16, alpha: 0.46)
    }

    /// 按下 / 命中态颜色
    private var activeColor: UIColor {
        return isDarkAppearance
            ? UIColor(white: 1.0, alpha: 0.88)
            : UIColor(white: 0.05, alpha: 0.80)
    }

    /// 把颜色重新套到触发条上（外观变化、刚挂上、松手恢复都走这里）
    func applyAppearance(active: Bool = false) {
        indicator.backgroundColor = active ? activeColor : idleColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle else { return }
        applyAppearance()
        AevonLog.info("[边缘] 触发条颜色已随系统外观切换（\(isDarkAppearance ? "深色 → 灰白" : "浅色 → 黑灰")）（AevonStripAdaptiveTintV26）")
    }

    /// 热区矩形（逻辑坐标，来自设置项）。三个通道共用同一个计算，避免「设置里调了但实际没变」。
    static func bandRect(in bounds: CGRect) -> CGRect {
        return AevonTriggerZone.rect(in: bounds)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 父视图尺寸变化时保持「贴右边缘」；纵向位置由 layoutInParent 按配置重算
        autoresizingMask = [.flexibleLeftMargin]

        // 一条淡淡的竖线当作"这里有东西"的提示，不喧宾夺主
        indicator.backgroundColor = idleColor
        indicator.layer.cornerRadius = 2
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)
        layoutIndicator()

        // 兜底通道：系统手势偶尔会把原始 touches 取消掉，识别器仍能独立拿到手势方向。
        // 两个识别器都不取消触摸，所以不会影响上面那套 touchesBegan/Moved 逻辑。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        addGestureRecognizer(pan)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldGesture(_:)))
        hold.minimumPressDuration = AevonEdgeStripView.holdDuration
        hold.cancelsTouchesInView = false
        addGestureRecognizer(hold)
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
        // 白条始终落在热区正中，高度不超过热区本身
        let barHeight = min(120, max(24, bounds.height - 12))
        indicator.frame = CGRect(x: bounds.width - 4,
                                 y: (bounds.height - barHeight) / 2,
                                 width: 4,
                                 height: barHeight)
    }

    // MARK: - 识别器兜底通道

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !fired else { return }
        let translation = gesture.translation(in: self)
        if translation.x <= -AevonEdgeStripView.swipeDistance,
           abs(translation.x) >= abs(translation.y) * 0.7 {
            fire(reason: "识别器左滑 \(Int(translation.x))pt")
        }
    }

    @objc private func handleHoldGesture(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !fired else { return }
        fire(reason: "识别器长按")
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
        applyAppearance()
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
        onTouch?(convert(point, to: nil), .began)

        let now = CACurrentMediaTime()
        if now - lastTouchLogAt > 0.8 {
            lastTouchLogAt = now
            AevonLog.info("[边缘] 手势区收到触摸 (条内 x=\(Int(point.x)), y=\(Int(point.y))，条宽 \(Int(bounds.width))，高 \(Int(bounds.height)))")
        }

        UIView.animate(withDuration: 0.12) {
            self.applyAppearance(active: true)
        }
        scheduleHold()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        // 无论是否已经触发，都把触摸流转发出去：圆盘要靠它跟手旋转
        onTouch?(convert(point, to: nil), .moved)
        guard !fired else { return }
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
        let point = touches.first?.location(in: self) ?? touchStart
        onTouch?(convert(point, to: nil), .ended)
        guard !fired else { return }
        let dx = point.x - touchStart.x
        let dy = point.y - touchStart.y
        let duration = Int((CACurrentMediaTime() - touchBeganAt) * 1000)
        AevonLog.info("[边缘] 手势区触摸结束未触发（dx=\(Int(dx)), dy=\(Int(dy)), 持续 \(duration)ms，阈值：左滑 \(-Int(AevonEdgeStripView.swipeDistance))pt 或长按 \(Int(AevonEdgeStripView.holdDuration * 1000))ms）")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelHold()
        restoreIndicator()
        if let point = touches.first?.location(in: self) {
            onTouch?(convert(point, to: nil), .cancelled)
        }
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
        indicator.backgroundColor = activeColor
        onTrigger?()
    }

    private func restoreIndicator() {
        UIView.animate(withDuration: 0.2) {
            self.applyAppearance()
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
    /// 最近一次边缘触摸的位置（窗口坐标），圆盘唤出时从这里接手那根手指
    private static var lastTouchPoint: CGPoint = .zero

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
            startTriggerZoneWatch()
            return
        }
        guard let installed = AevonEntryHost.ensureInstalled(attempt: attempt, reason: reason) else { return }
        // 优先挂到「能压住全屏 App」的场景覆盖层上
        let root = AevonEntryHost.activeRoot ?? installed

        let view = AevonEdgeStripView(frame: .zero)
        view.onTrigger = { attemptTrigger("手势条", source: "strip") }
        view.onTouch = { point, phase in handleStripTouch(point, phase) }
        root.addSubview(view)
        view.layoutInParent()

        strip = view
        // V0.0.26：触发区配置实时生效（Darwin 通知 + 0.35 秒轮询兜底）
        AevonEdgeEntry.startTriggerZoneWatch()
        let rootBounds = root.bounds
        AevonLog.info("[边缘] 手势条已挂到入口窗口（\(Int(view.frame.width))x\(Int(view.frame.height))，原点 \(Int(view.frame.minX)),\(Int(view.frame.minY))，根视图 \(Int(rootBounds.width))x\(Int(rootBounds.height))，热区 \(AevonTriggerZone.summary(in: rootBounds))，触发=左滑≥\(Int(AevonEdgeStripView.swipeDistance))pt 或 长按\(Int(AevonEdgeStripView.holdDuration * 1000))ms）（AevonEdgeTouch AevonTriggerZoneV25 AevonRingListLiveV27 AevonAppGuardSideV27）")

        // 圆盘的默认内容：首次使用时用应用列表预填，保证呼出不是空盘
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AevonRingStore.seedIfNeeded(from: AevonAppList.userApps())
        }
    }

    /// 尺寸 / 屏幕变化后重新落位。
    /// `logChange` 为 true 时多打一行「触发区已按设置重排」，方便在真机日志里确认设置生效。
    static func refreshLayoutIfNeeded(logChange: Bool = false) {
        guard let strip = strip else { return }
        strip.layoutInParent()
        strip.applyAppearance()
        if logChange {
            let bounds = strip.superview?.bounds ?? UIScreen.main.bounds
            AevonLog.info("[边缘] 触发区已按设置重排（\(AevonTriggerZone.summary(in: bounds))）（AevonTriggerZoneLiveV26）")
        }
    }

    // MARK: - 触发区实时生效（V0.0.26）

    /// 设置里改完立刻生效的两条通道：
    ///   1. **Darwin 通知**：设置页每次写值后立刻广播，延迟≈0；
    ///   2. **0.35 秒轮询兜底**：通知万一没到（设置进程被杀、跨进程通知丢失），
    ///      最迟一个轮询周期内也会跟上。
    ///
    /// 之前只靠看门狗每 3 秒的一次 refresh，而且 `CFPreferencesCopyAppValue`
    /// 在 SpringBoard 进程内还有缓存 —— 用户拖完滑杆盯着屏幕看，触发条就是不动。
    static func startTriggerZoneWatch() {
        migrateLegacyBrokenZoneIfNeeded()
        if zoneSignature.isEmpty { zoneSignature = AevonTriggerZone.signature() }
        if !prefsObserverInstalled {
            prefsObserverInstalled = true
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           nil,
                                           aevonPrefsChangedHandler,
                                           "com.aevon.prefschanged" as CFString,
                                           nil,
                                           .deliverImmediately)
            AevonLog.info("[边缘] 已监听设置变更通知（com.aevon.prefschanged）（AevonPrefsLiveV26）")
        }
        guard zoneTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            AevonPrefs.synchronize()
            AevonRingStore.invalidateCache()
            checkTriggerZoneChange()
        }
        RunLoop.main.add(timer, forMode: .common)
        zoneTimer = timer
    }

    /// V0.0.28：修掉 V0.0.27 留下的「触发区被写成 0% / 18pt / 80pt」。
    ///
    /// 那一版三个滑杆的初始值没从偏好读（停在最左端），用户一碰就把 0 写回去，
    /// 于是触发条跑到屏幕最顶部、又细又短 —— 用户以为是「纵向反了」。
    /// 这里按特征值识别（几乎不可能是人为组合），一次性恢复成默认值并记一行日志。
    private static var migratedLegacyZone = false

    private static func migrateLegacyBrokenZoneIfNeeded() {
        guard !migratedLegacyZone else { return }
        migratedLegacyZone = true
        let y = AevonPrefs.double("RingTriggerY", default: -1)
        let w = AevonPrefs.double("RingTriggerWidth", default: -1)
        let h = AevonPrefs.double("RingTriggerHeight", default: -1)
        guard y >= 0, y <= 1.5, w >= 0, w <= 18.5, h >= 0, h <= 80.5 else { return }
        AevonPrefs.set("RingTriggerY", 75)
        AevonPrefs.set("RingTriggerWidth", 48)
        AevonPrefs.set("RingTriggerHeight", 320)
        AevonPrefs.synchronize()
        zoneSignature = ""
        AevonLog.warn("[边缘] 检测到上一版误写的触发区（≈0% / 18pt / 80pt），已恢复默认 75% / 48pt / 320pt（AevonTriggerZoneResetV28）")
    }

    /// 指纹变了就重排触发条（幂等；没变什么都不做）
    static func checkTriggerZoneChange() {
        let signature = AevonTriggerZone.signature()
        guard signature != zoneSignature else { return }
        zoneSignature = signature
        refreshLayoutIfNeeded(logChange: true)
    }

    private static var zoneTimer: Timer?
    private static var zoneSignature = ""
    private static var prefsObserverInstalled = false

    /// 统一触发入口（手势条 / 窗口层兜底 / 识别器都走这里），带 0.6 秒去重。
    /// `source` 决定后续触摸流转发给圆盘时走哪条通道（圆盘只认最先来的那条）。
    static func attemptTrigger(_ reason: String, source: String) {
        let now = CACurrentMediaTime()
        guard now - lastTriggerAt > 0.6 else { return }
        guard !AevonRingMenu.isPresented else { return }
        lastTriggerAt = now
        AevonLog.info("[边缘] 触发（\(reason)，来源 \(source)），呼出圆盘")
        presentRing(source: source)
    }

    /// 边缘手势条的触摸流：唤出圆盘后那根手指还没松手，交给圆盘做「跟手旋转 / 逆时针选定」。
    private static func handleStripTouch(_ point: CGPoint, _ phase: UITouch.Phase) {
        lastTouchPoint = point
        guard let ring = AevonRingMenu.presented else { return }
        switch phase {
        case .began:
            ring.beginRemoteTracking(at: point, source: "strip")
        case .moved:
            ring.remoteMoved(to: point, source: "strip")
        case .ended:
            ring.remoteEnded(at: point, source: "strip")
        case .cancelled:
            ring.remoteCancelled(source: "strip")
        default:
            break
        }
    }

    /// 触摸探针 + 窗口层兜底判定。
    ///
    /// 三件事：
    ///  1. **诊断**：事件到达入口窗口时记一笔（限流），用来判断「事件有没有进窗口」。
    ///  2. **兜底触发**：直接在窗口层做左滑 / 长按判定，不经过 hitTest ——
    ///     哪怕手势条因为任何原因命中不到，手势照样能用。
    ///  3. **接力**（V0.0.21 关键修复）：圆盘展开后，唤出它的那根手指还没离开屏幕，
    ///     后续的 moved / ended 从这里转给圆盘，实现「滑出即可旋转、松手即开窗」。
    ///     V0.0.20 缺了这一步，用户看到的就是「圆盘出来后不动，得抬手再摸一次才行」。
    static func attachProbe(to window: AevonEntryWindow) {
        window.eventProbe = { point, phase in
            guard AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return }

            // 圆盘已展开：这根手指继续驱动圆盘（旋转 / 选定 / 松手开窗）
            if let ring = AevonRingMenu.presented {
                switch phase {
                case .began: ring.beginRemoteTracking(at: point, source: "window")
                case .moved: ring.remoteMoved(to: point, source: "window")
                case .ended: ring.remoteEnded(at: point, source: "window")
                case .cancelled: ring.remoteCancelled(source: "window")
                default: break
                }
                return
            }

            let bounds = UIScreen.main.bounds
            // V0.0.25：和全局通道 / 手势条用同一个热区（设置里可调位置与尺寸）
            let band = AevonTriggerZone.rect(in: bounds)
            let inside = band.contains(point)

            switch phase {
            case .began:
                probeStart = inside ? point : nil
                if inside {
                    lastTouchPoint = point
                    scheduleProbeHold()
                }
                // 关键诊断：任何落点都记一次（限流），判断触摸到底有没有进我们的窗口
                let now = CACurrentMediaTime()
                if now - lastProbeLogAt > 3.0 {
                    lastProbeLogAt = now
                    AevonLog.info("[边缘] 入口窗口收到触摸 (x=\(Int(point.x)), y=\(Int(point.y))，宽容区内=\(inside ? "是" : "否")，区 \(Int(band.minX))~\(Int(band.maxX)) x \(Int(band.minY))~\(Int(band.maxY)))")
                }
                if inside, !loggedProbeBegan {
                    loggedProbeBegan = true
                    AevonLog.info("[边缘] 窗口层已接管边缘触摸（兜底判定生效）")
                }
            case .moved:
                guard let start = probeStart else { return }
                lastTouchPoint = point
                let dx = point.x - start.x
                let dy = point.y - start.y
                if abs(dx) > 12 || abs(dy) > 12 { cancelProbeHold() }
                if dx <= -AevonEdgeStripView.swipeDistance, abs(dx) >= abs(dy) * 0.7 {
                    attemptTrigger("窗口层左滑 \(Int(dx))pt", source: "window")
                }
            default:
                probeStart = nil
                cancelProbeHold()
            }
        }
    }

    private static var probeHoldTimer: Timer?

    /// 窗口层的长按兜底（手指按住不动 0.42 秒也能呼出圆盘）。
    private static func scheduleProbeHold() {
        cancelProbeHold()
        let timer = Timer(timeInterval: AevonEdgeStripView.holdDuration, repeats: false) { _ in
            attemptTrigger("窗口层长按", source: "window")
        }
        RunLoop.main.add(timer, forMode: .common)
        probeHoldTimer = timer
    }

    private static func cancelProbeHold() {
        probeHoldTimer?.invalidate()
        probeHoldTimer = nil
    }

    // MARK: - 全局触摸通道（V0.0.23）

    /// 全局通道状态（与手势条 / 窗口探针完全独立，互不干扰）
    private static var globalInstalled = false
    private static var globalTouchID: UInt = 0
    private static var globalStart: CGPoint = .zero
    private static var globalFired = false
    private static var globalHoldTimer: Timer?
    private static var globalLastLogAt: CFTimeInterval = 0

    /// 圆盘接管期（V0.0.24）：只有「全局通道唤起的圆盘」需要把这根手指从 App 手里拿走。
    private static var ringSource = ""
    private static var swallowDeadline: CFTimeInterval = 0
    /// 接管硬上限：无论发生什么，12 秒后一定解除，杜绝「整块屏幕点不动」的最坏情况
    private static let swallowLimit: CFTimeInterval = 12

    /// 热区接管（V0.0.25）：在热区里按下的那根手指，**从 began 起**就完全归我们。
    ///
    /// Aevon(18) 的问题是：触发那一刻 App 已经收到了 began 和前几帧移动，
    /// 于是圆盘虽然展开、后续事件也被吞了，App 的列表照样会被那几帧带起来。
    /// 现在改成「手指一落到热区就接管」，App 连 began 都收不到，彻底不会跟着动。
    ///
    /// 代价是热区内的单击不会被 App 收到 —— 这是「只在特定位置才能呼出」的必然取舍，
    /// 所以热区默认只有 48×380pt，并且位置/宽度/高度都能在设置里调。
    private static var ownsTouch = false
    /// 热区按下后的最长接管时间（秒）。长按 0.42 秒就会触发圆盘，所以 4 秒足够；
    /// 超时后不再吞，避免用户按住很久后突然开始滑动时把触摸还留在我们手里。
    private static let pressLimit: CFTimeInterval = 4

    /// 装全局触摸通道（hook `UIApplication -sendEvent:`）。
    ///
    /// Aevon(16) 日志证明：App 前台时白条可见、但触摸永远进不到手势条 ——
    /// `SBDeviceApplicationSceneViewController.view` 的命中测试把靠右边缘的触摸
    /// 直接交给了 App 画面。视图层的任何几何/层级调整都解决不了，
    /// 只能从事件总入口（UIApplication）拿触摸。
    /// 返回 false 表示这条通道不可用，视图层通道照旧兜底。
    @discardableResult
    static func installGlobalTouch() -> Bool {
        if globalInstalled { return true }
        guard AevonPrefs.bool("Enabled", default: false) else { return false }
        guard AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return false }
        let ok = AevonTouchHookInstall()
        globalInstalled = ok
        if ok {
            AevonLog.info("[边缘] 全局触摸通道已安装（App 前台也能呼出圆盘）（AevonGlobalTouchV23）")
        } else {
            AevonLog.warn("[边缘] 全局触摸通道不可用，退回视图层通道")
        }
        return ok
    }

    /// 全局触摸分发（由 `AevonTouchHook.m` 在 `UIApplication -sendEvent:` 里回调）。
    static func handleGlobal(phase: UITouch.Phase, point: CGPoint, touchID: UInt) {
        guard AevonPrefs.bool("Enabled", default: false),
              AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return }
        let screen = UIScreen.main.bounds
        switch phase {
        case .began:
            // 圆盘已经开着时不再跟踪边缘：此时用户的触摸是在操作圆盘（点图标 / 点空白）
            guard !AevonRingMenu.isPresented else { return }
            // 只认设置里配置的那块热区（位置 / 宽度 / 高度都可调），
            // 不再像 V0.0.24 那样「右侧一大片 + 下半屏」都能划出来。
            let zone = AevonTriggerZone.rect(in: screen)
            guard zone.contains(point) else { return }
            globalTouchID = touchID
            globalStart = point
            globalFired = false
            lastTouchPoint = point
            // V0.0.25：App 前台时，这根手指从按下那一刻就归我们 —— App 连 began 都收不到，
            // 所以不管后面怎么滑动，前台 App 都不会跟着滚。
            ownsTouch = AevonEntryHost.mountedInAppScene
            if ownsTouch { swallowDeadline = CACurrentMediaTime() + pressLimit }
            scheduleGlobalHold()
            let now = CACurrentMediaTime()
            if now - globalLastLogAt > 2.0 {
                globalLastLogAt = now
                AevonLog.info("[边缘] 全局通道收到热区触摸 (x=\(Int(point.x)), y=\(Int(point.y))，\(AevonTriggerZone.summary(in: screen))，接管=\(ownsTouch ? "是" : "否")（AevonGlobalTouchV23 AevonTriggerZoneV25）")
            }

        case .moved:
            guard touchID == globalTouchID else { return }
            lastTouchPoint = point
            if ownsTouch { swallowDeadline = CACurrentMediaTime() + pressLimit }
            // 圆盘已展开：这根手指继续驱动它（旋转 / 选定 / 松手开窗）
            if let ring = AevonRingMenu.presented {
                cancelGlobalHold()
                // 滑动期间续期：只要手指还在动，就持续把这条 touch 挡在 App 外面。
                if ringSource == "global" {
                    swallowDeadline = CACurrentMediaTime() + swallowLimit
                }
                ring.remoteMoved(to: point, source: "global")
                return
            }
            let dx = point.x - globalStart.x
            let dy = point.y - globalStart.y
            if abs(dx) > 12 || abs(dy) > 12 { cancelGlobalHold() }
            if !globalFired, dx <= -AevonEdgeStripView.swipeDistance, abs(dx) >= abs(dy) * 0.7 {
                globalFired = true
                attemptTrigger("全局左滑 \(Int(dx))pt", source: "global")
            }

        case .ended:
            guard touchID == globalTouchID else { return }
            cancelGlobalHold()
            if let ring = AevonRingMenu.presented {
                ring.remoteEnded(at: point, source: "global")
            }
            globalTouchID = 0
            globalFired = false
            ownsTouch = false

        case .cancelled:
            guard touchID == globalTouchID else { return }
            cancelGlobalHold()
            AevonRingMenu.presented?.remoteCancelled(source: "global")
            globalTouchID = 0
            globalFired = false
            ownsTouch = false

        default:
            break
        }
    }

    private static func scheduleGlobalHold() {
        cancelGlobalHold()
        let timer = Timer(timeInterval: AevonEdgeStripView.holdDuration, repeats: false) { _ in
            guard globalTouchID != 0, !globalFired else { return }
            globalFired = true
            attemptTrigger("全局长按", source: "global")
        }
        RunLoop.main.add(timer, forMode: .common)
        globalHoldTimer = timer
    }

    private static func cancelGlobalHold() {
        globalHoldTimer?.invalidate()
        globalHoldTimer = nil
    }

    /// 呼出圆盘。圆心固定在屏幕 75% 高处，不再跟随触发点。
    static func presentRing(source: String) {
        guard let root = AevonEntryHost.activeRoot else {
            AevonLog.warn("[圆盘] 入口窗口不可用，无法呼出")
            return
        }
        AevonEntryHost.raise(reason: "呼出圆盘")
        AevonRingMenu.present(in: root)
        // 唤出圆盘的那根手指还没离开屏幕 —— 把它的位置交给圆盘，后续移动就是旋转。
        // 圆盘只认这个 source，另一条通道（手势条 / 窗口探针）的重复事件会被忽略。
        AevonRingMenu.presented?.beginRemoteTracking(at: lastTouchPoint, source: source)

        // V0.0.24：全局通道唤起时，这根手指的事件同时也被 App 收着（用户 Aevon(17) 反馈
        // 「滑圆盘时前台 App 跟着动」）。这里登记接管，`AevonTouchHook.m` 会在
        // sendEvent 里把这条 touch 丢掉，不再投递给 App。
        ringSource = source
        swallowDeadline = CACurrentMediaTime() + swallowLimit
        if source == "global" {
            AevonLog.info("[圆盘] 已接管该手指的触摸（App 不会再跟着滚动）（AevonRingSwallowV24）")
        }
    }

    /// 圆盘收起：立刻解除接管，把事件通道还给 App。
    /// 任何一条路径（松手开窗、点空白、点圆心、长按移除后重载）都会走到这里。
    static func ringDidDismiss() {
        ringSource = ""
        swallowDeadline = 0
        globalTouchID = 0
        globalFired = false
        ownsTouch = false
        cancelGlobalHold()
    }

    /// `AevonTouchHook.m` 逐帧询问：这根触摸要不要吞掉（不投递给 App）。
    ///
    /// 两条独立的接管路径，任意一条成立就吞：
    ///   A. **热区接管（V0.0.25）**：App 前台时，手指一落到热区就归我们 —— 连 began 都不给 App，
    ///      所以前台 App 不会跟着滑。桌面不接管（否则热区里的桌面图标点不动）。
    ///   B. **圆盘接管（V0.0.24）**：圆盘已由全局通道唤起，继续接管到圆盘收起。
    ///
    /// 还有两条硬性前提：必须是唤起/接管的那一根手指（别的指头照常给 App），且没超时。
    static func shouldSwallowGlobalTouch(_ touchID: UInt) -> Bool {
        guard AevonPrefs.bool("Enabled", default: false),
              AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return false }
        guard touchID != 0, globalTouchID != 0, touchID == globalTouchID else { return false }
        guard CACurrentMediaTime() <= swallowDeadline else { return false }
        if ownsTouch { return AevonEntryHost.mountedInAppScene }
        guard AevonRingMenu.isPresented, ringSource == "global" else { return false }
        return true
    }

    /// 圆盘展开期间关掉边缘手势条（避免它继续吃掉圆盘上的滑动），收起时恢复。
    static func setStripInteraction(_ enabled: Bool) {
        strip?.isUserInteractionEnabled = enabled
    }

    /// 打开完整应用面板。
    static func openPanel(preferRingEditing: Bool = false) {
        guard let root = AevonEntryHost.activeRoot else {
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

    /// 供其它入口复用同一套面板。
    static func hostRootView() -> UIView? {
        return AevonEntryHost.activeRoot
    }
}

// MARK: - C 入口（供 AevonTouchHook.m 调用）

/// 全局触摸回调。`phase` 是 `UITouchPhase` 的原始值：
/// 0 = began，1 = moved，3 = ended，4 = cancelled（2 = stationary 不会传进来）。
@_cdecl("AevonGlobalTouchPhase")
public func AevonGlobalTouchPhase(_ phase: Int, _ touchID: UInt, _ x: CGFloat, _ y: CGFloat) {
    let mapped: UITouch.Phase
    switch phase {
    case 0: mapped = .began
    case 1: mapped = .moved
    case 3: mapped = .ended
    case 4: mapped = .cancelled
    default: return
    }
    AevonEdgeEntry.handleGlobal(phase: mapped, point: CGPoint(x: x, y: y), touchID: touchID)
}

/// V0.0.24：事件是否丢弃（不投递给 App）的判定入口，供 `AevonTouchHook.m` 调用。
@_cdecl("AevonGlobalTouchShouldSwallow")
public func AevonGlobalTouchShouldSwallow(_ touchID: UInt) -> Bool {
    return AevonEdgeEntry.shouldSwallowGlobalTouch(touchID)
}

/// V0.0.26：设置页写完偏好后的 Darwin 通知回调。
///
/// 设置 App 与 SpringBoard 是两个进程，写完 `com.Aevon` 后 SpringBoard 的
/// CFPreferences 缓存不会自动失效 —— 这里先 synchronize，再回主线程比指纹。
private func aevonPrefsChangedHandler(_ center: CFNotificationCenter?,
                                      _ observer: UnsafeMutableRawPointer?,
                                      _ name: CFNotificationName?,
                                      _ object: UnsafeRawPointer?,
                                      _ userInfo: CFDictionary?) {
    AevonPrefs.synchronize()
    DispatchQueue.main.async {
        // 设置里可能刚改过圆盘 App 列表 / 顺序，先清缓存再比对热区
        AevonRingStore.invalidateCache()
        AevonEdgeEntry.checkTriggerZoneChange()
    }
}
