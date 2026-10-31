import UIKit
// V0.2.45（AevonCornerRadiusV245）：圆角过渡用 CATransaction / CAMediaTimingFunction，
// 显式导入 QuartzCore（UIKit 虽会间接带入，但不依赖隐式传递更稳）。
import QuartzCore

/// 缩放 / 移动手柄（V0.0.37）：带方向标记的透明视图。
/// 挂在浮窗**外侧**（Stheno 同款：手势区域为边缘外侧，绝不占窗内触摸）。
final class AevonEdgeHandleView: UIView {
    /// 这个手柄负责哪些边（角手柄是两个边的组合 → 缩放；单边条 → 移动）
    var edges: UIRectEdge = []
    /// 角手柄（横竖两边都有）= 缩放，单边条 = 移动
    var isCorner: Bool {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        return horizontal && vertical
    }
}

/// 浮窗外缘发光圈（V0.2.46，AevonFloatGlowV246；V0.2.47 收敛，AevonGlowEdgeV247）。
///
/// Aevon(21) 用户反馈：**深色模式下浮窗四周看不清**（窗是深灰、壁纸/App 也是深色，
/// 边缘糊在一起）。Stheno / ScreenCore 的做法正是给浮窗加一层「边缘发光」：
/// `SCFloatingContainerView` 身上有一整个 `_sceneGlowView`（配 4 条约束居中/定尺寸）
/// 和 `sc_isDarkAppearance` / `sc_updateCornerRadiusAndShadowPath` —— 也就是
/// **发光圈跟随窗几何、并且按深浅外观切换**。
///
/// **V0.2.47（AevonGlowEdgeV247）：Aevon(22) 判 0.2.46 那版「太明显」。**
/// 0.2.46 的参数是「外扩 12pt + 白色 0.90 + 半径 9 + border 1.0」，三条都过量：
///   · 12pt 外扩让描边落在窗外 12pt 处 —— 观感上等于窗口外面又套了一个框；
///   · 0.90 不透明度 + 半径 9 是一大片雾，不是「一圈边」；
///   · border 1.0 又给这片雾加了一条硬边。
/// 现在改成「贴边 + 只留光晕 + 压暗」：
///   · 外扩收到 **2pt**（0.2.49 再收到 **1pt**，AevonGlowTightV249）；
///   · 只留 shadowPath 光晕，深色 **0.42 → 0.46 / 半径 5 → 6**、浅色 **0.12 → 0.14 / 4 → 5**
///     （外扩收窄后靠半径补回「四周一圈柔光」的观感）；
///   · border 保持 0.5pt 的淡淡一层（深 0.22 / 浅 0.06），只用来「封口」。
/// 圈依然加在内容层**下面**（index 0），不占窗内任何像素、不参与命中（hitTest 恒 nil）。
final class AevonGlowRingView: UIView {
    /// 光晕外扩宽度（pt）。
    /// V0.2.47：12 → 2（贴边）；**V0.2.49（AevonGlowTightV249）：2 → 1**。
    ///
    /// Aevon(24)：「把边缘发光条外扩改为 1pt（只贴住窗沿 pt），呈现的画面应该是
    /// 悬浮四周出现光晕」。1pt = 只是把光晕的**起点**挪到窗沿外侧一点点，
    /// 视觉上那圈亮的是 `shadow` 从窗沿渗出来的柔光，不是一条框。
    /// 光晕强度靠 shadowRadius / shadowOpacity 给（半径略加，抵消外扩收窄后的观感）。
    static let halo: CGFloat = 1

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    /// 按当前几何 + 外观刷新（幂等；参数没变时内部直接返回）。
    ///
    /// **V0.2.49（AevonFloatAnimV249）：整段写入都在「禁用隐式动画」的事务里。**
    /// Aevon(24)：「缩放时悬浮窗边缘会出现抖动」—— 根因就在这里：缩放每帧都调
    /// 本函数改 frame / cornerRadius / borderWidth / shadowPath，而 CALayer 对这些
    /// 属性默认带 0.25 秒隐式动画，于是**每帧都重新起一段新动画**，边缘就来回抖。
    /// 关掉隐式动画后，边缘严格跟着手指走（一帧一个位置）。
    func apply(width: CGFloat, height: CGFloat, radius: CGFloat, dark: Bool) {
        let halo = AevonGlowRingView.halo
        let target = CGRect(x: -halo, y: -halo,
                            width: width + halo * 2, height: height + halo * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != target { frame = target }
        let corner = max(1, radius + halo)
        layer.cornerRadius = corner
        // 只留一条「封口」细线（0.2.46 是 1.0pt / 0.55，那是一条硬框）
        layer.borderWidth = 0.5
        layer.borderColor = (dark ? UIColor(white: 1.0, alpha: 0.15)
                                  : UIColor(white: 0.0, alpha: 0.06)).cgColor
        layer.shadowColor = (dark ? UIColor.white : UIColor.black).cgColor
        // V0.2.60（AevonGlowDimV260，用户 Aevon(34) #5）：深色模式光晕再压一档。
        // Aevon(34)：「深色模式下主悬浮窗四周的发光光晕还是有点明显，降一点亮度」。
        // 深色 0.46 / 半径 6 → 0.30 / 半径 5，封口细线 0.22 → 0.15（浅色档不动）。
        layer.shadowOpacity = Float(dark ? 0.30 : 0.14)
        layer.shadowRadius = 5
        layer.shadowOffset = .zero
        // 直接赋 path（不做相等比较：CGPath 的相等判断要走 CF 层，这里几何变才调用，
        // 调用频率由 updateEdgeGlow 的去重保证）
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: corner).cgPath
        CATransaction.commit()
    }

    /// V0.2.50（AevonMoveShadowOffV250）：**移动期间整圈光晕的投影全关**。
    ///
    /// Aevon(25) 第 2 条：「悬浮窗拖动时前 1 秒会非常卡顿掉帧，然后会恢复流畅度」。
    /// 同一个症状在 V0.0.56 出现过一次（`AevonMoveSmoothV56`），当时定位到的是
    /// 「位移期间没关投影 → 每帧重做离屏模糊」。这一版的投影比当年更贵：
    /// 0.2.47 起光晕层是一个**带 shadow 的独立图层**（深色 0.46 / 半径 6），
    /// 窗口每移动一帧，CoreAnimation 就要为它重算一次离屏模糊 —— 前几十帧尤其慢
    /// （缓存还没热），之后 CA 把结果缓存住才「恢复流畅」。
    /// 位移时把 shadowOpacity 归零（同时清掉 shadowPath，省一次路径光栅化），
    /// 抬手再按当前外观重新 `apply` 回来。光晕只有 1pt，位移中看不见它，观感无损。
    func setShadowSuppressed(_ suppressed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if suppressed {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
        } else {
            let dark = traitCollection.userInterfaceStyle == .dark
            layer.shadowColor = (dark ? UIColor.white : UIColor.black).cgColor
            // V0.2.60（AevonGlowDimV260）：与 apply() 保持同一组数（深色 0.30 / 半径 5）
            layer.shadowOpacity = Float(dark ? 0.30 : 0.14)
            layer.shadowRadius = 5
            layer.shadowOffset = .zero
            layer.shadowPath = UIBezierPath(roundedRect: bounds,
                                            cornerRadius: layer.cornerRadius).cgPath
        }
        CATransaction.commit()
    }
}

/// 浮窗上被按住的位置（V0.0.41，AevonFloatGlobalV41）。
///
/// 全局触摸通道拿不到 `UIPanGestureRecognizer`，只能拿到坐标，所以命中结果用这个
/// 枚举交给浮窗自己决定「这次拖动是移动 / 缩放 / 关闭」。
enum AevonFloatGrab {
    /// 外侧边条 → 移动窗口
    case bar(UIRectEdge)
    /// 外角块 → 从对角缩放
    case corner(UIRectEdge)
}

/// 单个 App 的浮窗外壳：纯内容（无标题栏）+ 右上悬浮 ✕ + 贴窗外边缘的手势区。
///
/// V0.0.9：App 场景按整屏尺寸渲染，浮窗只对承载容器做等比缩放。
/// V0.0.11：内容区宽高比锁定屏幕比例。
/// V0.0.12：手势期间只改外壳 `layer.transform`，抬手才提交真实 frame。
/// V0.0.13：窗口大小/位置记忆（V0.1.1 起双击改为「顶部双击恢复默认几何」）。
/// V0.0.14：拖到屏幕边缘自动吸附（左半屏 / 右半屏；顶部放大已随 V0.1.1 移除）。
/// V0.0.36：四周 8 向缩放（当时在窗内）。
/// V0.0.37（AevonSthenoEdgeBarV37）：按 Stheno 逆向证据重做手势体系 ——
///   手势区域**只在浮窗边缘外侧**（EdgeBarControlView / GestureIntroduction
///   「浮窗手势区域为边缘外侧…」），窗内 100% 留给 App 内容：
///     · 拖四条**边条**（外侧）＝ 移动窗口；
///     · 拖四个**外角块** ＝ 缩放（对角锚定，比例锁定）；
///     · **顶部边条双击** ＝ 恢复默认大小与位置（V0.1.1，双击放大/换档已移除）；
///     · 右上角悬浮 ✕ ＝ 关闭；
///     · 拖到屏幕左右边缘松手自动吸附半屏。
///   顶部标题栏（拖动条 + 关闭钮）整条移除（用户要求）。
/// V0.2.21（AevonFloat53V221，用户定档）：主悬浮窗 5:3 + 手势重做 ——
///   · 内容区比例**固定 5:3**（不再锁屏幕比例）；App 画面按 **min** 等比缩放居中
///     （letterbox：整块内容连顶栏/底栏一起完整可见，绝不裁切）；
///   · 手势全部在窗外：
///       底部 + 左右三条边条 = **长按 0.3s 后拖动**移动窗口；
///       左下 / 右下外角块 = 缩放（比例锁 5:3，锚点 = 不动的对边/顶边）；
///       **底部边条双击 = 关闭浮窗**；右上悬浮 ✕ 保留；
///       顶部不再有任何手势（顶部双击恢复默认已随本版移除）。
/// V0.0.37（AevonMedusaFrameV37）：几何记忆改用 Stheno 的方案 ——
///   全局一份 `MedusaFrameLast`（left/top/width 三个屏幕百分比，对应 Stheno 的
///   medusaFrameLast / _leftPecentLast 体系），所有浮窗共享上次位置与大小；
///   不再按 App 分别记忆。
/// V0.0.41（AevonFloatGlobalV41）：手势不再只靠手柄上的 `UIPanGestureRecognizer`。
///   Aevon(34) 真机：桌面拖动/缩放正常、全屏 App 里完全无效 —— 同一个视图层代码，
///   差别只在事件来源。全屏 App 时 `SBDeviceApplicationSceneViewController.view`
///   的命中测试不把窗外的点交给我们（V0.0.23 已确认的黑洞），pan 永远不 begun。
///   现在把手柄的**命中判定 + 位移计算**拆成 `grab(at:)` / `grabBegin` / `grabUpdate`
///   / `grabEnd`，由全局触摸通道（`UIApplication -sendEvent:`）直接驱动；
///   pan 仍保留，作为该通道不可用时的桌面兜底（通道接管时会吞掉事件，不会双触发）。
final class AevonWindowView: UIView {
    let bundleID: String
    /// V0.2.28（AevonSelfSceneV228）：可变 —— 自建场景 8 秒无首帧时整体换成主场景承载。
    private var sceneHost: AevonSceneHost
    /// 自建场景回退看门狗（8 秒无首帧 → 换主场景，单场景 App 可能拒绝连接第二个场景）
    private var selfSceneFallbackTimer: Timer?

    /// 历史常量：V0.2.22 的 5:3 竖窗比例（宽 ÷ 高 = 0.6）。
    /// V0.2.45（AevonRatio58V245）：**已不再是生效比例** —— 0.2.44 之前的默认形态
    /// 在这里只做历史记录保留（CI 1785 行断言钉住本行，按「历史串只加不改」规则不动）。
    /// 生效比例见 `contentAspect58` / `contentAspectCurrent`。
    static let contentAspect: CGFloat = 3.0 / 5.0

    /// V0.2.45（AevonRatio58V245）：**真重排档的生效比例 = 5:8 = 0.625**。
    ///
    /// 依据：参考视频逐像素实测（`交付/分析-主悬浮窗比例与圆角-2026-10-27/`）——
    /// 主窗 470×754 px = 0.623 ≈ 5:8（误差 0.3%），换算到 430pt 机型是 343×550 pt。
    /// 视频里抖音在这个窗口里拿到 **313×503 pt 的画布后自己重排**（顶栏 33pt、底栏 33pt、
    /// 底部安全区 36pt、右侧图标列 48pt 全落在原生 pt 上），不是整屏缩放也不是裁切。
    ///
    /// 与 5:3（0.6）的差别：宽 4% 而高多 4%，正是让抖音那类「按屏宽摆位 + 整页高排版」
    /// 的 App 在窗内既放得下右侧栏、又不至于把底栏挤出画布的关键。
    static let contentAspect58: CGFloat = 5.0 / 8.0

    /// V0.2.46（AevonRatioTallV246）：**当前生效比例 = 5:8 再加高 7%**（7:12 = 0.5833）。
    ///
    /// Aevon(21) 用户定档：0.2.45 的 5:8（0.625）看着「有一点胖」，要求在**不破坏真重排、
    /// 不出黑边**的前提下把高度加 5%~10%。取 7%：
    ///   344 宽 → 高 550 → **590**（+40pt），画布 430 宽 → 高 688 → **737**。
    /// 为什么加高不会出黑边：画布仍是「窗口 × 倍数」并按 1/k 等比缩回窗口
    /// （canvasSize / applyContentLayout 全链同比例），画布与窗口同比例 → 永远 1:1 贴合。
    /// 为什么对抖音有帮助：它的视频区高度跟着画布高走，画布越高、视频越靠中间，
    /// 「视频堆在中上部分」的观感随之减弱（剩下的是抖音自己把视频区锚在页面上部）。
    static let contentAspectTall: CGFloat = 7.0 / 12.0

    /// V0.2.44（AevonScreenAspectV244）：内容比例档 —— 是否跟随屏幕比例。
    ///
    /// **V0.2.45（AevonRatio58V245）改默认值：true → false。**
    /// 0.2.44 真机对测（Aevon(20)）结论：屏幕比例档是「整屏按 1/k 缩进窗口」，
    /// 三栏虽然都在位，但本质是整屏缩放，字号与浮窗尺寸脱钩、拖动窗口时内容只是
    /// 被整体拉伸，没有「真重排」的手感。用户定档：走 5:8 真重排（画布 = 窗口），
    /// 这才是参考视频的形态。屏幕比例档保留为可选（开 = 回到 0.2.44 行为）。
    ///
    /// **V0.2.47（AevonPrefsFixedV247）：写死 false，设置页开关删除。**
    /// Aevon(22) 用户定档：「将现在的悬浮窗画布倍数等设置内的开关改为默认状态，
    /// 并且移除设置中的开关」。默认状态 = 真重排档 —— 于是这一项从「可切换的档位」
    /// 降级成常量，屏幕比例档（0.2.44 形态：整屏等比缩进，不是真重排）随之退休。
    /// 盘上的旧键仍会被一次性回写成 false（见 fixContentPrefsIfNeeded），
    /// 免得将来回退版本的人被旧值带跑。
    static var usesScreenAspect: Bool { false }

    /// 当前生效的内容区宽高比：屏幕比例档 = 屏宽 / 屏高；否则 5:8 真重排（0.625）。
    /// 结果按「档位 + 屏幕尺寸」缓存（同一台设备上比例只可能被偏好改变）。
    static var contentAspectCurrent: CGFloat {
        let mode = usesScreenAspect
        let screen = UIScreen.main.bounds.size
        if cachedAspect > 0, cachedAspectMode == mode, cachedAspectScreen == screen {
            return cachedAspect
        }
        let value: CGFloat
        if mode, screen.width > 1, screen.height > 1 {
            value = screen.width / screen.height
        } else {
            // V0.2.45（AevonRatio58V245）：5:3 → 5:8（生效比例只此一处）
            // V0.2.46（AevonRatioTallV246）：5:8 → 5:8 加高 7%（7:12），用户定档
            value = contentAspectTall
        }
        cachedAspect = value
        cachedAspectMode = mode
        cachedAspectScreen = screen
        return value
    }

    private static var cachedAspect: CGFloat = 0
    private static var cachedAspectMode = false
    private static var cachedAspectScreen: CGSize = .zero

    private static let minContentWidth: CGFloat = 240

    /// V0.2.45（AevonCornerRadiusV245）：圆角半径 = **窗宽 × 11.1%**，夹在 [20, 44]。
    ///
    /// 依据：参考视频逐像素拟合（圆弧最小二乘，残差 0.13px）——
    /// 470px 宽窗 → r = 52px ≈ 35pt（393pt 机型）/ 38pt（430pt 机型）= 窗宽的 11.1%；
    /// 被拉到 567px 宽时 r 仍是 54~60px，说明它是**固定 pt 量级**而不是随宽度等比放大，
    /// 所以用百分比 + 上下夹来模拟（344 宽 → 38pt，与视频的 38pt 完全一致）。
    ///
    /// 历史：0.2.44 之前是写死的 12pt（窗宽的 4.5%），比参考视频小 3 倍。
    static func cornerRadius(for width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 1 else { return 20 }
        return min(44, max(20, (width * 0.111).rounded()))
    }

    /// V0.2.45（AevonCornerRadiusV245）：当前已应用的圆角（去重，避免每帧重写 layer）
    private var appliedCornerRadius: CGFloat = 0
    /// 外侧手势区厚度（边条）与外角块边长（pt）。Stheno 的 edgeWidth 同位概念。
    /// V0.2.23（AevonFloatWideGripV223）：Aevon(107) 反馈「不容易触发」，18/34 → 26/44。
    /// V0.2.26（AevonFloatSthenoEdgeV226）：26 → 30 —— 对齐 Stheno edgeWidth 默认值
    /// （GestureBorderWidth，其默认 30pt 用户可调；我们取默认起步）。
    static let barThickness: CGFloat = 30
    static let cornerSize: CGFloat = 44
    /// V0.2.24（AevonFloatGripOverlapV224）：手柄向窗内压边宽度（pt）——
    /// 边线两侧都算手势区，瞄准边缘的指尖不再滑进 App 内容。
    static let gripOverlap: CGFloat = 10

    /// 全局唯一的偏好域，和设置面板共用
    private static let prefsSuite = "com.Aevon"
    /// Stheno 式全局几何记忆键（medusaFrameLast 对应物）
    private static let frameMemoryKey = "MedusaFrameLast"

    private let contentClip = UIView()
    private let hintLabel = UILabel()
    /// V0.2.46（AevonFloatGlowV246）：边缘发光圈（深色模式看清窗口四周）
    private let glowRing = AevonGlowRingView()
    /// 上一次应用发光圈的参数（几何 / 圆角 / 深浅外观任一变化才重刷）
    private var appliedGlowKey = ""
    /// 上一次应用发光圈时的外观（深色 = true），供外观巡检比较
    private var appliedGlowDark: Bool?

