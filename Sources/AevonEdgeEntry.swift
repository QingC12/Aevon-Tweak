import UIKit
import QuartzCore

/// 圆盘触发热区（V0.0.25）。
///
/// 用户可在 设置 → Aevon → 「细节调整」调整三项：
///   · `RingTriggerY`      热区**底边**在屏幕高度的百分比（0~100，默认 75）。
///                         V0.0.30 起改为底边锚定：100% = 区底边贴住屏幕底，
///                         再怎么改高度，条也永远贴底不跑（用户 Aevon(23) 的核心诉求）；
///                         旧版是「中心」语义 —— 高度一大中心被钳制，显示的 % 和
///                         实际位置对不上，滑杆拉满也感觉「回不到底部」。
///   · `RingTriggerWidth`  热区横向宽度（pt，从右边缘往左，默认 48）
///   · `RingTriggerHeight` 热区纵向高度（pt，默认 320）
///
/// **三个入口通道（手势条视图 / 入口窗口探针 / 全局 sendEvent 通道）都只认这个矩形**，
/// 保证「设置里调的那块区域」就是实际能呼出的区域 —— V0.0.24 的问题是全局通道用了
/// 固定的「右 60pt × 下半屏 70%」，结果右侧一大片都能划出圆盘。
enum AevonTriggerZone {
    static let defaultBottomRatio: Double = 75
    static let defaultWidth: Double = 48
    static let defaultHeight: Double = 320

    /// 是否已完成「中心 → 底边」语义迁移（一次性，写回偏好）
    private static var bottomMigrationDone = false

    static var bottomRatio: CGFloat {
        migrateBottomSemanticsIfNeeded()
        let value = AevonPrefs.double("RingTriggerY", default: defaultBottomRatio)
        return CGFloat(min(max(value, 0), 100)) / 100
    }

    /// V0.0.30：旧存的 RingTriggerY 是「中心 %」，换算成「底边 %」并打标记（AevonTriggerBottomV30）。
    private static func migrateBottomSemanticsIfNeeded() {
        guard !bottomMigrationDone else { return }
        bottomMigrationDone = true
        guard !AevonPrefs.bool("RingTriggerYBottomSemantics", default: false) else { return }
        let old = AevonPrefs.double("RingTriggerY", default: -999)
        AevonPrefs.set("RingTriggerYBottomSemantics", true)
        guard old >= 0, old <= 100 else { return }   // 没存过值：直接用新默认 75
        let h = AevonPrefs.double("RingTriggerHeight", default: defaultHeight)
        let screenH = UIScreen.main.bounds.height
        guard screenH > 1 else { return }
        let newBottom = ((old / 100 * screenH) + h / 2) / screenH * 100
        AevonPrefs.set("RingTriggerY", min(max(newBottom, 0), 100))
        AevonPrefs.synchronize()
        AevonLog.info("[边缘] 触发位置切换为底边锚定：\(Int(old))%（中心）→ \(Int(min(max(newBottom, 0), 100)))%（底边）（AevonTriggerBottomV30）")
    }

    static var width: CGFloat {
        let value = AevonPrefs.double("RingTriggerWidth", default: defaultWidth)
        return CGFloat(min(max(value, 18), 140))
    }

    static var height: CGFloat {
        let value = AevonPrefs.double("RingTriggerHeight", default: defaultHeight)
        return CGFloat(min(max(value, 80), 900))
    }

