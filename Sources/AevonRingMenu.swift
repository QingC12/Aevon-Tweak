import UIKit

/// 圆盘上的一个 App 单元（V0.0.22：**恢复原生 App 图标**）。
///
/// 取图走 `AevonAppIcon`（多源兜底），取到就显示圆角方形图标；
/// 取不到才退回「深色胶囊 + 白字」的文字卡片，保证任何情况下都能认出是哪个 App。
final class AevonRingIcon: UIView {
    let bundleID: String
    var displayName: String

    private let label = UILabel()
    private let iconView = UIImageView()
    /// 是否成功拿到原生图标（决定高亮时改边框还是改底色）
    private let hasIcon: Bool

    init(bundleID: String, name: String, size: CGFloat) {
        self.bundleID = bundleID
        self.displayName = name
        // V0.2.62（AevonQuickActionV262）：截图 / 录屏两个动作槽没有 App 图标，
        // 用 SF Symbol 画（白色实心，和原生图标一样铺满方框）。
        let actionIcon = AevonQuickAction.symbolImage(bundleID: bundleID, size: size - 4)
        let icon = actionIcon ?? AevonAppIcon.image(bundleID: bundleID, size: size - 4)
        self.hasIcon = icon != nil
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        backgroundColor = hasIcon ? .clear : UIColor(white: 0.12, alpha: 0.92)
        isUserInteractionEnabled = false
        // V0.0.31（AevonRingSquareV31）：改回方形（用户 Aevon(24)：圆形看着别扭）
        // —— 与系统主屏图标一致的圆角方，外壳与内部图标都按 0.26 / 0.2237 圆角率。
        layer.cornerRadius = size * 0.26
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 1.0, alpha: 0.16).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

        if let icon = icon {
            iconView.image = icon
            iconView.frame = bounds.insetBy(dx: 2, dy: 2)
            // 动作槽是 SF Symbol，居中即可（拉伸会把线条图撑变形）
            iconView.contentMode = actionIcon != nil ? .center : .scaleAspectFill
            iconView.isUserInteractionEnabled = false
            iconView.layer.cornerRadius = size * 0.2237
            iconView.clipsToBounds = true
            addSubview(iconView)
        } else {
            label.frame = bounds.insetBy(dx: 3, dy: 2)
            label.text = AevonRingIcon.shortName(name)
            label.textAlignment = .center
            label.textColor = .white
            label.numberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.62
            label.isUserInteractionEnabled = false
            addSubview(label)
            label.font = UIFont.systemFont(ofSize: AevonRingIcon.fontSize(for: label.text ?? "", size: size),
                                           weight: .medium)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 当前是否处于高亮态（避免手指每移一帧就重写一遍 layer 属性）
    private var highlightedNow = false

    /// 高亮「松手就会打开」的那个图标
    func setHighlighted(_ highlighted: Bool) {
        guard highlighted != highlightedNow else { return }
        highlightedNow = highlighted
        layer.borderWidth = highlighted ? 2.5 : 0.5
        layer.borderColor = (highlighted
            ? UIColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0)
            : UIColor(white: 1.0, alpha: 0.16)).cgColor
        // 选中用蓝色光晕强化（文字已经去掉了，靠这个确认选的是哪个）
        layer.shadowColor = (highlighted
            ? UIColor(red: 0.30, green: 0.78, blue: 1.0, alpha: 1.0)
            : UIColor.black).cgColor
        layer.shadowOpacity = highlighted ? 0.85 : 0.45
        layer.shadowRadius = highlighted ? 10 : 6
        if !hasIcon {
            backgroundColor = highlighted
                ? UIColor(red: 0.10, green: 0.48, blue: 0.95, alpha: 0.96)
                : UIColor(white: 0.12, alpha: 0.92)
        }
    }

    /// 名字太长会挤成一团：超过 6 个字就截断（圆盘上一行最多 4 字、两行 8 字，取 6 兼顾）
    static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 6 { return trimmed }
        return String(trimmed.prefix(6))
    }

    private static func fontSize(for text: String, size: CGFloat) -> CGFloat {
        switch text.count {
        case 0...2: return size * 0.30
        case 3: return size * 0.26
        case 4: return size * 0.235
        default: return size * 0.21
        }
    }
}

/// 径向圆盘选择器（V0.0.23：整体缩到原来的 75% 面积 + 外圈多于内圈 + 手势对调）。
///
/// 形态：
///   · 圆心固定在屏幕水平中央、纵向 **75%**；
///   · 圈数按数量自动增加（≤8 一圈 / 9~20 两圈 / ≥21 三圈），
///     **每圈容量按半径递增**（内圈少、外圈多），相邻圈错开半个步进，视觉更自然；
///   · 内圈半径 62、间距 50（V0.0.28 收紧），图标 40pt、圆心按钮 48pt；
///   · 圆心按钮是蓝色圆 + 四宫格图标，点它打开完整应用选择面板。
///
/// 交互（V0.0.28 定稿，**替换掉此前所有旋转 / 解锁判定**）：
///   1. 圆盘呼出后默认是「选择模式」—— 手指指到哪个图标就高亮哪个，
///      松手落在图标上 → 用浮窗打开它；落在圆心 → 打开完整面板；落在空白 / 盘外 → 收起。
///   2. 手指在**圆心图标上停 1 秒** → 进入「旋转模式」（轻震 + 涟漪 + 圆心变青绿），
///      此后**顺时针、逆时针都能跟手旋转**。
///   3. 旋转模式下**其它图标一律不能选中**，只有圆心可以操作；
///      再按住圆心 1 秒（或按一下就松手）→ 退出旋转，回到选择模式。
///   4. 旋转中把手指移到盘外松手 → 收起圆盘（不打开任何 App）。
///   5. 唤出圆盘的那根手指**不必抬起**：它直接从边缘滑进圆盘就能选图标。
///      **手指没离开屏幕，圆盘绝不收起**（哪怕手指已经在盘外滑了一大圈 —— 呼盘那一下
///      手指本来就贴在右缘、离圆心一百多 pt，那不叫「在盘外」）；
///      只有**抬手**那一刻才判定：在盘外 → 收；在图标之间的间隙里 → 也收；
///      落在图标上 → 开窗；落在圆心 → 打开面板。
///      （V0.2.18 / AevonRingCloseOnLiftV218，取代 0.0.28 的「盘外抬手保持展开」
///      AevonRingKeepOpenV28 与 0.2.17 的「抬手即收」AevonRingLiftDismissV217 —— 规则没变，
///      变的是「手指还在屏上时，外面的定时器不许替它收」。）
///   6. **屏幕上没有任何文字**（圆心、底部都没有）—— 状态只靠圆心图标 / 颜色和动效表达。
///
/// 触摸来源去重：唤出圆盘的那根手指可能同时被「边缘手势条」「窗口 sendEvent 探针」
/// 「全局触摸通道」看到，三条通道都会转发同一个点。这里用 `pointerSource`
/// 只认最先开始的那一条，避免同一次滑动被算两遍。
final class AevonRingMenu: UIView {
    private static var current: AevonRingMenu?

    private static let iconSize: CGFloat = 40
    private static let centerSize: CGFloat = 48
    /// 命中半径系数
    private static let hitFactor: CGFloat = 0.95
    /// 圆心按住多久进入 / 退出旋转模式（秒）
    private static let centerHoldDuration: TimeInterval = 1.0
    /// 圆心命中半径（比按钮本身放大一点，手指压在图标边缘也算）
    private static let centerHitRadius: CGFloat = 40

