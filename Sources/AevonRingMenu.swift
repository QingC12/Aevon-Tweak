import UIKit

/// 圆盘上的一个 App 单元（V0.0.21：**只显示文字**，不再请求 App 图标）。
///
/// 为什么去掉图标：真机上 `SBIconController -applicationIconImageForBundleIdentifier:format:scale:`
/// 在 SpringBoard 的某些状态下返回 nil，于是圆盘里全是「首字母彩色圆点」——
/// 既不像图标也不像文字，反而更难认。用户明确要求只显示文字，这里直接改成文字卡片：
/// 深色半透明胶囊 + 白字，字号随字数自适应，视觉上干净且一定能显示出来。
final class AevonRingIcon: UIView {
    let bundleID: String
    var displayName: String

    private let label = UILabel()

    init(bundleID: String, name: String, size: CGFloat) {
        self.bundleID = bundleID
        self.displayName = name
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        backgroundColor = UIColor(white: 0.12, alpha: 0.92)
        isUserInteractionEnabled = false
        layer.cornerRadius = size * 0.26
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 1.0, alpha: 0.16).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)

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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

/// 径向圆盘选择器（V0.0.21：贴手跟动 + 顺时针旋转 / 逆时针选定 + 纯文字）。
///
/// 形态：
///   · 圆心固定在屏幕水平中央、纵向 **75%**（用户两轮要求：65% → 再下移 10%）；
///   · App 按「由内到外」依次放到第 1/2/3 圈，每圈容量 8 / 12 / 16，圈数随数量自动增加；
///   · 圆心按钮是蓝色圆 + 四宫格图标，点它打开完整应用选择面板。
///
/// 交互（用户 2026-10-22 第 14 号日志后定稿）：
///   1. 右边缘拉出圆盘后**立刻可用**，手指不离开屏幕：
///      **顺时针**滑动 → 图标跟着转（解压感），绝不打开任何 App；
///      **逆时针**滑动 → 停止旋转，进入「等待选择」，手指下的图标放大高亮；
///      原地停住 0.18 秒 → 同样进入「等待选择」。
///   2. 松手：处于「等待选择」且落在图标上 → 用浮窗打开该 App 并收起圆盘；
///      落在空白 → 收起；仍在旋转 → 直接收起（不误开）。
///   3. 圆盘停留期间可以再用手指点图标 / 点圆心 / 点空白。
///
/// 触摸来源去重：唤出圆盘的那根手指可能同时被「边缘手势条」和「窗口 sendEvent 探针」
/// 看到，两条通道都会转发同一个点。这里用 `remoteSource` 只认最先开始的那一条，
/// 避免同一次滑动把旋转角度算两遍。
final class AevonRingMenu: UIView {
    private static var current: AevonRingMenu?

    /// 由内到外的每圈容量；总容量 = 36
    static let ringCapacities = [8, 12, 16]

    private static let iconSize: CGFloat = 46
    private static let centerSize: CGFloat = 56
    /// 命中半径系数
    private static let hitFactor: CGFloat = 0.95
    /// 判定为「拖动旋转」的最小角度（度）
    private static let dragThreshold: CGFloat = 6
    /// 手指停住多久算「等待选择」
    private static let armDelay: TimeInterval = 0.18
    /// 圆心纵向位置（占屏幕高度比例）——V0.0.21 从 0.65 下移到 0.75
    private static let verticalRatio: CGFloat = 0.75

    private let dimView = UIView()
    private let trackLayer = CAShapeLayer()
    private let hintLabel = UILabel()
    private let centerButton = UIButton(type: .custom)
    private let centerTitle = UILabel()

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

        hintLabel.frame = CGRect(x: 0, y: 0, width: 340, height: 20)
        hintLabel.text = "顺时针转 · 逆时针选定 · 停住松手开窗"
        hintLabel.textColor = UIColor(white: 1.0, alpha: 0.55)
        hintLabel.font = UIFont.systemFont(ofSize: 11.5)
        hintLabel.textAlignment = .center
        hintLabel.isUserInteractionEnabled = false
        addSubview(hintLabel)

        centerButton.frame = CGRect(x: 0, y: 0, width: AevonRingMenu.centerSize, height: AevonRingMenu.centerSize)
        centerButton.backgroundColor = UIColor(red: 0.10, green: 0.48, blue: 0.95, alpha: 0.96)
        centerButton.layer.cornerRadius = AevonRingMenu.centerSize / 2
        centerButton.layer.shadowColor = UIColor.black.cgColor
        centerButton.layer.shadowOpacity = 0.45
        centerButton.layer.shadowRadius = 12
        centerButton.layer.shadowOffset = CGSize(width: 0, height: 3)
        // 圆心图标：四宫格（表示「应用列表 / 面板」）
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
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

