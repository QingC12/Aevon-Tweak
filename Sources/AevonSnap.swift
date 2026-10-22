import UIKit

/// 吸附槽位：把窗口拖到屏幕边缘松手时，自动对齐到的位置。
enum AevonSnapSlot: String {
    case free
    case left
    case right
    case top
}

/// 吸附几何计算。
///
/// 内容区宽高比恒等于屏幕比例（V0.0.11 的定论），所以每一格的尺寸都能由宽度唯一确定：
/// 高 = 宽 ÷ 比例 + 标题栏。左右半屏时两块并排，中间留 8pt 缝，正好铺满一屏宽度，
/// 这就是不用改场景尺寸也能做到的「真分屏」。
enum AevonSnap {
    static let gap: CGFloat = 8
    /// 距离边缘多少点以内算「想吸附」
    static let edgeThreshold: CGFloat = 22
    /// V0.0.37：浮窗无标题栏，高度就是纯内容高
    static let titleBarHeight: CGFloat = 0
    static let minContentWidth: CGFloat = 150

    static var aspect: CGFloat { return AevonWindowView.contentAspect }

    static func height(forWidth width: CGFloat) -> CGFloat {
        return width / max(0.2, aspect) + titleBarHeight
    }

    /// 某一格的完整 frame（含标题栏）。.free 返回零矩形。
    static func frame(for slot: AevonSnapSlot) -> CGRect {
        let screen = UIScreen.main.bounds
        switch slot {
        case .free:
            return .zero

        case .left, .right:
            let width = (screen.width - gap * 3.0) / 2.0
            let height = height(forWidth: width)
            let y = max(gap, (screen.height - height) / 2.0)
            let x = slot == .left ? gap : screen.width - width - gap
            return CGRect(x: x, y: y, width: width, height: height)

        case .top:
            // 顶部放大：宽度取「屏幕宽 - 边距」与「不超屏高」之间的较小值
            let byWidth = screen.width - gap * 2.0
            let byHeight = (screen.height - 48.0 - titleBarHeight) * aspect
            let width = max(minContentWidth, min(byWidth, byHeight))
            let height = height(forWidth: width)
            return CGRect(x: (screen.width - width) / 2.0, y: 24, width: width, height: height)
        }
    }

    /// 松手时按窗口位置判断想吸附到哪一格；不需要吸附时返回 nil。
    static func slot(for frame: CGRect) -> AevonSnapSlot? {
        let screen = UIScreen.main.bounds
        guard screen.width > 0, screen.height > 0, frame.width > 0 else { return nil }
        // 已经很宽的窗口别再缩成半屏，那只会让人觉得「窗口自己变小了」
        let canSplit = frame.width <= screen.width * 0.8

        if canSplit, frame.minX <= edgeThreshold { return .left }
        if canSplit, screen.maxX - frame.maxX <= edgeThreshold { return .right }
        if frame.minY <= 6 { return .top }
        return nil
    }

    static func describe(_ slot: AevonSnapSlot) -> String {
        switch slot {
        case .free: return "自由位置"
        case .left: return "左半屏"
        case .right: return "右半屏"
        case .top: return "顶部放大"
        }
    }
}
