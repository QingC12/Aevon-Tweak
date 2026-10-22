import UIKit

/// 吸附槽位：把窗口拖到屏幕边缘松手、或轻点左右侧条时，对齐到的位置。
enum AevonSnapSlot: String {
    case free
    case left
    case right
    case top
}

/// 吸附与安全区几何（V0.0.44，AevonSthenoDockV44）。
///
/// 按 Stheno 主浮窗的百分比几何模型（逆向键：`leftPecent` / `rightPecent` /
/// `leftHeightPecent` / `rightHeightPecent` / `edgeWidth` / `medusaFrameLast`）：
///   · 位置与大小都存屏幕百分比，换机型按比例还原；
///   · `edgeWidth` 只表示「贴边留多薄的一层」，没有大安全区（用户指定 5pt）；
///   · 停靠 = 贴边 + 换成停靠档的小尺寸。
///
/// V0.0.44 关键修正：**内容可视区去掉顶部状态栏那条空白**。
/// Aevon(37) 用户反馈「主悬浮窗顶部的空白区域很大，成了竖的细长条」——
/// 浮窗承载的是一个整屏场景（430x932），宿主的 App 自己不画状态栏，
/// 那 59pt 在浮窗里就是一条纯空白，且把整个窗口拉高成细长条。
/// 现在内容按「屏宽 ×（屏高 − 顶部安全区）」计量，场景整体上移那条高度，
/// 窗口顶部就是 App 真正的第一行内容。
enum AevonSnap {
    /// 贴边距离（Stheno `edgeWidth` 对应物）。用户要求 5pt。
    static let edgeInset: CGFloat = 5
    /// 距离屏幕边缘多少点以内算「想吸附」
    static let edgeThreshold: CGFloat = 22
    /// V0.0.37：浮窗无标题栏，高度就是纯内容高
    static let titleBarHeight: CGFloat = 0
    static let minContentWidth: CGFloat = 150

    /// 默认新开窗的宽度比例（屏宽百分比）V0.0.44：0.55 → 0.60（不再那么细）
    static let defaultWidthRatio: CGFloat = 0.60
    /// 停靠（吸附到某一侧）时的宽度比例 V0.0.44：0.50 → 0.42（用户要求再小一点）
    static let dockWidthRatio: CGFloat = 0.42
    /// 读历史几何时的宽度上限：旧版本可能存着 66%~94% 的巨窗，读出来必须收回来
    static let maxRestoredRatio: CGFloat = 0.62
    /// 自动避让时和别的浮窗之间留的缝
    static let obstacleGap: CGFloat = 8

    /// 顶部安全区（状态栏那条空白）在设备上的高度。
    /// 优先读真实 safeAreaInsets；SpringBoard 里的入口容器是整屏视图，能拿到 59。
    static var visualTopInset: CGFloat {
        if let root = AevonEntryHost.activeRoot {
            let top = root.safeAreaInsets.top
            if top > 1 { return top }
        }
        if let host = AevonEntryHost.floatHost {
            let top = host.safeAreaInsets.top
            if top > 1 { return top }
        }
        let height = UIScreen.main.bounds.height
        return height > 800 ? 59 : 20
    }

    /// 内容可视区的宽高比 = 屏宽 ÷（屏高 − 顶部状态栏空白）。
    /// iPhone 15 Pro Max：430 ÷ (932 − 59) ≈ 0.4925（原来 0.461，细长条的来源）。
    static var aspect: CGFloat {
        let screen = UIScreen.main.bounds
        guard screen.width > 1, screen.height > 1 else { return 9.0 / 19.5 }
        let usableHeight = max(screen.height * 0.6, screen.height - visualTopInset)
        return screen.width / usableHeight
    }

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

    /// 停靠档宽度（轻点侧条后的小窗）
    static var dockWidth: CGFloat {
        let screen = UIScreen.main.bounds
        return max(minContentWidth, min(screen.width * dockWidthRatio, maxWidth))
    }

    /// 默认新开窗的 frame：屏宽 60%，水平居中，顶边 12% 屏高
    static func defaultFrame() -> CGRect {
        let screen = UIScreen.main.bounds
        let width = max(minContentWidth, min(screen.width * defaultWidthRatio, maxWidth))
        let height = min(height(forWidth: width), maxHeight)
        let x = (screen.width - width) / 2.0
        let y = max(edgeInset, min(screen.height * 0.12, screen.height - edgeInset - height))
        return clamped(CGRect(x: x, y: y, width: width, height: height))
    }

