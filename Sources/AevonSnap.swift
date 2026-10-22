import UIKit

/// 吸附槽位：把窗口拖到屏幕边缘松手时，自动对齐到的位置。
enum AevonSnapSlot: String {
    case free
    case left
    case right
    case top
}

/// 吸附与安全区几何（V0.0.42，AevonSthenoDockV42）。
///
/// 按 Stheno 的主浮窗模型重做（逆向键：`leftPecent` / `rightPecent` /
/// `leftHeightPecent` / `rightHeightPecent` / `edgeWidth` / `medusaFrameLast`）：
///   · Stheno 的「停靠」是**把窗口靠到某一侧，尺寸不变**，位置与高度用百分比记忆；
///     从不会因为吸附就把窗口撑成巨窗。
///   · `edgeWidth` 对应这里的 `edgeInset`：窗口与屏幕边缘之间恒定留出的距离，
///     也是外侧手柄（角块 34pt）能被手指够到的前提。
///
/// V0.0.41 之前的 `top` 档会算出 407x884（屏 430x932），四个外角块全落在屏幕外，
/// 于是吸附完就再也缩放不了（Aevon(35) 日志：`吸附到顶部放大 407x884`）。
/// 现在所有档位都夹在安全区内，且吸附不改尺寸。
enum AevonSnap {
    static let gap: CGFloat = 8
    /// 距离边缘多少点以内算「想吸附」
    static let edgeThreshold: CGFloat = 26
    /// V0.0.37：浮窗无标题栏，高度就是纯内容高
    static let titleBarHeight: CGFloat = 0
    static let minContentWidth: CGFloat = 150

    /// 贴边避让（Stheno `edgeWidth` 对应物）：窗口与屏幕四边的最小距离。
    /// 取外角块边长 —— 窗口贴到最边上时，四个角的缩放手柄仍旧完整落在屏内。
    static var edgeInset: CGFloat { return AevonWindowView.cornerSize }

    static var aspect: CGFloat { return AevonWindowView.contentAspect }

    static func height(forWidth width: CGFloat) -> CGFloat {
        return width / max(0.2, aspect) + titleBarHeight
    }

    /// 安全区最大宽度（左右各留 edgeInset）
    static var maxWidth: CGFloat {
        let screen = UIScreen.main.bounds
        return max(minContentWidth, screen.width - edgeInset * 2)
    }

    /// 安全区最大高度（上下各留 edgeInset）
    static var maxHeight: CGFloat {
        let screen = UIScreen.main.bounds
        return max(minContentWidth / max(0.2, aspect), screen.height - edgeInset * 2)
    }

    /// 按宽度与安全区求一个合规 frame（宽高比锁定屏幕比例）
    static func fitted(width: CGFloat) -> CGRect {
        let screen = UIScreen.main.bounds
        var w = max(minContentWidth, min(width, maxWidth))
        var h = height(forWidth: w)
        if h > maxHeight {
            h = maxHeight
            w = max(minContentWidth, h * aspect)
        }
        let x = (screen.width - w) / 2.0
        let y = max(edgeInset, min(screen.height * 0.10, screen.height - edgeInset - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 把任意 frame 夹进安全区：尺寸超限先缩，再把 origin 推进屏内。
    /// 这是「贴边自动避让」的唯一实现点 —— 任何路径改完 frame 都过一遍这里。
    static func clamped(_ frame: CGRect) -> CGRect {
        let screen = UIScreen.main.bounds
        guard screen.width > 1, screen.height > 1, frame.width > 1 else { return frame }
        var f = frame

        if f.width > maxWidth {
            f.size.width = maxWidth
            f.size.height = height(forWidth: maxWidth)
        }
        if f.height > maxHeight {
            f.size.height = maxHeight
            f.size.width = max(minContentWidth, maxHeight * aspect)
        }

        let maxX = screen.width - edgeInset - f.width
        let maxY = screen.height - edgeInset - f.height
        // 屏比窗口还小时（极端机型 / 横屏）直接居中，不能反转区间
        f.origin.x = maxX >= edgeInset ? min(max(f.minX, edgeInset), maxX) : (screen.width - f.width) / 2.0
        f.origin.y = maxY >= edgeInset ? min(max(f.minY, edgeInset), maxY) : (screen.height - f.height) / 2.0
        return f
    }

    /// 停靠到某一格（Stheno 式：只动位置，不动尺寸）。
    /// `base` 是停靠前的 frame，用来保留当前大小与另一轴的位置。
    static func frame(for slot: AevonSnapSlot, from base: CGRect) -> CGRect {
        let screen = UIScreen.main.bounds
        guard slot != .free else { return clamped(base) }
        let size = clamped(base).size
        var f = CGRect(origin: .zero, size: size)
        switch slot {
        case .free:
            return clamped(base)
        case .left:
            f.origin.x = edgeInset
            f.origin.y = base.midY - size.height / 2.0
        case .right:
            f.origin.x = screen.width - edgeInset - size.width
            f.origin.y = base.midY - size.height / 2.0
        case .top:
            f.origin.x = base.midX - size.width / 2.0
            f.origin.y = edgeInset
        }
        return clamped(f)
    }

    /// 松手时按窗口位置判断想吸附到哪一格；不需要吸附时返回 nil。
    ///
    /// 阈值必须叠加 `edgeInset`：拖动时窗口已经被避让夹在离屏幕边缘 34pt 处，
    /// 若只按真实屏幕边缘判断，窗口永远进不了 26pt 区间 —— 吸附就再也触发不了
    /// （V0.0.42 改避让后踩到的连带问题）。
    static func slot(for frame: CGRect) -> AevonSnapSlot? {
        let screen = UIScreen.main.bounds
        guard screen.width > 0, screen.height > 0, frame.width > 0 else { return nil }
        let trigger = edgeInset + edgeThreshold
        if frame.minX <= trigger { return .left }
        if screen.maxX - frame.maxX <= trigger { return .right }
        if frame.minY <= trigger { return .top }
        return nil
    }

    static func describe(_ slot: AevonSnapSlot) -> String {
        switch slot {
        case .free: return "自由位置"
        case .left: return "靠左停靠"
        case .right: return "靠右停靠"
        case .top: return "靠顶停靠"
        }
    }
}
