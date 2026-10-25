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

/// 右缘接管带（V0.1.15，AevonRightEdgeTakeoverV115）。
///
/// Aevon(82) 的 P7 探针把前九版的假设全推翻了，四条实测：
///   · P7-1：右缘 (424,400) 的最高命中**就是我们自己的带视图** —— 它挂在
///     `SBMainSwitcherWindow`（level=5，App 画面所在窗口）里，压着 `SBDeviceApplicationSceneView`；
///     所以「我们的视图在命中链里排不上队」是错的，命中早就赢了。
///   · P7-2：入口窗口三个落点全是 `nil（穿透）` —— 它只负责显示，根本不参与裁决。
///   · P7-3：`SBMainDisplaySystemGestureManager` 的 14 个识别器**全部**挂在
///     `UISystemGestureView(0,0,430,932)` 上，而我们登记的那一个也在这个视图上 —— 同宿。
///     即「像 Stheno 一样进了系统手势环境」这件事我们已经做到了。
///   · P7-5：`BKSHIDEventDeferringPredicate` 只有 environment / display / token 三个维度，
///     **没有任何几何信息** → 无法「只延迟右缘那一带」，整屏延迟等于废手机 → 这条路判死。
///
/// 于是结论只剩一条：命中赢 ≠ App 收不到；系统手势环境只给「观察权」，不给「所有权」；
/// 真正能决定 App 收不收摸的，是 `UIApplication -sendEvent:` 这一层整指丢弃
/// （热区 12 次呼出零漏摸就是靠它，而右缘从 0.1.13 起在这一层是「本版不干预」）。
///
/// 所以这个版本把右缘做成「第二个热区」：began 即接管，与热区共用同一套 `ownsTouch`
/// 生命周期；不再碰识别器、不再扣移动帧、不再赌判向 —— 因为吞了 began 之后，
/// 判向失败也还不回去了（App 没有 began 就拿不住这根 touch）。
///
/// 代价是物理代价，不是 bug：带内 App 的轻点 / 右滑 / 贴边滚动全部归我们。
/// 因此带宽默认 28pt（抖音右侧按钮中心距边一般 ≥30pt），
/// 带高默认只覆盖**下半 60%**，上半屏右侧完全不受影响。
enum AevonRightEdge {
    // V0.1.18（AevonRightEdgeDefaultV118）：默认宽度 28 → **46**，下限 8 → **24**。
    //
    // 依据 Aevon(85) 的四次真实落点（距右缘 12 / 19 / 25 / 42pt）：
    //   · 用户把宽度拖到 17pt 后，四次右缘操作 **0 次进带**，其中 (411,744) 只差 1pt；
    //   · 按真实落点算覆盖率：17pt×60% = 0/4、28pt×60% = 1/4、
    //     46pt×60% = 3/4（只缺 y=80 那次高度外）、46pt×全高 = 4/4。
    // 结论：**把宽度做成可调、且允许调到「落在带外」的区间，等于把「猜自己落点」的成本
    // 转给用户** —— 一调小功能就静默归零，日志里还只有一行看起来像我们主动放弃的记录。
    // 所以默认直接给到上限 46（Stheno 的 `_edgeWidth` 也是固定值，不是滑条），
    // 下限抬到 24，让「设了也没用」的区间根本选不出来。
    //
    // 代价必须写明：46pt 会压到抖音右侧按钮（中心一般距边 30pt 开外），
    // 想保住按钮就把宽度调回 24~32，或者把带高缩到 40%。
    static let defaultWidth: Double = 46
    static let defaultHeightPercent: Double = 60
    static let minWidth: Double = 24
    static let maxWidth: Double = 46
    static let minHeightPercent: Double = 40
    static let maxHeightPercent: Double = 100

    static var enabled: Bool {
        // V0.1.17（Aevon(84) 事故后改默认）：**默认关**。
        // 出过一次「整屏点不动、只能卸载」的事故之后，这条「整指吞」的功能必须由用户显式打开；
        // 关着时右缘整段交回 App，只留一行「归口=起手窗·本版不干预」的记录。
        return AevonPrefs.bool("RightEdgeTakeover", default: false)
    }

    /// V0.1.16（AevonRightEdgeShowBandV116）：把接管带的**真实范围**画出来（默认关）。
    ///
    /// 为什么这一版要加它：28pt 是一条手指几乎看不见的宽度，而 Aevon(83) 里三次实测落点
    /// 全在 y=656~671 —— 那正是接管带最下沿、紧贴热区上边界的几像素。
    /// 「落点到底在不在带里、带的上边界在哪、这次是不是我们接住的」在真机上全靠猜，
    /// 猜错一次就要再跑一轮构建。打开这个开关后：
    ///   · 带内会有淡色填充 + 左边界竖线 + 上边界虚线，宽度/高度就是实际生效值；
    ///   · 每次接管成功整条带闪一下（0.3 秒），看得见「这次归我们」。
    /// 它只是一层绘制：`isUserInteractionEnabled = false` 且不改 hitTest，绝不影响触摸。
    static var showBand: Bool {
        return AevonPrefs.bool("RightEdgeShowBand", default: false)
    }

    static var width: CGFloat {
        let value = AevonPrefs.double("RightEdgeWidth", default: defaultWidth)
        return CGFloat(min(max(value, minWidth), maxWidth))
    }

    /// 带高占屏高的百分比（从底边往上量）。
    static var heightPercent: CGFloat {
        let value = AevonPrefs.double("RightEdgeHeight", default: defaultHeightPercent)
        return CGFloat(min(max(value, minHeightPercent), maxHeightPercent))
    }

    /// 屏幕坐标下的接管带（贴右边缘、贴底边向上伸展）。
    static func band(in bounds: CGRect) -> CGRect {
        guard bounds.width > 1, bounds.height > 1 else { return .zero }
        let w = min(width, bounds.width)
        let h = bounds.height * heightPercent / 100
        return CGRect(x: bounds.maxX - w, y: bounds.maxY - h, width: w, height: h)
    }

    static func summary(in bounds: CGRect) -> String {
        let r = band(in: bounds)
        return "宽 \(Int(r.width))pt · 高占比 \(Int(heightPercent))%（带 x \(Int(r.minX))~\(Int(r.maxX)) y \(Int(r.minY))~\(Int(r.maxY))）"
    }

    /// V0.1.18（AevonRightEdgeMissHintV118）：落点**为什么**没进带、要多大才进。
    ///
    /// Aevon(85) 的四次落点里没有一次进带，但日志原文只有「归口=起手窗·本版不干预」——
    /// 读起来像我们主动放弃，实际是「宽度差 1pt / 高度差 90pt」这种纯几何原因。
    /// 这个函数把原因和所需值算成一句话，让每一行日志自己说清结论，
    /// 不用再去比对屏幕尺寸反推。
    ///
    /// 返回空串 = 落点确实在带内（调用方只在带外时用它）。
    static func missReason(for point: CGPoint, in bounds: CGRect) -> String {
        let r = band(in: bounds)
        let gap = Int((bounds.maxX - point.x).rounded())
        let needWidth = gap                      // contains 要求 point.x >= r.minX，即 gap <= 带宽
        let needPercent = Int(((bounds.maxY - point.y) / bounds.height * 100).rounded()) + 1
        // 开关关着时「带内」也进不来 —— 必须先单独判，否则会把它误报成「高度差」
        // （band 的几何是照样算的，widthShort/heightShort 都为 false，会掉进最后一个分支）。
        guard enabled else {
            return "带外·开关未打开（落点距右缘 \(gap)pt，本可在带内；到设置里打开「右缘接管带」即可）"
        }
        let widthShort = point.x < r.minX
        let heightShort = point.y < r.minY
        if widthShort, heightShort {
            return "带外·宽度和高度都差（距边 \(gap)pt 需 ≥\(needWidth)pt，y=\(Int(point.y)) 需带高 ≥\(needPercent)%；当前 \(Int(width))pt×\(heightPercent)%）"
        }
        if widthShort {
            return "带外·宽度差（距边 \(gap)pt，需带宽 ≥\(needWidth)pt，当前 \(Int(width))pt）"
        }
        return "带外·高度差（y=\(Int(point.y)) 在带顶 y=\(Int(r.minY)) 之上，需带高 ≥\(needPercent)%，当前 \(Int(heightPercent))%）"
    }

