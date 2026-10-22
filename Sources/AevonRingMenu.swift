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
        let icon = AevonAppIcon.image(bundleID: bundleID, size: size - 4)
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
            iconView.contentMode = .scaleAspectFill
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
///   5. 唤出圆盘的那根手指**不必抬起**：它直接从边缘滑进圆盘就能选图标；
///      它若在盘外抬起，圆盘保持展开等下一次触摸（不再需要「抬手再摸一次」）。
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
    /// 指针事件中断多久之后允许新手指出手接管（自愈，防止某条通道漏发 ended 把圆盘卡死）
    private static let pointerStaleInterval: CFTimeInterval = 1.2
    /// 圆心纵向位置（占屏幕高度比例）
    private static let verticalRatio: CGFloat = 0.75

    private let dimView = UIView()
    private let trackLayer = CAShapeLayer()
    private let centerButton = UIButton(type: .custom)

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
    private var pointerPoint: CGPoint = .zero
    private var pointerAngle: CGFloat = 0
    private var pointerLastEventAt: CFTimeInterval = 0
    /// 这根手指是否进过圆盘范围（区分「唤出圆盘那一下」和「进盘后拖出去取消」）
    private var pointerEverInsideRing = false

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
        host.addSubview(menu)
        host.bringSubviewToFront(menu)
        current = menu
        menu.reload()
        menu.animateIn()
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

        // V0.0.25：圆心只留四宫格图标，不再有任何文字
        // V0.0.26：底部提示文字也一并移除 —— 屏幕上不再出现任何说明文字，
        //          后续用「选中动画」表达状态（用户 Aevon(19) 要求）

        centerButton.frame = CGRect(x: 0, y: 0, width: AevonRingMenu.centerSize, height: AevonRingMenu.centerSize)
        centerButton.backgroundColor = UIColor(red: 0.10, green: 0.48, blue: 0.95, alpha: 0.96)
        centerButton.layer.cornerRadius = AevonRingMenu.centerSize / 2
        centerButton.layer.shadowColor = UIColor.black.cgColor
        centerButton.layer.shadowOpacity = 0.45
        centerButton.layer.shadowRadius = 12
        centerButton.layer.shadowOffset = CGSize(width: 0, height: 3)
        // 圆心图标：四宫格（表示「应用列表 / 面板」）
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        if let symbol = UIImage(systemName: "square.grid.2x2.fill", withConfiguration: symbolConfig) {
            centerButton.setImage(symbol, for: .normal)
            centerButton.tintColor = .white
        } else {
            centerButton.setTitle("A", for: .normal)
            centerButton.setTitleColor(.white, for: .normal)
            centerButton.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .bold)
        }
        // 圆心不接收触摸：由几何判定处理，避免和旋转手势冲突
        centerButton.isUserInteractionEnabled = false
        addSubview(centerButton)
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
                addSubview(icon)
                icons.append(icon)
                iconRadii.append(radius)
                iconBaseAngles.append(-90 + offset + CGFloat(i) * step)
            }
        }

        drawRingTracks()
        layoutIcons()

        // V0.0.26：屏幕上不再有任何提示文字（圆心 / 底部都没有）
        let radiiText = ringRadii.map { String(Int($0)) }.joined(separator: "/")
        let countsText = ringCounts.map(String.init).joined(separator: "/")
        AevonLog.info("[圆盘] 已展开（\(icons.count) 个 App，\(ringCounts.count) 圈，每圈 \(countsText) 个，半径 \(radiiText)，圆心 \(Int(ringCenter.x)),\(Int(ringCenter.y))，间距 46pt 恒定 / 内圈贴中心 62 / 方形图标自适应 / 位置固定记忆 / 速度弹簧跟手 / 弹簧出入场 / 状态位共享内存）（AevonRingFullCircle AevonRingMultiRing AevonRingNativeIconV22 AevonRingAnchor75V21 AevonRingLayoutFitV23 AevonRingCenterTextFreeV24 AevonRingNoLabelV25 AevonRingNoHintV26 AevonRingInnerTightV28 AevonRingHoldRotateV28 AevonRingTwoModeV28 AevonRingDenseV29 AevonRingSpringV30 AevonRingDampV30 AevonRingSquareV31 AevonRingAutoSizeV31 AevonRingPinnedV31 AevonRingSpringV33 AevonNotifyRingV34 AevonRingHopV35）")
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
    /// 手感调参：刚度 140（跟手）/ 阻尼 16（急停过冲约 12%，慢拖黏滞）。
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
        let stiffness: CGFloat = 140
        let damping: CGFloat = 16
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

        UIView.animate(withDuration: 0.16, animations: {
            self.dimView.alpha = 1
            self.centerButton.alpha = 1
            self.centerButton.transform = .identity
        })
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.26
        trackLayer.add(fade, forKey: "fade")
        trackLayer.opacity = 1

        // V0.0.30（AevonRingSpringV30）：图标从圆心「弹射」到各自轨道 ——
        // SwiftUI spring(dampingFraction: 0.55) 的手感等价物：
        // UISpringTimingParameters 弹簧 + 逐个错峰，末端自然过冲回摆（Q 弹感）。
        let spring = UISpringTimingParameters(dampingRatio: 0.55, initialVelocity: CGVector(dx: 0.4, dy: 0.4))
        for (index, icon) in icons.enumerated() {
            let target = icon.center
            icon.center = ringCenter
            icon.alpha = 0
            icon.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            let animator = UIViewPropertyAnimator(duration: 0.55, timingParameters: spring)
            animator.addAnimations {
                icon.alpha = 1
                icon.transform = .identity
                icon.center = target
            }
            animator.startAnimation(afterDelay: 0.02 + 0.018 * Double(index))
        }
    }

    private func dismiss() {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        isDismissing = true
        cancelCenterHold()
        clearPointer()
        stopDamping()
        AevonRingMenu.current = nil
        AevonEdgeEntry.setStripInteraction(true)
        // V0.0.24：立刻解除「吞掉那根手指」的接管，把事件通道还给 App
        AevonEdgeEntry.ringDidDismiss()
        // V0.0.30：图标被圆心「吸」回来（弹簧收拢），比整体淡出更有生命感
        let spring = UISpringTimingParameters(dampingRatio: 0.78, initialVelocity: CGVector(dx: 0.5, dy: 0.5))
        for icon in icons {
            let animator = UIViewPropertyAnimator(duration: 0.3, timingParameters: spring)
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

    func remoteMoved(to point: CGPoint, source: String) {
        handlePointerMoved(to: point, source: source)
    }

    func remoteEnded(at point: CGPoint, source: String) {
        handlePointerEnded(at: point, source: source)
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

    private func handlePointerMoved(to point: CGPoint, source: String) {
        guard AevonRingMenu.current === self, !isDismissing, source == pointerSource else { return }
        pointerPoint = point
        pointerLastEventAt = CACurrentMediaTime()
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

    private func handlePointerEnded(at point: CGPoint, source: String) {
        guard AevonRingMenu.current === self, !isDismissing, source == pointerSource else { return }
        cancelCenterHold()
        pointerPoint = point
        if isInsideRingArea(point) { pointerEverInsideRing = true }
        let everInside = pointerEverInsideRing
        clearPointer()

        // ① 旋转模式：按在圆心松手 = 退出旋转；移到盘外松手 = 收起；其余忽略
        if rotating {
            if isInsideCenter(point) {
                setRotating(false, at: point)
                AevonLog.info("[圆盘] 圆心松手，退出旋转模式，回到选图标（AevonRingHoldRotateV28）")
                return
            }
            if !isInsideRingArea(point) {
                AevonLog.info("[圆盘] 旋转中移到盘外松手，收起圆盘")
                dismiss()
            }
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

        // ④ 盘外松手：进过圆盘 = 取消；从没进过（就是唤出圆盘那一下）= 圆盘保持展开
        if !isInsideRingArea(point), !everInside {
            AevonLog.info("[圆盘] 唤出圆盘的手指已抬起，圆盘保持展开等待选择（AevonRingKeepOpenV28）")
            return
        }
        AevonLog.info("[圆盘] 松手未选中（\(isInsideRingArea(point) ? "空白处" : "盘外")），收起圆盘")
        setHovered(nil)
        dismiss()
    }

    private func handlePointerCancelled(source: String) {
        guard source == pointerSource else { return }
        cancelCenterHold()
        clearPointer()
    }

    private func clearPointer() {
        pointerSource = ""
        pointerEverInsideRing = false
        pointerLastEventAt = 0
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
            centerButton.setImage(symbol, for: .normal)
        }
        centerButton.tintColor = .white
        centerButton.backgroundColor = rotating
            ? UIColor(red: 0.10, green: 0.72, blue: 0.60, alpha: 0.96)
            : UIColor(red: 0.10, green: 0.48, blue: 0.95, alpha: 0.96)
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
    private func setHovered(_ icon: AevonRingIcon?) {
        for item in icons {
            let on = (item === icon)
            item.setHighlighted(on)
            // V0.0.35（AevonRingHopV35）：划过图标 = 放大 1.18 + **向上跳跃 8pt** ——
            // 弹簧阻尼 0.42 + 初速 2.8，跳上去有过冲、回落的吸回感（用户点名要的跳跃动画）。
            // 位移用屏幕坐标向上（y 负），与圆周角度无关，任何位置的图标都是「向上跳」。
            let target: CGAffineTransform
            if on {
                target = CGAffineTransform(translationX: 0, y: -8)
                    .scaledBy(x: 1.18, y: 1.18)
            } else {
                target = .identity
            }
            if item.transform != target {
                UIView.animate(withDuration: 0.45,
                               delay: 0,
                               usingSpringWithDamping: 0.42,
                               initialSpringVelocity: 2.8,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    item.transform = target
                }
            }
        }
    }

    // MARK: - 本地触摸（第二根手指 / 抬手后再按）

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !isDismissing else { return }
        handlePointerBegan(at: point, source: "local")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !isDismissing else { return }
        handlePointerMoved(to: point, source: "local")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isDismissing else { return }
        let point = touches.first?.location(in: self) ?? pointerPoint
        handlePointerEnded(at: point, source: "local")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        handlePointerCancelled(source: "local")
    }

    // MARK: - 选中开窗

    private func activate(_ icon: AevonRingIcon) {
        let bundleID = icon.bundleID
        AevonLog.info("[圆盘] 选中 \(icon.displayName) (\(bundleID))，打开浮窗并收起圆盘")
        icon.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            AevonWindowManager.launchAndOpen(bundleID: bundleID)
        }
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
            let tolerance = max(icon.frame.width * 0.78, 28)
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
        return bestScore <= candidate.frame.width * AevonRingMenu.hitFactor ? candidate : nil
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        return atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }
}