    /// 屏幕坐标下的热区（贴右边缘；纵向以 bottomRatio 为**底边**，向上伸展并夹紧在屏内）
    static func rect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 1, bounds.height > 1 else { return .zero }
        let w = min(width, bounds.width)
        let h = min(height, bounds.height)
        let bottomY = bounds.height * bottomRatio
        let y = min(max(bottomY - h, 0), bounds.height - h)
        return CGRect(x: bounds.maxX - w, y: y, width: w, height: h)
    }

    /// 日志用的一行摘要
    static func summary(in bounds: CGRect) -> String {
        let r = rect(in: bounds)
        return "位置 \(Int(bottomRatio * 100))%（底边）· 宽 \(Int(r.width))pt · 高 \(Int(r.height))pt（区 x \(Int(r.minX))~\(Int(r.maxX)) y \(Int(r.minY))~\(Int(r.maxY))）"
    }

    /// 当前配置的指纹。设置里改了任意一项，指纹就变，SpringBoard 侧据此重排触发条。
    static func signature() -> String {
        return "\(Int((bottomRatio * 100).rounded()))|\(Int(width.rounded()))|\(Int(height.rounded()))"
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

    var onTrigger: (() -> Void)?
    /// 触摸流（窗口坐标 + 相位）：圆盘呼出后，这根手指还没松手，
    /// 后续的移动 / 抬起都由这里转给圆盘，实现「图标跟手旋转 + 停住松手开窗」。
    var onTouch: ((_ point: CGPoint, _ phase: UITouch.Phase) -> Void)?

    private let indicator = UIView()
    private var touchStart: CGPoint = .zero
    private var touchBeganAt: CFTimeInterval = 0
    private var fired = false
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
        // 识别器不取消触摸，所以不会影响上面那套 touchesBegan/Moved 逻辑。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        restoreIndicator()
        let point = touches.first?.location(in: self) ?? touchStart
        onTouch?(convert(point, to: nil), .ended)
        guard !fired else { return }
        let dx = point.x - touchStart.x
        let dy = point.y - touchStart.y
        let duration = Int((CACurrentMediaTime() - touchBeganAt) * 1000)
        AevonLog.info("[边缘] 手势区触摸结束未触发（dx=\(Int(dx)), dy=\(Int(dy)), 持续 \(duration)ms，阈值：左滑 \(-Int(AevonEdgeStripView.swipeDistance))pt）（AevonSwipeOnlyV38）")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        restoreIndicator()
        if let point = touches.first?.location(in: self) {
            onTouch?(convert(point, to: nil), .cancelled)
        }
    }

    // MARK: - 触发

    private func fire(reason: String) {
        guard !fired else { return }
        fired = true
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
        AevonLog.info("[边缘] 手势条已挂到入口窗口（\(Int(view.frame.width))x\(Int(view.frame.height))，原点 \(Int(view.frame.minX)),\(Int(view.frame.minY))，根视图 \(Int(rootBounds.width))x\(Int(rootBounds.height))，热区 \(AevonTriggerZone.summary(in: rootBounds))，触发=左滑≥\(Int(AevonEdgeStripView.swipeDistance))pt）（AevonEdgeTouch AevonTriggerZoneV25 AevonRingListLiveV27 AevonAppGuardSideV27 AevonSwipeOnlyV38）")

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
            // V0.1.2（AevonGuardCleanupV102）：Guard 回执通道已随 Guard 移除
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           nil,
                                           aevonPrefsChangedHandler,
                                           "com.aevon.prefschanged" as CFString,
                                           nil,
                                           .deliverImmediately)
            AevonLog.info("[边缘] 已监听设置变更通知（prefschanged）（AevonPrefsLiveV26 AevonGuardCleanupV102）")
        }
        guard zoneTimer == nil else { return }
        syncGuardConfig()
        // V0.0.34：SpringBoard 启动时清一次圆盘状态位 —— 防止 SB 崩溃时圆盘开着、
        // bit39 残留 1，导致前台 App 在下次启动后被 Guard 永久拦截（fail-open 方向）。
        AevonNotifySetRing(0)
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            AevonPrefs.synchronize()
            // V0.0.31（AevonRingPinnedV31）：轮询只管触发区指纹 ——
            // 旧版这里还顺手 AevonRingStore.invalidateCache()，0.2 秒一次跨进程重读
            // 导致圆盘 App 数与排序漂移（Aevon(24)），已删除。列表只在设置页广播时刷新。
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
        syncGuardConfig()
    }

    /// V0.1.2（AevonGuardCleanupV102）：guard.conf 文件写入器已删除 ——
    /// Guard 移除后那个兜底配置文件（移动分区根目录等 3 路径）无人读取，
    /// 却每版都被误认为「Guard 复活」。notify(3) 写入保留（未来手势仲裁可能复用）。
    /// 历史串 AEVONGUARDCONFV31 / AevonGuardNotifyV32 由 AevonAssertionShim.m 收容。
    static func syncGuardConfig() {
        let bounds = UIScreen.main.bounds
        let r = AevonTriggerZone.rect(in: bounds)
        let enabled = AevonPrefs.bool("Enabled", default: false)
            && AevonPrefs.bool("EdgeGestureEnabled", default: true)
        AevonNotifySetZone(Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), enabled ? 1 : 0)
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

    /// V0.1.4（AevonSystemGestureV104）：系统手势通道识别成功后的入口。
    ///
    /// 走这条路的触摸从落下那一刻就归 SpringBoard 的系统手势窗口 —— 前台 App 手里
    /// 没有这条 touch（这正是「抖音进度条不再跟着拖」的根本原因），所以这里不需要
    /// 任何「吞事件 / 事后补偿」，只要把起点交给圆盘、后续跟着喂位置就行。
    static func triggerFromSystemGesture(point: CGPoint) {
        lastTouchPoint = point
        attemptTrigger("系统手势右缘左扫", source: "systemgesture")
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
    ///  2. **兜底触发**：直接在窗口层做左滑判定，不经过 hitTest ——
    ///     哪怕手势条因为任何原因命中不到，手势照样能用。
    ///     V0.0.38（AevonSwipeOnlyV38）：长按触发整体移除，只保留左滑。
    ///  3. **接力**（V0.0.21 关键修复）：圆盘展开后，唤出它的那根手指还没离开屏幕，
    ///     后续的 moved / ended 从这里转给圆盘，实现「滑出即可旋转、松手即开窗」。
    ///     V0.0.20 缺了这一步，用户看到的就是「圆盘出来后不动，得抬手再摸一次才行」。
    static func attachProbe(to window: AevonEntryWindow) {
        window.eventProbe = { point, phase in
            guard AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return }

            // V0.0.36（AevonFloatInEntryV36）：落点在浮窗上就整个交给浮窗 ——
            // 浮窗搬进入口窗口后与探针同窗，浮窗压住热区时若不做这道短路，
            // 拖浮窗 / 缩放浮窗会被当成边缘手势误呼圆盘。
            if AevonEntryHost.pointHitsFloatingWindow(at: point) { return }

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
                if dx <= -AevonEdgeStripView.swipeDistance, abs(dx) >= abs(dy) * 0.7 {
                    attemptTrigger("窗口层左滑 \(Int(dx))pt", source: "window")
                }
            default:
                probeStart = nil
            }
        }
    }

    // MARK: - 全局触摸通道（V0.0.23）

    /// 全局通道状态（与手势条 / 窗口探针完全独立，互不干扰）
    private static var globalInstalled = false
    private static var globalTouchID: UInt = 0
    private static var globalStart: CGPoint = .zero
    private static var globalFired = false
    private static var globalLastLogAt: CFTimeInterval = 0
    // V0.1.2（AevonTapSummonV102 / AevonForensicBandV102）
    private static var globalBeganAt: CFTimeInterval = 0
    private static var forensicCount = 0
    // V0.1.3（AevonTakeoverBandV103 / AevonBandDeferV103）：右缘接管带「延迟接管」候选。
    // 只登记，不吞：等看清是向左横扫才把这根手指收归圆盘（轻点 / 上下滑 / 向右扫仍归 App）。
    private static var bandTouchID: UInt = 0
    private static var bandStart: CGPoint = .zero

    // MARK: - 浮窗手势（V0.0.41，AevonFloatGlobalV41）

    /// 当前被全局通道接管的那根手指（0 = 没接管浮窗）
    private static var floatTouchID: UInt = 0
    /// 弱引用：窗口被关掉 / 场景回收时这里自动失效，不会拖住已销毁的浮窗
    private static weak var floatWindow: AevonWindowView?
    private static var floatGrab: AevonFloatGrab?
    private static var floatDeadline: CFTimeInterval = 0
    /// 拖拽硬上限：拖到 30 秒一定解除，杜绝「窗口一直吸着手指」的最坏情况
    private static let floatDragLimit: CFTimeInterval = 30

    /// 双击识别（全局通道没有 UITapGestureRecognizer，得自己记）
    private static var floatLastTapAt: CFTimeInterval = 0
    private static var floatLastTapPoint: CGPoint = .zero
    private static weak var floatLastTapWindow: AevonWindowView?
    private static let floatDoubleTapGap: CFTimeInterval = 0.34
    private static let floatDoubleTapRadius: CGFloat = 26

    /// 浮窗手势是否正压着某根手指（供吞事件判断）
    private static var floatGestureActive: Bool {
        return floatTouchID != 0 && floatWindow != nil
    }

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
    /// 热区按下后的最长接管时间（秒）。V0.0.38 起长按触发已移除，
    /// 这 4 秒只兜「按住不动又不抬手」的极端情况；期间用户一开始滑动就继续续期。
    private static let pressLimit: CFTimeInterval = 4

    /// V0.0.29：圆盘展开期间的「额外手指」（原指针还在旋转 / 拖动时落下的新手指）。
    /// 只吞不驱动：App 收不到，也不参与圆盘的手势状态机。
    private static var ringExtraTouchID: UInt = 0
    private static var ringExtraDeadline: CFTimeInterval = 0

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
        // V0.0.41：不再依赖 EdgeGestureEnabled。这条通道现在同时承载浮窗拖拽，
        // 用户关掉边缘呼出圆盘也不该让浮窗拖不动 —— 热区逻辑自己在 began 里判断开关。
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
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        let screen = UIScreen.main.bounds
        switch phase {
        case .began:
            // V0.0.29：圆盘展开期间，**下半屏的触摸一律归圆盘**（用户 Aevon(22) 反馈：
            // 「手指滑动到圆盘外面时依旧会触发主屏 app 的操作」）。原先这里直接 return，
            // 新触摸既不跟踪也不吞 → 前台 App / 桌面照常响应。
            // 现在分两种情况：
            //   · 原指针还压着（正在旋转 / 拖动）→ 新手指只登记为「额外吞掉」，
            //     不驱动圆盘（圆盘同一时刻只认一根手指）；
            //   · 原指针已抬起（KeepOpen 等待选择）→ 新触摸接管为当前指针，
            //     可以继续点图标 / 点圆心 / 盘外松手收起。
            if let ring = AevonRingMenu.presented {
                // V0.1.2（AevonRingFullSwallowV102）：圆盘展开期间 **整屏** 触摸一律归圆盘。
                // 旧版只吞下半屏（V0.0.29），上半屏照常给 App —— Stheno 时代的 Guard 吞区
                // 就是「上 18% 以外整屏」（V0.0.33 RingWide / V0.0.35 实证），抖音全屏时
                // 上半屏滑动正是「圆盘开着还触发 App」的最后漏点。圆盘开着时 App 本来就
                // 不该可交互，全吞没有副作用。
                if ring.isPointerActive {
                    ringExtraTouchID = touchID
                    ringExtraDeadline = CACurrentMediaTime() + swallowLimit
                    return
                }
                globalTouchID = touchID
                globalStart = point
                globalFired = true          // 圆盘开着时绝不再走触发逻辑
                lastTouchPoint = point
                ownsTouch = true
                ringSource = "global"
                swallowDeadline = CACurrentMediaTime() + swallowLimit
                ring.beginRemoteTracking(at: point, source: "global")
                return
            }
            // V0.1.1（AevonZonePriorityV101）：热区改为**最高优先级**。
            // Stheno 逆向实锤（第 51 轮报告）：EdgeBarControlView / EBCI「触发边::开启可调节」
            // —— 触发边是专属手势区，独占边缘，不与浮窗、App 分抢同一块触摸。
            // 旧顺序（先浮窗手柄、先窗体命中、后热区）有两个漏点，都会把整条滑动漏给
            // 全屏 App（V0.1.0 实测「划圆盘触发 App 内左滑」）：
            //   ① 浮窗或其 ±20pt 手柄外扩压住热区 → pointHitsFloatingWindow 先返回
            //      → 既不接管也不吞 → App 收到整条滑动；
            //   ② 浮窗外侧手柄压住热区 → handleFloatGestureBegan 先命中 → 变成拖窗。
            // 现在只要 began 落在热区里，这根手指立刻归圆盘触发（V0.0.25 同款接管：
            // App 连 began 都收不到，sendEvent 丢弃，纯 SB 侧，无需 Guard）。
            // 代价：浮窗压住热区的那一小块不能再当拖窗起点（与 Stheno 触发边独占一致）。
            // V0.1.1（AevonZonePriorityV101）：热区最高优先级。
            // V0.1.2（AevonTakeoverBandV102）：接管带 = 热区向外扩 18pt（18pt 窄带 → 36pt）。
            // 归档(12) 实锤：抖音全屏 2 分钟会话里全局通道零日志 —— 手指起点稍偏出
            // 18pt 窄带就完全不接管，抖音照收整条左滑。外扩只在 **App 前台** 生效
            // （桌面仍按原热区，避免右侧桌面图标点不动）。
            let zone = AevonTriggerZone.rect(in: screen)
            let appForeground = AevonEntryHost.mountedInAppScene
            // V0.1.3（AevonTakeoverBandV103）：App 前台时接管带 = **右缘整条 × 全屏高**。
            //
            // 归档(13) 实锤：0.1.2 的接管带只是把底部热区四周外扩 18pt（纵向仍在 653~932），
            // 取证日志抓到的漏摸却全在**屏幕顶部右缘** ——（399,8）（396,13）（396,85），
            // x 距右缘只有 31~34pt，y 却远在热区之外，于是既不接管也不拦，整条滑动进了抖音
            // （抖音顶部标签栏就是横向翻页的）。只加宽不铺高，永远漏竖向。
            // 所以这里把纵向铺满整屏，横向至少 36pt（取热区宽度与 36 的较大者）。
            let bandWidth = max(zone.width, 36)
            let band = CGRect(x: screen.width - bandWidth, y: 0,
                              width: bandWidth, height: screen.height)
            let edgeEnabled = AevonPrefs.bool("EdgeGestureEnabled", default: true)
            let inZone = zone.contains(point)
            // 桌面只认原热区（接管优先，V0.0.33 同款）；App 前台才启用整条右缘接管带。
            if edgeEnabled, inZone || (appForeground && band.contains(point)) {
                if inZone {
                    // 原热区：老规矩，按下即完全接管（App 连 began 都收不到）。
                    globalTouchID = touchID
                    globalStart = point
                    globalBeganAt = CACurrentMediaTime()
                    globalFired = false
                    lastTouchPoint = point
                    ownsTouch = true
                    swallowDeadline = CACurrentMediaTime() + pressLimit
                    let now = CACurrentMediaTime()
                    if now - globalLastLogAt > 2.0 {
                        globalLastLogAt = now
                        AevonLog.info("[边缘] 全局通道收到热区触摸 (x=\(Int(point.x)), y=\(Int(point.y))，\(AevonTriggerZone.summary(in: screen))，接管=是（热区最高优先级）（AevonGlobalTouchV23 AevonZonePriorityV101 AevonTakeoverBandV103）")
                    }
                    return
                }
                // 带内、热区外：浮窗（含手柄 ±20pt 外扩）优先，否则整条右缘被接管后
                // 浮窗贴右边缘时手柄就拖不动了。浮窗不相关时才进入延迟接管候选。
                if !AevonEntryHost.pointHitsFloatingWindow(at: point) {
                    // **只登记，不吞**（AevonBandDeferV103）。
                    //
                    // 为什么不在这里就吞：抖音的点赞 / 评论 / 收藏 / 分享按钮正好长在这条带上，
                    // 一上来就吞等于把它们全部废掉。所以放行 began，等看清运动方向：
                    //   · 向左横扫（dx ≤ -6 且横向占优）→ 立刻收归圆盘，后续事件全吞；
                    //   · 轻点 / 上下滚 / 向右扫 → 彻底放手，App 按自己的逻辑处理。
                    // 代价：App 会先收到 began 和最多一两帧位移（≤6pt）—— 不足以让它的翻页 /
                    // 侧滑越过触发阈值，而我们从方向确认那一帧起就断供，手势不会成立。
                    bandTouchID = touchID
                    bandStart = point
                    if forensicCount < 40 {
                        forensicCount += 1
                        AevonLog.info("[穿透取证] began (\(Int(point.x)),\(Int(point.y))) 接管带=延迟接管（左扫才收，App前台=\(appForeground)，热区外，计数 \(forensicCount)）（AevonBandDeferV103 AevonForensicBandV102）")
                    }
                    return
                }
            }
            // V0.1.3：接管带外但仍在右缘 44pt 内的 began 记一条（bandWidth 之外的极端起点）。
            if forensicCount < 40, appForeground, point.x >= screen.width - 44 {
                forensicCount += 1
                AevonLog.info("[穿透取证] began (\(Int(point.x)),\(Int(point.y))) 接管=否（接管带外，App前台=\(appForeground)，计数 \(forensicCount)）（AevonBandDeferV103 AevonForensicBandV102）")
            }
            // 热区外：维持 V41 行为 —— 浮窗手柄手势 / 窗体命中探测。
            if handleFloatGestureBegan(point: point, touchID: touchID) { return }
            if AevonEntryHost.pointHitsFloatingWindow(at: point) { return }

        case .moved:
            // V0.0.41：正在被全局通道拖动的浮窗 —— 只驱动浮窗，绝不进 App
            if handleFloatGestureMoved(point: point, touchID: touchID) { return }
            // V0.0.29：圆盘开着时被「只吞不驱动」的额外手指 —— 续期吞咽即可
            if touchID == ringExtraTouchID {
                if CACurrentMediaTime() <= ringExtraDeadline {
                    ringExtraDeadline = CACurrentMediaTime() + swallowLimit
                }
                return
            }
            // V0.1.3（AevonBandDeferV103）：接管带候选的方向判定 —— 只有「向左横扫」才收归圆盘。
            // 判定用绝对值占优（|dx| ≥ |dy|×1.2）保证斜着划也能中；纵向滚动 / 向右扫立刻放手，
            // 让抖音右侧按钮的轻点、信息流的上下翻页完全不受影响。
            if touchID == bandTouchID {
                // V0.1.4（AevonSystemGestureV104）：这根手指已经归系统手势窗口 ——
                // App 那边没有它，我们也不必再「接管 / 吞事件」，直接让路。
                if AevonSystemGestureV104.isHandling(touchID: touchID) {
                    bandTouchID = 0
                    bandStart = .zero
                    return
                }
                let dx = point.x - bandStart.x
                let dy = point.y - bandStart.y
                if dx <= -6, abs(dx) >= abs(dy) * 1.2 {
                    bandTouchID = 0
                    globalTouchID = touchID
                    globalStart = bandStart
                    globalBeganAt = CACurrentMediaTime()
                    globalFired = false
                    lastTouchPoint = point
                    ownsTouch = true
                    swallowDeadline = CACurrentMediaTime() + swallowLimit
                    AevonLog.info("[边缘] 接管带确认左扫 → 收归圆盘（dx=\(Int(dx)) dy=\(Int(dy))，起点 \(Int(bandStart.x)),\(Int(bandStart.y))）（AevonBandDeferV103）")
                } else if abs(dy) > 60 || dx > 30 {
                    // 明确的 App 手势（纵向滚动 / 向右扫）：彻底放手，绝不再干预
                    bandTouchID = 0
                    return
                }
            }
            guard touchID == globalTouchID else { return }
            lastTouchPoint = point
            if ownsTouch { swallowDeadline = CACurrentMediaTime() + pressLimit }
            // 圆盘已展开：这根手指继续驱动它（旋转 / 选定 / 松手开窗）
            if let ring = AevonRingMenu.presented {
                // 滑动期间续期：只要手指还在动，就持续把这条 touch 挡在 App 外面。
                if ringSource == "global" {
                    swallowDeadline = CACurrentMediaTime() + swallowLimit
                }
                ring.remoteMoved(to: point, source: "global")
                return
            }
            let dx = point.x - globalStart.x
            let dy = point.y - globalStart.y
            if !globalFired, dx <= -AevonEdgeStripView.swipeDistance, abs(dx) >= abs(dy) * 0.7 {
                globalFired = true
                attemptTrigger("全局左滑 \(Int(dx))pt", source: "global")
            }

        case .ended:
            // V0.0.41：浮窗拖拽抬手 —— 提交几何 / 命中 ✕ 才关窗 / 记录双击候选
            if handleFloatGestureEnded(point: point, touchID: touchID, cancelled: false) { return }
            // V0.0.29：额外手指抬起（hook 已按「先询问再上报」把抬手帧吞掉）—— 只清状态
            if touchID == ringExtraTouchID {
                ringExtraTouchID = 0
                ringExtraDeadline = 0
                return
            }
            // V0.1.3：接管带候选抬手（始终没成左扫）—— 只清状态，事件本就归 App
            if touchID == bandTouchID {
                bandTouchID = 0
                bandStart = .zero
                return
            }
            guard touchID == globalTouchID else { return }
            if let ring = AevonRingMenu.presented {
                ring.remoteEnded(at: point, source: "global")
            }
            // V0.1.2（AevonTapSummonV102）：轻点热区 = 呼出圆盘。
            // 快按快抬（≤0.45s）且位移 ≤10pt 时触发 —— 无位移手势不可能带动
            // 抖音翻页 / 侧滑返回；且这根手指从 began 就被接管，App 连轻点都收不到，
            // 连带修掉「轻点右缘触发抖音暂停」的可能。
            if !globalFired, globalBeganAt > 0 {
                let elapsed = CACurrentMediaTime() - globalBeganAt
                let moved = hypot(point.x - globalStart.x, point.y - globalStart.y)
                if elapsed <= 0.45, moved <= 10.0 {
                    attemptTrigger("轻点呼出（按 \(Int(elapsed * 1000))ms 位移 \(Int(moved))pt）（AevonTapSummonV102）", source: "global")
                }
            }
            globalBeganAt = 0
            globalTouchID = 0
            globalFired = false
            ownsTouch = false

        case .cancelled:
            // V0.0.41：浮窗拖拽被系统打断 —— 缩放退回原几何，移动不落盘
            if handleFloatGestureEnded(point: point, touchID: touchID, cancelled: true) { return }
            if touchID == ringExtraTouchID {
                ringExtraTouchID = 0
                ringExtraDeadline = 0
                return
            }
            // V0.1.3：接管带候选被系统取消 —— 只清状态
            if touchID == bandTouchID {
                bandTouchID = 0
                bandStart = .zero
                return
            }
            guard touchID == globalTouchID else { return }
            AevonRingMenu.presented?.remoteCancelled(source: "global")
            globalTouchID = 0
            globalFired = false
            globalBeganAt = 0
            ownsTouch = false

        default:
            break
        }
    }

    // MARK: - 浮窗手势状态机（V0.0.41，AevonFloatGlobalV41）

    /// 按下：命中浮窗外侧手柄 / ✕ 就整段接管这根手指。
    ///
    /// 返回 true = 这根触摸已归浮窗，调用方必须立刻 return（既不再判热区，也不给 App）。
    private static func handleFloatGestureBegan(point: CGPoint, touchID: UInt) -> Bool {
        // 上一根手指的 ended 万一丢了，别让整段浮窗手势永久失效 —— 超时就地清理
        if floatTouchID != 0 {
            if CACurrentMediaTime() > floatDeadline { clearFloatGesture() } else { return false }
        }
        // 圆盘开着时一切归圆盘，浮窗让位（避免两套状态机抢同一根手指）
        guard AevonRingMenu.presented == nil else { return false }
        guard let hit = AevonEntryHost.grabFloatingWindow(atScreenPoint: point) else {
            return false
        }

        let now = CACurrentMediaTime()
        // V0.1.1（AevonRestoreDefaultV101）：顶部边条双击 = 恢复默认大小与位置。
        // 原「双击换档（小窗/大窗）」移除 —— 大窗档近乎铺满整屏且角手柄不可达；
        // 其余手柄双击不再有任何特殊动作，按普通拖动处理（无位移 = 轻点无动作）。
        if case .bar(.top) = hit.grab,
           now - floatLastTapAt <= floatDoubleTapGap,
           floatLastTapWindow === hit.window,
           hypot(point.x - floatLastTapPoint.x,
                 point.y - floatLastTapPoint.y) <= floatDoubleTapRadius {
            floatLastTapAt = 0
            floatLastTapWindow = nil
            floatTouchID = touchID
            floatWindow = hit.window
            floatGrab = nil              // 恢复默认不拖拽，抬手直接收尾
            floatDeadline = now + floatDragLimit
            hit.window.restoreDefaultFrame()
            AevonLog.info("[窗口] 顶部双击 → 恢复默认大小与位置（全局通道）（AevonRestoreDefaultV101）")
            return true
        }

        floatTouchID = touchID
        floatWindow = hit.window
        floatGrab = hit.grab
        floatDeadline = now + floatDragLimit
        hit.window.grabBegin(hit.grab, at: hit.layerPoint)
        switch hit.grab {
        case .bar:
            AevonLog.info("[窗口] 全局通道开始拖动（移动）\(Int(point.x)),\(Int(point.y))（AevonFloatGlobalV41）")
        case .corner:
            AevonLog.info("[窗口] 全局通道开始拖动（缩放）\(Int(point.x)),\(Int(point.y))（AevonFloatGlobalV41）")
        case .close:
            AevonLog.info("[窗口] 全局通道命中关闭钮（AevonFloatGlobalV41）")
        }
        return true
    }

    /// 拖动中。返回 true = 已消费，调用方 return。
    private static func handleFloatGestureMoved(point: CGPoint, touchID: UInt) -> Bool {
        guard floatTouchID != 0, touchID == floatTouchID else { return false }
        guard let win = floatWindow else {
            clearFloatGesture()
            return false
        }
        let now = CACurrentMediaTime()
        guard now <= floatDeadline else {
            win.grabCancel()
            clearFloatGesture()
            return false
        }
        floatDeadline = now + floatDragLimit      // 手指还在动就续期
        win.grabUpdate(to: AevonEntryHost.floatLayerPoint(fromScreen: point))
        return true
    }

    /// 抬手 / 取消。返回 true = 已消费，调用方 return。
    private static func handleFloatGestureEnded(point: CGPoint, touchID: UInt,
                                               cancelled: Bool) -> Bool {
        guard floatTouchID != 0, touchID == floatTouchID else { return false }
        let win = floatWindow
        let layerPoint = AevonEntryHost.floatLayerPoint(fromScreen: point)
        if cancelled {
            win?.grabCancel()
        } else {
            win?.grabEnd(at: layerPoint, commit: true)
            // 记一次双击候选：只有「手柄上的轻点」才算，✕ 不算
            if let grab = floatGrab, win != nil {
                switch grab {
                case .close:
                    break
                case .bar, .corner:
                    floatLastTapAt = CACurrentMediaTime()
                    floatLastTapPoint = point
                    floatLastTapWindow = win
                }
            }
        }
        clearFloatGesture()
        return true
    }

    private static func clearFloatGesture() {
        floatTouchID = 0
        floatWindow = nil
        floatGrab = nil
        floatDeadline = 0
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
        // V0.0.29：告诉 AevonGuard（App 进程）圆盘已展开 —— 它会在自己的进程里
        // 把下半屏的触摸整条吞掉，前台 App 在圆盘开着期间彻底收不到下半屏输入。
        syncGuardConfig()
        // V0.0.34（AevonNotifyRingBitV34）：圆盘状态写进 notify(3) 共享内存。
        // Darwin 广播（ringopen）是 fire-and-forget，沙盒 App 可能收不到 ——
        // Aevon(27) 连续 3 版「圆盘滑动带动全屏 App」的共同根因。共享内存位零时序依赖。
        AevonNotifySetRing(1)
        postRingState("com.aevon.ringopen")
        if source == "global" {
            AevonLog.info("[圆盘] 已接管该手指的触摸（App 不会再跟着滚动）（AevonRingSwallowV24 AevonRingHalfGuardV29 AevonRingFullSwallowV102）")
        }
    }

    /// V0.0.29：跨进程广播圆盘开 / 关（Darwin 通知无载荷，Guard 收到后自行计时兜底）。
    private static func postRingState(_ rawName: String) {
        let name = CFNotificationName(rawName as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             name, nil, nil, true)
    }

    /// 圆盘收起：立刻解除接管，把事件通道还给 App。
    /// 任何一条路径（松手开窗、点空白、点圆心、设置重载后移除）都会走到这里。
    static func ringDidDismiss() {
        ringSource = ""
        swallowDeadline = 0
        globalTouchID = 0
        globalFired = false
        ownsTouch = false
        ringExtraTouchID = 0
        ringExtraDeadline = 0
        // V0.1.3：顺手清掉接管带候选，避免圆盘收起后残留一根「疑似归我」的手指
        bandTouchID = 0
        bandStart = .zero
        // V0.0.34：清共享内存圆盘状态位（Guard 侧立即恢复放行）
        AevonNotifySetRing(0)
        postRingState("com.aevon.ringclose")
    }

    /// `AevonTouchHook.m` 逐帧询问：这根触摸要不要吞掉（不投递给 App）。
    ///
    /// 两条独立的接管路径，任意一条成立就吞：
    ///   A. **热区接管（V0.0.25）**：App 前台时，手指一落到热区就归我们 —— 连 began 都不给 App，
    ///      所以前台 App 不会跟着滑。桌面不接管（否则热区里的桌面图标点不动）。
    ///   B. **圆盘接管（V0.0.24）**：圆盘已由全局通道唤起，继续接管到圆盘收起。
    ///
    /// 还有三条硬性前提：必须是唤起/接管的那一根手指（别的指头照常给 App），且没超时。
    static func shouldSwallowGlobalTouch(_ touchID: UInt) -> Bool {
        guard AevonPrefs.bool("Enabled", default: false) else { return false }
        guard touchID != 0 else { return false }
        // V0.0.41（AevonFloatGlobalV41）：浮窗拖拽期间这根手指完全归浮窗。
        // 手柄在浮窗**外侧**，落点就是 App 内容 —— 不吞的话拖窗会连带拖动 App 页面 / 列表。
        if floatGestureActive, touchID == floatTouchID,
           CACurrentMediaTime() <= floatDeadline {
            return true
        }
        // V0.0.29：圆盘展开期间被吞掉的「额外手指」（下半屏、不驱动圆盘）
        if touchID == ringExtraTouchID {
            return CACurrentMediaTime() <= ringExtraDeadline
        }
        // V0.0.29：圆盘展开期间重新登记的指针（KeepOpen 后点选 / 盘外松手收起的那根）。
        // 桌面也要吞 —— 下半屏在圆盘开着时不该点动桌面图标。
        if AevonRingMenu.isPresented, ringSource == "global",
           touchID == globalTouchID, CACurrentMediaTime() <= swallowDeadline {
            return true
        }
        guard globalTouchID != 0, touchID == globalTouchID else { return false }
        guard CACurrentMediaTime() <= swallowDeadline else { return false }
        // V0.0.33（AevonTouchOwnV33）：ownsTouch 成立后**锁定不再回查** mountedInAppScene。
        // Aevon(26) 根因之一：每帧重查 → 容器搬家瞬间（日志反复「App 场景消失 / 画面进入」）
        // 判定翻转，吞到一半突然撒手，后半段滑动全进 App，全屏手势被触发。
        // began 时一旦接管就吞到 ended / cancelled，与挂载点无关。
        if ownsTouch { return true }
        guard AevonRingMenu.isPresented, ringSource == "global" else { return false }
        return true
    }

    /// 圆盘展开期间关掉边缘手势条（避免它继续吃掉圆盘上的滑动），收起时恢复。
    static func setStripInteraction(_ enabled: Bool) {
        strip?.isUserInteractionEnabled = enabled
    }

    /// 打开完整应用面板（V0.0.30 起只有单窗模式）。
    static func openPanel() {
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
        let panel = AevonAppPickerView(apps: apps) {
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
        // 设置里可能刚改过圆盘 App 列表 / 顺序 —— V0.0.31：带快照防漂移地刷新
        AevonRingStore.refreshFromSettings()
        AevonEdgeEntry.checkTriggerZoneChange()
        AevonEdgeEntry.syncGuardConfig()
    }
}

/// V0.1.2（AevonGuardCleanupV102）：Guard 回执计数与 handler 已随 Guard 移除。
/// 历史 CI 校验串（AevonGuardAckV35）由 AevonAssertionShim.m 的 used 常量收容。
