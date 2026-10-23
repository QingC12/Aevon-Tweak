import UIKit

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

/// 浮窗上被按住的位置（V0.0.44，AevonSthenoGestureV44）。
///
/// 全局触摸通道拿不到 `UIPanGestureRecognizer`，只能拿到坐标，所以命中结果用这个
/// 枚举交给浮窗自己决定「这次拖动是移动 / 缩放 / 关闭」。
enum AevonFloatGrab {
    /// 左右侧条：拖动 = 移动窗口；轻点 = 停靠到该侧变小窗 / 已停靠则还原主窗
    case side(UIRectEdge)
    /// 下方角块 → 从对角缩放
    case corner(UIRectEdge)
    /// 底边条：拖动 = 移动窗口；双击 = 关闭浮窗
    case bottom
    /// V0.0.46（AevonDockTapRestoreV46）：**停靠小窗的整块窗身**。
    /// 用户 Aevon(39)：「吸附停靠后的小窗能不能改为点击小窗后还原到主悬浮窗」——
    /// 小窗只有 30% 屏宽，侧条又只有 20pt，实际很难点准，所以整块窗身都算轻点还原。
    /// 拖动窗身仍然 = 移动（与侧条同一套位移逻辑）。
    case body
}

/// 单个 App 的浮窗外壳：纯内容（无标题栏）+ 右上悬浮 ✕ + 贴窗外边缘的手势区。
///
/// V0.0.9：App 场景按整屏尺寸渲染，浮窗只对承载容器做等比缩放。
/// V0.0.11：内容区宽高比锁定屏幕比例。
/// V0.0.12：手势期间只改外壳 `layer.transform`，抬手才提交真实 frame。
/// V0.0.13：窗口大小/位置记忆 + 双击切换大小档。
/// V0.0.14：拖到屏幕边缘自动吸附（左半屏 / 右半屏 / 顶部放大）。
/// V0.0.36：四周 8 向缩放（当时在窗内）。
/// V0.0.37（AevonSthenoEdgeBarV37）：按 Stheno 逆向证据重做手势体系 ——
///   手势区域**只在浮窗边缘外侧**（EdgeBarControlView / GestureIntroduction
///   「浮窗手势区域为边缘外侧…」），窗内 100% 留给 App 内容：
///     · 拖四条**边条**（外侧）＝ 移动窗口；
///     · 拖四个**外角块** ＝ 缩放（对角锚定，比例锁定）；
///     · 双击任意边条 ＝ 小窗 / 大窗切换；
///     · 右上角悬浮 ✕ ＝ 关闭；
///     · 拖到屏幕边缘松手仍自动吸附。
///   顶部标题栏（拖动条 + 关闭钮）整条移除（用户要求）。
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
/// V0.0.42（AevonSthenoDockV42 / AevonFloatLookV42）：按 Stheno 主浮窗的模型重做观感与几何 ——
///   · 圆角随内容缩放同比（取其 `_displayCornerRadius` * radiusLast 的思路），加投影 + 细描边；
///   · 停靠（吸附）只靠边、不改尺寸（对应 Stheno leftPecent/rightPecent/heightPecent）；
///   · 四边恒定留 `AevonSnap.edgeInset`（= 外角块 34pt），窗口永远抓得到缩放手柄。
///   Aevon(35) 日志里 `吸附到顶部放大 407x884`（屏 430x932）导致四角出屏、再也缩放不了。
/// V0.0.43（AevonSthenoGestureV43）：用户按 Stheno 实机观感重定义手势与几何 ——
///   · 顶部（顶边条 + 两个上角块 + 右上 ✕）全部移除，顶部不再有任何手势区；
///   · 左右**侧条**：长按 / 直接拖 = 移动；**轻点 = 吸附到该侧并变成小窗**；
///   · **底边条：双击 = 关闭浮窗**（原 ✕ 的替代出口）；
///   · 只保留两个**下角块**做缩放；
///   · 贴边距离 34pt → 5pt；默认窗宽 70% → 55%；停靠尺寸固定为 50% 屏宽的小窗。
///   关键：窗口贴到屏幕边上时，外侧手柄会整条滑出屏外（5pt 只剩 5pt 可点），
///   所以 `layoutGestureHandles()` 会按「该边离屏边多远」把对应手柄改挂到窗**内侧**，
///   保证任何位置都抓得到 —— 否则一贴边就再也拖不回来。
/// V0.0.44（AevonSthenoGestureV44）：
///   · 内容可视区去掉顶部状态栏那条空白（宿主不画状态栏 → 窗口顶部一大块空白、
///     整体变成竖长条，Aevon(37) 的观感问题）；
///   · 缩放改成每帧直接改 frame（AevonLiveResizeV44）—— 不再用 transform，
///     缩放过程圆角始终保留、画面全程实时，不再有「贴图快照 → 突然跳实时」的卡顿；
///   · 轻点已停靠的侧条 = 还原主悬浮窗（AevonDockRestoreV44）；
///   · 底边条加宽到 30pt，拖动 = 移动，双击 = 关闭；
///   · 浮窗之间自动避让（AevonDockAvoidV44），停靠小窗不再压住主窗的手势条；
///   · 四周加一圈 0.9pt / 白色 34% 的描边（AevonFloatEdgeGlowV44），深色背景也看得清边界。
/// V0.0.45（AevonFloatSmoothV45 / AevonDockSizeV45 / AevonCornerHotV45）：
///   · 缩放卡顿（Aevon(38)「一卡一卡，但不再有快照」）——两处根因一起修：
///     ① 每条 touch move 都同步改 frame，一帧布局 2~4 次 → 改由 CADisplayLink 合帧，
///        每个刷新周期只应用最新目标点；
///     ② 每一帧都改 `contentClip.cornerRadius` → 带 mask 的离屏合成每帧重建，
///        改成拖动期间圆角固定在起始值、抬手一次对到最终值。
///     拖动期间的避让计算（`dockedObstacles` 遍历）也挪到抬手时做一次。
///   · 停靠小窗收到屏宽 30%（原 42%），且不再被 `minContentWidth` 抬回去；
///   · 顶部停靠彻底删除（`AevonSnapSlot.top` 已不存在）；
///   · 白描边 0.9pt/34% → 0.5pt/26%；
///   · 下角块 36 → 48pt，另加 10pt 命中外扩（右下角缩放不好按）。
/// V0.0.46（AevonResizeSmoothV46 / AevonDockStackV46 / AevonFloatPaddingV46 /
///          AevonDockTapRestoreV46 / AevonFrameMemoryCleanV46），用户 Aevon(39)：
///   · **缩放抖动**：`clampedCornerWidth` 原来用 `abs(dx)>=abs(dy)` 在横/纵两条公式间
///     二选一，两值相差近一倍 → 手指没变方向窗口却突然变大变小。改为两向投影取平均。
///   · **停靠小窗竖向排版**：`AevonSnap.dockY` 先算屏幕中心，撞了优先往下叠。
///   · **顶部太窄 + 返回按钮被啃**：内容上下各留 14pt 深色边，窗口圆角不再咬到导航栏；
///     顶部裁剪量减少 8pt，保证导航栏那一行完整。
///   · **轻点停靠小窗 = 还原主窗**：整块窗身成为抓取区（`.body`），轻点还原、拖动移动。
///   · **几何记忆被小窗污染**：停靠态不再写 `MedusaFrameLast`，读到时也会作废。
final class AevonWindowView: UIView {
    let bundleID: String
    private let sceneHost: AevonSceneHost

    /// 内容可视区宽高比 = 屏宽 ÷（屏高 − 顶部状态栏空白）。见 `AevonSnap.aspect`。
    ///
    /// V0.0.44：不再用整屏比例。宿主不画状态栏，那条 59pt 在浮窗里是纯空白，
    /// 算进高度会把窗口拉成细长条（Aevon(37) 用户反馈「顶部空白很大」）。
    static var contentAspect: CGFloat { return AevonSnap.aspect }

    private static let minContentWidth: CGFloat = 118
    /// 左右侧条厚度（手势区）。Stheno 的 edgeWidth 同位概念。
    static let barThickness: CGFloat = 20
    /// 底边条厚度。V0.0.44 原 18pt → 30；V0.0.56（AevonBigBottomBarV56）30 → 46。
    ///
    /// 用户 Aevon(50) 第 2 条：「底部手势热区可以加宽一点，因为在全屏 App 中
    /// 双击浮窗底部关闭时会触发全屏 App 的点击操作」。
    /// 加宽解决"按不准"，漏点击的根治在两条跨进程判据上（浮窗矩形 + 停靠格几何），
    /// 见 `AevonEntryHost.syncFloatRectToGuard`。
    static let bottomBarThickness: CGFloat = 46
    /// 外角块边长。V0.0.45（AevonCornerHotV45）：36 → 48。
    /// 用户 Aevon(38)：「右下角的缩放手势有点不灵敏」—— 36pt 贴在窗角外侧，
    /// 手指要正好压在上面才开始缩放，实际很难命中。边长加到 48，另加 10pt 命中外扩。
    static let cornerSize: CGFloat = 48
    /// 角块的命中外扩（手指落点容错），侧条 / 底边条用小一点的外扩
    static let cornerHitSlop: CGFloat = 10
    /// V0.0.56：条状手柄的外扩 4 → 6（手指落点容错再宽一点）
    static let barHitSlop: CGFloat = 6
    /// 命中判定 / 避让外扩距离。
    /// V0.0.45：不再把 `cornerSize` 算进来 —— 否则整圈窗外 48pt 都被判成浮窗，
    /// 会连带把 App 边缘的触摸一起吞掉。角块自己的命中走 `cornerHitSlop`。
    static var maxHandleMargin: CGFloat { return max(barThickness, bottomBarThickness) }

