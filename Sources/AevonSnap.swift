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

/// 主悬浮窗**唯一**形态：小胖屏（V0.0.52，AevonFatWindowV52）。
///
/// 版本史：
///   · V0.0.50 及以前 = 整屏等比（内容比例 ≈ 0.4875，266 宽必须 560 高 → 细长条）；
///   · V0.0.51 = 双形态（整屏 ↔ 卡片 0.72），右下角轻点切换。
///     但 Aevon(45) 反馈：卡片形态「内容展示不完整，丢失下半部分（应用底栏）」。
///     根因不在比例，而在内容缩放公式 —— 固定按**宽度**缩放（`scale = 窗宽 ÷ 屏宽`），
///     窗口一矮，内容高度就超出窗口，底部被 `clipsToBounds` 直接吃掉。
///   · V0.0.52 = 只保留小胖屏一档（0.60），并把内容缩放改成**完整适配**
///     （宽、高各自能容纳的缩放比取小值，横向居中、纵向贴顶），任何窗口形状都不裁内容。
///     多形态与右下角轻点切换一并移除（用户要求），右下角只负责拖动缩放。
enum AevonSnapWindowShape {
    /// 小胖屏的内容区宽高比 = 0.60（3:5）。266 宽 → 内容高 443，窗口 457。
    static let fatAspect: CGFloat = 0.60
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
    /// 贴边距离（Stheno `edgeWidth` 对应物）。
    ///
    /// V0.0.48（AevonFlushEdgeV48）：5 → **0**。
    /// Aevon(41)：「现在屏幕边缘不再保留空白区，停靠小窗可以直接贴边」。
    /// Stheno 的 `edgeWidth` 本来就是「贴边态露出的那一条厚度」，不是安全区留白；
    /// 归零后停靠小窗真正贴在屏幕边缘，主窗拖到边上也能贴齐。
    static let edgeInset: CGFloat = 0
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
    /// （高度和宽度不是一个自由度），所以贴边状态就是一个窄条。
    ///
    /// V0.0.47（AevonDock916V47）：0.30 → 0.28，并且高度不再跟随主窗比例。
    /// Aevon(40)：「停靠小窗的尺寸依旧看起来很大，可以像 stheno 一样，
    /// 停靠吸附小窗的比例改为 9:16，然后停靠时缩小」。
    /// 旧版 0.30 宽度下按主窗比例（0.4875）算出的高度是 292pt —— 129x292 就是 1:2.26 的瘦高条，
    /// 面积比用户预期大得多。现在停靠走独立的 `dockAspect`（9:16）：
    /// 0.28 × 430 ≈ 120pt 宽、内容高 ≈ 213pt，窗高约 227pt（占屏 24%，旧版 31%）。
    static let dockWidthRatio: CGFloat = 0.28
    /// 停靠档的宽度下限：**不能**沿用 `minContentWidth`，
    /// 否则 430 × 0.30 = 129 会被 150 抬回去，看起来「收不小」（V0.0.44 的隐形坑）。
    static let dockMinWidth: CGFloat = 96

    // MARK: - 停靠列（V0.0.50，AevonDockTop5V50）

    /// 停靠小窗的最大数量。用户 Aevon(43)：「总数量只有 5 个」。
    ///
    /// 超过就拒绝新的停靠（保持主悬浮窗原样），而不是无限往下堆 ——
    /// 一列超过 5 个时必然有窗被挤出屏幕，用户根本点不到。
    static let dockMaxCount = 5

    /// 第一个停靠小窗的顶边位置 = 屏高 × 10%（用户 Aevon(43)：「第一个小窗在屏幕
    /// 右上角，距离顶部 10% 处」）。
    ///
    /// Stheno 的 `leftHeightPecent` / `rightHeightPecent` 正是这种「按屏高百分比定位」
    /// 的模型（高度百分比与宽度独立），所以这里也用比例而不是绝对 pt。
    static let dockTopRatio: CGFloat = 0.10

    /// 停靠列底部留白：最后一格不压到底（home indicator 那一条）。
    static let dockBottomMargin: CGFloat = 16

    /// 停靠档宽度的绝对下限（V0.0.50）。
    ///
    /// 比 `dockMinWidth` 小 —— 5 个 9:16 小窗要在「顶部 10% ~ 底部留白」之间排下，
    /// 单窗高度上限只有屏高约 17%，对应宽度约屏宽 19%（430 屏 ≈ 82pt）。
    /// 如果沿用 96 的下限，高度会被抬回去，5 个就排不下了。
    static let dockSlotMinWidth: CGFloat = 48

