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

/// 主窗与停靠小窗的比例（V0.0.53，AevonCoverCropV53 / AevonDockFatV53）。
///
/// 版本史：
///   · V0.0.50 及以前 = 整屏等比（内容比例 ≈ 0.4875）；
///   · V0.0.51 = 双形态（整屏 ↔ 卡片 0.72），右下角轻点切换；
///   · V0.0.52 = 只留小胖屏 0.60，内容改成「宽高取小」的完整适配 → 画面两侧出现黑边，
///     用户 Aevon(46) 第 1 条明确否定：「两侧会有黑边，正确的应该是自动剪裁画面内容」；
///   · V0.0.53 = 内容改 cover（无黑边）但比例为了不裁底压到 0.50 →
///     用户 Aevon(47) 第 4 条又指出「尺寸又变回了之前的等比例尺寸，并没有改为小胖屏」。
///   · V0.0.54 = **主窗回到 0.60 小胖屏**（用户两次明确要求），内容仍走 cover（无黑边）。
///
/// **几何硬约束**（必须写在这里，避免后面再绕回去）：屏内容是 430×881（去掉状态栏）
/// ≈ 0.4875 的窄条。窗口只要比它**胖**，按宽度铺满就必然纵向溢出、从底部裁掉。
///   0.60 时裁掉约 18.7% 的屏幕高度（≈175pt），覆盖 home 区与 App 底栏；
///   0.50 时只裁约 95pt，底栏基本留得住。
/// 所以「小胖屏」与「底栏完整」是数学互斥的，V0.0.54 按用户最新要求选前者 ——
/// 想看全底栏时把窗口往下拖高即可（高度接近 0.4875 就完全不裁）。
enum AevonSnapWindowShape {
    /// 主悬浮窗：0.60 小胖屏（用户 Aevon(45) 与 Aevon(47) 第 4 条两次指定）
    static let mainAspect: CGFloat = 0.60
    /// 停靠小窗：同样 0.60（用户 Aevon(46) 第 2 条：「吸附小窗的比例也按照小胖屏设计」）
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

    /// 停靠小窗的内容宽高比 = 0.60「小胖屏」（V0.0.53，AevonDockFatV53）。
    ///
    /// Stheno 的 `leftHeightPecent` / `rightHeightPecent` 是**独立**于宽度的高度百分比，
    /// 所以停靠态的高度本来就不跟着主窗走 —— 用户 Aevon(46) 第 2 条要求
    /// 「吸附小窗的比例也按照小胖屏设计」，于是固定成 0.60（原 9:16 = 0.5625）。
    static var dockAspect: CGFloat { return AevonSnapWindowShape.fatAspect }

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

    /// 主窗内容可视区的宽高比（宽 ÷ 高）。
    ///
    /// 版本史：0.60 小胖屏（V0.0.54）→ **屏幕比例**（V0.0.57，AevonContentFitV57）。
    ///
    /// 用户 Aevon(51) 第 1 条：「小胖屏内的内容比例被放大、画面被剪裁，内容排列依旧
    /// 存在问题，显示不全」。到这一版必须把话说清楚 —— 这是几何硬约束，不是实现细节：
    ///
    ///   屏内容 430×932（宽÷高 = 0.4614）。窗口一旦比它**胖**（0.60），
    ///   按宽度铺满就必然纵向溢出：0.60 要裁掉 ≈20% 屏高（≈186pt，正好是抖音底栏
    ///   与右侧工具栏所在的那一段）；按高度装下则必然左右各留 ≈27pt 黑边
    ///   （Aevon(45)/(46) 已两次否掉）。
    ///   **「0.60 小胖屏」与「内容完整」在「整屏画面缩放」这条路上数学互斥。**
    ///
    /// V0.0.55/V0.0.56 想绕开它：改 App 场景 frame + 在 App 进程里改 keyWindow，
    /// 让 App 自己按小窗重排。Aevon(51) 日志与截图证明两条都不成立 ——
    /// 改场景 frame 只裁了**渲染视口**（App 的 UIWindow 仍是 430×932，内容照旧按整屏
    /// 排版、视口只露左 62% = 字变大+右侧被切+右侧工具栏消失），而改 keyWindow
    /// 会让 App 真的变成 267×458 的小窗、关窗后残留 → 全屏打开大面积黑屏（第 4 条）。
    ///
    /// 所以 V0.0.57 回到 Stheno 真正在做的事（逆向键：`containerScale` / `finalScale`）：
    /// **整屏画面等比缩放，并且默认让窗口比例 = 屏幕比例** → 不裁切、无黑边、一次到位。
    /// 想回到 0.60 小胖屏的，设置里关掉「完整显示内容」即可（接受裁底）。
    static var aspect: CGFloat {
        let screen = UIScreen.main.bounds
        guard screen.width > 1, screen.height > 1 else { return 9.0 / 19.5 }
        if AevonSnap.fullContentEnabled {
            // 完整显示：比例 = 屏宽 ÷（屏高 − 状态栏那条空白）。
            // 这样按默认宽度算出来的高度刚好等于内容缩放后的高度 → 既铺满又不裁切，
            // 也不留黑边（屏幕比例算完是 0.4881，不是 0.60 —— 见上面的推导）。
            let usable = max(1, screen.height - AevonSnap.cropTop)
            return screen.width / usable
        }
        return AevonSnapWindowShape.mainAspect
    }

