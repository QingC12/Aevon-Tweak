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
    // V0.2.11（AevonBandRangeFreeV211）：上下限放开。
    //
    // 用户 Aevon(97)：「橙色右侧接管带的高度和宽度调节存在固定数值，无法继续降低高度」。
    // 0.1.18 把区间定成 24~46pt / 40~100%，依据是当时「把宽度调到必然落空 =
    // 把猜落点成本转给用户」这个结论。但那是**默认值**该守的纪律，不是**滑条**该守的：
    // 用户明确要「随意更改」，而限制区间只会让他以为滑条坏了。
    // 现在：宽度 8~140pt（8 = 只认最贴边的 8pt，140 ≈ 屏宽 1/3）、
    //       带高 6~100%（6% ≈ 底部 56pt 的右下角一小块）。
    // 默认值一个都不动（46 / 60），所以老用户升级后手感完全相同。
    // 落地时仍然 clamp，clamp 只防「手改偏好域写出非法值」，不再挡住正常拖动。
    static let defaultWidth: Double = 46
    static let defaultHeightPercent: Double = 60
    static let minWidth: Double = 8
    static let maxWidth: Double = 140
    static let minHeightPercent: Double = 6
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
        // V0.2.11（AevonBandRangeFreeV211）：区间放开到 8~140pt / 6~100% 之后，
        // 每行摘要都把「现在生效的区间」写出来 —— 用户报「滑条拖到底就不动了」时，
        // 一眼能看出是自己拖到了边界，还是代码又把它夹住了。
        return "宽 \(Int(r.width))pt · 高占比 \(Int(heightPercent))%（带 x \(Int(r.minX))~\(Int(r.maxX)) y \(Int(r.minY))~\(Int(r.maxY))；可调 \(Int(minWidth))~\(Int(maxWidth))pt / \(Int(minHeightPercent))~\(Int(maxHeightPercent))%）（AevonBandRangeFreeV211）"
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
        // V0.2.19（AevonSysEdgeBandGateV219）：这里原来有一条
        //   `guard enabled else { return "带外·开关未打开（…到设置里打开「右缘接管带」即可）" }`
        // 而 `enabled` 读的是 `RightEdgeTakeover` —— 那个开关在 0.2.15 随 SB 侧吞摸一起下线、
        // 0.2.17 从设置页撤掉，代码里恒 false。于是 Aevon(104) 的日志里每一行带外记录
        // 都变成「去设置里打开一个已经不存在的开关」（13:49:11.663 / 13:49:21.757 等 11 处）。
        // 带外的真实含义只有一个：这个落点不在你设定的热区里，本次整段交回 App。
        // 所以这里直接走几何分支，把「差多少」算给用户看。
        let widthShort = point.x < r.minX
        let heightShort = point.y < r.minY
        if widthShort, heightShort {
            return "带外·宽度和高度都差（距右缘 \(gap)pt 需带宽 ≥\(needWidth)pt，y=\(Int(point.y)) 需带高 ≥\(needPercent)%；当前 \(Int(width))pt×\(heightPercent)%）→ 整段交回 App（AevonMissReasonV219）"
        }
        if widthShort {
            return "带外·宽度差（距右缘 \(gap)pt，需带宽 ≥\(needWidth)pt，当前 \(Int(width))pt）→ 整段交回 App（AevonMissReasonV219）"
        }
        return "带外·高度差（y=\(Int(point.y)) 在带顶 y=\(Int(r.minY)) 之上，需带高 ≥\(needPercent)%，当前 \(Int(heightPercent))%）→ 整段交回 App（AevonMissReasonV219）"
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

    /// 手势条与触摸的关系，这一段被改过两次，两次的原因正好相反 ——
    ///
    /// **V0.2.9（AevonStripNoHitV209）→ 恒 nil**：Aevon(95) 22:36:43.398 的铁证是
    ///   `[边缘] 入口窗口收到触摸 (x=422, y=801，宽容区内=是)` →
    ///   `[边缘] 窗口层已接管边缘触摸（兜底判定生效）` →
    ///   `[边缘] 手势区收到触摸 (条内 x=10, y=130)`。
    /// 这根触摸在 **UIKit 命中测试** 阶段就被 18×260 的条子接走了；入口窗口
    /// level=10000000 压过 SBHomeScreenWindow，于是桌面**连 began 都收不到** ——
    /// 右下角点击与左右滑动同时死。当时的选择是「条子退回纯视觉，呼盘改走
    /// `sendEvent` 全局通道」。
    ///
    /// **V0.2.15（AevonDeskStripHitV215）→ 桌面上重新可命中**：那条全局通道的代价
    /// 后来被证明更大。`ownsTouch` 只让 `UIApplication -sendEvent:` 不往下投，
    /// 而桌面翻页 / Dock / 图标全是 SpringBoard 自己的视图 —— 吞一次就把整个桌面
    /// 连同系统手势一起吞掉（Aevon(101) 12:31:18~12:31:30 十二秒单指全死，
    /// 只有三指能穿过去）。
    ///
    /// 关键差别在于「桌面没有第二个进程」：条子在桌面上自己接下触摸，桌面从头到尾
    /// 就收不到这根手指 —— 不需要吞、不需要补投、不需要任何状态机。
    /// （Pullover-X 就是这个结构：一个真实可见、能摸到的手柄。）
    ///
    /// App 前台绝不允许命中：那里有 App 进程直投的一份触摸，条子接了也没用
    /// （App 照样滚），只会白丢 SpringBoard 这份。App 内的呼盘由 App 侧识别器负责。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard AevonEdgeEntry.isPureDesktop else { return nil }
        return super.hitTest(point, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard AevonEdgeEntry.isPureDesktop else { return false }
        return bounds.contains(point)
    }

    /// 原来的 touchesBegan / touchesMoved（下方「触摸（不使用手势识别器）」一节）保持不变 ——
    /// 它们只是永远收不到触摸了。留着是为了「万一有人把 hitTest 接回去」时行为可回溯，
    /// 而不是留一条隐形的新路径。

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
    /// V0.2.6（AevonEdgeFailGateV206）：App 侧最近一次判向失败（纵向/向右）的时刻，
    /// 此后 1.5s 内 global 兜底不得呼盘（那根手指是滚动/推回，不是呼出）。
    static var appEdgeFailUntil: CFTimeInterval = 0
    private static var loggedProbeBegan = false
    /// 最近一次边缘触摸的位置（窗口坐标），圆盘唤出时从这里接手那根手指
    private static var lastTouchPoint: CGPoint = .zero
    /// V0.2.14（AevonSwallowOnRingV214）：最近一次边缘触摸的时刻。
    ///
    /// 只为一件事：呼盘那一刻决定「要不要顺手把这根手指吞掉」时，
    /// 必须先确认 `globalTouchID` 指向的还是**活着的那根手指**。
    /// UITouch 指针会被系统复用 —— 没有这个时限，一个陈旧的 globalTouchID
    /// 会让圆盘的吞落到一根完全无关的新手指上。
    private static var lastTouchAt: CFTimeInterval = 0

    // MARK: - V0.2.10（AevonAppBlindHoldV210）App 侧在场判定
    //
    // Aevon(96) 09:49:09 抖音铁证：起手 → 判向成立 → 呼出圆盘，整条触摸里**没有**
    // `rightedgebegan`，我们自己的诊断行写着「本指无 App 侧起手痕迹（>2s 无让路）」。
    // 那根手指在 App 进程里从未被取消，圆盘一滑动抖音就跟着滚 —— 这就是「偶尔还会触发」。
    //
    // backboardd 双投已定论（0.2.0）：SB 侧在 sendEvent 层丢事件，只丢 SB 自己那一份，
    // App 那份碰不到；所以**事后无法补救**，只能在呼盘之前确认「这一侧到底在不在」。
    /// 最近一次收到 App 侧任何信号（appready / began / fail / trigger）的时刻。
    private static var appSideSignalAt: CFTimeInterval = 0
    /// 前台 App 换人的时刻（由 0.2 秒轮询比对 bundleID 得出）。
    private static var foregroundChangedAt: CFTimeInterval = 0
    /// 上一次看到的前台 bundleID
    private static var lastForegroundBundle = ""
    /// 盲期拒呼日志限频
    private static var blindHoldLoggedAt: CFTimeInterval = 0
    /// V0.2.15：全局通道呼盘被拦下的日志限频
    private static var globalGateLoggedAt: CFTimeInterval = 0
    /// 新前台 App 多久没给信号就认定为「盲期」（超过就放弃守门，当作未注入 App 处理）。
    private static let blindGateWindow: CFTimeInterval = 3.0

    /// App 侧发来任何信号 → 记「这一侧在场」。四个通知回调都调它。
    static func noteAppSideAlive() {
        appSideSignalAt = CACurrentMediaTime()
    }

    /// 前台 App 换人（0.2 秒轮询里比对）。
    private static func noteForegroundChange() {
        let bundle = AevonEntryHost.currentForegroundBundleID
        guard bundle != lastForegroundBundle else { return }
        lastForegroundBundle = bundle
        foregroundChangedAt = CACurrentMediaTime()
    }

    /// 现在这台前台 App 是不是「App 侧还没就位」的盲期。
    ///
    /// 判据三条，缺一不可：
    ///   ① 前台确实有 App（桌面永远不是盲期，桌面没有 App 进程要抢触摸）；
    ///   ② 换前台还不到盲期窗口（超过就说明这一侧可能根本没注入，守门会变成永久失效）；
    ///   ③ 这任前台**还没有任何** App 侧信号 —— `appSideSignalAt < foregroundChangedAt`
    ///      就是「上次信号发生在换前台之前」，等价于「这任一次都没响过」。
    private static func appSideIsBlind() -> Bool {
        // App 侧总开关被用户关掉时，这条守门必须让开 —— 那一侧本来就不会有任何信号，
        // 再守下去等于把「App 前台呼盘」整个功能关死（那是用户的选择，不是故障）。
        guard AevonPrefs.bool("AppSideEnabled", default: true) else { return false }
        guard AevonPrefs.bool("EdgeGestureEnabled", default: true) else { return false }
        // 浮窗开着时前台 bundleID 是浮窗里那个 App，但触摸归桌面通道处理（浮窗落点直通），
        // 拿它的在场状态去守门会误伤桌面热区 —— 这条路径不参与盲期判定。
        guard AevonWindowManager.openBundleID == nil else { return false }
        let bundle = AevonEntryHost.currentForegroundBundleID
        guard !bundle.isEmpty else { return false }
        let now = CACurrentMediaTime()
        guard now - foregroundChangedAt < blindGateWindow else { return false }
        return appSideSignalAt < foregroundChangedAt
    }

    /// 手势条是否已挂上（不代表手势一定能触发，触发靠系统触摸分发）
    static var isVisible: Bool { return strip != nil }

    static func install(attempt: Int, reason: String) {
        guard AevonPrefs.bool("Enabled", default: true) else { return }
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
        // V0.2.9（AevonStripNoHitV209）→ V0.2.15（AevonDeskStripHitV215）：
        // 条子在**桌面裸态**重新参与命中（自己接住触摸＝桌面收不到，见类头注释），
        // App 前台与浮窗仍然恒 nil。全局通道那一套吞摸本版已整体下线。
        AevonLog.info("[边缘] 手势条：桌面裸态可命中（自己接触摸，桌面不参与），App/浮窗恒 nil；SB 侧吞摸已下线（AevonStripNoHitV209 AevonDeskStripHitV215 AevonNoSBSwallowV215）")

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

    // MARK: - V0.2.20 右缘带几何发布（AevonAppGeomNotifyV220）

    /// 上次发布到共享内存的几何（变更检测：值没变不写状态位、不 post guardzone）。
    private static var lastNotifiedBandW: Int = -1
    private static var lastNotifiedBandH: Int = -1

    /// 把右缘带几何（RightEdgeWidth / RightEdgeHeight，已 clamp）写进 notify(3)
    /// 共享内存 bit48-63。三个时机调用：SB 加载完成 / 设置变更通知 / 0.2 秒轮询兜底。
    ///
    /// 为什么 App 侧不再自己读偏好域：Aevon(105) 铁证 —— 抖音（沙盒最严）读不到
    /// com.Aevon 域，App 侧静默落回 fallback 46pt×60%，「屏幕 50% 左右呼出圆盘」。
    /// notify 状态在沙盒 App 里必可读（bit39 圆盘位已验证多年），几何从今天起
    /// 只认它；App 侧读不到一律 fail-closed（只加载、不接管）。
    static func syncBandGeometryToNotify() {
        let w = Int(AevonRightEdge.width.rounded())
        let h = Int(AevonRightEdge.heightPercent.rounded())
        guard w >= 1, h >= 1 else { return }
        guard w != lastNotifiedBandW || h != lastNotifiedBandH else { return }
        AevonNotifySetBand(Double(w), Double(h))
        lastNotifiedBandW = w
        lastNotifiedBandH = h
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
            // V0.2.3（AevonAppYieldV203）：App 侧带内 began → SB 全局通道让路。
            // Aevon(89) 实证：热区与 App 侧识别器竞速时，4 根手指在 App 进程内整段断流
            // （began 之后无 moved / 无取消 / 无抬手），全部发生在 SB 同时接管时。
            // 收到本通知立刻停吞本指（ownsTouch=false，保留 globalTouchID 观察 +
            // global 兜底触发）—— 若 SB 吞是断流真凶，这一步在首帧移动前解除；
            // 若不是，global 兜底照旧，行为不变。非注入 App 不发通知，完全不受影响。
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           nil,
                                           aevonAppEdgeBeganHandler,
                                           "com.aevon.rightedgebegan" as CFString,
                                           nil,
                                           .deliverImmediately)
            // V0.2.6（AevonEdgeFailGateV206）：App 侧判向失败（纵向滚动/向右扫）也回传 ——
            // Aevon(92) 铁证：让路后兜底只看 dx=-30 就呼盘，不知道 App 已判失败，
            // 结果「圆盘弹出 + App 照滚」。收到本通知 1.5s 内 global 兜底闭嘴。
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           nil,
                                           aevonAppEdgeFailHandler,
                                           "com.aevon.rightedgefail" as CFString,
                                           nil,
                                           .deliverImmediately)
            // V0.2.10（AevonAppBlindHoldV210）：App 侧挂载成功 / 回到前台就广播这条 ——
            // SB 收到才认为「这一侧的识别器在」，之前一律按盲期处理（不呼盘）。
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           nil,
                                           aevonAppReadyHandler,
                                           "com.aevon.appready" as CFString,
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
        // V0.2.20（AevonAppGeomNotifyV220）：启动即把右缘带几何发布到共享内存，
        // App 侧（含沙盒最严的抖音）从这条通道读几何，不再各自读偏好域。
        syncBandGeometryToNotify()
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            AevonPrefs.synchronize()
            // V0.0.31（AevonRingPinnedV31）：轮询只管触发区指纹 ——
            // 旧版这里还顺手 AevonRingStore.invalidateCache()，0.2 秒一次跨进程重读
            // 导致圆盘 App 数与排序漂移（Aevon(24)），已删除。列表只在设置页广播时刷新。
            checkTriggerZoneChange()
            // V0.2.10（AevonAppBlindHoldV210）：顺手盯前台 App 换人 —— 换成新 App 的
            // 头几秒里，App 侧的识别器可能还没挂上，那几秒不许呼盘。
            noteForegroundChange()
            // V0.2.20（AevonAppGeomNotifyV220）：几何变更通知万一丢了（设置进程被杀），
            // 0.2 秒轮询兜底同步（内部有变更检测，值没变不写不 post）。
            syncBandGeometryToNotify()
            // V0.2.10（AevonGeomOverlayV210）：触发区 / 接管带的可视化跟着滑条走。
            checkPreviewRequest()
            AevonGeometryOverlay.sync()
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
    private static var panicHintOnceV202 = false
    private static func explainPanicDisabledOnceV119() {
        // V0.2.2（AevonPanicHintOnceV202）的幂等标记仍然保留（历史串），但**提醒本身停了**。
        //
        // V0.2.17（AevonPrefsSlimV217）：`RightEdgeTakeover` / `BandTakeoverFromBegan` 两个
        // 「整指吞」开关随 SB 侧吞摸一起在 0.2.15 下线、0.2.17 从设置页撤掉。
        // 于是这条「上次被三指急救关闭，回设置里可以再打开」的提醒变成了纯粹的误导 ——
        // Aevon(103) 13:08:58.602 就弹了一次，提示用户去开一个已经不存在的开关。
        // 急救的可见反馈改由 `panicReleaseNow` / 第二档的提示条承担（同一根手指、当场可见）。
        _ = panicHintOnceV202
        _ = AevonPrefs.bool("RightEdgePanicOffV119", default: false)
        return
    }

    /// V0.2.10（AevonGeomPreviewLiveV210）：设置页进「细节调整」时写一个时间戳，
    /// 这里看到数值变大就亮一次 —— 用户一进页面就知道两块区域现在在哪。
    private static func checkPreviewRequest() {
        let request = AevonPrefs.double("AevonPreviewReq", default: 0)
        guard request > lastPreviewRequest else { return }
        lastPreviewRequest = request
        AevonGeometryOverlay.preview()
    }

    /// 指纹变了就重排触发条（幂等；没变什么都不做）
    static func checkTriggerZoneChange() {        let signature = AevonTriggerZone.signature()
        if signature != zoneSignature {
            let isFirstZone = zoneSignature.isEmpty
            zoneSignature = signature
            refreshLayoutIfNeeded(logChange: true)
            syncGuardConfig()
            // V0.2.10（AevonGeomPreviewLiveV210）：用户刚拖了热区滑条 → 立刻把两块
            // 矩形亮出来 3 秒。启动时第一次建指纹不算「用户改动」，不弹（否则每次
            // 注销都会在屏幕上闪一块色板）。
            if !isFirstZone {
                AevonGeometryOverlay.preview()
            }
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
                AevonGeometryOverlay.preview()
                AevonLog.info("[右缘] 配置已更新：\(AevonRightEdge.summary(in: UIScreen.main.bounds))，可视化=\(AevonRightEdge.showBand ? "开" : "关")（AevonBandIndicatorV116 AevonGeomPreviewLiveV210）")
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
        let enabled = AevonPrefs.bool("Enabled", default: true)
            && AevonPrefs.bool("EdgeGestureEnabled", default: true)
        AevonNotifySetZone(Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), enabled ? 1 : 0)
    }

    private static var zoneTimer: Timer?
    private static var zoneSignature = ""
    /// V0.2.10（AevonGeomPreviewLiveV210）：设置页「请亮一下」的一次性请求戳，
    /// 数值变大就 preview 一次（进页面写时间戳，比 Darwin 通知多一个「是谁」的语义）。
    private static var lastPreviewRequest: Double = 0
    /// V0.1.16：右缘带（宽度 / 高度 / 可视化开关）的指纹，用于 0.2 秒轮询里发现改动后重画
    private static var rightEdgeSignature = ""
    private static var prefsObserverInstalled = false

    /// V0.2.15（AevonDeskStripHitV215）：真正的「桌面裸态」——没有全屏 App、也没有浮窗。
    ///
    /// 只在这里允许手势条自己接触摸。判据沿用 0.2.9 定下的那一对：
    ///   · `openBundleID != nil` → 有浮窗（浮窗里跑的是真实 App 场景，右边缘不是屏幕右边缘）；
    ///   · `mountedInAppScene`   → 容器挂在 App 画面容器上（全屏 App 或浮窗都算）。
    /// 两者都为假才是「桌面上什么都没有」。
    static var isPureDesktop: Bool {
        if AevonWindowManager.openBundleID != nil { return false }
        return !AevonEntryHost.mountedInAppScene
    }

    /// 统一触发入口（手势条 / 窗口层兜底 / 识别器都走这里），带 0.6 秒去重。
    /// `source` 决定后续触摸流转发给圆盘时走哪条通道（圆盘只认最先来的那条）。
    static func attemptTrigger(_ reason: String, source: String) {
        let now = CACurrentMediaTime()
        // V0.2.15（AevonNoSBSwallowV215）：`global` 这条来源整体下线。
        //
        // Aevon(101) 的账：全屏 App 里「圆盘出来、页面也跟着动」由 App 侧识别器解决，
        // SB 侧无论吞不吞都改变不了 App 那一份（backboardd 双投）；而 SB 侧吞的代价是
        // 桌面翻页 / Dock / 图标一起摸不动 —— 12:31:18~12:31:30 那 12 秒整机单指全死，
        // 只有三指能穿过去（三指事件 swallowCount < active 不吞），就是这条留下的。
        //
        // 现在 SB 侧呼盘只剩两条合法入口：
        //   · `strip`  —— 桌面手势条自己被命中（它拿到了触摸，桌面本来就收不到）；
        //   · `appedge`/`systemgesture` —— App 进程内识别器成立后通知过来。
        if source == "global" {
            if now - globalGateLoggedAt > 2.0 {
                globalGateLoggedAt = now
                AevonLog.info("[右缘] 全局通道呼盘已下线（本版起 SB 侧不再吞摸，桌面翻页/系统手势恢复；桌面呼盘请用右侧手势条）（AevonNoSBSwallowV215）")
            }
            return
        }
        // V0.2.6（AevonEdgeFailGateV206）：App 侧刚判过「失败」（纵向滚动/向右扫）→
        // global 兜底在这根手指上必须闭嘴。Aevon(92) 铁证：16 次让路里 8 次兜底呼盘
        // 发生在 App 已判失败之后（兜底只看 dx=-30，不看纵向），App 那份照滚 =
        // 用户看到的「呼出圆盘的同时全屏 App 也被操作」。只拦 global 兜底，
        // App 自己判成功走的 appedge 不受影响。
        if source == "global", now < appEdgeFailUntil {
            AevonLog.info("[右缘] App 侧已判失败（纵向/向右）→ 全局兜底不触发（AevonEdgeFailGateV206）")
            return
        }
        // V0.2.8（AevonSelectionCoolV208）：刚选中开窗（1.5 秒内）→ global 兜底闭嘴。
        // Aevon(94) 21:53:45 实证：选中威锋 0.65 秒后同一根手指的移动又呼了一次盘，
        // 圆盘盖在正在打开的浮窗上。appedge 主通道不受影响。
        if source == "global", now < selectionCoolUntil {
            AevonLog.info("[右缘] 刚选中开窗（1.5s 冷静期）→ 全局兜底不触发（AevonSelectionCoolV208）")
            return
        }
        // V0.2.10（AevonAppBlindHoldV210）：App 侧不在场（刚切到这台 App、识别器还没挂上）
        // → 这次不呼盘。
        //
        // 为什么必须放弃而不是「先开出来再说」：Aevon(96) 09:49:09 抖音那一次，SB 判向
        // 成立照常呼盘，但 App 侧从头到尾没发过 began —— App 手里那份触摸从未被取消，
        // 用户滑动圆盘时抖音跟着滚。事后没有任何手段补（SB 丢事件只丢自己那份）。
        // 代价明说：刚启动 / 刚切过来的 App 上，头一两秒划右缘可能不弹盘，再划一次就有。
        if source == "global", appSideIsBlind() {
            if now - blindHoldLoggedAt > 1.0 {
                blindHoldLoggedAt = now
                let spent = CACurrentMediaTime() - foregroundChangedAt
                AevonLog.info("[右缘] App 侧盲期：前台 \(AevonEntryHost.currentForegroundBundleID) 切上来 \(String(format: "%.1f", spent))s 还没广播 appready（识别器未挂上）→ 本次不呼盘，避免圆盘与 App 抢同一根手指（AevonAppBlindHoldV210 AevonAppReadyV210）")
            }
            return
        }
        guard now - lastTriggerAt > 0.6 else { return }
        guard !AevonRingMenu.isPresented else { return }
        lastTriggerAt = now
        // V0.2.7（AevonAppBlindDiagV207）：global 兜底触发且 App 侧长时间无起手痕迹 →
        // 大概率该 App 里识别器还没挂上（冷启动重试窗口）或没注入。钉到日志里好归因。
        if source == "global", now - lastYieldAt > 2.0,
           !AevonEntryHost.currentForegroundBundleID.isEmpty {
            AevonLog.info("[右缘] 诊断：前台 App=\(AevonEntryHost.currentForegroundBundleID)，本指无 App 侧起手痕迹（>2s 无让路）→ App 侧可能未挂载/未注入（AevonAppBlindDiagV207）")
        }
        appEdgePointerAdopted = false
        AevonLog.info("[边缘] 触发（\(reason)，来源 \(source)），呼出圆盘")
        // V0.1.17：圆盘要起来了，把右缘提示条收掉（别叠在圆盘上），并记下展开时刻给死手开关用。
        AevonBandHint.hideNow()
        ringOpenedAt = now
        presentRing(source: source)
    }

    /// V0.2.8（AevonSelectionCoolV208）：圆盘选中开窗 → 记 1.5 秒冷静期，
    /// 期间 global 兜底不再呼盘（圆盘别盖在正在打开的浮窗上）。由 AevonRingMenu.activate 调。
    static func noteSelectionCooldown() {
        selectionCoolUntil = CACurrentMediaTime() + 1.5
    }

    /// V0.2.3（AevonAppYieldV203）：App 侧已在带内扣住本指 → 全局通道停吞让路。
    ///
    /// Aevon(89) 铁证：热区与 App 侧识别器同抢一根手指时，4 根手指在 App 进程内
    /// began 之后整段断流（无 moved / 无取消 / 无抬手），全部伴随 SB 热区接管。
    /// 静态分析确认 ownsTouch 只吞 SB 份（sendEvent 钩子层），App 份断流真凶
    /// 未钉死 —— 但让路是零风险试探：停吞后保留 globalTouchID 观察，
    /// global 兜底触发照旧（App 侧若没判出来，-33pt 左滑照样呼盘）；
    /// 非注入 App 不发通知，此函数根本不会被调。
    static func yieldGlobalChannelToAppSide() {
        guard !AevonRingMenu.isPresented else { return }
        guard globalTouchID != 0 else { return }
        // V0.2.14（AevonSwallowOnRingV214）：本版热区落指已经不再吞，
        // 所以「停吞」这一步多数时候无事可做。但 lastYieldAt 是盲区诊断的依据
        // （-2s 无让路 = App 侧可能没挂上），必须先记时刻，再决定要不要打日志。
        lastYieldAt = CACurrentMediaTime()
        guard ownsTouch else { return }
        ownsTouch = false
        AevonLog.info("[右缘] App 侧已在带内起手 → 全局通道让路（停吞本指，保留观察与 global 兜底触发）（AevonAppYieldV203）")
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
                // V0.2.15（AevonDeskStripHitV215）：来源统一成 "strip" ——
                // 桌面手势条从本版起真的能被命中，探针与条子会在同一根手指上
                // 各收到一次事件。两处若用不同 source，圆盘只认先来的那个，
                // 另一条喂进去的移动会被丢掉 → 圆盘不动 / 松手选不中。
                case .began: ring.beginRemoteTracking(at: point, source: "strip")
                case .moved: ring.remoteMoved(to: point, source: "strip")
                case .ended: ring.remoteEnded(at: point, source: "strip")
                case .cancelled: ring.remoteCancelled(source: "strip")
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
                    attemptTrigger("窗口层左滑 \(Int(dx))pt", source: "strip")
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

    // MARK: - V0.2.12 接管状态自愈（AevonSwallowSelfHealV212）
    //
    // Aevon(98) 事故复盘：App 侧判向成立 → SB 接管本指 → 圆盘没选中自动收起 →
    // **整台设备只剩点击**：顶部下拉控制中心、底部上滑进后台、锁屏上滑解锁全部失效。
    //
    // 结构原因只有一个：`ownsTouch` / `globalTouchID` 这对状态一旦漏掉一次清空，
    // `shouldSwallowGlobalTouch` 就会继续对「那根手指」的每一帧返回 true。
    // 而 `touchID` 是 `UITouch` 指针，UIKit 会**池化复用**：手指抬起后同一个对象
    // 被派给下一根手指 → 那一根的 began / moved / ended 全被丢弃 →
    // SpringBoard 这一份触摸整体消失。系统手势全在 SpringBoard 里处理，于是全废；
    // 而 backboardd 直投 App 进程的那一份没被碰过，所以**点击仍然可用** ——
    // 这正是用户描述的「屏幕只能点击」。
    //
    // 为什么以前的三道闸都没拦住：
    //   ① 抬手清状态：抬手帧被我们自己的 hook 先询问后上报，`.ended` 分支里
    //      任何一条 `return`（touchID 不匹配 / 提前 return）都会跳过清理；
    //   ② 死手开关：`swallowDeadline` 在每次 moved 里被续期（+4 秒），
    //      用户一直试图滑动 → 一直续期 → 永远不到期；
    //   ③ 急救：只有用户自己三指按下才生效（日志里 678 / 683 两次都是这么救回来的）。
    //
    // 所以这一版把「不可能卡死」做成结构保证，而不是再补一条事件路径：
    //   · 吞咽的唯一正当性 = **圆盘正展开**。圆盘不在场，这根手指就没有任何理由被吞；
    //   · 圆盘在场时也有**绝对**上限（不随 moved 续期）。
    // 判据放在 `shouldSwallowGlobalTouch` 入口 —— 它是全系统每一根手指每一帧的必经之路，
    // 比任何回调、任何定时器都更早、更全。
    /// 「收归本指」的起始时刻（0 = 当前没有接管）
    private static var globalOwnedAt: CFTimeInterval = 0
    /// 这个起始时刻对应的是哪一根手指（touchID 变化 = 新接管，必须重新记时）
    private static var globalOwnedForTouch: UInt = 0
    /// 自愈日志限频（1 秒一行，避免逐帧刷屏把日志刷爆）
    private static var lastHealLogAt: CFTimeInterval = 0
    /// 圆盘在场时单根手指被吞的绝对上限（秒）。滑动**不续期**。
    /// 12 秒：正常呼盘后在盘上找图标 / 旋转很少超过这个量级（圆盘本身 20 秒自动收）；
    /// 一旦超过，宁可让 App 收到后续触摸（最坏是页面跟着动一下），也绝不继续吞。
    private static let globalOwnHardLimit: CFTimeInterval = 12
    /// 圆盘不在场时，接管最多再保留多久（秒）。这段窗口是留给「began 即接管 → 判向 → 呼盘」
    /// 的：判向在 60ms 量级完成，1.5 秒是极宽裕的上限；超过就说明这次接管已经没有去处。
    private static let healIdleWindow: CFTimeInterval = 1.5

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

    /// V0.2.7（AevonEdgeAdoptV207）：appedge 呼盘后是否已收养过「SB 侧没登记的手指」。
    /// 起手点在 App 侧 46pt 带内但不在 SB 18pt 热区（且 SB 接管带开关关闭）时，
    /// SB 从未登记这根手指的 globalTouchID —— 呼盘后 moved/ended 全被
    /// `guard touchID == globalTouchID` 挡掉，圆盘收不到任何事件 = 「圆盘卡住」。
    /// 收养 = 把呼盘后第一根移动的手指登记为 globalTouchID 继续喂圆盘。每次呼盘重置。
    private static var appEdgePointerAdopted = false
    /// V0.2.7（AevonAppBlindDiagV207）：最近一次 App 侧让路的时刻。
    /// global 兜底触发时若远超此时刻（且前台有 App），说明 App 侧没收到起手 —— 打诊断行。
    private static var lastYieldAt: CFTimeInterval = 0

    /// V0.2.8（AevonDeskZoneObserveV208）：桌面热区观察候选（**只观察，不吞**）。
    ///
    /// Aevon(94) 用户实证：桌面右下角 18×260 热区「按下即吞」导致「桌面左右滑、点击失灵」
    /// —— 翻页起手位与 dock 右端正好被盖住，手指一落下去桌面连 began 都收不到。
    /// 桌面（非 App 前台）改为只登记观察：轻点 / 纵向滑动整段放行；
    /// 看清向左横扫 ≥30pt 才呼盘（呼盘后由收养路径喂盘，桌面页面会跟走约 30pt，
    /// 用户 2026-10-25 拍板接受）。App 前台热区维持按下即接管（12/12 已验证路径，不动）。
    private static var deskZoneTouchID: UInt = 0
    private static var deskZoneStart: CGPoint = .zero
    private static var deskZoneFired = false
    /// V0.2.8（AevonDeskZoneObserveV208）：桌面呼盘后被收养的那根手指 ——
    /// **吞摸豁免**。began 与前几帧移动已经给了桌面（翻页 pan 已持住这根 touch），
    /// 后续帧绝不能再吞，否则桌面翻页卡在半路（began 后断流同款）。
    /// 只观察喂盘，不拦截；抬手/取消/圆盘收起时清零。
    private static var deskZoneAdoptedTouchID: UInt = 0

    /// V0.2.8（AevonSelectionCoolV208）：选中开窗后的冷静期。
    /// Aevon(94) 21:53:45 实证：选中威锋开浮窗后 0.65 秒，同一根手指的后续移动
    /// 又被 global 兜底呼了一次盘，圆盘盖在正在打开的浮窗上。
    private static var selectionCoolUntil: CFTimeInterval = 0

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
    /// 圆盘安全网（V0.2.18 / AevonRingCloseOnLiftV218 起从「展开超过 20 秒」改成
    /// 「**连续 30 秒没有任何指针事件**」）。
    ///
    /// 用户 Aevon(104) 的规则只有一条：手指还在屏上就不收。旧判据按「展开时长」算，
    /// 慢慢找图标 / 慢慢转 20 秒就会被收掉 —— 那正好是规则的例外。
    /// 现在按「静默时长」算：只要还有一只手指在动，它永远不到期；
    /// 到了期就说明要么 ended 丢了、要么人早就走了，这时候收掉是必要的卫生。
    private static let ringOpenLimit: CFTimeInterval = 30

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
        globalOwnedAt = 0
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
        appEdgePointerAdopted = false
        deskZoneTouchID = 0
        deskZoneStart = .zero
        deskZoneAdoptedTouchID = 0
        deskZoneFired = false
        if hadState {
            AevonLog.warn("[急救] 已释放接管状态（\(reason)）（AevonDeadManV117）")
            // V0.2.12（AevonReleaseAlsoClosesRingV212）：释放接管必须**连圆盘一起收掉**。
            //
            // Aevon(98) 事故里，死手开关走「接管超期」这条路释放了状态，但圆盘这个
            // 全屏视图还留在屏上 —— 它自己就是一层整屏吞摸（isUserInteractionEnabled=true）。
            // 释放接管却留着圆盘，等于「左手还了手指，右手又扣回去」。
            // dismiss() 是幂等的（current 已 nil / isDismissing 时直接 return），
            // 并且它内部会走 ringDidDismiss() → post ringclose 通知 App 侧一起收尾。
            AevonRingMenu.dismissCurrent()
            // 再补一次广播：dismiss() 里的 ringDidDismiss() 万一被 guard 挡掉（current 已空），
            // App 侧就永远等不到「圆盘收起」。这条是幂等的，重复发没有副作用。
            postRingState("com.aevon.ringclose")
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
        AevonPanicHint.show("三指急救：已释放全部接管。", duration: 4.0)
        AevonLog.warn("[急救] 三指按住 2 秒 → 已释放全部接管（两个整指吞开关 0.2.15 起已下线、0.2.17 从设置页撤掉，现在只做释放，功能本身不受影响）（AevonPanicThreeFingerV117 AevonPanicHoldV119 AevonPanicHintV119 AevonPrefsSlimV217）")
    }

    /// 死手开关：0.2 秒一次，只在「状态明显泄漏」时动手。
    static func enforceDeadManSwitch() {
        let now = CACurrentMediaTime()
        // V0.2.18（AevonRingCloseOnLiftV218）：**手指还在屏上，定时器一律不替圆盘做决定。**
        //
        // 下面三条都是「超时强收」。它们存在的理由是「接管状态泄漏了，必须兜底」，
        // 而不是「圆盘开太久要收」。手指在场时泄漏根本不存在 —— 抬手一定会走
        // `handlePointerEnded`，圆盘收起一定会走 `ringDidDismiss()` 把状态清干净。
        // 所以：手指在场 → 跳过这三档；手指离场（ended / cancelled）→ 恢复原样。
        // 万一 ended 真的丢了，`isFingerDown` 会一直是 true，兜底由上面那条
        // 「连续 30 秒没有任何指针事件」承担。
        let ringHoldsFinger = AevonRingMenu.presented?.isFingerDown == true
        if !ringHoldsFinger, ownsTouch, swallowDeadline > 0, now > swallowDeadline + deadManGrace {
            releaseAllTakeover("接管超期未释放")
        }
        // V0.2.12（AevonOwnHardDeadlineV212）：**绝对**上限，不随 moved 续期。
        //
        // 上面那条 `swallowDeadline` 判据形同虚设：moved 每次都给 swallowDeadline
        // 续 +4 秒（那是「按住不动」的兜底，不是「一直在滑」的兜底）。
        // Aevon(98) 里用户正是「一直在试图滑动」—— 每一次尝试都在续期，
        // 于是死手开关永远判不到期，最后靠三指急救才救回来。
        // 这条按「收归本指」的起始时刻算，8 秒到点无条件归还。
        if !ringHoldsFinger, (ownsTouch || globalTouchID != 0), globalOwnedAt > 0,
           now - globalOwnedAt > globalOwnHardLimit {
            releaseAllTakeover("收归超过 \(Int(globalOwnHardLimit)) 秒未归还")
        }
        if !ringHoldsFinger, rightEdgeTouchID != 0, swallowDeadline > 0, now > swallowDeadline + deadManGrace {
            releaseAllTakeover("右缘接管超期")
        }
        if let ring = AevonRingMenu.presented, ringOpenedAt > 0 {
            // 两个时长取小：既要「展开够久」，也要「确实没有任何指针事件」。
            let silentFor = min(now - ringOpenedAt, ring.pointerIdleSeconds)
            if silentFor > ringOpenLimit {
                ringOpenedAt = 0
                AevonLog.warn("[急救] 圆盘连续 \(Int(ringOpenLimit)) 秒没有任何指针事件（ended 可能丢了）→ 强制收起（AevonDeadManV117 AevonRingCloseOnLiftV218）")
                AevonRingMenu.dismissCurrent()
                releaseAllTakeover("圆盘静默超期")
            }
        }
        // V0.1.19（AevonPanicHoldV119）：三指按住的第二、三档升级。
        // 第一档（释放接管）已经在 began 里当场做了，这里只负责「超时升级」。
        if panicHoldSince > 0 {
            let held = now - panicHoldSince
            if held >= panicHoldHintAfter, !panicHoldReleased {
                panicHoldReleased = true
                AevonPanicHint.show("已释放接管。", duration: 2.5)
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
        guard AevonPrefs.bool("Enabled", default: true) else { return false }
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
        guard AevonPrefs.bool("Enabled", default: true) else { return }
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
            //   · 原指针已抬起（0.2.17 起抬手即收盘，这条只剩「收盘动画那 0.18 秒」与
            //     通道漏发 ended 的自愈两种情形）→ 新触摸接管为当前指针，
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
            // V0.2.9（AevonFloatStandDownV209）：**浮窗开着时一律按「桌面」处理**。
            //
            // 根因（Aevon(95) 主诉「桌面和悬浮内的 APP 都无法滑动，只能点击」）：
            // `mountedInAppScene` 只回答「容器挂在 App 画面容器上了吗」。浮窗也是把 App 场景
            // 呈现出来，容器同样会被搬到 `SBDeviceApplicationSceneViewController.view` 上 ——
            // 于是「桌面上开着一个浮窗」被误判成「App 前台」：
            //   · 热区走 `接管=是（热区最高优先级）` 整指吞掉；
            //   · 右缘 46pt 接管带（要求 appForeground=true）跟着一起生效；
            //   两者一开，浮窗里的内容和浮窗底下的桌面在那两个区域全瞎：
            //   点击、滑动一律收不到 began。
            // 判据换成 `AevonWindowManager.openBundleID`：有浮窗 = 没有全屏 App = 桌面模式。
            // （从桌面点图标把 App 全屏打开时浮窗会自动关，所以「无浮窗」等价于「真全屏 App」。）
            let floatUp = AevonWindowManager.openBundleID != nil
            let appForeground = AevonEntryHost.mountedInAppScene && !floatUp
            // V0.2.9（AevonFloatPassV209）：落在浮窗上的触摸**整个**交回浮窗。
            //
            // 浮窗里跑的是真实 App 场景，它自己最清楚要不要滚；边缘手势在浮窗里没有意义
            // （浮窗的右边缘不是屏幕右边缘）。所以这里既不接管也不吞，连「观察」都不做 ——
            // 只登记一个位置给日志用，然后立刻返回。
            if floatUp, AevonEntryHost.pointHitsFloatingWindow(at: point) {
                lastTouchPoint = point
                let nowFloat = CACurrentMediaTime()
                if nowFloat - globalLastLogAt > 2.0 {
                    globalLastLogAt = nowFloat
                    AevonLog.info("[边缘] 触摸落在浮窗上 (x=\(Int(point.x)), y=\(Int(point.y))) → 整个交回浮窗（不接管、不吞、不判向）（AevonFloatPassV209 AevonFloatStandDownV209）")
                }
                return
            }
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
                    // V0.2.8（AevonDeskZoneObserveV208）：桌面（非 App 前台）热区改为
                    // 「观察 + 延迟呼盘」—— Aevon(94) 实证桌面右下角按下即吞导致
                    // 「桌面左右滑、点击失灵」。只登记不吞：轻点/纵向整段放行，
                    // 左扫 ≥30pt 才呼盘（moved 里判向）。App 前台从 V0.2.14 起同款观察（见下面的说明）。
                    if !appForeground {
                        deskZoneTouchID = touchID
                        deskZoneStart = point
                        deskZoneFired = false
                        lastTouchPoint = point
                        let nowObserve = CACurrentMediaTime()
                        if nowObserve - globalLastLogAt > 2.0 {
                            globalLastLogAt = nowObserve
                            AevonLog.info("[边缘] 全局通道收到热区触摸 (x=\(Int(point.x)), y=\(Int(point.y))，\(AevonTriggerZone.summary(in: screen))，接管=否（桌面·观察中，左扫≥30pt 才呼盘，轻点/纵向全放行）（AevonGlobalTouchV23 AevonZonePriorityV101 AevonTakeoverBandV103 AevonDeskZoneObserveV208）")
                        }
                        return
                    }
                    // V0.2.14（AevonSwallowOnRingV214）：**热区不再「按下即接管」**。
                    //
                    // 这一条是本版对 Aevon(100) 的正面修正，理由是一条已经被数字钉死的账：
                    //   · `ownsTouch` 只让 `UIApplication -sendEvent:` 不往下投 ——
                    //     也就是**只丢得掉 SpringBoard 自己那一份**。前台 App 那份由
                    //     backboardd 直投，从来没被这根手指碰过（0.2.0 已定论）。
                    //     所以「按下即接管」对「App 跟着滚」的收益是 **0**；
                    //   · 而热区矩形（x 412~430 · y 664~932）正好压在**底部系统手势区**上。
                    //     底部上滑回桌面 / 锁屏上滑解锁 / 顶部下拉，全都是 SpringBoard
                    //     自己在 `UISystemGestureView` 上识别的 —— 被我们丢掉的正是它们。
                    //     Aevon(100) 里 14 次热区落指中 14 次「接管=是」，每一次都在那一瞬间
                    //     把这几条系统手势挡在门外。
                    //
                    // 收益为 0、代价是整个系统手势，所以本版把「吞」从**落指**推迟到**呼盘**：
                    // 平时只登记观察（轻点 / 纵向 / 向右一律整段放行给 App 和系统），
                    // 看清左扫 ≥30pt 呼出圆盘之后才开吞 —— 圆盘开着时本来就整屏归圆盘。
                    bandHoldTouchID = 0
                    bandHoldDeadline = 0
                    globalTouchID = touchID
                    globalStart = point
                    globalFired = false
                    lastTouchPoint = point
                    lastTouchAt = CACurrentMediaTime()
                    ownsTouch = false
                    swallowDeadline = 0
                    let now = CACurrentMediaTime()
                    if now - globalLastLogAt > 2.0 {
                        globalLastLogAt = now
                        // 历史文案（0.2.12 及以前是「接管=是（热区最高优先级）」）保留在这里，
                        // CI 的 V0.2.8 断言只加不改；含义已翻转为「只观察、呼盘后才吞」。
                        AevonLog.info("[边缘] 全局通道收到热区触摸 (x=\(Int(point.x)), y=\(Int(point.y))，\(AevonTriggerZone.summary(in: screen))，接管=否（热区·观察中，左扫≥30pt 才呼盘；旧版此处为「接管=是（热区最高优先级）」，本版已改为不吞，把底部/顶部系统手势让出来）（AevonGlobalTouchV23 AevonZonePriorityV101 AevonTakeoverBandV103 AevonSwallowOnRingV214）")
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
                        AevonLog.info("[右缘] 起手 (\(Int(point.x)),\(Int(point.y))) 距右缘 \(gap)pt → 归口=右缘接管带·在带内·按下即接管（App 连 began 都收不到；App前台=\(appForeground)；\(AevonRightEdge.summary(in: screen))），第 \(rightEdgeCount) 次（AevonRightEdgeTakeoverV115 AevonBandTakeoverBeganV113 AevonRightEdgeShowBandV116 AevonRightEdgeDefaultV118）")
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
            // V0.2.8（AevonDeskZoneObserveV208）：桌面热区观察候选的判向。
            // 左扫成立 → 呼盘后**不 return**，落到下面的收养块把这根手指喂给圆盘
            // （呼盘那一刻圆盘刚展开，收养块在本事件内即可接管驱动）。
            // 未成立 → 继续往下走；各 guard 会自然放行（我们没登记 globalTouchID）。
            if touchID == deskZoneTouchID {
                let zdx = point.x - deskZoneStart.x
                let zdy = point.y - deskZoneStart.y
                // V0.2.9（AevonDeskEdgePullV209）：桌面呼盘收紧成「贴边横拉」，把翻页让出来。
                //
                // 桌面翻页本身就是「从右下角向左滑」—— 和呼盘是同一个手势。
                // 0.2.8 只把「按下即吞」去掉、判据仍是「左扫 ≥30pt」，结果桌面能滑了，
                // 但每次翻页都会顺手弹出圆盘。这里加两把尺子，让两者分得开：
                //   · 起手必须**贴边**（距右缘 ≤12pt）：翻页是从页面中间起手的；
                //   · 必须**很横**（|dx| ≥ |dy|×1.3）：拇指翻页天然带弧线，横竖比压不到 1.3；
                //     而 Aevon(95) 里你那两次真实呼盘是 dx=-36/dy=-15、dx=-31/dy=-21（1.48），
                //     所以尺子不能比 1.3 更严，否则你自己的手势会被判成翻页。
                // 判据不成立时我们什么都不做 —— 这根手指照旧属于桌面（本来就没吞）。
                let startGap = screen.width - deskZoneStart.x
                let edgePull = startGap <= 12
                let stronglyHorizontal = abs(zdx) >= abs(zdy) * 1.3
                if !deskZoneFired, zdx <= -AevonEdgeStripView.swipeDistance, stronglyHorizontal {
                    if !edgePull {
                        deskZoneFired = true     // 只报一次，避免逐帧刷屏
                        AevonLog.info("[右缘] 桌面左扫 dx=\(Int(zdx)) dy=\(Int(zdy)) 但起手距右缘 \(Int(startGap))pt > 12pt → 判定为桌面翻页，不呼盘（AevonDeskEdgePullV209）")
                    } else {
                        deskZoneFired = true
                        deskZoneAdoptedTouchID = touchID   // 吞摸豁免：后续帧照常给桌面（AevonDeskZoneObserveV208）
                        lastTouchPoint = point
                        AevonLog.info("[右缘] 桌面贴边横拉成立 dx=\(Int(zdx)) dy=\(Int(zdy)) 距右缘 \(Int(startGap))pt → 呼出圆盘（桌面整段放行，页面会跟走）（AevonDeskZoneObserveV208 AevonDeskEdgePullV209）")
                        attemptTrigger("桌面热区左滑 \(Int(zdx))pt", source: "global")
                    }
                }
            }
            // V0.2.7（AevonEdgeAdoptV207）：圆盘展开但这根手指 SB 侧没登记过（起手在
            // App 侧 46pt 带内、不在 18pt 热区，且 SB 接管带开关关闭时正是如此）——
            // 呼盘后它的 moved/ended 全被下面的 guard 挡掉，圆盘收不到任何事件 =
            // Aevon(93) 用户反馈「圆盘卡住不动，要二次点击才能关」。收养它：登记为
            // globalTouchID 继续喂圆盘。只登记观察，**不开 ownsTouch**（不吞 App 份 ——
            // 判向成立的那根已被 App 侧合法取消；万一多指误收养也不影响 App 触摸）。
            if touchID != globalTouchID, AevonRingMenu.isPresented, ringSource == "global",
               !appEdgePointerAdopted, touchID != ringExtraTouchID {
                appEdgePointerAdopted = true
                globalTouchID = touchID
                globalStart = point
                globalFired = true          // 收养只喂圆盘，绝不再走触发逻辑
                lastTouchPoint = point
                AevonLog.info("[右缘] 收养手指（这根未经 SB 侧登记，只登记喂圆盘、不吞）→ 继续喂圆盘（AevonEdgeAdoptV207）")
            }
            guard touchID == globalTouchID else { return }
            lastTouchPoint = point
            lastTouchAt = CACurrentMediaTime()
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
            // V0.2.12（AevonEndAlwaysCleanV212）：抬手**必然**归还，不给任何分支留漏口。
            //
            // Aevon(98) 事故的结构性缺口：这条 case 里有七八个 `return`（桌面候选、
            // 额外手指、接管带候选、float、`guard touchID == globalTouchID`…），
            // 只要抬手那一帧的 touchID 和登记的 globalTouchID 对不上（多指、指针复用、
            // 圆盘已被别处收起），清理整段就被跳过 —— 而 hook 那边这一帧已经
            // 「先询问后上报」吞掉了，于是这根手指永远留在 ownsTouch 里。
            // 用 defer 把清理挂在 case 入口：不管从哪一行 return，都一定执行。
            let endedHeldGlobal = (globalTouchID != 0 && touchID == globalTouchID)
            defer {
                if endedHeldGlobal {
                    globalTouchID = 0
                    globalFired = false
                    ownsTouch = false
                    swallowDeadline = 0
                    globalOwnedAt = 0
                }
            }
            // V0.2.8（AevonDeskZoneObserveV208）：桌面热区观察候选抬手 —— 只清状态。
            // 未呼盘（轻点/纵向）→ 整段已放行给桌面，打一行收尾日志后 return；
            // 已呼盘（左扫成立且被收养）→ 绝不 return，让下面的 globalTouchID 清理
            // 照常把 remoteEnded 送达圆盘（否则「松手收起」永远不来）。
            if touchID == deskZoneTouchID {
                let fired = deskZoneFired
                if !fired {
                    let zdx = point.x - deskZoneStart.x
                    let zdy = point.y - deskZoneStart.y
                    AevonLog.info("[边缘] 桌面热区抬手：位移 dx=\(Int(zdx)) dy=\(Int(zdy)) 未达左扫 → 整段放行桌面（AevonDeskZoneObserveV208）")
                }
                deskZoneTouchID = 0
                deskZoneStart = .zero
                deskZoneAdoptedTouchID = 0
                deskZoneFired = false
                if !fired { return }
            }
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
            // V0.2.7（AevonEdgeAdoptV207）：同 moved —— 未登记的手指在圆盘展开期间抬手，
            // 也要收养后送达 remoteEnded，否则「松手未选中」永远不来，圆盘留在屏上。
            if touchID != globalTouchID, AevonRingMenu.isPresented, ringSource == "global",
               !appEdgePointerAdopted, touchID != ringExtraTouchID {
                appEdgePointerAdopted = true
                globalTouchID = touchID
                globalFired = true
                lastTouchPoint = point
                AevonLog.info("[右缘] 收养手指（抬手）→ 圆盘收起（AevonEdgeAdoptV207）")
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
            // V0.2.12（AevonEndAlwaysCleanV212）：同 ended —— 被系统取消同样是终态，
            // 这一根手指必须归还。理由见上面 ended 分支的注释（漏一个 return 就是整屏卡死）。
            let cancelledHeldGlobal = (globalTouchID != 0 && touchID == globalTouchID)
            defer {
                if cancelledHeldGlobal {
                    globalTouchID = 0
                    globalFired = false
                    ownsTouch = false
                    swallowDeadline = 0
                    globalOwnedAt = 0
                }
            }
            // V0.2.8（AevonDeskZoneObserveV208）：同 ended，桌面热区观察候选只清状态；
            // 已呼盘被收养的照常落到下面 remoteCancelled。
            if touchID == deskZoneTouchID {
                deskZoneTouchID = 0
                deskZoneStart = .zero
                deskZoneAdoptedTouchID = 0
                if !deskZoneFired { return }
                deskZoneFired = false
            }
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
        // V0.2.6（AevonEdgePointerUnifyV206）：appedge 呼盘后，这根手指的后续移动
        // 由**全局通道**以 source:"global" 持续喂给圆盘（右缘让路保留了观察）。
        // 指针 source 必须与喂入方一致，否则圆盘收不到任何移动/抬手 ——
        // 只能抬手后二次点选图标（Aevon(92) 用户反馈「需要抬手后二级选中」）。
        // 统一成 "global" 后：手指继续拖 → 圆盘跟随/悬停高亮；松手在图标上 → 直接开窗。
        let pointerSource = (source == "appedge") ? "global" : source
        AevonRingMenu.presented?.beginRemoteTracking(at: lastTouchPoint, source: pointerSource)

        // V0.0.24：全局通道唤起时，这根手指的事件同时也被 App 收着（用户 Aevon(17) 反馈
        // 「滑圆盘时前台 App 跟着动」）。这里登记接管，`AevonTouchHook.m` 会在
        // sendEvent 里把这条 touch 丢掉，不再投递给 App。
        // V0.2.7（AevonEdgeAdoptV207）：appedge 也统一成 "global" —— Aevon(93) 铁证：
        // ringSource=="appedge" 时，moved 续期（1419）、吞事件判定（1796/1807）全部不生效，
        // 且「已接管」日志只在 source=="global" 打 —— appedge 呼盘的圆盘看起来「卡住不动」。
        ringSource = "global"
        swallowDeadline = CACurrentMediaTime() + swallowLimit
        // V0.2.14（AevonSwallowOnRingV214）：**吞从「落指」推迟到「呼盘」**。
        //
        // 热区 began 已经不再设 ownsTouch（见热区分支的注释：收益为 0、代价是整个系统手势）。
        // 但圆盘张开之后仍然需要吞 —— 此时用户是在转盘、选图标，任何 SB 侧的其余手势
        // 都不该被触发。所以在这里补上：只要呼盘那根手指还活着（0.6 秒内有过事件），
        // 就把它收归本通道，直到抬手（ended/cancelled 的 defer 会清干净）。
        //
        // 0.6 秒的时限是必需的：`globalTouchID` 是一个 UITouch 指针，系统会复用。
        // 没有时限的话，圆盘刚开时若那根手指已经抬起，吞会落到下一根完全无关的新手指上。
        let nowForSwallow = CACurrentMediaTime()
        // V0.2.15（AevonNoSBSwallowV215）：吞摸下线后这里不再登记接管。
        // 登记了也没人执行（`shouldSwallowGlobalTouch` 已经恒 false），
        // 反而会让自愈巡检每次多打一条「接管状态未正常归还」的假告警。
        if AevonPrefs.bool("SBSwallow", default: false),
           globalTouchID != 0, nowForSwallow - lastTouchAt < 0.6 {
            ownsTouch = true
            globalOwnedForTouch = globalTouchID
            globalOwnedAt = nowForSwallow
        }
        // V0.0.29：告诉 AevonGuard（App 进程）圆盘已展开 —— 它会在自己的进程里
        // 把下半屏的触摸整条吞掉，前台 App 在圆盘开着期间彻底收不到下半屏输入。
        syncGuardConfig()
        // V0.0.34（AevonNotifyRingBitV34）：圆盘状态写进 notify(3) 共享内存。
        // Darwin 广播（ringopen）是 fire-and-forget，沙盒 App 可能收不到 ——
        // Aevon(27) 连续 3 版「圆盘滑动带动全屏 App」的共同根因。共享内存位零时序依赖。
        AevonNotifySetRing(1)
        postRingState("com.aevon.ringopen")
        if source == "global" || source == "appedge" {
            // V0.2.10（AevonAppBlindHoldV210）：这句话以前无条件写「App 不会再跟着滚动」，
            // Aevon(96) 证明它在 App 侧缺位时是假的 —— 现在按实际在场情况自述。
            // V0.2.15（AevonNoSBSwallowV215）：SB 侧吞摸已下线，这里只剩「指针归圆盘」，
            // 不再代表「事件被丢」—— 文字跟着改，别让日志继续替旧机制作证。
            let sideAlive = CACurrentMediaTime() - appSideSignalAt < 2.0
            AevonLog.info("[圆盘] 指针已交给圆盘（SB 侧吞摸本版已下线，不再丢事件；App 侧在场=\(sideAlive ? "是 · 它那份已由 App 内识别器合法取消" : "否 · App 那份未取消，可能出现同时响应")）（AevonRingSwallowV24 AevonRingHalfGuardV29 AevonRingFullSwallowV102 AevonEdgeAdoptV207 AevonAppBlindHoldV210 AevonNoSBSwallowV215）")
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
        appEdgePointerAdopted = false
        ringOpenedAt = 0
        swallowDeadline = 0
        globalTouchID = 0
        globalFired = false
        ownsTouch = false
        globalOwnedAt = 0
        ringExtraTouchID = 0
        ringExtraDeadline = 0
        // V0.2.8（AevonDeskZoneObserveV208）：桌面呼盘收养指的豁免随收起一并清掉
        deskZoneAdoptedTouchID = 0
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
    /// V0.2.12（AevonSwallowSelfHealV212）：接管状态自愈 —— 全系统触摸的必经之路上做巡检。
    ///
    /// 只在 `shouldSwallowGlobalTouch` 里调用，每根手指每一帧一次，开销就是两次时间比较。
    /// 两条判据，任意一条成立立刻归还：
    ///   ① **圆盘已不在场** —— 吞咽存在的唯一理由就是「圆盘正被这根手指驱动」。
    ///      圆盘收起后没有任何正当性继续吞；接管带「只扣移动帧」那条路（bandHoldTouchID）
    ///      不经 ownsTouch，不受影响，照常按它自己的 0.6 秒期限工作。
    ///   ② **圆盘在场但超过 8 秒绝对上限** —— 防「圆盘卡在屏上」时无限吞。
    private static func healGlobalTakeoverIfNeeded() {
        let now = CACurrentMediaTime()
        // 记时：只要「这根手指还挂着」（ownsTouch 或 globalTouchID）就开始算；
        // 两者都清掉才归零。**换了新手指（globalTouchID 变化）必须重新记时** ——
        // 否则「上一轮的旧接管时刻」会立刻把刚建立的新接管判成超期并清掉，
        // 热区连判向都做不成（这一条是本版最容易被写错的地方）。
        let holding = (ownsTouch || globalTouchID != 0)
        if holding {
            if globalTouchID != globalOwnedForTouch || globalOwnedAt == 0 {
                globalOwnedForTouch = globalTouchID
                globalOwnedAt = now
            }
        } else {
            globalOwnedForTouch = 0
            globalOwnedAt = 0
        }
        guard holding, globalOwnedAt > 0 else { return }

        var reason = ""
        if !AevonRingMenu.isPresented, now - globalOwnedAt > healIdleWindow {
            // 圆盘不在场 + 接管已经存在超过判向窗口 = 这次接管没有任何去处了。
            // 为什么不能「圆盘一不在就清」：热区/接管带的整个设计是「began 即接管，
            // 看清左扫才呼盘」—— 接管那一瞬间圆盘必然还没展开，若立刻清，
            // 热区连判向都做不成，功能整体失效。判向在 60ms 内完成，1.5 秒是极宽裕的上限。
            reason = "圆盘已收起且接管超过 \(String(format: "%.1f", healIdleWindow)) 秒"
        } else if now - globalOwnedAt > globalOwnHardLimit, !AevonRingMenu.isPresented {
            // V0.2.18（AevonRingCloseOnLiftV218）：圆盘还开着就不再走这一档。
            //
            // 这一档的正当性来自「接管已经没有去处了」；圆盘开着时接管恰好是最有去处的时候。
            // 旧版在圆盘开着时照砍：12 秒一到把 globalTouchID 清掉 → 圆盘的喂料瞬间断流
            // （moved / ended 全部被 `guard touchID == globalTouchID` 挡掉），
            // 用户看到的是「手指还在屏上，圆盘先定住、然后被强制收掉」。
            // 止血交给 `enforceDeadManSwitch` 里那条 30 秒「完全没有指针事件」的安全网。
            reason = "收归超过 \(Int(globalOwnHardLimit)) 秒"
        }
        guard !reason.isEmpty else { return }

        let heldID = globalTouchID
        ownsTouch = false
        globalTouchID = 0
        globalFired = false
        swallowDeadline = 0
        globalOwnedAt = 0
        globalOwnedForTouch = 0
        if now - lastHealLogAt > 1.0 {
            lastHealLogAt = now
            AevonLog.warn("[自愈] 接管状态未正常归还（\(reason)）→ 立刻把手指还给系统：ownsTouch=0 globalTouchID=\(heldID) → 0（AevonSwallowSelfHealV212）")
        }
    }

    static func shouldSwallowGlobalTouch(_ touchID: UInt, phase: Int) -> Bool {
        guard AevonPrefs.bool("Enabled", default: true) else { return false }
        guard touchID != 0 else { return false }
        // V0.2.12（AevonSwallowSelfHealV212）：任何判断之前先自愈。
        // 这一行就是「结构上不可能卡死」的全部：只要圆盘不在场，ownsTouch / globalTouchID
        // 会被当场清零，后面所有分支都不可能再对任何手指返回 true。
        healGlobalTakeoverIfNeeded()
        // V0.2.15（AevonNoSBSwallowV215）：整条「SB 侧吞摸」链路焊死在关。
        //
        // 为什么是「焊死」而不是「删掉」：CI 里压着 0.1.12 ~ 0.2.14 二十多条历史断言
        // （扣帧判据、抬手放行、自愈标记…），删代码等于把那些防线连同证据一起抹掉。
        // 焊在入口等价于删除运行行为，但每一版留下的判据还查得回去。
        //
        // 只留一条：**浮窗拖拽**。浮窗是 SpringBoard 自己的窗口，拖它的时候底下桌面
        // 也会跟着动，这一条必须吞。其余的（热区整指、右缘接管带、圆盘接管、收养指）
        // 全部不再生效 —— 它们的收益只存在于「App 收不到这根手指」，而这一条
        // 从来就不成立（backboardd 双投给 App 一份，SB 吞不到）。
        //
        // 开关是运行期读的（不是 `static let false`），所以不会被编译器折叠掉；
        // 没有界面入口，默认关，需要复现老问题时才用 `defaults write com.Aevon SBSwallow -bool YES`。
        if !AevonPrefs.bool("SBSwallow", default: false) {
            if floatGestureActive, touchID == floatTouchID,
               CACurrentMediaTime() <= floatDeadline {
                return true
            }
            return false
        }
        // V0.2.8（AevonDeskZoneObserveV208）：桌面热区呼盘的收养指 —— 吞摸豁免。
        // 这根手指 began 就给了桌面，后续帧（含 ended）必须照常投递，
        // 否则桌面翻页卡半路；圆盘只靠观察喂盘，不靠吞。
        if touchID == deskZoneAdoptedTouchID { return false }
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
        // V0.0.29：圆盘展开期间重新登记的指针（旧版是 KeepOpen 后点选的那根；
        // 0.2.17 起抬手即收盘，剩下的是「收盘动画的 0.18 秒」与通道漏发 ended 的自愈）。
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
        // V0.2.20（AevonAppGeomNotifyV220）：右缘带宽/带高改了 → 立刻发布到共享内存
        AevonEdgeEntry.syncBandGeometryToNotify()
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
        AevonEdgeEntry.noteAppSideAlive()
        AevonEdgeEntry.attemptTrigger("App 侧右缘判向成立（App 触摸已被合法取消）", source: "appedge")
    }
}

/// V0.2.3（AevonAppYieldV203）：App 侧带内 began 的通知回调 → 全局通道让路。
private func aevonAppEdgeBeganHandler(_ center: CFNotificationCenter?,
                                      _ observer: UnsafeMutableRawPointer?,
                                      _ name: CFNotificationName?,
                                      _ object: UnsafeRawPointer?,
                                      _ userInfo: CFDictionary?) {
    DispatchQueue.main.async {
        AevonEdgeEntry.noteAppSideAlive()
        AevonEdgeEntry.yieldGlobalChannelToAppSide()
    }
}

/// V0.2.6（AevonEdgeFailGateV206）：App 侧判向失败（纵向/向右/抬手未成立/卡死自愈）
/// 的通知回调 → 1.5s 内禁止 global 兜底呼盘（那根手指不是在呼出）。
private func aevonAppEdgeFailHandler(_ center: CFNotificationCenter?,
                                     _ observer: UnsafeMutableRawPointer?,
                                     _ name: CFNotificationName?,
                                     _ object: UnsafeRawPointer?,
                                     _ userInfo: CFDictionary?) {
    DispatchQueue.main.async {
        AevonEdgeEntry.noteAppSideAlive()
        AevonEdgeEntry.appEdgeFailUntil = CACurrentMediaTime() + 1.5
    }
}

/// V0.2.10（AevonAppBlindHoldV210）：App 侧挂载成功 / 回到前台的通告。
///
/// 这条通知是「盲期守门」的唯一解药：收到它，SB 才知道这一侧的识别器真的在，
/// 后面几秒才允许在这台 App 上呼盘。App 侧在 installWithAttempt 成功处与
/// handleBecomeActive 各发一次，覆盖冷启动与热切换两条路径。
private func aevonAppReadyHandler(_ center: CFNotificationCenter?,
                                  _ observer: UnsafeMutableRawPointer?,
                                  _ name: CFNotificationName?,
                                  _ object: UnsafeRawPointer?,
                                  _ userInfo: CFDictionary?) {
    DispatchQueue.main.async {
        AevonEdgeEntry.noteAppSideAlive()
    }
}

/// V0.1.2（AevonGuardCleanupV102）：Guard 回执计数与 handler 已随 Guard 移除。
/// 历史 CI 校验串（AevonGuardAckV35）由 AevonAssertionShim.m 的 used 常量收容。