    /// 停靠小窗的**统一**尺寸（宽, 高）。
    ///
    /// V0.0.50 的核心变化：不再用「屏宽 28%」直接当宽度，而是先算
    /// 「5 格必须排得下」的高度上限，再按 9:16 反推宽度：
    ///   · 高度上限 = (屏高 − 屏高×10% − 底部留白 − 4×间隙) ÷ 5；
    ///   · 单窗高度 ≤ 上限（同时也不超过 28% 宽对应的 9:16 高度）；
    ///   · 宽度 = (高度 − 顶部留白) × 9/16。
    /// iPhone 15 Pro Max（430×932）算出来约 82×160 —— 比 V0.0.49 的 120×228 小一档，
    /// 但 5 个一定能完整落在屏内（这是用户明确要求的「总数只有 5 个」的前提）。
    static var dockSize: CGSize {
        let screen = UIScreen.main.bounds
        let fallbackW = max(dockSlotMinWidth, dockMinWidth)
        guard screen.width > 1, screen.height > 200 else {
            return CGSize(width: fallbackW, height: dockHeight(forWidth: fallbackW))
        }
        let top = screen.height * dockTopRatio
        let avail = max(160, screen.height - top - dockBottomMargin)
        let slotGap = obstacleGap * CGFloat(max(1, dockMaxCount - 1))
        let maxH = (avail - slotGap) / CGFloat(max(1, dockMaxCount))
        var height = min(dockHeight(forWidth: dockWidth), maxH)
        var width = (height - titleBarHeight - dockTopPadding) * dockAspect
        if width < dockSlotMinWidth {
            width = dockSlotMinWidth
            height = dockHeight(forWidth: width)
        }
        return CGSize(width: width, height: height)
    }
    /// 读历史几何时的宽度上限：旧版本可能存着 66%~94% 的巨窗，读出来必须收回来
    static let maxRestoredRatio: CGFloat = 0.62
    /// 自动避让时和别的浮窗之间留的缝
    static let obstacleGap: CGFloat = 8

    /// 窗内上下留白（V0.0.46，AevonFloatPaddingV46）。
    ///
    /// Aevon(39)：「主悬浮窗看着不协调，顶部太小了，打开设置二级菜单时顶部的返回按钮
    /// 缺少部分（可以适当加宽一下顶部和底部）」。
    /// 根因是内容直接顶到窗口上边缘，而窗口的圆角半径有 20~24pt —— 左上角的圆弧正好
    /// 啃掉了导航栏返回按钮的角。上下各留 14pt 的深色边（看起来就是一圈屏幕边框），
    /// 内容整体下移，圆弧再也咬不到按钮，同时上下视觉也对称了。
    static let contentTopPadding: CGFloat = 14

    /// 底部深色边：V0.0.47（AevonNoBottomPadV47）已**移除**。
    ///
    /// Aevon(40)：「主悬浮窗底部新增的深色边在任何页面都是黑屏，所以直接移除，顶部的保留」。
    /// 底部那 14pt 露出来的是窗口自身的背景（纯黑），任何 App 里都是死黑一条，
    /// 看起来像把内容截断了；顶部那条之所以要留，是因为窗口圆角会啃掉导航栏返回按钮的角。
    /// 底部没有需要保护的控件（内容底边距窗口底边本来就有 home indicator 区），所以归零。
    static let contentBottomPadding: CGFloat = 0

    /// 停靠态顶部留白 = **0**（V0.0.51，AevonDockNoTopBarV51）。
    ///
    /// 用户 Aevon(44) 第 1 条：「停靠小窗的顶部出现黑条」。
    /// 主窗那 14pt 是为圆角保护导航栏返回按钮的；停靠小窗只有 158pt 高，
    /// 14pt 的深色边占了 9%，而小窗圆角只有 8pt，根本不需要这层保护 ——
    /// 于是在小窗顶部就是一条死黑。停靠态改为 0，内容直接铺到顶边。
    static let dockTopPadding: CGFloat = 0

    /// 停靠小窗的内容宽高比（V0.0.47，AevonDock916V47）= 9:16。
    ///
    /// Stheno 的 `leftHeightPecent` / `rightHeightPecent` 是**独立**于宽度的高度百分比，
    /// 所以停靠态的高度本来就不跟着主窗的整屏比例走。这里固定成用户要求的 9:16。
    static let dockAspect: CGFloat = 9.0 / 16.0

    /// 顶部实际裁掉多少（场景坐标，单位 = 整屏 pt）。
    ///
    /// = 状态栏空白 − 8pt：留一点点余量，保证导航栏那一行**一行都不缺**，
    /// 而不是正好切在它的上边缘上（差几 pt 就会啃掉返回按钮的顶）。
    static var cropTop: CGFloat {
        return max(0, visualTopInset - 8)
    }

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