    static func signature() -> String {
        return "\(enabled ? 1 : 0)|\(Int(width.rounded()))|\(Int(heightPercent.rounded()))|\(showBand ? 1 : 0)"
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
        disableRiskyTakeoverOnceV117()
        widenRightEdgeOnceV118()
        explainPanicDisabledOnceV119()
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
            // V0.2.1（AevonAppTriggerBridgeV201）：App 进程内识别器判向成立 → 呼圆盘。
            // 路 B 的回传通道：App 侧把右缘触摸合法取消（touchesCancelled）后广播这条通知，
            // SB 在这里收。去重交给 attemptTrigger 的 0.6 秒闸 + isPresented 闸 ——
            // 右下角热区可能同时被 SB 自己的通道和 App 侧命中，谁先到谁呼，后来的被去重。
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           nil,
                                           aevonAppTriggerHandler,
                                           "com.aevon.rightedgetrigger" as CFString,
                                           nil,
                                           .deliverImmediately)
            AevonLog.info("[边缘] 已监听设置变更通知（prefschanged）（AevonPrefsLiveV26 AevonGuardCleanupV102）")
            AevonLog.info("[边缘] 已监听 App 侧右缘判向通知（rightedgetrigger）（AevonAppTriggerBridgeV201）")
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
            // V0.1.17（AevonDeadManV117）：死手开关跟着这条 0.2 秒轮询走 ——
            // 接管状态一旦泄漏，最多 1 秒余量 + 4 秒 pressLimit 就会自动释放，
            // 不会再出现「整块屏幕点不动、只能卸载」的局面。
            enforceDeadManSwitch()
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

    // MARK: - V0.1.17 首次启动的安全复位
    //
    // 为什么必须做：偏好是**跨版本保留**的。Aevon(84) 里用户把「显示右缘接管带」打开了，
    // 升级到 0.1.17 之后那个 1 仍然会被读回来 —— 只改代码里的默认值，救不了已经在事故状态里的设备。
    // 所以这里按「一次性标记」判定：把三个危险开关写回关闭，再立标记。
    // 之后用户在设置里自己打开就永久保留，不会被反复重置（标记只在第一次生效）。
    private static var migratedSafeV117 = false

    private static func disableRiskyTakeoverOnceV117() {
        guard !migratedSafeV117 else { return }
        migratedSafeV117 = true
        guard !AevonPrefs.bool("SafeTakeoverResetV117", default: false) else { return }
        AevonPrefs.set("SafeTakeoverResetV117", true)
        AevonPrefs.set("RightEdgeTakeover", false)
        AevonPrefs.set("RightEdgeShowBand", false)
        AevonPrefs.set("BandTakeoverFromBegan", false)
        AevonPrefs.synchronize()
        AevonLog.warn("[安全] 0.1.17 首次启动：已把「右缘接管带 / 显示右缘接管带 / 右缘全域接管」三个开关写回关闭（0.1.16 卡死整屏的事故）。要用请回设置里手动打开（AevonNoBandDrawV117）")
    }

    // V0.1.18（AevonRightEdgeWidenV118）：把**被旧默认值坑住**的带宽一次性抬到 46。
    //
    // 为什么必须做迁移而不是只改默认值：`RightEdgeWidth` 是 CFPreferences 里的持久键，
    // 改代码里的 default 只影响「从没写过这个键」的设备。Aevon(85) 的设备上它已经被写成 17，
    // 只改默认值的话，用户装完这一版**仍然是 17pt**，等于白改。
    //
    // 判定阈值取 28（旧默认值）：<= 28 的值不可能来自「我想更容易呼出」（那应该往大调），
    // 只可能来自旧默认或跟着旧默认往下拖 —— 都是我们给的坑。用户主动调大过的一律保留。
    // 标记只生效一次，用户此后在设置里怎么调都永久保留。
    private static var migratedWideV118 = false

    private static func widenRightEdgeOnceV118() {
        guard !migratedWideV118 else { return }
        migratedWideV118 = true
        guard !AevonPrefs.bool("AevonRightEdgeWidenV118", default: false) else { return }
        AevonPrefs.set("AevonRightEdgeWidenV118", true)
        let previous = AevonPrefs.rawValue("RightEdgeWidth") as? NSNumber
        guard let raw = previous?.doubleValue, raw <= 28 else {
            AevonPrefs.synchronize()
            return
        }
        AevonPrefs.set("RightEdgeWidth", AevonRightEdge.defaultWidth)
        AevonPrefs.synchronize()
        AevonLog.warn("[右缘] 0.1.18 首次启动：带宽从 \(Int(raw))pt 抬到 \(Int(AevonRightEdge.defaultWidth))pt（旧默认值让它一直落在带外；想改回去请到「细节调整」里调，下限 \(Int(AevonRightEdge.minWidth))pt）（AevonRightEdgeWidenV118）")
    }