    private var moveOriginFrame: CGRect = .zero
    private var moveOriginPoint: CGPoint = .zero
    private var resizeOriginFrame: CGRect = .zero
    private var resizeOriginPoint: CGPoint = .zero
    /// 本次缩放抓的是哪几条边（角块 = 两边组合）
    private var resizeOriginEdges: UIRectEdge = []
    /// 缩放锚点（unit 坐标）：对角固定点，缩放时它不动
    private var resizeAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)

    /// 手势进行中（此时只允许改 transform，不允许改 frame）
    private var isLiveResizing = false
    /// V0.2.67（AevonFrameGuardV267）：close() 置位；置位后 persistFrame 不再发布矩形。
    var isClosing = false
    /// 边条拖动进行中（V0.2.21 建；V0.2.27 起落指即拖，AevonFloatEdgeGripV227）
    private var isBarHoldMoving = false
    /// V0.2.50（AevonMoveShadowOffV250）：位移进行中（此时光晕投影必须全关）
    private var isMovingWindow = false
    /// V0.2.43（AevonCanvasScaleV243）：最近一次提交给场景的画布尺寸（去重，
    /// 避免每次 layoutSubviews 都跨进程写一遍 settings.frame）
    private var appliedCanvasSize: CGSize = .zero
    /// V0.2.44（AevonScreenAspectV244）：当前生效的内容比例 + 变更监听定时器
    /// （设置页切「内容比例跟随屏幕」后 0.5 秒内自动重建窗口几何，不用重开浮窗）
    private var appliedAspect: CGFloat = 0
    private var aspectWatchTimer: Timer?

    init(sceneHost: AevonSceneHost, bundleID: String, title: String) {
        self.bundleID = bundleID
        self.sceneHost = sceneHost
        super.init(frame: CGRect.zero)

        /* V0.2.86（AevonNoFlashBirthV286）—— **出生即隐形**，这一行就是「闪一下」的根治。
         *
         * 0.2.83 摘掉遮罩后，显形只留一个点（onCanvasSettled → revealEntryNow）。但那次
         * 漏了出生瞬间：本类 `super.init` 出来的 alpha 默认是 **1**，而外层是
         *     host.addSubview(windowView)      ← 第 913 行，此刻 alpha = 1，已上屏
         *     host.bringSubviewToFront(...)
         *     windowView.alpha = 0             ← 第 932 行，才藏起来
         * 中间还要装垫底图、铺两个 timer —— 窗以**空面板**（或上一关旧帧）露出一帧，
         * 随后被藏 1.1 秒，再淡入。Aevon(59) 原话「打开悬浮窗时依旧会闪一下悬浮窗，
         * 然后在出现最终悬浮窗和内容」，那「闪一下」与「最终悬浮窗」就是同一个窗的
         * 两次上屏，中间隔着那段 alpha 复位。
         *
         * 修法：构造完立刻 alpha = 0 —— 窗从「存在」的第一纳秒起就不可见，显形点
         * 仍然只有 onCanvasSettled 一个，中途没有任何可见帧。 */
        alpha = 0

        // V0.1.5（AevonNoSnapV105）：左右吸附与左右分屏一起移除 ——
        // 单窗模式下不存在并排，吸附只会让窗在松手瞬间突然变形。
        // 几何一律走 Stheno 式全局记忆（medusaFrameLast 方案）。
        var sizeSource = "默认尺寸"
        let restored = AevonWindowView.rememberedFrame(fallback: AevonWindowView.defaultFrame())
        if restored != AevonWindowView.defaultFrame() { sizeSource = "已恢复上次几何（全局记忆）" }

        frame = CGRect(x: restored.minX, y: restored.minY,
                       width: restored.width, height: restored.height)

        backgroundColor = .clear
        // V0.0.37：窗口本体不裁剪 —— 外侧手势区要伸到 frame 外面；
        // 圆角裁剪由 contentClip 负责。
        clipsToBounds = false

        // 内容区（全高，无标题栏）。圆角 + 裁剪都在这一层。
        contentClip.frame = bounds
        contentClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentClip.clipsToBounds = true
        // V0.2.45（AevonCornerRadiusV245）：圆角 = 窗宽 × 11.1%（先按初始宽度落一次，
        // 之后每次布局/缩放抬手都会在 updateCornerRadius 里跟随）
        let initialRadius = AevonWindowView.cornerRadius(for: restored.width)
        contentClip.layer.cornerRadius = initialRadius
        appliedCornerRadius = initialRadius
        contentClip.backgroundColor = UIColor(white: 0.18, alpha: 1.0)
        // V0.2.46（AevonFloatGlowV246）：边缘发光圈先加 → 永远在内容层下面，
        // 只在窗口外沿露出光晕（深色模式靠它把窗口边和背景分开）。
        glowRing.isUserInteractionEnabled = false
        glowRing.backgroundColor = .clear
        addSubview(glowRing)
        addSubview(contentClip)

        // V0.2.55（AevonDockTapAnywhereV255，用户 Aevon(29) #2）：停靠小窗**任意位置
        // 轻点 = 装回主窗**，不再只有边条能点。停靠态内容层交互已关
        // （`setContentInteraction(false)`，不会误转发进 App），这里把 tap 挂在窗口
        // 本体上：dock 态才生效；非 dock 态一举一动都不管（guard 掉）。
        // 与全局通道「点边条装回」语义相同、幂等（restoreDocked 有 0.8s 仲裁防抖）。
        let dockTap = UITapGestureRecognizer(target: self,
                                             action: #selector(handleDockTapAnywhere(_:)))
        dockTap.cancelsTouchesInView = false
        dockTap.delaysTouchesBegan = false
        dockTap.delaysTouchesEnded = false
        addGestureRecognizer(dockTap)

        contentClip.addSubview(sceneHost.container)

        // 等待画面提示（拿到第一帧后自动消失）
        //
        // V0.2.50（AevonHintCleanV250）：Aevon(25) 第 6 条「每次悬浮窗打开设置时都会出现
        // 这个文字提示」—— 上一版那两行是**开发者排障文案**（还带日志路径），
        // 只要首帧慢半拍就会闪一次，观感等同于报错。两处一起改：
        //   ① 文案只留一句中性的「正在准备…」，不再出现任何路径 / 开发者字样；
        //   ② **z 序放到底层**（插在场景容器下面）：即便它该显示的时候，也绝不会盖住
        //      已经出画的真实内容 —— 上一版的观感问题一半来自它压在内容上面。
        //   ③ 另有 1.6 秒兜底强制隐藏（见下面的 hintFailsafe），任何首帧探测失灵都不会留字。
        hintLabel.frame = contentClip.bounds
        hintLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.textColor = UIColor(white: 0.72, alpha: 1.0)
        hintLabel.font = UIFont.systemFont(ofSize: 12.5)
        hintLabel.text = "正在准备画面…"
        contentClip.insertSubview(hintLabel, belowSubview: sceneHost.container)

        sceneHost.onFirstContent = { [weak self] in
            self?.handleFirstContent()
        }
        // V0.2.50（AevonHintCleanV250）：兜底 1.6 秒无条件隐藏 —— 首帧探测失灵时
        // （自建场景被 App 拒绝、presenter 迟到等）也绝不在窗口里留一行字。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.hintLabel.isHidden = true
        }

        // V0.2.28（AevonSelfSceneV228）：自建场景看门狗 —— 单场景 App 可能拒绝连接
        // 第二个场景（FrontBoardAppLauncher known issue），8 秒无首帧自动回退主场景承载。
        if sceneHost.isSelfBuilt {
            let timer = Timer(timeInterval: 8.0, repeats: false) { [weak self] _ in
                self?.fallbackToPrimarySceneIfEmpty()
            }
            RunLoop.main.add(timer, forMode: .common)
            selfSceneFallbackTimer = timer
        }

        // V0.2.24（AevonFloatTopBarV223 退休）：顶部留白栏整体移除 —— Aevon(108) 实测
        // 它盖住内容造成显示异常。顶部不再有任何覆盖物。

        // V0.0.37（AevonSthenoEdgeBarV37）：外侧边缘手势区（V0.2.27 起 = 左/右/底三条边条
        // 落指即拖 + 底部两角块，顶边条删除）
        installOutsideGestureHandles(width: restored.width, height: restored.height)

        // V0.2.26（AevonPiPProbeV226）：真重排路线 P0 探测（只读，一次一进程）
        AevonWindowView.probeSceneRoutesOnce()

        // V0.2.44（AevonScreenAspectV244）：记下开窗时的内容比例，并每 0.5s 检测一次
        // 偏好是否被改（设置页在另一个进程）—— 变了就原地重建窗口几何，不用重开浮窗。
        appliedAspect = AevonWindowView.contentAspectCurrent
        startAspectWatch()

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)"
            + "（外侧手势区，内容比例 \(AevonWindowView.usesScreenAspect ? "跟随屏幕（整屏等比缩进窗口）" : "7:12 竖窗（0.2.46 用户定档：比 5:8 高 7%）")"
            + "（AevonFloat53V221 AevonFloat53PortraitV222），"
            + "内容=整屏场景呈现（AevonFloatSceneLayoutV224 AevonFloatHostedResizeV225，"
            + "真重排唯一通路=自建场景路线，P0 探测 AevonPiPProbeV226），"
            + "手势区=左/右/底全宽 30/44+压边10 落指即拖（AevonFloatWideGripV223"
            + " AevonFloatGripOverlapV224 AevonFloatSthenoEdgeV226 AevonFloatEdgeGripV227，顶边条已删），"
            + "缩放=实时改窗宽 + 呈现层等比缩放，不改 App 画布也不冻结画面（AevonCanvasFixedV248），"
            + "快照能力转为黑屏守卫兜底（AevonFloatSnapResizeV226 AevonFloatSnapCacheV227）"
            + "全程圆角（AevonFloatRoundResizeV224），"
            + "内容 \(Int(restored.width))x\(Int(restored.height))，"
            + "\(sizeSource)）（AevonSthenoEdgeBarV37）")
        let initCanvas = AevonWindowView.canvasSize(for: restored.size)
        AevonLog.info("[窗口] 内容比例：\(AevonWindowView.usesScreenAspect ? "屏幕比例档（整屏原生排版 + 等比缩进窗口）" : "7:12 真重排档（画布恒 = 屏宽 × 屏宽/比例，与窗口尺寸脱钩）")"
            + "，比例 \(String(format: "%.4f", appliedAspect))"
            + "，窗口 \(Int(restored.width))x\(Int(restored.height))"
            + "，画布 \(Int(initCanvas.width))x\(Int(initCanvas.height))"
            + "，倍数 \(String(format: "%.2f", AevonWindowView.canvasScale))"
            + "（实际缩放 \(String(format: "%.2f", initCanvas.width / max(1, restored.width)))）"
            + "，圆角 \(Int(AevonWindowView.cornerRadius(for: restored.width)))pt"
            + "，外观 \(traitCollection.userInterfaceStyle == .dark ? "深色·边缘发光" : "浅色·淡描边")"
            + "（AevonScreenAspectV244 AevonRatio58V245 AevonRatioTallV246 AevonCanvasScaleV246 AevonCanvasFixedV248 AevonCornerRadiusV245 AevonFloatGlowV246）")
        updateEdgeGlow()
        // V0.2.48（AevonNoAutoLockV248）：浮窗在 → 不让系统按自动锁定暗屏/锁屏
        AevonWindowView.beginNoAutoLock()
        // V0.2.49（AevonNoAutoLockV249）：真正压住空闲熄屏（每 20 秒重申一次）
        startIdleKick()
        // V0.2.49（AevonUnlockGuardV249）：解锁 / 回前台后重新布防（治「解锁后黑 1 秒」）
        installSystemWakeObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 熄屏压制（V0.2.49，AevonNoAutoLockV249）

    /// 空闲熄屏重申定时器（V0.2.50：8 秒一次，见 `startIdleKick`）
    private var idleKickTimer: Timer?
    /// 上一次的压制结果位（只在变化时记日志，免得每 8 秒刷一行）
    private var idleKickMask: NSInteger = -1

    private func startIdleKick() {
        let mask = AevonWindowView.kickIdleTimerIfNeeded()
        idleKickMask = mask
        // V0.2.50（AevonNoAutoLockV250）：Aevon(25) 第 5 条「开悬浮窗时，依旧跟随系统时间
        // 锁屏」。0.2.49 的三条通道在这台机器上**全都没命中**（日志实锤 mask=4
        // → 只剩 UIApplication.isIdleTimerDisabled 那一条，而它在 SB 进程不进计时器）。
        // 本版补齐两条真正能压住的路子，并把节拍从 20 秒收到 8 秒：
        //   · `SBIdleTimerGlobalCoordinator` 类名/单例名/方法名全部扩表（含下划线私有变体）；
        //   · `SBLockScreenManager -lockUIFromSource:withOptions:` 兜底拦截（电源键放行）。
        // 8 秒 ≪ 系统最短「自动锁定 30 秒」，既压得住又不会每秒烧一次私有 API。
        let lockBlock = AevonInstallLockBlock()
        // V0.2.53（AevonDeactGateRetiredV253）：0.2.51 的「回桌面守画闸」退役 ——
        // 真机日志实锤它一次都没拦到（场景照常 deactivation），却站在系统场景
        // 状态机的登记路径上（系统手势失效的头号嫌疑）。黑屏交给守卫兜底。
        AevonLog.info("[窗口] 熄屏压制已启动（\(AevonWindowView.idleKickMaskText(mask))，"
            + "锁屏拦截=\(lockBlock ? "已装" : "不可用")，之后每 8 秒重申一次）"
            + "（AevonNoAutoLockV249 AevonNoAutoLockV250）")
        let timer = Timer(timeInterval: 8.0, repeats: true) { [weak self] _ in
            let now = AevonWindowView.kickIdleTimerIfNeeded()
            guard let self, now != self.idleKickMask else { return }
            self.idleKickMask = now
            AevonLog.info("[窗口] 熄屏压制方式变化 → \(AevonWindowView.idleKickMaskText(now))"
                + "（AevonNoAutoLockV249 AevonNoAutoLockV250）")
        }
        RunLoop.main.add(timer, forMode: .common)
        idleKickTimer = timer
    }

    private static func idleKickMaskText(_ mask: NSInteger) -> String {
        var parts: [String] = []
        if mask & 1 != 0 { parts.append("SBIdleTimerGlobalCoordinator.resetIdleTimer") }
        if mask & 2 != 0 { parts.append("resetIdleTimerAndUndim") }
        if mask & 4 != 0 { parts.append("UIApplication.isIdleTimerDisabled") }
        if mask & 8 != 0 { parts.append("空闲计时器禁用断言") }
        if mask & 16 != 0 { parts.append("私有变体 _resetIdleTimer") }
        return parts.isEmpty ? "全部不可用（本机压不住熄屏，按系统设置走）" : parts.joined(separator: " + ")
    }

    // MARK: - 解锁 / 回前台重新布防（V0.2.49，AevonUnlockGuardV249）

    /// 系统回到前台 / 解锁的通知令牌
    private var wakeObservers: [NSObjectProtocol] = []

    /// Aevon(24)：「悬浮窗打开期间，如果锁屏再解锁，悬浮窗内容会黑屏 1 秒才能出现画面」。
    ///
    /// 锁屏那一刻场景被置后台、远程表面回收；解锁后 App 要重新画一帧才回来。
    /// 我们能在「解锁」这个事件上立刻重申前台，把这个过程压到最短 ——
    /// 这也是 0.2.47 那条守卫唯一缺的触发源（它只接了「全屏画面离场」）。
    private func installSystemWakeObservers() {
        guard wakeObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [UIApplication.didBecomeActiveNotification,
                                          UIApplication.willEnterForegroundNotification]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.handleSystemWake(noteName: note.name.rawValue)
            }
            wakeObservers.append(token)
        }
    }

    private func handleSystemWake(noteName: String) {
        guard window != nil, sceneHost.hasContent, !isTearingDown else { return }
        // 已经在画就什么都不做 —— 别为了一个通知去写场景状态机
        if sceneHost.contentLooksRendering == true { return }
        AevonLog.info("[窗口] 系统回前台/解锁（\(noteName)）→ 布防守卫（当前 \(sceneHost.stateSummary())）"
            + "（AevonUnlockGuardV249）")
        armBackgroundGuard(reason: "解锁/回前台")
    }

    private func removeSystemWakeObservers() {
        let center = NotificationCenter.default
        for token in wakeObservers { center.removeObserver(token) }
        wakeObservers.removeAll()
    }

    // MARK: - 真重排路线 P0 探测（V0.2.26，AevonPiPProbeV226）

    /// Aevon(1) 定案：SB 侧「事后改场景尺寸」路线已被 0.0.x 档案三重实锤排除
    /// （V63：dc ivar 直写全链成功 App 仍不重排；V64：FBScene 无 resizesHosted 选择子；
    /// V87：SBDeviceApplicationSceneEntity 5 个候选 init 全 nil）。
    /// 剩余唯一通路 = **创建时烙定画布**（Stheno 在用的 FBSceneManager
    /// `_createSceneWithDefinition:settings:...` 族）或 PiP handle（TrollOpen
    /// `__pipSceneHandle` / PullOverX video-hosted 轨道）。本探测只读、一次一进程，
    /// 为下轮 P1 立项钉运行时判据 —— 不改变任何现有行为。
    private static var didProbeSceneRoutes = false
    private static func probeSceneRoutesOnce() {
        guard !didProbeSceneRoutes else { return }
        didProbeSceneRoutes = true
        let exception = AevonShieldRun {
            var parts: [String] = []
            let fbMethods = AevonMethodNamesForClass("FBSceneManager") ?? []
            let createWithSettings =
                "_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:"
            parts.append("FBSceneManager._createScene(带settings)=\(fbMethods.contains(createWithSettings) ? "响应" : "无")")
            parts.append("createSceneWithDefinition:initialParameters:=\(fbMethods.contains("createSceneWithDefinition:initialParameters:") ? "响应" : "无")")
            let sbVCMethods = AevonMethodNamesForClass("SBDeviceApplicationSceneViewController") ?? []
            parts.append("SceneVC.setSceneResizesHostedContext:=\(sbVCMethods.contains("setSceneResizesHostedContext:") ? "响应" : "无")")
            for name in ["FBSceneHostManager", "SBDeviceApplicationSceneHandle",
                         "FBSSceneParameters", "FBSMutableSceneDefinition"] {
                var exists = false
                AevonShieldRun { exists = NSClassFromString(name) != nil }
                parts.append("\(name)=\(exists ? "类在" : "无")")
            }
            AevonLog.info("[场景] 路线探测：\(parts.joined(separator: " "))（AevonPiPProbeV226）")
        }
        if let exception = exception {
            AevonLog.warn("[场景] 路线探测异常：\(exception)（AevonPiPProbeV226）")
        }
    }

    /// 无记忆时的默认几何：宽 62% 屏宽（5:3 竖窗 → 高约 48% 屏高），顶边 10% 屏高，水平居中。
    private static func defaultFrame() -> CGRect {
        let screen = UIScreen.main.bounds
        let aspect = contentAspectCurrent
        // V0.2.45（AevonRatio58V245）：默认窗宽 0.62 → **0.80 屏宽**。
        // 依据参考视频实测：窗宽占屏宽 79.7%（470/590），即 430pt 机型 344×550pt。
        // 这个尺寸下画布 = 窗口（倍数 1.00）时抖音拿到的就是它原生排版的尺寸，
        // 顶栏 / 底栏 / 右侧图标列全部落在画布内。
        let width = max(minContentWidth, min(screen.width * 0.80,
                                             (screen.height * 0.92) * aspect))
        let height = width / aspect
        return CGRect(x: (screen.width - width) / 2.0,
                      y: max(24, screen.height * 0.10),
                      width: width, height: height)
    }

    /// V0.2.28（AevonSelfSceneV228）：自建场景的画布尺寸 = 开窗时的内容区尺寸
    /// （恢复几何或默认）。开窗瞬间用它烙定场景画布。
    static func plannedContentSize() -> CGSize {
        let restored = rememberedFrame(fallback: defaultFrame())
        return CGSize(width: restored.width, height: restored.height)
    }

    /// V0.2.43（AevonCanvasScaleV243）：内容画布倍数。
    ///
    /// 0.2.42 真机（Aevon(18)）定论：S2 主场景改画布 = **真重排成立**（所有 App 都重排了），
    /// 但画布 = 窗口尺寸时 App 的逻辑宽度只有 272pt —— 比任何一台 iPhone 都窄，
    /// 而字号是固定 pt 值 → 用户看到的就是「文字比全屏大、显示的内容变少」。
    ///
    /// V0.2.45（AevonRatio58V245）：**默认值 1.30 → 1.00**。
    /// 0.2.44 之后窗口比例改成 5:8、默认宽 344pt，逻辑宽已经落在原生手机区间
    /// （参考视频里抖音拿到的就是 313pt 画布，排版完全正常），不再需要放大倍数来
    /// 伪装密度 —— 倍数 > 1 反而会把字压小、把画布推离「App 原生排版」的形态。
    /// 滑杆保留：想在一屏里塞更多内容时可以再放大（画布宽仍被屏宽夹住）。
    ///
    /// **V0.2.46（AevonCanvasScaleV246）：默认值 1.00 → 1.30（Aevon(21) 真机对测）。**
    /// 用户在 1.00 / 1.30 / 1.60 三档实测：1.00（画布 = 窗口 315×504）**字依旧很大、
    /// 一屏装不下内容**；1.30（画布 430×688，被屏宽夹住 → 实际 431→430 宽、k = 0.80）
    /// 「字正常了，而且内容确实重排」。原因是字号是固定 pt：画布逻辑宽越接近真实手机
    /// 宽度（430），排出来的字与全屏一致，再按 1/k 缩进窗口 → 观感正常。
    /// 1.60 与 1.30 都被屏宽夹到同一张 430 宽画布（只是缩放系数不同），
    /// 所以 1.30 是「画布吃满屏宽 + 缩放系数最不糊」的那个甜点，定为默认。
    /// 升级老用户的一次性回写见 fixContentPrefsIfNeeded（键值一律回到定档值）。
    ///
    /// **V0.2.47（AevonPrefsFixedV247）：滑杆删除，倍数写死 1.30。**
    /// Aevon(22) 用户定档：「将现在的悬浮窗画布倍数等设置内的开关改为默认状态，
    /// 并且移除设置中的开关」。1.30 是 0.2.46 三档真机对测出来的甜点
    /// （画布被屏宽夹到 430 宽 = 与真机同宽，字号与全屏一致，再按 1/k 缩回窗口），
    /// 没有继续暴露给用户的理由 —— 暴露它只会制造「字大了/字小了」的反复。
    static let canvasScaleDefault: CGFloat = 1.30

    /// 当前生效的画布倍数（常量；保留属性名是为了让调用点与历史日志一字不变）。
    static var canvasScale: CGFloat { canvasScaleDefault }

    /// 窗口内容尺寸 → 场景画布尺寸。
    ///
    /// V0.2.44（AevonScreenAspectV244）：屏幕比例档 → 画布恒等于**整屏原生尺寸**，
    /// App 的排版与全屏逐像素一致；呈现层按 1/k 等比缩进窗口（见 applyContentLayout，
    /// 那里 k = 画布宽 / 窗口宽，高度同系数 → 绝不会出现 X/Y 不等比的拉伸）。
    /// 5:3 档 → 等比放大 k 倍，宽不超屏宽（0.2.43 行为）。
    ///
    /// **V0.2.48（AevonCanvasFixedV248）：画布与窗口尺寸脱钩，恒等于「屏宽 × 屏宽/比例」。**
    ///
    /// Aevon(23) 三条反馈其实同源，全部指向「画布跟着窗口缩」这一个决定：
    ///   ① 「缩到最小时字体反而变大」—— 画布 = 窗口 × 1.30，窗口 240 时画布只有 312，
    ///      App 的字号是**固定 pt**（抖音 17pt 不随画布宽缩放），312 宽画布上 17pt 字
    ///      占的比例比 430 宽画布上大得多，再按 1/1.30 缩回窗口 → 字相对窗口更大了。
    ///   ② 「右侧点赞栏显示不全 / 不显示」—— 抖音的右侧图标列按 **UIScreen 屏宽**摆位，
    ///      画布 312 / 396 都比屏宽 430 窄，图标列被画布右边界裁掉（截图为证）。
    ///   ③ 「缩放时整窗黑屏」—— 每次缩放提交都要写一次场景画布，App 重排期间表面重绘，
    ///      于是拖动过程中看到的是黑。
    ///
    /// 三者一起改掉：**画布恒定 = 屏宽（430）× 屏宽/比例（737）**，于是
    ///   · App 永远拿到和真机一样宽的画布 → 字号比例恒定、右侧栏永远在画布内；
    ///   · 窗口缩放只改「窗口 frame + 呈现层 scale(窗口宽/画布宽)」，**一次场景写都不发生**
    ///     → 拖动过程实时出画、不黑、不重排，也不会把 App 的内部布局弄坏（断层/黑屏）。
    static func canvasSize(for windowSize: CGSize) -> CGSize {
        _ = windowSize   // 保留形参：全链调用点与历史日志口径不变（画布已与窗口脱钩）
        let screen = UIScreen.main.bounds.size
        let width = floor(max(1, screen.width))
        let aspect = max(0.2, contentAspectCurrent)
        return CGSize(width: width, height: floor(width / aspect))
    }

    /// 首帧到达（主场景 / 自建场景共用）。
    private func handleFirstContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hintLabel.isHidden = true
            // V0.2.28：自建场景等到首帧 = 真重排成立的硬证据，看门狗使命完成
            if self.sceneHost.isSelfBuilt {
                self.selfSceneFallbackTimer?.invalidate()
                self.selfSceneFallbackTimer = nil
            }
            // V0.2.27（AevonFloatSnapCacheV227）：首帧到达后空闲预抓快照，
            // 之后的缩放手势落指即用缓存图（零同步渲染）
            self.scheduleSnapshotRecapture()
        }
    }

    /// V0.2.28（AevonSelfSceneFallbackV228）：自建场景 8 秒无首帧 →
    /// 销毁自建场景，换成主场景全屏接管承载（0.2.27 形态）—— 绝不黑屏。
    private func fallbackToPrimarySceneIfEmpty() {
        selfSceneFallbackTimer = nil
        let host = sceneHost
        guard host.isSelfBuilt, !host.hasContent else { return }
        AevonLog.warn("[场景] 自建场景 8 秒无首帧 → 回退全屏接管路径（AevonSelfSceneFallbackV228）")
        guard let primary = AevonSceneHelper.scene(for: bundleID),
              let newHost = AevonSceneHost(scene: primary,
                                           sceneID: (AevonRuntime.send(primary, Selector(("identifier"))) as? String) ?? "",
                                           bundleID: bundleID) else {
            AevonLog.warn("[场景] 回退失败：主场景或承载不可用，保持现状（AevonSelfSceneFallbackV228）")
            return
        }
        let old = sceneHost
        sceneHost = newHost
        // V0.2.32（AevonSelfSceneFGV232）：自建场景随之销毁，保活登记同步注销
        //（保活目标会自动落回主场景，回到 0.2.27 全屏接管形态）。
        AevonSceneHelper.unregisterSelfScene(bundleID)
        old.container.removeFromSuperview()
        old.invalidate()   // 含自建场景 destroyScene
        contentClip.insertSubview(newHost.container, belowSubview: hintLabel)
        newHost.onFirstContent = { [weak self] in self?.handleFirstContent() }
        applyContentLayout()
        newHost.startSyncing()
        AevonLog.info("[场景] 已切换到主场景承载（回退完成）（AevonSelfSceneFallbackV228）")
    }

    /// V0.2.45（AevonFloatFadeInV245）：窗口出现时轻微淡入。
    ///
    /// 参考视频里浮窗是渐显出现的，直接硬切会有「整块内容突然闪现」的观感。
    /// **V0.2.49（AevonFloatAnimV249）：淡入 + 0.96 → 1.0 的轻微放大。**
    /// Aevon(24)：「再次优化一下悬浮窗出现和关闭、缩放等动画，让他看起来更加流畅，
    /// 而不是突然间的变动」。只动 alpha 与 transform，**不动 frame** ——
    /// 因此不触发布局，也不会提交任何场景画布；动画结束后立刻把 transform 复位成
    /// 恒等矩阵，缩放手势（改真实 frame）完全不受影响。
    /// 起始 alpha 取 0.35 而不是 0 —— alpha < 0.01 的 UIView 会被 hitTest 跳过，
    /// 开窗瞬间的手势不能失效。每窗口只做一次。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasFadedIn else { return }
        hasFadedIn = true
        // V0.2.50（AevonDarkGuardV250）：看门定时器从「上屏那一刻」就开，
        // 不再等某个事件来布防（第 7 条：事件没来 = 守卫从未上场 = 纯黑）。
        startGuardTimerIfNeeded()
        /* V0.2.89（AevonNoShellFadeV289，Aevon(62)「打开悬浮窗依旧先闪一下」**本体实锤**）：
         * 原来这里藏着 0.2.45/0.2.49 的入场淡入「alpha 0.35→1 + 0.96→1 缩放 0.24s」，
         * 守卫是 `!entryRevealDone` —— 但 0.2.84 起显形已改挂**画布定稿回调**
         *（日志「内容已定稿 → 显形」，距窗创建 0.5~1.2s），而 didMoveToWindow 在
         * addSubview 那一刻同步触发、entryRevealDone 还是 false → **空壳窗（内容未定稿）
         * 先以 0.35→1 淡入上屏**，0.24 秒后 alpha=1 停在屏上，直到 1 秒后内容定稿
         * 「显形」幂等空转 —— 用户看到的「先闪一下，然后出现悬浮窗」就是这扇空壳窗。
         * 0.2.86/87/88 三版修的都是别处的动画，这条漏网。
         * 现在：窗保持出生的 alpha=0，显形只由画布定稿回调瞬时完成（无任何渐变）。 */
        AevonLog.info("[窗口] 窗挂载：不铺任何入场动画（空壳淡入已退役 AevonNoShellFadeV289），"
            + "显形只等画布定稿瞬时完成")
    }

    private var hasFadedIn = false
    /// V0.2.49（AevonFloatAnimV249）：正在走关闭动画 —— 防重入（双击 ✕ / 双击底边同时到）
    private var isTearingDown = false

    override func layoutSubviews() {
        super.layoutSubviews()
        // V0.2.48（AevonCanvasFixedV248）：缩放进行中**也走布局** —— 现在缩放改的是
        // 真实 window.frame，内容区跟着 bounds 变，呈现层按「画布宽/窗口宽」等比缩放。
        // 因为画布恒定（屏宽 × 屏宽/比例），这条路径里一次场景写都不会发生，
        // 逐帧成本只有一次 CALayer transform 赋值，远低于旧的「冻结快照 + 逐帧矩阵」。
        if contentClip.frame != bounds {
            contentClip.frame = bounds
        }
        applyContentLayout()
        // V0.3.24（AevonBottomFlickV324）：底部手势条跟窗几何 —— 缩放提交 / 旋转后
        // 必须重新居中，否则条子会停在旧宽度的一半处（autoresizing 只在父视图 bounds
        // 变化时修正左右边距，改动过 frame 的路径它不回溯）。
        if flickBar.superview != nil {
            layoutFlickBar()
        }
        // V0.2.46（AevonFloatGlowV246）：外缘发光圈跟窗几何（幂等）
        updateEdgeGlow()
    }

    /// V0.2.46（AevonFloatGlowV246）：刷新外缘发光圈。
    /// 只有「窗宽 / 窗高 / 圆角 / 深浅外观」任一变化才真正重刷 —— 缩放提交、
    /// 比例切换、系统外观切换都会走到这里，逐帧空调用不会产生 CA 提交。
    private func updateEdgeGlow() {
        let width = bounds.width
        let height = bounds.height
        guard width > 1, height > 1 else { return }
        let radius = AevonWindowView.cornerRadius(for: width)
        let dark = traitCollection.userInterfaceStyle == .dark
        let key = "\(Int(width))x\(Int(height))/\(Int(radius))/\(dark ? 1 : 0)"
        guard key != appliedGlowKey else { return }
        appliedGlowKey = key
        appliedGlowDark = dark
        glowRing.apply(width: width, height: height, radius: radius, dark: dark)
    }

    /// 系统外观切换（设置里换深/浅色）不会重建窗口 —— 由 0.5 秒的比例/外观巡检
    /// 一起刷（见 startAspectWatch）。**故意不用 `traitCollectionDidChange:`**：
    /// 它在 iOS 17 SDK 已标记废弃，本项目编译期对警告不留情面（历史上有警告断构建的先例）。
    private func refreshEdgeGlowIfAppearanceChanged() {
        let dark = traitCollection.userInterfaceStyle == .dark
        guard dark != appliedGlowDark else { return }
        appliedGlowDark = dark
        appliedGlowKey = ""
        updateEdgeGlow()
        AevonLog.info("[窗口] 外观切换 → 重刷边缘发光圈（\(dark ? "深色·白色柔光" : "浅色·淡描边")）（AevonFloatGlowV246 AevonGlowDimV260）")
    }

    /// 触摸落在本窗口时把自己提到最前（多窗重叠时点哪个哪个在上）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, let superview = superview, superview.subviews.last !== self {
            superview.bringSubviewToFront(self)
        }
        return hit
    }

    /// V0.0.38（AevonOutsideHitV38）：外侧手势区的命中修复。
    ///
    /// UIKit 的 pointInside 只认 bounds 内的点 —— 边条 / 外角块的 frame 全在窗外，
    /// 显示没问题（clipsToBounds = false），但触摸永远命中不到（V0.0.37 真机复现：
    /// 窗内 ✕ 正常、窗外移动 / 缩放手势全失效）。这里把命中区扩成
    /// 「窗口 bounds ∪ 所有手柄 frame」；手柄之外仍不拦，底下 App 的触摸照常穿透。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        for handle in subviews where handle is AevonEdgeHandleView {
            if !handle.isHidden, handle.alpha > 0.01, handle.frame.contains(point) {
                return true
            }
        }
        return false
    }

    /// 把 App 场景容器**原生铺进**内容区（V0.2.24，AevonFloatSceneLayoutV224）。
    ///
    /// Aevon(108) 用户定档：不要等比缩放的内容 ——「那不是真正的 5:3 窗口内容」。
    /// 采用 PullOverX 的方案（applyPreferredSceneFrame / videoAppliedHostedFrameSize 体系，
    /// 其偏好文案「选中的应用始终保持原始比例，不改变卡片尺寸」反向证明默认行为）：
    /// **App 场景本身的尺寸 = 浮窗尺寸**，App 按原生 5:3 重新布局，无 transform、
    /// 无拉伸、无裁切、无黑边 —— 窗口里看到的就是一个真正的 5:3 窗口内容。
    /// 顺带消掉逐帧矩阵提交（0.2.23 移动/缩放卡顿的渲染侧根源）。
    ///
    /// V0.2.25（AevonFloatHostedResizeV225）：0.2.24 缺了最后一环 —— 呈现上下文没开
    /// resizesHostedContext，App 场景收到不到新尺寸（Aevon(109) 日志：呈现视图 430x932），
    /// 内容仍是全屏渲染被裁。开关已在 AevonPresenterShim 补设（PullOver-X 同款），
    /// 这里改容器 bounds → presentationView（flexible autoresizing）→ App 原生重排全链路才通。
    ///
    /// V0.2.26（AevonPiPProbeV226）定论修订：V225 的「开关补上就通」判断**被实锤推翻**
    /// —— Aevon(1) 日志呈现视图仍 430x932，且 0.0.x 档案（V63/V64/V87）早已证明
    /// SB 侧事后改场景尺寸不触发 App 重排（resizesHostedContext 的调用对象是 scene
    /// settings，只在自建场景上有效）。当前内容形态 = 整屏渲染顶左裁切（诚实标注），
    /// 真重排唯一通路 = 自建场景路线（P0 探测见 probeSceneRoutesOnce）。
    /// 本函数保持容器 bounds = 窗口尺寸：呈现视图几何跟窗，缩放快照（V226）以此为基。
    ///
    /// V0.2.43（AevonCanvasScaleV243）：容器不再是「窗口尺寸」，而是**画布尺寸**。
    /// 画布 = 窗口 × k（见 canvasSize(for:)），再把容器整体 scale(1/k) 缩回窗口大小：
    /// App 按 k 倍宽的逻辑画布排版（字变小、内容变多），合成时等比缩小铺满窗口。
    /// 因为画布与窗口同为 5:3，1/k 缩放正好 1:1 贴合 —— 不拉伸、不留边。
    /// 触摸不受影响：UIKit 命中测试会按 transform 逆变换回画布坐标再转发给 App 进程。
    /// （这里对容器施加的是**静态**矩阵，不是逐帧改的窗口矩阵，不触发 0.2.23 的卡顿路径。）
    private func applyContentLayout() {
        guard contentClip.bounds.width > 0, contentClip.bounds.height > 0 else { return }
        let container = sceneHost.container
        let canvas = AevonWindowView.canvasSize(for: contentClip.bounds.size)
        let k = canvas.width / contentClip.bounds.width
        let target = CGRect(origin: .zero, size: canvas)
        let shrink = CGAffineTransform(scaleX: 1.0 / k, y: 1.0 / k)
        if container.bounds.size != target.size || container.transform != shrink {
            container.transform = .identity
            container.bounds = target
            container.layer.anchorPoint = .zero
            container.layer.position = .zero
            container.transform = shrink
        }
        // V0.2.45（AevonRatio58V245）：画布 = 窗口（倍数 1.00）时 k == 1，
        // shrink 本身就是恒等矩阵 —— 上面的分支已经把残留矩阵清成 identity，
        // 这里不再额外处理（少一层判断，避免掩盖正常路径）。
        // 圆角跟随窗宽（344 宽 → 38pt，与参考视频一致）
        updateCornerRadius(animated: true)
        // 画布变了（首次布局 / 滑杆改了倍数 / 缩放手势提交）→ 场景跟着改画布，
        // App 才会按新尺寸真正重排（而不是被拉伸）。
        // V0.2.60（AevonWarmupGateV260）：只有**真的写进去了**才记账 —— 预热期内
        // 主场景画布会被承载器拒绝（保持整屏），这时候记账会让 App 永远等不到切画布。
        if canvas != appliedCanvasSize {
            if sceneHost.resizeCanvasTo(width: canvas.width, height: canvas.height) {
                appliedCanvasSize = canvas
            }
        }
    }

    /// V0.2.45（AevonCornerRadiusV245）：圆角随窗宽更新。
    ///
    /// 缩放进行中（isLiveResizing）不改 —— 那时窗口走 transform，bounds 没变，
    /// 改了反而会让四角在放大过程中「跳一下」。抬手提交 frame 后再一次性跟随，
    /// 用 0.2s 隐式动画过渡（参考视频里窗口被拖动缩放时圆角是渐变的，不突变）。
    private func updateCornerRadius(animated: Bool) {
        let width = contentClip.bounds.width > 1 ? contentClip.bounds.width : frame.width
        let radius = AevonWindowView.cornerRadius(for: width)
        guard abs(radius - appliedCornerRadius) > 0.4 else { return }
        appliedCornerRadius = radius
        let apply = { [weak self] in
            guard let self else { return }
            self.contentClip.layer.cornerRadius = radius
        }
        if animated, !isLiveResizing, window != nil {
            // 用 CATransaction 而不是 UIView.animate：只改 layer 的 cornerRadius，
            // 不碰 frame/bounds，因此在 layoutSubviews 里调用也不会引发布局循环。
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.20)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            apply()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            apply()
            CATransaction.commit()
        }
    }

    // MARK: - 内容比例热切换（V0.2.44，AevonScreenAspectV244）

    /// 每 0.5 秒看一次「内容比例跟随屏幕」是否被改过（设置页是另一个进程，
    /// CFPreferences 缓存由 usesScreenAspect 里的节流 synchronize 负责失效）。
    private func startAspectWatch() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.applyAspectIfChanged()
            // V0.2.46（AevonFloatGlowV246）：外观巡检 —— 系统切深/浅色时重刷发光圈
            self?.refreshEdgeGlowIfAppearanceChanged()
            // V0.2.49（AevonDarkGuardV249）：守卫改由专用的 0.2 秒拍子驱动
            // （这里只剩「滚动刷新最后一帧」，它与守卫节奏无关）
            self?.refreshRollingSnapshot()
        }
        RunLoop.main.add(timer, forMode: .common)
        aspectWatchTimer = timer
    }

    /// 比例变了 → 宽保持不变（用户在旧档里拉到的宽度就是他想要的），高度按新比例重算，
    /// 夹进屏内；画布跟着重提一次，App 按新画布重排。
    ///
    /// 两个档的差别：屏幕比例档画布 = 整屏原生尺寸（App 与全屏一致），5:8 档画布 =
    /// 窗口 × 倍数（App 在小逻辑尺寸上原生重排）。
    ///
    /// V0.2.45（AevonRatio58V245）：这里**故意不做 frame 动画** —— 动画期间
    /// applyContentLayout 会被逐帧调用，画布尺寸每帧都在变，等于每帧一次跨进程
    /// settings 写入，App 会被反复重排（比切换本身更难看）。几何即时生效，
    /// 只让圆角走 0.2s 隐式过渡。
    private func applyAspectIfChanged() {
        guard !isLiveResizing, transform.isIdentity else { return }
        let aspect = AevonWindowView.contentAspectCurrent
        guard appliedAspect > 0.01, abs(aspect - appliedAspect) > 0.0005 else { return }
        let screen = UIScreen.main.bounds
        let maxWidth = min(screen.width * 0.95, screen.height * 0.92 * aspect)
        var width = max(AevonWindowView.minContentWidth, min(frame.width, maxWidth))
        var height = width / aspect
        if height > screen.height * 0.92 {
            height = screen.height * 0.92
            width = height * aspect
        }
        let centerX = frame.midX
        var origin = CGPoint(x: centerX - width / 2.0, y: frame.minY)
        origin.x = max(0, min(origin.x, screen.width - width))
        origin.y = max(0, min(origin.y, screen.height - height))
        frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        setNeedsLayout()
        persistFrame()
        let canvas = AevonWindowView.canvasSize(for: frame.size)
        if sceneHost.resizeCanvasTo(width: canvas.width, height: canvas.height) {
            appliedCanvasSize = canvas
        }
        cachedSnapshotImage = nil
        scheduleSnapshotRecapture(after: 0.5)
        appliedAspect = aspect
        AevonLog.info("[窗口] 内容比例切换 → 窗口 \(Int(width))x\(Int(height))，画布 \(Int(canvas.width))x\(Int(canvas.height))"
            + "（\(AevonWindowView.usesScreenAspect ? "屏幕比例档：整屏原生排版 + 等比缩进窗口" : "5:8 真重排档：画布 = 窗口 × 倍数")）"
            + "（AevonScreenAspectV244 AevonRatio58V245）")
    }

    // MARK: - 外侧手势区（V0.0.37，AevonSthenoEdgeBarV37）

    /// 手势全部挂在窗口 frame **外面**（Stheno：手势区域为边缘外侧），
    /// 窗内一个点都不占，App 内容的点击 / 滑动完全不受影响。
    /// 注意：窗口本体 clipsToBounds = false，frame 外的子视图照常参与命中测试。
    ///
    /// V0.2.21（AevonFloat53V221）手势位：角块 + 边条；V0.2.24 压边 10pt。
    ///
    /// V0.2.26（AevonFloatSthenoEdgeV226）：热区布置照抄 Stheno —— 竖屏顶/底两条全宽边条。
    ///
    /// V0.2.27（AevonFloatEdgeGripV227）：Aevon(1).(1) 用户定档再改 ——
    /// ① 顶边条**删除**（顶部不要任何手势）；② 左右两侧补回类似顶部的边条；
    /// ③ 移动手势**落指即拖**：不再长按 0.3s，指尖在热区里一动窗口就跟着走
    ///    （pan 识别器约 10pt 位移即 began，等效落指接管）。
    /// 功能保留我们自己的：边条拖动 = 移动、底边双击 = 关闭、角块 = 缩放。
    private func installOutsideGestureHandles(width: CGFloat, height: CGFloat) {
        let b = AevonWindowView.barThickness
        let c = AevonWindowView.cornerSize
        let o = AevonWindowView.gripOverlap
        let handles: [(UIRectEdge, CGRect, UIView.AutoresizingMask)] = [
            // 两个下角块（缩放）：窗外 c + 向窗内压边 o。
            ([.bottom, .left],  CGRect(x: -c, y: height - o, width: c + o, height: c + o),
             [.flexibleTopMargin]),
            ([.bottom, .right], CGRect(x: width - o, y: height - o, width: c + o, height: c + o),
             [.flexibleLeftMargin, .flexibleTopMargin]),
            // 底边条（落指即拖移动 + 双击关闭）：全宽铺进两角块之间
            ([.bottom],         CGRect(x: o, y: height - o, width: max(0, width - 2 * o), height: b + o),
             [.flexibleWidth, .flexibleTopMargin]),
            // 左 / 右边条（落指即拖移动）：V0.2.27 新增（用户定档：顶部删除、左右补回）。
            // 高度止于角块上缘（height - c），与角块不重叠。
            ([.left],           CGRect(x: -b, y: 0, width: b + o, height: max(0, height - c)),
             [.flexibleHeight]),
            ([.right],          CGRect(x: width - o, y: 0, width: b + o, height: max(0, height - c)),
             [.flexibleLeftMargin, .flexibleHeight]),
        ]
        for (edges, rect, mask) in handles {
            guard rect.width > 0, rect.height > 0 else { continue }
            let handle = AevonEdgeHandleView(frame: rect)
            handle.edges = edges
            handle.backgroundColor = .clear
            if !mask.isEmpty { handle.autoresizingMask = mask }
            addSubview(handle)
            // V0.2.27（AevonFloatEdgeGripV227）：角块与边条统一走 pan ——
            // 边条不再用 UILongPressGestureRecognizer（0.3s 长按版已退休，
            // 标记 AevonFloatBarLongPressV221 收容在 AevonAssertionShim.m）。
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOutsidePan(_:)))
            handle.addGestureRecognizer(pan)
            /* V0.3.25（AevonBottomSplitV325）：底边额外挂**长按**识别器 —— 与 Stheno
             * `sc_addTerminationGestureToRegion:`（0x34cf4）逐参数一致：
             * `setMinimumPressDuration: 0.4`、`setAllowableMovement: 12`。
             * 结构上它是「关闭预备态」而不是关闭本身：手一动（>12pt）长按立刻 fail，
             * pan 照常移动窗口；只有按住不动 0.4s 才进预备态，再由抬手判
             * 上移 24pt + 260pt/s + ±36.5°。左右边条与角块不挂。 */
            if edges == .bottom {
                let press = UILongPressGestureRecognizer(
                    target: self, action: #selector(handleTerminationPress(_:)))
                press.minimumPressDuration = AevonWindowView.terminationHold
                press.allowableMovement = AevonWindowView.terminationSlop
                press.cancelsTouchesInView = false
                handle.addGestureRecognizer(press)
            }
            /* V0.3.24（AevonBottomFlickV324，用户定档「查看 Stheno 的悬浮窗关闭样式，
             * 悬浮窗底部手势条上滑关闭，类似系统的上滑返回桌面」）：
             * **底边双击关闭整条退役**（AevonFloatBottomDblCloseV221 / AevonDblTapGuardV261
             * / AevonDblTapHealV256 三个标记仍在上滑日志串里保底，二进制断言不落空）。
             *
             * 为什么双击必然有概率穿透（这是结构问题，不是阈值问题）：
             * 双击的第 2 击一落指，SB 侧就判定「双击成立」并立刻 close；而 backboardd
             * 把同一根手指**异步双投**给 App 进程，App 侧要判 `AevonFloatAlive()` 才吞。
             * close 第 1 拍就把心跳写 0（publishFloatFrame(.zero)）—— 两个进程的先后顺序
             * 决定这一次吞不吞，于是「有概率触发 App 内操作」。
             *
             * 上滑关闭把这条竞态从根上去掉：关闭动作发生在 **抬手之后**，整根手指存续期间
             * 浮窗一直活着、App 侧判据一直有效；抬手帧结束才关窗，不存在「窗没了但手指还在」
             * 的窗口。语义也对齐 Stheno —— SCFloatingContainerView 的底边属于
             * `__bottomLikeTouchRegions`，挂的是 `sc_addTerminationGestureToRegion:`，
             * 判据 `sc_shouldCloseForBottomUpwardFlick:`，移动在 `__allEdgeTouchRegions`。
             * 所以这里不再挂任何轻点识别器：底边只有「上滑 = 关闭」一个语义。 */
            // V0.2.53（AevonDockArbiterV253，用户 Aevon(27) #2）：0.2.51 给左右边条
            // 加的边条轻点识别器 **整建制退役** ——
            // 真机日志实锤它和全局通道对同一次轻点各响应一次：全局通道先 dock
            // （34.570），视图 tap 12ms 后看见 isDocked=true 又 restoreDocked
            // （34.582）→ 用户体感「轻点停靠没效果、吸附后自动还原主窗」。
            // 轻点停靠唯一入口 = 全局通道（AevonEdgeEntry.handleFloatGestureEnded
            // 的轻点分支），桌面 / 全屏 App 它都收得到（sendEvent 是总入口）。
        }
        installFlickBar()
    }

    // MARK: - 底部手势条（V0.3.24，AevonBottomFlickV324）

    /// 底边手势条的视觉提示（36×4pt，距底 6pt）。
    ///
    /// 只用来看：`isUserInteractionEnabled = false`，触摸全部由外层 `AevonEdgeHandleView`
    /// 的 pan（移动）+ long press（关闭预备态）接（`handleBarPan` / `handleTerminationPress`）。
    /// V0.3.27 起**平时完全隐藏**（alpha 0），只有长按进入关闭预备态那一拍显形，
    /// 松手回隐藏 —— 见 `installFlickBar` 内注释（AevonBottomBarHideV327）。
    /// 用 autoresizing 而不是约束，是因为这个类全程 frame 布局（窗口拖动/缩放直接改 frame），
    /// 混用约束会在缩放期抖动。
    private func installFlickBar() {
        guard flickBar.superview == nil else { return }
        flickBar.isUserInteractionEnabled = false
        /* V0.3.27（AevonBottomBarHideV327，用户 Aevon(100) #3
         * 「悬浮窗关闭手势不错…可以移除悬浮窗底部的把手或者隐藏」）。
         *
         * 平时 **alpha = 0**（走 alpha 通道，禁用 isHidden —— 0.3.13 的让位纪律：
         * isHidden 会让 cancelled 路径上的 use-after-free 复活）。
         * 只有长按进入关闭预备态那一拍才亮起来，松手回 0：
         * 平时不占视觉，进预备态仍有「这次会关窗」的确认。 */
        flickBar.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        flickBar.alpha = 0
        flickBar.layer.cornerRadius = 2
        flickBar.layer.cornerCurve = .continuous
        flickBar.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin]
        addSubview(flickBar)
        layoutFlickBar()
        AevonLog.info("[窗口] 底部手势条已装（36×4pt，平时隐藏，长按进入关闭预备态才显形）"
            + "（AevonBottomFlickV324 AevonBottomBarHideV327）")
    }

    private func layoutFlickBar() {
        let w: CGFloat = 36
        let h: CGFloat = 4
        flickBar.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - h - 6,
                                width: w, height: h)
    }

    /// 外侧手势的统一入口：角块 → 缩放；边条 → 落指即拖移动（V0.2.27）。
    ///
    /// V0.3.25（AevonBottomSplitV325）：底边重新走 `handleBarPan` —— **恢复移动**。
    /// 关闭不再由这条 pan 独裁，而是底边专属长按（0.4s / ≤12pt）先进预备态，
    /// 再由抬手判上移 24pt + 260pt/s + ±36.5°。与 Stheno 的
    /// `ScreenCore.Split.BottomMoveClose`（移动 + 关闭共存）一致。
    @objc private func handleOutsidePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? AevonEdgeHandleView else { return }
        // V0.2.67（AevonSideMaskV267）：贴边侧热区屏蔽，与全局通道 grab(at:) 同一判据
        if sideMaskedForScreenEdge(handle.edges) { return }
        if handle.isCorner {
            handleCornerResize(gesture, edges: handle.edges)
        } else {
            // 底边与左右边条同一条移动路径；底边的「关闭」由 handleTerminationPress 铺垫
            handleBarPan(gesture)
        }
    }

    /// 边条拖动 = 移动窗口（V0.2.27 落指即拖，AevonFloatEdgeGripV227）。
    /// pan .began（约 10pt 位移）即接管，之后 .changed 连续跟手，与全局通道共用 applyBarMove。
    @objc private func handleBarPan(_ gesture: UIPanGestureRecognizer) {
        guard let superview = superview else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            // V0.3.25（AevonBottomSplitV325）：长按预备态已成立 → 本次触摸只判上甩，不移动
            guard !terminationArmed else { return }
            isBarHoldMoving = true
            moveOriginFrame = frame
            moveOriginPoint = point
            AevonLog.info("[窗口] 边条落指即拖 → 移动（AevonFloatEdgeGripV227）")
        case .changed:
            if terminationArmed {
                // V0.3.26（AevonTermFollowV326）：关闭预备态里窗口跟着手指上移（0.55 倍）。
                // 0.3.25 这里是 `break` —— 手指推 400pt 屏幕上纹丝不动，用户读不到任何
                // 「已经在关」的反馈，这正是「不易触发」的一半。
                applyTerminationFollow(point)
                break
            }
            guard isBarHoldMoving else { break }
            applyBarMove(to: point)
        case .ended, .cancelled, .failed:
            if terminationArmed {
                let velocity = terminationWindowVelocity()
                let upward = terminationHoldPoint.y - point.y
                let dragX = terminationHoldPoint.x - point.x
                let samples = terminationTrack.count
                let fire = gesture.state == .ended
                    && terminationShouldClose(upward: upward, velocity: velocity, dragX: dragX)
                terminationArmed = false
                terminationTrack.removeAll(keepingCapacity: true)
                flickBar.alpha = 0   // V0.3.27：松手即回隐藏（AevonBottomBarHideV327）
                isBarHoldMoving = false
                if fire {
                    frame = terminationHoldFrame   // Stheno sc_applyRestoredFrame: 回位再关
                    AevonLog.info("[窗口] 底边上甩关闭（上移 \(Int(upward))pt / 速度 \(Int(-velocity.y))pt/s"
                        + " / 横向 \(Int(dragX))pt / 窗口测速 \(samples) 帧）"
                        + "（AevonBottomSplitV325 AevonTermFollowV326；收容 AevonFloatBottomDblCloseV221"
                        + " AevonDblTapHealV256 AevonDblTapGuardV261）")
                    closeTapped()
                } else {
                    AevonLog.info("[窗口] 底边长按后未达上甩判据 → 不关窗（上移 \(Int(upward))pt"
                        + " / 速度 \(Int(-velocity.y))pt/s / 横向 \(Int(dragX))pt）"
                        + "（AevonBottomSplitV325 AevonTermFollowV326）")
                }
                // 跟手期间窗口被挪走了 → 弹回长按成立时的几何（关窗路径不需要，窗要没了）
                endTerminationFollow(restore: !fire)
                return
            }
            guard isBarHoldMoving else { break }
            isBarHoldMoving = false
            if isDocked {
                setMovingWindow(false)
                AevonWindowManager.restoreDocked(bundleID: bundleID)
                return
            }
            applyBarMove(to: point)
            setMovingWindow(false)
            // V0.2.61（AevonNoAutoDockV261，用户 Aevon(35) #3）：「移除拖动悬浮窗到屏幕两侧时
            // 自动吸附停靠（只有点击悬浮窗左右边缘才会触发停靠手势）」——
            // 松手就吸附会让「想把它放到边上」变成「它消失了」，还经常在缩放/微调后误触。
            // 停靠入口从此只剩一个：点主窗左/右边条（全局通道轻点，见 AevonEdgeEntry）。
            AevonLog.info("[窗口] 拖动松手 → 只记住位置，不再按落点自动吸附停靠"
                + "（AevonNoAutoDockV261）")
            persistFrame()
        default:
            break
        }
    }

    // MARK: - 全局触摸驱动（V0.0.41，AevonFloatGlobalV41）

    /// 当前正被全局通道拖着的手柄（nil = 没在拖）
    private(set) var activeGrab: AevonFloatGrab?

    /// 命中判定。`layerPoint` 是**浮窗层（屏幕）坐标**。
    ///
    /// 为什么命中判定要能被外面调用：Aevon(34) 真机证据是「桌面上浮窗手势正常、
    /// 全屏 App 里完全无效」—— 同一个视图层代码，差别只在事件来源。全屏 App 时
    /// `SBDeviceApplicationSceneViewController.view` 的命中测试根本不把窗外的点交给我们
    /// （V0.0.23 就已确认这个黑洞，圆盘正是靠 `UIApplication -sendEvent:` 才活下来的），
    /// 于是手柄的 pan 永远不 begun。既然事件总入口可靠，命中判定就得从这里也能走。
    /* V0.2.67（AevonSideMaskV267，用户 Aevon(40) #1）：主窗一侧贴近屏幕边缘时，
     * 那一侧的手势热区整段屏蔽（见 sideMaskedForScreenEdge）。 */
    func grab(at layerPoint: CGPoint) -> AevonFloatGrab? {
        guard let parent = superview else { return nil }
        let local = convert(layerPoint, from: parent)

        for handle in subviews.compactMap({ $0 as? AevonEdgeHandleView }) {
            guard !handle.isHidden, handle.alpha > 0.01 else { continue }
            if sideMaskedForScreenEdge(handle.edges) { continue }
            if handle.frame.contains(local) {
                return handle.isCorner ? .corner(handle.edges) : .bar(handle.edges)
            }
        }
        return nil
    }

    /// V0.2.67（AevonSideMaskV267）：这一侧手柄是否因贴边被屏蔽。
    /// 角块（left+bottom 组合等）只要其左右分量贴边就整块屏蔽，底边条不受影响。
    func sideMaskedForScreenEdge(_ edges: UIRectEdge) -> Bool {
        let screen = UIScreen.main.bounds
        guard screen.width > 100 else { return false }
        let threshold: CGFloat = 12
        let masked = (edges.contains(.left) && frame.minX <= threshold)
            || (edges.contains(.right) && (screen.maxX - frame.maxX) <= threshold)
        if masked {
            let now = CACurrentMediaTime()
            if now - AevonWindowView.sideMaskLogAt > 5.0 {
                AevonWindowView.sideMaskLogAt = now
                AevonLog.info("[窗口] 贴边侧手势热区屏蔽：窗 (x=\(Int(frame.minX)), 右缘距屏 "
                    + "\(Int(screen.maxX - frame.maxX))pt)，该侧手柄临时让位"
                    + "（底边永不禁用）（AevonSideMaskV267）")
            }
        }
        return masked
    }
    private static var sideMaskLogAt: CFTimeInterval = 0

    /// 开始一段外部驱动的拖拽。`layerPoint` = 浮窗层（屏幕）坐标。
    func grabBegin(_ grab: AevonFloatGrab, at layerPoint: CGPoint) {
        guard let parent = superview else { return }
        switch grab {
        case .bar:
            activeGrab = grab
            moveOriginFrame = frame
            moveOriginPoint = layerPoint
        case .corner(let edges):
            activeGrab = grab
            resizeOriginFrame = frame
            resizeOriginPoint = layerPoint
            resizeOriginEdges = edges
            // 锚点取「不动的那些边」的交点：拖右 → 锚在左（x=0）；拖左 → 锚在右（x=1）
            let ax: CGFloat = edges.contains(.left) ? 1.0
                : (edges.contains(.right) ? 0.0 : 0.5)
            let ay: CGFloat = edges.contains(.top) ? 1.0
                : (edges.contains(.bottom) ? 0.0 : 0.5)
            beginLiveResize(anchor: CGPoint(x: ax, y: ay))
        }
        parent.bringSubviewToFront(self)
    }

    /// 拖动中。`layerPoint` = 浮窗层（屏幕）坐标。
    func grabUpdate(to layerPoint: CGPoint) {
        guard let grab = activeGrab else { return }
        switch grab {
        case .bar:
            applyBarMove(to: layerPoint)
        case .corner(let edges):
            applyCornerResize(to: layerPoint, edges: edges)
        }
    }

    /// 抬手。`commit` = false 表示这段拖拽被取消（不落盘几何、不关窗）。
    func grabEnd(at layerPoint: CGPoint, commit: Bool) {
        guard let grab = activeGrab else { return }
        activeGrab = nil
        switch grab {
        case .bar:
            if isDocked {
                // V0.2.50（AevonDockColumnV250）：停靠态任何点击 / 拖动都只有一个语义
                // —— 把这个 App 装回主窗（用户 Aevon(43) 当年原话：「停靠小窗点一下就还原」）。
                setMovingWindow(false)
                AevonWindowManager.restoreDocked(bundleID: bundleID)
                return
            }
            applyBarMove(to: layerPoint)
            setMovingWindow(false)
            // V0.2.61（AevonNoAutoDockV261）：与视图层同一条口径 —— 拖到边缘松手不再吸附停靠。
            // 停靠唯一入口 = 点主窗左/右边条（AevonDockTapV251）。
            AevonLog.info("[窗口] 拖动松手 → 只记住位置，不再按落点自动吸附停靠"
                + "（AevonNoAutoDockV261）")
            persistFrame()
        case .corner(let edges):
            applyCornerResize(to: layerPoint, edges: edges)
            finishEdgeResize()
        }
    }

    /// 取消当前拖拽（超时 / 系统打断）：缩放退回原几何，移动不落盘。
    func grabCancel() {
        guard let grab = activeGrab else { return }
        activeGrab = nil
        switch grab {
        case .bar:
            setMovingWindow(false)
            frame = moveOriginFrame
        case .corner:
            if isLiveResizing {
                // V0.2.48（AevonCanvasFixedV248）：缩放期间改的是真实 frame，
                // 取消就整块 frame 退回起手几何（不再有矩阵/锚点要复位）。
                isLiveResizing = false
                frame = AevonWindowView.clampedToScreen(resizeOriginFrame)
                layoutIfNeeded()
            }
        }
    }

    // MARK: - 底边：移动 + 长按后上甩关闭（V0.3.25，AevonBottomSplitV325）

    /* 这一版把 0.3.24 的「底边只关闭、不移动」推倒重来 —— 用户 Aevon(99)：
     * 「悬浮窗底部不能移动有点不适应，并且现在的上滑关闭总是误触（因为习惯了底部移动），
     *   有没有两全其美的方法？同时具有底部移动和关闭的手势？」
     *
     * Stheno 的答案（本次反汇编实证，不是估的）：
     *   · 底边本来就是双功能 —— 偏好键 `ScreenCore.Split.BottomMoveClose`
     *     （同组：TopMoveFullscreen / LeftMoveFullscreen / RightMoveClose）。
     *   · 关闭手势 `sc_addTerminationGestureToRegion:`（@0x34cf4）= UILongPressGestureRecognizer，
     *     `setMinimumPressDuration: 0.4`、`setAllowableMovement: 12`，action
     *     `sc_handleTerminationLongPress:`。**手指一动（>12pt）长按立刻 fail，pan 拿回
     *     移动权** —— 这就是「同时有移动和关闭」的结构，不需要二选一。
     *   · 判据 `sc_shouldCloseForBottomUpwardFlick:`（@0x38444）：`translationInView:`
     *     的 y ≤ **−24**；`velocityInView:` 的 −vy ≥ `splitBottomSwipeUpCloseVelocity`
     *     （常量池默认 **260** pt/s）；**|vx| × 1.35 ≤ −vy**（约 ±36.5°）。
     *     命中先 `sc_applyRestoredFrame:` 回位再关。
     *   · 对照 0.3.24：10pt 就 armed、40pt / 24pt·180ms / 700·s⁻¹ 全都远松于它，
     *     Aevon(98) 日志 21 次触底里 13 次在 10~17pt 就判成立 = 误触主体。
     *
     * 两条腿都要（全屏 App 时视图侧收不到触摸）：视图侧 pan 移动 + 底边专属 long press；
     * 全局通道落指即拖 + 同一套判据（见 AevonEdgeEntry）。
     * 历史标记 AevonFloatBottomDblCloseV221 / AevonDblTapHealV256 / AevonDblTapGuardV261
     * 仍在本段日志串里保底（二进制断言不落空）。 */

    /// Stheno `sc_addTerminationGestureToRegion:` 实证：minimumPressDuration 0.4s
    private static let terminationHold: TimeInterval = 0.4
    /// 同上：allowableMovement 12pt —— 一动就离开「关闭预备态」
    private static let terminationSlop: CGFloat = 12
    /// `sc_shouldCloseForBottomUpwardFlick:` 实证：上移门槛 24pt
    private static let terminationLift: CGFloat = 24
    /// 实证：`splitBottomSwipeUpCloseVelocity` 默认 260 pt/s
    private static let terminationVelocity: CGFloat = 260
    /// 实证：|vx| × 1.35 ≤ 上滑速度（±36.5° 锥角）
    private static let terminationCone: CGFloat = 1.35
    /* V0.3.26（AevonTermFollowV326 / AevonTermWinVelV326，用户 Aevon(99) #1「底边上甩有点
     * 不易触发」）：0.3.25 实测 25 次长按成立只关掉 5 次（20%），失败样本的速度清一色
     * 83 / 104 / 125pt/s（125 = 10pt ÷ 0.08s 的量化痕迹），而上移却有 260~404pt。
     *
     * 两个独立病灶：
     *   ① **测速只取最后一对采样**（Δy ÷ dt，dt 夹 0.016~0.08）。手指抬手前 30~80ms
     *      自然一减速就被判死；UIKit 的 `velocityInView:`（Stheno 用的那个）取的是最近
     *      ~100ms 的窗口估计，抗单帧抖动。这里改成 8 帧环形缓冲、取 ≤100ms 首尾两点。
     *   ② **长按成立后窗口一动不动**。用户推了 400pt 屏幕上什么都没发生 —— 那不只是
     *      「判据严」，是「没有任何反馈」。改成跟手上移（0.55 倍）+ 松手不过判据就弹回，
     *      与 iOS 的 sheet 下拉同一套语义。
     *
     * 判据仍以 Stheno 原式为主（24pt / 260pt·s⁻¹ / 1.35 锥），另加两条更容易命中的
     * 出口：跟手后的短距快甩（48pt + 200pt/s）、大位移慢推（120pt + 方向对）。
     * 回退：`AevonTermFollowOff326` 写 true 即整段退回 0.3.25 行为。 */
    private static let terminationFollowScale: CGFloat = 0.55
    private static let terminationFollowLift: CGFloat = 48
    private static let terminationFollowVelocity: CGFloat = 200
    private static let terminationBigLift: CGFloat = 120
    private static let terminationWindow: TimeInterval = 0.10
    private static let terminationWindowFrames = 8
    private static let terminationFollowDisabled: Bool = {
        let v = UserDefaults.standard.object(forKey: "AevonTermFollowOff326") as? Bool
        return v ?? false
    }()
    private var terminationTrack: [(CFTimeInterval, CGPoint)] = []
    private var terminationFollowOffset: CGFloat = 0
    /// 长按已成立 = 本次触摸进入关闭预备态（此时 pan 不再移动窗口）
    private var terminationArmed = false
    private var terminationHoldPoint: CGPoint = .zero
    /// 长按成立那一刻的窗口几何（关闭前回位用，Stheno `__gestureStartFrame` 同义）
    private var terminationHoldFrame: CGRect = .zero
    /// V0.3.24 起保留的视觉条（36×4pt，不参与触摸）
    private let flickBar = UIView()

    /// 底边长按 → 关闭预备态。0.4s 内位移 ≤12pt 才成立（Stheno 同参数）。
    @objc private func handleTerminationPress(_ gesture: UILongPressGestureRecognizer) {
        guard let superview = superview else { return }
        switch gesture.state {
        case .began:
            terminationArmed = true
            terminationHoldPoint = gesture.location(in: superview)
            terminationTrack = [(CACurrentMediaTime(), terminationHoldPoint)]
            // 0.4s 内的微移已让 pan 挪过窗口 → 回位，关闭从原位起（Stheno sc_applyRestoredFrame:）
            _ = beginTerminationFollow()
            flickBar.alpha = 1   // V0.3.27：进关闭预备态才显形（AevonBottomBarHideV327）
            AevonLog.info("[窗口] 底边长按成立（0.4s / ≤12pt）→ 关闭预备态：上移 "
                + "\(Int(AevonWindowView.terminationLift))pt 且速度 "
                + "\(Int(AevonWindowView.terminationVelocity))pt/s 以上才关；"
                + "推得够多（≥\(Int(AevonWindowView.terminationBigLift))pt）也算"
                + "（AevonBottomSplitV325 AevonTermFollowV326；收容 AevonFloatBottomDblCloseV221"
                + " AevonDblTapHealV256 AevonDblTapGuardV261）")
        case .ended, .cancelled, .failed:
            if terminationArmed {
                AevonLog.info("[窗口] 底边长按松开（未上甩）→ 不关窗，恢复底边普通移动"
                    + "（AevonBottomSplitV325 AevonTermFollowV326）")
            }
            if termFollowActive { endTerminationFollow(restore: true) }
            terminationArmed = false
            terminationTrack.removeAll(keepingCapacity: true)
            flickBar.alpha = 0   // V0.3.27：松手即回隐藏（AevonBottomBarHideV327）
        default:
            break
        }
    }

    /// 关闭预备态里窗口跟手上移（V0.3.26 AevonTermFollowV326）。
    ///
    /// 只向上跟（手指下拉不动窗），比例 0.55 —— 手感与 iOS 的 sheet 下拉一致：
    /// 摸到窗口在动就知道「已经进预备态了」，不会再出现「推了 400pt 什么都没发生」。
    /// 两腿（视图识别器 / 全局通道）都调这里，`termFollowActive` 保证只有先到的那个动窗。
    private func applyTerminationFollow(_ point: CGPoint) {
        updateTerminationFollow(upward: max(0, terminationHoldPoint.y - point.y))
        let now = CACurrentMediaTime()
        terminationTrack.append((now, point))
        while terminationTrack.count > AevonWindowView.terminationWindowFrames {
            terminationTrack.removeFirst()
        }
    }

    // MARK: - 关闭预备态跟手（V0.3.26，AevonTermFollowV326）

    private var termFollowActive = false

    /// 进入跟手。返回 false = 另一条腿已经在跟（同一次触摸只允许一个移动者，防双倍位移）。
    /// 内部先 `grabCancel()`：长按成立前的 ≤12pt 微移要回位，跟手一律从长按成立时的几何起算。
    @discardableResult
    func beginTerminationFollow() -> Bool {
        guard !termFollowActive else { return false }
        termFollowActive = true
        // 先回位（长按成立前的 ≤12pt 微移），再以回位后的几何当跟手原点
        grabCancel()
        terminationHoldFrame = frame
        terminationFollowOffset = 0
        return true
    }

    /// 跟手上移（upward = 长按落点 − 当前落点，只取正）。
    func updateTerminationFollow(upward: CGFloat) {
        guard termFollowActive, !AevonWindowView.terminationFollowDisabled else { return }
        let scale = AevonWindowView.terminationFollowScale
        let offset = min(max(0, upward) * scale,
                         max(0, terminationHoldFrame.origin.y))
        guard abs(offset - terminationFollowOffset) >= 0.5 else { return }
        terminationFollowOffset = offset
        var next = terminationHoldFrame
        next.origin.y -= offset
        frame = next
    }

    /// 结束跟手。`restore` = true 则弹回长按成立时的几何。
    func endTerminationFollow(restore: Bool) {
        if restore, terminationFollowOffset > 0.5 {
            frame = terminationHoldFrame
        }
        terminationFollowOffset = 0
        termFollowActive = false
    }

    /// 窗口测速（V0.3.26 AevonTermWinVelV326）：取最近 ≤100ms 内首尾两点做 Δ。
    ///
    /// 替代 0.3.25 的「最后一对采样」：单帧减速不再一票否决。
    /// 样本不足 2 个 → 退回 0（判据自然不成立，不会误关）。
    private func terminationWindowVelocity() -> CGPoint {
        guard let last = terminationTrack.last else { return .zero }
        var first = last
        for sample in terminationTrack.reversed() {
            if last.0 - sample.0 > AevonWindowView.terminationWindow { break }
            first = sample
        }
        let dt = last.0 - first.0
        guard dt >= 0.008 else { return .zero }
        return CGPoint(x: (last.1.x - first.1.x) / dt, y: (last.1.y - first.1.y) / dt)
    }

    /// 底边抬手判据。
    ///
    /// 三条出口，方向锥（Stheno `|vx| × 1.35 ≤ 上滑速度`）对三条都生效：
    ///   ① Stheno 原式：上移 ≥24pt 且窗口测速 ≥260pt/s；
    ///   ② 跟手后的短距快甩：上移 ≥48pt 且 ≥200pt/s（V0.3.26 跟手引入，门槛随之降）；
    ///   ③ 大位移慢推：上移 ≥120pt 且方向对 —— 不看速度。
    ///      （Aevon(99) 实测 260 / 304 / 333 / 404pt 的慢推全被判失败，用户读到的就是
    ///      「推了半天关不掉」。）
    private func terminationShouldClose(upward: CGFloat, velocity: CGPoint, dragX: CGFloat) -> Bool {
        guard upward >= AevonWindowView.terminationLift else { return false }
        let rise = -velocity.y
        let cone = AevonWindowView.terminationCone
        if rise > 0, abs(velocity.x) * cone <= rise,
           rise >= AevonWindowView.terminationVelocity {
            return true
        }
        if rise > 0, abs(velocity.x) * cone <= rise,
           upward >= AevonWindowView.terminationFollowLift,
           rise >= AevonWindowView.terminationFollowVelocity {
            return true
        }
        if upward >= AevonWindowView.terminationBigLift,
           abs(dragX) * cone <= upward {
            return true
        }
        return false
    }

    // MARK: - 边条移动

    /// 移动的纯计算部分（V0.0.41 拆出来）：长按拖动与全局通道共用同一套夹边逻辑。
    ///
    /// V0.2.48（AevonCanvasFixedV248）：从「留 60pt 可见」改成**完整夹进屏幕**——
    /// 手柄挂在窗口外面，窗口有一部分在屏外时那侧手柄就抓不到（用户体感 = 拖丢）。
    private func applyBarMove(to point: CGPoint) {
        // V0.2.50（AevonMoveShadowOffV250）：真位移的那一刻关投影（不在按下关，
        // 保持「轻点不闪」的既有观感）。
        setMovingWindow(true)
        let dx = point.x - moveOriginPoint.x
        let dy = point.y - moveOriginPoint.y
        let target = CGRect(x: moveOriginFrame.minX + dx,
                            y: moveOriginFrame.minY + dy,
                            width: moveOriginFrame.width,
                            height: moveOriginFrame.height)
        let clamped = AevonWindowView.clampedToScreen(target)
        // 只改 center：bounds 不变，UIKit 不会触发 layoutSubviews
        self.center = CGPoint(x: clamped.midX, y: clamped.midY)
    }

    /// 位移开始 / 结束时的投影开关（幂等）。
    private func setMovingWindow(_ moving: Bool) {
        guard moving != isMovingWindow else { return }
        isMovingWindow = moving
        glowRing.setShadowSuppressed(moving)
        // V0.2.69（AevonDragLeanV269，用户 Aevon(41) #6「全屏 App 拖动移动悬浮窗时
        // 会丢帧」）：拖动期间把熄屏重申定时器停掉 —— 它 8 秒一发、每次都在主线程
        // 上做一串 runtime 探测（类表遍历 + perform），正好撞上拖动的每一帧合成；
        // 落位后立即重启（浮窗还在，防熄屏语义不受影响）。缩放同享（isLiveResizing）。
        AevonLog.info("[窗口] 拖动\((moving ? "开始 → 熄屏重申拍子暂停（降载防丢帧）" : "结束 → 熄屏重申拍子恢复"))"
            + "（AevonDragLeanV269）")
        if moving {
            idleKickTimer?.invalidate()
            idleKickTimer = nil
        } else {
            if idleKickTimer == nil { startIdleKickTimerOnly() }
        }
        if moving {
            // 位移期间不做任何抓帧（整屏 drawHierarchy 会直接掉帧）
            snapshotRecaptureWork?.cancel()
        } else {
            // 落位后补一张（守卫要用最新的「最后一帧」）
            scheduleSnapshotRecapture(after: 0.8)
        }
    }

    /// V0.2.69：只重启 8 秒重申拍子（不重复布防日志、不重复 install）。
    private func startIdleKickTimerOnly() {
        let timer = Timer(timeInterval: 8.0, repeats: true) { [weak self] _ in
            let now = AevonWindowView.kickIdleTimerIfNeeded()
            guard let self, now != self.idleKickMask else { return }
            self.idleKickMask = now
            AevonLog.info("[窗口] 熄屏压制方式变化 → \(AevonWindowView.idleKickMaskText(now))"
                + "（AevonNoAutoLockV249 AevonNoAutoLockV250）")
        }
        RunLoop.main.add(timer, forMode: .common)
        idleKickTimer = timer
    }

    // MARK: - 外角缩放（V0.0.36 起，V0.0.37 移到窗外角块）

    /// 外角块的缩放手势。
    ///
    /// 缩放锚点 = 对角的固定点（拖右下角 → 左上角不动），手势期间只改
    /// 外层 `transform`（V0.0.12 的零布局思路），抬手才提交真实 frame。
    private func handleCornerResize(_ gesture: UIPanGestureRecognizer, edges: UIRectEdge) {
        guard superview != nil else { return }
        let point = gesture.location(in: superview)
        switch gesture.state {
        case .began:
            resizeOriginFrame = frame
            resizeOriginPoint = point
            resizeOriginEdges = edges
            // 锚点取「不动的那些边」的交点：拖右 → 锚在左（x=0）；拖左 → 锚在右（x=1）；
            // 只拖上下 → x 居中；y 同理。
            let ax: CGFloat = edges.contains(.left) ? 1.0
                : (edges.contains(.right) ? 0.0 : 0.5)
            let ay: CGFloat = edges.contains(.top) ? 1.0
                : (edges.contains(.bottom) ? 0.0 : 0.5)
            beginLiveResize(anchor: CGPoint(x: ax, y: ay))

        case .changed:
            applyCornerResize(to: point, edges: edges)

        case .ended, .cancelled, .failed:
            finishEdgeResize()

        default:
            break
        }
    }

    /// 缩放的纯计算部分（V0.0.41 拆出来）：pan 与全局通道共用。
    ///
    /// **V0.2.48（AevonCanvasFixedV248）：不再动外层矩阵，直接改真实 frame。**
    /// 因为画布恒定，改 frame 只影响两件本地的事：内容区 bounds（→ 呈现层 scale）
    /// 与外缘发光圈几何；App 侧一次 resize 都收不到，画面始终是活的。
    /// 固定点 = 手势起手 frame 里锚点对应的那一点（拖右下角 → 左上角不动）。
    private func applyCornerResize(to point: CGPoint, edges: UIRectEdge) {
        let dx = point.x - resizeOriginPoint.x
        let dy = point.y - resizeOriginPoint.y
        let width = clampedCornerWidth(dx: dx, dy: dy, base: resizeOriginFrame,
                                       edges: edges, point: point)
        let height = width / AevonWindowView.contentAspectCurrent
        let anchor = resizeAnchor
        let fixed = CGPoint(x: resizeOriginFrame.minX + anchor.x * resizeOriginFrame.width,
                            y: resizeOriginFrame.minY + anchor.y * resizeOriginFrame.height)
        let target = CGRect(x: fixed.x - anchor.x * width,
                            y: fixed.y - anchor.y * height,
                            width: width, height: height)
        frame = target
        layoutIfNeeded()   // 立即把 bounds/圆角/呈现层缩放落到位（拖动要跟手）
    }

    /// 只有「宽度」一个自由度：高度 = 宽度 × 比例（高:宽 = 7:12，AevonFloat53PortraitV222）。
    ///
    /// **V0.2.68（AevonZoomRadialV268，用户 Aevon(40) #2「快速缩放时，悬浮窗会一跳一跳的」）：**
    /// 0.2.67 修好了底边方向（+dy），但「横向按 dx / 纵向按 dy、按绝对值大小
    /// 切换口径」这个机制还在 —— 快速斜拖时手指在切换点两侧来回穿越，两次取的
    /// 是**两个不同的值**（横向宽度 vs 纵向换算宽度），宽度帧间无过渡地来回跳，
    /// 这就是「一跳一跳」的真凶。
    /// 现在角块改**径向因子**：k = 当前指尖到锚点的距离 / 起手指尖到锚点的距离，
    /// 宽度 = 起手宽 × k —— 任何方向、任何速度都连续（缩放手势的标准做法）；
    /// 纯边拖动保持单一轴向（本来就连续）。同一手势内 edges 不变，口径永不切换。
    private func clampedCornerWidth(dx: CGFloat, dy: CGFloat, base: CGRect,
                                    edges: UIRectEdge, point: CGPoint) -> CGFloat {
        let aspect = AevonWindowView.contentAspectCurrent
        let screen = UIScreen.main.bounds

        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        let anchorPt = CGPoint(x: base.minX + resizeAnchor.x * base.width,
                               y: base.minY + resizeAnchor.y * base.height)
        var width: CGFloat? = nil
        if horizontal && vertical {
            /* 角块：径向因子（V0.2.68 AevonZoomRadialV268）。
             * r0 有下限 20pt，防起手点与锚点重合时除零。 */
            let r0 = hypot(resizeOriginPoint.x - anchorPt.x, resizeOriginPoint.y - anchorPt.y)
            let r = hypot(point.x - anchorPt.x, point.y - anchorPt.y)
            width = base.width * (r / max(r0, 20.0))
        } else if horizontal {
            let signed = edges.contains(.left) ? -dx : dx
            width = base.width + signed
        } else if vertical {
            /* 底边 +dy（下拖 = 放大）、顶边 -dy（上拖 = 放大）（V0.2.67 AevonCornerDirV267）。 */
            let signedY = edges.contains(.top) ? -dy : dy
            width = (base.height + signedY) * aspect
        }
        var result = width ?? base.width
        // 上限：不超屏高 92%，宽度不超屏宽 95%
        let maxWidth = max(AevonWindowView.minContentWidth,
                           min(screen.width * 0.95, screen.height * 0.92 * aspect))
        result = max(AevonWindowView.minContentWidth, min(result, maxWidth))
        return result
    }

    /// 进入「实时缩放」。
    ///
    /// V0.0.24（AevonFloatRoundResizeV224）：Aevon(108) 反馈缩放中四角变直角 ——
    /// 不再临时关圆角/裁剪（圆角全程保持）。
    /// V0.2.26（AevonFloatSnapResizeV226）：Aevon(1) 反馈缩放卡顿 → 起手冻结成静态图。
    /// **V0.2.48（AevonCanvasFixedV248）：Aevon(23) 反馈「缩放时整窗黑屏、必须松手才出画」——
    /// 冻结图这条路彻底退出缩放手势。**
    ///
    /// 为什么现在可以不冻结：画布恒定 = 屏宽 × 屏宽/比例，缩放不再写 App 画布，
    /// 「实时内容」只是一层本地 CALayer transform（scale = 窗口宽/屏宽），
    /// 逐帧成本与一张静态图同级，却**始终是活画面** —— 黑屏的成因（每次提交后
    /// App 远程表面重绘）根本不再发生。
    /// 只保留 `captureSnapshotImage` / `cachedSnapshotImage` 这一层，改由
    /// 回桌面黑屏守卫使用（那里需要「最后一帧」兜底）。
    private func beginLiveResize(anchor: CGPoint) {
        isLiveResizing = true
        resizeAnchor = anchor
    }

    // MARK: - 缩放快照（V0.2.26，AevonFloatSnapResizeV226；V0.2.27 缓存化 AevonFloatSnapCacheV227）
    //
    // V0.2.48（AevonCanvasFixedV248）：**缩放手势不再使用快照**（画布恒定后缩放只改本地
    // 矩阵，活画面比静态图更好）。`installResizeSnapshot` / `removeResizeSnapshot` /
    // `resizeSnapshotView` 随之删除；只保留「抓一帧 + 空闲预抓缓存」这一层，
    // 由回桌面黑屏守卫拿去当「最后一帧」兜底。

    /// 空闲时预抓的内容快照（V0.2.27，AevonFloatSnapCacheV227）
    private var cachedSnapshotImage: UIImage?
    private var snapshotRecaptureWork: DispatchWorkItem?

    /// 抓一帧内容区当前画面，并校验「这真是一幅画面」。
    ///
    /// **V0.2.49（AevonDarkGuardV249）：两条路径 + 一条判据。**
    /// Aevon(24) 的「回桌面黑屏 1 秒以上」追下去发现：`layer.render(in:)` **抓不到
    /// 跨进程远程表面**（0.2.26 已记录），抓到的只是 contentClip 那层深灰底色 ——
    /// 于是「最后一帧」铺上去就是一块纯色，用户看到的就是黑屏。
    /// 现在：
    ///   ① 主路径 `drawViewHierarchyInRect:afterScreenUpdates:NO` —— 走渲染服务器取
    ///      「这一块屏幕上现在是什么」，这类抓法**包含**远程表面（屏幕截图同源）；
    ///   ② 备路径 `layer.render(in:)`（老路径，某些场景下反而有效）；
    ///   ③ 判据 `imageLooksLikeContent`：既要有不透明像素，也要有明显明暗差
    ///      （纯色 = 空壳，宁可不盖）；两条路径都过不了就返回 nil。
    /// 只在空闲路径调用；缩放手势里绝不做同步渲染。
    private func captureSnapshotImage() -> UIImage? {
        let bounds = contentClip.bounds
        guard bounds.width > 1, bounds.height > 1, !isLiveResizing else { return nil }
        let scale = contentClip.layer.contentsScale > 0 ? contentClip.layer.contentsScale : 3.0

        // ① 屏幕同源抓取（含远程表面）
        var hierarchyImage: UIImage?
        let hierarchyException = AevonShieldRun { [weak self] in
            guard let self else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
            hierarchyImage = renderer.image { _ in
                _ = self.contentClip.drawHierarchy(in: self.contentClip.bounds,
                                                   afterScreenUpdates: false)
            }
        }
        if hierarchyException == nil, let image = hierarchyImage, imageLooksLikeContent(image) {
            return image
        }

        // ② 老路径：CALayer 渲染
        var layerImage: UIImage?
        let layerException = AevonShieldRun { [weak self] in
            guard let self else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
            layerImage = renderer.image { ctx in
                self.contentClip.layer.render(in: ctx.cgContext)
            }
        }
        guard layerException == nil, let image = layerImage,
              image.size.width > 1, imageLooksLikeContent(image) else { return nil }
        return image
    }

    /// V0.2.93（AevonFrameMatchRevealV293）：冻结帧 vs 实时帧「结构一致」判定。
    ///
    /// 双图降采样 16x16 灰度，平均绝对差 < 10/255 视为一致 —— 内容是静态 UI（设置、
    /// Sileo 等）时撤帧瞬间零跳变；视频内容帧间运动大时大概率不一致 → 走回 2 拍
    /// 稳定撤（fail-open，行为不劣于 0.2.92）。不对齐 alpha（裁剪后统一不透明化）。
    private func freezeMatchesLive(_ freeze: UIImage, _ live: UIImage) -> Bool {
        guard let fcg = freeze.cgImage, let lcg = live.cgImage else { return false }
        let n = 16
        var fBuf = [UInt8](repeating: 0, count: n * n * 4)
        var lBuf = [UInt8](repeating: 0, count: n * n * 4)
        guard let fCtx = CGContext(data: &fBuf, width: n, height: n, bitsPerComponent: 8,
                                   bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let lCtx = CGContext(data: &lBuf, width: n, height: n, bitsPerComponent: 8,
                                   bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        fCtx.interpolationQuality = .low
        lCtx.interpolationQuality = .low
        fCtx.draw(fcg, in: CGRect(x: 0, y: 0, width: n, height: n))
        lCtx.draw(lcg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var total = 0
        for i in stride(from: 0, to: fBuf.count, by: 4) {
            // 不透明化：黑底合成（远端表面抓帧可能带 alpha）
            let fl = (Int(fBuf[i]) * Int(fBuf[i + 3]) * 3 + Int(fBuf[i + 1]) * Int(fBuf[i + 3]) * 6
                + Int(fBuf[i + 2]) * Int(fBuf[i + 3])) / (10 * 255)
            let ll = (Int(lBuf[i]) * Int(lBuf[i + 3]) * 3 + Int(lBuf[i + 1]) * Int(lBuf[i + 3]) * 6
                + Int(lBuf[i + 2]) * Int(lBuf[i + 3])) / (10 * 255)
            total += abs(fl - ll)
        }
        let avg = total / (n * n)
        return avg < 10
    }

    /// 判「这张图是一幅画面，还是一块纯色空壳」。
    ///
    /// 采样 8×8：既要有不透明像素（全透明 = 远程表面没抓到），
    /// 又要有明显明暗差（纯色 = 只抓到了背景层，铺上去就是一块黑/灰）。
    /// 阈值取 10/255：真实 App 界面（哪怕全黑视频 + 一行字幕）的明暗跨度远大于它。
    private func imageLooksLikeContent(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let n = 8
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var maxAlpha: UInt8 = 0
        var minLuma = 255
        var maxLuma = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            maxAlpha = max(maxAlpha, pixels[i + 3])
            let luma = (Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])) / 10
            minLuma = min(minLuma, luma)
            maxLuma = max(maxLuma, luma)
        }
        if maxAlpha <= 8 { return false }
        return (maxLuma - minLuma) >= 10
    }

    // MARK: - 断层修复（V0.2.61，AevonDouyinRepairV261，用户 Aevon(35) #9）

    /// 开窗 2.2 秒后自查一次：窗口下半截是不是整块黑的。
    ///
    /// 判据用**现场抓到的画面**，不看尺寸（0.2.60 的尺寸判定已经被日志证明会误判
    /// 「已贴合」）：下半 25% 采样点几乎全黑、上半 50% 有明显明暗跨度、且**黑区正上方那一带
    /// 本身是亮的**（把「深色 App 本来就底部全黑」摘出去）→ 判定断层，
    /// 触发一次「画布回整屏 → 写回 → 踢重排」。一次开窗只做一次。
    func scheduleSeamRepair(canvas: CGSize) {
        guard canvas.width > 2, canvas.height > 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.window != nil, !self.isTearingDown, !self.isDocked else { return }
            guard let image = self.captureSnapshotImage() else {
                AevonLog.info("[窗口] 断层自查：抓不到画面，本次跳过（AevonDouyinRepairV261）")
                return
            }
            let stats = AevonWindowView.lumaStats(image)
            guard stats.topRange >= 20 else {
                AevonLog.info("[窗口] 断层自查：上半截明暗跨度只有 \(stats.topRange)，画面还没稳定 → 跳过"
                    + "（AevonDouyinRepairV261）")
                return
            }
            guard stats.bottomBlack >= 0.985 else {
                AevonLog.info("[窗口] 断层自查：下半截黑点占比 "
                    + "\(String(format: "%.3f", stats.bottomBlack)) → 画面正常，无需修复"
                    + "（AevonDouyinRepairV261）")
                return
            }
            // 深色 App 本来就「上半有内容、下半一片黑」—— 只按黑点占比判会误伤一大片，
            // 每次开窗都白做一次全屏往返（肉眼就是一下闪）。断层的特征是**断层线**
            // 上方紧贴的就是正常画面，所以再要求黑区正上方那一带确实有亮度。
            guard stats.aboveMean >= 25 else {
                AevonLog.info("[窗口] 断层自查：下半截虽黑，但黑区上方也是暗的（平均亮度 "
                    + "\(Int(stats.aboveMean))）→ 判定为深色界面，不修复"
                    + "（AevonDouyinRepairV261）")
                return
            }
            AevonLog.warn("[窗口] 断层自查：上半截正常而**下半截整块黑**"
                + "（黑点 \(String(format: "%.3f", stats.bottomBlack))）→ 判定断层，触发全屏往返修复"
                + "（AevonDouyinRepairV261）")
            self.sceneHost.bounceFullscreenThenBack(width: canvas.width, height: canvas.height,
                                                    tag: self.bundleID)
        }
    }

    /// 采样 12×24 网格：返回「下半截黑点占比」「上半截明暗跨度」「黑区正上方的平均亮度」。
    static func lumaStats(_ image: UIImage) -> (bottomBlack: Double, topRange: Int, aboveMean: Double) {
        guard let cg = image.cgImage else { return (1.0, 0, 0) }
        let w = 12, h = 24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (1.0, 0, 0)
        }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext 的原点在左下：row 0 = 画面**底部**。
        // 下半截 = row 0..<6（底部 25%）；黑区上方那一带 = row 6..<9（25%–37.5%）。
        var bottomTotal = 0, bottomDark = 0
        var topMin = 255, topMax = 0
        var aboveSum = 0, aboveCount = 0
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let luma = (Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])) / 10
                if row < 6 {
                    bottomTotal += 1
                    if luma <= 14 { bottomDark += 1 }
                } else if row < 9 {
                    aboveSum += luma
                    aboveCount += 1
                } else if row >= 12 {
                    topMin = min(topMin, luma)
                    topMax = max(topMax, luma)
                }
            }
        }
        let ratio = bottomTotal > 0 ? Double(bottomDark) / Double(bottomTotal) : 1.0
        let above = aboveCount > 0 ? Double(aboveSum) / Double(aboveCount) : 0
        return (ratio, max(0, topMax - topMin), above)
    }

    /// 「离黑屏最近的那一帧」：优先现场抓（画面还在时抓到的就是真·最后一帧），
    /// 抓不到/是空壳才退回滚动缓存。
    /// V0.2.98（AevonCacheFreezeV298）：新增 refreshCache 开关 —— 盖帧路径传 false，
    /// 绝不把回桌面转场中抓到的模糊帧写进滚缓存（污染后续垫帧）。
    private func lastContentFrame(refreshCache: Bool = true) -> UIImage? {
        if let fresh = captureSnapshotImage() {
            // V0.2.73（AevonLivePadDarkV273，用户 Aevon(45) #5「回桌面黑屏 1 秒左右才出
            // 实时画面」）：**黑帧拒垫** —— 现场抓帧发生在 App 场景退场过程中时，
            // drawHierarchy 抓出来的可能整幅发黑；黑帧垫上去 = 用户看到的「黑屏 1 秒」。
            // 中心 + 四角采样，全黑（RGB 均 < 8/255）就丢弃，回落滚动缓存帧
            //（refreshRollingSnapshot 每 3 秒保温的那张「离黑屏最近的帧」）。
            if Self.isMostlyBlack(fresh) {
                AevonLog.warn("[窗口] 现场抓帧全黑（退场中抓到黑画面）→ 弃用，垫滚动缓存帧"
                    + "（AevonLivePadDarkV273）")
            } else {
                if refreshCache { cachedSnapshotImage = fresh }
                return fresh
            }
        }
        return cachedSnapshotImage
    }

    /// V0.2.73（AevonLivePadDarkV273）：中心 + 四角五点采样，全部 RGB < 8 视为黑帧。
    ///
    /// V0.2.78（AevonSnapDarkV278）：从实例方法提成 static —— 再开窗的「窗口区域屏幕快照」
    /// 垫底图也要用同一套判据（见 `windowRegionSnapshot`）。
    private static func isMostlyBlack(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, cg.width > 4, cg.height > 4 else { return false }
        guard let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let pts = [(cg.width / 2, cg.height / 2),
                   (cg.width / 4, cg.height / 4),
                   ((cg.width * 3) / 4, cg.height / 4),
                   (cg.width / 4, (cg.height * 3) / 4),
                   ((cg.width * 3) / 4, (cg.height * 3) / 4)]
        for (px, py) in pts {
            let off = py * bpr + px * bpp
            guard off + 3 < CFDataGetLength(data) else { continue }
            let r = Int(bytes[off]), g = Int(bytes[off + 1]), b = Int(bytes[off + 2])
            if r > 8 || g > 8 || b > 8 { return false }
        }
        return true
    }

    /// V0.3.24（AevonSharpCacheGateV324）：这张图是否达到本窗历史清晰基线的 85%。
    /// 基线还没建立（<1）时一律放行 —— 不能因为「不知道多清晰」就把所有帧拒掉。
    private func snapshotIsSharp(_ image: UIImage) -> Bool {
        guard sharpBaseline > 1.0 else { return true }
        return sharpnessScore(image) >= sharpBaseline * 0.85
    }

    /// V0.3.24（AevonSharpCacheGateV324）：**缓存帧入库闸**。
    ///
    /// 用户 Aevon(98) #2「返回桌面时悬浮窗内容从定格模糊变为清晰的实时画面」的根因之一：
    /// `scheduleSnapshotRecapture` / `refreshRollingSnapshot` 抓到什么就存什么，只过了
    /// `imageLooksLikeContent`（8×8 明暗差）和 `isMostlyBlack`（五点黑）—— 这两个判据
    /// **对模糊完全无感**。0.6s / 3s 的定时很容易落在回桌面转场、场景降级那一拍，
    /// 抓到的就是系统重采样后的低清表面；一旦入库，此后每次盖帧垫的都是它，
    /// 而撤帧门槛又是「相对这张图」算的（base × 0.72）→ 基准被拉低 → 模糊活画面
    /// 也判「已清晰」→ 早撤 → 用户看到的就是「定格模糊 → 变清晰」。
    ///
    /// 药方两层：
    ///   ① 入库要过清晰度闸（相对 `sharpBaseline` 的 85%）；模糊帧丢弃，保留上一张清晰帧；
    ///   ② `sharpBaseline` 取同窗历史**最大值**，一次清晰帧就把门槛抬到正确高度。
    ///      连续 6 次被拒说明内容真的变简（纯色页），此时接受当前帧并按它重置基准 ——
    ///      否则会永远拒收、缓存冻结在旧画面。
    @discardableResult
    private func admitSnapshot(_ image: UIImage?, tag: String) -> Bool {
        guard let image else { return false }
        let score = sharpnessScore(image)
        let floor = sharpBaseline > 1.0 ? sharpBaseline * 0.85 : 0
        if score >= floor {
            cachedSnapshotImage = image
            lastSharpSnapshotImage = image
            if score > sharpBaseline { sharpBaseline = score }
            sharpRejectStreak = 0
            if !sharpAdmitLogged {
                sharpAdmitLogged = true
                AevonLog.info("[窗口] 缓存帧入库：清晰度 \(Int(score))（基准 \(Int(sharpBaseline))，"
                    + "来源 \(tag)）（AevonSharpCacheGateV324）")
            }
            return true
        }
        sharpRejectStreak += 1
        if sharpRejectStreak >= 6 {
            // 连续被拒 = 内容本来就没有高频（纯色/极简页），接受并重置基准
            cachedSnapshotImage = image
            lastSharpSnapshotImage = image
            sharpBaseline = score * 0.9
            sharpRejectStreak = 0
            AevonLog.warn("[窗口] 连续 6 次缓存帧被判模糊（内容可能本就极简）→ 接受并按它重置基准"
                + "（清晰度 \(Int(score))，来源 \(tag)）（AevonSharpCacheGateV324）")
            return true
        }
        if sharpRejectStreak == 1 || sharpRejectStreak == 3 {
            AevonLog.info("[窗口] 缓存帧清晰度不足 → 丢弃（\(Int(score)) < 门槛 \(Int(floor))，"
                + "连续第 \(sharpRejectStreak) 次，保留上一张清晰帧，来源 \(tag)"
                + "）（AevonSharpCacheGateV324）")
        }
        return false
    }

    /// 空闲时预抓快照进缓存（窗口创建后首帧、每次缩放提交后各一次）。
    private func scheduleSnapshotRecapture(after delay: TimeInterval = 0.6) {
        // V0.3.25（AevonNoFreezeV325）：B3 不盖帧 ⇒ 预抓也没有消费方，直接不抓（省热路径开销）
        guard !AevonWindowView.freezeDisabled else { return }
        snapshotRecaptureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isLiveResizing, !self.isBarHoldMoving,
                  self.hintLabel.isHidden else { return }
            self.admitSnapshot(self.captureSnapshotImage(), tag: "空闲预抓")
        }
        snapshotRecaptureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 抬手：几何在拖动过程中已经实时生效，这里只做「夹回屏幕 + 落盘 + 刷圆角/发光」。
    ///
    /// V0.2.48（AevonCanvasFixedV248）：不再有 `transform → frame` 的换算，
    /// 也不再有「抬手后重排一次画布」那一步（画布恒定）。
    private func finishEdgeResize() {
        guard isLiveResizing else { return }
        isLiveResizing = false
        let clamped = AevonWindowView.clampedToScreen(frame)
        if clamped != frame {
            frame = clamped
            layoutIfNeeded()
        }
        persistFrame()
        updateCornerRadius(animated: true)
        updateEdgeGlow()
        let canvas = AevonWindowView.canvasSize(for: frame.size)
        AevonLog.info("[窗口] 缩放到 \(Int(frame.width))x\(Int(frame.height))"
            + "（实时缩放：画布恒 \(Int(canvas.width))x\(Int(canvas.height)) 未变，"
            + "呈现层缩放 \(String(format: "%.2f", canvas.width / max(1, frame.width)))）"
            + "（AevonEdgeResizeV37 AevonCanvasFixedV248 AevonCornerDirV267 AevonZoomRadialV268）")
    }

    /// V0.2.48（AevonCanvasFixedV248）：把窗口**完整夹进屏幕**。
    ///
    /// Aevon(23)：「设定一个值，悬浮窗永远不能移出手机屏幕，必须保留左右或者底部一方在屏幕内，
    /// 避免出现无法拖动的问题」。旧逻辑是「留 60pt 可见」，但手柄是挂在窗口**外面**的边条，
    /// 窗口有一半在屏外时那侧手柄就点不到了 —— 用户体感就是「拖丢了、救不回来」。
    /// 完整夹进屏内后，四条边条的 10pt 压边（向窗内）始终在屏幕里，随时能再抓住它。
    /// 这同时根治了「有时自动跑到右下角」：旧逻辑允许把窗口停在只露 60pt 的位置，
    /// 那个位置被当成记忆落盘（x 86% / y 92%），下次开窗就「跑到右下角」。
    static func clampedToScreen(_ rect: CGRect) -> CGRect {
        let screen = UIScreen.main.bounds
        guard screen.width > 4, screen.height > 4, rect.width > 1, rect.height > 1 else { return rect }
        let aspect = max(0.2, contentAspectCurrent)
        var width = min(rect.width, screen.width)
        var height = width / aspect
        if height > screen.height {
            height = screen.height
            width = height * aspect
        }
        let x = min(max(0, rect.minX), max(0, screen.width - width))
        let y = min(max(0, rect.minY), max(0, screen.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - 回桌面黑屏守卫（V0.2.47，AevonDarkGuardV247）

    /// 布防截止时刻（`CACurrentMediaTime`；0 = 未布防）。
    private var guardArmedUntil: TimeInterval = 0
    /// V0.2.49（AevonDarkGuardV249）：守卫专用拍子（0.2 秒一拍）。
    ///
    /// 0.2.47/0.2.48 用的是 0.5 秒那根通用巡检定时器，撤冻结还要连续两拍 ——
    /// 场景明明 0.2 秒就回来了，用户却还要多看最多 1 秒的定格画面。
    /// Aevon(24)：「回桌面时会出现 1 秒以上的黑屏」= 这一段。
    /// 现在守卫自己拿一根 0.2 秒的拍子，且**一看到 cs=2 就立刻撤**。
    private var guardTimer: Timer?
    /// 连续「没在画」的拍数（0.2s 一拍）
    private var darkTicks = 0
    /// 连续「在画」的拍数（V0.2.50：稳定 2 拍才撤冻结）
    private var renderTicks = 0
    /// 这个布防窗口里撤过几次冻结（用于日志与「撤了又掉」的自愈）
    private var freezeRemoveCount = 0
    /// V0.2.63（AevonFlashDampV263）：最近一次撤冻结的时刻 —— 撤完 1.2 秒内不许再盖。
    ///
    /// Aevon(37) #6：回桌面后「画面快速闪」。常驻看门是 0.1 秒一拍，而系统在这段时间里
    /// `cs` 会 2→0→2 抖：一掉就盖帧、一回来就撤帧、再掉再盖…… 每次盖/撤都是一次
    /// 完整换图 = 用户眼里的「快速闪」。这里给盖帧加两道阻尼：
    /// ① 连续 3 拍（0.3s）都不在画才盖；② 撤帧后 1.2s 的静默期内不许再盖。
    private var lastFreezeRemovedAt: TimeInterval = 0
    private static let freezeQuietWindow: TimeInterval = 1.2
    /// 常驻看门（没布防）时的连续「掉出画」拍数
    private var idleDarkTicks = 0
    /// 盖上来的「最后一帧」快照（永不黑屏的兜底层）
    private var darkFreezeView: UIImageView?
    /// 本次布防里已经重申过几次前台 / 上一次重申的时刻
    private var reassertCount = 0
    private var lastReassertAt: TimeInterval = 0
    /// V0.3.27（AevonReassertBudgetV327，用户 Aevon(100) #2「返回桌面时黑白闪 2 次」）：
    /// **让位期的重申预算**。`-1` = 不限（沿用旧的 `reassertCount < 4`），`>= 0` = 还能写几次。
    ///
    /// 为什么要有它：Aevon(100) 三次回桌面全部同构 —— 布防那拍「立即」一发、+0.40s 再一发，
    /// 两发之间 `cs` 还在 0/1 之间来回（0→1，又掉回 0→1）。每一次 `updateSettings`
    /// 都会让远程表面重建一次，屏幕上就是黑一下再亮一下 —— 用户数的「闪两次」就是这两发。
    /// 让位窗口只有 0.75 秒，两发都在窗口里，第二发抢到的是**同一个**恢复过程，
    /// 额外价值接近零，代价是实打实多闪一次。所以让位期只放行 1 发。
    private var liveWaitReassertBudget = -1
    /// 让位期「画面已在画 → 重申跳过」只打一行，避免每 0.1s 一拍刷屏
    private var liveWaitReassertSkipLogged = false
    /// V0.2.85（AevonIdleRewakeV285）：定格自愈 —— 上一次「重新布防 + 重申」的时刻
    /// 与累计次数。低频（每 3 秒最多一次）是为了不在全屏 App 前台时把场景设置写爆。
    private var lastIdleRewakeAt: TimeInterval = 0
    private var lastIdleRewakeStartedAt: TimeInterval = 0
    private var idleRewakeCount = 0
    /// 滚动快照的最后刷新时刻
    private var lastSnapshotRefreshAt: TimeInterval = 0
    /// 连续抓不到快照的次数（≥3 就把滚动刷新退避到 30 秒）
    private var snapshotMissStreak = 0

    // V0.2.60（AevonLiveFirstV260，用户 Aevon(34) #1）：「先显示实时动画，然后再自动
    // 打开悬浮窗」—— 回桌面时不再拿一张定格帧盖住整窗硬撑 1 秒，而是：浮窗先让位
    //（alpha 0.02 = 看不见但仍在渲染树里，一秒内会被拉回），系统的回桌面动画先播完，等浮窗里那个场景真的重新
    // 出画（cs=2 且现场抓得到真画面）再 0.12 秒淡入。上限 1.0 秒，到点无论如何都要
    // 出现（画面还没回来就先垫缓存帧，绝不留一块黑的空窗）。
    private var liveWaitDeadline: TimeInterval = 0
    private var liveWaitStartedAt: TimeInterval = 0
    /// 连续「cs=2 且现场抓得到真画面」的拍数（0.1s 一拍）：要求稳定 2 拍才淡入，
    /// Aevon(34) 日志里 cs 会 2→0→2 抖一次，第一拍就淡入会「亮一下又黑」。
    private var liveWaitTicks = 0
    /// V0.2.65（AevonNoVanishV265）：让位期**不再现场抓帧**，次数计数器随之退休。
    /// V0.2.94（AevonQuietRevealV294，用户确认方案 M）：加「转场静默」闸后多占拍数
    /// （连续 2 拍静止才放行），fail-open 上限 1.0 → 1.5s —— 冻结帧全程在盖，
    /// 最坏也只是定格多 0.5s，绝不回到黑窗。
    private static let liveWaitLimit: TimeInterval = 1.5
    /// V0.2.93（AevonFrameMatchRevealV293，用户 Aevon(62)「从虚变实的淡入还在」+ 用户
    /// 确认按 Stheno 方案 A）：**撤帧判据升级为「冻结帧与实时画面比对一致」**。
    /// Stheno 揭幕纪律 = 封面与目标内容连续采样**一致**才揭幕（startupCoverReadySamples）
    /// —— 撤帧瞬间定格与实时若画面一致，视觉就是零跳变；「虚→实」从机制上消失。
    /// 冻结帧图像本体（installDarkFreeze 时留存），供比对；撤帧即清。
    private var darkFreezeImage: UIImage?
    /// 让位期比对只做一次（0.2.65 教训：drawHierarchy 强迫重绘 = 闪，绝不逐拍抓）。
    private var frameMatchTried = false
    /* V0.2.94~0.2.99 的「转场静默」几何采样（旧静默拍数/几何基线变量组）已于
     * V0.2.100 整体退役 —— Aevon(77) 实锤：几何静止 ≠ 画面清晰（静止时活表面仍是被
     * 切换器重采样后的模糊帧），且「静默重抓」从模糊表面抓回来的还是模糊帧。 */
    /* V0.2.100（AevonReturnDeadlineV2100，用户 Aevon(77)「按 Stheno 无模糊段是独立窗口的
     * 结构优势去重新制作，回桌面不要任何几何禁止画面模糊」+ 确认方案 F）：
     * **Stheno SCWSNativeFullRequest.returnDeadline 同构** —— 逆向报告 §4.4 CONFIRMED：
     * 它回桌面时立一个独立返回窗口承接视觉，挂固定 returnDeadline，等转场彻底走完才
     * completeReturn；它的场景是 owned 场景、不在切换器缩放层级里，转场动不了它。
     * Aevon 的场景被系统放在切换器缩放层级里，唯一等价做法 = **盖帧挂固定 returnDeadline
     * （盖帧起 1.2s），deadline 内任何路径不得撤帧**；到点一次撤清，此时回桌面转场
     * （实测 0.8~1.2s）已结束、活表面已清晰。全程零几何判定、纯独立窗口遮盖。
     * 盖帧时刻起算的撤帧时钟（installDarkFreeze 设定，removeDarkFreeze 清零）。 */
    private var freezeReturnDeadline: TimeInterval = 0
    /// deadline 内压住撤帧只记一次日志，避免逐拍刷屏
    private var guardHoldLogged = false
    /* V0.3.1（AevonSharpGateV301，用户 Aevon(79) #2「依旧从模糊到清晰」+ 确认「清晰度
     * 就绪采样闸」）：**撤帧判据从「时间到了」改成「画面真的清晰了」**。
     * Aevon(79) 三条实锤拼出真相：①盖帧图 315x540pt @3x = 945x1620 像素（图本身不模糊）；
     * ②撤帧前 1.2s 日志「屏幕贴合：状态翻转 → 开（改报画布尺寸），已让 1 个窗口立即重排」
     * （App 正在重排渲染）；③「让位期帧比对：一致」用的是 16x16 降采样灰度平均差 ——
     * 模糊的本质是高频丢失，降到 16x16 后高频全没了，模糊图与清晰图**永远判"一致"**。
     * 所以真实链条是：盖住 1.2s（清晰定格，用户无感）→ 撤帧 → 露出正在重排的画面 /
     * 系统低清场景快照（模糊）→ 真实渲染到位（清晰）。模糊在**撤帧之后**，过去六版
     * （0.2.94 静默闸 / 0.2.97 重抓 / 0.2.98 缓存帧 / 0.2.99 全程盖 / 0.2.100 deadline /
     * 0.3.0 独立窗口）全修在盖帧期，所以怎么改都没用。
     * Stheno 逆向对照（浮窗生命周期报告 §揭幕）：它的揭幕判据 = 「启动图封面 + **连续
     * 就绪采样** + 代际」，不是固定延迟。这里搬"连续就绪采样"，采样指标换成画面清晰度
     * —— 直接对准症状本身。 */
    /// V0.3.25（AevonNoFreezeV325）B3「完全不盖帧」→ **V0.3.34 收回（AevonFreezeBackV334）**。
    ///
    /// 0.3.25 定档 B3 的理由是「盖上去的是一张缓存帧，撤帧时糊一下再清」；但这个前提
    /// 在 0.3.24 的 AevonSharpCacheGateV324 之后已经不成立（缓存入库过清晰度闸、
    /// 另有可信帧兜底）。而 B3 的代价是实打实的：Aevon(99) 实测过渡哨命中到画面回来
    /// **1.48 秒**（08:17:58.629 哨 → 08:17:59.529 布防 cs=0 → 08:18:00.108 cs=2），
    /// 这 1.48 秒里浮窗一个字都没有 = 用户说的「回桌面闪一下」。
    /// 恢复盖帧后这 1.48 秒被一张清晰帧顶住，画面「停住」而不是「消失」。
    ///
    /// 回退通道不变：UserDefaults `AevonFreezeOff325` 写 true 即整条停用。
    /// ⛔ 不能写成字面量 `false`：Swift -O 的 whole-module 优化会做「从未被写过的
    /// 常量恒为该值」推断，把 guard 之后的函数体整段判为 unreachable 并删除 ——
    /// 连带里面的历史标记串一起消失（0.3.25 第一次构建就是红在这条）。
    /// 走 UserDefaults 取值，编译器拿不到编译期常量 → 函数体与标记都保留。
    static let freezeDisabled: Bool = {
        let v = UserDefaults.standard.object(forKey: "AevonFreezeOff325") as? Bool
        return v ?? false
    }()
    /// 「盖帧已停用」日志只打前 3 条，避免每次内容掉出画刷一行
    private static var freezeSkipLogCount = 0
    /// V0.3.24（AevonSharpCacheGateV324）：同窗历史**最清晰**帧的拉普拉斯方差 —— 撤帧门槛的
    /// 绝对基准。取最大值而非滑动平均：一次清晰帧就把门槛抬到正确高度，模糊帧永远抬不高它。
    private var sharpBaseline: Double = 0
    /// 最近一张过闸的清晰帧：缓存被拒/为空时的盖帧回退源（保证盖帧永不缺图）。
    private var lastSharpSnapshotImage: UIImage?
    /// 连续被清晰度闸拒收的次数（≥6 视为「内容本就极简」，接受并重置基准）
    private var sharpRejectStreak = 0
    private var sharpAdmitLogged = false
    /// 当次盖帧图是否可信（未过闸、用了回退源时为 false → 撤帧门槛改用历史基准）
    private var freezeBaseTrusted = true
    /// 开窗定稿后的「可信首帧」重试次数（上限 3）
    private var primeSharpAttempts = 0
    /// 盖帧图本身的清晰度基准（拉普拉斯方差；盖帧图是健康帧，作为"清晰"的参照）
    private var freezeBaseSharpness: Double = 0
    /// 清晰度采样的失败放行上限（超过就撤，行为退回 0.3.0，绝不把画面盖死）
    private var freezeSharpnessDeadline: TimeInterval = 0
    /// 上一次采样时刻（节流：0.3s 一次，抓帧=重绘纪律）
    private var lastSharpSampleAt: TimeInterval = 0
    /// 采样次数（上限 12 次，与 2.6s 上限双重封顶）
    private var sharpSampleCount = 0
    /// 「活画面仍模糊 → 继续盖」只记一次
    private var sharpHoldLogged = false
    /// 「清晰度就绪 → 准撤」只记一次
    private var sharpOpenLogged = false

    /// V0.3.1（AevonSharpGateV301）：**画面清晰度评分** —— 96x96 灰度 + 3x3 拉普拉斯方差。
    /// 模糊 = 高频丢失 = 拉普拉斯响应方差显著变小；清晰画面（文字边缘、图标、视频细节）
    /// 方差大。同一尺度下比较「盖帧图」与「当前活画面」，就能判出前者是否已经清晰到位。
    /// 成本：96x96 = 9216 次卷积，微秒级。
    private func sharpnessScore(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let n = 96
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 0
        }
        ctx.interpolationQuality = .default
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var gray = [Double](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            let o = i * 4
            let a = Double(buf[o + 3]) / 255.0
            gray[i] = (Double(buf[o]) * 0.3 + Double(buf[o + 1]) * 0.59
                + Double(buf[o + 2]) * 0.11) * a
        }
        var sum = 0.0, sumSq = 0.0, cnt = 0.0
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                let c = gray[y * n + x]
                let lap = 4 * c - gray[(y - 1) * n + x] - gray[(y + 1) * n + x]
                    - gray[y * n + x - 1] - gray[y * n + x + 1]
                sum += lap
                sumSq += lap * lap
                cnt += 1
            }
        }
        guard cnt > 0 else { return 0 }
        let mean = sum / cnt
        return max(0, sumSq / cnt - mean * mean)
    }

    /// V0.3.1（AevonSharpGateV301）：撤帧闸 = 最短保护期 + 清晰度就绪采样。
    /// 返回 true = 准撤（已过最短保护且活画面清晰度达标 / 采样到期 fail-open）；
    /// 返回 false = 继续盖帧（画面还没清晰到位，露出去就是用户看到的模糊）。
    private func guardReturnDeadlineOpen(now: TimeInterval) -> Bool {
        guard freezeReturnDeadline > 0 else { return true }   // 无盖帧 = 无压帧需求
        // ① 最短保护期 0.9s：任何路径不得撤帧（回桌面转场的最基本保护）
        if now <= freezeReturnDeadline {
            if !guardHoldLogged {
                guardHoldLogged = true
                AevonLog.warn("[窗口] 盖帧最短保护期内 → 冻结保持，不撤帧（0.9s 起进清晰度采样）"
                    + "（AevonFullFreezeV299 AevonReturnDeadlineV2100 AevonSharpGateV301）")
            }
            return false
        }
        // ② 清晰度就绪采样（Stheno「连续就绪采样」同构）：活画面够清晰才准撤
        if now <= freezeSharpnessDeadline, sharpSampleCount < 12 {
            if lastSharpSampleAt == 0 || now - lastSharpSampleAt >= 0.3 {
                lastSharpSampleAt = now
                sharpSampleCount += 1
                guard let live = captureSnapshotImage() else {
                    // 抓不到帧 = 无法判定 → fail-open 放行（绝不把画面盖死）
                    return true
                }
                let base = freezeBaseSharpness
                let score = sharpnessScore(live)
                /* V0.3.24（AevonSharpCacheGateV324）：门槛不再只由「当次盖帧图」决定 ——
                 * 那是自洽陷阱：盖帧图模糊 → base 低 → 门槛低 → 模糊的活画面也被判
                 * 「已清晰」→ 早撤 → 用户看到的正是「定格模糊 → 变清晰」。
                 * 有历史清晰基线时取 max(base×0.72, baseline×0.75)；盖帧图不可信时
                 * 直接以历史基线为准；基线缺失（<1，极简纯色内容）才退回 base 相对值
                 * 与 0.6 绝对下限。 */
                let need: Double
                if sharpBaseline > 1.0 {
                    need = freezeBaseTrusted ? max(base * 0.72, sharpBaseline * 0.75)
                                             : sharpBaseline * 0.75
                } else {
                    need = base > 1.0 ? base * 0.72 : 0.6
                }
                if score >= need {
                    if !sharpOpenLogged {
                        sharpOpenLogged = true
                        AevonLog.info("[窗口] 清晰度就绪：活画面 \(Int(score)) ≥ 门槛 \(Int(need))"
                            + "（盖帧基准 \(Int(base))，第 \(sharpSampleCount) 次采样）→ 准撤"
                            + "（AevonSharpGateV301）")
                    }
                    return true
                }
                if !sharpHoldLogged {
                    sharpHoldLogged = true
                    AevonLog.info("[窗口] 活画面仍模糊（\(Int(score)) < 门槛 \(Int(need))，"
                        + "盖帧基准 \(Int(base))，第 \(sharpSampleCount) 次采样）→ 继续盖帧等真实渲染"
                        + "（AevonSharpGateV301）")
                }
            }
            return false
        }
        // ③ 上限 fail-open：采样到期还在模糊 → 撤帧（行为退回 0.3.0，不劣化）
        AevonLog.warn("[窗口] 清晰度采样到期（\(sharpSampleCount) 次 / 上限 2.6s）→ fail-open 撤帧"
            + "（AevonSharpGateV301）")
        return true
    }
    /// V0.2.61（AevonLiveFirstFixV261）：淡入之后的「稳定期」。
    ///
    /// 回桌面那一下 cs 会 2→0→2 来回抖（Aevon(35)：让位 0.22s 淡入，随后系统还在
    /// 收尾动画）。0.2.60 在这个抖动里会按「看门：内容掉出画」去盖一张旧帧 →
    /// 用户看到的就是「画面 ←→ 黑」交替。稳定期内不盖帧、只重申前台。
    private var liveSettleUntil: TimeInterval = 0
    /// V0.2.63（AevonLiveHiddenV263）：让位到点仍无画面 → 整窗藏着等真画面
    private var liveAwaitingContent = false
    /// V0.2.65（AevonNoVanishV265）：让位期允许垫定格帧（窗口不再靠隐藏来遮黑）
    private var liveWaitFreezeAllowed = false
    /// V0.2.65（AevonEntryRevealV265）：入场淡入只做一次
    private var entryRevealDone = false
    private static let liveSettleWindow: TimeInterval = 0.9

    /// 全屏 App 画面离场（回桌面 / 切 App）时布防。
    ///
    /// 为什么是「布防 + 有界重申」而不是「每秒无限重申」：0.1.5 的历史结论写得很清楚
    /// —— 无限次往 FrontBoard 的场景状态机写 settings 是归档(14) SIGTRAP 的成因之一，
    /// 所以前台补偿一直是「开窗后头 8 次」的有界写法。这里沿用同一条纪律：
    /// 只在明确发生「场景离场」这个事件时补两拍，其他时候一次都不写。
    ///
    /// V0.2.49（AevonDarkGuardV249）：两处改动对齐 Aevon(24) 的 #6「回桌面黑屏 1 秒以上」。
    ///   ① **只在「确认没在画」时才盖最后一帧** —— 0.2.48 是无条件先盖，于是
    ///      「离场事件来了但画面其实还在」的情况下会白盖一张最多 3 秒前的旧帧，
    ///      撤帧又要等 → 观感反而是「画面顿住一下」。现在 cs 还在画就不盖。
    ///   ② 撤帧从「连续 2 拍确认（≥1 秒）」改成「**一看到 cs=2 立刻撤**」，
    ///      拍子也从 0.5 秒提到 0.2 秒 —— 恢复窗口从 ~1.2 秒压到 ~0.2 秒。
    /// V0.3.34（AevonArmEarlyV334）：过渡哨完成布防的时刻。
    ///
    /// 「场景消失事件」比过渡哨晚约 0.9 秒到达。既然哨已经布过防了，事件这一拍
    /// 就不该再布一次 —— 再布一次意味着 `reassertCount` 归零、让位期再发 1 发
    /// `updateSettings`，而每写一笔都让远程表面重建一次 = 用户看到的第二次黑。
    private var sentryArmedAt: CFTimeInterval = 0

    /// V0.3.34：布防前移 —— 从「场景消失事件」提前到「过渡哨 + delay」。
    ///
    /// Aevon(99) 实测：哨命中 08:17:58.629 → 布防 08:17:59.529，**晚 0.900 秒**，
    /// 布防那一刻 cs 已经是 0。这 0.9 秒里没有任何守卫拍在跑（常驻看门只在
    /// `guardArmedUntil == 0` 的分支里看 cs，且要连续 8 拍才判 presenter 死，
    /// 那时早过了 1.6 秒）。提前布防 = 让位期、盖帧、守卫拍全部提前 0.9 秒上场。
    ///
    /// 为什么 +0.2s 而不是同拍：哨命中时转场刚起（几何已变 2 拍），让位期只放行
    /// 1 发重申，同拍发很容易打在「系统还没开始动」的空档里；0.2s 落在转场中段。
    ///
    /// `reason` 必须含「画面离场」四个字 —— `armBackgroundGuard` 用它决定走
    /// 「让位期 1 发预算」还是「非让位三拍重申」，写成别的会自己制造三次黑。
    func armBackgroundGuardSoon(reason: String, delay: Double) {
        guard window != nil, !isTearingDown, sceneHost.hasContent else { return }
        guard guardArmedUntil == 0 else {
            AevonLog.info("[窗口] 布防前移跳过：已有布防在跑（\(reason)）（AevonArmEarlyV334）")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.window != nil, !self.isTearingDown,
                  self.guardArmedUntil == 0, self.sceneHost.hasContent else { return }
            self.sentryArmedAt = CACurrentMediaTime()
            self.armBackgroundGuard(reason: reason)
            AevonLog.info("[窗口] 布防前移：过渡哨 +"
                + String(format: "%.2f", delay)
                + "s 已布防（比「场景消失事件」早约 0.7s）（AevonArmEarlyV334）")
        }
    }

    func armBackgroundGuard(reason: String) {
        guard window != nil else { return }
        guard sceneHost.hasContent else { return }   // 还没出过首帧：交给首帧探测，别掺和
        /* V0.3.34（AevonArmEarlyV334）：过渡哨已经布过防 → 不再重来一次。
         * 旧行为：哨 +0.2s 布防一次（发 1 发「立即」），场景消失事件再布防一次
         * （reassertCount 归零、再发 1 发）—— 两发 updateSettings = 两次表面重建
         * = 用户看到的两次黑。4 秒窗口足够覆盖一次回桌面转场。 */
        if guardArmedUntil > 0, CACurrentMediaTime() - sentryArmedAt < 4.0 {
            AevonLog.info("[窗口] 布防跳过：过渡哨已布防（\(reason)）（AevonArmEarlyV334）")
            return
        }
        beginGuardWindow(reason: reason)
        // V0.2.60（AevonLiveFirstV260）：回桌面 / 切 App 走「先让位、后淡入」，
        // 不再盖定格帧（Aevon(34) #1：定格 1 秒观感比晚出现 0.3 秒差得多）。
        // V0.3.27（AevonReassertBudgetV327）：让位期总预算 1 发（见 liveWaitReassertBudget 注释）
        let isLiveWait = reason.contains("画面离场")
        liveWaitReassertBudget = isLiveWait ? 1 : -1
        liveWaitReassertSkipLogged = false
        if isLiveWait {
            beginLiveWait(reason: reason)
        } else if sceneHost.contentLooksRendering == false {
            installDarkFreeze(reason: "离场")
        }
        reassertContentForeground(tag: "立即")
        // V0.2.55（AevonDarkGuardV255，用户 Aevon(29) #3）：回桌面 1~2 秒卡顿提速。
        // Aevon(29) 日志：布防立即重申 cs 0→1，+0.9s 那拍重申后 0.36s cs 才到 2 ——
        // cs=2（真出画）卡在「等下一拍重申把场景彻底推醒」。把拍距从 0.9s 压到 0.35s，
        // 桶还是 4 次（0.1.5 的有界纪律不变：一次布防最多 4 次写入）。
        // V0.2.59（AevonGuardFastV259，用户 Aevon(33) #1「回桌面还要等 1 秒才见实时画面」）：
        // Aevon(33) 日志实测布防→撤冻结仍 0.78s，其中 cs 反复 0→1→0→1→2 —— 重申密度
        // 再收紧一档（0.25s 桶距），并配合守卫拍 0.1s（撤冻结最多晚 0.1s 检测），
        // 预期压到 ~0.5s。剩下的时间常数是系统回桌面动画本身，不再可压。
        // V0.2.62（AevonLiveQuietV262，用户 Aevon(36) #5「回桌面闪烁还在，这次是画面
        // 闪烁、频率很快」）：让位期（回桌面）只重申**一次**。
        //
        // 每一次 updateSettings 重申都会让远程表面重建一次，屏幕上就是「黑一下、
        // 再亮一下」；0.25 / 0.55 / 0.85 三发 + 立即那一发 = 让位期四发，正好凑成
        // 用户说的「频率很快的闪」。让位分支（reason 含「画面离场」）改成只留一发
        // 0.40s 的兜底重申；其它离场（切 App 等）保持原来的三拍。
        // V0.3.27（AevonReassertBudgetV327）：让位分支的 `+0.40s` 那一发**退役**。
        // Aevon(100) 三次回桌面实测：那两发之间 cs 在 0↔1 之间反复，第二发并没有让
        // 恢复更快（让位结束时刻 1.708 / 1.554 / 1.744 秒，与 0.3.26 的 1.7 秒一致），
        // 只是多黑一次。让位期现在只发「立即」这一发，其余交给守卫拍（同样受预算约束）。
        let reassertDelays: [Double] = isLiveWait ? [] : [0.25, 0.55, 0.85]
        for delay in reassertDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reassertContentForeground(tag: String(format: "+%.2fs", delay))
            }
        }
    }

    // MARK: - 回桌面「先实时、后出现」（V0.2.60，AevonLiveFirstV260）

    /// 让位开始：**不动整窗 alpha**，垫一张最后一帧等实时画面。
    ///
    /// V0.2.65（AevonNoVanishV265，用户 Aevon(38) #8「全屏 App 开浮窗回桌面时依旧会闪」）：
    /// 0.2.60~0.2.64 的做法是「整窗 alpha 打到 0.02（或 0）让位，等实时画面回来再淡入」。
    /// 观感上就是：浮窗**消失**（露出桌面）→ 0.3~1.0 秒后**又出现**。这不是"闪"是什么？
    /// 每一版都在调「让位多长 / 淡入多快」，但「窗会消失再出现」这件事本身就是闪的根源。
    ///
    /// 现在改成：窗口**从头到尾 alpha = 1，位置不动**；内容层用最后一张真画面顶住，
    /// 实时画面回来后即时交接（0.2.69 起 removeDarkFreeze 直接摘帧，无交叉淡出）。屏幕上永远有一块
    /// 连续的浮窗，没有"空窗"帧，也就不可能闪。
    /// V0.3.27（AevonKeepAliveEarlyV327）：把保活探针的起跑点提前到「回桌面过渡哨」那一拍。
    ///
    /// 0.3.26 把它放在 `beginLiveWait`，而 `beginLiveWait` 是**布防**那拍调用的 ——
    /// Aevon(100) 实测布防比过渡哨晚 0.95 秒（1.708/1.554/1.744 秒的让位窗口全同构）。
    /// 等布防才起跑，那 0.95 秒里场景早就是 cs=0，先手根本拿不到。
    /// 探针内部幂等：布防那拍再调一次直接返回 2，不会重复建断言。
    func kickKeepAliveProbeOnTransition() {
        _ = AevonKeepAliveProbeBegin(Unmanaged.passUnretained(sceneHost.scene).toOpaque())
        AevonLog.info("[保活] 过渡哨同拍起跑（抢在布防之前约 0.95s）（AevonKeepAliveEarlyV327）")
    }

    /// 过渡哨误报（控制中心半拉之类）时把探针收掉，别留一个没人释放的断言。
    func cancelKeepAliveProbe() {
        AevonKeepAliveProbeEnd()
    }

    private func beginLiveWait(reason: String) {
        let now = CACurrentMediaTime()
        /* V0.3.26（AevonKeepAliveProbeV326）：回桌面同一拍起跑场景保活探针。
         * 为什么必须在这一拍起跑、而不是等 0.9s 后的布防：Aevon(99) 实测布防比过渡哨
         * 晚 0.9 秒，那 0.9 秒里 cs 已经是 0（浮窗是黑的）。探针要把「先手」拿到手，
         * 才有机会让场景根本不掉。整个探针 fail-open，任何一步失败都不影响既有路径。 */
        _ = AevonKeepAliveProbeBegin(Unmanaged.passUnretained(sceneHost.scene).toOpaque())
        liveWaitStartedAt = now
        liveWaitDeadline = now + AevonWindowView.liveWaitLimit
        liveWaitTicks = 0
        liveAwaitingContent = false
        frameMatchTried = false   // V0.2.93（AevonFrameMatchRevealV293）每次让位重置比对额度
        guardHoldLogged = false   // V0.2.100（AevonReturnDeadlineV2100）限流日志重置
        alpha = 1
        liveSettleUntil = 0
        /* 尽量先盖住：能抓到最后一帧就盖（此时窗口还是可见的，盖上去 = 画面「停住」），
         * 抓不到就保持现状 —— 但**绝不隐藏窗口**。 */
        if darkFreezeView == nil {
            liveWaitFreezeAllowed = true
            installDarkFreeze(reason: "回桌面垫最后一帧")
            liveWaitFreezeAllowed = false
        }
        AevonLog.info("[窗口] 回桌面：窗口保持可见（整窗 alpha 不动，\(reason)）→ 用最后一帧顶住，"
            + "实时画面回来即时交接（无交叉淡出），上限 \(String(format: "%.1f", AevonWindowView.liveWaitLimit)) 秒"
            + "（AevonLiveFirstV260 AevonLiveFirstFixV261 AevonLiveQuietV262 AevonNoVanishV265"
            + " AevonReassertBudgetV327）")
    }

    /// 让位结束：只决定「定格帧撤不撤」，永远不碰窗口自身 alpha。
    private func finishLiveWait(reason: String) {
        guard liveWaitDeadline > 0 else { return }
        let held = CACurrentMediaTime() - liveWaitStartedAt
        liveWaitDeadline = 0
        liveWaitStartedAt = 0
        liveWaitTicks = 0
        let rendering = sceneHost.contentLooksRendering
        liveSettleUntil = CACurrentMediaTime() + AevonWindowView.liveSettleWindow
        if rendering == true {
            removeDarkFreeze(reason: "让位结束且实时画面已回来")
        }
        // V0.3.26（AevonKeepAliveProbeV326）：让位结束 → 释放保活断言，记本轮持有时长
        // V0.3.27（AevonReassertBudgetV327）：让位窗口关闭 → 预算解除（回到通用有界 4 次）
        liveWaitReassertBudget = -1
        AevonKeepAliveProbeEnd()
        /* rendering != true 时保留定格帧（宁可停住，也不露一块空窗）；
         * 常驻看门会在 cs=2 时撤掉它。 */
        AevonLog.info("[窗口] 回桌面让位结束（\(String(format: "%.2f", held))s，\(reason)，"
            + "画面=\(rendering == true ? "实时" : "仍定格")，窗口 alpha 全程 1）"
            + "（\(sceneHost.stateSummary())）（AevonNoVanishV265 AevonStableRevealV292）")
    }

    /// V0.2.63（AevonLiveHiddenV263）：藏着等真画面 —— 连续 2 拍在画才淡入。
    /// V0.2.88（AevonLiveInstantV288，Aevon(61)「悬浮窗的内容依旧存在由虚到实的过渡」）：
    /// **0.22s 浮现 + 0.985→1.0 缩放整段退役**。此刻实时画面已在位（cs=2 连续 2 拍），
    /// 内容已是终态 —— 过渡动画纪律（0.2.87 定档）：显形/交接发生在内容定稿之后，
    /// 任何 alpha 渐变与缩放都是负资产，用户读作「从虚到实」。瞬时 alpha=1 上屏。
    private func checkAwaitingContent() -> Bool {
        guard liveAwaitingContent else { return false }
        if sceneHost.contentLooksRendering == true {
            renderTicks += 1
            if renderTicks >= 2 {
                liveAwaitingContent = false
                liveSettleUntil = CACurrentMediaTime() + AevonWindowView.liveSettleWindow
                alpha = 1
                transform = .identity
                AevonLog.info("[窗口] 真画面到了（cs=2 连续 2 拍）→ 藏着等的那扇窗瞬时上屏，"
                    + "无淡入无缩放（\(sceneHost.stateSummary())）"
                    + "（AevonLiveHiddenV263 AevonFadeInV264 AevonLiveInstantV288）")
            }
        } else {
            renderTicks = 0
        }
        return true
    }

    private func beginGuardWindow(reason: String) {
        guardArmedUntil = CACurrentMediaTime() + 4.0
        darkTicks = 0
        renderTicks = 0
        freezeRemoveCount = 0
        reassertCount = 0
        startGuardTimerIfNeeded()
        AevonLog.info("[窗口] 回桌面守卫布防（\(reason)）：0.1 秒一拍盯 contentState，"
            + "不在画才盖最后一帧、cs=2 抓到真画面立即撤（当前 \(sceneHost.stateSummary())）"
            + "（AevonDarkGuardV247 AevonDarkGuardV249 AevonDarkGuardV250 AevonGuardFastV259）")
    }

    private func startGuardTimerIfNeeded() {
        guard guardTimer == nil else { return }
        // V0.2.59（AevonGuardFastV259）：0.2 → 0.1 秒。cs=2 达成后最多再等 0.1s
        // 就检测到并撤冻结（原来最多等 0.2s）；抓帧验证更密也更快命中第一拍。
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkBackgroundGuard()
        }
        RunLoop.main.add(timer, forMode: .common)
        guardTimer = timer
    }

    private func stopGuardTimer() {
        guardTimer?.invalidate()
        guardTimer = nil
    }

    /// 重申浮窗里这个场景的前台（有界：一次布防最多 4 次，V0.2.55 起间隔 ≥0.35 秒）。
    private func reassertContentForeground(tag: String) {
        guard guardArmedUntil > 0, window != nil else { return }
        guard reassertCount < 4 else { return }
        /* V0.3.27（AevonReassertGateV327，用户 Aevon(100) #2）：两道闸，都在**写之前**。
         *
         *   ① 让位期预算用完 → 一发都不再写（这是「闪两次」变「闪一次」的直接来源）；
         *   ② 先读 cs：**已经在画（cs=2）就不许写** —— 每次 `updateSettings` 都会让
         *      远程表面重建一次，屏幕上就是黑一下再亮一下；画面明明在，写它只是自伤。
         *  ⛔ 读不到 cs（nil / -1）时**照常写**：fail-open，不把「读不到」当「在画」。 */
        if liveWaitReassertBudget == 0 { return }
        if liveWaitReassertBudget >= 0, sceneHost.contentLooksRendering == true {
            if !liveWaitReassertSkipLogged {
                liveWaitReassertSkipLogged = true
                AevonLog.info("[窗口] 重申跳过：实时画面已在画（cs=2），写一次就是多黑一次"
                    + "（\(tag)）（AevonReassertGateV327）")
            }
            return
        }
        if liveWaitReassertBudget > 0 { liveWaitReassertBudget -= 1 }
        let now = CACurrentMediaTime()
        // V0.2.59（AevonGuardFastV259）：间隔下限 0.35 → 0.25（用户 Aevon(33) #1）。
        if reassertCount > 0, now - lastReassertAt < 0.25 { return }
        reassertCount += 1
        lastReassertAt = now
        let before = sceneHost.stateSummary()
        let ok = sceneHost.reassertForegroundForFloat()
        let after = sceneHost.stateSummary()
        AevonLog.info("[窗口] 重申浮窗场景前台（\(tag)，\(ok ? "已提交" : "失败")）"
            + "\(before) → \(after)（AevonDarkGuardV247）")

    }

    /// 每 0.2 秒一拍（V0.2.49）：布防期里盯 contentState。
    ///
    /// 三档判读，全部沿用 0.2.47 的 fail-open 纪律：
    ///   · `cs == 2`（在画）→ **立刻撤冻结**（这是 #6「黑屏 1 秒以上」的直接解）；
    ///   · `cs` 是 0/1（确实没在画）→ 确认没画面就盖最后一帧 + 有界重申；
    ///   · `cs == -1`（读不到）→ **一根手指都不动**，既不盖也不撤（绝不把「读不到」当黑）。
    private func checkBackgroundGuard() {
        guard window != nil, !isTearingDown else { return }
        // V0.2.63（AevonLiveHiddenV263）：藏着等真画面的状态优先处理（此时 alpha=0，
        // 屏幕上看不到这个窗口，任何判定都不会造成闪烁）。
        if checkAwaitingContent() { return }
        // ── V0.2.60（AevonLiveFirstV260）：让位期只做一件事 —— 等实时画面 ──────────
        // 判定口径与「撤冻结」完全一致（cs=2 且现场 drawHierarchy 抓得到真画面），
        // 区别只是收尾动作从「撤一张图」变成「整窗淡入」。
        if liveWaitDeadline > 0 {
            let now = CACurrentMediaTime()
            // V0.2.62（AevonLiveQuietV262）：让位期抓帧有界（最多 3 次）。
            // 每次 drawHierarchy 都会让窗口重绘一遍，0.1 秒一拍地抓 = 让位期反复重绘，
            // 视觉上就是「闪」。抓到 3 次还没成功就只等 cs 判定 + 到点垫帧。
            /* V0.2.65（AevonNoVanishV265）：让位期**不再做 drawHierarchy 抓帧验证** ——
             * 窗口现在是全程可见的，抓帧会强迫重绘一遍，那一下本身就是闪。
             * 判定只看场景的 contentState（cs=2 = 在画），足够了。 */
            let live = (sceneHost.contentLooksRendering == true)
            liveWaitTicks = live ? liveWaitTicks + 1 : 0
            /* V0.2.100（AevonReturnDeadlineV2100）：0.2.94 的转场静默几何采样与 0.2.97 的
             * 静默重抓整体退役 —— Aevon(77) 实锤：几何静止 ≠ 画面清晰；静默重抓从模糊
             * 表面抓回来的还是模糊帧（3~7 拍重抓多条命中，用户仍见模糊→清晰）。
             * 改为 Stheno returnDeadline 同构：盖帧挂 1.2s 固定期，期内任何路径不撤帧，
             * 到点一次撤清（活表面已清晰）。让位路径与看门/布防路径共用同一个闸。 */
            let transitionQuiet = guardReturnDeadlineOpen(now: CACurrentMediaTime())
            /* V0.2.93（AevonFrameMatchRevealV293，用户 Aevon(62)「从虚变实的淡入还在」
             * + 用户确认按 Stheno 方案 A）：Stheno 揭幕纪律 = 封面与目标内容**一致**才揭幕。
             * 0.2.92 的 2 拍稳定撤帧里，撤帧瞬间「定格→实时」的画面差异 = 用户看到的
             * 虚→实。现在 cs 回来第一拍就抓一次实时帧与冻结帧比对：一致 → 立即交接
             * （视觉零跳变，且比 2 拍更快）；不一致（视频内容在动）→ 退回 2 拍稳定
             * （行为底线 = 0.2.92，fail-open）。抓帧有界：让位期最多 1 次（0.2.65 教训
             * drawHierarchy 强迫重绘 = 闪，绝不逐拍抓）。 */
            if live, darkFreezeView != nil, !frameMatchTried, liveWaitTicks >= 1 {
                frameMatchTried = true
                var matched = false
                if let freeze = darkFreezeImage, let liveImg = captureSnapshotImage() {
                    matched = freezeMatchesLive(freeze, liveImg)
                }
                AevonLog.info("[窗口] 让位期帧比对：\(matched ? "一致" : "不一致 → 退回 2 拍稳定")"
                    + "，盖帧\(transitionQuiet ? "已过 returnDeadline" : "在 returnDeadline 保护期内")"
                    + "（AevonFrameMatchRevealV293 AevonQuietRevealV294 AevonReturnDeadlineV2100）")
                if matched {
                    if transitionQuiet {
                        finishLiveWait(reason: "实时画面与冻结帧比对一致且盖帧到期，零跳变交接"
                            + "（AevonFrameMatchRevealV293 AevonQuietRevealV294）")
                        return
                    }
                    // 比对一致但 returnDeadline 未到：压住不撤（撤了就是模糊期），只记一次日志
                    if !guardHoldLogged {
                        guardHoldLogged = true
                        AevonLog.info("[窗口] 帧比对一致但盖帧 returnDeadline 未到 → 压住撤帧"
                            + "（AevonQuietRevealV294 AevonReturnDeadlineV2100）")
                    }
                }
            }
            // V0.2.60（AevonLiveFirstV260）：要求稳定才淡入。
            // V0.2.62（AevonLiveQuietV262，Aevon(36) #5）：从「连续 2 拍」放宽成
            // 「至少 1 拍 + 让位已过 0.12 秒」。Aevon(36) 实测让位 0.43 / 0.65 秒才淡入，
            // 这么长的「窗口消失」本身就是一次闪。
            // V0.2.92（AevonStableRevealV292，Aevon(61) #3「会闪或者黑屏，然后才出现
            // 实时内容」+ 逆向对照报告 §4.3）：Stheno/ScreenCore 的揭幕纪律 =
            // **连续 N 次采样都判定内容就绪才揭幕**（防「刚出图又掉层」的出现→消失）。
            // 0.2.62 放宽的前提（窗口消失感）在 0.2.87 瞬时显形 + 冻结帧全程在盖之后
            // 已经不成立 —— 现在撤帧前画面一直是冻结帧，多等 1 拍（0.1s）无感；
            // 而撤早了 = cs 先报 2、远程表面还没真画上 → 用户看到黑一瞬。收回 2 拍。
            if liveWaitTicks >= 2, now - liveWaitStartedAt > 0.12, transitionQuiet {
                finishLiveWait(reason: "实时画面已回来（\(liveWaitTicks) 拍，盖帧已过 returnDeadline）"
                    + "（AevonQuietRevealV294 AevonReturnDeadlineV2100）")
            } else if now > liveWaitDeadline {
                finishLiveWait(reason: "上限到达")
            }
            return
        }
        // V0.2.61（AevonLiveFirstFixV261）：淡入后的稳定期 —— 系统回桌面动画还在收尾，
        // cs 会 2→0→2 抖。这段时间「掉出画」一律**不盖帧**（盖了就变成「画面 ←→ 黑」
        // 交替，正是 Aevon(35) #7 看到的闪烁）。
        // V0.2.62（AevonLiveQuietV262，Aevon(36) #5）：**也不再重申**。重申 = 重建远程
        // 表面 = 一次黑闪，稳定期内重申就是自己制造闪烁。这里完全静默，只等系统自己
        // 把画面送回来；稳定期结束后交给常驻看门处理。
        if liveSettleUntil > 0, CACurrentMediaTime() < liveSettleUntil {
            return
        }
        // ── V0.2.50（AevonDarkGuardV250）：常驻看门（没布防也在盯）───────────────
        // Aevon(25) 第 7 条：「全屏 App 时开浮窗后回桌面：悬浮窗黑屏时间依旧大于 1 秒
        // 甚至更多」。0.2.49 只在「全屏 App 画面离场」这一个事件上布防 —— 只要那一刻
        // 事件没来（App 切换、上滑手势被别的通道吃掉、从锁屏回来…），守卫就从未上场，
        // 用户看到的就是纯黑。现在改成**浮窗只要在，就 0.2 秒一拍盯着**：
        //   · 看到不在画 → 盖上最后一帧（有缓存图才盖）；
        //   · 看到回画 → 稳定 0.4 秒（2 拍）才撤（防止「cs 先报 2、表面还是空」）。
        // 布防窗口只额外多一件事：有界重申前台（最多 4 次），其它时候一次都不写场景设置。
        guard guardArmedUntil > 0 else {
            guard !isDocked else { return }
            switch sceneHost.contentLooksRendering {
            case .some(true):
                idleDarkTicks = 0
                renderTicks += 1
                // V0.2.100（AevonReturnDeadlineV2100）：撤帧过盖帧 returnDeadline 闸——
                // 回桌面转场中 cs 先报 2 时撤帧 = 露出被缩放重采样的实时宿主（Aevon(76)
                // 的模糊窗口期），deadline（1.2s）内一律保持盖帧。
                if renderTicks >= 2, guardReturnDeadlineOpen(now: CACurrentMediaTime()) {
                    removeDarkFreeze(reason: "看门：内容回来了（cs=2）")
                }
            case .some(false):
                renderTicks = 0
                idleDarkTicks += 1
                /* V0.3.24（AevonPresenterRebuildV324）：连续 8 拍（0.2s 一拍 ≈1.6s）不出画，
                 * 且这扇窗**曾经有过画面** → 判定 presenter 侧已死（重申多少次都没用），
                 * 重建一次。每窗上限 1 次（sceneHost 内部计数）。
                 * 排除让位期（窗口 alpha 极低）与首次加载（hasContent=false）。 */
                if sceneHost.hasContent, alpha > 0.5, liveWaitDeadline == 0,
                   idleDarkTicks == 8,
                   sceneHost.rebuildPresenter(reason: "看门：连续 1.6s 不出画") {
                    idleDarkTicks = 0
                    return
                }
                // V0.2.63（AevonFlashDampV263）：必须连续 3 拍不在了才盖，且刚撤过图
                // 就静默 1.2 秒 —— 盖/撤来回切就是「快速闪」。
                if darkFreezeView == nil, sceneHost.hasContent, hintLabel.isHidden,
                   idleDarkTicks >= 3,
                   CACurrentMediaTime() - lastFreezeRemovedAt > AevonWindowView.freezeQuietWindow {
                    installDarkFreeze(reason: "看门：内容掉出画")
                }
            case .none:
                idleDarkTicks = 0
                break
            }
            return
        }
        let now = CACurrentMediaTime()
        if now > guardArmedUntil {
            // 布防期结束：在画（或读不到）就撤图；确认不在画则保留冻结（宁可冻着也不黑着）
            guardArmedUntil = 0
            darkTicks = 0
            renderTicks = 0
            if sceneHost.contentLooksRendering != false {
                removeDarkFreeze(reason: "布防结束且已恢复")
            }
            return
        }
        switch sceneHost.contentLooksRendering {
        case .some(true):
            darkTicks = 0
            renderTicks += 1
            // V0.2.53（AevonDarkGuardV253，用户 Aevon(27) #5）：0.2.50 的「稳定 2 拍
            // （0.4s）才撤」防的是「cs 先报 2、表面还没画」。现在第一拍就**现场验证**：
            // drawHierarchy 抓得到真画面 = 远程表面确实在画 → 立刻撤冻结；
            // 抓不到就按老规矩等满 2 拍（抓不到 ≠ 黑，宁可持续定格也不露黑窗）。
            if renderTicks >= 2, guardReturnDeadlineOpen(now: CACurrentMediaTime()) {
                removeDarkFreeze(reason: "布防：内容已回画（cs=2 连续 2 拍）")
            } else if darkFreezeView != nil, captureSnapshotImage() != nil,
                      guardReturnDeadlineOpen(now: CACurrentMediaTime()) {
                renderTicks = 2
                removeDarkFreeze(reason: "布防：cs=2 且现场抓到真画面（第一拍验证，AevonDarkGuardV253）")
            }
        case .some(false):
            renderTicks = 0
            darkTicks += 1
            // V0.2.63（AevonFlashDampV263）：同上，布防期也要静默期防盖/撤抖动。
            // V0.2.69（AevonSnapPadV269，用户 Aevon(41) #5「进入全屏 App 时悬浮窗先
            // 黑屏一下」）：布防期 3 拍（0.3s）才盖 = 每次进全屏 App 都先看 0.3s 黑。
            // 布防的语义就是「画面离场事件已实锤」，第一拍就垫帧；静默期压到
            // 0.6s（只防 cs 抖动引发的反复盖撤，第一次盖不受静默期限制）。
            let quiet = AevonWindowView.freezeQuietWindow * 0.5
            let everCovered = freezeRemoveCount > 0
            if darkFreezeView == nil, darkTicks >= (everCovered ? 3 : 1),
               CACurrentMediaTime() - lastFreezeRemovedAt > quiet {
                installDarkFreeze(reason: "巡查发现不出画（布防期第一拍即垫）")
            }
            reassertContentForeground(tag: "发现不出画")
            /* V0.2.85（AevonIdleRewakeV285，Aevon(58)「浮窗开启期间切换全屏应用时，
             * 浮窗内画面会定格，并且不会自动恢复，只能关掉浮窗再打开」）：
             *
             * 定格不是「画面不刷新」这么简单 —— 是**我们主动放弃了恢复**。
             * `reassertContentForeground` 头两条 guard 就决定了上限：
             *   `guard guardArmedUntil > 0` / `guard reassertCount < 4`
             * 布防期只有 4 秒、最多 4 次重申；4 秒后 `guardArmedUntil` 归零，
             * 常驻看门的重在这里**一次都发不出去**（第一条 guard 直接 return）。
             * 而浮窗场景被别的全屏 App 压在后台时，系统**永远**不会自己把它拉回来 ——
             * 于是「盖一张最后一帧 + 再也没人叫醒」= 用户看到的定格。
             *
             * 修法：不取消布防，改成**低频自愈** —— 内容连续掉出画时，每 3 秒重新
             * 布防 0.9 秒、放行 1 次重申。代价是每个 3 秒窗口最多 1 次场景设置写入
             *（全屏 App 在前台时这次重申本来也无效，但它是我们唯一能做的动作，
             * 而切回浮窗 App 的那一刻它正好能把画面叫回来）。 */
            let nowR = CACurrentMediaTime()
            if nowR - lastIdleRewakeAt > 3.0 {
                let gap = lastIdleRewakeStartedAt > 0 ? nowR - lastIdleRewakeStartedAt : 0
                lastIdleRewakeAt = nowR
                lastIdleRewakeStartedAt = nowR
                idleRewakeCount += 1
                guardArmedUntil = nowR + 0.9
                reassertCount = 3            // 只放行 1 次（闸门是 < 4）
                lastReassertAt = 0
                AevonLog.info("[窗口] 定格自愈：内容连续掉出画 → 重新布防并重申一次"
                    + "（第 \(idleRewakeCount) 次，距上次 " + String(format: "%.1f", gap) + "s）"
                    + "（AevonIdleRewakeV285）")
                reassertContentForeground(tag: "定格自愈")
            }
        case .none:
            break
        }
    }

    /// 盖上最后一帧（缓存快照；没有可用快照就不盖 —— 盖一张纯色图没有意义）。
    ///
    /// V0.2.49（AevonDarkGuardV249）：**加一条「这张图是画面还是空壳」的校验**。
    /// `layer.render(in:)` 抓不到跨进程远程表面（0.2.26 已记录），抓到的往往只是
    /// contentClip 的深灰底色 —— 铺上去就是一块纯色，用户看到的就是「黑屏」。
    /// 现在只接受「有明显明暗差异」的图（见 `imageLooksLikeContent`），
    /// 空壳一律不盖：宁可让真实画面自己回来，也不盖一张假的。
    private func installDarkFreeze(reason: String) {
        /* V0.3.25（AevonNoFreezeV325）：**B3 —— 回桌面完全不盖帧，完全按 Stheno。**
         *
         * Stheno 的 SCFloatingContainerView 从不抓实时截图盖帧：它只有冷启动期的
         * `SCStartupCoverView`（UIImageView + 启动图/最后一张显示图），内容就绪判据
         * `sc_hostedContentIsReadyInHostView:`（layer 子树里有 CALayerHost、宽高 >1pt、
         * KVC `contextId` 非 0、KVC `hasBeenCommitted` == YES）连续 2 拍成立才
         * `sc_revealHostedContentForHostView:` 一次性揭示；之后回桌面也不盖任何东西。
         *
         * 我们 0.2.47 起那一整套「定格帧」是给黑屏兜底的，但它同时是
         * 「先模糊 → 再变清晰」的唯一来源：盖上去的是一张缓存帧（可能低清 / 空白，
         * Aevon(98) 日志 20:41:32 实测 `可信首帧已建立（清晰度 1）`），0.9s 保护期后
         * 撤帧露出实时画面 —— 用户读到的就是「糊一下再清」。
         * 用户 0.3.24 后定档 B3：整条停用。不抓帧、不盖帧、不压帧。
         * 代价（已告知）：回桌面那 0.3~0.5s 浮窗里没有画面。 */
        if AevonWindowView.freezeDisabled {
            if AevonWindowView.freezeSkipLogCount < 3 {
                AevonWindowView.freezeSkipLogCount += 1
                AevonLog.info("[窗口] 盖帧已停用（B3：完全按 Stheno，不盖定格帧）→ 跳过（\(reason)）"
                    + "（AevonNoFreezeV325）")
            }
            return
        }
        guard darkFreezeView == nil, hintLabel.isHidden, !isTearingDown else { return }
        // V0.2.100（AevonReturnDeadlineV2100，用户确认方案 F，Stheno SCWSNativeFullRequest
        // .returnDeadline 同构）：盖帧起挂 1.2s 固定撤帧保护期 —— 期内任何撤帧路径一律
        // 压住（零几何判定），到点一次撤清。回桌面转场实测 0.8~1.2s，保护期覆盖全程。
        let armedAt = CACurrentMediaTime()
        /* V0.3.1（AevonSharpGateV301）：0.9s 最短保护期 + 2.6s 清晰度采样上限。
         * 0.2.100 的 1.2s 固定 deadline 只解决"盖了又早撤"，解决不了"撤了以后还模糊"
         * —— 模糊在撤帧之后（App 正在重排 / 系统低清场景快照），撤帧判据必须看画面。 */
        freezeReturnDeadline = armedAt + 0.9
        freezeSharpnessDeadline = armedAt + 2.6
        freezeBaseSharpness = 0
        lastSharpSampleAt = 0
        sharpSampleCount = 0
        sharpHoldLogged = false
        sharpOpenLogged = false
        guardHoldLogged = false
        // V0.2.60（AevonLiveFirstV260）：让位期整窗是隐形的，再盖一张定格帧纯属浪费
        //（还会在淡入那一刻露出旧画面）。让位收尾时会自己决定要不要垫缓存帧。
        //
        // V0.2.65（AevonNoVanishV265）：让位期窗口不再隐形了 —— 现在正是**要在让位期
        // 盖一张最后一帧顶住**（否则那一秒就是一块空窗）。所以只在「让位期且不是
        // 让位自己要求盖」时才拒绝。
        guard liveWaitDeadline == 0 || liveWaitFreezeAllowed else { return }
        let bounds = contentClip.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        /* V0.2.98（AevonCacheFreezeV298，用户 Aevon(75)「能否直接取消模糊状态，我记得
         * stheno 中没有模糊这一步」+ 用户确认方案 S-B）：**盖帧优先垫滚动缓存帧**。
         * Stheno 逆向实锤（round15/16/17 三份事故档案）：它的垫底快照 = 健康拍每 ≥2s
         * 刷新的缓存帧，**从不现场抓帧**——所以它没有模糊这一步。0.2.97 的静默重抓
         * 已把模糊期压到动画本身时长，但盖帧那一下（过渡哨命中瞬间）抓的现场帧仍是
         * 转场重采样的模糊帧。修法：优先垫 cachedSnapshotImage（空闲预抓的清晰帧，
         * 内容=浮窗显示画面，最多旧 0.6~3s），现场抓帧仅在缓存不可用时兜底；
         * 0.2.97 的静默重抓保留——静默后立刻换成最新清晰帧，旧画面最多显示 ~0.4s。
         * 同时修掉一个污染漏洞：原 lastContentFrame() 现场抓帧成功会把模糊帧写进
         * cachedSnapshotImage（滚缓存被污染 → 后续垫帧全模糊）。 */
        let padSource: String
        var resolvedImage: UIImage?
        /* V0.3.24（AevonSharpCacheGateV324）：盖帧选图也过清晰度闸。
         * 缓存在多数情况下已是清晰帧；若它本身不够清晰（历史遗留/内容变了），
         * 退到最近一张通过校验的清晰帧，再不行才现场抓。
         * 这一层保证「盖上去那张图」不会是模糊的 —— 用户报的「定格模糊」正是它。 */
        if let cached = cachedSnapshotImage, snapshotIsSharp(cached) {
            resolvedImage = cached
            padSource = "缓存帧"
        } else if let sharp = lastSharpSnapshotImage {
            resolvedImage = sharp
            padSource = "可信帧"
        } else {
            resolvedImage = lastContentFrame(refreshCache: false)
            padSource = "现场帧"
        }
        guard let image = resolvedImage else {
            AevonLog.warn("[窗口] 内容不出画但没有可用快照 → 无法冻结（只能等重申生效，\(reason)）"
                + "（\(sceneHost.stateSummary())）（AevonDarkGuardV247 AevonDarkGuardV249 AevonCacheFreezeV298）")
            return
        }
        // V0.3.1（AevonSharpGateV301）：记下盖帧图自身的清晰度基准 —— 后面每一次采样
        // 都拿活画面与它比，够接近才算"真实渲染已到位"，准撤。
        freezeBaseSharpness = sharpnessScore(image)
        // V0.3.24（AevonSharpCacheGateV324）：这张图是否够清晰，决定撤帧门槛取哪条式子
        freezeBaseTrusted = sharpBaseline < 1.0 || freezeBaseSharpness >= sharpBaseline * 0.85
        let view = UIImageView(image: image)
        view.contentMode = .scaleToFill
        view.layer.cornerRadius = AevonWindowView.cornerRadius(for: bounds.width)
        view.layer.masksToBounds = true
        /* V0.2.90（AevonRootFreezeV290，用户 Aevon(63) 视频实锤「回桌面时悬浮窗整体
         * 消失约 1 秒再弹回 = 由虚到实」）：冻结帧升级为窗口根级覆盖 —— 视频逐帧取证
         * 回桌面动画中面板跟着 App 卡片一起缩放（内容呈现视图物理上在切换器的缩放
         * 层级里），窗体内盖帧会跟着消失 ~1s 再弹回；窗口根级能存活整段动画。
         * V0.3.0（AevonFreezeIndepWinV300，用户 Aevon(78) #2「依旧模糊→清晰」+ 确认
         * 只做方案三）：**盖帧统一挂 AevonEntryWindow（独立窗口）**。0.2.100 的
         * returnDeadline 闸把「撤早了」堵住了，但盖帧仍跟着宿主窗口搬家：浮窗态挂
         * AevonEntryWindow、全屏态挂 SBMainSwitcherWindow —— 后者在转场缩放层级里，
         * 冻结帧自身也会被系统重采样（模糊来源之二）。Stheno 无模糊段的完整结构优势
         * = 独立窗口系统动画动不了它：现在盖帧一律挂入口窗（层级 10000000 恒在最上、
         * 不在任何转场层级里），坐标跨窗换算（UIKit convert 走屏幕坐标，同屏两窗成立）。
         * 入口窗不在（极端时序）才回退旧宿主窗口路径。 */
        if let indep = AevonEntryHost.freezeWindow, indep.window != nil {
            view.frame = convert(contentClip.frame, to: indep)
            indep.addSubview(view)
        } else if let win = window {
            view.frame = convert(contentClip.frame, to: win)
            win.addSubview(view)
        } else {
            view.frame = contentClip.frame
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        /* V0.2.87（AevonFreezePassthruV287，Aevon(60)「点不动问题还在」）：**冻结帧不再挡触摸**。
         *
         * 0.2.49 起冻结帧收触摸（tap = 手动重申），但 Aevon(60) 实锤切换应用后冻结期
         * 0.69s 里用户点浮窗 = 点在冻结帧上 = 点不动；而手动重申这件事 0.2.85 的
         * IdleRewake 已经自动兜底（每 3 秒放行一次重申，画面死了最多 3 秒自动救），
         * 「点一下救活」失去存在价值 —— 让它挡着实时内容的触摸纯亏。
         * 改成不参与事件：触摸穿透到下面的 contentClip（实时恢复的瞬间就能点）。 */
        view.isUserInteractionEnabled = false
        darkFreezeView = view
        darkFreezeImage = image   // V0.2.93（AevonFrameMatchRevealV293）留存供让位期比对
        AevonLog.warn("[窗口] 内容不出画 → 盖上最后一帧（\(reason)，\(padSource)不挡触摸，重申由看门自动兜底；"
            + "根级覆盖 \(Int(view.frame.width))x\(Int(view.frame.height))，"
            + "帧 \(Int(image.size.width))x\(Int(image.size.height))，父层=\(view.superview.map { String(describing: type(of: $0)) } ?? "无")，"
            + "returnDeadline 1.2s 内不撤帧）"
            + "（\(sceneHost.stateSummary())）（AevonDarkGuardV247 AevonDarkGuardV249"
            + " AevonFreezePassthruV287 AevonRootFreezeV290 AevonCacheFreezeV298"
            + " AevonQuietRefreezeV297 AevonReturnDeadlineV2100 AevonFreezeIndepWinV300"
            + " AevonFreezeBackV334）")
    }

    /// V0.2.91（AevonHomeFreezeV291）：回桌面过渡哨命中的**无条件**冻结入口。
    ///
    /// 与布防链（armBackgroundGuard → beginLiveWait）的区别：布防在场景消失时才来
    /// （缩放动画已跑完），过渡哨在动画第一帧就到 —— 这里绕过「让位期判断」直接
    /// 放行垫帧（liveWaitFreezeAllowed 短暂置真），挂载方式与 AevonRootFreezeV290
    /// 相同（窗口根级，与把手同层）。快照取不到时 fail-open（只跳过，不重试）。
    /// 后续布防链到达时 darkFreezeView 已在位，幂等不重装；cs=2 后照旧即时交接。
    func installTransitionFreeze(reason: String) {
        guard window != nil, !isTearingDown, darkFreezeView == nil else {
            AevonLog.info("[窗口] 过渡哨冻结未装（窗不在/销毁中/已有冻结）（AevonHomeFreezeV291）")
            return
        }
        AevonLog.info("[窗口] 过渡哨冻结入口放行：\(reason)（AevonHomeFreezeV291）")
        liveWaitFreezeAllowed = true
        installDarkFreeze(reason: reason)
        liveWaitFreezeAllowed = false
    }

    private func removeDarkFreeze(reason: String) {
        guard let view = darkFreezeView else { return }
        darkFreezeView = nil
        darkFreezeImage = nil   // V0.2.93（AevonFrameMatchRevealV293）比对基准随帧清
        freezeReturnDeadline = 0   // V0.2.100（AevonReturnDeadlineV2100）撤帧时钟随帧清，防旧期限残留
        freezeSharpnessDeadline = 0   // V0.3.1（AevonSharpGateV301）采样上限随帧清
        freezeBaseSharpness = 0
        freezeBaseTrusted = true      // V0.3.24（AevonSharpCacheGateV324）：可信标记随帧复位
        freezeRemoveCount += 1
        // V0.2.63（AevonFlashDampV263）：记下撤帧时刻，1.2 秒内不再盖（防「盖/撤」抖动）。
        lastFreezeRemovedAt = CACurrentMediaTime()
        idleDarkTicks = 0
        darkTicks = 0
        /* V0.2.65（AevonFreezeCrossFadeV265）/ 0.2.66（AevonFreezeSoftV266）：
         * 交叉溶解 0.35s —— Aevon(41) #4 实锤观感「先显示快照，然后快照变为实时画面，
         * 看着不舒服」：溶解期里新旧两帧叠着，用户看到的就是「快照糊着实时」。
         * V0.2.69（AevonSnapPadV269，对齐 Stheno/MultiFloat 事故 20 的快照垫底方案）：
         * 撤帧只发生在「cs=2 且现场抓到真画面」之后 —— 此刻实时帧已经在位，
         * 直接摘掉垫帧 = 快照与实时的交接近似同帧完成，无溶解糊感。 */
        view.removeFromSuperview()
        AevonLog.info("[窗口] 撤掉最后一帧冻结（\(reason)，第 \(freezeRemoveCount) 次，即时交接）"
            + "（\(sceneHost.stateSummary())）（AevonDarkGuardV247 AevonDarkGuardV249 AevonFlashDampV263"
            + " AevonFreezeCrossFadeV265 AevonFreezeSoftV266 AevonSnapPadV269）")
    }

    /// 点冻结图：用户主动要画面。
    /// V0.2.87（AevonFreezePassthruV287）：手动重申由 IdleRewake 自动兜底（每 3 秒放行
    /// 1 次重申），冻结帧退役「点一下手动重申」，本函数随之删除（无调用者 = 整体消除）。

    /// 滚动刷新最后一帧（默认每 3 秒一次，只在空闲且画面正常时）：
    /// 冻结层要「离黑屏最近的那一帧」，而不是开窗那一帧。顺手把缩放快照也保温。
    ///
    /// 抓不到就退避：远程表面抓取可能恒为透明（0.2.26 已记录的兜底路径），
    /// 连续 3 次失败说明这台设备上抓不出快照 → 间隔放到 30 秒，别白烧 CPU。
    private func refreshRollingSnapshot() {
        // V0.3.25（AevonNoFreezeV325）：B3 不盖帧 ⇒ 滚动刷新没有消费方
        guard !AevonWindowView.freezeDisabled else { return }
        let now = CACurrentMediaTime()
        let interval: TimeInterval = snapshotMissStreak >= 3 ? 30.0 : 3.0
        guard now - lastSnapshotRefreshAt >= interval else { return }
        guard window != nil, hintLabel.isHidden, darkFreezeView == nil else { return }
        guard !isLiveResizing, !isBarHoldMoving, transform.isIdentity else { return }
        guard sceneHost.contentLooksRendering != false else { return }
        lastSnapshotRefreshAt = now
        guard let fresh = captureSnapshotImage() else {
            snapshotMissStreak += 1
            return
        }
        snapshotMissStreak = 0
        admitSnapshot(fresh, tag: "滚动刷新")
    }

    // MARK: - 顶层置顶

    /// 把窗口提到最前（面板里的「已开窗口」点名称时用）。
    func bringToFront() {
        guard let superview = superview else { return }
        superview.bringSubviewToFront(self)
    }

    // MARK: - 窗口几何记忆（V0.0.37，AevonMedusaFrameV37）

    /// Stheno 方案：全局一份几何记忆（对应其 medusaFrameLast / _leftPecentLast 体系），
    /// 存屏幕百分比（left / top / width），换机型 / 旋转后依然成立。
    /// 所有浮窗共享 —— 下一个开的窗就是上一个关的窗的位置与大小。
    private static func rememberedFrame(fallback: CGRect) -> CGRect {
        guard let store = UserDefaults(suiteName: prefsSuite) else { return fallback }
        migrateFrameMemoryIfNeeded(store)
        fixContentPrefsIfNeeded(store)
        guard let raw = store.array(forKey: frameMemoryKey) as? [Double],
              raw.count >= 3 else { return fallback }

        let screen = UIScreen.main.bounds
        let aspect = contentAspectCurrent
        let width = max(minContentWidth, min(screen.width * CGFloat(raw[2]) / 100.0, screen.width))
        let height = width / aspect
        let x = screen.width * CGFloat(raw[0]) / 100.0
        let y = screen.height * CGFloat(raw[1]) / 100.0
        // V0.2.48（AevonCanvasFixedV248）：恢复时也完整夹进屏幕 ——
        // 旧版本可能存下过「只露 60pt」的位置（x 86% / y 92%），
        // 那正是 Aevon(23) 说的「有时自动跑到右下角」。夹一次就永久根治。
        return clampedToScreen(CGRect(x: x, y: y, width: width, height: height))
    }

    /// V0.2.45（AevonRatio58V245）：几何记忆一次性迁移。
    ///
    /// 0.2.44 及之前存下来的宽度百分比是按 5:3（0.62 屏宽起步）或屏幕比例档记的，
    /// 换成 5:8 + 0.80 屏宽后如果不迁移，老用户永远停在 319×510，看不到参考视频的
    /// 那个尺寸（也就看不到抖音右侧栏回来的效果）。迁移策略：**只改宽与横向居中，
    /// 纵向落点保留**（用户熟悉的位置不动），并写标记键只做一次。
    private static var ratio58Migrated: Bool?
    private static func migrateFrameMemoryIfNeeded(_ store: UserDefaults) {
        if let done = ratio58Migrated, done { return }
        if store.bool(forKey: "AevonRatio58Migrated") {
            ratio58Migrated = true
            return
        }
        let old = (store.array(forKey: frameMemoryKey) as? [Double]) ?? []
        // 0.80 屏宽 + 水平居中；纵向沿用旧值（没有旧值就用默认 10%）
        let top = old.count >= 3 ? old[1] : 10.0
        let migrated: [Double] = [10.0, top, 80.0]
        store.set(migrated, forKey: frameMemoryKey)
        store.set(true, forKey: "AevonRatio58Migrated")
        store.synchronize()
        ratio58Migrated = true
        AevonLog.info("[窗口] 几何记忆迁移到 5:8 默认尺寸：宽 80% 屏宽（\(String(format: "%.0f", top))% 顶边）"
            + "（AevonRatio58V245）")
    }

    /// V0.2.46（AevonCanvasScaleV246）→ V0.2.47（AevonPrefsFixedV247）：内容偏好一次性定档。
    ///
    /// 沿革：
    ///   · 0.2.45 迁移**显式写过** `ContentCanvasScale = 1.00`（当时定档）与
    ///     `ContentScreenAspect = false`；0.2.46 只把「旧值 ≤ 1.05」改成 1.30，
    ///     用户自己拉过的档（1.20 / 1.58）保留。
    ///   · 0.2.47 起设置页两个单元都删了 —— 用户已经没有途径再调，留着旧键只会让
    ///     升级后的画布/比例与「默认状态」不一致（Aevon(22) 明确要求「改为默认状态」）。
    ///     所以这里**无条件**回写定档值：倍数 = 1.30、内容比例 = 真重排档（false），
    ///     并立新标记 `AevonPrefsFixedV247` 只跑一次。
    ///     程序内部已不再读这两个键（canvasScale / usesScreenAspect 均为常量），
    ///     回写只是为了「回退到旧版本时不被陈旧值带跑」，纯卫生动作。
    private static var contentPrefsFixed: Bool?
    private static func fixContentPrefsIfNeeded(_ store: UserDefaults) {
        if let done = contentPrefsFixed, done { return }
        if store.bool(forKey: "AevonPrefsFixedV247") {
            contentPrefsFixed = true
            return
        }
        let oldScale = (store.object(forKey: "ContentCanvasScale") as? Double) ?? 0
        let oldAspect = (store.object(forKey: "ContentScreenAspect") as? Bool) ?? false
        store.set(Double(canvasScaleDefault), forKey: "ContentCanvasScale")
        store.set(false, forKey: "ContentScreenAspect")
        store.set(true, forKey: "AevonPrefsFixedV247")
        store.synchronize()
        contentPrefsFixed = true
        let scaleText = oldScale > 0 ? String(format: "%.2f", oldScale) : "无"
        AevonLog.info("[窗口] 内容偏好定档：画布倍数 \(scaleText) → \(String(format: "%.2f", canvasScaleDefault))"
            + "，内容比例 \(oldAspect ? "跟随屏幕" : "真重排") → 真重排（设置页两项已移除）"
            + "（AevonPrefsFixedV247）")
    }

    // MARK: - 浮窗存在期间禁止空闲锁屏（V0.2.48，AevonNoAutoLockV248）

    /// 原始 `isIdleTimerDisabled`（nil = 当前没在守）。
    private static var idleTimerSaved: Bool?

    /// Aevon(23)：「用浮窗播放抖音视频时，手机会根据系统的锁屏时间来暗屏和锁屏」。
    ///
    /// 浮窗里放视频时用户的手不碰屏幕（否则系统会重置空闲计时），于是系统照常
    /// 按「自动锁定」暗屏 → 锁屏 → 视频停。这里在浮窗存在期间把空闲锁屏关掉，
    /// 关窗时**还原成原值**（不假设用户设置里自动锁定是开还是关）。
    ///
    /// 为什么不用 `UIApplication.shared`：那是非可选属性，SpringBoard 里万一
    /// `sharedApplication` 返回 nil 就是**必崩**（SB 崩 = 注销）。改为
    /// 运行时取类 + `responds(to:)` 先验 + KVC 读写 —— KVC 会自动按属性类型装箱，
    /// 不会出现 `perform(_:with:)` 把 BOOL 当对象指针传（那样 `false` 会变成 YES）的坑。
    static func beginNoAutoLock() {
        guard idleTimerSaved == nil else { return }
        var saved = false
        var applied = false
        let exception = AevonShieldRun {
            guard let app = AevonRuntime.sendClass("UIApplication", Selector(("sharedApplication"))) as? NSObject,
                  app.responds(to: Selector(("setIdleTimerDisabled:")))
            else { return }
            saved = (app.value(forKey: "idleTimerDisabled") as? Bool) ?? false
            app.setValue(true, forKey: "idleTimerDisabled")
            applied = true
        }
        guard exception == nil, applied else {
            AevonLog.warn("[窗口] 禁用空闲锁屏失败（取不到 UIApplication / 键不存在，异常已拦，继续运行）"
                + "（AevonNoAutoLockV248）")
            return
        }
        idleTimerSaved = saved
        AevonLog.info("[窗口] 浮窗期间禁用空闲锁屏（原值 \(saved ? "已禁用" : "未禁用") → 禁用）"
            + "（AevonNoAutoLockV248）")
    }

    /// V0.2.49（AevonNoAutoLockV249）：**真正压住熄屏的那一下**。
    ///
    /// Aevon(24)：「悬浮窗打开期间，依旧会跟随系统时间暗屏锁屏」。
    /// 0.2.48 只写了 `UIApplication.isIdleTimerDisabled` —— 在 SpringBoard 进程里
    /// 这一笔不进 SpringBoard 自己的空闲计时器（归 `SBIdleTimerGlobalCoordinator`），
    /// 所以日志写着「已禁用」、屏幕照样按时暗。
    /// 这里每 20 秒调一次垫片 `AevonIdleTimerKick`：调 SpringBoard 全局协调器的
    /// `resetIdleTimer`（= 告诉系统「用户又动了」，空闲计时重新起表），
    /// 垫片内部同时兜底重写一次 `isIdleTimerDisabled`。
    ///
    /// 频率是刻意的：20 秒 ≪ 系统最短的「自动锁定 30 秒」，又不会每秒烧一次私有 API。
    static func kickIdleTimerIfNeeded() -> NSInteger {
        let mask = AevonIdleTimerKick()
        return mask
    }

    static func endNoAutoLock() {
        guard let saved = idleTimerSaved else { return }
        idleTimerSaved = nil
        let exception = AevonShieldRun {
            guard let app = AevonRuntime.sendClass("UIApplication", Selector(("sharedApplication"))) as? NSObject,
                  app.responds(to: Selector(("setIdleTimerDisabled:")))
            else { return }
            app.setValue(saved, forKey: "idleTimerDisabled")
        }
        // V0.2.69（AevonIdleRelV269，用户 Aevon(41) #7）：0.2.50 起 kick 里
        // acquireIdleTimerDisableAssertionForReason: 只取不放 —— 浮窗关闭后断言
        // 还持有，SpringBoard 空闲计时器仍被禁 = 手机不按设置自动暗屏锁屏。
        // 这里把断言释放掉（release 内部同时把 isIdleTimerDisabled 写回 NO）。
        // 注意不能再调 kickIdleTimerIfNeeded —— kick 会把断言重新 acquire 回来。
        let released = AevonIdleTimerRelease()
        if exception != nil {
            AevonLog.warn("[窗口] 浮窗已关，空闲锁屏还原异常但断言已释放 mask=\(released)"
                + "（AevonIdleRelV269）")
            return
        }
        AevonLog.info("[窗口] 浮窗已关，空闲锁屏还原为原值（\(saved ? "禁用" : "启用")）"
            + "，熄屏断言已释放 mask=\(released)（AevonNoAutoLockV248 AevonIdleRelV269）")
    }

    // MARK: - 停靠态（V0.2.50，AevonDockColumnV250）

    /// 当前是否在停靠列里（吸附小窗）。
    private(set) var isDocked = false
    /// 停靠在左列还是右列
    /* V0.2.71（AevonDockSideFirstV271）：setter 开放到模块内。
     * 事故：停靠入口先 relayoutDock、enterDock 后才写 dockedSide —— relayoutDock
     * 按旧值过滤，刚停靠的窗永远不在「目标侧」列里（Aevon(43)「该侧现有 0 个」实锤）：
     * 左列过滤为空 = 窗没吸附；装回路径 relayoutDock(.right) 又把它按旧值扫进右列 =
     * 「一下出现两个吸附小窗」。修法 = 停靠前先钉死 dockedSide。 */
    var dockedSide: AevonDockSide = .right
    /// V0.2.50：这个窗承载的是自建场景吗（关窗收尾补写整屏画布时要排除 —— 自建场景已被销毁）
    var usesSelfScene: Bool { return sceneHost.isSelfBuilt }

    /// 主窗还原时的目标几何（全局记忆 → 夹屏）。
    static func mainFrameForRestore() -> CGRect {
        let restored = rememberedFrame(fallback: defaultFrame())
        return clampedToScreen(restored)
    }

    /// 进入停靠：变成边缘那一格的小窗。
    ///
    /// 三件事必须同时发生，否则「小窗」会名不副实：
    ///   ① 几何切到槽位（动画，0.22s）→ 圆角 / 光晕 / 画布缩放全部跟着走；
    ///   ② **内容不再接收触摸** —— 停靠窗只是一个「活缩略图」，点它的语义是「装回主窗」，
    ///      绝不能把这次点击转发进 App（历史上正是这条把抖音点跑了）；
    ///   ③ 不落盘几何（`persistFrame` 里拦掉）—— 停靠坐标不是用户想要的「主窗位置」。
    func enterDock(side: AevonDockSide, index: Int, animated: Bool) {
        let target = AevonDock.frame(side: side, index: index)
        guard !isDocked || frame != target else {
            isDocked = true
            dockedSide = side
            return
        }
        isDocked = true
        dockedSide = side
        sceneHost.setContentInteraction(false)
        // V0.2.60（AevonDockTapOnlyV260，用户 Aevon(34) #2）：停靠小窗**四周边条手柄整建制摘除**。
        // Aevon(34)：「移除停靠吸附小窗四周的手势，只保留点击小窗还原的手势」。
        // 92x158 的小窗上，四条边条 + 两个角块把面积吃掉大半，点哪儿基本都落在手柄上
        //（手柄只有 pan，轻点既不还原也不停靠）—— 用户体感就是「点小窗没反应」。
        // 停靠态唯一语义 = 点任意位置装回，手柄留着只会抢命中。
        setDockHandlesEnabled(false)
        // V0.2.61（AevonDockTapFixV261）：手柄摘除后补一层真实命中控件 —— 停靠态
        // 「点任意位置 = 装回」从此有一条不依赖命中判定的硬通道。
        installDockTapCatcher()
        // V0.2.59（AevonDockHaloOffV259，用户 Aevon(33) #4「主窗变小窗的过渡中光晕闪过」）：
        // 窗口本体走 0.22s 动画（presentation 层逐帧插值），而光晕 apply 里禁了隐式动画
        // —— 它在动画**开始那一帧**就立刻缩到小窗尺寸。大窗还在、光晕先没了，
        // 小窗位置又瞬间出现一小圈 = 视觉上「闪过」。停靠小窗本来就不需要光晕
        // （还省一份每帧离屏模糊），过渡开始就整圈隐藏，装回主窗时再恢复。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowRing.isHidden = true
        CATransaction.commit()
        let apply = { [weak self] in
            guard let self else { return }
            self.frame = target
            self.layoutIfNeeded()
        }
        if animated, window != nil {
            UIView.animate(withDuration: 0.22, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction],
                           animations: apply, completion: nil)
        } else {
            apply()
        }
        AevonLog.info("[停靠] \(bundleID) 已吸附到屏幕\(side.title)侧第 \(index + 1) 格"
            + "（\(Int(target.width))x\(Int(target.height))，顶部起向下排列，最多 \(AevonDock.maxCount) 格，"
            + "过渡期光晕隐藏）（AevonDockColumnV250 AevonDockHaloOffV259）")
    }

    /// V0.2.64（AevonMainAvoidV264，用户 Aevon(38) #2）：主窗避让停靠栏时的平滑位移。
    ///
    /// 只动 frame（不动 transform / 不重建 presenter），落盘走 `persistFrame` ——
    /// 避让后的位置就是新的「主窗记忆」，用户随后再手动拖动会覆盖它。
    func nudgeForDockAvoidance(to target: CGRect) {
        guard !isDocked else { return }
        let apply = { [weak self] in
            guard let self else { return }
            self.frame = target
            self.layoutIfNeeded()
        }
        if window != nil {
            UIView.animate(withDuration: 0.30, delay: 0,
                           usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0.2,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: apply,
                           completion: { [weak self] _ in self?.persistFrame() })
        } else {
            apply()
            persistFrame()
        }
    }

    /// V0.2.60（AevonDockTapOnlyV260）：停靠态摘除 / 装回后恢复窗外手势手柄。
    ///
    /// 摘除用 `isHidden + isUserInteractionEnabled` 两道：隐藏负责视觉与命中，
    /// 关交互负责识别器彻底不接事件（隐藏视图本身就不再参与 hitTest，双保险）。
    private func setDockHandlesEnabled(_ enabled: Bool) {
        for case let handle as AevonEdgeHandleView in subviews {
            handle.isHidden = !enabled
            handle.isUserInteractionEnabled = enabled
        }
    }

    // MARK: - 停靠「点一下装回」命中层（V0.2.61，AevonDockTapFixV261）

    /// 停靠小窗上铺一层**真实控件**（UIControl），只负责一件事：轻点 = 装回主窗。
    ///
    /// 为什么 0.2.60 的「点小窗没反应」会复发（Aevon(35) #6）：
    /// 0.2.60 把四周边条手柄整建制摘除之后，`grab(at:)`（全局通道认领浮窗的唯一入口）
    /// 只看手柄 frame —— 手柄没了，它对这个窗口恒返回 nil，全局通道于是**根本不知道
    /// 这一下点在小窗上**；而窗口自带的 `UITapGestureRecognizer` 在这种「内容层关交互
    /// + 无任何可交互子视图」的窗口上并不可靠（真机日志里 0.2.60 之后再没打出过
    /// 一次 AevonDockTapAnywhereV255）。铺一层 UIControl 把「命中归属」钉死在
    /// 我们自己手里 —— hitTest 必然返回它，`touchUpInside` 必然到。
    private var dockTapCatcher: UIControl?

    private func installDockTapCatcher() {
        if let existing = dockTapCatcher {
            existing.frame = bounds
            bringSubviewToFront(existing)
            return
        }
        let catcher = UIControl(frame: bounds)
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.backgroundColor = .clear
        catcher.isUserInteractionEnabled = true
        catcher.isMultipleTouchEnabled = false
        catcher.addTarget(self, action: #selector(handleDockCatcherTap(_:)),
                          for: .touchUpInside)
        addSubview(catcher)
        bringSubviewToFront(catcher)
        dockTapCatcher = catcher
        AevonLog.info("[停靠] 已铺「点一下装回」命中层（\(Int(bounds.width))x\(Int(bounds.height))，"
            + "真实控件，不依赖手柄也不依赖全局通道）（AevonDockTapFixV261）")
    }

    private func removeDockTapCatcher() {
        guard let catcher = dockTapCatcher else { return }
        catcher.removeFromSuperview()
        dockTapCatcher = nil
    }

    @objc private func handleDockCatcherTap(_ sender: UIControl) {
        guard isDocked else { return }
        AevonLog.info("[停靠] 小窗轻点（命中层）→ 装回主窗（AevonDockTapFixV261）")
        AevonWindowManager.restoreDocked(bundleID: bundleID)
    }

    /// V0.2.55（AevonDockTapAnywhereV255，用户 Aevon(29) #2）：停靠小窗任意位置
    /// 轻点 = 装回主窗（这是 dock 态唯一的手势语义；点边条与点内容等价，同为装回）。
    @objc private func handleDockTapAnywhere(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, isDocked else { return }
        AevonLog.info("[停靠] 小窗轻点（任意位置）→ 装回主窗（AevonDockTapAnywhereV255）")
        AevonWindowManager.restoreDocked(bundleID: bundleID)
    }

    /// 离开停靠：装回主窗（几何回到主窗记忆）。
    func leaveDock(animated: Bool) {
        guard isDocked else { return }
        isDocked = false
        sceneHost.setContentInteraction(true)
        // V0.2.60（AevonDockTapOnlyV260）：停靠期被摘除的窗外手势手柄立刻恢复。
        setDockHandlesEnabled(true)
        // V0.2.61（AevonDockTapFixV261）：装回后撤掉「点一下装回」命中层，
        // 否则它会在主窗上继续吃点击（主窗内容要能正常交互）。
        removeDockTapCatcher()
        // V0.2.59（AevonDockHaloOffV259）→ V0.2.60（AevonDockHaloBackV260）：
        // 还原光晕的时机改到**动画结束之后**。Aevon(34) #2：「吸附小窗还原时也会有光晕
        // 闪过」—— 0.2.59 是动画一开始就把光晕按主窗尺寸恢复，于是小窗位置瞬间冒出
        // 一大圈光，和正在长开的窗口不同步 = 又是那次「闪过」。等 0.22s 长完再恢复。
        let restoreGlow = { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.glowRing.isHidden = false
            CATransaction.commit()
            self.appliedGlowKey = ""
            self.updateEdgeGlow()
        }
        let target = AevonWindowView.mainFrameForRestore()
        let apply = { [weak self] in
            guard let self else { return }
            self.frame = target
            self.layoutIfNeeded()
        }
        if animated, window != nil {
            UIView.animate(withDuration: 0.22, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction],
                           animations: apply, completion: { _ in restoreGlow() })
        } else {
            apply()
            restoreGlow()
        }
        AevonLog.info("[停靠] \(bundleID) 已从停靠列装回主窗"
            + "（\(Int(target.width))x\(Int(target.height))，光晕在过渡结束后才恢复）"
            + "（AevonDockColumnV250 AevonDockHaloOffV259 AevonDockHaloBackV260）")
    }

    // MARK: - 停靠封面（V0.3.34，AevonDockCoverV334 / AevonDockSleepV334）

    /// 停靠封面总开关。写 UserDefaults `AevonDockCoverOff334` = true 可整条回退。
    ///
    /// ⛔ 不能写成 `static let = false` 字面量：Swift -O 的 whole-module 优化会把
    /// 「从未被写过」的常量做常量传播，把 guard 之后的函数体整段判为 unreachable 并删除，
    /// 连带里面的标记串一起消失（0.3.25 的 AevonNoFreezeV325 就是红在这条）。
    /// 走 UserDefaults 取值，编译器拿不到编译期常量 → 函数体与标记都保留。
    static let dockCoverDisabled: Bool = {
        let v = UserDefaults.standard.object(forKey: "AevonDockCoverOff334") as? Bool
        return v ?? false
    }()

    /// 停靠期盖在内容层上的静态封面。
    private var dockCoverView: UIImageView?
    /// 封面撤帧闸的计时起跑点（吸附那一刻；装回时重置）。
    private var dockCoverArmedAt: CFTimeInterval = 0
    private var dockCoverTimer: Timer?
    private var dockCoverTicks = 0

    /// 吸附前抓一帧画面当封面。
    ///
    /// 为什么必须有它：停靠小窗是全工程**唯一没有守卫的浮窗** ——
    /// `checkBackgroundGuard` 里 `guard !isDocked else { return }` 让它既不盖帧也不重申。
    /// 而全屏 App 在前台时，停靠窗的场景一旦失去前台身份，远程表面就被系统回收，
    /// 92x158 那一块就是纯黑，只能点一下装回才恢复。封面不依赖远程表面，
    /// 场景死没死都有画面。
    ///
    /// 抓帧点必须在「窗口还是大尺寸、画面还是活的」那一拍 —— `dockCurrent` 里
    /// 钉 dockedSide / relayout 之前。用 `captureSnapshotImage`（drawHierarchy，
    /// 能取到远程表面；`layer.render(in:)` 抓不到，见 AevonDarkGuardV249）。
    @discardableResult
    func installDockCover() -> Bool {
        if AevonWindowView.dockCoverDisabled {
            AevonLog.info("[停靠] 封面已停用（AevonDockCoverOff334）→ 跳过抓帧（\(bundleID)）"
                + "（AevonDockCoverV334）")
            return false
        }
        guard dockCoverView == nil, window != nil, !isTearingDown else { return false }
        guard let image = captureSnapshotImage() else {
            AevonLog.warn("[停靠] 抓不到可用画面 → 不装封面，退化成无兜底（\(bundleID)）"
                + "（AevonDockCoverV334）")
            return false
        }
        let cover = UIImageView(image: image)
        cover.contentMode = .scaleToFill
        cover.frame = contentClip.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        cover.layer.cornerRadius = AevonWindowView.cornerRadius(for: contentClip.bounds.width)
        cover.layer.masksToBounds = true
        contentClip.addSubview(cover)
        dockCoverView = cover
        dockCoverArmedAt = CACurrentMediaTime()
        dockCoverTicks = 0
        AevonLog.info("[停靠] 已装封面（图 \(Int(image.size.width))x\(Int(image.size.height))，"
            + "\(sceneHost.stateSummary())）→ 停靠期不再依赖远程表面"
            + "（AevonDockCoverV334）")
        return true
    }

    /// 吸附完成 → 把该场景主动置后台。
    ///
    /// 停靠小窗不显示实时画面（封面已经顶住），继续占着前台身份只有一个后果：
    /// 和用户正在用的全屏 App 抢同一个前台位 → 两边都在 cs 0/1 之间来回抖。
    /// 主动降后台把状态说清楚，装回时由 `restoreDocked` 推回前台。
    ///
    /// ⛔ 顺序铁律：**先抓封面，再降后台**。反了就抓到一张空表面（表面已被回收）。
    func suspendSceneForDock() {
        guard !isTearingDown, sceneHost.hasContent else { return }
        AevonSceneHelper.setForeground(sceneHost.scene, false, reason: "吸附降后台 \(bundleID)")
        AevonLog.info("[停靠] \(bundleID) 场景已主动置后台（停靠期不需要实时画面，"
            + "装回时再推前台）（AevonDockSleepV334）")
    }

    /// 装回主窗 → 开始判「实时画面真的回来了没有」，到了才撤封面。
    ///
    /// 判据只认 `contentState == 2` 连续 2 拍，并且要过 0.42 秒地板：
    /// 装回动画 0.22s 期间窗口还在长开，cs 会先报 2 再掉回 0（历史教训：
    /// 「cs 先报 2、远程表面还没真画上」），提前撤就是「静止图 → 黑一瞬 → 实时」。
    /// 上限 1.5 秒必撤 —— 宁可露实时，也不许永久盖着。
    func beginDockCoverLift() {
        guard dockCoverView != nil else { return }
        dockCoverArmedAt = CACurrentMediaTime()
        dockCoverTicks = 0
        guard dockCoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.dockCoverLiftTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        dockCoverTimer = timer
        AevonLog.info("[停靠] \(bundleID) 装回 → 封面留到实时画面连续 2 拍到位才撤"
            + "（上限 1.5s，AevonDockCoverLiftV334）")
    }

    private func dockCoverLiftTick() {
        guard dockCoverView != nil else {
            dockCoverTimer?.invalidate()
            dockCoverTimer = nil
            return
        }
        guard !isTearingDown else {
            dropDockCover(reason: "正在销毁")
            return
        }
        let now = CACurrentMediaTime()
        if now - dockCoverArmedAt > 1.5 {
            dropDockCover(reason: "上限 1.5s 到达")
            return
        }
        if now - dockCoverArmedAt < 0.42 { return }   // 装回动画 0.22s + 0.2s 地板
        if sceneHost.contentLooksRendering == true {
            dockCoverTicks += 1
            if dockCoverTicks >= 2 {
                dropDockCover(reason: "实时画面连续 2 拍到位（\(dockCoverTicks) 拍）")
            }
        } else {
            dockCoverTicks = 0
        }
    }

    /// 撤封面（幂等；关窗 / 重新吸附 / 超时都走它）。
    func dropDockCover(reason: String) {
        dockCoverTimer?.invalidate()
        dockCoverTimer = nil
        dockCoverTicks = 0
        guard let view = dockCoverView else { return }
        dockCoverView = nil
        view.removeFromSuperview()
        AevonLog.info("[停靠] 撤封面（\(reason)，\(sceneHost.stateSummary())）"
            + "（AevonDockCoverLiftV334）")
    }

    /// V0.2.66（AevonTraitWakeV266，用户 Aevon(39) #1「悬浮窗画面不跟随系统深浅色」）：
    /// 系统深浅色切换时，浮窗里那个 App 的场景被压在后台 —— 它收得到 trait 变化
    /// 但不重绘（远程表面停在旧外观的那一帧）。这里在 SpringBoard 侧窗口的 trait
    /// 翻转时把场景叫醒（与「抢全屏叫醒」同一条路），App 重绘后远程表面就是新外观。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard window != nil, !isTearingDown, sceneHost.hasContent else { return }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            AevonLog.info("[窗口] 系统深浅色切换（\(traitCollection.userInterfaceStyle == .dark ? "深色" : "浅色")）"
                + "→ 叫醒浮窗场景重绘（AevonTraitWakeV266）")
            refreshLiveContent(reason: "外观切换")
        }
    }

    /// V0.2.65（AevonLiveWakeV265，用户 Aevon(38) #9）：别的 App 抢了全屏 → 把浮窗里
    /// 这个场景叫醒，否则窗口上永远停着最后一帧（用户得点一下才恢复实时画面）。
    func refreshLiveContent(reason: String) {
        guard window != nil, !isTearingDown, sceneHost.hasContent else { return }
        guardArmedUntil = CACurrentMediaTime() + 4.0
        reassertCount = 0
        darkTicks = 0
        renderTicks = 0
        lastReassertAt = 0
        startGuardTimerIfNeeded()
        let rendering = sceneHost.contentLooksRendering
        if rendering != true {
            installDarkFreeze(reason: "实时画面停了")
        }
        reassertContentForeground(tag: "抢全屏叫醒")
        AevonLog.info("[窗口] 别的 App 抢了全屏（\(reason)）→ 叫醒浮窗场景，"
            + "0.9 秒后再补一次（当前 \(sceneHost.stateSummary())）（AevonLiveWakeV265）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.window != nil, !self.isTearingDown else { return }
            self.reassertContentForeground(tag: "抢全屏补一次")
        }
    }

    /// V0.2.65（AevonEntryRevealV265，用户 Aevon(38) #3「浮窗打开 App 时第一时间底栏黑屏」）：
    /// 开窗时窗口先以 alpha 0 藏着，等画布真的切到浮窗尺寸、App 重排过一拍之后再显。
    /// 幂等：重复调用只生效一次。
    func revealEntryNow(_ reason: String) {
        /* V0.2.77（AevonRevealOnceV277）：不再要求 `window != nil` —— 新定序是
         * 「addSubview 之后立刻显形」，此刻窗口可能还没挂进 window（入口容器搬家瞬间），
         * 旧判据会直接 return 且不置 entryRevealDone（留下一个隐形窗 = 用户 Aevon(49) #1）。
         * 现在挂了就显：动画在离屏也能跑完，挂上后第一帧就是终态。 */
        guard !entryRevealDone, !isTearingDown else { return }
        entryRevealDone = true
        /* V0.2.85（AevonRevealPlainV285，Aevon(58)「打开悬浮窗时依旧会闪一下悬浮窗，
         * 然后在出现最终悬浮窗和内容」）：
         *
         * 0.2.83 摘掉遮罩之后，**入场动画本身就成了那个「闪」**。原来的三拍是
         *   alpha 0 → 0.34 秒弹簧淡入（transform 0.965 → 1.0）
         * 缩放会让窗口在 0.34 秒里一直变大小，淡入会让内容半透明 —— 在已经"全程
         * alpha=0 到定稿才显"的新时序下，用户看到的第一个东西就是「窗从小变大 +
         * 渐渐透出来」，然后内容才清晰。他描述成「先闪一下悬浮窗，再出现最终悬浮窗
         * 和内容」，与这三拍完全一致（Aevon(58) 13:48:18.988 显形 → 18.991 淡入
         * 0.34s + 弹簧 → 19.73 复查）。
         *
         * 显形这件事的语义已经变成「画布定稿后一次性揭开」，不需要再补任何入场
         * 编排：缩放去掉（transform 恒 identity）。
         *
         * V0.2.87（AevonRevealInstantOnV287，Aevon(60)「悬浮窗内容会从虚到实的过渡，
         * 看着很别扭」）：**0.12 秒淡入也退役** —— Aevon(60) 日志实锤显形发生在
         * 「内容已定稿（第 0 次复查）」之后，此刻内容就是终态，任何 alpha 渐变
         * 都只是把终态画面盖上一层半透明再揭掉 = 用户读作「从虚到实」。显形只有
         * 一个正确姿势：定稿了就 alpha=1，零动画、零过渡、零渐变。 */
        alpha = 0
        transform = .identity
        alpha = 1
        AevonLog.info("[窗口] 开窗入场（\(reason)）：\(bundleID) 瞬时上屏，无淡入无缩放"
            + "（AevonRevealPlainV285 AevonRevealInstantOnV287）")
        primeSharpSnapshot(reason: reason)
    }

    /// V0.3.24（AevonSharpPrimeV324）：开窗定稿后强制建立一张**可信清晰帧**。
    ///
    /// 为什么必须在开窗这一拍抓：回桌面盖帧的图只能来自缓存或现场抓帧，而回桌面那一刻
    /// 场景正在被系统降级 —— 现场抓到的往往是低清表面，缓存若也为空就只剩「不冻」一条路
    ///（`内容不出画但没有可用快照 → 无法冻结`），用户全程看系统低清快照 = 定格模糊。
    /// 定稿这一拍画面是活的、清晰的，此时抓一张存起来，之后盖帧永远有图。
    /// 抓取成本：一次 drawHierarchy（约 10~30ms），发生在窗刚上屏的同一拍，
    /// 且只在开窗时执行一次（失败重试上限 3 次，间隔 0.4s）。
    private func primeSharpSnapshot(reason: String) {
        // V0.3.25（AevonNoFreezeV325）：B3 不盖帧 ⇒ 可信首帧无人消费（0.3.24 的那套
        // 「空白帧被当基准」问题也随之消失：根本不抓）
        guard !AevonWindowView.freezeDisabled else { return }
        guard sharpBaseline <= 1.0 || lastSharpSnapshotImage == nil else { return }
        guard primeSharpAttempts < 3 else { return }
        primeSharpAttempts += 1
        guard let image = captureSnapshotImage() else {
            AevonLog.info("[窗口] 可信首帧抓取失败（第 \(primeSharpAttempts) 次 / 上限 3）"
                + "→ 0.4s 后重试（AevonSharpPrimeV324）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.isTearingDown else { return }
                self.primeSharpSnapshot(reason: reason)
            }
            return
        }
        let score = sharpnessScore(image)
        cachedSnapshotImage = image
        lastSharpSnapshotImage = image
        if score > sharpBaseline { sharpBaseline = score }
        AevonLog.info("[窗口] 可信首帧已建立（清晰度 \(Int(score))，\(reason)）"
            + "→ 盖帧选图与撤帧门槛都以此为准（AevonSharpPrimeV324）")
    }

    /// V0.2.78（AevonRevealInstantV278，用户 Aevon(50) #4/#5）：
    /// **直显档零动画上屏**（已有垫底图时唯一的正确做法）。
    ///
    /// 为什么不能用 revealEntryNow：它内部先 `alpha = 0` 再 0.34 秒动画到 1。
    /// 对于「已经铺好垫底图」的再开窗，这个动作本身就是
    /// 「可见（垫底帧）→ 全透明（黑）→ 淡入（出现画面）」——
    /// 用户 Aevon(50) 的原话「先黑屏，然后出现画面」正是这三拍。
    /// 直显档要的语义是「窗从第一帧就在」：不淡入、不缩放，直接终态。
    func revealEntryInstant(_ reason: String) {
        guard !entryRevealDone, !isTearingDown else { return }
        entryRevealDone = true
        alpha = 1
        transform = .identity
        AevonLog.info("[窗口] 开窗直显（\(reason)）：\(bundleID) 零动画上屏，垫底图即终态"
            + "（AevonRevealInstantV278）")
    }

    // MARK: - 再开窗占位直换（V0.2.76，AevonReopenSwapV276）
    //
    // 用户 Aevon(48)：「悬浮窗打开时依旧会先出现悬浮窗，然后消失，1 秒后再次出现」。
    // Aevon(48) 22:02:00 时序账：0.600 直接开窗 → 0.623 入口遮罩（0.2.75 提前档）→
    // 0.795 第二代遮罩（V274，此刻抓屏抓到的已是 App 画面 = 「像开了」）→ 1.267 画布
    // 定稿 → 显窗。第二代遮罩的快照内容就是 App —— 盖上 = 「悬浮窗出现」，摘除换
    // 真窗 = 「消失再出现」。根治：关窗前抓最后一帧当占位图，再开窗面板**立刻显形**
    //（占位帧垫底），画布切换 / 回弹全程藏在占位后面，定稿后 crossfade 到活画面。

    /// 关窗前抓「最后一帧」当再开窗占位图（优先空闲预抓缓存）。
    func placeholderSnapshot() -> UIImage? {
        if let cached = cachedSnapshotImage, imageLooksLikeContent(cached) { return cached }
        return captureSnapshotImage()
    }

    private var reopenPlaceholderView: UIImageView?

    /// 开窗时把垫底图铺进内容区（场景内容之上）。
    /// V0.2.77（AevonRevealOnceV277）：两路来源 —— 关窗缓存的最后一帧（再开窗）/
    /// 现场裁的窗口区域屏幕快照（新开 App 时那块是桌面）。日志里区分来源，便于验收。
    func installReopenPlaceholder(_ image: UIImage, reason: String = "上一关最后一帧") {
        guard reopenPlaceholderView == nil else { return }
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleToFill
        iv.isUserInteractionEnabled = false
        iv.tag = 0xAE276
        /* V0.2.78（AevonRevealInstantV278）：垫底图尺寸兜底 —— 面板此刻可能还没走
         * 第一次 layout（contentClip.bounds 是 0x0），0 尺寸的垫底图铺上去等于没铺，
         * 直显出来就是一块空窗（这正是 #5「有概率不显示」的另一个面）。
         * 布局还没发生就用整窗 bounds 兜底，autoresizing 会随后对齐。 */
        let clipSize = contentClip.bounds.size
        let size = (clipSize.width > 1 && clipSize.height > 1) ? clipSize : bounds.size
        iv.frame = CGRect(origin: .zero, size: size)
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentClip.addSubview(iv)
        contentClip.bringSubviewToFront(iv)
        reopenPlaceholderView = iv
        AevonLog.info("[窗口] 再开窗垫底图已铺进面板（\(reason)直显）（AevonReopenSwapV276 AevonRevealOnceV277 AevonRevealInstantV278）")
    }

    /// V0.2.77（AevonRevealOnceV277）：把整屏快照裁出**窗口所在区域**当垫底图。
    /// 新开 App（没有关窗缓存）用 —— 那块区域本来就该显示下面的画面（桌面 / 前一个 App），
    /// 盖上它之后「窗在哪、窗多大」从第一帧就是确定且平滑的，不会有空面板 / 黑块。
    static func windowRegionSnapshot(for frame: CGRect) -> UIImage? {
        guard frame.width > 8, frame.height > 8 else { return nil }
        guard let shot = AevonQuickAction.captureScreenImage() else { return nil }
        let scale = shot.scale > 0 ? shot.scale : 1
        let bounds = CGRect(origin: .zero, size: shot.size)
        let rect = CGRect(x: frame.minX, y: frame.minY,
                          width: frame.width, height: frame.height).intersection(bounds)
        guard rect.width > 8, rect.height > 8 else { return shot }
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
        guard let cg = shot.cgImage?.cropping(to: pixelRect) else { return shot }
        let cropped = UIImage(cgImage: cg, scale: scale, orientation: shot.imageOrientation)
        /* V0.2.78（AevonSnapDarkV278，用户 Aevon(50) #4「新版本通过圆盘选中图标打开悬浮窗时
         * 会先黑屏，然后出现画面」）：
         *
         * 这块快照是在**开窗转场那一拍**抓的（presenter 正在激活 / 画布正在切），
         * 抓到的整幅可能就是黑的；把它当垫底图铺上去 = 用户描述的第一个黑屏。
         * 判黑就直接弃用（返回 nil），调用方退回「不铺、等画布定稿再淡入」——
         * 少一次直显，但绝不拿黑图骗自己。 */
        if isMostlyBlack(cropped) {
            AevonLog.warn("[窗口] 窗口区域快照判黑（转场瞬间抓帧）→ 弃用该垫底图"
                + "（AevonSnapDarkV278）")
            return nil
        }
        return cropped
    }

    /// 画布定稿后摘占位（crossfade 到活画面）。
    func settleReopenPlaceholder() {
        guard let iv = reopenPlaceholderView else { return }
        reopenPlaceholderView = nil
        UIView.animate(withDuration: 0.22, animations: { iv.alpha = 0 },
                       completion: { _ in iv.removeFromSuperview() })
    }

    private func persistFrame() {
        // V0.2.50：停靠态的坐标不进「主窗几何记忆」（否则下次开窗跑到边角）
        guard !isDocked else { return }
        // V0.2.67（AevonFrameGuardV267，用户 Aevon(40) #8「0.2.66 有概率屏幕点击失效」）：
        // 关窗后收尾动画的 completion 里也会走到这里 —— 把刚被 close() 清成 0x0 的
        // 浮窗矩形又写回通道，App 侧就拿着这个**残留矩形**继续吞「旧窗右缘/底缘带」
        // 的触摸（Aevon(40) 日志 14:51:00 三连吞 {348,218}{360,228}{355,222} 全落在
        // 上一扇窗 (29,194,340,583) 的右边带 = 实锤）。关窗中/已关窗一律不发布。
        // （不再查 currentView —— 它是 private；isClosing + isTearingDown 已覆盖
        //  全部复活路径，停靠窗另有 isDocked 闸。）
        if isTearingDown || isClosing { return }
        guard !isLiveResizing, transform.isIdentity else { return }
        guard let store = UserDefaults(suiteName: AevonWindowView.prefsSuite) else { return }
        let screen = UIScreen.main.bounds
        guard screen.width > 1, screen.height > 1, frame.width > 1 else { return }
        // V0.2.48（AevonCanvasFixedV248）：落盘前先夹屏 —— 只存「合法几何」，
        // 免得把「停在屏边只露一角」的状态写进记忆，下次开窗又跑到边角去。
        let safe = AevonWindowView.clampedToScreen(frame)
        guard safe.height > 1 else { return }
        let xp = Double(safe.minX / screen.width * 100.0)
        let yp = Double(safe.minY / screen.height * 100.0)
        let wp = Double(safe.width / screen.width * 100.0)
        let previous = (store.array(forKey: AevonWindowView.frameMemoryKey) as? [Double]) ?? []
        store.set([xp, yp, wp], forKey: AevonWindowView.frameMemoryKey)
        // V0.2.48：**必须 synchronize**。0.2.47 及以前只 set 不落盘，
        // 注销（respring 是 SIGKILL）时未刷盘的写入直接丢失 → 用户体感
        // 「每次注销后位置尺寸都回到默认」。一次同步写成本可忽略，只在落盘时发生。
        store.synchronize()
        var text = "[窗口] 几何已记忆 \(Int(safe.width))x\(Int(safe.height))"
            + " 左上 (\(Int(safe.minX)),\(Int(safe.minY)))"
            + " = \(String(format: "%.1f", xp))%/\(String(format: "%.1f", yp))%/宽 \(String(format: "%.1f", wp))%"
            + "（关窗中一律不发布，防残留矩形误吞）（AevonFrameGuardV267）"
        if previous.count >= 3 {
            text += "（上次 \(String(format: "%.1f", previous[0]))%/\(String(format: "%.1f", previous[1]))%/\(String(format: "%.1f", previous[2]))%）"
        }
        AevonLog.info(text + "（AevonFrameMemoryV248）")
        AevonWindowManager.publishFloatFrame(safe)
    }

    // MARK: - 关闭

    @objc private func closeTapped() {
        AevonWindowManager.close(bundleID: bundleID)
    }

    /// V0.2.49（AevonFloatAnimV249）：Aevon(24)「关闭动画要更流畅，而不是突然间的变动」。
    ///
    /// 关闭的三步顺序是刻意的：
    ///   ① 先把当前画面**冻结成一张图**（在场景被销毁之前抓，否则抓到的是空表面）；
    ///   ② 同步做完全部销毁（host.invalidate / 场景 sleep 由 close 接着做）——
    ///      这一刻真实画面已经没了，但上面盖着那张图，视觉上什么都没发生；
    ///   ③ 视图做 0.18 秒淡出 + 0.97 缩小后自己摘掉。
    ///
    /// 如果没有第 ① 步，淡出的就是一块黑 —— 那比硬切还难看。
    /// 抓不到快照（远程表面异常）就跳过冻结，直接硬摘（退回 0.2.48 行为）。
    func teardown() {
        guard !isTearingDown else { return }
        isTearingDown = true
        // V0.2.77（AevonRevealOnceV277）：垫底图别跟着面板一起被强引用住（每窗一份）
        reopenPlaceholderView?.removeFromSuperview()
        reopenPlaceholderView = nil
        // 关窗前把最终位置记下来
        persistFrame()
        // V0.2.48（AevonNoAutoLockV248）：浮窗没了 → 空闲锁屏还原
        AevonWindowView.endNoAutoLock()
        // V0.2.49：熄屏重申定时器与系统唤醒观察者一起收尾
        idleKickTimer?.invalidate()
        idleKickTimer = nil
        removeSystemWakeObservers()
        selfSceneFallbackTimer?.invalidate()
        selfSceneFallbackTimer = nil
        // V0.2.47（AevonDarkGuardV247）：守卫与冻结层一起收尾
        guardArmedUntil = 0
        stopGuardTimer()
        removeDarkFreeze(reason: "关窗收尾")
        // V0.3.34（AevonDockCoverV334）：停靠封面与它的撤帧闸一起收尾
        dropDockCover(reason: "关窗收尾")
        // V0.2.60（AevonLiveFirstV260）：让位期（整窗 alpha 0）里关窗 → 先撤销让位。
        // 否则离场帧是在一个隐形窗口上抓的（抓到空壳 → 淡出动画被跳过，硬切一下）。
        if liveWaitDeadline > 0 {
            liveWaitDeadline = 0
            liveWaitStartedAt = 0
            liveWaitTicks = 0
            alpha = 1
            AevonLog.info("[窗口] 让位期关窗：先撤销让位再抓离场帧（AevonLiveFirstV260）")
        }
        // V0.2.89（AevonCloseInstantV289）：离场帧抓取已随关闭动画退役。
        // V0.2.44（AevonScreenAspectV244）：比例监听到此为止
        aspectWatchTimer?.invalidate()
        aspectWatchTimer = nil
        // 必须先 invalidate 承载容器再拆视图，否则容器 dealloc 会抛
        // NSInternalInconsistencyException: Must be invalidated before deallocating
        sceneHost.onFirstContent = nil
        sceneHost.invalidate()
        sceneHost.container.removeFromSuperview()

        /* V0.2.89（AevonCloseInstantV289）：**关闭瞬时化** —— 原离场帧 + 0.18s 淡出缩放
         * 整段退役（用户 2026-10-29 定档：移除悬浮窗的所有交互动画；圆盘动画不在此列）。
         * 承载容器已 invalidate、画布已还原，直接摘视图，无任何 alpha/transform 渐变；
         * exitFreezeView（离场帧抓取，只为给淡出动画供画面）随之整体删除。 */
        AevonLog.info("[窗口] 浮窗已关：瞬时摘除，无离场帧无淡出（AevonCloseInstantV289）")
        removeFromSuperview()
    }

    /* V0.2.89（AevonCloseInstantV289）：exitFreezeView（离场帧）已随关闭动画整体退役。
     * V0.2.49（AevonFloatAnimV249）的关闭动画 era 至此结束。 */
}

/* V0.3.26（AevonKeepAliveProbeV326）：场景保活探针的 C 桥。
 *
 * 实现在 Sources/AevonKeepAliveProbe.m —— 之所以放在 ObjC 而不是 Swift：内部要
 * `objc_msgSend` 直调一大批**不确定是否存在**的私有选择子（UIApplicationScene
 * DeactivationManager 的断言 API），未知选择子抛的 NSException **Swift 抓不到**，
 * 会直接打成 SIGABRT。ObjC 的 @try/@catch 是这层唯一的崩溃防线。 */
@_silgen_name("AevonKeepAliveProbeBegin")
private func AevonKeepAliveProbeBegin(_ scene: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("AevonKeepAliveProbeEnd")
private func AevonKeepAliveProbeEnd()

/// ObjC 探针的统一日志出口（探针自己拼中文，这里只负责落盘 + 带标记串）。
@_cdecl("AevonKeepAliveLog")
public func AevonKeepAliveLog(_ detail: UnsafePointer<CChar>?) {
    let d = detail.map { String(cString: $0) } ?? ""
    AevonLog.info("[保活] \(d)（AevonKeepAliveProbeV326）")
}