        centerTitle.frame = CGRect(x: 0, y: 0, width: 220, height: 16)
        centerTitle.textColor = UIColor(white: 1.0, alpha: 0.72)
        centerTitle.font = UIFont.systemFont(ofSize: 11)
        centerTitle.textAlignment = .center
        centerTitle.isUserInteractionEnabled = false
        addSubview(centerTitle)
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
        centerTitle.center = CGPoint(x: ringCenter.x, y: ringCenter.y + AevonRingMenu.centerSize / 2 + 15)
        hintLabel.center = CGPoint(x: bounds.midX, y: bounds.maxY - 34)
    }

    /// 圆的可用最大半径：不超出左右边界，也不顶到状态栏 / 底部
    private var maxRadius: CGFloat {
        let byWidth = bounds.width / 2 - AevonRingMenu.iconSize / 2 - 6
        let verticalRoom = min(ringCenter.y, bounds.height - ringCenter.y)
        let byHeight = verticalRoom - AevonRingMenu.iconSize / 2 - 12
        return max(70, min(byWidth, byHeight))
    }

    private func radii(forRingCount count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let limit = maxRadius
        if count == 1 { return [min(120, limit)] }
        let base: CGFloat = 78
        let spacing = min(56, max(34, (limit - base) / CGFloat(count - 1)))
        return (0..<count).map { min(base + CGFloat($0) * spacing, limit) }
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

        // 由内到外依次填圈：8 / 12 / 16
        var remaining = bundleIDs.count
        for cap in AevonRingMenu.ringCapacities {
            let take = min(remaining, cap)
            if take > 0 { ringCounts.append(take) }
            remaining -= take
            if remaining <= 0 { break }
        }
        ringRadii = radii(forRingCount: ringCounts.count)

        var cursor = 0
        for (ringIndex, count) in ringCounts.enumerated() {
            let radius = ringRadii[ringIndex]
            let step = 360 / CGFloat(max(count, 1))
            for i in 0..<count {
                guard cursor < bundleIDs.count else { break }
                let bundleID = bundleIDs[cursor]
                cursor += 1
                let name = AevonWindowManager.title(for: bundleID)
                let icon = AevonRingIcon(bundleID: bundleID, name: name, size: AevonRingMenu.iconSize)
                addSubview(icon)
                icons.append(icon)
                iconRadii.append(radius)
                iconBaseAngles.append(-90 + CGFloat(i) * step)
            }
        }

        drawRingTracks()
        layoutIcons()

        centerTitle.text = icons.isEmpty ? "点圆心添加 App" : "共 \(icons.count) 个"
        let radiiText = ringRadii.map { String(Int($0)) }.joined(separator: "/")
        AevonLog.info("[圆盘] 已展开（\(icons.count) 个 App，\(ringCounts.count) 圈，半径 \(radiiText)，圆心 \(Int(ringCenter.x)),\(Int(ringCenter.y))，纯文字图标 75% 锚点）（AevonRingFullCircle AevonRingMultiRing AevonRingTextOnlyV21 AevonRingAnchor75V21）")
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
        centerTitle.alpha = 0
        hintLabel.alpha = 0

        UIView.animate(withDuration: 0.16, animations: {
            self.dimView.alpha = 1
            self.centerButton.alpha = 1
            self.centerButton.transform = .identity
            self.centerTitle.alpha = 1
            self.hintLabel.alpha = 1
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

        // iOS 屏幕坐标 y 向下：角度递增 = 顺时针。
        // 顺时针（用户原话：「只要手指顺时针滑动，那么就会触发圆盘内应用旋转」）→ 旋转
        if delta > 1.0 {
            rotation += delta
            layoutIcons()
            if remoteSelecting {
                remoteSelecting = false
                setHovered(nil)
            }
            remoteLastAngle = currentAngle
            scheduleArm()
            return
        }
        // 逆时针 → 停止旋转，进入「等待选择」
        if delta < -1.0 {
            remoteLastAngle = currentAngle
            cancelArm()
            enterSelecting(at: point)
            return
        }
        // 几乎没有角度变化：如果已在选择模式，就让高亮跟着手指走（同一圈上换图标）
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

    /// 高亮「松手就会打开」的那个图标，并在圆心下方显示名字
    private func setHovered(_ icon: AevonRingIcon?) {
        for item in icons {
            item.transform = (item === icon) ? CGAffineTransform(scaleX: 1.10, y: 1.10) : .identity
            item.backgroundColor = (item === icon)
                ? UIColor(red: 0.10, green: 0.48, blue: 0.95, alpha: 0.96)
                : UIColor(white: 0.12, alpha: 0.92)
        }
        if let icon = icon {
            centerTitle.text = icon.displayName
        } else if !isDismissing {
            centerTitle.text = icons.isEmpty ? "点圆心添加 App" : "共 \(icons.count) 个"
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