    /// 按宽度与安全区求一个合规 frame（宽高比锁定内容可视区比例）
    static func fitted(width: CGFloat) -> CGRect {
        let screen = UIScreen.main.bounds
        var w = max(minContentWidth, min(width, maxWidth))
        var h = height(forWidth: w)
        if h > maxHeight {
            h = maxHeight
            w = max(minContentWidth, h * aspect)
        }
        let x = (screen.width - w) / 2.0
        let y = max(edgeInset, min(screen.height * 0.12, screen.height - edgeInset - h))
        return clamped(CGRect(x: x, y: y, width: w, height: h))
    }

    /// 把任意 frame 夹进屏幕：尺寸超限先缩，再把 origin 推进屏内（只留 edgeInset）。
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

    /// 停靠到某一侧的 frame（Stheno 式：贴边 + 换成停靠档的小尺寸）。
    /// `base` 是停靠前的 frame，用来保留另一轴的中心位置。
    static func frame(for slot: AevonSnapSlot, from base: CGRect) -> CGRect {
        let screen = UIScreen.main.bounds
        guard slot != .free else { return clamped(base) }
        var width = dockWidth
        var height = height(forWidth: width)
        if height > maxHeight {
            height = maxHeight
            width = max(minContentWidth, height * aspect)
        }
        var f = CGRect(x: 0, y: 0, width: width, height: height)
        switch slot {
        case .free:
            return clamped(base)
        case .left:
            f.origin.x = edgeInset
            f.origin.y = base.midY - height / 2.0
        case .right:
            f.origin.x = screen.width - edgeInset - width
            f.origin.y = base.midY - height / 2.0
        case .top:
            f.origin.x = base.midX - width / 2.0
            f.origin.y = edgeInset
        }
        return clamped(f)
    }

    /// 松手时按窗口位置判断想吸附到哪一格；不需要吸附时返回 nil。
    static func slot(for frame: CGRect) -> AevonSnapSlot? {
        let screen = UIScreen.main.bounds
        guard screen.width > 0, screen.height > 0, frame.width > 0 else { return nil }
        let trigger = edgeInset + edgeThreshold
        if frame.minX <= trigger { return .left }
        if screen.maxX - frame.maxX <= trigger { return .right }
        if frame.minY <= trigger { return .top }
        return nil
    }

    /// 自动避让（V0.0.44）：把 frame 推开，别压住别的浮窗（尤其是已停靠的小窗）。
    ///
    /// 用户 Aevon(37)：停靠小窗会盖住主窗边缘的手势条，主窗就拖不动了。
    /// `obstacles` 是已外扩过手柄厚度的小窗矩形；这里选「位移最小且推完不撞别人」的方向。
    static func avoid(_ frame: CGRect, obstacles: [CGRect]) -> CGRect {
        var f = frame
        guard !obstacles.isEmpty else { return f }
        let screen = UIScreen.main.bounds

        for _ in 0..<3 {
            guard let hit = obstacles.first(where: { f.intersects($0) }) else { break }
            let gap = obstacleGap
            let candidates: [CGPoint] = [
                CGPoint(x: 0, y: hit.minY - gap - f.maxY),
                CGPoint(x: 0, y: hit.maxY + gap - f.minY),
                CGPoint(x: hit.minX - gap - f.maxX, y: 0),
                CGPoint(x: hit.maxX + gap - f.minX, y: 0),
            ]
            var best: CGPoint?
            var bestScore = CGFloat.greatestFiniteMagnitude
            for c in candidates {
                var t = f.offsetBy(dx: c.x, dy: c.y)
                t.origin.x = max(edgeInset, min(t.origin.x, screen.width - edgeInset - t.width))
                t.origin.y = max(edgeInset, min(t.origin.y, screen.height - edgeInset - t.height))
                guard !obstacles.contains(where: { t.intersects($0) }) else { continue }
                let score = abs(c.x) + abs(c.y)
                if score < bestScore { bestScore = score; best = c }
            }
            if best == nil {
                // 四边都放不下（屏幕被占满）：往上推，至少不压在同一块上
                best = CGPoint(x: 0, y: hit.minY - gap - f.maxY)
            }
            guard let offset = best else { break }
            f = f.offsetBy(dx: offset.x, dy: offset.y)
        }
        return clamped(f)
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