    // MARK: - 划过图标的「跳跃」动画（V0.0.35 起，V0.2.18 加大）
    //
    // 用户 Aevon(104) 的两条要求，都在这一组常量里：
    //   ① 「图标跳动的高度增加 50%」 —— 8pt → 12pt（`hoverLift`）；
    //   ② 「划过图标时放大效果再大一点，圆盘看起来更 Q 弹」 —— 1.18 → 1.30（`hoverScale`），
    //      同时把弹簧阻尼从 0.42 降到 0.34、初速从 2.8 提到 3.4 —— 阻尼越低回摆越多，
    //      视觉上就是「弹上去 → 超调 → 吸回来」的那一下。
    //
    // 位置放在这里而不是写进 `setHovered` 里：这两个数以后只该改这一处。
    /// 划过图标时的向上跳跃高度（屏幕坐标，负 y = 向上）
    static let hoverLift: CGFloat = 12
    /// 划过图标时的放大倍数
    static let hoverScale: CGFloat = 1.30
    /* V0.3.18（AevonSpringUnifyV318）：跳跃 / 放大的弹簧参数改成 **response**（一个振荡周期）。
     *
     * 0.3.17 及以前这里是 `UIView.animate(0.52, damping 0.34, velocity 3.4)`。那是 iOS 7 的
     * 老 API，duration 的语义是「起到静止的总时长」，和 Stheno 用的 SwiftUI
     * `Animation.spring(response:dampingFraction:)` 里的 response **不是同一个物理量**；
     * 配上 0.34 的低阻尼与 3.4 的初速，划过图标是「猛冲 → 大幅过冲 → 晃回来」。
     * 更要紧的是它和圆盘上另外四条弹道（ζ 0.55 / 0.676 / 0.78 / easeOut）各弹各的 ——
     * 同一个盘上五种手感，观感就是不连贯。
     *
     * 现在全部走 `AevonSpring.params`：response 0.40、ζ 由用户滑条给（默认 0.72），
     * 回摆约 4% —— 看得见「弹」，但收得干净。老的那三个常量已删除，不许再长回来。 */
    static let hoverSpringResponse: Double = 0.40
    /// 指针事件中断多久之后允许新手指出手接管（自愈，防止某条通道漏发 ended 把圆盘卡死）
    private static let pointerStaleInterval: CFTimeInterval = 1.2
    /// V0.2.66（AevonRingIdleV266）：指针静默多久后判定「手指早已离屏但 ended 漏发」
    /// → 自动收起圆盘。用户 Aevon(39) #5：滑动呼出圆盘后抬手，圆盘留在屏上必须
    /// 再点一下才消失 —— 就是某条通道漏了 ended，`isFingerDown` 恒真，圆盘成了死态。
    /// 0.8 秒比 pointerStaleInterval(1.2) 短：宁可早一点收，也不让用户多点一次。
    /// 副作用：按住圆盘完全静止 0.8 秒也会收 —— 「静止不动」与「已抬手」在事件层
    /// 无法区分，选择偏向用户报的那一侧。
    private static let pointerIdleDismissInterval: CFTimeInterval = 0.8
    /// 指针**通道**交接阈值（V0.2.16 / AevonRingPointerHandoffV216）。
    ///
    /// 与上面那个 1.2 秒不是一回事：1.2 秒管的是「新手指出手」，这里管的是
    /// 「同一根手指换一条通道继续喂」。用 0.12 秒是因为系统手势识别器判向失败后
    /// 就再也不投递了（Aevon(102) 里 9 次呼盘全部在 0.1~0.5 秒内 Failed），
    /// 交接必须比这个快，否则圆盘会明显「愣一下」。
    private static let pointerHandoffInterval: CFTimeInterval = 0.12
    /// V0.3.16（AevonOwnLiftV316）：抬手帧被交换闸拒的日志限流（0.5s 一条）。
    private static var lastLiftRejectLogAt: CFTimeInterval = 0
    /// 圆心纵向位置（占屏幕高度比例）
    private static let verticalRatio: CGFloat = 0.75

    private let dimView = UIView()
    private let trackLayer = CAShapeLayer()
    private let centerButton = UIButton(type: .custom)
    // V0.2.10（AevonRingHubV210）：圆心外面加两层「底盘」。
    //
    // 用户 Aevon(96)：「美化一下圆盘中间的应用选择器面板」。原来圆心就是一个孤零零的
    // 蓝色圆浮在图标中间，和内圈 62pt 的轨道之间空出一大块，看着像没画完。
    // 现在补两层同心圆盘（外层 92、内层 70，都是白色的 6~7% 填充 + 1pt 微光描边），
    // 圆心按钮本身改成渐变蓝、按下 / 旋转时整组一起换色 —— 变成「枢纽」而不是「一个按钮」。
    // 两层都 `isUserInteractionEnabled = false`，绝不参与触摸判定（命中仍走几何距离）。
    private let hubPlate = UIView()
    private let hubInner = UIView()
    private let centerGradient = CAGradientLayer()
    // V0.2.11（AevonRingGlyphTopV211）：四宫格「应用选择」图标单独一层。
    //
    // 用户 Aevon(97) 第四条：「圆盘中心的应用选择图标不要被蓝色层覆盖」。
    // 0.2.10 把圆心底色从 backgroundColor 换成了插在 layer 第 0 位的 CAGradientLayer ——
    // 于是这个图标能不能看见，取决于 UIKit 给 UIButton 的 imageView 排在第几层，
    // 那是实现细节，不该由它决定。现在图标是**独立视图**，层级比按钮高一级（zPosition 3），
    // 蓝层再怎么插都盖不住它。
    private let centerGlyph = UIImageView()

    private var icons: [AevonRingIcon] = []
    private var iconRadii: [CGFloat] = []
    private var iconBaseAngles: [CGFloat] = []
    private var ringCounts: [Int] = []
    private var ringRadii: [CGFloat] = []

    private var rotation: CGFloat = 0
    /// 阻尼显示角（V0.0.30 起，V0.0.33 升级为速度弹簧）：图标不直接贴手指角度。
    /// V0.0.33（AevonRingSpringV33）：从「每帧追 32%」的纯指数追赶，换成
    /// **质量-弹簧-阻尼**积分器 —— 带速度项，急停会过冲回摆（Q 弹），
    /// 慢拖有黏滞阻尼感（更跟手、更顺），比 diff*0.32 的发飘手感强得多。
    private var displayRotation: CGFloat = 0
    /// 显示角速度（度/帧），弹簧积分器的状态量
    private var displayVelocity: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var ringCenter: CGPoint = .zero
    private var isDismissing = false

    // V0.0.28：统一指针状态（唤出圆盘的那根手指 / 事后新按的手指走同一套逻辑）
    /// 当前指针归属（"" = 没有活动指针）。同一时刻只认一根手指。
    private var pointerSource = ""
    /// 交接日志限频（AevonRingPointerHandoffV216）
    private var pointerHandoffLogAt: CFTimeInterval = 0
    private var pointerPoint: CGPoint = .zero
    private var pointerAngle: CGFloat = 0
    private var pointerLastEventAt: CFTimeInterval = 0
    /// 这根手指是否进过圆盘范围（区分「唤出圆盘那一下」和「进盘后拖出去取消」）
    private var pointerEverInsideRing = false

    /// 手指是否**还压在屏上**（V0.2.18 / AevonRingFingerDownV218）。
    ///
    /// 用户 Aevon(104) 把关闭规则讲清楚了：
    ///   ① 手指滑出圆盘但没离开屏幕 —— **不算**「在圆盘外」，圆盘不许收；
    ///   ② 只有手指**离开屏幕**时在盘外，或落在图标之间的**间隙**里，才收圆盘。
    ///
    /// 所以「收不收」只由 `handlePointerEnded` 一处决定。这个字段的作用是给外面
    /// （SpringBoard 侧的三个定时器）一个判据：手指还在屏上就别替我收。
    /// 置真：began / moved / 通道交接；置假：ended / cancelled / 收起。
    private(set) var isFingerDown = false

    /// 距离上一次指针事件过去了多少秒（没有过事件时返回一个大数）。
    /// 只用于「真的没人操作了」的安全网，不参与「收不收」的判断。
    var pointerIdleSeconds: CFTimeInterval {
        guard pointerLastEventAt > 0 else { return .greatestFiniteMagnitude }
        return CACurrentMediaTime() - pointerLastEventAt
    }

    /// 旋转模式：只有「按住圆心 1 秒」能开关
    private var rotating = false
    private var centerHoldTimer: Timer?
    /// 刚切换过模式：要等手指离开圆心 / 重新按下，才允许再按 1 秒切换
    private var centerHoldSuppressed = false

    // V0.0.39（AevonRingNoHoldRemoveV39）：长按图标移除功能已整体删除（用户不需要）；
    // 圆盘列表的增删统一走设置页的圆盘编辑器。

    // MARK: - 呼出 / 收起

    static func present(in host: UIView) {
        if let existing = current {
            existing.dismiss()
            return
        }
        let menu = AevonRingMenu(frame: host.bounds)
        /* V0.3.18（AevonSpringUnifyV318）：阻尼比在展开这一刻读一次，之后整局复用。
         * 滑条改动要下次呼盘才生效 —— 这是刻意的：逐帧读 prefs 是跨进程 IPC。 */
        menu.hoverZ = AevonSpring.userDampingFraction()
        host.addSubview(menu)
        host.bringSubviewToFront(menu)
        current = menu
        menu.reload()
        menu.animateIn()
        menu.startIdleWatch()
    }

    // MARK: - V0.2.66（AevonRingIdleV266）：指针静默自动收起
    //
    // 用户 Aevon(39) #5：滑动呼出圆盘后手指离开屏幕，圆盘留在屏上必须再点一下。
    // 抬手判定（handlePointerEnded）本身没问题 —— 问题是那条通道**根本没把 ended
    // 送进来**（收养手指只登记观察，通道交接 / 系统手势抢断都可能漏发最后一报），
    // isFingerDown 恒真，圆盘成了死态。这里用「静默时长」兜底：0.8 秒没有任何
    // 指针事件就判定手指早已离屏，按「抬手未选中」收起。

    private var idleWatch: Timer?