    /// 设备屏幕圆角（Stheno 读了 `_displayCornerRadius`，这里同源）。
    /// iPhone 15 Pro Max ≈ 55pt；取不到时用 55 兜底（比小圆角更接近真机观感）。
    ///
    /// 注意：这个 getter 返回的是 CGFloat 而不是对象，`perform` 会把标量当指针返回，
    /// 所以只能走 KVC（KVC 按属性类型编码包装成 NSNumber），并且先查 responds(to:)。
    static let deviceCornerRadius: CGFloat = {
        let screen = UIScreen.main
        let key = "_displayCornerRadius"
        if screen.responds(to: NSSelectorFromString(key)),
           let number = screen.value(forKey: key) as? NSNumber,
           number.doubleValue > 1, number.doubleValue < 200 {
            return CGFloat(number.doubleValue)
        }
        return 55
    }()

    /// 浮窗圆角（V0.0.42，AevonFloatLookV42）。
    ///
    /// Stheno 的浮窗圆角随内容缩放同比变化（逆向键 `_radius` / `radiusLast` 与其
    /// `_displayCornerRadius` 同现）—— 内容缩小多少，圆角就缩小多少，视觉上才和
    /// 设备本身的圆角「同族」。写死 12pt 会让小窗看起来像方盒子。
    static func cornerRadius(forWidth width: CGFloat) -> CGFloat {
        let screen = UIScreen.main.bounds
        let screenWidth = max(1, screen.width)
        let scale = max(0.2, min(1.0, width / screenWidth))
        return max(14, min(deviceCornerRadius * scale * 0.75, 36))
    }

    /// 统一套圆角（V0.0.44）：拖动中每帧也会走这里，尺寸一变圆角立刻同步，
    /// 不会再出现「缩放时直角、抬手才圆」。
    static func applyRadius(to clip: UIView, width: CGFloat) {
        let radius = cornerRadius(forWidth: width)
        if abs(clip.layer.cornerRadius - radius) > 0.2 {
            clip.layer.cornerRadius = radius
        }
    }

    /// 投影浓度（拖动期间会被临时清零，抬手恢复）
    static let shadowOpacity: Float = 0.42

    /// 全局唯一的偏好域，和设置面板共用
    private static let prefsSuite = "com.Aevon"
    /// Stheno 式全局几何记忆键（medusaFrameLast 对应物）
    private static let frameMemoryKey = "MedusaFrameLast"

    private let contentClip = UIView()
    private let hintLabel = UILabel()

    /// V0.0.43：手势区只剩「左右侧条 + 底边条 + 两个下角块」。各自持有引用，
    /// 因为贴边时要按「离屏边多远」把它们从窗外挪到窗内（`layoutGestureHandles`）。
    private let leftBar = AevonEdgeHandleView(frame: .zero)
    private let rightBar = AevonEdgeHandleView(frame: .zero)
    private let bottomBar = AevonEdgeHandleView(frame: .zero)
    private let bottomLeftCorner = AevonEdgeHandleView(frame: .zero)
    private let bottomRightCorner = AevonEdgeHandleView(frame: .zero)
    private var gestureHandles: [AevonEdgeHandleView] {
        return [leftBar, rightBar, bottomBar, bottomLeftCorner, bottomRightCorner]
    }

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

    /// 窗口正在被**移动**（不是缩放）。V0.0.56（AevonMoveSmoothV56）。
    ///
    /// 用户 Aevon(50) 第 1 条：「主悬浮窗滑动底部移动位置时，前 1.5 秒会卡顿，
    /// 然后才恢复正常」。移动期间每帧只有 `center` 在变，但窗口有一层
    /// `shadowRadius=16` 的离屏高斯模糊投影 —— 位置一变就要重新合成一整张阴影位图，
    /// 叠在「跨进程场景图层整体位移」上，正好把主线程和渲染线程都压住。
    /// 缩放早就用 `shadowOpacity = 0` 规避了（V0.0.45），移动这一路一直漏着。
    /// 这里在**真正产生位移**的那一刻关投影，抬手立刻恢复。
    private var isLiveMoving = false

    /// 上一次写过的投影路径参数（V0.0.56：幂等化，避免每帧重建 CGPath）
    private var lastShadowBounds: CGRect = .null
    private var lastShadowRadius: CGFloat = -1

    /// 几何动画进行中（V0.0.48，AevonGeomAnimV48）。
    ///
    /// 停靠 / 还原 / 开关窗的动画由 `animateGeometry` 统一驱动，动画期间
    /// `layoutSubviews` 必须闭嘴 —— 否则它会把 `contentClip.frame` 与
    /// `sceneHost.container.transform` 立刻写成**最终值**，而窗口 frame 还在动画途中，
    /// 于是内容先缩成一小块、四周露出窗口黑底，再在动画结束的瞬间对齐。
    /// 这正是 Aevon(41) 第 1 条「停靠成小窗时先黑屏再出现画面」的根因。
    private var isAnimatingGeometry = false

    /// 停靠列的重排目标 y（V0.0.50）。
    /// 缩放动画期间到来的重排请求先存这里，动画结束再补做 —— 否则会被 `isAnimatingGeometry` 丢掉。
    private var pendingDockY: CGFloat?
    /// 正在播退场动画（关窗），期间不接受任何手势
    private(set) var isDismissing = false
    /// 退场动画开始前已经落盘过几何（teardown 里不要再用缩小后的 frame 覆盖它）
    private var geometryPersistedBeforeDismiss = false
    /// 上一次真正应用过的内容区尺寸与缩放系数（缓存，用来跳过无变化的布局）
    private var lastClipSize: CGSize = .zero
    private var lastAppliedScale: CGFloat = 0
    /// V0.0.57（AevonContentFitV57）：上一次应用过的内容偏移（等比完整适配后居中）
    private var lastContentOffset: CGPoint = CGPoint(x: -1, y: -1)
    /// V0.0.55（AevonAdaptiveContentV55）：上一次用的「内容来源尺寸」
    /// —— V0.0.57 起固定是整屏尺寸（不再改场景 / 窗口）。
    private var lastSourceSize: CGSize = .zero

    /// 合帧用的待处理拖拽目标（V0.0.45，AevonFloatSmoothV45）。
    ///
    /// 触摸事件在 15 Pro Max 上最高 120Hz，而且一个 vsync 里可能来好几条 move；
    /// V0.0.44 是**每条 move 都同步改一次 frame** → 一帧里布局 2~4 次、
    /// 还带一次 `contentClip` 圆角重算，真机上就是「画面一卡一卡」。
    /// 现在触摸只记目标点，由 CADisplayLink 每个刷新周期应用一次（最多 120Hz）。
    private var pendingDragPoint: CGPoint?
    private var dragLink: CADisplayLink?
    /// 本次缩放实际提交了多少帧（日志证据：确认合帧生效）
    private var resizeStepCount = 0

    /// 当前吸附槽位（自由位置 / 靠左 / 靠右 / 靠顶）
    private(set) var currentSlot: AevonSnapSlot = .free

    /// 停靠成小窗之前的几何（V0.0.44）：轻点已停靠的小窗时用它还原主悬浮窗
    private var preDockFrame: CGRect?

    /// 上一次停靠所在的侧（V0.0.53，AevonDockKeepSideV53）。
    ///
    /// 还原后 `currentSlot` 会变回 `.free`，于是「这个窗原本属于哪一列」的信息就丢了。
    /// 下次它被 `demoteMainWindows` 降级时只能按当前位置猜 —— 落在屏幕中间就默认右侧，
    /// 用户看到的就是 Aevon(46) 第 4 条的「自动吸附到另一侧、原侧出现缺口」。
    /// 记住它，降级时回到原列。
    private(set) var lastDockSide: AevonSnapSlot = .free

    /// 进入停靠列的时间戳（V0.0.54，AevonDockOrderV54）。
    ///
    /// Aevon(47) 第 6 条：「快速点击 2、3、4 位置的停靠小窗时，会出现排列的缺口，
    /// 但 1 秒内会自动补齐」。
    ///
    /// 根因：`relayoutDockedColumn` 原来按 `frame.minY` 给这一列排序。可停靠动画要跑 0.42s，
    /// 快速连点时参与排序的是**动画中间值** —— 一个刚被降到第 4 格的窗此刻还飘在屏幕中间，
    /// 就被排到队尾，于是每格都对自己错位（缺口）；等动画跑完 `pendingDockY` 再补一次，
    /// 就是用户说的「1 秒内自动补位」。
    /// 现在排序只看「谁先进入这一列」（单调时间戳），与画面位置彻底解耦。
    private(set) var dockSeq: CFTimeInterval = 0

    /// 是否处于停靠状态（被别的浮窗当作「要避让的障碍」）
    var isDocked: Bool { return currentSlot != .free }

    init(sceneHost: AevonSceneHost, bundleID: String, title: String, slot: AevonSnapSlot = .free) {
        self.bundleID = bundleID
        self.sceneHost = sceneHost
        super.init(frame: CGRect.zero)

        let screen = UIScreen.main.bounds
        let aspect = AevonWindowView.contentAspect

        // 分屏时用吸附槽位算位置；否则恢复 Stheno 式全局记忆（medusaFrameLast 方案）
        var sizeSource = "默认尺寸"
        let restored: CGRect
        if slot != .free {
            restored = AevonSnap.frame(for: slot, from: AevonWindowView.defaultFrame())
            currentSlot = slot
            sizeSource = "吸附\(AevonSnap.describe(slot))"
        } else {
            let fallback = AevonWindowView.defaultFrame()
            let remembered = AevonWindowView.rememberedFrame(fallback: fallback)
            restored = AevonSnap.clamped(remembered)
            if remembered != fallback { sizeSource = "已恢复上次几何（全局记忆）" }
        }

        // V0.0.47（AevonNoPushV47）：新开窗也**不再**被已停靠小窗推开。
        // Aevon(40) 第 4 条明确「自动避让让主悬浮窗随意挪动位置，很不合理」——
        // 位置只由记忆几何 + 用户操作决定，重叠了用户自己拖一下即可。
        frame = AevonSnap.clamped(restored)

        backgroundColor = .clear
        // V0.0.37：窗口本体不裁剪 —— 外侧手势区要伸到 frame 外面；
        // 圆角裁剪由 contentClip 负责。
        clipsToBounds = false

        // V0.0.42（AevonFloatLookV42）：Stheno 观感 —— 投影 + 细描边 + 随缩放同比的圆角。
        // 投影走 shadowPath（每次 layout 更新），比让系统按 alpha 逐帧算便宜得多。
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = AevonWindowView.shadowOpacity
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 8)