    /// 内容可视区的宽高比（宽 ÷ 高）= 小胖屏 0.60（V0.0.52，AevonFatWindowV52）。
    ///
    /// 旧版这里是「屏宽 ÷（屏高 − 顶部裁剪）≈ 0.4875」，266 宽就必须 560 高，
    /// 所以窗口永远细长（Aevon(44) 抱怨的就是这个）。多形态（整屏 / 卡片）在
    /// Aevon(45) 之后已移除 —— 只留一档小胖屏，其余比例不再存在。
    static var aspect: CGFloat {
        let screen = UIScreen.main.bounds
        guard screen.width > 1, screen.height > 1 else { return 9.0 / 19.5 }
        return AevonSnapWindowShape.fatAspect
    }

    /// 内容完整显示所需的缩放比（V0.0.52，AevonFitContentV52）。
    ///
    /// 这是「内容丢失下半部分」的根因修复：
    ///   · 旧公式 `scale = 窗宽 ÷ 屏宽` 只管宽度 —— 窗口一变矮（卡片形态）内容就纵向溢出，
    ///     底部（应用底栏、抖音操作栏）被 contentClip 的 `clipsToBounds` 直接裁掉；
    ///   · 现在宽、高各自算出「刚好塞得下」的比例，取**小**的那个 ——
    ///     内容永远完整，多余的一侧留窗口深色底（横向居中、纵向贴顶）。
    ///
    /// - Parameters:
    ///   - windowWidth: 窗口宽度
    ///   - clipHeight: 内容区（contentClip）高度
    ///   - topPad: 内容顶部留白（主窗 14pt / 停靠窗 0）
    static func contentScale(windowWidth: CGFloat, clipHeight: CGFloat, topPad: CGFloat) -> CGFloat {
        let screen = UIScreen.main.bounds
        guard screen.width > 1, screen.height > 1, windowWidth > 1, clipHeight > 1 else { return 1 }
        let usableHeight = max(screen.height * 0.6, screen.height - cropTop)
        let byWidth = windowWidth / screen.width
        let avail = max(1, clipHeight - topPad)
        let byHeight = avail / usableHeight
        let scale = min(byWidth, byHeight)
        return max(0.02, scale)
    }

    /// 窗口高度 = 内容高度 + 上下留白（V0.0.46）
    static func height(forWidth width: CGFloat) -> CGFloat {
        return width / max(0.2, aspect) + titleBarHeight
            + contentTopPadding + contentBottomPadding
    }