    private func startIdleWatch() {
        idleWatch?.invalidate()
        // 呼盘后先给 1 秒宽限：部分通道（视图层 pan）呼盘后才交指针，
        // 不能让「还没喂过第一报」被误判成「手指早已离屏」。
        presentedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, AevonRingMenu.current === self, !self.isDismissing else { return }
            guard CACurrentMediaTime() - self.presentedAt >= 1.0 else { return }
            // V0.2.69（AevonRingIdleFixV269，用户 Aevon(41) #2「触发圆盘时，手指
            // 没有离开屏幕，有时候会自动关闭圆盘」）：静默 ≠ 手指已离屏 —— 用户
            // 按住不动（圆心按住 / 旋转模式 / 盯着看）同样静默。真判据是 UIKit
            // 活跃触摸：圆盘视图与把手上都查不到活跃 touch，才算「ended 真漏发」。
            // 圆心按住与旋转模式照旧豁免（它们的 touch 一定在）。
            guard !self.rotating, self.centerHoldTimer == nil else { return }
            guard self.pointerIdleSeconds >= AevonRingMenu.pointerIdleDismissInterval else { return }
            guard !self.hasLiveTouch else { return }
            AevonLog.info("[圆盘] 指针已静默 \(String(format: "%.1f", self.pointerIdleSeconds))s"
                + "（最后落点 (\(String(format: "%.0f", self.pointerPoint.x)), \(String(format: "%.0f", self.pointerPoint.y)))）"
                + " → 圆盘与把手均无活跃触摸（ended 漏发实锤），自动收起"
                + "（AevonRingIdleV266 AevonRingIdleFixV269）")
            self.dismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleWatch = timer
    }

    private var presentedAt: CFTimeInterval = 0

    /// V0.2.69（AevonRingIdleFixV269）：圆盘视图与把手上还有没有活跃触摸。
    /// 静默看门狗的「ended 真漏发」判据 —— 手指物理在屏上时 UIKit 一定把
    /// touch 挂在命中视图（圆盘全屏视图 / 把手控件）上，查得到就不是漏发。
    /// V0.2.69（AevonRingIdleFixV269）：圆盘视图与把手上还有没有活跃触摸。
    /// 静默看门狗的「ended 真漏发」判据 —— UIKit touches 家族是硬通道（指针
    /// 喂料通道会漏最后一报），圆盘自己的触摸计数为 0 且把手上也没手指，
    /// 才算「手指真不在屏上」。
    fileprivate var hasLiveTouch: Bool {
        if uiKitTouchCount > 0 { return true }
        if AevonRingGrip.hasActiveGripTouch { return true }
        return false
    }

    static var presented: AevonRingMenu? { return current }
    static var isPresented: Bool { return current != nil }

    static func dismissCurrent() {
        current?.dismiss()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = true

        dimView.backgroundColor = UIColor(white: 0, alpha: 0.28)
        dimView.frame = bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.isUserInteractionEnabled = false
        addSubview(dimView)

        // 每圈一条极淡的描边，给出「圆盘」的轮廓
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor(white: 1.0, alpha: 0.13).cgColor
        trackLayer.lineWidth = 1.5
        layer.addSublayer(trackLayer)

        // V0.2.10（AevonRingHubV210）：圆心底盘（两层同心圆，纯图层，不参与触摸）
        hubPlate.isUserInteractionEnabled = false
        hubPlate.backgroundColor = UIColor(white: 1.0, alpha: 0.07)
        hubPlate.layer.borderWidth = 1.0
        hubPlate.layer.borderColor = UIColor(white: 1.0, alpha: 0.13).cgColor
        hubPlate.layer.zPosition = 0
        addSubview(hubPlate)

        hubInner.isUserInteractionEnabled = false
        hubInner.backgroundColor = UIColor(white: 1.0, alpha: 0.05)
        hubInner.layer.borderWidth = 1.0
        hubInner.layer.borderColor = UIColor(white: 1.0, alpha: 0.10).cgColor
        hubInner.layer.zPosition = 0
        addSubview(hubInner)

        // V0.0.25：圆心只留四宫格图标，不再有任何文字
        // V0.0.26：底部提示文字也一并移除 —— 屏幕上不再出现任何说明文字，
        //          后续用「选中动画」表达状态（用户 Aevon(19) 要求）

        centerButton.frame = CGRect(x: 0, y: 0, width: AevonRingMenu.centerSize, height: AevonRingMenu.centerSize)
        // V0.2.10（AevonRingHubV210）：填充改渐变（底色交给 CAGradientLayer，按钮自身透明）
        centerButton.backgroundColor = .clear
        centerButton.layer.cornerRadius = AevonRingMenu.centerSize / 2
        centerGradient.cornerRadius = AevonRingMenu.centerSize / 2
        centerGradient.startPoint = CGPoint(x: 0.18, y: 0.02)
        centerGradient.endPoint = CGPoint(x: 0.82, y: 1.0)
        centerGradient.colors = [
            UIColor(red: 0.30, green: 0.66, blue: 1.00, alpha: 0.98).cgColor,
            UIColor(red: 0.07, green: 0.36, blue: 0.88, alpha: 0.98).cgColor
        ]
        centerButton.layer.insertSublayer(centerGradient, at: 0)
        centerButton.layer.shadowColor = UIColor.black.cgColor
        centerButton.layer.shadowOpacity = 0.45
        centerButton.layer.shadowRadius = 12
        centerButton.layer.shadowOffset = CGSize(width: 0, height: 3)
        // 圆心图标：四宫格（表示「应用列表 / 面板」）
        // V0.2.11（AevonRingGlyphTopV211）：图标不再挂在按钮上（UIButton 的 imageView 层级
        // 由 UIKit 决定，蓝色渐变一插入就可能压住它）—— 改成独立视图，zPosition 最高。
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        if let symbol = UIImage(systemName: "square.grid.2x2.fill", withConfiguration: symbolConfig) {
            centerGlyph.image = symbol
            centerGlyph.tintColor = .white
        } else {
            centerButton.setTitle("A", for: .normal)
            centerButton.setTitleColor(.white, for: .normal)
            centerButton.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .bold)
        }
        // 圆心不接收触摸：由几何判定处理，避免和旋转手势冲突
        centerButton.isUserInteractionEnabled = false
        centerButton.layer.zPosition = 2
        addSubview(centerButton)

        // 图标层压在最上面：蓝色渐变 / 底盘 / 高亮环都在它下面，怎么插都盖不住
        centerGlyph.isUserInteractionEnabled = false
        centerGlyph.contentMode = .scaleAspectFit
        centerGlyph.layer.zPosition = 3
        addSubview(centerGlyph)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        centerHoldTimer?.invalidate()
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - 几何

    private func computeGeometry() {
        // 圆心固定：水平正中，纵向 75%（用户 2026-10-22 第二次要求）
        ringCenter = CGPoint(x: bounds.midX, y: bounds.height * AevonRingMenu.verticalRatio)

        centerButton.center = ringCenter
        centerGradient.frame = centerButton.bounds
        layoutHub()
    }

    /// V0.2.11（AevonRingHubFitV211）：心圆底盘 + 四宫格图标的尺寸与位置。
    ///
    /// 0.2.10 把底盘写死成 92 / 70 —— 92 的半径 46 比「内圈半径 62 − 图标半宽 19 = 43」
    /// 还大 3pt，于是底盘边缘必然压在内圈图标的内侧边上（用户 Aevon(97) 看到的
    /// 「中心图标被盖住」）。现在按**实际内圈半径和本圈图标尺寸**反算：
    ///   底盘半径 = min(46, 内圈半径 − 图标半宽 − 5)，至少 35；
    ///   内层半径 = 底盘半径 − 6，至少 30。
    /// 一圈布局（内圈半径更大）时自动放大，多圈挤压时自动缩小，永远不与图标相交。
    private func layoutHub() {
        let innerRadius = ringRadii.first ?? 62
        let iconHalf = (icons.first.map { $0.bounds.width } ?? AevonRingMenu.iconSize) / 2
        let plateRadius = min(46, max(35, innerRadius - iconHalf - 5))
        let innerHole = max(30, plateRadius - 6)

        hubPlate.bounds = CGRect(x: 0, y: 0, width: plateRadius * 2, height: plateRadius * 2)
        hubPlate.center = ringCenter
        hubPlate.layer.cornerRadius = plateRadius

        hubInner.bounds = CGRect(x: 0, y: 0, width: innerHole * 2, height: innerHole * 2)
        hubInner.center = ringCenter
        hubInner.layer.cornerRadius = innerHole

        let glyphSide: CGFloat = 22
        centerGlyph.frame = CGRect(x: 0, y: 0, width: glyphSide, height: glyphSide)
        centerGlyph.center = ringCenter
    }

    /// 圆的可用最大半径：不超出左右边界，也不顶到状态栏 / 底部
    private var maxRadius: CGFloat {
        let byWidth = bounds.width / 2 - AevonRingMenu.iconSize / 2 - 6
        let verticalRoom = min(ringCenter.y, bounds.height - ringCenter.y)
        let byHeight = verticalRoom - AevonRingMenu.iconSize / 2 - 12
        return max(64, min(byWidth, byHeight))
    }

