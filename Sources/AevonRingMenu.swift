import UIKit

/// 圆盘上的一个 App 图标（带文字兜底：拿不到系统图标就画首字母圆点）。
///
/// 图标本身**不接收触摸**（`isUserInteractionEnabled = false`），
/// 触摸统一由 `AevonRingMenu` 按几何命中判定 —— 这样「点按」和「拖动旋转」不会互相取消。
final class AevonRingIcon: UIView {
    let bundleID: String
    var displayName: String

    private let imageView = UIImageView()
    private let letterLabel = UILabel()

    init(bundleID: String, name: String, size: CGFloat) {
        self.bundleID = bundleID
        self.displayName = name
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.cornerRadius = size * 0.235
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = size * 0.235
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        letterLabel.frame = bounds
        letterLabel.textAlignment = .center
        letterLabel.textColor = .white
        letterLabel.font = UIFont.systemFont(ofSize: size * 0.42, weight: .semibold)
        letterLabel.isUserInteractionEnabled = false
        addSubview(letterLabel)

        letterLabel.text = String(name.prefix(1))

        if let image = AevonIconImage(bundleID, 3.0) {
            imageView.image = image
            letterLabel.isHidden = true
        } else {
            // 取不到图标：用名字首字母 + 由 bundleID 决定的稳定色
            letterLabel.isHidden = false
            backgroundColor = AevonRingIcon.fallbackColor(bundleID)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func fallbackColor(_ seed: String) -> UIColor {
        var hash = 0
        for scalar in seed.unicodeScalars {
            hash = (hash &* 31 &+ Int(scalar.value)) & 0xFFFF
        }
        let hue = CGFloat(hash % 360) / 360.0
        return UIColor(hue: hue, saturation: 0.55, brightness: 0.62, alpha: 1.0)
    }
}

/// 径向圆盘选择器（V0.0.20：多圈 + 手指跟手旋转 + 停顿选定）。
///
/// 形态：
///   · 圆心**固定在屏幕水平中央、纵向 65% 处**（用户指定），不随触发点浮动；
///   · App 按「由内到外」依次放到第 1/2/3 圈，每圈容量 8 / 12 / 16，圈数随数量自动增加；
///   · 圆心按钮是蓝色圆 + 九宫格图标，点它打开完整应用选择面板。
///
/// 交互（用户 2026-10-22 明确要求）：
///   1. 从右边缘左滑唤出圆盘，**手指不离开屏幕**时继续滑动 → 整盘图标跟着手指转，绝不打开任何 App；
///   2. 手指停住（≥0.18s）→ 判定为「选定」，此时不再旋转；
///   3. 停住后松手落在某个图标上 → 用浮窗打开它；
///   4. 停住后松手落在圆盘空白处 → 收起圆盘；
///   5. 还在旋转中松手 → 圆盘保留，可以用第二根手指直接点图标（此时走本地触摸逻辑）。
///
/// 实现要点：唤出圆盘的触摸被「边缘手势条」持有（UIKit 不会因为视图被覆盖就换发事件），
/// 所以圆盘提供一组 `remoteXxx` 接口，由手势条把那根手指的移动转发进来；
/// 圆盘自身的 `touchesBegan/Moved/Ended` 负责「第二次直接点」的场景。
/// 两套入口共用同一套几何判定，不会互相打架。
final class AevonRingMenu: UIView {
    private static var current: AevonRingMenu?

    /// 由内到外的每圈容量；总容量 = 36
    static let ringCapacities = [8, 12, 16]

    private static let iconSize: CGFloat = 44
    private static let centerSize: CGFloat = 56
    /// 命中半径系数（图标半径 22pt，取 0.9 让相邻图标之间不留死区）
    private static let hitFactor: CGFloat = 0.9
    /// 判定为「拖动旋转」的最小角度（度）
    private static let dragThreshold: CGFloat = 6
    /// 手指停住多久算「选定」
    private static let armDelay: TimeInterval = 0.18
    /// 圆心纵向位置（占屏幕高度比例）
    private static let verticalRatio: CGFloat = 0.65

    private let dimView = UIView()
    private let trackLayer = CAShapeLayer()
    private let hintLabel = UILabel()
    private let centerButton = UIButton(type: .custom)
    private let centerTitle = UILabel()

    private var icons: [AevonRingIcon] = []
    /// 每个图标所在圈的半径与基准角度（不含 rotation）
    private var iconRadii: [CGFloat] = []
    private var iconBaseAngles: [CGFloat] = []
    /// 每圈的图标数量（下标 = 圈序号，从内到外）
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

    // 远程触摸（边缘手势那根手指，尚未松手）
    private var remoteLastAngle: CGFloat = 0
    private var remotePoint: CGPoint = .zero
    private var remoteArmed = false
    private var remoteRotating = false
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

        dimView.backgroundColor = UIColor(white: 0, alpha: 0.30)
        dimView.frame = bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.isUserInteractionEnabled = false
        addSubview(dimView)

        // 每圈一条极淡的描边，给出「圆盘」的轮廓
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor(white: 1.0, alpha: 0.14).cgColor
        trackLayer.lineWidth = 1.5
        layer.addSublayer(trackLayer)

        hintLabel.frame = CGRect(x: 0, y: 0, width: 320, height: 20)
        hintLabel.text = "滑动旋转 · 停住松手即开窗 · 点图标选择 · 点圆心改列表"
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
        // 圆心图标：四宫格（表示「应用列表 / 面板」），比一个字母直观
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

        centerTitle.frame = CGRect(x: 0, y: 0, width: 200, height: 16)
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
        // 圆心固定：水平正中，纵向 65%（用户 2026-10-22 指定）
        ringCenter = CGPoint(x: bounds.midX, y: bounds.height * AevonRingMenu.verticalRatio)

        centerButton.center = ringCenter
        centerTitle.center = CGPoint(x: ringCenter.x, y: ringCenter.y + AevonRingMenu.centerSize / 2 + 16)
        hintLabel.center = CGPoint(x: bounds.midX, y: bounds.maxY - 42)
    }

    /// 圆的可用最大半径：不超出左右边界，也不顶到状态栏 / 底部
    private var maxRadius: CGFloat {
        let byWidth = bounds.width / 2 - AevonRingMenu.iconSize / 2 - 10
        let verticalRoom = min(ringCenter.y, bounds.height - ringCenter.y)
        let byHeight = verticalRoom - AevonRingMenu.iconSize / 2 - 16
        return max(70, min(byWidth, byHeight))
    }

    private func radii(forRingCount count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let limit = maxRadius
        if count == 1 { return [min(118, limit)] }
        let base: CGFloat = 74
        let spacing = min(54, max(30, (limit - base) / CGFloat(count - 1)))
        return (0..<count).map { base + CGFloat($0) * spacing }
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
        AevonLog.info("[圆盘] 已展开（\(icons.count) 个 App，\(ringCounts.count) 圈，半径 \(radiiText)，圆心 \(Int(ringCenter.x)),\(Int(ringCenter.y))）（AevonRingFullCircle AevonRingMultiRing）")
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

        UIView.animate(withDuration: 0.18, animations: {
            self.dimView.alpha = 1
            self.centerButton.alpha = 1
            self.centerButton.transform = .identity
            self.centerTitle.alpha = 1
            self.hintLabel.alpha = 1
        })
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.28
        trackLayer.add(fade, forKey: "fade")
        trackLayer.opacity = 1

        for (index, icon) in icons.enumerated() {
            icon.alpha = 0
            icon.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            let delay = 0.02 + 0.02 * Double(index)
            UIView.animate(withDuration: 0.38,
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
        UIView.animate(withDuration: 0.16, animations: {
            self.alpha = 0
            for icon in self.icons {
                icon.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
            self.centerButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    // MARK: - 远程触摸（边缘手势那根手指，尚未松手）

    /// 圆盘被边缘手势唤出时立刻调用，`point` 是窗口坐标。
    func beginRemoteTracking(at point: CGPoint) {
        remotePoint = point
        remoteLastAngle = angle(from: ringCenter, to: point)
        remoteArmed = false
        remoteRotating = false
        scheduleArm()
    }

    func remoteMoved(to point: CGPoint) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        remotePoint = point
        let currentAngle = angle(from: ringCenter, to: point)
        var delta = currentAngle - remoteLastAngle
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        if abs(delta) >= 0.4 {
            rotation += delta
            layoutIcons()
            remoteRotating = true
            if remoteArmed { disarm() }
        }
        remoteLastAngle = currentAngle
        scheduleArm()
    }

    /// 松手：停顿后落在图标上 → 开窗；停顿后落在空白 → 收起；仍在旋转 → 保留圆盘等第二次点击。
    func remoteEnded(at point: CGPoint) {
        guard AevonRingMenu.current === self, !isDismissing else { return }
        armTimer?.invalidate()
        armTimer = nil
        remotePoint = point

        if remoteArmed {
            if let icon = icon(at: point) {
                setHovered(nil)
                activate(icon)
            } else {
                AevonLog.info("[圆盘] 停顿后松手在空白处，收起圆盘")
                setHovered(nil)
                dismiss()
            }
            return
        }
        // 还在旋转时松手：不打开任何 App，圆盘留着给第二次点击
        AevonLog.info("[圆盘] 旋转中松手，圆盘保留（可直接点图标）")
        setHovered(nil)
        centerTitle.text = icons.isEmpty ? "点圆心添加 App" : "共 \(icons.count) 个"
    }

    func remoteCancelled() {
        armTimer?.invalidate()
        armTimer = nil
    }

    private func scheduleArm() {
        armTimer?.invalidate()
        let timer = Timer(timeInterval: AevonRingMenu.armDelay, repeats: false) { [weak self] _ in
            guard let self = self, AevonRingMenu.current === self else { return }
            self.remoteArmed = true
            self.remoteRotating = false
            if let icon = self.icon(at: self.remotePoint) {
                self.setHovered(icon)
            } else {
                self.setHovered(nil)
            }
        }
        // 手指按住时 RunLoop 处于 tracking 模式，必须挂 common modes
        RunLoop.main.add(timer, forMode: .common)
        armTimer = timer
    }

    private func disarm() {
        remoteArmed = false
        setHovered(nil)
    }

    /// 高亮「松手就会打开」的那个图标，并在圆心下方显示名字
    private func setHovered(_ icon: AevonRingIcon?) {
        for item in icons {
            item.transform = (item === icon) ? CGAffineTransform(scaleX: 1.14, y: 1.14) : .identity
        }
        if let icon = icon {
            centerTitle.text = icon.displayName
        } else if !remoteRotating && !isDismissing {
            centerTitle.text = icons.isEmpty ? "点圆心添加 App" : "共 \(icons.count) 个"
        }
    }

    // MARK: - 本地触摸（第二根手指直接点 / 拖）

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
        if centerDistance <= AevonRingMenu.centerSize * 0.8 {
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
        AevonLog.info("[圆盘] 选中 \(icon.displayName) (\(bundleID))")
        icon.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            AevonWindowManager.launchAndOpen(bundleID: bundleID)
        }
    }

    // MARK: - 几何工具

    /// 命中哪个图标：先按角度找该圈上最近的一个，再校验径向距离。
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
            let tolerance = max(AevonRingMenu.iconSize * 0.72, 26)
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
        // 命中半径：图标边长的 0.9 倍（避免落到相邻图标身上）
        return bestScore <= AevonRingMenu.iconSize * AevonRingMenu.hitFactor ? candidate : nil
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        return atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }
}
