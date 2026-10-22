import UIKit

/// 圆盘上的一个 App 图标（带文字兜底：拿不到系统图标就画首字母圆点）。
final class AevonRingIcon: UIView {
    let bundleID: String

    private let imageView = UIImageView()
    private let letterLabel = UILabel()

    init(bundleID: String, name: String, size: CGFloat) {
        self.bundleID = bundleID
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))

        backgroundColor = .clear
        layer.cornerRadius = size * 0.23
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = size * 0.23
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

/// 圆盘选择器（从屏幕边缘呼出的径向 App 菜单）。
///
/// 逆向证据（Stheno.dylib 的属性名与本地化文案）：
///   `_ring` / `_apps` / `_selected` / `_radius` / `_iconWidth` / `_rotationAngle` /
///   `_tailDegree`（本地化文案 `LastIconAngle = 尾角`）/ `_dragScale` / `_scaleAngle`，
///   文案 `Star = 收藏`、`UserList = 用户列表`、`AppSearcher`、`TrashAppView`。
///   即：图标沿圆周排列，半径与图标宽度可调，整环可旋转（拖动改角度），可收藏自选 App。
///
/// 本实现取这套模型的最小可用集：
///   · 图标沿左半圆（96°–264°）等角分布，圆心靠在右侧边缘，视觉上是「从右边滑出的半圆盘」；
///   · 拖动圆盘整体旋转，松手吸附到最近的步进；
///   · 点图标 = 开窗，长按图标 = 从圆盘移除；
///   · 圆心按钮 = 打开完整面板（单窗 / 左右分屏 / 编辑圆盘）。
final class AevonRingMenu: UIView {
    private static var current: AevonRingMenu?

    private static let iconSize: CGFloat = 54
    private static let centerSize: CGFloat = 58
    private static let arcStart: CGFloat = 96
    private static let arcEnd: CGFloat = 264

    private let dimView = UIView()
    private let hintLabel = UILabel()
    private let centerButton = UIButton(type: .custom)
    private let centerTitle = UILabel()

    private var icons: [AevonRingIcon] = []
    private var rotation: CGFloat = 0
    private var rotationStart: CGFloat = 0
    private var panStartAngle: CGFloat = 0
    private var panStartRotation: CGFloat = 0
    private var didDrag = false

    private var ringCenter: CGPoint = .zero
    private var radius: CGFloat = 180

    // MARK: - 呼出 / 收起

