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
///   · V0.0.21：热区 34 → 44pt（贴最边缘 20pt 会被 SpringBoard 的系统手势门控吞掉，
///     往里挪一点反而更容易命中）；同时补一条手势识别器通道做兜底。
final class AevonEdgeStripView: UIView {
    /// 热区宽度。太宽会抢掉 App 自己靠右边缘的手势，44pt 是「好呼出」与「少误触」的折中。
    static let hitWidth: CGFloat = 44
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

    /// 右侧条带（逻辑坐标），供触摸探针判断「事件落在条带里」
    static func bandRect(in bounds: CGRect) -> CGRect {
        return CGRect(x: bounds.maxX - hitWidth,
                      y: bounds.midY,
                      width: hitWidth,
                      height: bounds.height - bounds.midY)
    }

    /// 兜底判定用的「宽容区」：比真实热区再往内、往上各放宽一截。
    ///
    /// 依据 Aevon(14) 日志：桌面时点悬浮球（x=375）窗口能收到事件，
    /// 但贴右边缘（x≈420）整段零事件 —— 边缘 20pt 会被系统手势门控吃掉。
    /// 用户手指不需要精确压在最边上，往里 60pt 也算数。
    static func looseRect(in bounds: CGRect) -> CGRect {
        return CGRect(x: bounds.maxX - 60,
                      y: bounds.height * 0.30,
                      width: 60,
                      height: bounds.height * 0.70)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 父视图尺寸变化时保持「贴右边缘 + 占下半屏」
        autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin, .flexibleHeight]

        // 一条淡淡的竖线当作"这里有东西"的提示，不喧宾夺主（V0.0.21：调亮到能看清）
        indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.34)
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
        indicator.frame = CGRect(x: bounds.width - 4,
                                 y: (bounds.height - 120) / 2,
                                 width: 4,
                                 height: 120)
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
            self.indicator.backgroundColor = UIColor(white: 1.0, alpha: 0.55)
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
            let band = AevonEdgeStripView.looseRect(in: bounds)
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
            // 宽容区：右边 60pt、纵向下半 70%。贴最边缘 20pt 会被系统手势门控吞掉，
            // 用户手指落在 370~430 之间都算数。
            guard AevonEdgeStripView.looseRect(in: screen).contains(point) else { return }
            globalTouchID = touchID
            globalStart = point
            globalFired = false
            lastTouchPoint = point
            scheduleGlobalHold()
            let now = CACurrentMediaTime()
            if now - globalLastLogAt > 2.0 {
                globalLastLogAt = now
                AevonLog.info("[边缘] 全局通道收到边缘触摸 (x=\(Int(point.x)), y=\(Int(point.y)))（AevonGlobalTouchV23）")
            }

        case .moved:
            guard touchID == globalTouchID else { return }
            lastTouchPoint = point
            // 圆盘已展开：这根手指继续驱动它（旋转 / 选定 / 松手开窗）
            if let ring = AevonRingMenu.presented {
                cancelGlobalHold()
                // 滑动期间续期：只要手指还在动，就持续把这条 touch 挡在 App 外面。
                // 停下来 12 秒不动才自然释放（圆盘收起 / 手指抬起会立刻释放）。
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

        case .cancelled:
            guard touchID == globalTouchID else { return }
            cancelGlobalHold()
            AevonRingMenu.presented?.remoteCancelled(source: "global")
            globalTouchID = 0
            globalFired = false

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
        cancelGlobalHold()
    }

    /// `AevonTouchHook.m` 逐帧询问：这根触摸要不要吞掉（不投递给 App）。
    ///
    /// 只有同时满足才吞：
    ///   1. 圆盘开着；
    ///   2. 圆盘是全局通道唤起的（桌面由我们容器自己收，不需要也不应该吞）；
    ///   3. 就是唤起圆盘的那一根手指（别的指头照常给 App）；
    ///   4. 还在接管时间窗内。
    static func shouldSwallowGlobalTouch(_ touchID: UInt) -> Bool {
        guard AevonRingMenu.isPresented else { return false }
        guard ringSource == "global" else { return false }
        guard touchID != 0, globalTouchID != 0, touchID == globalTouchID else { return false }
        return CACurrentMediaTime() <= swallowDeadline
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
        // 面板全屏覆盖，把备用悬浮球提到最上层，保持「点球收起」的手感
        AevonBubble.shared.bringBallToFront()
    }

    /// 供悬浮球（备用入口）复用同一套面板。
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
