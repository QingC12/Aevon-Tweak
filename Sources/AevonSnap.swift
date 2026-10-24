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

/// 主窗比例（V0.0.87 AevonSlimWindowV87 后只剩「细长」一档，见 `AevonSnap.aspect`）。
///
/// **几何硬约束**（必须写在这里，避免后面再绕回去）：屏内容是 430×881（去掉状态栏）
/// ≈ 0.4875 的窄条。窗口只要比它**胖**，按宽度铺满就必然纵向溢出、从底部裁掉。
///   0.60 时裁掉约 18.7% 的屏幕高度（≈175pt），覆盖 home 区与 App 底栏；
///   0.50 时只裁约 95pt，底栏基本留得住。
/// 所以「小胖屏」与「底栏完整」是数学互斥的，V0.0.54 按用户最新要求选前者 ——
/// 想看全底栏时把窗口往下拖高即可（高度接近 0.4875 就完全不裁）。
///
/// V0.0.90：停靠小窗整体回退（用户指定）—— 停靠 = V0.0.42 的「贴边吸附，
/// 只动位置不动尺寸」，之后所有「停靠变小窗 / 停靠列 / 轻点停靠还原 / Guard 停靠格吞摸」
/// 全部移除。

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

    // V0.0.90：停靠档全部尺寸常量（宽度比例 / 宽度下限 / 列上限 / 顶部锚点 /
    // 底部留白 / 槽宽下限 / 统一尺寸 / 顶部留白 / 停靠比例 / 高宽计算 / 列纵向落点 /
    // 纵向只让位）已随「停靠小窗回退到最初版本」整体移除 ——
    // 停靠只动位置，不再有小窗形态与停靠列。
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

    // V0.0.90：dockTopPadding / dockAspect 已随停靠小窗回退移除（不再有停靠态布局）。

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
        // V0.0.87（AevonSlimWindowV87）：**恒「细长」** —— 主窗比例永远等于
        // 屏宽 ÷（屏高 − 状态栏空白），整屏等比缩放进窗口，任何情况下都不裁切。
        //
        // 为什么不再给 0.60 小胖屏留开关：
        //   1) 0.60 比内容窄条（0.488）胖，按宽度铺满必然纵向溢出 ≈20% 屏高 ——
        //      「小胖屏」与「内容完整」在「整屏画面缩放」这条路上数学互斥（V0.0.57 已论证）；
        //   2) 唯一能让 App 真按小窗重排的路是 SB 侧自建场景（TrollOpen/Mango/ScreenCore
        //      三方实锤），V0.0.68~V0.0.86 共 5 版打这条路，最后一版日志（归档(8)）：
        //      P1 第 1/2/3 步全过，第 4 步 `SBDeviceApplicationSceneEntity` 的 5 个候选
        //      init **全部返回 nil**（诊断里 app / sceneHandle / displayIdentity 都在），
        //      说明这个实体在 SpringBoard 之外的构造链上根本立不起来；
        //   3) 用户 2026-10-24 决定：本版做不到小胖屏就终止项目、主窗回细长。
        // 所以这里不再读任何「内容模式」偏好（开关已随小胖屏项目整体移除）。
        let usable = max(1, screen.height - AevonSnap.cropTop)
        return screen.width / usable
    }

    /// 内容布局（V0.0.88：真重排 / 小胖屏机制已整体移除，只剩「整屏等比 fit」一条路）。
    ///
    /// - 停靠小窗（`fill == true`）：缩略图，按宽度铺满、贴顶，底部溢出裁掉（cover）。
    /// - 主窗：**等比完整适配**（fit），永不裁切，多余方向居中留边。
    ///
    /// 唯一的「裁」是**状态栏那一条空白**（`cropTop`）：App 的画面不画系统状态栏，
    /// 那 50 多 pt 在浮窗里就是一条纯空白色带，切掉它才算真正「从第一行内容开始」。
    ///
    /// - Returns: scale = 缩放比；offset = 内容左上角在窗口内容区里的位置。
    static func contentLayout(windowSize: CGSize, topPad: CGFloat,
                              cropTop: CGFloat? = nil,
                              fill: Bool = false) -> (scale: CGFloat, offset: CGPoint) {
        let screen = UIScreen.main.bounds.size
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
            return (scale, CGPoint(x: (windowSize.width - screen.width * scale) / 2.0,
                                   y: topPad - crop * scale))
        }
        let scale = max(0.02, min(byWidth, byHeight))
        return (scale, CGPoint(x: (windowSize.width - screen.width * scale) / 2.0,
                               y: topPad - crop * scale + (availH - usableHeight * scale) / 2.0))
    }

    /// 内容缩放比（fit 口径，供老调用点使用）。
    static func contentScale(windowWidth: CGFloat, clipHeight: CGFloat, topPad: CGFloat,
                             source: CGSize? = nil,
                             sourceCropTop: CGFloat? = nil) -> CGFloat {
        return contentLayout(windowSize: CGSize(width: windowWidth, height: clipHeight),
                             topPad: topPad, cropTop: sourceCropTop).scale
    }

    /// 窗口高度 = 内容高度 + 上下留白（V0.0.46）
    static func height(forWidth width: CGFloat) -> CGFloat {
        return width / max(0.2, aspect) + titleBarHeight
            + contentTopPadding + contentBottomPadding
    }

    // V0.0.90：dockHeight(forWidth:) 已随停靠小窗回退移除。

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

    // V0.0.90：dockWidth 已随停靠小窗回退移除。

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

    /// 停靠到某一格（**V0.0.90 回退到 V0.0.42 语义：只动位置，不动尺寸**）。
    /// `base` 是停靠前的 frame，用来保留当前大小与纵向位置。
    ///
    /// V0.0.90：停靠小窗整体回退（用户指定「停靠小窗也回退版本，回到最初版本」）——
    /// 不再有停靠档小尺寸、停靠列、5 格上限；贴边吸附只把窗口贴到屏幕左/右边缘，
    /// 大小保持用户当前设定（Stheno 的 leftPecent / rightPecent 同款语义）。
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
        }
        return clamped(f)
    }

    // V0.0.90：停靠列纵向落点计算已随停靠列回退移除。

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
    /// 贴边吸附动画（V0.0.90 回退 V0.0.42 语义：只动位置，参数沿用统一弹簧）
    static let dockDuration: TimeInterval = 0.42
    /// 0.80 = 落位后有极轻的一次回弹，接近系统卡片
    static let dockDamping: CGFloat = 0.80

    // V0.0.90：restoreDuration / restoreDamping / columnDuration / columnDamping
    // 已随「停靠小窗还原 / 停靠列重排」整体移除。

    /// 开窗入场：位移用弹簧，透明度单独用更短的 easeOut
    static let entryDuration: TimeInterval = 0.42
    static let entryDamping: CGFloat = 0.82
    static let entryFadeDuration: TimeInterval = 0.20

    /// 关窗退场：快速收住，不做过冲（消失时过冲会显得"抖动"）
    static let dismissDuration: TimeInterval = 0.24
    static let dismissDamping: CGFloat = 0.98
    /// 退场缩到 90%（原来是 94%，收得不够明显，像"卡了一下"）
    static let dismissScaleRatio: CGFloat = 0.90

    // V0.0.52（AevonNoShapeTapV52）：形态切换已删除（只保留小胖屏一档），
    // 原先给它的 shapeDuration / shapeDamping 一并移除。
}