    /// 停靠小窗的高度（V0.0.47，AevonDock916V47）：内容按 9:16 计量。
    ///
    /// 注意：主窗用 `aspect`（屏宽 ÷（屏高 − 顶部裁剪）≈ 0.4875），停靠窗用 `dockAspect`（0.5625）。
    /// 两者混用就是旧版「小窗又瘦又高」的来源 —— 停靠窗比屏幕内容区更宽，
    /// 所以宽度贴合后底部会裁掉一截（被 `clipsToBounds` 吃掉），换来整体尺寸明显变小。
    static func dockHeight(forWidth width: CGFloat) -> CGFloat {
        return width / max(0.2, dockAspect) + titleBarHeight + dockTopPadding
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
    /// `base` 是停靠前的 frame，用来保留「想停在哪个高度」；
    /// `obstacles` 是其它已停靠小窗（已按手势厚度外扩），用来竖向堆叠。
    ///
    /// V0.0.46（AevonDockStackV46）：纵向落点改走 `dockY`，第二个小窗往**下**叠，
    /// 不再被 `avoidVertical` 顶到第一个的上方（Aevon(39) 的第 2 个问题）。
    static func frame(for slot: AevonSnapSlot, from base: CGRect,
                      obstacles: [CGRect] = []) -> CGRect {
        let screen = UIScreen.main.bounds
        guard slot != .free else { return clamped(base) }
        // V0.0.50（AevonDockTop5V50）：统一尺寸（保证 5 个排得下），不再逐窗算宽度
        let size = dockSize
        var f = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        switch slot {
        case .free:
            return clamped(base)
        case .left:
            f.origin.x = edgeInset
        case .right:
            f.origin.x = screen.width - edgeInset - size.width
        }
        f.origin.y = dockColumnY(index: obstacles.count, height: size.height)
        return clamped(f)
    }

    /// 停靠小窗的纵向落点（V0.0.50，AevonDockTop5V50）。
    ///
    /// 用户 Aevon(43) 重新定义了整列：
    ///   · 第 1 个窗贴**右上角**，顶边在屏高 10% 处；
    ///   · 之后依次向下排（间隔 `obstacleGap`）；
    ///   · 最多 5 个（`dockMaxCount`），超出的停靠请求会被拒绝；
    ///   · 中间某个被还原时，下面的窗整列上移补空缺（由 `relayoutDockedColumn` 驱动动画）。
    ///
    /// 旧实现（V0.0.48~49）是「第一个在屏幕正中、放不下整列上移」——
    /// 那套锚点会随窗数不断变化（1 个在正中、3 个整体偏上），用户看到的就是
    /// 「第一个在边缘中间、第二个跑到上面」。现在锚点固定在屏高 10%，永不动摇。
    static func dockColumnY(index: Int, height: CGFloat) -> CGFloat {
        let ys = dockColumnYs(count: max(1, index + 1), height: height)
        guard !ys.isEmpty else { return UIScreen.main.bounds.height * dockTopRatio }
        return ys[min(index, ys.count - 1)]
    }

    /// 一列停靠小窗的全部纵向落点（V0.0.50，顶部 10% 锚点向下）。
    static func dockColumnYs(count: Int, height: CGFloat) -> [CGFloat] {
        let screen = UIScreen.main.bounds
        guard count > 0, height > 0, screen.height > height else { return [] }
        let top = screen.height * dockTopRatio
        let step = height + obstacleGap
        var ys: [CGFloat] = (0..<count).map { top + CGFloat($0) * step }
        // 极端情况（小屏 / 横屏）排到屏底之外：整列等量上移，保证最后一格不越界。
        // 尺寸本身已按「5 格装得下」反算，正常机型不会走到这里。
        if let last = ys.last {
            let overflow = (last + height) - (screen.height - dockBottomMargin)
            if overflow > 0 {
                ys = ys.map { max(0, $0 - overflow) }
            }
        }
        return ys
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

/// 统一的动效参数（V0.0.49，AevonFineMotionV49）。
///
/// Aevon(42) 第 3 条：「悬浮窗的过渡动画再细腻一点，不然太生硬」。
/// 生硬的两个来源其实不是时长，而是**曲线形状**：
///   1. 原来停靠 / 还原都用 `damping 0.88 + 时长 0.34`，弹簧偏硬、收尾太干脆，
///      看上去像线性缓动；iOS 系统级卡片动效基本都是 `damping 0.80~0.84`
///      —— 落位时有一点点"压住"的感觉，才是细腻。
///   2. 入场时位移和透明度用同一条曲线，前 40% 又慢又淡，像"从黑里浮出来"。
///      透明度应该更快（内容先"睁眼"，位置再落下）。
///
/// Stheno 用的是 `spring(response:dampingFraction:)` 与自研 `CustomSpringAnimation`
/// （字符串里有 `_dampingFraction` / `_fastMoveSpeed`），路线一致：弹簧，不用线性。
///
/// 这里集中管理，避免每处各自写一个魔法数字导致观感不统一。
enum AevonMotion {
    /// 停靠成小窗：位移 + 2.2 倍缩小，需要稍长一点时长，否则显得"砸"下去
    static let dockDuration: TimeInterval = 0.42
    /// 0.80 = 落位后有极轻的一次回弹，接近系统卡片
    static let dockDamping: CGFloat = 0.80

    /// 还原主窗：放大比缩小更"重"，时长再长一点，阻尼略高（避免大窗回弹太明显）
    static let restoreDuration: TimeInterval = 0.46
    static let restoreDamping: CGFloat = 0.84

    /// 开窗入场：位移用弹簧，透明度单独用更短的 easeOut
    static let entryDuration: TimeInterval = 0.42
    static let entryDamping: CGFloat = 0.82
    static let entryFadeDuration: TimeInterval = 0.20

    /// 关窗退场：快速收住，不做过冲（消失时过冲会显得"抖动"）
    static let dismissDuration: TimeInterval = 0.24
    static let dismissDamping: CGFloat = 0.98
    /// 退场缩到 90%（原来是 94%，收得不够明显，像"卡了一下"）
    static let dismissScaleRatio: CGFloat = 0.90

    /// 停靠列重排（只动 y）：轻、快，不抢停靠动画的视线
    static let columnDuration: TimeInterval = 0.36
    static let columnDamping: CGFloat = 0.86

    // V0.0.52（AevonNoShapeTapV52）：形态切换已删除（只保留小胖屏一档），
    // 原先给它的 shapeDuration / shapeDamping 一并移除。
}