    /// 是否「完整显示内容」（V0.0.57，AevonContentFitV57）。
    /// 开：窗口按屏幕比例、整屏等比缩放，永不裁切；
    /// 关（**V0.0.58 起默认**，AevonPomoDefaultV58）：0.60 小胖屏 +
    /// PullOverMF 同款「可视区铺满卡片」逻辑（AevonPomoCoverV58）。
    static var fullContentEnabled: Bool {
        return AevonPrefs.bool("FullContent", default: false)
    }

    /// 小胖屏可视区位置（V0.0.58，AevonCardVisPanV58）。
    ///
    /// PullOverMF 逆向：`mfUserVisualCenterX/Y` + `mfUserVisualCenterValid` ——
    /// 卡片显示的是整屏画面的**一个可视区**（`mfCardVisualScreenRect`），铺满卡片、
    /// 溢出裁掉；可视中心存在**偏好里**（设置驱动，不是手势）。0.60 小胖屏按宽度
    /// 铺满时底部必然溢出（几何硬约束），用户想看被裁掉的底栏就把可视区往下调。
    /// 偏好存 0~100（0 = 贴顶，100 = 贴底），这里换算成 0~1。
    static var cardVisPanRatio: CGFloat {
        let v = AevonPrefs.double("CardVisPan", default: 0)
        return max(0, min(1, CGFloat(v) / 100.0))
    }

    /// 内容布局（V0.0.57；V0.0.58 加 `panRatio`）。
    ///
    /// - `fill == false`（默认）：**等比完整适配**，永不裁切，多出来的方向居中留边。
    /// - `fill == true`：铺满（cover），从底部吃溢出 —— 只给停靠小窗当缩略图用，
    ///   以及用户手动关掉「完整显示内容」时。
    ///
    /// 唯一的「裁」是**状态栏那一条空白**（`cropTop`）：App 的画面不画系统状态栏，
    /// 那 50 多 pt 在浮窗里就是一条纯空白色带，切掉它才算真正「从第一行内容开始」。
    ///
    /// - Returns: scale = 缩放比；offset = 内容左上角在窗口内容区里的位置。
    ///
    /// V0.0.58（AevonPomoCoverV58）：`fill` 分支升级为 **PullOverMF 同款可视区逻辑** ——
    /// 卡片 = 整屏画面的一个可视区，按单一缩放比铺满卡片（cover，`max`），溢出裁掉、
    /// 永不留黑边；`panRatio`（0~1）决定竖向溢出段里露哪一部分
    /// （0 = 贴顶同 V53 旧行为，1 = 贴底 —— 想看抖音底栏就调到 1）。
    /// 对应 PullOverMF 的 `mfCardVisualScreenRect` / `mfUserVisualCenterX/Y`。
    static func contentLayout(windowSize: CGSize, topPad: CGFloat,
                              source: CGSize? = nil,
                              cropTop: CGFloat? = nil,
                              fill: Bool = false,
                              panRatio: CGFloat = 0) -> (scale: CGFloat, offset: CGPoint) {
        let screen = source ?? UIScreen.main.bounds.size
        guard screen.width > 1, screen.height > 1,
              windowSize.width > 1, windowSize.height > topPad + 1 else {
            return (1, .zero)
        }
        let crop = max(0, min(cropTop ?? AevonSnap.cropTop, screen.height * 0.2))
        let usableHeight = max(screen.height * 0.5, screen.height - crop)
        let availH = max(1, windowSize.height - topPad)
        let byWidth = windowSize.width / screen.width
        let byHeight = availH / usableHeight
        if fill {
            let scale = max(0.02, max(byWidth, byHeight))
            // 竖向装不下的那段（内容坐标）；visTop = 可视区顶部在内容里的 y。
            let hidden = max(0, usableHeight - availH / scale)
            let visTop = max(0, min(hidden, panRatio * hidden))
            return (scale, CGPoint(x: (windowSize.width - screen.width * scale) / 2.0,
                                   y: topPad - crop * scale - visTop * scale))
        }
        let scale = max(0.02, min(byWidth, byHeight))
        return (scale, CGPoint(x: (windowSize.width - screen.width * scale) / 2.0,
                               y: topPad - crop * scale + (availH - usableHeight * scale) / 2.0))
    }

    /// 内容缩放比（V0.0.57）。旧签名保留，内部统一走 `contentLayout` 的 **fit** 逻辑。
    ///
    /// V0.0.53 这里取过 `max`（cover，铺满裁切）—— 用户 Aevon(51) 第 1 条把它的代价
    /// 说得很清楚：字被放大、画面被剪、右侧工具栏消失。V0.0.57 起一律 `min`（完整适配），
    /// 宁可留一点点边也不会裁掉任何内容。
    static func contentScale(windowWidth: CGFloat, clipHeight: CGFloat, topPad: CGFloat,
                             source: CGSize? = nil,
                             sourceCropTop: CGFloat? = nil) -> CGFloat {
        return contentLayout(windowSize: CGSize(width: windowWidth, height: clipHeight),
                             topPad: topPad, source: source).scale
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