    /// 各圈半径。
    ///
    /// V0.0.30（AevonRingDenseV29 → 自适应间距）：**一切以圆心图标为基准向外扩散**——
    /// 半径 = max(内圈基准 62 + 44×圈序, 每圈数量 × 46pt ÷ 2π)，即「图标中心间距 ≈46pt」
    /// 恒定、内圈永远不小于贴住圆心的 62（62 − 圆心半径 24 − 图标半径 20 = 18pt 间隙）。
    /// 8 个 → 62、20 个(8/12) → 62/88、25 个(10/15) → 73/110，
    /// 不会再出现「内圈被数量撑到 70+、离中心一大截」（用户 Aevon(23) 反馈）。
    /// 上限压到 maxRadius（不顶屏幕边）。
    private func radii(forCounts counts: [Int]) -> [CGFloat] {
        guard !counts.isEmpty else { return [] }
        let spacing: CGFloat = 46
        let inner: CGFloat = 62
        let limit = maxRadius
        var result: [CGFloat] = []
        var previous: CGFloat = 0
        for (index, count) in counts.enumerated() {
            let base = inner + 44 * CGFloat(index)
            var r = max(base, spacing * CGFloat(count) / (2 * .pi))
            r = max(r, previous + 44)
            r = min(r, limit)
            result.append(r)
            previous = r
        }
        return result
    }

    /// 按总数决定每圈放几个（V0.0.29 重写，标记 AevonRingDenseV29）。
    ///
    /// 旧版问题（用户 Aevon(22) 反馈）：固定权重 1 : 1.5 : 2 + 内圈半径 62 起步，
    /// 21~25 个 App 时内圈只摊到 4~5 个，弧线间距被拉到 ~80pt，「图标之间的间隔非常大」。
    ///
    /// 新规则（配合 `radii(forCounts:)` 的「数量反推半径」一起用）：
    ///   · ≤16 个：一圈（半径由数量反推，4 个也只会撑到 62 的下限）；
    ///   · 17~34 个：两圈，内圈约 40%（20 个 → 8 + 12，半径约 70 / 106，间距≈55）；
    ///   · ≥35 个：三圈，权重 1 : 1.5 : 2（36 个 → 8 + 12 + 16，间距≈55）。
    /// 外圈仍不少于内圈；每圈数量有上限（12 / 15 / 20），防止间距被压到图标重叠。
    static func distribution(for total: Int) -> [Int] {
        guard total > 0 else { return [] }
        if total <= 16 { return [total] }
        if total <= 34 {
            var inner = Int((CGFloat(total) * 0.4).rounded())
            inner = min(max(inner, 4), 12)
            return [inner, total - inner]
        }
        let caps = [12, 15, 20]
        let weights: [CGFloat] = [1, 1.5, 2]
        var parts = weights.enumerated().map { (i, w) in
            min(max(Int((CGFloat(total) * w / 4.5).rounded(.down)), 4), caps[i])
        }
        var rest = total - parts.reduce(0, +)
        // 余数先给外圈、再给中圈（保持「外多内少」），同时不超容量
        var guardCounter = 0
        while rest > 0 && guardCounter < 64 {
            guardCounter += 1
            if parts[2] < caps[2] { parts[2] += 1; rest -= 1 }
            else if parts[1] < caps[1] { parts[1] += 1; rest -= 1 }
            else if parts[0] < caps[0] { parts[0] += 1; rest -= 1 }
            else { break }
        }
        // 超出总容量（>47 个）时溢出塞给外圈，间距略压小于目标值即可
        if rest > 0 { parts[2] += rest }
        return parts
    }

    private func reload() {
        computeGeometry()
        for icon in icons { icon.removeFromSuperview() }
        icons.removeAll()
        iconRadii.removeAll()
        iconBaseAngles.removeAll()
        ringCounts.removeAll()
        ringRadii.removeAll()

        let bundleIDs = AevonRingStore.bundleIDs()

        // 由内到外依次填圈：容量按总数动态分配（外圈一定比内圈多）
        ringCounts = AevonRingMenu.distribution(for: bundleIDs.count)
        ringRadii = radii(forCounts: ringCounts)

        var cursor = 0
        for (ringIndex, count) in ringCounts.enumerated() {
            let radius = ringRadii[ringIndex]
            let step = 360 / CGFloat(max(count, 1))
            // 相邻圈错开半个步进：图标不会在上下方向连成一条直线，视觉更自然
            let offset: CGFloat = (ringIndex % 2 == 1) ? step / 2 : 0
            // V0.0.31（AevonRingAutoSizeV31）：图标大小自适应 —— 按本圈弧间距缩放，
            // 挤的时候自动变小、疏的时候保持 40pt，永远不互相重叠。
            let arcSpacing = 2 * CGFloat.pi * radius / CGFloat(max(count, 1))
            let iconSize = min(AevonRingMenu.iconSize, max(28, arcSpacing * 0.78))
            for i in 0..<count {
                guard cursor < bundleIDs.count else { break }
                let bundleID = bundleIDs[cursor]
                cursor += 1
                let name = AevonWindowManager.title(for: bundleID)
                let icon = AevonRingIcon(bundleID: bundleID, name: name, size: iconSize)
                // V0.2.11（AevonRingGlyphTopV211）：图标层级固定 1（底盘 0 / 蓝层按钮 2 / 四宫格 3）
                icon.layer.zPosition = 1
                addSubview(icon)
                icons.append(icon)
                iconRadii.append(radius)
                iconBaseAngles.append(-90 + offset + CGFloat(i) * step)
            }
        }

        drawRingTracks()
        layoutIcons()
        // 图标与半径都就位了，按真实几何重算心圆底盘（不能放在 computeGeometry 里 ——
        // 那一刻 ringRadii / icons 还是空的，会算成默认 62/40）
        layoutHub()

        // V0.0.26：屏幕上不再有任何提示文字（圆心 / 底部都没有）
        let radiiText = ringRadii.map { String(Int($0)) }.joined(separator: "/")
        let countsText = ringCounts.map(String.init).joined(separator: "/")
        AevonLog.info("[圆盘] 已展开（\(icons.count) 个 App，\(ringCounts.count) 圈，每圈 \(countsText) 个，半径 \(radiiText)，圆心 \(Int(ringCenter.x)),\(Int(ringCenter.y))，间距 46pt 恒定 / 内圈贴中心 62 / 方形图标自适应 / 位置固定记忆 / 速度弹簧跟手 / 弹簧出入场 / 状态位共享内存）（AevonRingFullCircle AevonRingMultiRing AevonRingNativeIconV22 AevonRingAnchor75V21 AevonRingLayoutFitV23 AevonRingCenterTextFreeV24 AevonRingNoLabelV25 AevonRingNoHintV26 AevonRingInnerTightV28 AevonRingHoldRotateV28 AevonRingTwoModeV28 AevonRingDenseV29 AevonRingSpringV30 AevonRingDampV30 AevonRingSquareV31 AevonRingAutoSizeV31 AevonRingPinnedV31 AevonRingSpringV33 AevonNotifyRingV34 AevonRingHopV35 AevonRingGlyphTopV211 AevonRingHubFitV211）")
    }

    private func drawRingTracks() {
        let path = UIBezierPath()
        for radius in ringRadii {
            path.append(UIBezierPath(arcCenter: ringCenter,
                                     radius: radius,
                                     startAngle: 0,
                                     endAngle: CGFloat.pi * 2,
                                     clockwise: true))
        }
        trackLayer.path = path.cgPath
        trackLayer.frame = bounds
    }

    private func layoutIcons(_ angle: CGFloat? = nil) {
        guard !icons.isEmpty else { return }
        let use = angle ?? rotation
        for (index, icon) in icons.enumerated() {
            guard index < iconRadii.count, index < iconBaseAngles.count else { continue }
            let radians = (iconBaseAngles[index] + use) * .pi / 180
            let radius = iconRadii[index]
            icon.center = CGPoint(x: ringCenter.x + radius * cos(radians),
                                  y: ringCenter.y + radius * sin(radians))
        }
    }

    // MARK: - 阻尼跟手旋转（V0.0.30，V0.0.33 速度弹簧 AevonRingSpringV33）

