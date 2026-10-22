import UIKit

/// 圆盘上的一个 App 图标（带文字兜底：拿不到系统图标就画首字母圆点）。
///
/// 注意：图标本身**不接收触摸**（`isUserInteractionEnabled = false`）。
/// 原因见 `AevonRingMenu` 顶部的说明 —— 触摸统一由圆盘自己按几何命中判定。
final class AevonRingIcon: UIView {
    let bundleID: String

    private let imageView = UIImageView()
    private let letterLabel = UILabel()

    init(bundleID: String, name: String, size: CGFloat) {
        self.bundleID = bundleID
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        backgroundColor = .clear
        isUserInteractionEnabled = false
        layer.cornerRadius = size * 0.235
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 9
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
            layer.backgroundColor = UIColor.clear.cgColor
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

/// 径向圆盘选择器：**整圆**居中，App 图标沿圆周均匀分布。
///
/// V0.0.16 两处关键修正：
///  1. **形状**：V0.0.15 是「圆心贴在右边缘的左半圆」，看起来就是一条贴边弧线。
///     现在圆心在屏幕正中、图标绕满 360°，并画一圈细描边，和 Stheno 的形态一致。
///  2. **点击**：V0.0.15 的图标各自挂了 UITapGestureRecognizer，而父视图又挂了
///     UIPanGestureRecognizer（拖动旋转）。手指落下的几十毫秒里只要轻微位移就让 pan
///     进入 `.began`，`cancelsTouchesInView` 会把图标的 tap 直接取消，于是点图标
///     完全没有反应 —— 日志里三次「已展开」后没有任何「选中」记录，就是这个原因。
///     现在**不使用任何手势识别器**：图标 `isUserInteractionEnabled = false`，
///     由圆盘自己 `touchesBegan/Moved/Ended` 按几何判定（命中半径 / 旋转阈值 / 长按），
///     点击与拖动互不干扰。
///
/// 逆向证据（Stheno.dylib）：`_ring` / `_rings` / `_apps` / `_selected` / `_radius` /
/// `_iconWidth` / `_rotationAngle` / `_tailDegree` / `_dragScale` / `_scaleAngle`，
/// 本地化 `Star = 收藏`、`RTSIF = 承载形状::圆盘`、`LastIconAngle = 尾角`。
final class AevonRingMenu: UIView {
    private static var current: AevonRingMenu?

    private static let iconSize: CGFloat = 54
    private static let centerSize: CGFloat = 64
    /// 触摸命中半径系数（图标半径 27pt，取 0.82 让相邻图标之间不留死区）
    private static let hitFactor: CGFloat = 0.82
    /// 判定为「拖动旋转」的最小角度（度）。低于它的位移一律当点击。
    private static let dragThreshold: CGFloat = 7

    private let dimView = UIView()
    private let trackLayer = CAShapeLayer()
    private let hintLabel = UILabel()
    private let centerButton = UIButton(type: .custom)
    private let centerTitle = UILabel()

    private var icons: [AevonRingIcon] = []
    private var rotation: CGFloat = 0
    private var panStartAngle: CGFloat = 0
    private var panStartRotation: CGFloat = 0
    private var didDrag = false
    private var isDismissing = false

    private var touchStart: CGPoint?
    private var pressedIcon: AevonRingIcon?
    private var longPressTimer: Timer?

    private var ringCenter: CGPoint = .zero
    private var radius: CGFloat = 170

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
        // V0.0.18：不再需要「展开期间关掉边缘手势条」——
        // 圆盘和手势条现在在同一个根视图里，圆盘最后添加、在最上层，
        // hitTest 天然先命中圆盘，手势条拿不到触摸。
        // 旧版靠开关 isUserInteractionEnabled 反而留下了「收起时忘记恢复就再也呼不出」的风险。
        menu.reload()
        menu.animateIn()
    }

    static func dismissCurrent() {
        current?.dismiss()
    }

    static var isPresented: Bool { return current != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = true

        dimView.backgroundColor = UIColor(white: 0, alpha: 0.46)
        dimView.frame = bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.isUserInteractionEnabled = false
        addSubview(dimView)

        // 圆周细描边：给「圆盘」一个可见轮廓
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor(white: 1.0, alpha: 0.16).cgColor
        trackLayer.lineWidth = 1.5
        layer.addSublayer(trackLayer)

        hintLabel.frame = CGRect(x: 0, y: 0, width: 300, height: 20)
        hintLabel.text = "拖动旋转 · 点图标开窗 · 长按移除 · 点空白收起"
        hintLabel.textColor = UIColor(white: 1.0, alpha: 0.55)
        hintLabel.font = UIFont.systemFont(ofSize: 12)
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
        centerButton.setTitle("A", for: .normal)
        centerButton.setTitleColor(.white, for: .normal)
        centerButton.titleLabel?.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        // 同样不接收触摸：圆心点击由 touchesEnded 按距离判定
        centerButton.isUserInteractionEnabled = false
        addSubview(centerButton)

        centerTitle.frame = CGRect(x: 0, y: 0, width: 160, height: 16)
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
    }

    private func computeGeometry() {
        // 整圆居中：圆心在屏幕中心略偏上，给底部提示留位置
        ringCenter = CGPoint(x: bounds.midX, y: bounds.midY - bounds.height * 0.02)
        // 半径：既不超出左右边界，也不顶到状态栏/底部
        let byWidth = bounds.width / 2 - AevonRingMenu.iconSize / 2 - 20
        let byHeight = bounds.height / 2 - AevonRingMenu.iconSize / 2 - 96
        radius = max(96, min(byWidth, byHeight, 200))

        centerButton.center = ringCenter
        centerTitle.center = CGPoint(x: ringCenter.x, y: ringCenter.y + AevonRingMenu.centerSize / 2 + 15)
        hintLabel.center = CGPoint(x: bounds.midX, y: bounds.maxY - 46)

        let path = UIBezierPath(arcCenter: ringCenter,
                                radius: radius,
                                startAngle: 0,
                                endAngle: CGFloat.pi * 2,
                                clockwise: true)
        trackLayer.path = path.cgPath
        trackLayer.frame = bounds
    }

    private func reload() {
        computeGeometry()
        for icon in icons { icon.removeFromSuperview() }
        icons.removeAll()

        for bundleID in AevonRingStore.bundleIDs() {
            let name = AevonWindowManager.title(for: bundleID)
            let icon = AevonRingIcon(bundleID: bundleID, name: name, size: AevonRingMenu.iconSize)
            icon.center = ringCenter
            addSubview(icon)
            icons.append(icon)
        }

        hintLabel.isHidden = false
        centerTitle.text = icons.isEmpty ? "点圆盘打开面板添加 App" : "共 \(icons.count) 个"
        layoutIcons()
        AevonLog.info("[圆盘] 已展开（\(icons.count) 个 App，整圆半径 \(Int(radius))，圆心 \(Int(ringCenter.x)),\(Int(ringCenter.y))）（AevonRingFullCircle）")
    }

    /// 圆周上的等角步进（整圆 360°）
    private var step: CGFloat {
        guard icons.count > 1 else { return 0 }
        return 360 / CGFloat(icons.count)
    }

    private func layoutIcons() {
        guard !icons.isEmpty else { return }
        let n = icons.count
        for (index, icon) in icons.enumerated() {
            // 从正上方（-90°）开始顺时针均分整圆
            let base: CGFloat = n == 1 ? -90 : -90 + CGFloat(index) * step
            let radians = (base + rotation) * .pi / 180
            icon.center = CGPoint(x: ringCenter.x + radius * cos(radians),
                                  y: ringCenter.y + radius * sin(radians))
            icon.alpha = 1.0
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
            let delay = 0.03 + 0.025 * Double(index)
            UIView.animate(withDuration: 0.42,
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

    // MARK: - 触摸（不使用手势识别器，避免与拖动互相取消）

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
        let current = angle(from: ringCenter, to: point)
        var delta = current - panStartAngle
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

        if didDrag {
            snapRotation()
            return
        }

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
        if centerDistance <= AevonRingMenu.centerSize * 0.75 {
            AevonLog.info("[圆盘] 圆心被点击，打开应用面板")
            dismiss()
            AevonEdgeEntry.openPanel(preferRingEditing: icons.isEmpty)
            return
        }

        // 点到空白处：收起
        AevonLog.info("[圆盘] 点击空白处，收起圆盘")
        dismiss()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelLongPress()
        if let icon = pressedIcon {
            icon.transform = .identity
            pressedIcon = nil
        }
        if !didDrag { return }
        snapRotation()
    }

    private func snapRotation() {
        let stepValue = max(1, step)
        let snapped = (rotation / stepValue).rounded() * stepValue
        rotation = rotationStartFrom(snapped)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.layoutIcons()
        }
    }

    // MARK: - 长按移除

    private func scheduleLongPress(for icon: AevonRingIcon) {
        cancelLongPress()
        let timer = Timer(timeInterval: 0.7, repeats: false) { [weak self, weak icon] _ in
            guard let self = self, let icon = icon, !self.didDrag else { return }
            self.removeIcon(icon)
        }
        // 手指按住期间 RunLoop 处于 tracking 模式，必须显式挂到 common modes 才会触发
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func removeIcon(_ icon: AevonRingIcon) {
        let name = AevonWindowManager.title(for: icon.bundleID)
        AevonLog.info("[圆盘] 长按移除 \(name) (\(icon.bundleID))")
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
        let name = AevonWindowManager.title(for: bundleID)
        AevonLog.info("[圆盘] 选中 \(name) (\(bundleID))")
        icon.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            AevonWindowManager.launchAndOpen(bundleID: bundleID)
        }
    }

    // MARK: - 几何工具

    private func icon(at point: CGPoint) -> AevonRingIcon? {
        var best: AevonRingIcon?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        let limit = AevonRingMenu.iconSize * AevonRingMenu.hitFactor
        for icon in icons {
            let dx = point.x - icon.center.x
            let dy = point.y - icon.center.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= limit && distance < bestDistance {
                best = icon
                bestDistance = distance
            }
        }
        return best
    }

    private func rotationStartFrom(_ value: CGFloat) -> CGFloat {
        // 把吸附后的角度收进 -180…180，避免长期拖动后数值无限增长
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }

    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        return atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }
}
