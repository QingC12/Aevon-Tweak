import UIKit

/// 触发区 / 接管带的「所见即所得」预览层（V0.2.10 / AevonGeomOverlayV210）。
///
/// 用户 Aevon(96) 的要求：右侧边缘圆盘的**手势触发区**和**接管地带**这两块，
/// 要「清晰可见、可以随意更改、更改时实时可见，随着滑动条的拖动而实时更新位置变化」。
///
/// 以前能看到的只有两样东西，都不够用：
///   · `AevonEdgeStripView.indicator` —— 一条 4pt 宽的淡色竖线，只知道「这附近有东西」，
///     不知道热区的左右边界在哪、上下边界在哪；
///   · `AevonBandHint` —— 一次性的淡蓝填充块，只画接管带，3 秒后消失，且开关关着就不画。
///
/// 这一版给两块带完整边框的矩形，各自挂一个尺寸胶囊标签：
///   · **呼出热区**（青色，实线 2pt）—— `AevonTriggerZone.rect`，划出圆盘的那一格；
///   · **右缘接管带**（橙色，实线 2pt）—— `AevonRightEdge.band`，App 前台时按下即接管的那条；
///     接管带开关关着时整体半透明、标签补一句「未启用」，这样用户能先看清范围再决定开不开。
///
/// ⛔ 纪律（0.1.16 的事故不能重演）：**绝不重写 `draw(_:)`、绝不 `setNeedsDisplay`**。
/// Aevon(84) 就是因为一块全屏视图自绘 + 每次布局重绘 + `draw` 里读 CFPreferences，
/// 把整台手机卡死到必须卸载。这里全部是 `layer.borderWidth` / `backgroundColor` 的
/// 图层合成，没有任何后备存储；容器 `isUserInteractionEnabled = false` 且
/// `hitTest` 恒返回 nil —— 它看得见、摸不到、不参与任何触摸裁决。
enum AevonGeometryOverlay {
    /// 只做容器：保证自己和孩子都不吃触摸。层级上单独一层，方便整体显示 / 隐藏。
    private final class Host: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { return nil }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { return false }
    }

    private static weak var host: Host?
    private static weak var zoneBox: UIView?
    private static weak var bandBox: UIView?
    private static weak var zoneLabel: UILabel?
    private static weak var bandLabel: UILabel?

    /// 预览到期时刻（`CACurrentMediaTime` 基准）。0 = 当前没有预览请求。
    private static var previewUntil: CFTimeInterval = 0
    /// 接管成功闪一下的到期时刻（只加粗边框，不改变位置）。
    private static var flashUntil: CFTimeInterval = 0

    private static let zoneColor = UIColor(red: 0.16, green: 0.84, blue: 0.86, alpha: 1.0)
    private static let bandColor = UIColor(red: 1.00, green: 0.60, blue: 0.18, alpha: 1.0)

    // MARK: - 对外：预览 / 同步 / 收起

    /// 设置里的几何指纹变了 → 亮 `duration` 秒，让用户立刻看到新范围。
    ///
    /// 拖动滑条时每帧都会改写偏好，SB 侧 0.2 秒轮询发现指纹变化就再调一次本函数，
    /// 于是预览在整段拖动过程中**一直亮着**，而且每一帧都在跟着新尺寸走。
    static func preview(duration: CFTimeInterval = 3.0) {
        previewUntil = CACurrentMediaTime() + duration
        sync()
    }

    /// 接管成功 → 接管带边框加粗 0.35 秒（告诉用户「这一下归我们」）。
    ///
    /// 注意方法名：CI 有一条 0.1.17 的历史负向断言，禁止
    /// `AevonSystemGestureV104.swift` 里再出现 `flashBand()` 这个旧名字
    /// （0.1.16 那套全屏自绘的闪示会把整屏卡死）。这里刻意不叫那个名字，
    /// 也不要把它引回那个文件 —— 视觉反馈走的是两块矩形自己的边框。
    static func flashEdge() {
        flashUntil = CACurrentMediaTime() + 0.35
        guard bandBox != nil else { return }
        bandBox?.layer.borderWidth = 3.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            bandBox?.layer.borderWidth = 2.0
        }
    }

    /// 圆盘呼出 / 容器要重排时立刻收掉（别和圆盘叠在一起）。
    static func hideNow() {
        host?.isHidden = true
    }

    /// 0.2 秒轮询调用：决定要不要显示，并按最新偏好重排。
    ///
    /// 显示条件只有两条：**开关总闸打开** +（正在预览 或 用户把「显示接管带」常开了）。
    /// 圆盘展开期间一律不画 —— 盘上的图标需要干净背景。
    static func sync() {
        guard AevonPrefs.bool("Enabled", default: false) else { hideNow(); return }
        guard !AevonRingMenu.isPresented else { hideNow(); return }
        guard let root = AevonEntryHost.activeRoot, root.bounds.width > 1, root.bounds.height > 1 else {
            hideNow()
            return
        }
        let now = CACurrentMediaTime()
        let previewing = now < previewUntil
        let pinned = AevonRightEdge.showBand
        guard previewing || pinned else { hideNow(); return }

        ensureViews(in: root)
        layout(in: root, strong: previewing || now < flashUntil)
        host?.isHidden = false
    }

    // MARK: - 视图搭建（一次性）

    private static func ensureViews(in root: UIView) {
        if let existing = host, existing.superview === root {
            return
        }
        host?.removeFromSuperview()

        let container = Host(frame: root.bounds)
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let zone = makeBox(color: zoneColor)
        let band = makeBox(color: bandColor)
        container.addSubview(band)      // 先加接管带，热区压在它上面
        container.addSubview(zone)

        let zoneText = makeLabel()
        let bandText = makeLabel()
        container.addSubview(zoneText)
        container.addSubview(bandText)

        root.addSubview(container)
        root.bringSubviewToFront(container)

        host = container
        zoneBox = zone
        bandBox = band
        zoneLabel = zoneText
        bandLabel = bandText
    }

    private static func makeBox(color: UIColor) -> UIView {
        let box = UIView()
        box.isUserInteractionEnabled = false
        box.backgroundColor = color.withAlphaComponent(0.10)
        box.layer.borderColor = color.cgColor
        box.layer.borderWidth = 2.0
        box.layer.cornerRadius = 6.0
        box.layer.cornerCurve = .continuous
        return box
    }

    private static func makeLabel() -> UILabel {
        let label = UILabel()
        label.isUserInteractionEnabled = false
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor(white: 0.0, alpha: 0.66)
        label.layer.cornerRadius = 7.0
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        return label
    }

    // MARK: - 落位

    private static func layout(in root: UIView, strong: Bool) {
        let bounds = root.bounds
        let zone = AevonTriggerZone.rect(in: bounds)
        let band = AevonRightEdge.band(in: bounds)
        let bandOn = AevonRightEdge.enabled

        if let box = zoneBox {
            box.frame = zone
            box.layer.borderWidth = 2.0
            box.backgroundColor = zoneColor.withAlphaComponent(strong ? 0.16 : 0.10)
        }
        if let box = bandBox {
            box.frame = band
            box.layer.borderWidth = 2.0
            box.alpha = bandOn ? 1.0 : 0.5
            box.backgroundColor = bandColor.withAlphaComponent(strong ? 0.16 : 0.10)
        }

        // 标签内容：把「现在这一格到底多大、贴哪」直接写出来
        if let label = zoneLabel {
            label.text = " 呼出热区 \(Int(zone.width))×\(Int(zone.height))pt · 底边 \(Int(AevonTriggerZone.bottomRatio * 100))% "
            place(label, beside: zone, in: bounds)
        }
        if let label = bandLabel {
            let suffix = bandOn ? "" : " · 未启用"
            label.text = " 接管带 \(Int(band.width))pt × 高 \(Int(AevonRightEdge.heightPercent))%\(suffix) "
            place(label, beside: band, in: bounds)
        }
    }

    /// 标签放在矩形**左侧**（矩形永远贴屏幕右边，往左永远有地方），纵向跟着矩形中心。
    /// 带子只有 18~46pt 宽，标签放进去必然挤成一团，所以宁可放在外面当引线。
    private static func place(_ label: UILabel, beside rect: CGRect, in bounds: CGRect) {
        let size = label.sizeThatFits(CGSize(width: bounds.width, height: 40))
        let width = min(size.width + 4, max(60, bounds.width - 24))
        let height: CGFloat = 22
        var x = rect.minX - width - 8
        if x < 8 { x = 8 }
        var y = rect.midY - height / 2
        y = min(max(y, 8), bounds.height - height - 8)
        label.frame = CGRect(x: x, y: y, width: width, height: height)
    }
}