    /// 启动弹簧追赶：图标角速度向 `rotation` 弹簧收敛，
    /// 收敛完成后自动停掉 CADisplayLink（平时零开销）。
    private func startDamping() {
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepDamping))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    private func stopDamping() {
        displayLink?.invalidate()
        displayLink = nil
        displayVelocity = 0
    }

    /// V0.0.33 速度弹簧积分器（AevonRingSpringV33）。
    /// 加速度 = 刚度 × 位移 − 阻尼 × 速度；半隐式欧拉积分，60/120Hz 自适应 dt。
    ///
    /// V0.3.18（AevonSpringUnifyV318）：系数不再是一组孤立的 140/16，改由
    /// `AevonSpring.coefficients(response:dampingFraction:)` 从 (0.45, 0.68) 换算 ——
    /// 与划过 / 入场 / 收起是同一条 ζ 谱。140/16 等价于 (0.531, 0.676)，数值接近但
    /// 换算基准不同；统一之后「拖着转」与「划过去」的收尾是同一个劲儿。
    /// k = (2π/0.45)² ≈ 195、c = 2×0.68×2π/0.45 ≈ 19。
    private static let spinSpring = AevonSpring.coefficients(response: 0.45, dampingFraction: 0.68)

    @objc private func stepDamping() {
        guard AevonRingMenu.current === self, !isDismissing else {
            stopDamping()
            return
        }
        let diff = rotation - displayRotation
        if abs(diff) <= 0.05 && abs(displayVelocity) <= 0.4 {
            displayRotation = rotation
            displayVelocity = 0
            layoutIcons(displayRotation)
            stopDamping()
            return
        }
        // dt 用 displayLink 真实帧间隔（秒），120Hz 设备上步长减半，手感一致
        let dt = CGFloat(displayLink?.duration ?? (1.0 / 60.0))
        let stiffness: CGFloat = AevonRingMenu.spinSpring.stiffness
        let damping: CGFloat = AevonRingMenu.spinSpring.damping
        let accel = stiffness * diff - damping * displayVelocity
        displayVelocity += accel * dt
        displayRotation += displayVelocity * dt
        layoutIcons(displayRotation)
    }

    // MARK: - 动画

    private func animateIn() {
        dimView.alpha = 0
        trackLayer.opacity = 0
        centerButton.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        centerButton.alpha = 0
        centerGlyph.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        centerGlyph.alpha = 0
        // V0.2.10（AevonRingHubV210）：底盘比按钮早一点淡入、放大到位，视觉上「按钮从盘里长出来」
        hubPlate.alpha = 0
        hubInner.alpha = 0
        hubPlate.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
        hubInner.transform = CGAffineTransform(scaleX: 0.70, y: 0.70)

        UIView.animate(withDuration: 0.16, animations: {
            self.dimView.alpha = 1
            self.centerButton.alpha = 1
            self.centerButton.transform = .identity
            self.centerGlyph.alpha = 1
            self.centerGlyph.transform = .identity
        })
        UIView.animate(withDuration: 0.26, delay: 0.02, options: [.curveEaseOut], animations: {
            self.hubPlate.alpha = 1
            self.hubInner.alpha = 1
            self.hubPlate.transform = .identity
            self.hubInner.transform = .identity
        }, completion: nil)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.26
        trackLayer.add(fade, forKey: "fade")
        trackLayer.opacity = 1

        // V0.0.30（AevonRingSpringV30）：图标从圆心「弹射」到各自轨道。
        // V0.3.18（AevonSpringUnifyV318）：换成与划过同一条 ζ 谱 ——
        // 以前是 `UISpringTimingParameters(dampingRatio: 0.55)` + duration 0.55（老式的
        // 「百分比阻尼 + 总时长」组合），和划过那条（ζ 0.34）不是一套手感。
        // 现在 response 0.50 / ζ = 用户的滑条值（默认 0.72），入场的过冲量也跟着滑条走。
        let spring = AevonSpring.params(response: 0.50,
                                        dampingFraction: hoverZ,
                                        initialVelocity: CGVector(dx: 0.25, dy: 0.25))
        for (index, icon) in icons.enumerated() {
            let target = icon.center
            icon.center = ringCenter
            icon.alpha = 0
            icon.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            let animator = UIViewPropertyAnimator(duration: 1.0, timingParameters: spring)
            animator.addAnimations {
                icon.alpha = 1
                icon.transform = .identity
                icon.center = target
            }
            animator.startAnimation(afterDelay: 0.02 + 0.018 * Double(index))
        }
    }

    /// V0.2.88（AevonRingDismissInstantV288）：选中开窗路径必须**瞬时收起**。
    ///
    /// Aevon(61)「打开悬浮窗时依旧会先闪一下，然后出现悬浮窗」取证：选中后走的是
    /// 弹簧收拢 0.3s + 整体淡出 0.18s + **再等 0.18s 才 launchAndOpen** —— 用户看到
    /// 「圆盘消散（闪一下）→ 约 1 秒空档 → 悬浮窗出现」。显形链 0.2.87 已全部瞬时化
    /// 之后，圆盘收起动画就是开窗前屏幕上最后一个过渡，它就是把「从虚到实」的观感
    /// 递给用户的最后一人。选中 = 用户已经做出决定，动画没有信息量，纯负资产。
    /// 抬手未选中 / 旋转松手等被动收起保留原动画（那里动画有「回到桌面」的连续感）。
    private func dismiss(instant: Bool = false) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        isDismissing = true
        // V0.2.66（AevonRingIdleV266）：静默看门狗随圆盘一起停。
        idleWatch?.invalidate()
        idleWatch = nil
        // V0.2.8（AevonRingDismissNoTouchV208）：收起决定一做出就立刻断触摸 ——
        // 0.18 秒淡出动画期间这个全屏视图不再截住任何点击（Aevon(94) 用户
        // 「桌面无法操作」的最坏情况兜底：动画 completion 万一没跑，触摸通道也已还清）。
        isUserInteractionEnabled = false
        cancelCenterHold()
        clearPointer()
        stopDamping()
        /* V0.3.18（AevonSpringUnifyV318）：收起时先把划过动画停在当前值，再让「吸附回圆心」
         * 接管这批 transform —— 两个 animator 同时写 transform 会互相打断，收起来一顿一顿。 */
        if let hovering = hoverAnimator {
            if hovering.isRunning {
                hovering.stopAnimation(false)
                hovering.finishAnimation(at: .current)
            }
            hoverAnimator = nil
        }
        AevonRingMenu.current = nil
        // V0.2.50（AevonRingGripV250）：圆盘收起 → 把手重新露出来
        AevonRingGrip.setVisible(true)
        // V0.0.24：立刻解除「吞掉那根手指」的接管，把事件通道还给 App
        AevonEdgeEntry.ringDidDismiss()
        // V0.2.88（AevonRingDismissInstantV288）：瞬时档 —— 零动画直接摘除。
        if instant {
            removeFromSuperview()
            AevonLog.info("[圆盘] 选中收起：瞬时摘除，无弹簧无淡出（AevonRingDismissInstantV288）")
            return
        }
        // V0.0.30：图标被圆心「吸」回来（弹簧收拢），比整体淡出更有生命感
        // V0.3.18（AevonSpringUnifyV318）：同一条 ζ 谱里收得最紧的一档（response 0.32 / ζ 0.85）——
        // 收起是「决定已经做完」，不需要回摆，只要不硬切。
        let spring = AevonSpring.params(response: 0.32,
                                        dampingFraction: max(hoverZ, 0.85),
                                        initialVelocity: CGVector(dx: 0.30, dy: 0.30))
        for icon in icons {
            let animator = UIViewPropertyAnimator(duration: 1.0, timingParameters: spring)
            animator.addAnimations {
                icon.center = self.ringCenter
                icon.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                icon.alpha = 0
            }
            animator.startAnimation()
        }
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 0
            self.centerButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            self.centerGlyph.alpha = 0
            self.hubPlate.alpha = 0
            self.hubInner.alpha = 0
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    // MARK: - 统一指针处理（V0.0.28）
    //
    // 唤出圆盘的那根手指（global / strip / window）与事后新按的手指（local）
    // 走完全相同的状态机，只是 source 不同 —— 这样「手指不用抬起就能选图标」。
    //
    // 两种模式：
    //   · 选择（默认）：指到哪个图标高亮哪个，松手开窗；
    //   · 旋转（圆心按住 1 秒进入）：顺 / 逆时针都跟手转，期间除了圆心都不能选。

    /// 圆盘被呼出时立刻调用，`point` 是窗口坐标。
    func beginRemoteTracking(at point: CGPoint, source: String) {
        handlePointerBegan(at: point, source: source)
    }

    func remoteMoved(to point: CGPoint, source: String, authoritative: Bool = false) {
        handlePointerMoved(to: point, source: source, authoritative: authoritative)
    }

    func remoteEnded(at point: CGPoint, source: String) {
        handlePointerEnded(at: point, source: source)
    }

    /// V0.3.16（AevonOwnLiftV316）：**权威抬手** —— 来自召唤那根手指所属的识别器。
    ///
    /// 与 `remoteEnded` 的唯一差别：不过 `claimPointer` 的「原通道静默 ≥0.12s」交换闸。
    /// 那道闸是为「指针从一条喂料通道换到另一条」设计的（两条通道报的坐标有差值，
    /// 必须确认原通道已死才敢抢）。抬手帧不属于这个场景：它就是这根手指的终点，
    /// 谁先到谁说了算 —— 被闸吞掉只会让圆盘多钉 1 秒。
    func remoteLift(at point: CGPoint, source: String) {
        handlePointerEnded(at: point, source: source, authoritative: true)
    }

    func remoteCancelled(source: String) {
        handlePointerCancelled(source: source)
    }

    /// V0.0.29：当前是否有活动指针（与 `handlePointerBegan` 的去重判定同口径）。
    /// 圆盘展开期间，新落下的手指只有在没有活动指针时才接管为当前指针。
    var isPointerActive: Bool {
        return !pointerSource.isEmpty &&
               CACurrentMediaTime() - pointerLastEventAt < AevonRingMenu.pointerStaleInterval
    }

    /// 这条通道现在能不能代表当前指针；能就直接通过，不能就按静默时长决定要不要交接。
    ///
    /// V0.2.16（AevonRingPointerHandoffV216）：**指针不能死绑在一条通道上。**
    ///
    /// Aevon(102) 的账（15 次呼盘：`systemgesture` 9 / `appedge` 4 / `strip` 2）：
    /// 呼盘时把指针绑成呼盘来源的字符串，但 `systemgesture` 那个字符串在这一版**没有
    /// 任何活着的喂料方** —— 唯一用它的 `AevonSystemGestureV105` 早在 0.1.13 就停手了
    /// （探针 P7-4 的「愿接=0」就是它）。于是那 9 次呼盘之后：
    ///   · 手指继续往圆心滑 → 一条 moved 都进不来，图标不高亮也不旋转 = 「选不中」；
    ///   · 抬手 → ended 也进不来 → 指针一直挂在圆盘上，只能等 1.2 秒超时后
    ///     由下一次触摸（圆盘自己的 `touchesBegan`）接管 = 「必须抬手再摸一次」。
    ///
    /// 现在：原通道静默 ≥0.12 秒就允许另一条通道接手，并**重设角度基线**
    /// （两条通道报的坐标有差，不重设会被算成一次旋转，圆盘会跳一下）。
    /// 原通道一直在动就抢不走，所以「同一次滑动被算两遍」的去重语义没丢。
    private func claimPointer(source: String, at point: CGPoint) -> Bool {
        let now = CACurrentMediaTime()
        if pointerSource == source { return true }
        let silence = now - pointerLastEventAt
        if !pointerSource.isEmpty, silence < AevonRingMenu.pointerHandoffInterval { return false }
        let previous = pointerSource
        pointerSource = source
        pointerPoint = point
        pointerAngle = angle(from: ringCenter, to: point)
        pointerLastEventAt = now
        // V0.2.18（AevonRingFingerDownV218）：换通道继续喂，说明这根手指还在屏上。
        isFingerDown = true
        if isInsideRingArea(point) { pointerEverInsideRing = true }
        if !previous.isEmpty, now - pointerHandoffLogAt > 0.5 {
            pointerHandoffLogAt = now
            AevonLog.info("[圆盘] 指针通道交接 \(previous) → \(source)（原通道已静默 \(Int(silence * 1000))ms，重设角度基线、不产生旋转）（AevonRingPointerHandoffV216）")
        }
        return true
    }

    private func handlePointerBegan(at point: CGPoint, source: String) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        let now = CACurrentMediaTime()
        // 上一根手指还在操作就忽略新的（超时视为通道漏发 ended，允许新手指接管）
        if !pointerSource.isEmpty, now - pointerLastEventAt < AevonRingMenu.pointerStaleInterval {
            return
        }
        pointerSource = source
        pointerPoint = point
        pointerAngle = angle(from: ringCenter, to: point)
        pointerLastEventAt = now
        isFingerDown = true
        pointerEverInsideRing = isInsideRingArea(point)
        // 新手指落下来，重新允许「按住圆心 1 秒」切换模式
        centerHoldSuppressed = false
        if rotating {
            setHovered(nil)
        } else {
            setHovered(icon(at: point))
        }
        updateCenterHold(at: point)
    }

    private func handlePointerMoved(to point: CGPoint, source: String,
                                    authoritative: Bool = false) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        if authoritative {
            /* V0.3.17（AevonOwnFeedV317）：权威喂料 —— 坐标来自**持有这根手指的识别器**。
             *
             * 为什么可以不过交换闸：`claimPointer` 的 0.12 秒静默要求是给「两根手指经
             * 两条喂料通道换车道」用的。识别器与手指一对一，它报的坐标不需要旁证。
             * Aevon(94) 里 9 次成功交接时刻全部落在 120/123/124/128ms —— 正好是那道闸，
             * 也就是说每次展开都必然先盲 0.12 秒；手指在这段时间里停下，这一次就永久失明。
             *
             * 通道名变了要重设角度基线：两条通道报的坐标有差值，不重设会被算成一次
             * 旋转（指针轻轻一动圆盘就转一下）。 */
            if pointerSource != source {
                pointerSource = source
                pointerAngle = angle(from: ringCenter, to: point)
            }
        } else {
            guard claimPointer(source: source, at: point) else { return }
        }
        pointerPoint = point
        pointerLastEventAt = CACurrentMediaTime()
        isFingerDown = true
        if isInsideRingArea(point) { pointerEverInsideRing = true }

        let currentAngle = angle(from: ringCenter, to: point)
        var delta = currentAngle - pointerAngle
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        pointerAngle = currentAngle

        if rotating {
            // 旋转模式：顺时针 / 逆时针都跟手转；画面上不选中任何图标。
            // V0.0.30：不直接贴手指角度，走阻尼追赶（图标有「韧劲」的跟随感）
            if abs(delta) > 0.01 {
                rotation += delta
                startDamping()
            }
            setHovered(nil)
        } else {
            setHovered(icon(at: point))
        }
        // 手指离开圆心就解除「刚切换过」的抑制，也取消还没到 1 秒的计时
        if !isInsideCenter(point) { centerHoldSuppressed = false }
        updateCenterHold(at: point)
    }

    /// 手指**离开屏幕**。圆盘收不收，全部在这一处决定（V0.2.18 / AevonRingCloseOnLiftV218）。
    ///
    /// 用户 Aevon(104) 把规则讲清楚了，这里逐条对上：
    ///   · 滑出圆盘但手指没离开屏幕 → **什么都不做**（不叫「在圆盘外」，不许收）；
    ///   · 抬手时在盘外 → 收；
    ///   · 抬手时落在图标之间的**间隙**里（盘内但没有图标）→ 收；
    ///   · 抬手时正好在图标上 → 用浮窗打开它；
    ///   · 抬手时在圆心 → 打开应用面板。
    /// 换句话说：**只有抬手这一件事会收起圆盘**（加上选中开窗、圆心面板、三指急救三条显式路径）。
    private func handlePointerEnded(at point: CGPoint, source: String,
                                    authoritative: Bool = false) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        /* V0.3.16（AevonOwnLiftV316）：`authoritative == true` 只由自建识别器腿的抬手
         * 回调传入（`remoteLift`）。识别器与手指是一对一的，它报的抬手不需要任何
         * 「原通道静默时长」旁证 —— 那道 0.12s 闸是给「指针换喂料通道」用的
         * （两条通道坐标有差值，必须确认原通道已死），抬手帧套上去只会被静默吞掉。
         * Aevon(93) 的 16 次「圆盘钉住 1 秒」全部落在这一条上。 */
        if !authoritative {
            if !claimPointer(source: source, at: point) {
                /* V0.3.16（AevonOwnLiftV316）：被交换闸拒 = 抬手帧到了但通道没换过来。
                 * 以前这里是静默 return，Aevon(93) 那 16 次「圆盘钉住 1 秒」在日志上
                 * 完全空白，分不清到底是「ended 没到」还是「到了被拒」。留这一条，
                 * 下一份日志一眼可判；限流 0.5s 防刷。 */
                let now = CACurrentMediaTime()
                if now - AevonRingMenu.lastLiftRejectLogAt > 0.5 {
                    AevonRingMenu.lastLiftRejectLogAt = now
                    let silence = pointerLastEventAt > 0
                        ? Int((now - pointerLastEventAt) * 1000) : -1
                    AevonLog.info("[圆盘] 抬手帧被通道交换闸拒（来源 \(source)，"
                        + "当前指针 \(pointerSource.isEmpty ? "空" : pointerSource)，"
                        + "静默 \(silence)ms）→ 圆盘只能等看门狗（AevonOwnLiftV316）")
                }
                return
            }
        }
        cancelCenterHold()
        pointerPoint = point
        if isInsideRingArea(point) { pointerEverInsideRing = true }
        // 取证用：这根手指这一次有没有进过盘内（0.2.17 起不再影响「收不收」，
        // 只写进日志 —— 用户报「刚划出来就没了」时，靠它区分是抬手太早还是触发太晚）
        let everInside = pointerEverInsideRing
        let landing = isInsideRingArea(point) ? "盘内" : "盘外"
        clearPointer()

        // ① 旋转模式：按在圆心松手 = 退出旋转；其余一律收起（与选择模式同一条规则）
        if rotating {
            if isInsideCenter(point) {
                setRotating(false, at: point)
                AevonLog.info("[圆盘] 圆心松手，退出旋转模式，回到选图标（AevonRingHoldRotateV28）")
                return
            }
            AevonLog.info("[圆盘] 旋转中松手（\(landing)，来源 \(source)），收起圆盘（AevonRingCloseOnLiftV218）")
            setHovered(nil)
            dismiss()
            return
        }

        // ② 选择模式：落在图标上就开窗
        if let icon = icon(at: point) {
            setHovered(nil)
            activate(icon)
            return
        }

        // ③ 落在圆心：打开完整面板（V0.0.30 起面板只显示可开浮窗的 App）
        if isInsideCenter(point) {
            AevonLog.info("[圆盘] 圆心被点击，打开应用面板")
            dismiss()
            AevonEdgeEntry.openPanel()
            return
        }

        // ④ 落在盘外、或落在盘内图标之间的间隙：**一律收起**
        //
        // 0.0.28 ~ 0.2.16 这里是「从没进过圆盘（就是唤出圆盘那一下）→ 圆盘保持展开等下一次触摸」
        // （旧标记 AevonRingKeepOpenV28，0.2.17 起作废）。用户 Aevon(103) 的结论很直接：
        // 松开就该收起 —— 圆盘的用法是「按住不松、直接滑到图标上再松手」（0.2.16 的
        // 指针通道交接就是为了这条路），没松手就不该有第二个状态。
        // 留着「保持展开」只有一个后果：呼盘那一下抬起，屏上多一个必须再点一次才消失的圆盘。
        //
        // Aevon(104) 补充的语义（本版写进日志，免得再猜）：**只有抬手才会收**。
        // 呼盘那一刻手指贴在右缘、离圆心一百多 pt（本来就在盘外），这不叫「手指在圆盘外」；
        // 手指继续按着往盘里滑的整段过程，圆盘一动不动，直到抬手才判定。
        AevonLog.info("[圆盘] 抬手未选中（\(landing)·间隙，来源 \(source)，进过盘内=\(everInside ? "是" : "否")），收起圆盘（AevonRingLiftDismissV217 AevonRingCloseOnLiftV218）")
        setHovered(nil)
        dismiss()
    }

    private func handlePointerCancelled(source: String) {
        if source != pointerSource {
            // 不是当前指针那条通道报的取消：只有原通道已经静默（它死了）才顺手清，
            // 否则会误清一条还在动的指针。
            guard CACurrentMediaTime() - pointerLastEventAt >= AevonRingMenu.pointerHandoffInterval else { return }
        }
        cancelCenterHold()
        clearPointer()
        // V0.2.18（AevonRingCloseOnLiftV218）：**取消 ≠ 抬手**。
        //
        // 取消是「这条通道不投了」的意思（系统手势识别器被别的识别器抢走、App 切后台…），
        // 手指通常还压在屏幕上。把它当成抬手，等于让三个定时器重新获得「替圆盘收」的权力，
        // 用户看到的就是「我手指没离开，圆盘自己收了」。这里保留「手指在屏上」的判断，
        // 真正的收尾交给 30 秒静默安全网，或者下一根手指的 touchesBegan。
        isFingerDown = true
    }

    private func clearPointer() {
        pointerSource = ""
        pointerEverInsideRing = false
        pointerLastEventAt = 0
        // V0.2.18（AevonRingFingerDownV218）：指针没了 = 这根手指已经离开屏幕（或圆盘已收起）。
        // 外面三个定时器看到这一位变假，才会重新使用「强制收起」这一档。
        isFingerDown = false
    }

    // MARK: - 圆心按住 1 秒：开 / 关旋转模式

    private func distanceToCenter(_ point: CGPoint) -> CGFloat {
        let dx = point.x - ringCenter.x
        let dy = point.y - ringCenter.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func isInsideCenter(_ point: CGPoint) -> Bool {
        return distanceToCenter(point) <= AevonRingMenu.centerHitRadius
    }

    /// 圆盘的外沿（最外圈半径 + 图标半宽 + 一点余量）—— 走出这个范围的松手算「取消」
    private var ringOuterLimit: CGFloat {
        let outer = ringRadii.max() ?? 62
        return outer + AevonRingMenu.iconSize / 2 + 20
    }

    private func isInsideRingArea(_ point: CGPoint) -> Bool {
        return distanceToCenter(point) <= ringOuterLimit
    }

    private func updateCenterHold(at point: CGPoint) {
        guard !centerHoldSuppressed else {
            cancelCenterHold()
            return
        }
        if isInsideCenter(point) {
            if centerHoldTimer == nil { scheduleCenterHold() }
        } else {
            cancelCenterHold()
        }
    }

    private func scheduleCenterHold() {
        cancelCenterHold()
        let timer = Timer(timeInterval: AevonRingMenu.centerHoldDuration, repeats: false) { [weak self] _ in
            guard let self = self, AevonRingMenu.current === self, !self.isDismissing else { return }
            self.centerHoldTimer = nil
            guard self.isInsideCenter(self.pointerPoint) else { return }
            // 切换后必须先离开圆心（或重新按下）才能再切一次，避免按着不动来回抖
            self.centerHoldSuppressed = true
            let turnOn = !self.rotating
            self.setRotating(turnOn, at: self.pointerPoint)
            AevonLog.info("[圆盘] 圆心按住 1 秒 → \(turnOn ? "进入旋转模式（顺 / 逆时针都能转）" : "退出旋转模式（可以选图标）")（AevonRingHoldRotateV28）")
        }
        // 手指按住时 RunLoop 处于 tracking 模式，必须挂 common modes
        RunLoop.main.add(timer, forMode: .common)
        centerHoldTimer = timer
    }

    private func cancelCenterHold() {
        centerHoldTimer?.invalidate()
        centerHoldTimer = nil
    }

    private func setRotating(_ on: Bool, at point: CGPoint?) {
        guard rotating != on else { return }
        rotating = on
        updateCenterAppearance()
        if on {
            pulseRotationFeedback()
            setHovered(nil)
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 0.86, 1.0]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 0.3
        centerButton.layer.add(pulse, forKey: "centerPulse")
        if let point = point, !isInsideCenter(point) {
            setHovered(icon(at: point))
        } else {
            setHovered(nil)
        }
    }

    /// 圆心按钮外观：蓝 + 四宫格 = 选择模式；青绿 + 旋转箭头 = 旋转模式。
    /// 屏幕上没有文字，这个颜色 / 图标就是**唯一的模式指示**。
    private func updateCenterAppearance() {
        let config = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        let name = rotating ? "arrow.triangle.2.circlepath" : "square.grid.2x2.fill"
        if let symbol = UIImage(systemName: name, withConfiguration: config) {
            // V0.2.11（AevonRingGlyphTopV211）：换的是独立图标层，不是按钮的 image
            centerGlyph.image = symbol
        }
        centerGlyph.tintColor = .white
        // V0.2.10（AevonRingHubV210）：底色改由渐变层承担，这里换的是渐变的两个端点。
        let top = rotating
            ? UIColor(red: 0.26, green: 0.88, blue: 0.74, alpha: 0.98)
            : UIColor(red: 0.30, green: 0.66, blue: 1.00, alpha: 0.98)
        let bottom = rotating
            ? UIColor(red: 0.05, green: 0.52, blue: 0.44, alpha: 0.98)
            : UIColor(red: 0.07, green: 0.36, blue: 0.88, alpha: 0.98)
        centerGradient.colors = [top.cgColor, bottom.cgColor]
        hubInner.layer.borderColor = (rotating
            ? UIColor(red: 0.25, green: 0.92, blue: 0.78, alpha: 0.40).cgColor
            : UIColor(white: 1.0, alpha: 0.10).cgColor)
        centerButton.layer.shadowColor = (rotating
            ? UIColor(red: 0.20, green: 0.95, blue: 0.80, alpha: 1.0)
            : UIColor.black).cgColor
        centerButton.layer.shadowOpacity = rotating ? 0.75 : 0.45
    }

    /// 进入旋转模式的反馈：一圈涟漪 + 轻度触感 + 圆心轻微放大。
    private func pulseRotationFeedback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        guard let radius = ringRadii.first, radius > 0 else { return }
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.path = UIBezierPath(arcCenter: ringCenter,
                                 radius: radius,
                                 startAngle: 0,
                                 endAngle: .pi * 2,
                                 clockwise: true).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(red: 0.25, green: 0.92, blue: 0.78, alpha: 1.0).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        layer.addSublayer(ring)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0]
        fade.keyTimes = [0, 0.22, 1]
        fade.duration = 0.55
        ring.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ring.removeFromSuperlayer()
        }

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.18, 1.0]
        pop.keyTimes = [0, 0.45, 1]
        pop.duration = 0.34
        centerButton.layer.add(pop, forKey: "centerPop")
    }

    /// 高亮「松手就会打开」的那个图标。
    ///
    /// V0.0.25 起**屏幕上不再出现任何文字**——选中只靠放大 + 蓝色描边 + 蓝色光晕，
    /// 旋转模式下则完全不选中（`rotating` 时调用方只传 nil）。
    /// V0.3.17（AevonHoverTrackV317）：当前高亮的 App。
    ///
    /// 单独存一份而不是「问图标自己」，是因为这里要判的是**状态切换**：`setHovered`
    /// 每帧都会调一次，只有真的换了一个图标才是用户看得见的「划过」。
    private var hoveredBundleID = ""

    /// V0.3.18（AevonSpringUnifyV318）：划过动画的**唯一** animator（见 `startHoverAnimation`）。
    private var hoverAnimator: UIViewPropertyAnimator?

    /// 本次展开的阻尼比。在 `present` 里读一次缓存 —— `AevonPrefs` 走 CFPreferences，
    /// 是跨进程 IPC，放进 `setHovered` 这种逐帧路径会拖慢触摸响应。
    var hoverZ: Double = AevonSpring.defaultDampingFraction

    private func setHovered(_ icon: AevonRingIcon?) {
        let newID = icon?.bundleID ?? ""
        let changed = newID != hoveredBundleID
        if changed {
            hoveredBundleID = newID
            /* V0.3.17（AevonHoverTrackV317）：只在**高亮真的换了**时打一条。
             * 这条日志是本版唯一的验收判据 —— 上一份日志分不清「移动帧到了但没高亮」
             * 和「移动帧根本没到」，因为两者在日志上都只剩一片空白。现在：
             * 有「划过 X」= 喂料与高亮都通了；只有「喂盘 N 帧」没有「划过」= 帧到了
             * 但坐标永远落在图标外（那是几何/命中问题，不是喂料问题）。 */
            if let icon = icon {
                let d = distanceToCenter(pointerPoint)
                var a = angle(from: ringCenter, to: pointerPoint).truncatingRemainder(dividingBy: 360)
                if a < 0 { a += 360 }
                AevonLog.info("[圆盘] 划过 \(icon.displayName)（离圆心 \(Int(d))pt，角度 \(Int(a))°）"
                    + "→ 高亮 + 跳跃（AevonHoverTrackV317）")
            }
        }
        /* V0.3.18（AevonSpringUnifyV318）：高亮集合没变就**一个字都不动**。
         * 以前是「每个图标各自判断 transform != target 再起动画」，在划过中途新动画与
         * 旧动画并存；这里改成整盘一条弹道，没换图标时重启只会把弹簧按回第 0 帧，
         * 表现是一顿一顿。 */
        if !changed && hoverAnimator != nil { return }
        // 展开后的首帧（还没划过任何图标）不必启动动画：全场本来就都是 identity。
        if !changed && hoverAnimator == nil && icon == nil { return }
        startHoverAnimation(highlighting: icon)
    }

    /// V0.3.18（AevonSpringUnifyV318）：**一条弹道带动全部图标** —— 旧高亮回落与
    /// 新高亮升起在同一个 animator 里、用同一条弹簧，这是「连续感」的来源。
    ///
    /// 切换高亮时先把现有 animator 停在当前值（`stopAnimation(false)` +
    /// `finishAnimation(at: .current)`），再从定格处重新出发。这正是 SwiftUI 在目标
    /// 变化时的 retarget 行为（也就是它 `blendDuration` 想解决的问题）：画面永远是
    /// 「从此刻的位置接着弹」，不会跳回起点重来。
    private func startHoverAnimation(highlighting icon: AevonRingIcon?) {
        if let anim = hoverAnimator {
            if anim.isRunning {
                anim.stopAnimation(false)
                anim.finishAnimation(at: .current)
            }
            hoverAnimator = nil
        }
        // V0.0.35（AevonRingHopV35）：划过图标 = 放大 + **向上跳跃**。
        // 位移用屏幕坐标向上（y 负），与圆周角度无关，任何位置的图标都是「向上跳」。
        let params = AevonSpring.params(response: AevonRingMenu.hoverSpringResponse,
                                        dampingFraction: hoverZ)
        let animator = UIViewPropertyAnimator(duration: 1.0, timingParameters: params)
        animator.addAnimations {
            for item in self.icons {
                let on = (item === icon)
                /* V0.3.18：高亮（边框 / 光晕 / 底色）也放进同一条弹道。
                 * 以前它在动画块外、瞬时生效 —— 图标放大是弹簧、边框是硬切，
                 * 快划时就看见「框先跳、块后弹」。layer 属性在
                 * UIViewPropertyAnimator 的动画块内会被一并驱动。 */
                item.setHighlighted(on)
                if on {
                    item.transform = CGAffineTransform(translationX: 0, y: -AevonRingMenu.hoverLift)
                        .scaledBy(x: AevonRingMenu.hoverScale, y: AevonRingMenu.hoverScale)
                } else {
                    item.transform = .identity
                }
            }
        }
        hoverAnimator = animator
        animator.startAnimation()
    }

    // MARK: - 本地触摸（第二根手指 / 抬手后再按）

    /// V0.2.69（AevonRingIdleFixV269）：UIKit 层活跃触摸计数 —— 静默看门狗的
    /// 「ended 真漏发」实判。touches 家族是 UIResponder 硬通道（指针喂料通道
    /// 会漏最后一报，UIKit 不会），计数为 0 = 手指真不在圆盘上。
    private var uiKitTouchCount = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        uiKitTouchCount += touches.count
        guard let point = touches.first?.location(in: self), !isDismissing else { return }
        handlePointerBegan(at: point, source: "local")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !isDismissing else { return }
        handlePointerMoved(to: point, source: "local")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        uiKitTouchCount = max(0, uiKitTouchCount - touches.count)
        guard !isDismissing else { return }
        let point = touches.first?.location(in: self) ?? pointerPoint
        handlePointerEnded(at: point, source: "local")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        uiKitTouchCount = 0
        handlePointerCancelled(source: "local")
    }

    // MARK: - 选中开窗

    private func activate(_ icon: AevonRingIcon) {
        let bundleID = icon.bundleID
        // V0.2.62（AevonQuickActionV262）：截图 / 录屏不是 App，直接执行动作，不开窗。
        if AevonQuickAction.isAction(bundleID) {
            AevonLog.info("[圆盘] 选中 \(icon.displayName) (\(bundleID))，执行快捷动作并收起圆盘"
                + "（AevonQuickActionV262）")
            icon.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            AevonEdgeEntry.noteSelectionCooldown()
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                AevonQuickAction.perform(bundleID: bundleID)
            }
            return
        }
        AevonLog.info("[圆盘] 选中 \(icon.displayName) (\(bundleID))，打开浮窗并收起圆盘")
        icon.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        // V0.2.8（AevonSelectionCoolV208）：选中后 1.5 秒内 global 兜底不呼盘 ——
        // Aevon(94) 21:53:45 实证：选中开窗后 0.65 秒同一根手指的移动又呼了一次盘。
        AevonEdgeEntry.noteSelectionCooldown()
        // V0.2.88（AevonRingDismissInstantV288）：收起瞬时化 + 开窗不再等 0.18s。
        // 原来「弹簧 0.3s + 淡出 0.18s + 延迟 0.18s 才开窗」= 用户看到的
        // 「先闪一下（圆盘消散），空档约 1 秒，然后悬浮窗才出现」。防重复呼盘
        // 由 noteSelectionCooldown 的 1.5s 冷却继续兜底，0.18s 延迟没有第二个职责。
        dismiss(instant: true)
        AevonWindowManager.launchAndOpen(bundleID: bundleID)
    }

    // MARK: - 几何工具

    /// 命中哪个图标：先按角度找该圈上最近的一个，再校验弧长距离。
    private func icon(at point: CGPoint) -> AevonRingIcon? {
        guard !icons.isEmpty else { return nil }
        let dx = point.x - ringCenter.x
        let dy = point.y - ringCenter.y
        let distance = (dx * dx + dy * dy).squareRoot()
        var pointAngle = atan2(dy, dx) * 180 / .pi
        if pointAngle < 0 { pointAngle += 360 }

        var best: AevonRingIcon?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for (index, icon) in icons.enumerated() {
            guard index < iconRadii.count, index < iconBaseAngles.count else { continue }
            let radius = iconRadii[index]
            // 径向容差：半圈间距（至少图标半径）—— V0.0.31 用图标实际尺寸（自适应后各圈不同）
            //
            // V0.2.18（AevonRingHitStableV218）：这里必须用 `bounds`，不能用 `frame`。
            // `frame` 会跟着 transform 变 —— 悬停放大从 1.18 提到 1.30 之后，
            // 被放大的那个图标判定半径会跟着膨胀 30%，隔壁图标会被它抢走，
            // 表现是「手指明明在这个图标上，高亮的却是旁边那个」。
            // `bounds` 不受 transform 影响，永远是布局时的原始尺寸。
            let baseSize = icon.bounds.width
            let tolerance = max(baseSize * 0.78, 28)
            guard abs(distance - radius) <= tolerance else { continue }
            var iconAngle = (iconBaseAngles[index] + rotation).truncatingRemainder(dividingBy: 360)
            if iconAngle < 0 { iconAngle += 360 }
            var delta = abs(iconAngle - pointAngle)
            if delta > 180 { delta = 360 - delta }
            // 角距换算成弧长（pt），再挑最近的
            let arc = delta * .pi / 180 * radius
            if arc < bestScore {
                bestScore = arc
                best = icon
            }
        }
        guard let candidate = best else { return nil }
        return bestScore <= candidate.bounds.width * AevonRingMenu.hitFactor ? candidate : nil
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        return atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }
}
