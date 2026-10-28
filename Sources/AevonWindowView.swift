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
        alpha = 0.35
        transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        // V0.2.50（AevonDarkGuardV250）：看门定时器从「上屏那一刻」就开，
        // 不再等某个事件来布防（第 7 条：事件没来 = 守卫从未上场 = 纯黑）。
        startGuardTimerIfNeeded()
        UIView.animate(withDuration: 0.24, delay: 0,
                       options: [.curveEaseOut, .allowUserInteraction]) { [weak self] in
            self?.alpha = 1.0
            self?.transform = .identity
        } completion: { [weak self] _ in
            // 兜底：动画被打断（比如手势立刻开始）也必须回到恒等矩阵
            self?.transform = .identity
        }
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
            if edges == .bottom {
                // 底边双击 = 关闭浮窗（V0.2.21，AevonFloatBottomDblCloseV221）。
                // 与落指即拖共存：pan 需要约 10pt 位移才 began，双击原地点两下不会触发拖动。
                let doubleTap = UITapGestureRecognizer(target: self,
                                                       action: #selector(handleBottomDoubleTap(_:)))
                doubleTap.numberOfTapsRequired = 2
                doubleTap.cancelsTouchesInView = false
                doubleTap.delaysTouchesBegan = false
                doubleTap.delaysTouchesEnded = false
                handle.addGestureRecognizer(doubleTap)
            }
            // V0.2.53（AevonDockArbiterV253，用户 Aevon(27) #2）：0.2.51 给左右边条
            // 加的边条轻点识别器 **整建制退役** ——
            // 真机日志实锤它和全局通道对同一次轻点各响应一次：全局通道先 dock
            // （34.570），视图 tap 12ms 后看见 isDocked=true 又 restoreDocked
            // （34.582）→ 用户体感「轻点停靠没效果、吸附后自动还原主窗」。
            // 轻点停靠唯一入口 = 全局通道（AevonEdgeEntry.handleFloatGestureEnded
            // 的轻点分支），桌面 / 全屏 App 它都收得到（sendEvent 是总入口）。
        }
    }

    /// 外侧手势的统一入口：角块 → 缩放；边条 → 落指即拖移动（V0.2.27）。
    @objc private func handleOutsidePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? AevonEdgeHandleView else { return }
        // V0.2.67（AevonSideMaskV267）：贴边侧热区屏蔽，与全局通道 grab(at:) 同一判据
        if sideMaskedForScreenEdge(handle.edges) { return }
        if handle.isCorner {
            handleCornerResize(gesture, edges: handle.edges)
        } else {
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
            isBarHoldMoving = true
            moveOriginFrame = frame
            moveOriginPoint = point
            AevonLog.info("[窗口] 边条落指即拖 → 移动（AevonFloatEdgeGripV227）")
        case .changed:
            guard isBarHoldMoving else { break }
            applyBarMove(to: point)
        case .ended, .cancelled, .failed:
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

    /// 底边双击 = 关闭浮窗（V0.2.21，AevonFloatBottomDblCloseV221）。
    /// 原「顶部双击恢复默认大小与位置」随顶部手势区一起移除（0.2.21 用户定档；
    /// 其 CI 历史串 AevonRestoreDefaultV101 收容在 AevonAssertionShim.m）。
    @objc private func handleBottomDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !isLiveResizing, !isBarHoldMoving else { return }
        guard let handle = gesture.view as? AevonEdgeHandleView,
              handle.edges == .bottom else { return }
        AevonLog.info("[窗口] 底边双击 → 关闭浮窗（AevonFloatBottomDblCloseV221）")
        closeTapped()
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
    private func lastContentFrame() -> UIImage? {
        if let fresh = captureSnapshotImage() {
            // V0.2.73（AevonLivePadDarkV273，用户 Aevon(45) #5「回桌面黑屏 1 秒左右才出
            // 实时画面」）：**黑帧拒垫** —— 现场抓帧发生在 App 场景退场过程中时，
            // drawHierarchy 抓出来的可能整幅发黑；黑帧垫上去 = 用户看到的「黑屏 1 秒」。
            // 中心 + 四角采样，全黑（RGB 均 < 8/255）就丢弃，回落滚动缓存帧
            //（refreshRollingSnapshot 每 3 秒保温的那张「离黑屏最近的帧」）。
            if isMostlyBlack(fresh) {
                AevonLog.warn("[窗口] 现场抓帧全黑（退场中抓到黑画面）→ 弃用，垫滚动缓存帧"
                    + "（AevonLivePadDarkV273）")
            } else {
                cachedSnapshotImage = fresh
                return fresh
            }
        }
        return cachedSnapshotImage
    }

    /// V0.2.73（AevonLivePadDarkV273）：中心 + 四角五点采样，全部 RGB < 8 视为黑帧。
    private func isMostlyBlack(_ image: UIImage) -> Bool {
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

    /// 空闲时预抓快照进缓存（窗口创建后首帧、每次缩放提交后各一次）。
    private func scheduleSnapshotRecapture(after delay: TimeInterval = 0.6) {
        snapshotRecaptureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isLiveResizing, !self.isBarHoldMoving,
                  self.hintLabel.isHidden else { return }
            self.cachedSnapshotImage = self.captureSnapshotImage()
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
    private static let liveWaitLimit: TimeInterval = 1.0
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
    func armBackgroundGuard(reason: String) {
        guard window != nil else { return }
        guard sceneHost.hasContent else { return }   // 还没出过首帧：交给首帧探测，别掺和
        beginGuardWindow(reason: reason)
        // V0.2.60（AevonLiveFirstV260）：回桌面 / 切 App 走「先让位、后淡入」，
        // 不再盖定格帧（Aevon(34) #1：定格 1 秒观感比晚出现 0.3 秒差得多）。
        if reason.contains("画面离场") {
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
        let reassertDelays: [Double] = reason.contains("画面离场") ? [0.40] : [0.25, 0.55, 0.85]
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
    /// 实时画面回来后 0.22 秒交叉淡出（见 removeDarkFreeze）。屏幕上永远有一块
    /// 连续的浮窗，没有"空窗"帧，也就不可能闪。
    private func beginLiveWait(reason: String) {
        let now = CACurrentMediaTime()
        liveWaitStartedAt = now
        liveWaitDeadline = now + AevonWindowView.liveWaitLimit
        liveWaitTicks = 0
        liveAwaitingContent = false
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
            + "实时画面回来再 0.22 秒交叉淡出，上限 \(String(format: "%.1f", AevonWindowView.liveWaitLimit)) 秒"
            + "（AevonLiveFirstV260 AevonLiveFirstFixV261 AevonLiveQuietV262 AevonNoVanishV265）")
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
        /* rendering != true 时保留定格帧（宁可停住，也不露一块空窗）；
         * 常驻看门会在 cs=2 时撤掉它。 */
        AevonLog.info("[窗口] 回桌面让位结束（\(String(format: "%.2f", held))s，\(reason)，"
            + "画面=\(rendering == true ? "实时" : "仍定格")，窗口 alpha 全程 1）"
            + "（\(sceneHost.stateSummary())）（AevonNoVanishV265）")
    }

    /// V0.2.63（AevonLiveHiddenV263）：藏着等真画面 —— 连续 2 拍在画才淡入，
    /// 全程只有一次 alpha 变化（0 → 1），中间任何一帧都不会出现在屏幕上。
    private func checkAwaitingContent() -> Bool {
        guard liveAwaitingContent else { return false }
        if sceneHost.contentLooksRendering == true {
            renderTicks += 1
            if renderTicks >= 2 {
                liveAwaitingContent = false
                liveSettleUntil = CACurrentMediaTime() + AevonWindowView.liveSettleWindow
                alpha = 0
                transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
                UIView.animate(withDuration: 0.22, delay: 0,
                               options: [.curveEaseOut, .allowUserInteraction],
                               animations: { [weak self] in
                    self?.alpha = 1
                    self?.transform = .identity
                })
                AevonLog.info("[窗口] 真画面到了（cs=2 连续 2 拍）→ 藏着等的那扇窗 0.22s 浮现"
                    + "（\(sceneHost.stateSummary())）（AevonLiveHiddenV263 AevonFadeInV264）")
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
            // V0.2.60（AevonLiveFirstV260）：要求稳定才淡入。
            // V0.2.62（AevonLiveQuietV262，Aevon(36) #5）：从「连续 2 拍」放宽成
            // 「至少 1 拍 + 让位已过 0.12 秒」。Aevon(36) 实测让位 0.43 / 0.65 秒才淡入，
            // 这么长的「窗口消失」本身就是一次闪；0.12 秒足够避开系统回桌面动画的首帧，
            // 又不至于让用户觉得窗口「没了」。
            if liveWaitTicks >= 1, now - liveWaitStartedAt > 0.12 {
                finishLiveWait(reason: "实时画面已回来（\(liveWaitTicks) 拍）")
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
                if renderTicks >= 2 { removeDarkFreeze(reason: "看门：内容回来了（cs=2）") }
            case .some(false):
                renderTicks = 0
                idleDarkTicks += 1
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
            if renderTicks >= 2 {
                removeDarkFreeze(reason: "布防：内容已回画（cs=2 连续 2 拍）")
            } else if darkFreezeView != nil, captureSnapshotImage() != nil {
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
        guard darkFreezeView == nil, hintLabel.isHidden, !isTearingDown else { return }
        // V0.2.60（AevonLiveFirstV260）：让位期整窗是隐形的，再盖一张定格帧纯属浪费
        //（还会在淡入那一刻露出旧画面）。让位收尾时会自己决定要不要垫缓存帧。
        //
        // V0.2.65（AevonNoVanishV265）：让位期窗口不再隐形了 —— 现在正是**要在让位期
        // 盖一张最后一帧顶住**（否则那一秒就是一块空窗）。所以只在「让位期且不是
        // 让位自己要求盖」时才拒绝。
        guard liveWaitDeadline == 0 || liveWaitFreezeAllowed else { return }
        guard let image = lastContentFrame() else {
            AevonLog.warn("[窗口] 内容不出画但没有可用快照 → 无法冻结（只能等重申生效，\(reason)）"
                + "（\(sceneHost.stateSummary())）（AevonDarkGuardV247 AevonDarkGuardV249）")
            return
        }
        let bounds = contentClip.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let view = UIImageView(image: image)
        view.frame = contentClip.frame
        view.contentMode = .scaleToFill
        view.layer.cornerRadius = AevonWindowView.cornerRadius(for: bounds.width)
        view.layer.masksToBounds = true
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 点一下 = 手动再要一次画面（等同「关掉重开」那次重申，但不用真关）
        view.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(darkFreezeTapped))
        view.addGestureRecognizer(tap)
        addSubview(view)
        darkFreezeView = view
        AevonLog.warn("[窗口] 内容不出画 → 盖上最后一帧（\(reason)，点一下可手动重申）"
            + "（\(sceneHost.stateSummary())）（AevonDarkGuardV247 AevonDarkGuardV249）")
    }

    private func removeDarkFreeze(reason: String) {
        guard let view = darkFreezeView else { return }
        darkFreezeView = nil
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
    @objc private func darkFreezeTapped() {
        AevonLog.info("[窗口] 用户点了冻结画面 → 手动重申前台（等同关掉重开的那一下）"
            + "（\(sceneHost.stateSummary())）（AevonDarkGuardV247）")
        guardArmedUntil = CACurrentMediaTime() + 4.0
        darkTicks = 0
        reassertCount = 0
        lastReassertAt = 0
        startGuardTimerIfNeeded()
        // 点一下之后继续盖着：巡查看到 cs=2 会立刻撤（0.2.49 起不再等两拍）
        reassertContentForeground(tag: "手动点击")
        for delay in [0.6, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reassertContentForeground(tag: "手动点击 +\(delay)s")
            }
        }
    }

    /// 滚动刷新最后一帧（默认每 3 秒一次，只在空闲且画面正常时）：
    /// 冻结层要「离黑屏最近的那一帧」，而不是开窗那一帧。顺手把缩放快照也保温。
    ///
    /// 抓不到就退避：远程表面抓取可能恒为透明（0.2.26 已记录的兜底路径），
    /// 连续 3 次失败说明这台设备上抓不出快照 → 间隔放到 30 秒，别白烧 CPU。
    private func refreshRollingSnapshot() {
        let now = CACurrentMediaTime()
        let interval: TimeInterval = snapshotMissStreak >= 3 ? 30.0 : 3.0
        guard now - lastSnapshotRefreshAt >= interval else { return }
        guard window != nil, hintLabel.isHidden, darkFreezeView == nil else { return }
        guard !isLiveResizing, !isBarHoldMoving, transform.isIdentity else { return }
        guard sceneHost.contentLooksRendering != false else { return }
        lastSnapshotRefreshAt = now
        if let image = captureSnapshotImage() {
            cachedSnapshotImage = image
            snapshotMissStreak = 0
        } else {
            snapshotMissStreak += 1
        }
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
        guard !entryRevealDone, !isTearingDown, window != nil else { return }
        entryRevealDone = true
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.965, y: 0.965)
        UIView.animate(withDuration: 0.34, delay: 0,
                       usingSpringWithDamping: 0.86,
                       initialSpringVelocity: 0.3,
                       options: [.allowUserInteraction, .beginFromCurrentState],
                       animations: { [weak self] in
            self?.alpha = 1
            self?.transform = .identity
        }, completion: nil)
        AevonLog.info("[窗口] 开窗入场（\(reason)）：\(bundleID) 淡入 + 0.965→1.0 弹簧 0.34s"
            + "（AevonFloatTransitionV264 AevonEntryRevealV265）")
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
        // V0.2.60（AevonLiveFirstV260）：让位期（整窗 alpha 0）里关窗 → 先撤销让位。
        // 否则离场帧是在一个隐形窗口上抓的（抓到空壳 → 淡出动画被跳过，硬切一下）。
        if liveWaitDeadline > 0 {
            liveWaitDeadline = 0
            liveWaitStartedAt = 0
            liveWaitTicks = 0
            alpha = 1
            AevonLog.info("[窗口] 让位期关窗：先撤销让位再抓离场帧（AevonLiveFirstV260）")
        }
        // V0.2.49：抓离场帧（必须在承载容器 invalidate 之前）
        let exitFrame = exitFreezeView()
        // V0.2.44（AevonScreenAspectV244）：比例监听到此为止
        aspectWatchTimer?.invalidate()
        aspectWatchTimer = nil
        // 必须先 invalidate 承载容器再拆视图，否则容器 dealloc 会抛
        // NSInternalInconsistencyException: Must be invalidated before deallocating
        sceneHost.onFirstContent = nil
        sceneHost.invalidate()
        sceneHost.container.removeFromSuperview()

        guard exitFrame != nil, window != nil else {
            removeFromSuperview()
            return
        }
        // ②→③ 动画离场：只动 alpha / transform，不动 frame（不触发布局）
        UIView.animate(withDuration: 0.18, delay: 0,
                       options: [.curveEaseIn, .allowUserInteraction]) { [weak self] in
            self?.alpha = 0
            self?.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        } completion: { [weak self] _ in
            self?.removeFromSuperview()
        }
    }

    /// 离场帧：把当前内容区画面盖成一张静态图（只为让关闭动画有画面可淡）。
    /// 优先用空闲预抓的缓存（零渲染），没有才现场抓一帧；都拿不到返回 nil。
    private func exitFreezeView() -> UIView? {
        let bounds = contentClip.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        guard let image = cachedSnapshotImage ?? captureSnapshotImage() else { return nil }
        let view = UIImageView(image: image)
        view.frame = contentClip.frame
        view.contentMode = .scaleToFill
        view.layer.cornerRadius = AevonWindowView.cornerRadius(for: bounds.width)
        view.layer.masksToBounds = true
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        addSubview(view)
        AevonLog.info("[窗口] 关闭动画：已冻结离场帧（\(Int(bounds.width))x\(Int(bounds.height))）"
            + "（AevonFloatAnimV249）")
        return view
    }
}
