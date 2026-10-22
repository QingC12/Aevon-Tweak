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

    /// 高亮「松手就会打开」的那个图标
    func setHighlighted(_ highlighted: Bool) {
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
///   · 半径整体 ×0.866（面积 = 原来的 75%），图标 40pt、圆心按钮 48pt；
///   · 圆心按钮是蓝色圆 + 四宫格图标，点它打开完整应用选择面板。
///
/// 交互（用户 2026-10-22 第 19 号日志后定稿：**旋转需要先转半圈解锁**）：
///   1. 右边缘拉出圆盘后**立刻可用**，手指不离开屏幕：
///      **逆时针净转满 180°** → 解锁「跟手旋转」，此后逆时针继续划 = 图标跟着转；
///      （解锁之前怎么划都不会转，避免「选图标时手指一歪就整盘乱转」）
///      **顺时针**滑动 → 停止旋转，进入「等待选择」，手指下的图标放大高亮；
///      原地停住 0.18 秒 → 同样进入「等待选择」。
///   2. 松手：处于「等待选择」且落在图标上 → 用浮窗打开该 App 并收起圆盘；
///      落在空白 → 收起；仍在旋转 → 直接收起（不误开）。
///   3. 圆盘停留期间可以再用手指点图标 / 点圆心 / 点空白。
///   4. **屏幕上没有任何文字**（圆心、底部都没有）—— 选中只靠放大 + 蓝色描边 + 光晕。
///
/// 触摸来源去重：唤出圆盘的那根手指可能同时被「边缘手势条」「窗口 sendEvent 探针」
/// 「全局触摸通道」看到，三条通道都会转发同一个点。这里用 `remoteSource`
/// 只认最先开始的那一条，避免同一次滑动把旋转角度算两遍。
final class AevonRingMenu: UIView {
    private static var current: AevonRingMenu?

    private static let iconSize: CGFloat = 40
    private static let centerSize: CGFloat = 48
    /// 命中半径系数
    private static let hitFactor: CGFloat = 0.95
    /// 判定为「拖动旋转」的最小角度（度）—— 仅用于**已解锁后**的跟手灵敏度
    private static let dragThreshold: CGFloat = 6
    /// 解锁「跟手旋转」所需的逆时针净角度（度）：半圈（V0.0.26）
    ///
    /// 用户 Aevon(19)：原来转 6° 就跟着转，选图标时手指稍一歪圆盘就乱转、经常选错。
    /// 现在必须**净逆时针转满半圈**才认为「用户在转圆盘」，转之前的所有角度都只当选择。
    private static let armAngle: CGFloat = 180
    /// 手指停住多久算「等待选择」
    private static let armDelay: TimeInterval = 0.18
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
    private var ringCenter: CGPoint = .zero
    private var isDismissing = false

    // 本地触摸（第二根手指直接操作）
    private var touchStart: CGPoint?
    private var panStartAngle: CGFloat = 0
    private var panStartRotation: CGFloat = 0
    private var didDrag = false
    private var pressedIcon: AevonRingIcon?
    private var longPressTimer: Timer?

    // 远程触摸（唤出圆盘的那根手指，尚未松手）
    private var remoteSource = ""
    private var remoteLastAngle: CGFloat = 0
    private var remotePoint: CGPoint = .zero
    /// 是否已进入「等待选择」
    private var remoteSelecting = false
    private var armTimer: Timer?

    // 旋转解锁（V0.0.26）
    /// 从呼出那一刻起累积的**净角度**（度，逆时针为负）
    private var netAngle: CGFloat = 0
    /// 是否已解锁「跟手旋转」
    private var rotationArmed = false
    /// 解锁瞬间的角度 / rotation 基准，保证解锁后不跳变
    private var rotationAtArm: CGFloat = 0
    private var netAtArm: CGFloat = 0

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
        longPressTimer?.invalidate()
        armTimer?.invalidate()
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

    /// 各圈半径。V0.0.23：整体缩到原面积的 75%（半径 ×0.866），
    /// 基准 68（原 78）、两圈间距 48（原 56），三圈时间距收到 42 免得外圈顶到边。
    private func radii(forRingCount count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let limit = maxRadius
        if count == 1 { return [min(92, limit)] }
        let base: CGFloat = 68
        let spacing: CGFloat = count >= 3 ? 42 : 48
        return (0..<count).map { min(base + CGFloat($0) * spacing, limit) }
    }

    /// 按总数决定每圈放几个（V0.0.23：**外圈一定比内圈多**）。
    ///
    /// 旧的固定容量 [8, 12, 16] 在 20 个 App 时会排成 8 + 12，
    /// 视觉上内圈挤、外圈松，用户反馈「外圈应该比内圈多」。
    /// 现在按总数动态分配：
    ///   · ≤ 8  ：一圈
    ///   · 9~20 ：两圈，内圈约 38%（20 个 → 8 + 12）
    ///   · ≥ 21 ：三圈，权重 1 : 1.5 : 2（36 个 → 8 + 12 + 16）
    /// 余数优先补给外圈，保证「越外越多」。
    static func distribution(for total: Int) -> [Int] {
        guard total > 0 else { return [] }
        if total <= 8 { return [total] }
        if total <= 20 {
            var inner = Int((CGFloat(total) * 0.38).rounded())
            inner = min(max(inner, 3), 8)
            return [inner, total - inner]
        }
        let weights: [CGFloat] = [1, 1.5, 2]
        var parts = weights.map { Int((CGFloat(total) * $0 / 4.5).rounded(.down)) }
        parts[0] = max(parts[0], 3)
        var rest = total - parts.reduce(0, +)
        // 余数先给外圈，再给中圈
        while rest > 0 {
            parts[2] += 1
            rest -= 1
            if rest > 0 {
                parts[1] += 1
                rest -= 1
            }
        }
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
        ringRadii = radii(forRingCount: ringCounts.count)

        var cursor = 0
        for (ringIndex, count) in ringCounts.enumerated() {
            let radius = ringRadii[ringIndex]
            let step = 360 / CGFloat(max(count, 1))
            // 相邻圈错开半个步进：图标不会在上下方向连成一条直线，视觉更自然
            let offset: CGFloat = (ringIndex % 2 == 1) ? step / 2 : 0
            for i in 0..<count {
                guard cursor < bundleIDs.count else { break }
                let bundleID = bundleIDs[cursor]
                cursor += 1
                let name = AevonWindowManager.title(for: bundleID)
                let icon = AevonRingIcon(bundleID: bundleID, name: name, size: AevonRingMenu.iconSize)
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
        AevonLog.info("[圆盘] 已展开（\(icons.count) 个 App，\(ringCounts.count) 圈，每圈 \(countsText) 个，半径 \(radiiText)，圆心 \(Int(ringCenter.x)),\(Int(ringCenter.y))，面积 75% 外多内少，无任何文字）（AevonRingFullCircle AevonRingMultiRing AevonRingNativeIconV22 AevonRingAnchor75V21 AevonRingLayoutFitV23 AevonRingCounterClockV23 AevonRingCenterTextFreeV24 AevonRingNoLabelV25 AevonRingNoHintV26）")
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

    private func layoutIcons() {
        guard !icons.isEmpty else { return }
        for (index, icon) in icons.enumerated() {
            guard index < iconRadii.count, index < iconBaseAngles.count else { continue }
            let radians = (iconBaseAngles[index] + rotation) * .pi / 180
            let radius = iconRadii[index]
            icon.center = CGPoint(x: ringCenter.x + radius * cos(radians),
                                  y: ringCenter.y + radius * sin(radians))
        }
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

        for (index, icon) in icons.enumerated() {
            icon.alpha = 0
            icon.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            let delay = 0.015 + 0.015 * Double(index)
            UIView.animate(withDuration: 0.32,
                           delay: delay,
                           usingSpringWithDamping: 0.72,
                           initialSpringVelocity: 0.6,
                           options: [.curveEaseOut, .allowUserInteraction]) {
                icon.alpha = 1
                icon.transform = .identity
            }
        }
    }

    private func dismiss() {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        isDismissing = true
        longPressTimer?.invalidate()
        longPressTimer = nil
        armTimer?.invalidate()
        armTimer = nil
        AevonRingMenu.current = nil
        AevonEdgeEntry.setStripInteraction(true)
        // V0.0.24：立刻解除「吞掉那根手指」的接管，把事件通道还给 App
        AevonEdgeEntry.ringDidDismiss()
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha = 0
            for icon in self.icons {
                icon.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
            self.centerButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    // MARK: - 远程触摸（唤出圆盘的那根手指）

    /// 圆盘被呼出时立刻调用，`point` 是窗口坐标。
    /// `source` 用来去重：手势条和窗口探针会同时看到同一根手指，只认最先来的那条。
    func beginRemoteTracking(at point: CGPoint, source: String) {
        remoteSource = source
        remotePoint = point
        remoteLastAngle = angle(from: ringCenter, to: point)
        remoteSelecting = false
        netAngle = 0
        rotationArmed = false
        setHovered(nil)
        scheduleArm()
    }

    func remoteMoved(to point: CGPoint, source: String) {
        guard AevonRingMenu.current === self, !isDismissing, source == remoteSource else { return }
        remotePoint = point
        let currentAngle = angle(from: ringCenter, to: point)
        var delta = currentAngle - remoteLastAngle
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        remoteLastAngle = currentAngle
        netAngle += delta

        // ── 第一阶段：未解锁。只累积逆时针角度，图标一动不动（防误转）──
        if !rotationArmed {
            if netAngle <= -AevonRingMenu.armAngle {
                rotationArmed = true
                rotationAtArm = rotation
                netAtArm = netAngle
                cancelArm()
                pulseUnlockRotation()
                AevonLog.info("[圆盘] 逆时针已累积 \(Int(-netAngle))°，解锁跟手旋转（AevonRingRotateArmV26）")
                return
            }
            if remoteSelecting {
                // 已经在「等待选择」：高亮跟着手指走，换到哪圈哪个图标都行
                setHovered(icon(at: point))
            } else {
                // 手指还在动，重新计时；停住 0.18 秒才进入「等待选择」
                scheduleArm()
            }
            return
        }

        // ── 第二阶段：已解锁。逆时针跟手转，顺时针停转并进入选择 ──
        if delta < -0.5 {
            rotation = rotationAtArm + (netAngle - netAtArm)
            layoutIcons()
            if remoteSelecting {
                remoteSelecting = false
                setHovered(nil)
            }
            scheduleArm()
            return
        }
        if delta > 0.5 {
            cancelArm()
            enterSelecting(at: point)
            return
        }
        // 几乎没有角度变化：已在选择模式就让高亮跟着手指走（同一圈上换图标）
        if remoteSelecting { setHovered(icon(at: point)) }
    }

    /// 松手：选择模式下落在图标上 → 开窗并收起；落在空白 / 仍在旋转 → 收起。
    func remoteEnded(at point: CGPoint, source: String) {
        guard AevonRingMenu.current === self, !isDismissing, source == remoteSource else { return }
        armTimer?.invalidate()
        armTimer = nil
        remotePoint = point

        if remoteSelecting, let icon = icon(at: point) {
            setHovered(nil)
            activate(icon)
            return
        }
        AevonLog.info("[圆盘] 松手未选中（\(remoteSelecting ? "空白处" : "旋转中")），收起圆盘")
        setHovered(nil)
        dismiss()
    }

    func remoteCancelled(source: String) {
        guard source == remoteSource else { return }
        armTimer?.invalidate()
        armTimer = nil
    }

    private func scheduleArm() {
        armTimer?.invalidate()
        let timer = Timer(timeInterval: AevonRingMenu.armDelay, repeats: false) { [weak self] _ in
            guard let self = self, AevonRingMenu.current === self else { return }
            self.enterSelecting(at: self.remotePoint)
        }
        // 手指按住时 RunLoop 处于 tracking 模式，必须挂 common modes
        RunLoop.main.add(timer, forMode: .common)
        armTimer = timer
    }

    private func cancelArm() {
        armTimer?.invalidate()
        armTimer = nil
    }

    private func enterSelecting(at point: CGPoint) {
        remoteSelecting = true
        setHovered(icon(at: point))
    }

    /// 解锁「跟手旋转」的反馈：一圈蓝色涟漪 + 轻度触感。
    ///
    /// 全程没有任何文字（用户要求去掉屏幕上所有提示文案），
    /// 只用一个瞬间的视觉 + 触觉信号告诉用户「现在开始转了」。后续动画可以挂在这里。
    private func pulseUnlockRotation() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let radius = ringRadii.first, radius > 0 else { return }
        let ring = CAShapeLayer()
        ring.frame = bounds
        ring.path = UIBezierPath(arcCenter: ringCenter,
                                 radius: radius,
                                 startAngle: 0,
                                 endAngle: .pi * 2,
                                 clockwise: true).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0).cgColor
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

        // 图标轻轻一弹，视觉上也能看出「已进入旋转」。
        // 用 layer 动画而不是 UIView.transform —— 避免把高亮用的 1.14 缩放覆盖掉。
        let now = CACurrentMediaTime()
        for (index, icon) in icons.enumerated() {
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [1.0, 1.12, 1.0]
            pop.keyTimes = [0, 0.45, 1]
            pop.duration = 0.34
            pop.beginTime = now + 0.005 * Double(index)
            icon.layer.add(pop, forKey: "unlockPop")
        }
    }

    /// 高亮「松手就会打开」的那个图标。
    ///
    /// V0.0.25：**屏幕上不再出现任何「选中的 App 名字」文字**（用户要求）——
    /// 选中状态只靠图标本身的放大 + 蓝色描边 + 蓝色光晕表达（后续再加动画）。
    private func setHovered(_ icon: AevonRingIcon?) {
        for item in icons {
            item.transform = (item === icon) ? CGAffineTransform(scaleX: 1.14, y: 1.14) : .identity
            item.setHighlighted(item === icon)
        }
    }

    // MARK: - 本地触摸（圆盘停留期间直接操作）

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !isDismissing else { return }
        touchStart = point
        panStartAngle = angle(from: ringCenter, to: point)
        panStartRotation = rotation
        didDrag = false
        pressedIcon = icon(at: point)
        if let icon = pressedIcon {
            UIView.animate(withDuration: 0.12) {
                icon.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
            }
            scheduleLongPress(for: icon)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !isDismissing else { return }
        let currentAngle = angle(from: ringCenter, to: point)
        var delta = currentAngle - panStartAngle
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        if !didDrag {
            guard abs(delta) >= AevonRingMenu.dragThreshold else { return }
            didDrag = true
            cancelLongPress()
            if let icon = pressedIcon {
                icon.transform = .identity
                pressedIcon = nil
            }
        }
        rotation = panStartRotation + delta
        layoutIcons()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        guard !isDismissing else { return }
        let point = touches.first?.location(in: self) ?? touchStart ?? .zero
        let start = touchStart ?? point
        touchStart = nil

        if didDrag { return }

        if let icon = pressedIcon {
            icon.transform = .identity
            pressedIcon = nil
            activate(icon)
            return
        }

        // 圆心 = 打开完整面板
        let cdx = start.x - ringCenter.x
        let cdy = start.y - ringCenter.y
        let centerDistance = (cdx * cdx + cdy * cdy).squareRoot()
        if centerDistance <= AevonRingMenu.centerSize * 0.85 {
            AevonLog.info("[圆盘] 圆心被点击，打开应用面板")
            dismiss()
            AevonEdgeEntry.openPanel(preferRingEditing: icons.isEmpty)
            return
        }

        AevonLog.info("[圆盘] 点击空白处，收起圆盘")
        dismiss()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        if let icon = pressedIcon {
            icon.transform = .identity
            pressedIcon = nil
        }
    }

    // MARK: - 长按移除

    private func scheduleLongPress(for icon: AevonRingIcon) {
        cancelLongPress()
        let timer = Timer(timeInterval: 0.7, repeats: false) { [weak self, weak icon] _ in
            guard let self = self, let icon = icon, !self.didDrag else { return }
            self.removeIcon(icon)
        }
        // 手指按住期间 RunLoop 处于 tracking 模式，必须显式挂到 common modes
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func removeIcon(_ icon: AevonRingIcon) {
        AevonLog.info("[圆盘] 长按移除 \(icon.displayName) (\(icon.bundleID))")
        AevonRingStore.remove(icon.bundleID)
        UIView.animate(withDuration: 0.14, animations: {
            icon.alpha = 0
            icon.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        }, completion: { _ in
            self.reload()
        })
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
            // 径向容差：半圈间距（至少图标半径）
            let tolerance = max(AevonRingMenu.iconSize * 0.78, 28)
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
        return bestScore <= AevonRingMenu.iconSize * AevonRingMenu.hitFactor ? candidate : nil
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        return atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }
}