    static func present(in host: UIView) {
        if let existing = current {
            existing.dismiss()
            return
        }
        let menu = AevonRingMenu(frame: host.bounds)
        host.addSubview(menu)
        current = menu
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

        dimView.backgroundColor = UIColor(white: 0, alpha: 0.22)
        dimView.frame = bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(dimView)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))

        hintLabel.frame = CGRect(x: 0, y: 0, width: 240, height: 20)
        hintLabel.text = "左右拖动旋转 · 点图标开窗 · 长按移除"
        hintLabel.textColor = UIColor(white: 1.0, alpha: 0.55)
        hintLabel.font = UIFont.systemFont(ofSize: 12)
        hintLabel.textAlignment = .center
        hintLabel.isHidden = true
        addSubview(hintLabel)

        centerButton.frame = CGRect(x: 0, y: 0, width: AevonRingMenu.centerSize, height: AevonRingMenu.centerSize)
        centerButton.backgroundColor = UIColor(red: 0.10, green: 0.48, blue: 0.95, alpha: 0.95)
        centerButton.layer.cornerRadius = AevonRingMenu.centerSize / 2
        centerButton.layer.shadowColor = UIColor.black.cgColor
        centerButton.layer.shadowOpacity = 0.4
        centerButton.layer.shadowRadius = 10
        centerButton.layer.shadowOffset = CGSize(width: 0, height: 3)
        centerButton.setTitle("A", for: .normal)
        centerButton.setTitleColor(.white, for: .normal)
        centerButton.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .bold)
        centerButton.addTarget(self, action: #selector(centerTapped), for: .touchUpInside)
        addSubview(centerButton)

        centerTitle.frame = CGRect(x: 0, y: 0, width: 160, height: 16)
        centerTitle.textColor = UIColor(white: 1.0, alpha: 0.7)
        centerTitle.font = UIFont.systemFont(ofSize: 11)
        centerTitle.textAlignment = .center
        centerTitle.isHidden = true
        addSubview(centerTitle)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func computeGeometry() {
        let screen = UIScreen.main.bounds
        ringCenter = CGPoint(x: screen.width - 46, y: screen.height * 0.70)
        radius = min(screen.width * 0.44, 190)
        centerButton.center = ringCenter
        centerTitle.center = CGPoint(x: ringCenter.x, y: ringCenter.y + AevonRingMenu.centerSize / 2 + 14)
        hintLabel.center = CGPoint(x: screen.width / 2 - 30, y: screen.height - 40)
    }

    private func reload() {
        computeGeometry()
        for icon in icons { icon.removeFromSuperview() }
        icons.removeAll()

        var entries: [(String, String)] = []
        for bundleID in AevonRingStore.bundleIDs() {
            let name = AevonWindowManager.title(for: bundleID)
            entries.append((bundleID, name))
        }

        for (bundleID, name) in entries {
            let icon = AevonRingIcon(bundleID: bundleID, name: name, size: AevonRingMenu.iconSize)
            icon.center = ringCenter
            icon.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(iconTapped(_:))))
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(iconLongPressed(_:)))
            longPress.minimumPressDuration = 0.65
            icon.addGestureRecognizer(longPress)
            addSubview(icon)
            icons.append(icon)
        }

        hintLabel.isHidden = icons.count < 2
        centerTitle.text = icons.isEmpty ? "点 + 添加 App" : "共 \(icons.count) 个"
        centerTitle.isHidden = icons.isEmpty
        layoutIcons()
        AevonLog.info("[圆盘] 已展开（\(icons.count) 个 App，半径 \(Int(radius))，圆心 \(Int(ringCenter.x)),\(Int(ringCenter.y))）")
    }

    private var step: CGFloat {
        guard icons.count > 1 else { return 0 }
        return (AevonRingMenu.arcEnd - AevonRingMenu.arcStart) / CGFloat(icons.count - 1)
    }

    private func layoutIcons() {
        guard !icons.isEmpty else { return }
        let n = icons.count
        for (index, icon) in icons.enumerated() {
            let base: CGFloat
            if n == 1 {
                base = 180
            } else {
                base = AevonRingMenu.arcStart + CGFloat(index) * step
            }
            let degree = base + rotation
            let radians = degree * .pi / 180
            let point = CGPoint(x: ringCenter.x + radius * cos(radians),
                                y: ringCenter.y + radius * sin(radians))
            icon.center = point
            // 离圆心越远（越靠外侧）越清晰，避免图标互相压住时糊成一团
            icon.alpha = 1.0
        }
    }

    // MARK: - 动画

    private func animateIn() {
        dimView.alpha = 0
        centerButton.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        centerButton.alpha = 0
        for icon in icons {
            icon.alpha = 0
            icon.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        }

        UIView.animate(withDuration: 0.18, animations: {
            self.dimView.alpha = 1
            self.centerButton.alpha = 1
            self.centerButton.transform = .identity
        })

        for (index, icon) in icons.enumerated() {
            let delay = 0.04 + 0.03 * Double(index)
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
        guard AevonRingMenu.current === self else { return }
        AevonRingMenu.current = nil
        UIView.animate(withDuration: 0.16, animations: {
            self.alpha = 0
            for icon in self.icons {
                icon.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            }
            self.centerButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    // MARK: - 交互

    @objc private func dimTapped() {
        dismiss()
    }

    @objc private func centerTapped() {
        AevonLog.info("[圆盘] 圆心被点击，打开应用面板")
        dismiss()
        AevonEdgeEntry.openPanel(preferRingEditing: icons.isEmpty)
    }

    @objc private func iconTapped(_ gesture: UITapGestureRecognizer) {
        guard let icon = gesture.view as? AevonRingIcon, !didDrag else { return }
        let name = AevonWindowManager.title(for: icon.bundleID)
        AevonLog.info("[圆盘] 选中 \(name) (\(icon.bundleID))")
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            AevonWindowManager.launchAndOpen(bundleID: icon.bundleID)
        }
    }

    @objc private func iconLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let icon = gesture.view as? AevonRingIcon else { return }
        let name = AevonWindowManager.title(for: icon.bundleID)
        AevonLog.info("[圆盘] 长按移除 \(name) (\(icon.bundleID))")
        AevonRingStore.remove(icon.bundleID)
        reload()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !icons.isEmpty else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            didDrag = false
            panStartAngle = angle(from: ringCenter, to: point)
            panStartRotation = rotation
        case .changed:
            let currentAngle = angle(from: ringCenter, to: point)
            var delta = currentAngle - panStartAngle
            // 跨 ±180° 时修正，避免整盘突然翻转
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            if abs(delta) > 4 { didDrag = true }
            rotation = panStartRotation + delta
            layoutIcons()
        case .ended, .cancelled, .failed:
            guard didDrag else { return }
            let stepValue = max(1, step)
            let snapped = (rotation / stepValue).rounded() * stepValue
            rotation = rotationStartFrom(snapped)
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                self.layoutIcons()
            }
        default:
            break
        }
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