    /// V0.1.19（AevonPanicHintV119）：把「上次被三指急救关掉」这件事说清楚。
    ///
    /// 为什么 4 秒提示还不够：Aevon(86) 里用户在 17:51:51 触发急救，当时屏幕上没有反馈，
    /// 他接着做了 40 秒无效尝试，最后只能得出「这一版还是没修好」。
    /// 所以每次 SpringBoard 启动后都再提醒一次（仅当开关是关的、且标记确实来自急救）。
    /// 用户重新打开开关时 `checkTriggerZoneChange()` 会清标记，之后不再提示。
    private static func explainPanicDisabledOnceV119() {
        guard !AevonPrefs.bool("RightEdgeTakeover", default: false),
              AevonPrefs.bool("RightEdgePanicOffV119", default: false) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            guard !AevonPrefs.bool("RightEdgeTakeover", default: false),
                  AevonPrefs.bool("RightEdgePanicOffV119", default: false) else { return }
            AevonPanicHint.show("「右缘接管带」当前是关闭状态。\n上次由三指急救关闭，可在设置里重新打开。", duration: 5.0)
            AevonLog.info("[急救] 启动检查：右缘接管带仍处于「被急救关闭」状态，已提示一次（AevonPanicHintV119）")
        }
    }

    /// 指纹变了就重排触发条（幂等；没变什么都不做）
    static func checkTriggerZoneChange() {
        let signature = AevonTriggerZone.signature()
        if signature != zoneSignature {
            zoneSignature = signature
            refreshLayoutIfNeeded(logChange: true)
            syncGuardConfig()
        }
        // V0.1.16（AevonBandIndicatorV116）：右缘带的宽度 / 高度 / 可视化开关变了要立刻重画 ——
        // 否则用户得注销才能看到新范围，而这一版的重点恰恰是「让他能看见那条带」。
        // 首次进来只记指纹，不刷日志（避免启动时多一行噪音）。
        let bandSignatureNow = AevonRightEdge.signature()
        if bandSignatureNow != rightEdgeSignature {
            let isFirst = rightEdgeSignature.isEmpty
            rightEdgeSignature = bandSignatureNow
            AevonSystemGestureV105.refreshBandIndicator()
            if !isFirst {
                AevonLog.info("[右缘] 配置已更新：\(AevonRightEdge.summary(in: UIScreen.main.bounds))，可视化=\(AevonRightEdge.showBand ? "开" : "关")（AevonBandIndicatorV116）")
            }
        }
        // V0.1.19（AevonPanicHintV119）：用户重新打开「右缘接管带」→ 清掉「被急救关掉」的标记，
        // 之后不再在启动时提示。
        if AevonPrefs.bool("RightEdgeTakeover", default: false),
           AevonPrefs.bool("RightEdgePanicOffV119", default: false) {
            AevonPrefs.set("RightEdgePanicOffV119", false)
            AevonPrefs.synchronize()
            AevonLog.info("[急救] 「右缘接管带」已被重新打开 → 清除急救关闭标记（AevonPanicHintV119）")
        }
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
    /// V0.1.16：右缘带（宽度 / 高度 / 可视化开关）的指纹，用于 0.2 秒轮询里发现改动后重画
    private static var rightEdgeSignature = ""
    private static var prefsObserverInstalled = false

    /// 统一触发入口（手势条 / 窗口层兜底 / 识别器都走这里），带 0.6 秒去重。
    /// `source` 决定后续触摸流转发给圆盘时走哪条通道（圆盘只认最先来的那条）。
    static func attemptTrigger(_ reason: String, source: String) {
        let now = CACurrentMediaTime()
        guard now - lastTriggerAt > 0.6 else { return }
        guard !AevonRingMenu.isPresented else { return }
        lastTriggerAt = now
        AevonLog.info("[边缘] 触发（\(reason)，来源 \(source)），呼出圆盘")
        // V0.1.17：圆盘要起来了，把右缘提示条收掉（别叠在圆盘上），并记下展开时刻给死手开关用。
        AevonBandHint.hideNow()
        ringOpenedAt = now
        presentRing(source: source)
    }

    /// V0.1.4/V0.1.5（AevonSystemGestureV104 / AevonSystemGestureV105）：系统手势管线识别成功后的入口。
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
    private static var forensicCount = 0
    // V0.1.3（AevonTakeoverBandV103 / AevonBandDeferV103）：右缘接管带「延迟接管」候选。
    // 只登记，不吞：等看清是向左横扫才把这根手指收归圆盘（轻点 / 上下滑 / 向右扫仍归 App）。
    private static var bandTouchID: UInt = 0
    private static var bandStart: CGPoint = .zero
    // V0.1.12（AevonBandHoldMovedV112）：起手窗「只扣移动帧」的持有状态。
    //
    // Aevon(79) 的 15 次呼出全部落在右下角热区、全部成功，所以「偶尔触发」的那几次
    // 根本没被这份日志覆盖到 —— 它只能发生在热区之外。热区之外以前是「began 照给 App，
    // 等看清方向才吞」，判定期内 App 已经吃到 6pt 横向位移；抖音自己的横滑手势阈值就在
    // 这个量级，快速或斜向起手时它会先立起来，于是圆盘出来了、进度条也动了。
    // 现在的做法：began 仍给 App（轻点才能用），但**移动帧先扣住**，App 累计横向位移始终为 0，
    // 横滑手势立不起来；看清是纵向 / 向右就立刻放行（App 拿到后续移动帧照样滚，只晚一两帧）。
    private static var bandHoldTouchID: UInt = 0
    private static var bandHoldDeadline: CFTimeInterval = 0
    /// V0.1.13（AevonBandTakeoverBeganV113）：起手窗「不干预」证据的限频时间戳。
    /// 这一段默认整段交回 App，只有这一行日志能证明「我们看过了、但没碰」。
    private static var bandPassLogAt: CFTimeInterval = 0
    /// 判定期上限（秒）：超时还没定向就整根放行。
    /// 宁可漏一次，也绝不让右缘变成「划不动」—— 这是本机制唯一可能伤到用户的地方。
    private static let bandHoldLimit: CFTimeInterval = 0.6

    // V0.1.15（AevonRightEdgeTakeoverV115）：右缘接管带「按下即接管」的当前手指。
    //
    // 与上面的 bandHoldTouchID 是**互斥的两套**：那套是「began 给 App、只扣移动帧」的旧机制
    // （0.1.12 留下、0.1.13 默认停用），这套是「began 就吞」的新机制。二者同时只用一套。
    private static var rightEdgeTouchID: UInt = 0
    private static var rightEdgeStart: CGPoint = .zero
    /// 判向日志只记一次（逐帧刷屏没意义，一次足够定位方向）
    private static var rightEdgeDirLogged = false
    /// 右缘呼出计数器（日志里看「这一版到底用了几次右缘」）
    private static var rightEdgeCount = 0

    // V0.1.18（AevonRightEdgeMissHintV118）：**带外落点候选**（只记录，绝不接管）。
    //
    // 起手落在「右缘 46pt 内、但不在接管带里」（宽度外 / 高度外 / 开关没开）时记在这里。
    // 抬手时用它回答一个问题：这一次到底是「他想呼出但落空了」，还是「他就是在用 App」。
    // 判据只看位移方向 —— 左扫成立 = 他想呼出，我们欠他一个更大的带；
    // 其余方向 = 正常 App 操作，说明没误伤（这半句同样重要）。
    // 它不参与任何吞摸决策，只是把取证做完。
    private static var rightEdgeMissTouchID: UInt = 0
    private static var rightEdgeMissStart: CGPoint = .zero
    private static var rightEdgeMissReason = ""

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
    /// V0.1.17（AevonDeadManV117）：圆盘展开时刻，死手开关据此兜「圆盘状态泄漏」。
    private static var ringOpenedAt: CFTimeInterval = 0

    // MARK: - V0.1.17 急救与死手开关（AevonDeadManV117 / AevonPanicThreeFingerV117）
    //
    // 起因是真机事故 Aevon(84)：用户打开「显示右缘接管带」后**整个屏幕失去操作**，
    // 只能卸载插件恢复。那次是绘制路径卡死主线程；但它也暴露了一个更危险的结构性问题：
    // 本插件有三条「整屏吞摸」的路（热区 / 右缘接管带 / 圆盘展开期），
    // 任何一条的状态机漏掉一次 ended，用户就会面对一块点不动的屏幕，且**没法自己救**。
    //
    // 所以这一版补两道闸：
    //   ① 死手开关：0.2 秒巡检一次，接管状态一旦超过自己的期限还没被清除，强制清空；
    //      圆盘展开超过 20 秒强制收起。最坏情况从「只能卸载」变成「最多 4 秒自动恢复」。
    //   ② 三指急救：任何位置三根手指同时按下 → 立刻释放全部接管。
    //      这条不依赖任何视图、任何开关，只要 hook 在就有效，是真正的逃生门。
    //
    // V0.1.19（AevonPanicHoldV119）：第 ② 条拆成两档 —— 三指只释放、按住 2 秒才关开关。
    // 起因见 Aevon(86)：一次普通三指操作就把「右缘接管带」静默关掉，用户全程没有可见反馈。

    /// 正在屏幕上的手指数（按 UITouch 指针计）。只用于三指急救判定。
    private static var activeTouches = Set<UInt>()
    /// 急救限频（3 秒内只执行一次，避免三指按住不放时反复写盘）
    private static var panicAt: CFTimeInterval = 0
    /// V0.1.19（AevonPanicHoldV119）：三指「开始同时按下」的时刻，0 表示当前不足三指。
    ///
    /// 为什么要有它：旧版只要屏幕上同时有 3 个触点，三指急救就立刻把
    /// 「右缘接管带 / 右缘全域接管」写盘关掉。Aevon(86) 的日志里，用户在 17:51:51
    /// 做了一次三指操作（iOS 的三指轻点撤销 / 三指捏合复制都会命中），开关被静默关闭，
    /// 之后 40 秒里两次右缘尝试全部落空（一次距右缘 36pt、一次只有 9pt），
    /// 而屏幕上没有任何提示 —— 用户唯一的感受就是「这一版还是没修好」。
    ///
    /// 现在分两档：
    ///   · 三指成形 → **立即**释放全部接管（不写盘、不关开关，松手即恢复）；
    ///   · 按住 0.6 秒 → 弹提示条，告诉用户还能继续按住；
    ///   · 按住 2.0 秒 → 才写盘关闭右缘两个开关（附提示条）。
    private static var panicHoldSince: CFTimeInterval = 0
    /// 本次三指按住是否已经执行过「释放」档，避免 0.2 秒轮询重复释放 / 重复提示
    private static var panicHoldReleased = false
    /// 三指按住多少秒弹提示条
    private static let panicHoldHintAfter: CFTimeInterval = 0.6
    /// 三指按住多少秒才真正关闭右缘两个开关
    private static let panicHoldDisableAfter: CFTimeInterval = 2.0
    /// V0.1.19：急救释放后的冷却期。这段时间里不再接管任何新落点 ——
    /// 否则三指操作里落在右缘的那根手指会被「刚释放完又立刻接管」，等于白释放。
    private static var panicCooldownUntil: CFTimeInterval = 0
    /// 接管状态宽限（秒）：超过自己的 deadline 再加这个余量还没被清 → 判定为泄漏
    private static let deadManGrace: CFTimeInterval = 1.0
    /// 圆盘展开硬上限（秒）：超过就强制收起（正常一次选择不会超过 20 秒）
    private static let ringOpenLimit: CFTimeInterval = 20

    /// 释放**所有**整指接管状态。幂等，任何路径都能调。
    ///
    /// 只清「谁归我」这类状态，不动浮窗几何、不动偏好、不动圆盘内容 ——
    /// 目的是把手指还给系统，不是把用户的活儿撤销。
    static func releaseAllTakeover(_ reason: String) {
        let hadState = ownsTouch || globalTouchID != 0 || rightEdgeTouchID != 0 || bandTouchID != 0
        ownsTouch = false
        globalTouchID = 0
        globalFired = false
        swallowDeadline = 0
        rightEdgeTouchID = 0
        rightEdgeStart = .zero
        rightEdgeDirLogged = false
        rightEdgeMissTouchID = 0
        rightEdgeMissStart = .zero
        rightEdgeMissReason = ""
        bandTouchID = 0
        bandStart = .zero
        bandHoldTouchID = 0
        bandHoldDeadline = 0
        ringExtraTouchID = 0
        ringExtraDeadline = 0
        ringSource = ""
        if hadState {
            AevonLog.warn("[急救] 已释放接管状态（\(reason)）（AevonDeadManV117）")
        }
    }

    /// 三指急救（V0.1.19 AevonPanicHoldV119 起改成两档）。
    ///
    /// **第一档（三指一成形就执行）**：只把手指还给系统，不写任何偏好 ——
    /// 松手以后一切照旧，误触的代价只有「这一次接管被打断」。
    /// 这一档放在 began 里直接调用，不依赖 0.2 秒轮询，所以插件开关关着也有效。
    static func panicReleaseNow(_ reason: String) {
        releaseAllTakeover(reason)
        AevonRingMenu.dismissCurrent()
        panicCooldownUntil = CACurrentMediaTime() + 0.8
    }

    /// **第二档（三指按住 2 秒）**：写盘关掉两个「整指吞」的开关。
    /// 这是真正的逃生门，代价是功能消失 —— 所以必须有可见提示，不能让用户以为插件坏了。
    private static func panicDisableRightEdge() {
        AevonPrefs.set("RightEdgeTakeover", false)
        AevonPrefs.set("BandTakeoverFromBegan", false)
        // V0.1.19：留一个标记，好让每次 SpringBoard 启动后还能提醒用户「这是被急救关的」。
        // 用户重新打开开关时由 checkTriggerZoneChange() 清除。
        AevonPrefs.set("RightEdgePanicOffV119", true)
        AevonPrefs.synchronize()
        AevonPanicHint.show("三指急救：已关闭「右缘接管带」。\n回设置「细节调整」里可以再打开。", duration: 4.0)
        AevonLog.warn("[急救] 三指按住 2 秒 → 已关闭「右缘接管带 / 右缘全域接管」并释放全部接管；不用卸载，回设置里可再打开（AevonPanicThreeFingerV117 AevonPanicHoldV119 AevonPanicHintV119）")
    }

    /// 死手开关：0.2 秒一次，只在「状态明显泄漏」时动手。
    static func enforceDeadManSwitch() {
        let now = CACurrentMediaTime()
        if ownsTouch, swallowDeadline > 0, now > swallowDeadline + deadManGrace {
            releaseAllTakeover("接管超期未释放")
        }
        if rightEdgeTouchID != 0, swallowDeadline > 0, now > swallowDeadline + deadManGrace {
            releaseAllTakeover("右缘接管超期")
        }
        if AevonRingMenu.isPresented, ringOpenedAt > 0, now > ringOpenedAt + ringOpenLimit {
            ringOpenedAt = 0
            AevonLog.warn("[急救] 圆盘展开超过 \(Int(ringOpenLimit)) 秒 → 强制收起（AevonDeadManV117）")
            AevonRingMenu.dismissCurrent()
            releaseAllTakeover("圆盘超期")
        }
        // V0.1.19（AevonPanicHoldV119）：三指按住的第二、三档升级。
        // 第一档（释放接管）已经在 began 里当场做了，这里只负责「超时升级」。
        if panicHoldSince > 0 {
            let held = now - panicHoldSince
            if held >= panicHoldHintAfter, !panicHoldReleased {
                panicHoldReleased = true
                AevonPanicHint.show("已释放接管。继续按住 2 秒可关闭「右缘接管带」。", duration: 2.5)
                AevonLog.warn("[急救] 三指按住 0.6 秒 → 已释放全部接管（未关闭任何开关）（AevonPanicHoldV119 AevonPanicHintV119）")
            }
            if held >= panicHoldDisableAfter, now - panicAt > 3.0 {
                panicAt = now
                panicHoldSince = 0
                panicHoldReleased = false
                panicDisableRightEdge()
            }
        }
    }

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
        // V0.1.17（AevonPanicThreeFingerV117）：急救判定放在**所有闸门之前** ——
        // 哪怕插件开关被关、右缘接管被关，只要 hook 还活着，三指同时按下就必须能救回来。
        switch phase {
        case .began:
            activeTouches.insert(touchID)
            if activeTouches.count > 6 { activeTouches.removeAll() }
            if activeTouches.count >= 3 {
                // V0.1.19（AevonPanicHoldV119）：三指成形 → **立即**释放接管，
                // 但**不再**在这里写盘关开关。旧版就是这一步把功能静默关掉的（Aevon(86) 17:51:51）。
                // 关开关要按住 2 秒，由 enforceDeadManSwitch 的轮询升级。
                if panicHoldSince == 0 {
                    panicHoldSince = CACurrentMediaTime()
                    panicHoldReleased = false
                    panicReleaseNow("三指同时按下")
                }
            } else {
                panicHoldSince = 0
                panicHoldReleased = false
            }
        case .ended, .cancelled:
            activeTouches.remove(touchID)
            if activeTouches.count < 3 {
                panicHoldSince = 0
                panicHoldReleased = false
            }
        default:
            break
        }
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        // V0.1.19（AevonPanicHoldV119）：急救释放后的 0.8 秒冷却期内，新落点一律不接管。
        // 三指操作里常有一指落在右缘带内，不挡的话会出现「刚释放完又立刻接管」。
        if phase == .began, CACurrentMediaTime() < panicCooldownUntil { return }
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
            // V0.1.11（AevonBandWidenV111）：接管带横向由「max(热区宽,36)」改成对齐系统手势通道的起手窗。
            //
            // Aevon(78) 日志：起手窗内落点在距右缘 39~45pt，通道「接收」了却一次都没 began；
            // 而更靠里的 45pt 落点连接受都没有。结论是**缝外那段没人兜底**：
            // 管线只在外侧 20pt 真的管事，20~46pt 又整条让路给管线 → 触摸两头落空，直接进 App。
            // 老通道是 sendEvent 观察者，**落指时不抢**（只在看清「向左 + 横向占优」后才吞），
            // 所以把它铺到 46pt 不吃点击、不吃滚动 —— 这段交给它是对的。
            let bandWidth = max(zone.width, AevonGestureBandView.beginSlack)
            let band = CGRect(x: screen.width - bandWidth, y: 0,
                              width: bandWidth, height: screen.height)
            let edgeEnabled = AevonPrefs.bool("EdgeGestureEnabled", default: true)
            let inZone = zone.contains(point)
            // V0.1.8（AevonSystemGestureV108）：把「右缘真的来了触摸」这件事回报给系统手势通道，
            // 让通道自己判断登记是否真的生效（它只在「识别器一次都没被问过」时才降级）。
            // V0.1.12 起右缘已不依赖管线呼出，这里的计数只用于记录管线状态，降级也不影响呼出。
            if appForeground, !inZone, band.contains(point) {
                AevonSystemGestureV105.shared.noteBandTouchSeenByGlobalChannel(at: point)
            }
            // V0.1.12（AevonBandHoldMovedV112）：**整条右缘（0~46pt）一律由本通道登记候选**，
            // 包含原来让给系统手势管线的那 20pt 缝。
            //
            // 判据来自 Aevon(79)：15 次呼出全部落在右下角热区（x=417~425，距右缘 5~13pt）、
            // 全部成功、抖音一次没动 —— 说明「偶尔触发」的那几次必然落在热区之外。
            // 而热区之外以前是「began 照给 App，等看清方向才吞」，判定期内 App 已经吃到 6pt 横向位移，
            // 抖音自己的横滑阈值就在这个量级，快一点、斜一点它就抢先立起来。
            // 0.1.11 想让管线接手这段，可「登记进管线」只能让它被问要不要，真正跟踪仍要视图命中
            // （0.1.11 自己的结论），靠不住。所以改由本通道独家负责，机制换成
            // 「began 照给 App、移动帧先扣住」—— 纯 SB 侧就确定生效，不必赌管线的跟踪能力。
            // 管线保留登记，只当「began 延迟器」叠加使用；它的呼出已被否决，不会双呼。
            //
            // 桌面只认原热区（接管优先，V0.0.33 同款）；App 前台才启用整条右缘接管带。
            if edgeEnabled, inZone || (appForeground && band.contains(point)) {
                if inZone {
                    // 原热区：老规矩，按下即完全接管（App 连 began 都收不到）。
                    // 热区这条路「began 就吞」，所以没有孤儿触摸问题，扣帧状态要顺手清掉。
                    bandHoldTouchID = 0
                    bandHoldDeadline = 0
                    globalTouchID = touchID
                    globalStart = point
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
                // 浮窗贴右边缘时手柄就拖不动了。
                if !AevonEntryHost.pointHitsFloatingWindow(at: point) {
                    let gap = Int(screen.width - point.x)
                    // V0.1.15（AevonRightEdgeTakeoverV115）：**右缘接管带 = 第二个热区**。
                    //
                    // 优先级：热区（上面已 return）→ 本带 → 0.1.13 的「起手窗两态」遗留分支。
                    // 本带是热区的真子集（默认 28pt × 下半 60%，热区在右下角 48×320），
                    // 所以本带接管的那一段，热区早就先接走了；它接的是热区上方那一段右缘。
                    //
                    // 机制与热区完全一致：began 就把这根手指收归自己（ownsTouch + globalTouchID），
                    // hook 紧接着的「要不要吞」询问必然拿到 YES，`UIApplication -sendEvent:`
                    // 整个 UIEvent 被丢弃 → App 连 began 都收不到。
                    // 这条路不再依赖识别器（P7 已证明系统手势环境只给观察权）、
                    // 不再依赖视图命中（P7-1 证明命中早就赢了、但赢了也拦不住 App）。
                    if AevonRightEdge.enabled, appForeground,
                       AevonRightEdge.band(in: screen).contains(point) {
                        // 上一根手指的 ended 万一丢了（多指 / 场景切换），新的一根直接顶替它，
                        // 方向日志也重新开始 —— 绝不能让旧状态把新手指判成「已定向」。
                        rightEdgeTouchID = touchID
                        rightEdgeStart = point
                        rightEdgeDirLogged = false
                        // 旧的扣帧状态与新的接管互斥，顺手清干净。
                        // `bandTouchID` 也必须一起清：它是上一套机制（0.1.12 扣移动帧）的候选指针，
                        // 万一它的 ended 丢了、指针又被系统复用给这根新手指，
                        // 新手指就会在 moved 里被旧分支当成「判向失败」而撒手（ownsTouch 被清）。
                        bandHoldTouchID = 0
                        bandHoldDeadline = 0
                        bandTouchID = 0
                        bandStart = .zero
                        // 上一根手指的带外候选也一并清（touchID 是 UITouch 指针，会被复用）
                        rightEdgeMissTouchID = 0
                        rightEdgeMissStart = .zero
                        rightEdgeMissReason = ""
                        globalTouchID = touchID
                        globalStart = point
                        globalFired = false
                        lastTouchPoint = point
                        ownsTouch = true
                        swallowDeadline = CACurrentMediaTime() + pressLimit
                        rightEdgeCount += 1
                        // V0.1.16：接管成功闪一下带（开关关着时是空操作）
                        AevonSystemGestureV105.flashBandIndicator()
                        AevonLog.info("[右缘] 起手 (\(Int(point.x)),\(Int(point.y))) 距右缘 \(gap)pt → 归口=右缘接管带·在带内·按下即接管（App 连 began 都收不到；\(AevonRightEdge.summary(in: screen))），第 \(rightEdgeCount) 次（AevonRightEdgeTakeoverV115 AevonBandTakeoverBeganV113 AevonRightEdgeShowBandV116 AevonRightEdgeDefaultV118）")
                        return
                    }
                    // V0.1.13（AevonBandTakeoverBeganV113）：起手窗改成**两态**，中间态全部作废。
                    //
                    // Aevon(80) 复盘把 0.1.12 的「began 给 App、只扣移动帧」判死：
                    // App 拿到 began，就拿到了这根 touch 的起点；我们又放行 ended，
                    // 而 ended 的落点就是抬起位置 —— UITouch 的坐标每帧都在更新，
                    // 我们只是没把中间帧投递过去，最终位置照样躺在 ended 里。
                    // 所以「扣移动帧」挡不住横滑，只会让右缘变迟钝（微信式滑动会卡一两帧）。
                    // 结论：要么连 began 一起吞（App 完全看不到，100% 干净），要么整段不碰。
                    if AevonPrefs.bool("BandTakeoverFromBegan", default: false) {
                        // ① 按下即接管：与热区同语义，App 连 began 都收不到。
                        //    代价明说：这条带（右缘 20~46pt × 全屏高）里 App 的轻点也收不到，
                        //    抖音那排点赞 / 评论 / 收藏会点不动 —— 所以默认关，由用户自己开。
                        bandTouchID = touchID
                        bandStart = point
                        bandHoldTouchID = 0
                        bandHoldDeadline = 0
                        globalTouchID = touchID
                        globalStart = point
                        globalFired = false
                        lastTouchPoint = point
                        ownsTouch = true
                        swallowDeadline = CACurrentMediaTime() + pressLimit
                        forensicCount += 1
                        AevonLog.info("[右缘] 落点 (\(Int(point.x)),\(Int(point.y))) 距右缘 \(gap)pt → 归口=右缘全域接管·按下即接管（App 连 began 都收不到），第 \(forensicCount) 次（AevonBandTakeoverBeganV113 AevonBandHoldMovedV112）")
                        return
                    }
                    // ② 默认：只留一行证据，**不登记、不扣帧、不吞**，整段交回 App。
                    //    这是本版唯一诚实的选择：既然我们无法在不吞 began 的前提下阻止 App 拿到位移，
                    //    那就别碰 —— 呼不出圆盘只是少一个入口，绝不能变成「抖音被带起来」。
                    //
                    // V0.1.18（AevonRightEdgeMissHintV118）：这一行必须**自己说出原因**。
                    // Aevon(85) 四次落点全落在这里，日志却是同一句话，看上去像我们主动放弃；
                    // 实际是「宽度差 1pt」「y 在带顶之上 292pt」这种纯几何问题。
                    // 现在把「带外原因 + 需要多大才进」直接写出来，并登记为「落点候选」，
                    // 抬手时再补一行「本可命中 / 本次是 App 操作」。
                    let now = CACurrentMediaTime()
                    let miss = AevonRightEdge.missReason(for: point, in: screen)
                    rightEdgeMissTouchID = touchID
                    rightEdgeMissStart = point
                    rightEdgeMissReason = miss
                    if now - bandPassLogAt > 1.0 {
                        bandPassLogAt = now
                        AevonLog.info("[右缘] 落点 (\(Int(point.x)),\(Int(point.y))) 距右缘 \(gap)pt → 归口=起手窗·本版不干预（整段交回 App；\(miss)）（AevonBandTakeoverBeganV113 AevonRightEdgeMissHintV118）")
                    }
                    return
                }
            }
            // 正常流程走不到这里：接管带已铺到 46pt，右缘触摸都会在上一段被接走。
            // 留着是为了「右缘呼出已关 / 浮窗压住」这两种情况仍有痕迹。
            if forensicCount < 40, appForeground, point.x >= screen.width - AevonGestureBandView.beginSlack {
                forensicCount += 1
                let gap = Int(screen.width - point.x)
                let why = !edgeEnabled ? "右缘呼出已关" : "浮窗压住"
                AevonLog.info("[穿透取证] began (\(Int(point.x)),\(Int(point.y))) 接管=否（\(why)，距右缘 \(gap)pt，App前台=\(appForeground)，计数 \(forensicCount)）（AevonBandDeferV103 AevonForensicBandV102 AevonBandHoldMovedV112）")
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
                if AevonSystemGestureV105.isHandling(touchID: touchID) {
                    bandTouchID = 0
                    bandStart = .zero
                    bandHoldTouchID = 0
                    return
                }
                let dx = point.x - bandStart.x
                let dy = point.y - bandStart.y
                if dx <= -6, abs(dx) >= abs(dy) * 1.2 {
                    bandTouchID = 0
                    globalTouchID = touchID
                    globalStart = bandStart
                    globalFired = false
                    lastTouchPoint = point
                    ownsTouch = true
                    swallowDeadline = CACurrentMediaTime() + swallowLimit
                    // V0.1.12：扣帧窗口跟着接管一起续期 —— 否则 0.6s 判定期一到就松手，
                    // 整条滑动后半段会漏回 App（那等于把刚补上的洞重新挖开）。
                    bandHoldDeadline = CACurrentMediaTime() + swallowLimit
                    AevonLog.info("[边缘] 接管带确认左扫 → 收归圆盘（dx=\(Int(dx)) dy=\(Int(dy))，起点 \(Int(bandStart.x)),\(Int(bandStart.y))）（AevonBandDeferV103 AevonBandHoldMovedV112）")
                } else if bandHoldTouchID == touchID,
                          let reason = bandReleaseReason(dx: dx, dy: dy) {
                    // 只有「扣移动帧」模式才谈得上放手；按下即接管模式（V0.1.13）一旦吞了 began，
                    // 中途撒手也没用 —— App 没有 began 就拿不住这根 touch，放出去只是白放。
                    // V0.1.12：看清不是左扫就**立刻放行**。扣移动帧是为了不让 App 立起横滑手势，
                    // 不是为了拦它滚动 —— 放行后 App 拿到后续移动帧照常生效（只晚一两帧）。
                    bandTouchID = 0
                    bandStart = .zero
                    bandHoldTouchID = 0
                    bandHoldDeadline = 0
                    if touchID == globalTouchID {
                        globalTouchID = 0
                        globalFired = false
                        ownsTouch = false
                    }
                    AevonLog.info("[穿透取证] 放手→App（dx=\(Int(dx)) dy=\(Int(dy))，原因=\(reason)）（AevonBandHoldMovedV112 AevonBandDeferV103）")
                }
            }
            guard touchID == globalTouchID else { return }
            lastTouchPoint = point
            if ownsTouch { swallowDeadline = CACurrentMediaTime() + pressLimit }
            // V0.1.15（AevonRightEdgeTakeoverV115）：右缘接管带的判向证据，一根手指只记一次。
            // 这里**只记录、不决策** —— began 已经被 sendEvent 丢掉了，判向失败也还不回 App
            // （App 没有 began 就拿不住这根 touch）。记它只为下一次复盘时知道方向分布。
            if touchID == rightEdgeTouchID, !rightEdgeDirLogged {
                let rdx = point.x - rightEdgeStart.x
                let rdy = point.y - rightEdgeStart.y
                if abs(rdx) >= 8 || abs(rdy) >= 8 {
                    rightEdgeDirLogged = true
                    let dir = (rdx <= -8 && abs(rdx) >= abs(rdy) * 1.2)
                        ? "左扫"
                        : (abs(rdy) > abs(rdx) ? "纵向" : "向右")
                    AevonLog.info("[右缘] 判向 dx=\(Int(rdx)) dy=\(Int(rdy)) → \(dir)（在带内·已吞，不还 App）（AevonRightEdgeTakeoverV115）")
                }
            }
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
            // V0.1.15：右缘接管带用 1.2 的横向占优比（与它自己的判向日志一致），
            // 热区那条路维持原来的 0.7（热区已验证 12/12，不动它）。
            let horizontalRatio: CGFloat = (touchID == rightEdgeTouchID) ? 1.2 : 0.7
            if !globalFired, dx <= -AevonEdgeStripView.swipeDistance, abs(dx) >= abs(dy) * horizontalRatio {
                globalFired = true
                if touchID == rightEdgeTouchID {
                    // V0.1.16：判向成立再闪一次 —— 用户能分清「接住了」与「接住并呼出」
                    AevonSystemGestureV105.flashBandIndicator()
                    AevonLog.info("[右缘] 判向成立 → 呼出圆盘（dx=\(Int(dx)) dy=\(Int(dy))，起点 \(Int(globalStart.x)),\(Int(globalStart.y))）（AevonRightEdgeTakeoverV115 AevonRightEdgeShowBandV116）")
                }
                attemptTrigger("全局左滑 \(Int(dx))pt", source: "global")
            }

        case .ended:
            // V0.1.15：右缘接管带抬手 —— 只清本带状态，**绝不 return**，
            // 让下面的 globalTouchID 清理照常跑到；否则会留下一个指向已释放 UITouch 的
            // globalTouchID（指针会被复用，下一根手指可能莫名被吞）。
            if touchID == rightEdgeTouchID {
                if !globalFired {
                    AevonLog.info("[右缘] 抬手，全程未定向 → 只吞不呼出（AevonRightEdgeTakeoverV115）")
                }
                rightEdgeTouchID = 0
                rightEdgeStart = .zero
                rightEdgeDirLogged = false
            }
            // V0.1.12：抬手一律先清「扣移动帧」状态 —— 抬手帧在 hook 里已经放行给 App 了，
            // 这里不清会留下一个永远吞移动帧的指针（touchID 是 UITouch 指针，会被复用）。
            if touchID == bandHoldTouchID {
                bandHoldTouchID = 0
                bandHoldDeadline = 0
            }
            // V0.1.18（AevonRightEdgeMissHintV118）：带外落点抬手 → 补一行结论。
            //
            // 这一行把「落空」和「正常操作」分开：
            //   · 左扫成立 → 他本来要呼出，是我们欠他一个更大的带（给出所需宽度）；
            //   · 其它方向 → 他就是在用 App，说明没误伤（这半句同样要留证）。
            // 不 return：miss 候选本来就没被接管，后面的 guard 会自然放行。
            if touchID == rightEdgeMissTouchID {
                let mdx = point.x - rightEdgeMissStart.x
                let mdy = point.y - rightEdgeMissStart.y
                let sweep = mdx <= -AevonEdgeStripView.swipeDistance && abs(mdx) >= abs(mdy) * 1.2
                let start = rightEdgeMissStart
                let reason = rightEdgeMissReason
                rightEdgeMissTouchID = 0
                rightEdgeMissStart = .zero
                rightEdgeMissReason = ""
                let gap = Int((UIScreen.main.bounds.width - start.x).rounded())
                if sweep {
                    // V0.1.19（AevonPanicHintV119）：开关关着时，原来的「把宽度调到 ≥Npt」是错的建议 ——
                    // Aevon(86) 17:52:31 那次距右缘只有 9pt、带宽早已是 46pt，日志却还在让他调宽度。
                    // 开关没开就先把这件事说清楚。
                    if AevonRightEdge.enabled {
                        AevonLog.info("[右缘] 本可命中：起手 (\(Int(start.x)),\(Int(start.y))) 距右缘 \(gap)pt，\(reason)；这次左扫 dx=\(Int(mdx)) dy=\(Int(mdy)) 已经进了 App → 把「右缘带宽度」调到 ≥\(gap)pt（或带高调到能让 y=\(Int(start.y)) 进带）就能在这里呼出（AevonRightEdgeMissHintV118）")
                    } else {
                        AevonLog.info("[右缘] 本可命中：起手 (\(Int(start.x)),\(Int(start.y))) 距右缘 \(gap)pt，\(reason)；这次左扫 dx=\(Int(mdx)) dy=\(Int(mdy)) 已经进了 App → 宽度本身够（当前 \(Int(AevonRightEdge.width))pt），是开关关着；到设置里打开「右缘接管带」就能在这里呼出（AevonRightEdgeMissHintV118 AevonPanicHintV119）")
                    }
                } else {
                    let dir = abs(mdy) > abs(mdx) ? "纵向" : "向右"
                    AevonLog.info("[右缘] 带外落点结束：起手 (\(Int(start.x)),\(Int(start.y))) 距右缘 \(gap)pt，\(reason)；位移 dx=\(Int(mdx)) dy=\(Int(mdy)) → \(dir)不是左扫 → 本次是 App 自己的操作，未误伤（AevonRightEdgeMissHintV118）")
                }
            }
            // V0.0.41：浮窗拖拽抬手 —— 提交几何 / 命中 ✕ 才关窗 / 记录双击候选
            if handleFloatGestureEnded(point: point, touchID: touchID, cancelled: false) { return }
            // V0.0.29：额外手指抬起（hook 已按「先询问再上报」把抬手帧吞掉）—— 只清状态
            if touchID == ringExtraTouchID {
                ringExtraTouchID = 0
                ringExtraDeadline = 0
                return
            }
            // V0.1.3：接管带候选抬手（始终没成左扫）—— 只清状态，事件本就归 App
            // V0.1.13：按下即接管模式下这根手指同时挂在 globalTouchID 上，
            // 只清 bandTouchID 会留下一个指向已释放 UITouch 的 globalTouchID（指针会被复用），
            // 所以两套状态一起清。
            if touchID == bandTouchID {
                bandTouchID = 0
                bandStart = .zero
                if touchID == globalTouchID {
                    globalFired = false
                    ownsTouch = false
                    globalTouchID = 0
                }
                return
            }
            guard touchID == globalTouchID else { return }
            if let ring = AevonRingMenu.presented {
                ring.remoteEnded(at: point, source: "global")
            }
            // V0.1.5（AevonNoTapSummonV105）：**轻点热区呼出圆盘已删除**。
            // 归档(14) 用户反馈：热区就在右下角，日常操作（返回、发消息、刷到屏幕边缘）
            // 动不动就误触，圆盘莫名弹出来。现在只保留「热区里向左滑」这一种呼出手势，
            // 轻点一律什么都不做（这根手指仍被接管，所以也不会漏给 App）。
            globalTouchID = 0
            globalFired = false
            ownsTouch = false

        case .cancelled:
            // V0.1.15：同 ended，右缘接管带只清本带状态，不提前 return
            if touchID == rightEdgeTouchID {
                rightEdgeTouchID = 0
                rightEdgeStart = .zero
                rightEdgeDirLogged = false
            }
            // V0.1.12：被系统取消同样先清扣帧状态
            if touchID == bandHoldTouchID {
                bandHoldTouchID = 0
                bandHoldDeadline = 0
            }
            // V0.1.18：带外落点候选被系统取消 —— 只清状态，不出结论（落点已被打断，没有意义）
            if touchID == rightEdgeMissTouchID {
                rightEdgeMissTouchID = 0
                rightEdgeMissStart = .zero
                rightEdgeMissReason = ""
            }
            // V0.0.41：浮窗拖拽被系统打断 —— 缩放退回原几何，移动不落盘
            if handleFloatGestureEnded(point: point, touchID: touchID, cancelled: true) { return }
            if touchID == ringExtraTouchID {
                ringExtraTouchID = 0
                ringExtraDeadline = 0
                return
            }
            // V0.1.3：接管带候选被系统取消 —— 只清状态
            // V0.1.13：同 ended，两套状态一起清
            if touchID == bandTouchID {
                bandTouchID = 0
                bandStart = .zero
                if touchID == globalTouchID {
                    globalFired = false
                    ownsTouch = false
                    globalTouchID = 0
                }
                return
            }
            guard touchID == globalTouchID else { return }
            AevonRingMenu.presented?.remoteCancelled(source: "global")
            globalTouchID = 0
            globalFired = false
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
        ringOpenedAt = 0
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

    /// V0.1.12：右缘起手窗是否正持有这根手指（供系统手势通道防双呼）。
    ///
    /// 右缘呼出现在独家归本通道 —— 它扣移动帧，是纯 SB 侧确定生效的机制；
    /// 管线里那个识别器只要也 begin，就会各呼一次圆盘，所以那边直接否决。
    static var isBandHoldingTouch: Bool {
        return bandHoldTouchID != 0
    }

    /// V0.1.12：判定期内的放行判据。返回 nil = 方向还没定，继续扣着移动帧。
    ///
    /// 顺序不能换：调用方先判「向左横扫」收归圆盘，剩下才问这里要不要放手。
    /// 纵向判据用「纵向位移绝对占优」（|dy| ≥ 5 且 |dy| > |dx|）而不是「|dx| 很小」——
    /// 快速竖划的第一帧可能已经带了 5~8pt 横向抖动，按「|dx| 小」判会一路扣着不放，
    /// 那才是真正会让右缘「划不动」的写法。
    private static func bandReleaseReason(dx: CGFloat, dy: CGFloat) -> String? {
        if abs(dy) >= 5, abs(dy) > abs(dx) { return "纵向滚动（|dy|>|dx|）" }
        if dx >= 3 { return "向右扫" }
        if CACurrentMediaTime() > bandHoldDeadline { return "\(Int(bandHoldLimit * 1000))ms 内未定向" }
        return nil
    }

    /// `AevonTouchHook.m` 逐帧询问：这根触摸要不要吞掉（不投递给 App）。
    ///
    /// `phase`：0 = began，1 = moved，3 = ended，4 = cancelled（V0.1.12 起传入）。
    ///
    /// 三条独立的接管路径，任意一条成立就吞：
    ///   A. **右缘起手窗扣移动帧（V0.1.12 / AevonBandHoldMovedV112）**：began 与抬手放行，
    ///      只扣「方向未定」的移动帧 —— App 累计横向位移恒为 0，横滑手势立不起来。
    ///   B. **热区接管（V0.0.25）**：App 前台时，手指一落到热区就归我们 —— 连 began 都不给 App。
    ///   C. **圆盘接管（V0.0.24）**：圆盘已由全局通道唤起，继续接管到圆盘收起。
    ///
    /// 还有三条硬性前提：必须是唤起/接管的那一根手指（别的指头照常给 App），且没超时。
    static func shouldSwallowGlobalTouch(_ touchID: UInt, phase: Int) -> Bool {
        guard AevonPrefs.bool("Enabled", default: false) else { return false }
        guard touchID != 0 else { return false }
        // A. 右缘起手窗：只扣移动帧（V0.1.12）
        //
        //   · began 一律放行 —— 轻点 / 长按 / App 自己的按钮必须照常可用；
        //   · 抬手一律放行 —— 否则 App 会留下一条只有 began、永远没有 ended 的孤儿触摸。
        //     （热区那条路 began 就吞了，所以它没有孤儿问题；这条路 began 是给出去的，必须有始有终。）
        //   · 已收归圆盘 → 后续移动帧全吞；
        //   · 判定期内 → 扣住移动帧；超时放行（宁可漏一次，也绝不让右缘变成「划不动」）。
        if touchID == bandHoldTouchID {
            if phase == 3 || phase == 4 { return false }
            if phase == 0 { return false }
            if ownsTouch, touchID == globalTouchID { return true }
            guard CACurrentMediaTime() <= bandHoldDeadline else { return false }
            return true
        }
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
///
/// V0.1.12（AevonBandHoldMovedV112）：多收一个 `phase`。右缘起手窗要「began 放行、移动帧扣住、
/// 抬手放行」，光凭 touchID 分不出这三件事。签名改了就必须两侧同改 —— AevonTouchHook.m 里的
/// extern 声明已同步，CI 也会查这两处。
@_cdecl("AevonGlobalTouchShouldSwallow")
public func AevonGlobalTouchShouldSwallow(_ touchID: UInt, _ phase: Int) -> Bool {
    return AevonEdgeEntry.shouldSwallowGlobalTouch(touchID, phase: phase)
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

/// V0.2.1（AevonAppTriggerBridgeV201）：App 进程内识别器判向成立的通知回调。
///
/// App 侧（AevonApp.dylib）在右缘 30pt 横向占优时：① 让 App 收到合法的
/// touchesCancelled（圆盘出来了 App 不再跟着动）；② 广播本通知。SB 收到后呼圆盘。
///
/// 双呼免疫：右下角热区的触摸 SB 自己也会命中（全局通道，来源 global），
/// 与本通知都汇入 attemptTrigger —— 0.6 秒去重 + isPresented 闸保证只呼一次，
/// 谁先到谁呼。圆盘呼出后那根手指的跟手旋转走不上（App 侧已取消、SB 侧
/// 未登记该指），圆盘以「等待点选」形态存在，点图标 / 盘外松手照常。
private func aevonAppTriggerHandler(_ center: CFNotificationCenter?,
                                    _ observer: UnsafeMutableRawPointer?,
                                    _ name: CFNotificationName?,
                                    _ object: UnsafeRawPointer?,
                                    _ userInfo: CFDictionary?) {
    DispatchQueue.main.async {
        AevonEdgeEntry.attemptTrigger("App 侧右缘判向成立（App 触摸已被合法取消）", source: "appedge")
    }
}

/// V0.1.2（AevonGuardCleanupV102）：Guard 回执计数与 handler 已随 Guard 移除。
/// 历史 CI 校验串（AevonGuardAckV35）由 AevonAssertionShim.m 的 used 常量收容。