        // 内容区（全高，无标题栏）。圆角 + 裁剪都在这一层。
        contentClip.frame = bounds
        contentClip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentClip.clipsToBounds = true
        contentClip.layer.cornerRadius = AevonWindowView.cornerRadius(forWidth: restored.width)
        contentClip.layer.cornerCurve = .continuous
        // V0.0.44（AevonFloatEdgeGlowV44）：四周一圈浅白描边。
        // 用户 Aevon(38)：「白色描边有点宽，修改的细一点」——0.9pt/34% → 0.5pt/26%，
        // 细到几乎只是一道高光线，深色背景依然能分辨边界。
        contentClip.layer.borderWidth = 0.5
        contentClip.layer.borderColor = UIColor(white: 1.0, alpha: 0.26).cgColor
        contentClip.backgroundColor = UIColor(white: 0.10, alpha: 1.0)
        addSubview(contentClip)

        contentClip.addSubview(sceneHost.container)

        // 等待画面提示（拿到第一帧后自动消失）
        hintLabel.frame = contentClip.bounds
        hintLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.textColor = UIColor(white: 0.85, alpha: 1.0)
        hintLabel.font = UIFont.systemFont(ofSize: 13)
        hintLabel.text = "正在等待 App 画面…\n若一直停在这里，请把 /var/mobile/Aevon.log 发给开发者"
        contentClip.addSubview(hintLabel)

        sceneHost.onFirstContent = { [weak self] in
            DispatchQueue.main.async {
                self?.hintLabel.isHidden = true
            }
        }

        // V0.0.43（AevonSthenoGestureV43）：顶部 ✕ 已移除（用户要求），
        // 关闭浮窗改成「底边手势区双击」。这里只装手势区，不加任何窗内控件 ——
        // 窗内 100% 留给 App 内容。
        installGestureHandles()
        layoutGestureHandles()

        AevonLog.info("[窗口] 浮窗外壳已创建 \(bundleID)"
            + "（无标题栏，侧条长按移动/轻点停靠或还原、底边拖动移动/双击关闭、下角拖动缩放（轻点无动作），"
            + (AevonSnap.fullContentEnabled
               ? "内容模式=完整显示（窗口按屏幕比例，整屏等比缩放，顶栏/底栏/右侧工具栏全在，永不裁切），"
               : "内容模式=小胖屏铺满（0.600 小胖屏，铺满裁切、内容按宽度铺满、底部溢出裁掉），")
            + "内容比例 \(String(format: "%.3f", aspect))（AevonContentFitV57），"
            + "内容 \(Int(restored.width))x\(Int(restored.height))，"
            + "\(sizeSource)）（AevonSthenoGestureV44 AevonFatWindowV52）")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 无记忆时的默认几何（V0.0.43）：走 `AevonSnap.defaultFrame()` —— 屏宽 55%。
    private static func defaultFrame() -> CGRect {
        return AevonSnap.defaultFrame()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // V0.0.48（AevonGeomAnimV48）：动画期间几何全部由动画块驱动，这里一律不动，
        // 否则就会「内容先缩成小块 → 黑屏 → 动画结束才出现画面」。
        if isAnimatingGeometry { return }
        // V0.0.44：缩放改成「实时改 frame」，所以这里必须照常布局 ——
        // 以前缩放期间直接 return，正是「缩放中四角变直角、抬手才跳回圆角」的来源。
        if contentClip.frame != bounds {
            contentClip.frame = bounds
        }
        // 几何一变就重算手势区位置（贴边时改挂到窗内）
        layoutGestureHandles()
        // 圆角随尺寸走（Stheno radiusLast 体系）。
        // V0.0.45（AevonFloatSmoothV45）：**缩放期间不再每帧改圆角** ——
        // 圆角 = 一层带 mask 的离屏合成，尺寸每一帧都在变就每一帧都要重建遮罩，
        // 真机上就是「画面一卡一卡」的主因之一。拖动期间圆角固定在起始值（一样是圆的，
        // 不会出现 V0.0.43 的直角问题），抬手时再一次性对到最终值。
        if !isLiveResizing {
            let radius = AevonWindowView.cornerRadius(forWidth: bounds.width)
            if abs(contentClip.layer.cornerRadius - radius) > 0.3 {
                contentClip.layer.cornerRadius = radius
            }
        }
        // 拖动 / 缩放期间不做投影路径（每帧重建 bezier 是纯粹的浪费，且会被离屏合成）
        if !isLiveResizing {
            updateShadowPath()
        }
        applyContentScale()
    }

    // MARK: - 几何动画（V0.0.48，AevonGeomAnimV48 / AevonFloatAnimV48）

    /// 统一的几何动画：窗口 frame、内容裁剪框、场景缩放**同一条曲线、同一个块**里走。
    ///
    /// 关键在于 `sceneHost.container.transform` 必须跟窗口一起插值 ——
    /// 内容可视大小 = 窗口宽 ×（窗口宽 ÷ 屏宽），两者必须同比例变化。
    /// 旧版（V0.0.47 及以前）只动画了窗口 frame，而 `applyContentScale` 在
    /// `layoutSubviews` 里立刻把 scale 写成最终值，于是中间态是「窗口还是大的、
    /// 内容已经缩成一小块」，四周露出窗口背景 —— 即 Aevon(41) 说的
    /// 「停靠成小窗时先黑屏，然后才出现画面」。
    /// 立即打断进行中的几何动画，把窗口落到动画终点（V0.0.53，AevonDockForceV53）。
    ///
    /// 用于「只允许一个主悬浮窗」：上一个窗的还原动画还没跑完，用户又去点别的小窗，
    /// 必须先把这个正在动画的窗**当场收成停靠小窗**，否则两个主窗会同时在屏上。
    /// `removeAllAnimations()` 会让图层直接取 model 值（也就是动画终点），不会跳回起点。
    private func interruptGeometryAnimation() {
        guard isAnimatingGeometry else { return }
        layer.removeAllAnimations()
        contentClip.layer.removeAllAnimations()
        sceneHost.container.layer.removeAllAnimations()
        isAnimatingGeometry = false
        lastAppliedScale = -1
        pendingDockY = nil
        setNeedsLayout()
        layoutIfNeeded()
        updateShadowPath()
        if layer.shadowOpacity < 0.01 { layer.shadowOpacity = AevonWindowView.shadowOpacity }
        AevonLog.info("[窗口] 已打断进行中的几何动画，立即落到目标几何"
            + "（避免两个主悬浮窗同时存在，AevonDockForceV53）")
    }

