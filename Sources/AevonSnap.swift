import UIKit

/// 吸附槽位：把窗口拖到屏幕边缘松手、或轻点左右侧条时，对齐到的位置。
///
/// V0.0.45（AevonNoTopDockV45）：`.top` 已删除。
/// Aevon(38) 用户：「浮窗会吸附到桌面顶部，我不知道原因（这不应该出现）」——
/// 日志里确有 `停靠到靠顶停靠 19,5`（拖侧条时被顶边判定抢走）。
/// Stheno 只有 `leftPecent` / `rightPecent` 两个横向停靠位，**从来不存在顶部停靠**，
/// 顶边手势本身在 V0.0.43 也已全部删除，所以这里连枚举值一起删掉，杜绝任何路径再产生。
enum AevonSnapSlot: String {
    case free
    case left
    case right
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
///
/// V0.0.45（AevonNoTopDockV45 / AevonDockSizeV45）：
///   · 槽位只剩 left / right —— Stheno 只有 `leftPecent` / `rightPecent`，
///     顶边吸附是 Aevon 自己多出来的东西（Aevon(38) 明确要求不要）；
///   · 停靠宽度 42% → 30%（Stheno 的贴边态就是一根窄条），并给停靠单独的
///     宽度下限 `dockMinWidth`，不再被主窗的 `minContentWidth` 抬回去；
///   · 新增 `avoidVertical`：停靠小窗只上下让位，绝不被横向推离所在的那一侧。
enum AevonSnap {
    /// 贴边距离（Stheno `edgeWidth` 对应物）。用户要求 5pt。
    static let edgeInset: CGFloat = 5
    /// 距离屏幕边缘多少点以内算「想吸附」
    static let edgeThreshold: CGFloat = 22
    /// V0.0.37：浮窗无标题栏，高度就是纯内容高
    static let titleBarHeight: CGFloat = 0
    static let minContentWidth: CGFloat = 118

    /// 默认新开窗的宽度比例（屏宽百分比）V0.0.44：0.55 → 0.60（不再那么细）
    static let defaultWidthRatio: CGFloat = 0.60
    /// 停靠（吸附到某一侧）时的宽度比例。
    ///
    /// V0.0.45（AevonDockSizeV45）：0.42 → 0.30。用户 Aevon(38)：「吸附后的小窗还是大」。
    /// Stheno 的停靠尺寸由 `leftHeightPecent` / `rightHeightPecent` 独立按百分比记忆
    /// （高度和宽度不是一个自由度），所以贴边状态就是一个窄条 —— 0.30 × 430 ≈ 129pt 宽。
    static let dockWidthRatio: CGFloat = 0.30
    /// 停靠档的宽度下限：**不能**沿用 `minContentWidth`，
    /// 否则 430 × 0.30 = 129 会被 150 抬回去，看起来「收不小」（V0.0.44 的隐形坑）。
    static let dockMinWidth: CGFloat = 96
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
        return max(dockMinWidth, min(screen.width * dockWidthRatio, maxWidth))
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
            width = max(dockMinWidth, height * aspect)
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
        }
        return clamped(f)
    }

    /// 松手时按窗口位置判断想吸附到哪一格；不需要吸附时返回 nil。
    ///
    /// V0.0.45：只剩左右两个横向停靠位（Stheno 同款）。顶边 / 底边一律不吸附 ——
    /// 用户 Aevon(38) 明确「浮窗会吸附到桌面顶部，这不应该出现」。
    static func slot(for frame: CGRect) -> AevonSnapSlot? {
        let screen = UIScreen.main.bounds
        guard screen.width > 0, screen.height > 0, frame.width > 0 else { return nil }
        let trigger = edgeInset + edgeThreshold
        // 两侧都够近时，往更近的那侧吸；这样拖到角落也不会乱跳
        let leftGap = frame.minX
        let rightGap = screen.maxX - frame.maxX
        if leftGap > trigger && rightGap > trigger { return nil }
        return leftGap <= rightGap ? .left : .right
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
                // V0.0.45（AevonNoTopDockV45）：优先横向让位，且**别贴到屏顶/屏底**。
                // Aevon(38) 真机：小窗一停靠，主窗就被推到 79,5（顶到屏幕上边），
                // 用户看起来就是「浮窗吸附到桌面顶部」——其实是被避让算法顶上去了。
                var score = abs(c.x) + abs(c.y) * 1.5
                if t.origin.y <= edgeInset + 44
                    || t.origin.y >= screen.height - edgeInset - t.height - 44 {
                    score += 260
                }
                if score < bestScore { bestScore = score; best = c }
            }
            if best == nil {
                // 四边都放不下（屏幕被占满）：优先横向推，别往屏顶/屏底顶（V0.0.45）
                best = CGPoint(x: hit.minX - gap - f.maxX, y: 0)
            }
            guard let offset = best else { break }
            f = f.offsetBy(dx: offset.x, dy: offset.y)
        }
        return clamped(f)
    }

    /// 只上下让位（V0.0.45，AevonDockKeepSideV45）。
    ///
    /// Aevon(38) 日志铁证：`停靠到靠右停靠 19,92 180x366` —— 明明吸到右边，x 却是 19。
    /// 根因是 `avoid()` 会往左右推，把刚贴到右边缘的小窗又推到左边去（语义直接错乱）。
    /// 停靠小窗的位置由 `frame(for:from:)` 决定，让位只允许在纵向做。
    static func avoidVertical(_ frame: CGRect, obstacles: [CGRect]) -> CGRect {
        var f = frame
        guard !obstacles.isEmpty else { return f }
        let screen = UIScreen.main.bounds
        for _ in 0..<3 {
            guard let hit = obstacles.first(where: { f.intersects($0) }) else { break }
            let gap = obstacleGap
            let up = hit.minY - gap - f.maxY
            let down = hit.maxY + gap - f.minY
            // 选位移更小、且推完不撞别人的那一边
            var applied = false
            for dy in [up, down] {
                var t = f.offsetBy(dx: 0, dy: dy)
                t.origin.y = max(edgeInset, min(t.origin.y, screen.height - edgeInset - t.height))
                guard !obstacles.contains(where: { t.intersects($0) }) else { continue }
                f = t
                applied = true
                break
            }
            if !applied { break }
        }
        return clamped(f)
    }

    static func describe(_ slot: AevonSnapSlot) -> String {
        switch slot {
        case .free: return "自由位置"
        case .left: return "靠左停靠"
        case .right: return "靠右停靠"
        }
    }
}