    func animateGeometry(to target: CGRect,
                         duration: TimeInterval = AevonMotion.dockDuration,
                         alpha targetAlpha: CGFloat? = nil,
                         spring: Bool = true,
                         damping: CGFloat = AevonMotion.dockDamping,
                         completion: (() -> Void)? = nil) {
        guard target.width > 1, target.height > 1 else { completion?(); return }
        isAnimatingGeometry = true
        // V0.0.57（AevonContentFitV57）：动画中间态与 `applyContentScale` 必须用**同一条**
        // 公式（等比完整适配 + 居中），否则动画期按一套、落位按另一套，结束瞬间会跳一下。
        let source = sceneHost.sourceSize
        // V0.0.51（AevonDockNoTopBarV51）：停靠态顶部留白为 0，内容直接铺到顶边。
        let topPad = self.isDocked ? AevonSnap.dockTopPadding : AevonSnap.contentTopPadding
        let fill = self.isDocked || !AevonSnap.fullContentEnabled
        let layout = AevonSnap.contentLayout(windowSize: target.size, topPad: topPad,
                                             source: source, fill: fill)
        let scale = layout.scale
        let offset = layout.offset
        let container = sceneHost.container
        let radius = AevonWindowView.cornerRadius(forWidth: target.width)
        let clipTarget = CGRect(origin: .zero, size: target.size)
        // 锚点必须是左上角，否则动画块里设的 position 会算偏
        if container.layer.anchorPoint != .zero {
            container.layer.anchorPoint = .zero
        }

        // V0.0.50（AevonDockShadowV50）：这里是「点边缘变停靠小窗时屏幕右边冒出一块黑色阴影」的根因。
        //
        // `layer.shadowPath` 只在 `layoutSubviews` 里按当前 bounds 重算，而动画期间
        // layoutSubviews 被 `isAnimatingGeometry` 拦住了 —— 于是整个停靠动画期间，
        // 投影用的还是**主窗尺寸**（266×560）的圆角矩形路径。窗口本身已经缩到 82 宽并
        // 贴到右边，阴影却仍按 266 宽画，尾部直接溢出屏外，看起来就是右侧一块死黑。
        // 动画一结束 layoutSubviews 重算路径，黑影立刻消失 —— 正是用户描述的
        // 「停靠小窗出现时阴影消失」。
        // 修法：动画期间投影整体淡出，落位后再按新尺寸重算路径并淡入。
        let savedShadowOpacity = layer.shadowOpacity
        let steps: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.frame = target
            self.contentClip.frame = clipTarget
            self.contentClip.layer.cornerRadius = radius
            self.layer.shadowOpacity = 0
            container.transform = CGAffineTransform(scaleX: scale, y: scale)
            container.layer.position = offset
            if let a = targetAlpha { self.alpha = a }
            self.layoutGestureHandles()
        }
        let done: (Bool) -> Void = { [weak self] _ in
            guard let self = self else { completion?(); return }
            self.isAnimatingGeometry = false
            // 缓存失效，让下一次布局把最终值再对一遍（值与动画终点相同，不会跳）
            self.lastAppliedScale = -1
            self.setNeedsLayout()
            self.layoutIfNeeded()
            // 几何已落定：按新 bounds 写一次 shadowPath，再让投影淡回来
            self.updateShadowPath()
            if savedShadowOpacity > 0.001 {
                UIView.animate(withDuration: 0.18, delay: 0,
                               options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.layer.shadowOpacity = savedShadowOpacity
                }
            }
            // 动画期间被挡下的停靠列重排：现在补做（带弹簧，不会瞬移）
            if let pending = self.pendingDockY {
                self.pendingDockY = nil
                self.setDockedY(pending)
            }
            // V0.0.56：几何落定 → 同步主窗矩形给 Guard
            AevonEntryHost.syncFloatRectToGuard()
            completion?()
        }
        if spring {
            UIView.animate(withDuration: duration, delay: 0,
                           usingSpringWithDamping: damping,
                           initialSpringVelocity: 0.2,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: steps, completion: done)
        } else {
            UIView.animate(withDuration: duration, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                           animations: steps, completion: done)
        }
    }

    /// 开窗入场（V0.0.48）：从下方 22pt 浮上来 + 淡入。
    ///
    /// 入场**只动位置和透明度、不动尺寸** —— 尺寸一变就要跑一遍内容缩放，
    /// 反而容易在第一帧闪一下。停靠 / 还原才需要真正的尺寸动画。
    func playEntryAnimation() {
        let target = frame
        guard target.width > 1, target.height > 1 else { return }
        // 入场**不**设 `isAnimatingGeometry`：尺寸没变，必须让 layoutSubviews 正常跑一次，
        // 否则 `applyContentScale` 永远不会执行，第一帧内容会以 1:1 尺寸塞进小窗里。
        alpha = 0
        frame = CGRect(x: target.minX, y: target.minY + 28,
                       width: target.width, height: target.height)
        layoutIfNeeded()
        // V0.0.49（AevonFineMotionV49）：透明度与位移**分两条曲线**。
        // 原来两者共用一条 0.34s 弹簧 —— 前 40% 画面还是半透明的，像"从黑里浮出来"，
        // 这就是 Aevon(42) 说的"生硬"。现在内容 0.20s 先"睁眼"（easeOut），
        // 位置再用 0.42s 弹簧慢慢落位，两层叠起来才像系统卡片。
        UIView.animate(withDuration: AevonMotion.entryFadeDuration,
                       delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = 1
        }
        UIView.animate(withDuration: AevonMotion.entryDuration, delay: 0,
                       usingSpringWithDamping: AevonMotion.entryDamping,
                       initialSpringVelocity: 0.25,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.frame = target
        } completion: { _ in
            self.alpha = 1
            self.lastAppliedScale = -1
            self.setNeedsLayout()
        }
    }

    /// 关窗退场（V0.0.48）：缩到 94% + 淡出，动画结束再真正拆视图。
    func playDismissAnimation(completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        isUserInteractionEnabled = false
        stopDragLink()
        activeGrab = nil
        // 几何必须在动画前落盘：动画会把 frame 改成缩小后的值
        persistFrame()
        geometryPersistedBeforeDismiss = true
        // V0.0.49（AevonFineMotionV49）：退场从「0.18s 线性 + 缩到 94%」改成
        // 「0.24s 弹簧（damping 0.98，几乎不过冲）+ 缩到 90%」。
        // 原来收得太快太浅，观感像"卡了一下就没了"；现在是明确的"收住再消失"。
        let target = AevonWindowView.scaledFrame(frame, ratio: AevonMotion.dismissScaleRatio)
        animateGeometry(to: target,
                        duration: AevonMotion.dismissDuration,
                        alpha: 0,
                        damping: AevonMotion.dismissDamping) { [weak self] in
            self?.isDismissing = false
            completion()
        }
    }

    /// 以原中心为基准按比例缩放一个 frame
    static func scaledFrame(_ frame: CGRect, ratio: CGFloat) -> CGRect {
        let w = max(1, frame.width * ratio)
        let h = max(1, frame.height * ratio)
        return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
    }

    /// 投影路径与圆角矩形严格一致，避免系统按 alpha 逐帧重算（滚动 App 画面时开销很大）
    ///
    /// V0.0.56（AevonMoveSmoothV56）：**幂等化**。
    /// 以前每次 `layoutSubviews` 都无条件新建一条 CGPath 并赋值给 `layer.shadowPath` ——
    /// 即使几何一点没变，CA 也会认为路径变了，重新做一次离屏高斯模糊。
    /// 拖动 / 缩放这种高频布局场景下，这就是「移动窗口时画面一卡一卡」的直接原因。
    private func updateShadowPath() {
        let radius = contentClip.layer.cornerRadius
        if lastShadowBounds == bounds, abs(lastShadowRadius - radius) < 0.05 { return }
        lastShadowBounds = bounds
        lastShadowRadius = radius
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
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
            if !handle.isHidden, handle.alpha > 0.01,
               handle.frame.insetBy(dx: -AevonWindowView.barHitSlop,
                                    dy: -AevonWindowView.barHitSlop).contains(point) {
                return true
            }
        }
        return false
    }

    /// 把整屏尺寸的容器等比铺进内容区，并把顶部状态栏那条空白裁掉。
    ///
    /// V0.0.44（AevonSthenoDockV44）：`scale` 只由宽度决定，场景整体上移
    /// `visualTopInset * scale` —— 宿主 App 不画状态栏，那块在浮窗里是纯空白，
    /// 上移之后窗口顶部就是 App 真正的第一行内容（用户 Aevon(37) 的核心抱怨）。
    ///
    /// V0.0.52（AevonFitContentV52）：**改成宽高双向完整适配**。
    /// Aevon(45)：「复刻的 Stheno 多形态窗口改成小胖屏时，内容展示不完整，
    /// 丢失下半部分（例如应用底栏）」—— 旧公式只管宽度，窗口一矮内容就纵向溢出，
    /// 底栏被 `clipsToBounds` 直接吃掉。现在取「按宽度」与「按高度」两个比例的**较小值**：
    /// 内容永远完整，宽度方向多余的部分左右均分（窗口深色底），高度方向贴顶不留白。
    private func applyContentScale() {
        let clipSize = contentClip.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }

        // V0.0.57（AevonContentFitV57）：这里**不再**请求改 App 场景尺寸 / 改 App 窗口。
        //
        // Aevon(51) 的日志与截图把 V0.0.55/V0.0.56 两条路都判死了：
        //   · 改场景 frame：只裁渲染视口（App 的 UIWindow 还是 430×932），内容按整屏
        //     排版、视口只露左 62% → 「字变大 + 右边被切 + 抖音右侧工具栏不显示」；
        //   · 在 App 进程改 keyWindow.frame：抖音这类按 UIScreen 排版的 App 依旧错位，
        //     而且关窗后会残留小窗口 → 全屏打开大面积黑屏（第 4 条）。
        // 现在回到 Stheno 的做法（`containerScale` / `finalScale`）：整屏画面等比缩放，
        // 只做「完整适配」，任何情况下都不裁切。
        let source = sceneHost.sourceSize
        // V0.0.51（AevonDockNoTopBarV51）：停靠小窗顶部不留深色边（那是一条死黑）。
        let topPad = isDocked ? AevonSnap.dockTopPadding : AevonSnap.contentTopPadding
        // 停靠小窗是缩略图 → 铺满（cover）；主窗在「完整显示」开启时 → 等比完整适配。
        let fill = isDocked || !AevonSnap.fullContentEnabled

        let layout = AevonSnap.contentLayout(windowSize: clipSize, topPad: topPad,
                                             source: source, fill: fill)
        let scale = layout.scale
        let offset = layout.offset

        if abs(clipSize.width - lastClipSize.width) < 0.01,
           abs(clipSize.height - lastClipSize.height) < 0.01,
           abs(scale - lastAppliedScale) < 0.0001,
           abs(offset.x - lastContentOffset.x) < 0.5,
           abs(offset.y - lastContentOffset.y) < 0.5,
           abs(source.width - lastSourceSize.width) < 0.5,
           abs(source.height - lastSourceSize.height) < 0.5 {
            return
        }
        lastClipSize = clipSize
        lastAppliedScale = scale
        lastContentOffset = offset
        lastSourceSize = source

        let container = sceneHost.container
        // anchorPoint 只在第一次设一次：每帧写它会让 CA 重算 position，纯浪费
        if container.layer.anchorPoint != .zero {
            container.layer.anchorPoint = .zero
        }
        let targetBounds = CGRect(origin: .zero, size: source)
        if container.bounds != targetBounds {
            container.bounds = targetBounds
        }
        container.transform = CGAffineTransform(scaleX: scale, y: scale)
        container.layer.position = offset
    }

    // MARK: - 手势区（V0.0.43，AevonSthenoGestureV43）

    /// 建立五个手势区并挂上（位置由 `layoutGestureHandles` 每次布局重算）：
    ///   · 左右侧条 → 长按/拖动 = 移动，轻点 = 停靠到该侧并变小窗；
    ///   · 底边条   → 双击 = 关闭浮窗；
    ///   · 两个下角块 → 拖动 = 对角缩放（顶部两个角块与顶边条按用户要求删除）。
    /// 全部不挂 `UIGestureRecognizer`：手势统一由全局触摸通道驱动
    /// （全屏 App 里视图层的识别器根本收不到窗外触摸，Aevon(34) 已确证）。
    private func installGestureHandles() {
        let specs: [(AevonEdgeHandleView, UIRectEdge)] = [
            (leftBar, [.left]),
            (rightBar, [.right]),
            (bottomBar, [.bottom]),
            (bottomLeftCorner, [.bottom, .left]),
            (bottomRightCorner, [.bottom, .right]),
        ]
        for (handle, edges) in specs {
            handle.edges = edges
            handle.backgroundColor = .clear
            addSubview(handle)
        }
    }

    /// 按窗口当前离屏幕四边多远，决定每个手势区挂在窗外还是窗内。
    ///
    /// 为什么必须动态：贴边距离现在只有 5pt，外侧条（18pt 宽）会整条滑出屏外 ——
    /// 窗口一旦贴到左边，左手就再也点不到它（V0.0.42 用户正是卡在「贴边后无法缩放」）。
    /// 规则很简单：某条边离屏边不足一个条宽，就把这条边的手柄改挂到窗**内侧**。
    private func layoutGestureHandles() {
        let b = AevonWindowView.barThickness
        let bb = AevonWindowView.bottomBarThickness
        let c = AevonWindowView.cornerSize
        let w = bounds.width
        let h = bounds.height
        guard w > 1, h > 1 else { return }
        let screen = UIScreen.main.bounds
        // frame 就是浮窗层坐标（= 屏幕坐标），直接算到屏边的距离
        let gapLeft = frame.minX
        let gapRight = screen.width - frame.maxX
        let gapBottom = screen.height - frame.maxY

        let sideInsetL: CGFloat = gapLeft < b ? 0 : -b
        let sideInsetR: CGFloat = gapRight < b ? w - b : w
        // 下角块是否也要挪进窗内（取决于横向/纵向是否贴边）
        let cornerInsetL: CGFloat = gapLeft < c ? 0 : -c
        let cornerInsetR: CGFloat = gapRight < c ? w - c : w
        let cornerY: CGFloat = gapBottom < c ? h - c : h

        // 侧条在底部给底边条留出整条空间（避免两套手势帧重叠）
        //
        // V0.0.56（AevonMoveSmoothV56）：改成幂等写入 —— 移动时每帧都会走到这里，
        // 而 `view.frame = 相同值` 仍会让 UIKit 走一遍 setFrame → 标记布局。
        // 拖动时的「卡」有一部分就来自每帧 5 次无意义的手柄重排。
        let sideHeight = max(40, h - bb)
        setHandleFrame(leftBar, CGRect(x: sideInsetL, y: 0, width: b, height: sideHeight))
        setHandleFrame(rightBar, CGRect(x: sideInsetR, y: 0, width: b, height: sideHeight))
        setHandleFrame(bottomLeftCorner, CGRect(x: cornerInsetL, y: cornerY, width: c, height: c))
        setHandleFrame(bottomRightCorner, CGRect(x: cornerInsetR, y: cornerY, width: c, height: c))

        // 底边条夹在两个下角块之间，厚度用 bottomBarThickness（用户要求加宽）
        let barLeft: CGFloat = gapLeft < c ? c : 0
        let barRight: CGFloat = gapRight < c ? w - c : w
        let barY: CGFloat = gapBottom < bb ? h - bb : h
        setHandleFrame(bottomBar, CGRect(x: barLeft, y: barY,
                                         width: max(40, barRight - barLeft), height: bb))
    }

    /// 手柄 frame 幂等写入（值没变就完全不碰 UIKit 布局）
    private func setHandleFrame(_ handle: UIView, _ rect: CGRect) {
        if handle.frame == rect { return }
        handle.frame = rect
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
    func grab(at layerPoint: CGPoint) -> AevonFloatGrab? {
        guard let parent = superview else { return nil }
        let local = convert(layerPoint, from: parent)
        // V0.0.50（AevonDockNoMoveV50）：停靠小窗**不做任何手柄命中**。
        //
        // 用户 Aevon(43)：「停靠的小窗无法被手动移动（避免与呼出圆盘手势冲突），
        // 只能通过点击卡片还原成主悬浮窗」。
        // 旧实现下停靠小窗贴右边，右侧 20pt 侧条正好压在「边缘左滑呼出圆盘」的热区上，
        // 于是用户想划出圆盘，结果把小窗拖走了。现在整窗只有一种交互：
        // 轻点 = 还原主窗（拖动 / 缩放 / 底边双击全部停用）。
        if isDocked {
            return bounds.contains(local) ? .body : nil
        }
        // 命中顺序：角块 → 底边条 → 左右侧条。角块最具体，先判；
        // 侧条帧比底边条长，放最后才不会把底边条整条吃掉。
        let order: [AevonEdgeHandleView] = [bottomLeftCorner, bottomRightCorner,
                                            bottomBar, leftBar, rightBar]
        for handle in order {
            guard !handle.isHidden, handle.alpha > 0.01 else { continue }
            // V0.0.45（AevonCornerHotV45）：角块外扩 10pt 命中容错 ——
            // 「右下角缩放手势不灵敏」的直接原因就是必须精确压在 36pt 方块上。
            let slop = handle.isCorner ? AevonWindowView.cornerHitSlop : AevonWindowView.barHitSlop
            guard handle.frame.insetBy(dx: -slop, dy: -slop).contains(local) else { continue }
            if handle.isCorner { return .corner(handle.edges) }
            if handle === bottomBar { return .bottom }
            return .side(handle.edges)
        }
        return nil
    }

    /// 开始一段外部驱动的拖拽。`layerPoint` = 浮窗层（屏幕）坐标。
    func grabBegin(_ grab: AevonFloatGrab, at layerPoint: CGPoint) {
        guard let parent = superview else { return }
        activeGrab = grab
        switch grab {
        case .side, .bottom, .body:
            // 只记基准，不动几何：要「越过阈值」才真正开始移动，
            // 轻点（侧条=停靠 / 底边=双击关闭 / 窗身=还原）由全局通道判定后回调。
            moveOriginFrame = frame
            moveOriginPoint = layerPoint
        case .corner(let edges):
            resizeOriginFrame = frame
            resizeOriginPoint = layerPoint
            resizeOriginEdges = edges
            // 锚点取「不动的那些边」的交点：拖右 → 锚在左（x=0）；拖左 → 锚在右（x=1）
            let ax: CGFloat = edges.contains(.left) ? 1.0
                : (edges.contains(.right) ? 0.0 : 0.5)
            let ay: CGFloat = edges.contains(.top) ? 1.0
                : (edges.contains(.bottom) ? 0.0 : 0.5)
            // V0.0.54（AevonCornerNoFlashV54）：按下**不**进入实时缩放。
            //
            // Aevon(47) 第 1 条：「点击主悬浮窗右下角时，悬浮窗边缘会闪烁」。
            // 根因就在 `beginLiveResize`：它一进来就把 `layer.shadowOpacity` 归零
            // （为了拖动期不做离屏合成），抬手时 `finishEdgeResize` / `grabCancel` 又把它
            // 恢复 —— 于是一次「按下即抬起」的点击 = 投影消失再出现，看起来就是边缘闪两下。
            // 日志里每次点击都是「全局通道开始拖动（缩放）… 合帧 0 帧」，证实压根没拖。
            // 现在按下只记锚点，越过 10pt 阈值（`rebaseGrab`）才真正进入缩放，
            // 纯点击全程零视觉变化。
            resizeAnchor = CGPoint(x: ax, y: ay)
        }
        parent.bringSubviewToFront(self)
    }

    /// 侧条 / 底边条越过了「算拖动」的阈值：把基准点重设到当前位置。
    /// 不重设的话第一帧就会把窗口瞬移一个阈值距离（10pt），手感发跳。
    func rebaseGrab(at layerPoint: CGPoint) {
        guard let grab = activeGrab else { return }
        switch grab {
        case .side, .bottom, .body:
            moveOriginFrame = frame
            moveOriginPoint = layerPoint
        case .corner:
            // V0.0.54（AevonCornerNoFlashV54）：真正开始拖了才进入实时缩放
            // （关投影 + 定圆角只在这时做，纯点击不会再触发任何视觉变化）。
            beginLiveResize(anchor: resizeAnchor)
            // 基准点对齐到当前点，否则第一帧会按旧基准算出一段位移（窗口「跳一下」）
            resizeOriginFrame = frame
            resizeOriginPoint = layerPoint
        }
    }

    /// 拖动中。`layerPoint` = 浮窗层（屏幕）坐标。
    ///
    /// V0.0.45（AevonFloatSmoothV45）：这里**只记目标点**，真正的几何提交交给
    /// `stepDrag`（CADisplayLink，每个刷新周期一次）。原因见 `pendingDragPoint`。
    func grabUpdate(to layerPoint: CGPoint) {
        guard activeGrab != nil else { return }
        pendingDragPoint = layerPoint
        startDragLink()
    }

    /// 启动合帧定时器（幂等）
    private func startDragLink() {
        guard dragLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepDrag))
        link.add(to: .main, forMode: .common)
        dragLink = link
    }

    private func stopDragLink() {
        dragLink?.invalidate()
        dragLink = nil
        pendingDragPoint = nil
    }

    /// 每个刷新周期应用一次最新目标点（合帧）。
    @objc private func stepDrag() {
        guard let grab = activeGrab, let point = pendingDragPoint else { return }
        pendingDragPoint = nil
        // 关掉隐式动画：frame / transform 的隐式动画会让每一帧都排一个动画事务
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch grab {
        case .side, .bottom, .body:
            applyBarMove(to: point)
        case .corner(let edges):
            applyCornerResize(to: point, edges: edges)
            resizeStepCount += 1
        }
        CATransaction.commit()
    }

    /// 抬手。`commit` = false 表示这段拖拽被取消（不落盘几何）。
    func grabEnd(at layerPoint: CGPoint, commit: Bool) {
        guard let grab = activeGrab else { return }
        // V0.0.56：几何一变就把主窗矩形同步给 Guard（浮窗盖住的区域，App 一律别收到输入）
        defer { AevonEntryHost.syncFloatRectToGuard() }
        // 投影在抬手时恢复 —— 必须在下面可能触发的 snap / restore 动画之前，
        // 否则 animateGeometry 读到的 savedShadowOpacity 是 0，动画结束后投影就再也不回来了。
        if isLiveMoving {
            isLiveMoving = false
            layer.shadowOpacity = AevonWindowView.shadowOpacity
            AevonLog.info("[窗口] 移动结束：拖动全程关闭投影，抬手恢复"
                + "（投影离屏模糊 + 场景图层整体位移叠加 = 移动卡顿的主因）（AevonMoveSmoothV56）")
        }
        // 合帧可能把最后一段位移留在 pending 里 —— 抬手时用终点补一次，手感才不「掉尾」
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch grab {
        case .side, .bottom, .body:
            applyBarMove(to: layerPoint)
        case .corner(let edges):
            applyCornerResize(to: layerPoint, edges: edges)
        }
        CATransaction.commit()
        stopDragLink()
        activeGrab = nil
        switch grab {
        case .side:
            if commit, AevonPrefs.bool("SnapEnabled", default: true),
               let slot = AevonSnap.slot(for: frame) {
                snap(to: slot)
                return
            }
            // V0.0.47（AevonNoPushV47）：松手只夹屏幕边界，不再因为「别处有停靠小窗」而跳位置。
            // Aevon(40)：「自动避让停靠小窗会让主悬浮窗随意挪动位置，很不合理」——
            // 手指放下的地方就是最终位置，重叠由用户自己摆。
            if commit {
                frame = AevonSnap.clamped(frame)
            }
            persistFrame()
        case .body:
            // V0.0.50（AevonDockNoMoveV50）：停靠小窗**不移动、不换边**。
            // 拖动一律无效（`applyBarMove` 也拦了一道），只有轻点才还原 —— 还原由
            // 全局通道的「轻点」判定直接调 `restoreMainWindow()`，不走这里。
            if isDocked { return }
            persistFrame()
        case .corner:
            finishEdgeResize()
        case .bottom:
            // 底边拖动 = 移动（用户 Aevon(37) 的新交互），贴底不再自动吸附
            if commit {
                // V0.0.47：同上，只夹边界，不做跨窗避让
                frame = AevonSnap.clamped(frame)
            }
            persistFrame()
        }
    }

    /// 取消当前拖拽（超时 / 系统打断 / 侧条其实只是轻点）：几何退回原样，不落盘。
    func grabCancel() {
        stopDragLink()
        if isLiveMoving {
            isLiveMoving = false
            layer.shadowOpacity = AevonWindowView.shadowOpacity
        }
        guard let grab = activeGrab else { return }
        activeGrab = nil
        switch grab {
        case .side, .bottom, .body:
            frame = moveOriginFrame
        case .corner:
            if isLiveResizing {
                isLiveResizing = false
                layer.shadowOpacity = AevonWindowView.shadowOpacity
                frame = AevonSnap.clamped(resizeOriginFrame)
                AevonWindowView.applyRadius(to: contentClip, width: frame.width)
                setNeedsLayout()
            }
        }
    }

    /// 移动的纯计算部分（V0.0.41 拆出来）：pan 手势与全局通道共用同一套夹边逻辑。
    ///
    /// V0.0.42（AevonSthenoDockV42）：夹边距离从原来的 60pt 改成 `AevonSnap.edgeInset`
    /// —— 拖到屏幕边上时窗口自动停在内侧，四个外角块始终留在屏内可抓。
    private func applyBarMove(to point: CGPoint) {
        // V0.0.50（AevonDockNoMoveV50）：停靠小窗禁止移动。
        // 这是「避免与呼出圆盘手势冲突」的落地点 —— 用户在停靠列上左滑本意是呼出圆盘，
        // 旧版会把这根手指当成拖动，小窗跟着跑。现在几何一格都不动。
        if isDocked { return }
        let dx = point.x - moveOriginPoint.x
        let dy = point.y - moveOriginPoint.y
        let screen = UIScreen.main.bounds
        var center = CGPoint(x: moveOriginFrame.midX + dx, y: moveOriginFrame.midY + dy)
        let halfW = moveOriginFrame.width / 2.0
        let halfH = moveOriginFrame.height / 2.0
        let inset = AevonSnap.edgeInset

        let minX = inset + halfW
        let maxX = screen.width - inset - halfW
        center.x = maxX >= minX ? min(max(center.x, minX), maxX) : screen.width / 2.0

        let minY = inset + halfH
        let maxY = screen.height - inset - halfH
        center.y = maxY >= minY ? min(max(center.y, minY), maxY) : screen.height / 2.0

        // 只改 center：bounds 不变，UIKit 不会触发 layoutSubviews，
        // 所以手势区的内外位置要手动跟着重算（贴边时侧条要挪进窗内）
        self.center = center
        // V0.0.56（AevonMoveSmoothV56）：真正产生位移的那一刻关投影（见 isLiveMoving）。
        // 只在这里关（不在 grabBegin），所以纯点击不会有「边缘闪一下」（AevonCornerNoFlashV54 的同样思路）。
        if !isLiveMoving, abs(dx) + abs(dy) > 0.5 {
            isLiveMoving = true
            layer.shadowOpacity = 0
        }
        // V0.0.45：这里不再每帧算避让 —— `AevonEntryHost.dockedObstacles()` 每次都会
        // 遍历所有窗并构造矩形，120Hz 下是纯浪费；避让改到抬手时做一次。
        layoutGestureHandles()
    }

    // MARK: - 下角块缩放（V0.0.36 起，V0.0.37 移到窗外角块，V0.0.43 只保留下角）

    /// 缩放的纯计算部分：**每帧直接改 frame**，不再用 transform。
    ///
    /// V0.0.44（AevonLiveResizeV44）：V0.0.12 起的「只改 transform、抬手才提交 frame」
    /// 在真机上有两个副作用（Aevon(37) 用户反馈）：
    ///   · 缩放期间视图被离屏栅格化，画面先变成一张「贴图快照」，抬手那一刻才跳回实时；
    ///   · 抬手时 transform→identity + 新 frame + 圆角重设，一次性大重排看起来就是卡一下。
    /// 现在每帧直接改 frame：圆角、内容比例、描边全部同步，画面全程实时，四角始终是圆的。
    private func applyCornerResize(to point: CGPoint, edges: UIRectEdge) {
        let dx = point.x - resizeOriginPoint.x
        let dy = point.y - resizeOriginPoint.y
        let width = clampedCornerWidth(dx: dx, dy: dy, base: resizeOriginFrame, edges: edges)
        let height = AevonSnap.height(forWidth: width)

        // 固定点 = 原始 frame 里锚点对应的那一点；新 frame 以它为基准反推 origin
        let anchor = resizeAnchor
        let fixed = CGPoint(x: resizeOriginFrame.minX + anchor.x * resizeOriginFrame.width,
                            y: resizeOriginFrame.minY + anchor.y * resizeOriginFrame.height)
        var target = CGRect(x: fixed.x - anchor.x * width,
                            y: fixed.y - anchor.y * height,
                            width: width, height: height)
        target = AevonSnap.clamped(target)
        // V0.0.45：拖动期间不做避让（见 applyBarMove 的说明），也**不每帧改圆角**——
        // 圆角遮罩重建是缩放卡顿的主要来源，抬手时在 finishEdgeResize 里一次到位。
        frame = target
    }

    /// 只有「宽度」一个自由度：高度 = 宽度 ÷ 屏幕比例。
    /// 角块横竖都在动，所以把横、纵两个方向的位移**都投影成宽度再取平均**。
    ///
    /// V0.0.46（AevonResizeSmoothV46）：这里是「缩放时突然抖动变大变小」的根因。
    /// 旧实现用 `abs(dx) >= abs(dy)` 在「按 X 算」和「按 Y 算」之间二选一 ——
    /// dx / dy 每帧都在微小抖动，一旦跨越这个判据就换公式，而两条公式给出的宽度
    /// 相差近一倍（aspect ≈ 0.49：横向 10pt 就是 10pt 宽，纵向 10pt 只有 4.9pt 宽），
    /// 于是手指几乎没动，窗口却突然跳大或跳小。取平均是连续的，永远不会跳。
    private func clampedCornerWidth(dx: CGFloat, dy: CGFloat, base: CGRect,
                                    edges: UIRectEdge) -> CGFloat {
        let aspect = AevonWindowView.contentAspect
        let screen = UIScreen.main.bounds
        // 纵向位移换算宽度时只能用「内容区高度」，上下留白不能算进去
        let contentHeight = max(1, base.height
            - AevonSnap.contentTopPadding - AevonSnap.contentBottomPadding)

        var estimates: [CGFloat] = []
        if edges.contains(.left) || edges.contains(.right) {
            let signed = edges.contains(.left) ? -dx : dx
            estimates.append(base.width + signed)
        }
        if edges.contains(.top) || edges.contains(.bottom) {
            let signed = edges.contains(.top) ? -dy : dy
            estimates.append((contentHeight + signed) * aspect)
        }
        var result = estimates.isEmpty ? base.width
            : estimates.reduce(0, +) / CGFloat(estimates.count)
        // 上限：不超屏高 92%，宽度不超屏宽 95%
        let maxWidth = max(AevonWindowView.minContentWidth,
                           min(screen.width * 0.95, screen.height * 0.92 * aspect))
        result = max(AevonWindowView.minContentWidth, min(result, maxWidth))
        return result
    }

    /// 进入「实时缩放」：记锚点、暂时关投影，圆角与裁剪一律保留。
    private func beginLiveResize(anchor: CGPoint) {
        if isLiveResizing { return }
        isLiveResizing = true
        resizeAnchor = anchor
        resizeStepCount = 0
        // 缩放期间关投影：带投影的活体场景在几何持续变化时会被离屏合成
        layer.shadowOpacity = 0
        // V0.0.44：圆角全程保留。以前这里把 cornerRadius 清 0 并关掉裁剪，
        // 于是「缩放中四角是直角、抬手才跳回圆角」——Aevon(37) 的第一个问题。
        // V0.0.45：保留的是**起始尺寸对应的圆角**（拖动期间不再逐帧改），
        // 所以整个缩放过程四角一直是圆的，同时不触发任何遮罩重建。
        contentClip.clipsToBounds = true
        AevonWindowView.applyRadius(to: contentClip, width: frame.width)
    }

    /// 抬手：收尾（几何已经在拖动过程中实时提交过，这里只做避让校正与落盘）。
    private func finishEdgeResize() {
        guard isLiveResizing else { return }
        isLiveResizing = false
        layer.shadowOpacity = AevonWindowView.shadowOpacity
        // V0.0.47（AevonNoPushV47）：缩放收尾只夹边界，不再被别的小窗推着跳
        frame = AevonSnap.clamped(frame)
        // 圆角一次对到最终尺寸；此时阴影路径与描边一并刷新
        AevonWindowView.applyRadius(to: contentClip, width: frame.width)
        setNeedsLayout()
        persistFrame()
        AevonLog.info("[窗口] 缩放到 \(Int(frame.width))x\(Int(frame.height))"
            + "（圆角 \(Int(contentClip.layer.cornerRadius)) · 全程实时渲染"
            + " · 拖动合帧已生效 \(resizeStepCount) 帧）（AevonLiveResizeV44 AevonFloatSmoothV45）")
    }

    // MARK: - 停靠 / 吸附

    /// 停靠到某一侧（V0.0.43：贴边 + 换成停靠档小尺寸）。
    ///
    /// 两个入口共用：
    ///   · 拖侧条贴边松手 → 自动吸附（`grabEnd` 里按 `AevonSnap.slot(for:)` 判定）；
    ///   · 轻点左右侧条 → 直接停靠到那一侧（用户在 Aevon(36) 指定的新交互）。
    ///
    /// V0.0.48（AevonDockColumnV48）：落点改走「同侧一列」模型 ——
    /// 第一个在屏幕垂直中心、后续向下排、放不下整列上移（Aevon(41) 第 4 条）。
    func snap(to slot: AevonSnapSlot, force: Bool = false) {
        // V0.0.53（AevonDockForceV53）：`force` 用于「只允许一个主窗」的强制降级 ——
        // 上一版这里遇到 `isAnimatingGeometry` 就直接 return，于是正在做还原动画的那个窗
        // 降级被静默跳过，屏幕上就出现了两个主悬浮窗（Aevon(46) 第 5 条）。
        if force { interruptGeometryAnimation() }
        guard slot != .free, !isLiveResizing, !isAnimatingGeometry else { return }
        // 记住这一侧：还原后再被降级时要回到同一列，不能按位置乱猜（Aevon(46) 第 4 条）
        lastDockSide = slot
        // V0.0.46（AevonDockTapRestoreV46）：从自由态进停靠时先记住主窗几何，
        // 之后轻点窗身还原能回到原来那个位置和大小。
        if !isDocked { preDockFrame = frame }
        // V0.0.54（AevonDockOrderV54）：记下进入这一列的时刻。
        // 重排 / 补位按它排序，而不是按动画中的 `frame.minY` —— 后者在快速连点时会算出缺口。
        if !isDocked { dockSeq = CACurrentMediaTime() }
        // 同侧已有的小窗（按纵向顺序），它们决定本窗落在这一列的第几格
        let peers = AevonEntryHost.dockedPeers(side: slot, excluding: self)
        // V0.0.50（AevonDockTop5V50）：这一侧已经排满 5 个 → 拒绝新的停靠。
        // 用户 Aevon(43)：「总数量只有 5 个」。不拒绝的话第 6 个会被挤到屏外，
        // 用户点不到也还原不了，等于丢了一个窗。
        if !isDocked, peers.count >= AevonSnap.dockMaxCount {
            persistFrame()
            AevonLog.info("[窗口] 停靠位已满，这一侧最多 \(AevonSnap.dockMaxCount) 个停靠小窗，"
                + "本次停靠已取消（保持主悬浮窗原样）（AevonDockTop5V50）")
            return
        }
        let target = AevonSnap.frame(for: slot, from: frame,
                                     obstacles: peers.map { $0.frame })
        guard target.width > 1, target.height > 0 else { return }

        // 目标与当前几乎一致就不折腾了（拖动松手时已经贴在位置上的情况）
        if abs(target.minX - frame.minX) < 0.5,
           abs(target.minY - frame.minY) < 0.5,
           abs(target.width - frame.width) < 0.5 {
            currentSlot = slot
            sceneHost.setContentInteraction(false)
            persistFrame()
            AevonEntryHost.relayoutDockedColumn(side: slot)
            return
        }

        currentSlot = slot
        // V0.0.55（AevonDockNoTouchV55）：停靠小窗的内容停止接收触摸 ——
        // 它的唯一操作是「轻点还原」，绝不能把手指转发进 App（Aevon(48) 第 4 条）。
        sceneHost.setContentInteraction(false)
        AevonLog.info("[窗口] 停靠小窗内容已停止接收触摸（轻点只还原主窗，不再转发进 App 合成点击）"
            + "（AevonDockNoTouchV55）")
        // V0.0.48：停靠走统一几何动画（弹簧 + 内容缩放同步），不再裸改 frame
        // V0.0.49（AevonFineMotionV49）：时长 / 阻尼统一走 AevonMotion（0.42s / 0.80）
        animateGeometry(to: target,
                        duration: AevonMotion.dockDuration,
                        damping: AevonMotion.dockDamping) { [weak self] in
            guard let self = self else { return }
            self.persistFrame()
            // 整列重排：把这一列的小窗按「中心锚点 + 向下生长」重新对齐
            AevonEntryHost.relayoutDockedColumn(side: slot)
        }
        AevonLog.info("[窗口] 停靠到\(AevonSnap.describe(slot)) \(Int(target.minX)),\(Int(target.minY)) "
            + "\(Int(target.width))x\(Int(target.height))"
            + "（贴边 \(Int(AevonSnap.edgeInset))pt · 停靠小窗小胖屏 3:5（0.60）· 顶部 10% 锚点向下第 "
            + "\(peers.count + 1) 格 / 最多 \(AevonSnap.dockMaxCount) 个 · 统一弹簧动效）"
            + "（AevonSthenoDockV44 AevonDockSizeV45 AevonDockTop5V50 AevonDockNoMoveV50 AevonFineMotionV49 AevonDockFatV53）")
    }

    /// 把自己挪到停靠列的指定纵向位置（V0.0.48，AevonGrowFromCenterV48）。
    ///
    /// 只改 y、不动尺寸 —— 内容缩放不变，所以不会出现停靠黑屏那种问题。
    func setDockedY(_ y: CGFloat) {
        guard isDocked, !isDismissing else { return }
        // V0.0.50（AevonDockFillAnimV50）：自己正在做停靠 / 还原的缩放动画时，
        // 不能同时改 frame（两段动画会互相覆盖，落点就偏了）。先记下来，动画结束补做。
        if isAnimatingGeometry {
            pendingDockY = y
            return
        }
        /* V0.0.57（AevonDockAtomicV57）：尺寸还没缩到停靠档时，不能只改 y。
         *
         * 旧实现直接 `t.origin.y = y` 再走 `AevonSnap.clamped(t)`，而 clamped 会按
         * **当前高度**把 y 夹回屏内：一个还停在 509pt 高的窗（缩放动画被打断后的中间态）
         * 被夹到 y=423，然后才慢慢变成 158 高 —— 画面上就是「某一格飘在屏幕中间」，
         * 也就是用户说的断层。这里直接按停靠档尺寸 + 目标 y 重做一次几何动画。 */
        if abs(frame.height - AevonSnap.dockSize.height) > 1.5 {
            var t = frame
            t.size = AevonSnap.dockSize
            if currentSlot == .left { t.origin.x = AevonSnap.edgeInset }
            if currentSlot == .right {
                t.origin.x = UIScreen.main.bounds.width - AevonSnap.edgeInset - t.width
            }
            t.origin.y = y
            animateGeometry(to: t, duration: AevonMotion.columnDuration,
                            damping: AevonMotion.columnDamping)
            return
        }
        guard abs(frame.minY - y) > 0.5 else { return }
        var t = frame
        t.origin.y = y
        let screen = UIScreen.main.bounds
        t.origin.y = min(max(t.origin.y, 0), max(0, screen.height - t.height))
        UIView.animate(withDuration: AevonMotion.columnDuration,
                       delay: 0,
                       usingSpringWithDamping: AevonMotion.columnDamping,
                       initialSpringVelocity: 0.2,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.frame = t
        } completion: { _ in
            self.setNeedsLayout()
        }
    }

    /// 轻点侧条（V0.0.44）。
    ///
    /// V0.0.48（AevonDockTapOnlyV48）：**已停靠时的「轻点侧条还原」已移除**。
    /// Aevon(41) 第 2 条：「既然现在停靠小窗可以直接点击变成主悬浮窗，
    /// 那么可以移除之前的小窗还原手势」—— 整块窗身轻点就是唯一的还原入口，
    /// 侧条轻点在小窗态只负责「挪到另一侧」或原地不动，避免两套还原手势打架。
    func dock(to slot: AevonSnapSlot) {
        guard slot == .left || slot == .right else { return }
        snap(to: slot)
    }

    /// 切换主窗形态 —— **V0.0.52 已删除**（AevonNoShapeTapV52）。
    ///
    /// Aevon(45)：「如果可以的话，主悬浮窗默认尺寸改为小胖屏，移除其他的比例
    /// （同时移除右下角点击手势，保留缩放手势）」。
    /// 现在只存在小胖屏一档（`AevonSnapWindowShape.fatAspect = 0.60`），
    /// 右下角角块只负责拖动缩放，点击不再有任何动作。

    /// 还原成主悬浮窗：**位置和尺寸都回到停靠前那一块**。
    ///
    /// V0.0.47（AevonRestorePosV47）：Aevon(40)「主悬浮窗吸附停靠后，点击还原时
    /// 不会回到停靠前的主悬浮窗位置」。旧实现有两处把落点改写掉：
    ///   ① 按当前停靠侧把 `origin.x` 强设成贴边 —— 于是无论停靠前在哪儿，还原后总是贴边；
    ///   ② 再走一次 `AevonSnap.avoid(...)` 让别人把它推开。
    /// 现在两处都删掉：`preDockFrame` 原样用，位置/尺寸与停靠前逐点一致。
    func restoreMainWindow() {
        // V0.0.50：停靠动画还没结束就再点一下（手指快）时直接忽略，
        // 否则两段几何动画叠在一起，落点会算错。
        guard !isAnimatingGeometry, !isDismissing else { return }

        /* V0.0.57（AevonDockAtomicV57）：先把「自己」从停靠列里摘出去，**再**降级其它主窗。
         *
         * Aevon(51) 第 3 条：「多个停靠小窗切换时依旧会出现断层，尤其是第一个变成第五个时」。
         * 旧顺序是 demote → relayout → 自己置 free → relayout：
         *   ① demote 的时候自己还占着第 1 格，列里算出来是 5 个 → 被降级的那个主窗
         *      按「第 5 格」落到 y=757（屏幕最下），
         *   ② 紧接着自己离开这一列 → 列里变 4 个 → 那个刚落到第 5 格的窗又要往上升到 591。
         * 两段动画方向相反、时间错开，用户看到的就是「先掉到底、再滑上去」的断层。
         * 现在先摘自己 → 列里从一开始就是 4 个 → 被降级的窗一次落到正确的 591。
         */
        currentSlot = .free
        AevonEntryHost.relayoutAllDockedColumns()

        // V0.0.51（AevonSingleMainV51）：再让其它主悬浮窗自动吸附成停靠小窗，
        // 街上只留自己这一个主窗 —— 否则几个窗都会回到同一份几何记忆（同一点）上叠起来。
        AevonEntryHost.demoteMainWindows(except: self)

        var target: CGRect
        if let previous = preDockFrame,
           previous.width > AevonSnap.minContentWidth,
           previous.height > AevonSnap.minContentWidth {
            // 原样恢复（只做屏幕边界夹取，不做任何避让 / 贴边改写）
            var p = previous
            // V0.0.54（AevonFatMainV54）：高度一律按**当前**比例重算。
            // `preDockFrame` 可能是旧版本（0.50 细长档）存下来的 266×547，
            // 原样用会把「小胖屏」又还原成细长条 —— 用户 Aevon(47) 第 4 条看到的就是这个。
            p.size.height = AevonSnap.height(forWidth: p.width)
            target = AevonSnap.clamped(p)
        } else {
            target = AevonWindowView.defaultFrame()
        }

        preDockFrame = nil
        // V0.0.49（AevonDockColumnFillV49）：Aevon(42) 第 2 条 ——
        // 「右侧放了 3 个小窗，把中间那个还原之后，下面的小窗不会主动上移」。
        // 还原前先记住自己在哪一侧，置成自由态（这样它不会被算进停靠列），
        // 然后立刻让整列重新按「中心锚点 + 向下生长」对齐 —— 空位当场被补上。
        currentSlot = .free
        // V0.0.55（AevonDockNoTouchV55）：还原成主窗 → 内容重新接收触摸
        sceneHost.setContentInteraction(true)
        // V0.0.53（AevonDockSlotFitV53）：两侧一起重排 —— 上面的 demote 可能刚把某个窗
        // 挪到对面那一列，只重排本侧会留下缺口（Aevon(46) 第 4 条）。
        AevonEntryHost.relayoutAllDockedColumns()
        // V0.0.48：还原也走统一几何动画（弹簧 + 内容缩放同步），不再裸改 frame
        animateGeometry(to: target,
                        duration: AevonMotion.restoreDuration,
                        damping: AevonMotion.restoreDamping) { [weak self] in
            self?.persistFrame()
        }
        AevonLog.info("[窗口] 轻点已停靠小窗 → 还原主悬浮窗 \(Int(target.minX)),\(Int(target.minY)) "
            + "\(Int(target.width))x\(Int(target.height))"
            + "（回到停靠前的位置与尺寸 · 下方整列上移补位（带动画）· 弹簧动画）"
            + "（AevonDockRestoreV44 AevonRestorePosV47 AevonGeomAnimV48 AevonDockColumnFillV49 AevonDockFillAnimV50）")
    }

    /// 关闭自己（底边条双击时由全局通道调用）。
    func closeSelf() {
        AevonWindowManager.close(bundleID: bundleID)
    }

    /// V0.0.47（AevonNoPushV47）：跨窗自动避让**整体停用**。
    ///
    /// Aevon(40) 第 4 条：「自动避让停靠小窗会让主悬浮窗随意挪动位置，很不合理」。
    /// 旧链路是「某个窗停靠完成 → `AevonEntryHost.avoidDockedWindow` 挨个通知其它窗
    /// 重新 `avoid()`」，于是用户什么都没做，别的主窗就自己飘走了 —— 而且飘到的位置
    /// 还会写进几何记忆，下次开窗继续错位。
    /// 现在保留空实现只为兼容调用点；真正的位置只由「用户拖动 / 缩放 / 停靠」决定。
    func avoidDockedWindows() {
    }

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
        guard let store = UserDefaults(suiteName: prefsSuite),
              let raw = store.array(forKey: frameMemoryKey) as? [Double],
              raw.count >= 3 else { return fallback }

        let screen = UIScreen.main.bounds
        // V0.0.46（AevonFrameMemoryCleanV46）：旧版本会把停靠小窗的 30% 宽写成全局记忆，
        // 读出来会让「新开的主窗」变成一根窄条。落在停靠档 ±2% 内的一律作废，用默认尺寸。
        let storedPercent = CGFloat(raw[2])
        if abs(storedPercent - AevonSnap.dockWidthRatio * 100.0) < 2.0 {
            return fallback
        }
        // V0.0.43：旧版本可能存着 66%~94% 的巨窗，读出来按 maxRestoredRatio 收回
        let cap = screen.width * AevonSnap.maxRestoredRatio
        let width = max(minContentWidth,
                        min(screen.width * storedPercent / 100.0, cap, AevonSnap.maxWidth))
        let height = AevonSnap.height(forWidth: width)
        let x = screen.width * CGFloat(raw[0]) / 100.0
        let y = screen.height * CGFloat(raw[1]) / 100.0
        return AevonSnap.clamped(CGRect(x: x, y: y, width: width, height: height))
    }

    private func persistFrame() {
        // V0.0.46（AevonFrameMemoryCleanV46）：**停靠态一律不写几何记忆**。
        // Aevon(39)：「吸附停靠变成小窗后，再用圆盘打开新应用，主悬浮窗会按小窗尺寸打开」——
        // 根因就是停靠落盘时把 30% 宽的小窗当成全局记忆（MedusaFrameLast）写进去了。
        guard currentSlot == .free else { return }
        guard !isLiveResizing, transform.isIdentity else { return }
        guard let store = UserDefaults(suiteName: AevonWindowView.prefsSuite) else { return }
        let screen = UIScreen.main.bounds
        guard screen.width > 1, screen.height > 1, frame.width > 1 else { return }
        let xp = Double(frame.minX / screen.width * 100.0)
        let yp = Double(frame.minY / screen.height * 100.0)
        let wp = Double(frame.width / screen.width * 100.0)
        store.set([xp, yp, wp], forKey: AevonWindowView.frameMemoryKey)
    }

    // MARK: - 关闭

    func teardown() {
        // 合帧定时器会强引用 self，必须显式停掉，否则关窗后视图泄漏
        stopDragLink()
        // 关窗前把最终位置记下来（退场动画已经落过盘就不用再来一次，
        // 否则会用缩小 94% 后的 frame 覆盖掉正确几何 —— V0.0.48）
        if !geometryPersistedBeforeDismiss {
            persistFrame()
        }
        // 必须先 invalidate 承载容器再拆视图，否则容器 dealloc 会抛
        // NSInternalInconsistencyException: Must be invalidated before deallocating
        sceneHost.onFirstContent = nil
        // V0.0.55（AevonAdaptiveContentV55）：关窗前把场景尺寸还原成整屏，
        // 否则这个 App 下次真的全屏打开时只有一小块（场景设置是我们改的）。
        sceneHost.resetAdaptiveSize()
        sceneHost.invalidate()
        sceneHost.container.removeFromSuperview()
        removeFromSuperview()
    }
}
