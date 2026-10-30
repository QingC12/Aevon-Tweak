import UIKit

/* V0.3.13（AevonHandleHideV313）：把手隐藏的 fail-open 判据 —— 两条腿都没就绪时强制显形。
 * ObjC 侧用 int 版导出（BOOL 的跨语言返回 ABI 不保证一致）。 */
@_silgen_name("AevonGripOwnLegReadyInt")
func aevonOwnLegReadyFlag() -> Int32
@_silgen_name("AevonGripSystemLegReadyInt")
func aevonSystemLegReadyFlag() -> Int32

/// 圆盘呼出把手（V0.2.50，AevonRingGripV250；V0.2.55 物理化重构 AevonRingGripV255；
/// V0.2.59 竖条化 + 自定义 AevonGripCustomV259）。
///
/// 为什么改成「可见把手」而不是继续调热区数值
/// ------------------------------------------
/// Aevon(25) 第 4 条：「圆盘的呼出手势热区改动一下，或者从新制作一下」。
/// 本项目自己的逆向档案（`逆向/PullOverX-1.8.80/手势呼出逻辑-逆向报告.html`）里
/// 有一段结论是把这件事说透了的：
///
///   > Pullover-X 之所以干净，不是因为它技术更高，而是因为它把「用户必须摸到一个
///   > 真实控件」当成了前提。一旦前提变成「空白区域的手势也要拦」，hitTest 这条路
///   > 就没了 —— 那个位置没有任何属于你的视图，返回非 nil 就是抢，返回 nil 就是放。
///   > 这正是 Aevon 一直撞的那堵墙：右缘空白带上不存在「既拦住又没拦」的中间态。
///
/// 换句话说：只要入口是「右缘一段没有视觉元素的空白带」，就只能靠吞触摸 / 延迟判向
/// 去抢，抢到就伤系统手势（历史多次事故），抢不到就呼不出圆盘（本次反馈）。
/// 真正能把「命中归属」还给我们的只有一条路 —— **那里放一个真实的、属于我们的视图**。
/// （MilkyWayReborn 的 `MWWindowView` / TweakPilot 的侧边气泡同款做法。）
///
/// V0.2.55（AevonRingGripV255）：识别器挂在真实控件 handle 上，全屏宿主零识别器。
///
/// V0.2.59（AevonGripCustomV259，用户 Aevon(33) #3）：
///   · 形状从「34pt 圆角块 + 图标」改成**贴边小短竖条**（宽 5pt × 高可调）；
///   · 位置（从底部起的百分比）与长度（pt）进设置页，**实时生效**（prefschanged）；
///   · 命中区向屏幕内侧外扩 12pt、上下各 14pt（V0.3.3 从 40pt 收窄，理由见 hitOutsetX）。
final class AevonRingGripView: UIView {
    /// V0.2.69（AevonRingIdleFixV269）：把手上活跃触摸计数 —— 圆盘静默看门狗的
    /// 「ended 真漏发」实判（touches 家族是 UIKit 硬通道，不会漏）。
    fileprivate var touchCount = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchCount += touches.count
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchCount = max(0, touchCount - touches.count)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchCount = 0
        super.touchesCancelled(touches, with: event)
    }

    /// 竖条视觉宽度（pt）。贴屏幕右缘。
    static let barWidth: CGFloat = 5
    /* 命中区外扩：向屏幕内侧 **12pt**、上下各 14pt。
     *
     * V0.3.3（AevonGripBandNarrowV303，用户 Aevon(81) 定档「方案 C：整根认领 + 收窄命中带」）：
     * 内侧 40 → 12pt。0.2.50 定的 40pt 是为了「好按」，但它把命中带铺到了抖音右栏
     * 评论/收藏按钮上（按钮中心距右缘约 30~50pt），逼得 0.2.61/0.2.77 在 App 侧写
     * 一堆「tap 豁免」补丁，还间接养出了 0.2.97 那条致命的「中途改吞」。
     *
     * Stheno 的 `GestureBorderWidth` 本来就是一条窄带（用户原话「我们在探针 Stheno 同款
     * 手势，它不会和抖音冲突」）。收窄到 12pt 后：呼盘手势仍然贴右手拇指自然位置，
     * 而右缘 12pt 之外的点击（几乎全部按钮）彻底不接触 → 误吞面从 46×92pt 缩到 17×92pt。
     * **App 侧 AevonAppSide.m 的 outsetX 必须与此同步**（两侧不一致 = 一侧吞一侧不吞）。 */
    static let hitOutsetX: CGFloat = 12
    static let hitOutsetY: CGFloat = 14
    /* V0.3.8（AevonGripZoneV308）：触发带宽度改为**可配**（偏好 GripWidth，12–60pt，默认 24）。
     *
     * 为什么是 24 而不是 17：0.3.4~0.3.7 系统腿判据里硬编码的就是 `screen.width - 24`，
     * 用户 Aevon(86) 已经是这个体感；把它变成可配时**默认取同一个值 = 横向行为零变化**，
     * 这样本版唯一的变量就是纵向（收窄触发范围），出事好归因。
     * 下限仍取 `barWidth + hitOutsetX`（=17pt），保证滑条拉到 12 也不会比 0.3.3 更窄。 */
    static let widthMin: CGFloat = 12
    static let widthMax: CGFloat = 60
    static let widthDefault: CGFloat = 24
    /* 触发带纵向余量（pt，上下各一份）：给「手指落点比把手中心偏一点」留活路。
     * 没有它，GripLen 拉到 36 时触发带只有 92pt 高，实测会掉呼盘成功率。 */
    static let bandPadY: CGFloat = 10
    /// 长度可调区间（pt）与默认值
    static let lenMin: CGFloat = 36
    /* V0.3.8（AevonGripZoneV308）：上限 120 → 400。
     * 用户 Aevon(86) 要的「右缘任意高度都能呼」不必再加一个模式开关 —— 把长度拉到 400
     * 就把整条右缘盖住了，滑条本身就是那个开关。 */
    static let lenMax: CGFloat = 400
    static let lenDefault: CGFloat = 64
    /// 位置可调区间（占屏幕高度比例，从底部起）与默认值
    static let ratioMin: CGFloat = 0.10
    static let ratioMax: CGFloat = 0.90
    static let ratioDefault: CGFloat = 0.30

    /* V0.3.13（AevonGripZoneV313）：触发区改成**右缘底部的百分比矩形**。
     *
     * 用户 Aevon(92) 定的几何：「右边缘底部向上的 30% 高度，宽度是贴近右边缘的 25%，
     * 在这个区域内都可以呼出圆盘」= (屏宽×75% ~ 屏宽) × (屏高×70% ~ 屏高)。
     *
     * 为什么必须换掉「中心 GripY + 长度 GripLen + 宽度 GripWidth」那套：
     * Aevon(91) 的 28 次 hold **全部有结局**，纵向闸 0 次、0.28s 超时闸 0 次 ——
     * 逻辑层一个洞都没有，剩下的漏出口**只剩几何边界**（横向只有 24pt 宽，
     * 手指偏 1~2mm 就落进 pass，App 把整根手指吃掉 = 用户说的「很小的几率」）。
     *
     * 用百分比而不是 pt：换机型还是同一个手感，用户也不必再算数值。 */
    static let zoneWMin: CGFloat = 10
    static let zoneWMax: CGFloat = 40
    static let zoneWDefault: CGFloat = 25
    static let zoneHMin: CGFloat = 15
    static let zoneHMax: CGFloat = 50
    static let zoneHDefault: CGFloat = 30

    /// 命中与手势的承载视图（V0.2.55）：frame = 命中区，识别器都挂在它上面。
    private let handle = UIView()
    /// 视觉竖条（5pt 宽 × 长可调），贴 handle 右缘 = 贴屏幕右缘，不参与交互。
    private let visual = UIView()
    private var didSummon = false

    /// V0.3.5（AevonGripYieldV305）：让路模式（实验，默认关）。
    ///
    /// 打开后把手**完全不接触摸**（handle 不交互、不装 pan、hitTest 返回 nil），
    /// 右缘的手指改由系统 `UISystemGestureView` 那条边沿识别器接收 —— 也就是
    /// 系统识别器腿 100% 接管。存在的意义是做 A/B：Aevon(83) 日志里 60 次呼盘
    /// 系统腿只占 3 次，全部落在把手竖条之外；把手竖条之内到底是「系统腿没认领」
    /// 还是「认领了但比把手慢」，只有让把手闭嘴才能测出来。
    private var yieldMode = false

    var onSummon: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        isAccessibilityElement = false

        handle.backgroundColor = .clear
        handle.isUserInteractionEnabled = true
        addSubview(handle)

        visual.isUserInteractionEnabled = false
        visual.backgroundColor = UIColor(white: 1.0, alpha: 0.32)
        visual.layer.cornerRadius = AevonRingGripView.barWidth * 0.5
        visual.layer.cornerCurve = .continuous
        visual.layer.borderWidth = 0.5
        visual.layer.borderColor = UIColor(white: 1.0, alpha: 0.25).cgColor
        handle.addSubview(visual)
        // 竖条只有 5pt 宽，旧版 34pt 块里的图标（glyph）放不下 —— V0.2.59 起纯视觉条。

        // V0.2.55（AevonRingGripV255）：识别器全部挂 handle（真实控件），
        // 全屏宿主不再持有任何识别器。
        installHandlePan()
        // V0.2.60（AevonGripSwipeOnlyV260，用户 Aevon(34) #3）：「移除触发条的点击显示
        // 圆盘功能，只保留滑动触发圆盘」—— 点击识别器整建制退役（含 require(toFail:)）。
        // 顺带解决一个老毛病：把手和右侧吸附边条在屏幕上挨着，点边条停靠时那一下
        // 也会被把手当点击吃掉（Aevon(34) 32.180 那次「边条轻点停靠」紧跟着
        // 「把手被点 → 呼出圆盘」就是它）。

        // V0.3.5（AevonGripYieldV305）：装完 pan 再按偏好决定是否让路。
        yieldMode = false
        applyYieldMode()
    }

    /// V0.3.5：把手自己的滑动识别器（让路模式下会被摘掉）。
    private func installHandlePan() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        handle.addGestureRecognizer(pan)
    }

    /// V0.3.5（AevonGripYieldV305）：读偏好并切换让路状态。
    /// 设置页改完会走 Darwin 通知 → `AevonRingGrip.refreshFromPrefs()` → 这里，**实时生效**。
    func applyYieldMode() {
        // V0.3.7（AevonYieldDefaultV307）：默认值 false → true（转正）。
        // 依据 Aevon(85)：让路开启的 67 秒里 33 次呼盘 33 次全由系统识别器腿完成
        // （前台全在抖音 com.ss.iphone.ugc.Aweme —— __RESTRICT、Aevon 无注入），
        // 「手指落在把手上」0 条、「（全局通道）」0 条、「不在右缘」0 条、0 崩溃。
        // 这就是 Stheno 的架构：只骑系统识别器，Aevon 一根手指都不碰。
        let want = AevonPrefs.bool("GripSystemYield", default: true)
        // V0.3.6（AevonGripYieldDeepV306）：静态镜像无条件对齐（哪怕状态没变），
        // 这样把手实例被销毁重建后不会留下过期值。
        AevonRingGrip.yieldActive = want
        guard want != yieldMode else { return }
        yieldMode = want
        if want {
            handle.isUserInteractionEnabled = false
            for g in handle.gestureRecognizers ?? [] {
                handle.removeGestureRecognizer(g)
            }
            AevonLog.warn("[圆盘] 把手让路模式已开（实验）：把手不接触摸、不装 pan，"
                + "右缘全部交给系统 gesture view → 系统识别器腿 100% 接管；"
                + "SB 侧全局通道的手势呼盘同步停用（AevonGripYieldV305 AevonGripYieldDeepV306）")
        } else {
            handle.isUserInteractionEnabled = true
            if (handle.gestureRecognizers ?? []).isEmpty {
                installHandlePan()
            }
            AevonLog.info("[圆盘] 把手让路模式已关：把手恢复自建 pan（系统腿只做补充）"
                + "（AevonGripYieldV305 AevonGripYieldDeepV306）")
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 自定义参数（V0.2.59 AevonGripCustomV259 → V0.3.13 区域模型）

    /* V0.3.13（AevonGripZoneV313）：`bottomRatio` / `barLength` / `hitWidth` 三个
     * 读 GripY / GripLen / GripWidth 的属性整体退役 —— 几何唯一来源改成
     * `AevonRingGrip.bandRect()`（百分比区域）。留在文件里只会让人以为还有第二个
     * 权威算法，而两侧不一致正是 0.2.61~0.2.84 那串鬼的根。 */

    override func layoutSubviews() {
        super.layoutSubviews()
        let zone = AevonRingGrip.bandRect(screenW: bounds.width, screenH: bounds.height)
        guard zone.width > 0, zone.height > 0 else { return }
        // handle = 整个触发区（显形时 point(inside:)/hitTest 与全局通道都靠它）
        handle.frame = CGRect(x: zone.minX, y: zone.minY,
                              width: zone.width, height: zone.height)
        // 视觉竖条：只在 fail-open 显形的那一刻可见，取区域内居中、贴右缘的一小段
        let len = min(max(zone.height * 0.4, AevonRingGripView.lenMin), 96.0)
        visual.frame = CGRect(x: handle.bounds.width - AevonRingGripView.barWidth,
                              y: (handle.bounds.height - len) / 2,
                              width: AevonRingGripView.barWidth,
                              height: len)
    }

    /// 命中区 = handle 的 frame = 整个呼出区（V0.3.13 起为右缘底部百分比矩形；
    /// 0.3.3~0.3.12 是 17×92 的窄带，再早是 46×92）。
    private var hitRect: CGRect {
        return handle.frame
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // V0.3.5（AevonGripYieldV305）：让路模式下手把自己的窗口也不接这一下 ——
        // 触摸不投给我们的窗口，系统 UISystemGestureView 才拿得到完整序列。
        guard !yieldMode else { return false }
        guard !isHidden, alpha > 0.01 else { return false }
        return hitRect.contains(point)
    }

    override func hitTest(_ p: CGPoint, with event: UIEvent?) -> UIView? {
        // 把手之外一律 nil：系统继续往 App 派发，不产生任何争抢。
        // V0.2.55：命中时返回 handle（真实控件），不再返回全屏宿主自身 ——
        // touch.view 永远不会是这块全屏透明视图。
        guard !yieldMode else { return nil }        // V0.3.5 让路模式：整块让开
        guard !isHidden, alpha > 0.01 else { return nil }
        guard hitRect.contains(p) else { return nil }
        return handle
    }

    /// V0.2.60（AevonGripSwipeGlobalV260）：屏幕坐标是否落在把手命中区里。
    ///
    /// 给全局触摸通道用：全屏 App 时触摸根本不进我们的视图树，`hitTest` 永远命中不到，
    /// 只能由 `sendEvent` 侧拿屏幕点来问「这是不是把手」。
    func containsScreenPoint(_ screenPoint: CGPoint) -> Bool {
        guard !isHidden, alpha > 0.01 else { return false }
        let local = convert(screenPoint, from: nil)
        guard bounds.contains(local) else { return false }
        return hitRect.contains(local)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            didSummon = false
            visual.alpha = 1.0
        case .changed:
            guard !didSummon else { break }
            let delta = gesture.translation(in: self)
            // V0.2.99（AevonGripThreshV299）：-14→-8pt，与全局通道同步（Aevon(76) 23% 成功率实锤）。
            if delta.x < -8, abs(delta.y) < 30 {
                didSummon = true
                AevonLog.info("[圆盘] 把手被左滑 \(Int(delta.x))pt → 呼出圆盘（0.2.99 阈值 14→8pt）"
                    + "（AevonRingGripV250 AevonRingGripV255 AevonGripThreshV299）")
                onSummon?("ringgrip")
            }
        case .ended, .cancelled, .failed:
            visual.alpha = 0.85
            didSummon = false
        default:
            break
        }
    }
}

extension AevonRingGripView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        return hitRect.contains(touch.location(in: self))
    }
}

/// 把手安装与显隐（V0.2.50，AevonRingGripV250）。
enum AevonRingGrip {
    private static var grip: AevonRingGripView?

    /// V0.2.69（AevonRingIdleFixV269）：把手上还有没有活跃触摸 ——
    /// 圆盘静默看门狗的「ended 真漏发」判据（把手视图自己的 UIKit 触摸计数）。
    static var hasActiveGripTouch: Bool {
        guard let grip else { return false }
        return grip.touchCount > 0
    }
    private static var lastInstalledAt: CFTimeInterval = 0

    // MARK: 键盘在屏 → 把手整条抑制（V0.2.67 引入；V0.2.68 换主驱动源，AevonKbSenseV268）
    //
    // 用户 Aevon(40) #3「全屏 App 打开键盘时，键盘右侧会和手势触发条冲突」：
    // 0.2.67 让 App 侧发 Darwin 通知广播键盘状态 —— **方向错了**。Aevon(40) 整篇
    // 日志「键盘=否」一条没变过（通知链一次都没触发），因为**全屏 App 的键盘窗口
    // （SBMedusaHostedKeyboardWindow / _UISceneSessionRoleKeyboard 键盘场景）活在
    // SpringBoard 进程里**，App 进程根本不知道它显没显示。
    //
    // V0.2.68 主驱动源改为 **SB 侧现场检测**：枚举本进程全部场景的窗口，看到
    // 非隐藏、够高的 `*KeyboardWindow`（UIRemoteKeyboardWindow /
    // SBMedusaHostedKeyboardWindow）就抑制把手；0.5s 缓存，判定成本可忽略。
    // Darwin 通知监听保留当辅助（承载浮窗内的键盘在 App 进程，那一路仍有用）。

    /// 键盘在屏中（现场检测 + Darwin 通知双通道驱动，SB 侧只读）。
    static var keyboardSuppressed = false

    /// V0.3.6（AevonGripYieldDeepV306）：让路状态的**静态镜像**（SB 侧通道的收口点）。
    ///
    /// Aevon(84) 日志实锤 0.3.5 的让路开关无效：开关开着（`11:53:58.120 把手让路模式已开`）
    /// 之后仍有 **37 次「把手左滑 → 呼出圆盘（全局通道）」**。原因是 0.3.5 只摘了可视控件层
    /// （`point(inside:)` / `hitTest` / pan），而真正的主力是 **SpringBoard 侧 sendEvent 的
    /// 全局通道** —— 它走 `AevonRingGrip.hitTestScreenPoint`，根本不看视图层有没有交互。
    /// 现场铁证：`11:54:27.741 手指落在把手上 (420,695)` → `.778 全局通道呼盘`（比系统腿早 40ms）
    /// → `.801 系统腿认领` → `.803 达阈值但被拦 原因=圆盘已开`。
    ///
    /// 这个镜像就是那个收口点：`hitTestScreenPoint` 让路时直接返回 false，SB 侧的
    /// 「把手候选登记」与「左滑呼盘」同时失效，一处改动覆盖两条代码路径。
    /// 由 `AevonRingGripView.applyYieldMode()` 同步（构造 + 偏好变更各一次），
    /// **不进触摸热路径、零 IPC**。
    static var yieldActive = false

    /* V0.3.13（AevonGripZoneV313）：触发几何的**唯一权威算法** —— 右缘底部百分比矩形。
     *
     * 历史（为什么不沿用 0.3.8 那套）：0.3.8 把「右缘整条」收成 GripWidth×GripLen 的
     * 一条带，解决了「整个右侧都触发」，但带子横向只有 24pt。Aevon(91) 实测：
     * 带内 28 次扣指 **全部有结局**（27 次自建呼盘 + 1 次借腿认领），纵向闸与超时闸
     * 一次都没 fire，18 次 pass **全部**是「落点不在带内」—— 也就是说唯一漏出去的
     * 通道就是这道 24pt 的边。用户直接在体验上确认了：「开启后很小的几率触发 App 内操作」。
     *
     * 现在改成区域：横向 = 屏宽 × GripZoneW%（默认 25），纵向 = 屏高 × GripZoneH%（默认 30，
     * 贴底）。区域内任意落点都算呼盘，边界一次性退出 100pt 量级。
     *
     * ⛔ 两侧同侧纪律（0.2.61~0.2.84 反复踩）：本函数仍是唯一权威。App 侧
     * `AevonAppSide.m` 的吞带在 0.3.13 已退役（`AevonAppBandRetireV313`）——
     * 区域扩大到 107×280pt 后，App 侧若跟随式吞指会把 App 右下角一整片按钮全吃掉，
     * 而实测证明「App 不跟手」100% 由 SB 侧自建腿提供（0.3.12 抖音 27/27）。
     * 因此不再有镜像公式，CI 的 V0.3.13 块改为断言「App 侧吐带已归零」。 */
    static func bandRect(screenW: CGFloat, screenH: CGFloat) -> CGRect {
        guard screenW >= 100, screenH >= 200 else { return .zero }
        let rawW = CGFloat(AevonPrefs.double("GripZoneW", default: Double(zoneWDefault)))
        let wPct = min(max(rawW, zoneWMin), zoneWMax)
        let rawH = CGFloat(AevonPrefs.double("GripZoneH", default: Double(zoneHDefault)))
        let hPct = min(max(rawH, zoneHMin), zoneHMax)
        let w = screenW * wPct / 100.0
        let h = screenH * hPct / 100.0
        return CGRect(x: screenW - w, y: screenH - h, width: w, height: h)
    }

    /// V0.3.8（AevonGripZoneV308）：触发范围模式。
    /// `false`（默认）= 只在把手那条带内呼盘，带外的右缘左滑归还给侧滑返回插件；
    /// `true` = 右缘任意高度都能呼盘（0.3.7 的行为，作为兜底）。
    /// 等价做法：把 GripLen 拉到 400 也能盖住整条右缘，这个开关是给「不想算数值」的场合用的。
    static var scopeFullEdge: Bool {
        return AevonPrefs.bool("GripScope", default: false)
    }

    private static var kbObserversInstalled = false
    private static var kbSenseAt: CFTimeInterval = 0
    private static var kbLastVisible = false   // V0.2.70：在屏日志只在状态切换时打

    fileprivate static func setKeyboardSuppressed(_ on: Bool) {
        guard keyboardSuppressed != on else { return }
        keyboardSuppressed = on
        guard let grip = grip, grip.superview != nil else { return }
        /* V0.2.85（AevonYieldPureAlphaV285）：键盘这条也在「手指刚点完输入框」的瞬间触发，
         * 原来的 `isHidden` + `isUserInteractionEnabled = false` 同样是两个 cancel 面。
         * 统一走 alpha：键盘在屏或圆盘正展开 → 全透明；否则按开关恢复。 */
        let shouldShow = !on && AevonRingMenu.presented == nil
            && AevonPrefs.bool("RingGripEnabled", default: true)
        grip.alpha = shouldShow ? gripShownAlpha : gripHiddenAlpha
        AevonLog.info("[圆盘] 键盘\((on ? "在屏" : "收起")) → 把手触发条\((on ? "临时屏蔽（防压键盘右列）" : "恢复"))"
            + "（AevonKbSenseV268 AevonKbHideV267 AevonYieldPureAlphaV285）")
    }

    /// V0.2.68（AevonKbSenseV268）：现场检测键盘窗口是否在屏（0.5s 缓存）。
    /// 判据纯几何 + 类名，不依赖任何跨进程通知的时序。
    /// V0.2.69（AevonKbSense2V269，用户 Aevon(41) #9「全屏 App 打开键盘时还是会
    /// 触碰到圆盘触发条」）：Aevon(41) 全篇零条本检测的日志 = 从未命中。窗口栈实锤
    /// `SBMedusaHostedKeyboardWindow(h)` —— 全屏 App 的键盘窗口在 SB 栈里是
    /// **隐藏**的（键盘真正画在 `UITextEffectsWindow` 里），「非隐藏 KeyboardWindow」
    /// 判据永远不成立。补两条主判据：
    ///   ① `UIKeyboardImpl` 的 isOnScreen（SB 进程里键盘状态的最权威来源，
    ///      类方法 / activeInstance / sharedInstance 三档探测，全 @try）；
    ///   ② 窗口栈放宽：非隐藏 `*KeyboardWindow` **或** 非隐藏 UITextEffectsWindow
    ///      里翻得到 Keyboard 类子视图（含 RemoteKeyboard 视图）。
    static func syncKeyboardSuppression() {
        let now = CACurrentMediaTime()
        if now - kbSenseAt < 0.5 { return }
        kbSenseAt = now
        var visible = false
        var probe = "窗口扫描=无"

        // ① UIKeyboardImpl.isOnScreen（三档探测；BOOL 返回必须走类型化 msgSend，
        //    NSObject.perform 接原始 BOOL 会拿回垃圾对象）
        if let kbCls = NSClassFromString("UIKeyboardImpl") {
            typealias BoolFn0 = @convention(c) (AnyObject, Selector) -> Bool
            typealias IdFn0 = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") {
                let sendBool = unsafeBitCast(sym, to: BoolFn0.self)
                let sendId = unsafeBitCast(sym, to: IdFn0.self)
                let selOn = NSSelectorFromString("isOnScreen")
                let kbAny = kbCls as AnyObject
                // 类方法档（部分 iOS 版本提供 +isOnScreen）
                if kbAny.responds(to: selOn) {
                    let on = sendBool(kbAny, selOn)
                    visible = on
                    probe = "UIKeyboardImpl.+isOnScreen=\(on)"
                }
                if !visible {
                    // 实例档：activeInstance / sharedInstance
                    for factory in ["activeInstance", "sharedInstance"] {
                        let selF = NSSelectorFromString(factory)
                        guard kbAny.responds(to: selF),
                              let boxed = sendId(kbAny, selF),
                              let inst = boxed.takeUnretainedValue() as? NSObject,
                              inst.responds(to: selOn) else { continue }
                        let on = sendBool(inst, selOn)
                        visible = on
                        probe = "UIKeyboardImpl.\(factory).isOnScreen=\(on)"
                        break
                    }
                }
            }
        }

        // ② 窗口扫描（原判据 + UITextEffectsWindow 内容物检查）
        if !visible {
            let app = UIApplication.shared
            scan: for scene in app.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for w in ws.windows where !w.isHidden && w.frame.height > 150 {
                    let name = NSStringFromClass(type(of: w))
                    if name.contains("KeyboardWindow") {
                        visible = true
                        probe = "\(name) 非隐藏"
                        break scan
                    }
                    if name.contains("TextEffects") {
                        // 键盘画在 UITextEffectsWindow 里：翻子树找「真在显示」的键盘视图。
                        // V0.2.70（AevonKbVisGateV270）：0.2.69 只查类名 = 误报实锤
                        //（Aevon(42) 全篇「键盘在屏」刷屏 70s+，把手被永久 hidden，
                        // 用户实锤「触发条自动消失，无法呼出圆盘」）——
                        // UITextEffectsWindow 是**常驻窗口**，键盘收起时里面照样挂着
                        // UIKeyboard* 管理视图（hidden / alpha=0 / 零尺寸）。加可见性三关：
                        // 祖先链全非 hidden + alpha≥0.9 + 键盘几何（高≥150 宽≥半屏）。
                        if AevonRingGrip.subtreeContainsVisibleKeyboard(w, depth: 0) {
                            visible = true
                            probe = "\(name) 内含可见键盘视图"
                            break scan
                        }
                    }
                }
            }
        }
        // V0.2.70：只在本轮状态发生变化时打 probe 日志（0.2.69 每 0.5s 刷一条 = 噪音）
        let changed = (visible != kbLastVisible)
        setKeyboardSuppressed(visible)
        if visible && changed {
            AevonLog.info("[圆盘] 键盘在屏（\(probe)）→ 把手触发条临时屏蔽（AevonKbSense2V269 AevonKbVisGateV270）")
        }
        kbLastVisible = visible
    }

    /// V0.2.70（AevonKbVisGateV270）：UITextEffectsWindow 子树里有没有「真在显示」的
    /// Keyboard 类视图（限深 5 层防大遍历）。可见性三关防误报：
    /// 自身与祖先链全非 hidden、alpha≥0.9、高≥150pt 且宽≥半屏（键盘的几何）。
    /// 判据宁可漏报不可误报：漏报只退回 0.2.68 的「键盘碰触发条」小痛点，
    /// 误报 = 把手永久 hidden、圆盘整个呼不出（0.2.69 Aevon(42) 实锤）。
    private static func subtreeContainsVisibleKeyboard(_ view: UIView, depth: Int) -> Bool {
        if depth > 5 { return false }
        for sub in view.subviews {
            if NSStringFromClass(type(of: sub)).contains("Keyboard") {
                let halfW = UIScreen.main.bounds.width / 2
                if sub.frame.height >= 150, sub.frame.width >= halfW {
                    var cur: UIView? = sub
                    var allVisible = true
                    while let node = cur {
                        if node.isHidden || node.alpha < 0.9 { allVisible = false; break }
                        cur = node.superview
                    }
                    if allVisible { return true }
                }
            }
            if subtreeContainsVisibleKeyboard(sub, depth: depth + 1) { return true }
        }
        return false
    }

    private static func installKbObserversIfNeeded() {
        guard !kbObserversInstalled else { return }
        kbObserversInstalled = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        // 两个通知名各配一个无捕获回调（Swift 非捕获闭包可直接当 C 函数指针）。
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { AevonRingGrip.setKeyboardSuppressed(true) }
        }, "com.aevon.kbvis.on" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { AevonRingGrip.setKeyboardSuppressed(false) }
        }, "com.aevon.kbvis.off" as CFString, nil, .deliverImmediately)
    }

    /// 装到入口容器最上层（容器会搬进全屏 App 的画面容器，所以全屏 App 里也在）。
    /// 幂等：重复调用只做一次真正的安装。
    /// V0.2.58（AevonGripToggleV258）：偏好 RingGripEnabled（默认开）= 隔离实验开关
    ///（用户 Aevon(32)：「先暂时屏蔽把手，看看问题还会出现吗」）——
    /// 关闭时把手整体摘除、呼盘入口禁用（浮窗也无法呼出，专用于 A/B 定位）；
    /// 改动后需注销生效。
    static func installIfNeeded(force: Bool = false) {
        if !AevonPrefs.bool("RingGripEnabled", default: true) {
            if let existing = grip, existing.superview != nil {
                existing.removeFromSuperview()
                grip = nil
                AevonLog.warn("[圆盘] 把手已按偏好屏蔽（RingGripEnabled=否，呼盘入口停用；"
                    + "重新打开需注销）（AevonGripToggleV258）")
            }
            return
        }
        if let existing = grip, existing.superview != nil, !force {
            // V0.2.60（AevonGripFrontV260，用户 Aevon(34) #3）：容器搬进全屏 App 画面
            // 容器后，后加入容器的子视图（浮窗层 / 圆盘 / 面板）会压在把手上 ——
            // 每轮核对都把它顶回最上层，否则「全屏 App 里把手点不到」。
            existing.superview?.bringSubviewToFront(existing)
            existing.setNeedsLayout()
            return
        }
        // 容器还没就绪：1 秒内最多重试一次，不要在启动期空转
        let now = CACurrentMediaTime()
        if !force, now - lastInstalledAt < 1.0 { return }
        lastInstalledAt = now
        let view = AevonRingGripView(frame: .zero)
        view.onSummon = { source in
            AevonRingGrip.setVisible(false)
            AevonEdgeEntry.presentRing(source: source)
        }
        view.alpha = AevonRingGripView.gripShownAlpha   // V0.3.13：隐藏开关在装窗这一刻就生效
        guard AevonEntryHost.attachOverlay(view) else { return }
        grip = view
        installKbObserversIfNeeded()
        AevonLog.info("[圆盘] 右缘呼出区已就位（V0.3.13 起为右缘底部百分比矩形，宽高可在设置页调，"
            + "把手默认隐藏：alpha=\(String(format: "%.2f", view.alpha))），"
            + "呼盘靠系统手势管线里的识别器，全屏宿主零识别器"
            + "（AevonRingGripV250 AevonRingGripV255 AevonGripCustomV259"
            + " AevonGripSwipeOnlyV260 AevonGripFrontV260"
            + " AevonGripBandNarrowV303 AevonGripIntentRetireV303"
            + " AevonGripZoneV313 AevonHandleHideV313）")
    }

    /// V0.2.59（AevonGripCustomV259）：设置页改了 GripY / GripLen → 实时重排。
    /// 参数读取在 layoutSubviews 里做（每次现读偏好、带夹取），
    /// 这里只需让把手视图重排一次。位置不落盘状态、无缓存漂移。
    static func refreshFromPrefs() {
        guard let grip = grip, grip.superview != nil else { return }
        // V0.3.5（AevonGripYieldV305）：让路开关实时切换（Darwin 通知已通到这条路）
        grip.applyYieldMode()
        /* V0.3.13（AevonHandleHideV313）：隐藏开关也在这条路上实时生效 ——
         * 设成「按开关状态恢复」的那一处口径：圆盘没展开、键盘没在屏才允许显形。 */
        let shouldShow = !keyboardSuppressed && AevonRingMenu.presented == nil
            && AevonPrefs.bool("RingGripEnabled", default: true)
        grip.alpha = shouldShow ? AevonRingGripView.gripShownAlpha : AevonRingGripView.gripHiddenAlpha
        grip.setNeedsLayout()
        grip.layoutIfNeeded()
    }

    /// V0.2.60（AevonGripSwipeGlobalV260）：屏幕点是否落在把手命中区（给全局通道问）。
    static func hitTestScreenPoint(_ point: CGPoint) -> Bool {
        // V0.3.6（AevonGripYieldDeepV306）：让路模式下**整条把手通道闭嘴上锁**。
        // 这是 SB 侧全局通道唯一入口（AevonEdgeEntry 落指登记 + moved 呼盘都走它），
        // 在这里返回 false 就一次性停掉两条代码路径 —— 0.3.5 只关视图层留下的洞。
        guard !yieldActive else { return false }
        syncKeyboardSuppression()   // V0.2.68 AevonKbSenseV268：判定前先现场核一次键盘（0.5s 缓存）
        guard !keyboardSuppressed else { return false }   // V0.2.67 AevonKbHideV267
        guard AevonPrefs.bool("RingGripEnabled", default: true) else { return false }
        guard let grip = grip, grip.superview != nil else { return false }
        // V0.2.85（AevonYieldPureAlphaV285）：藏起来（alpha 0）时不再拦触摸 ——
        // 以前靠 isHidden 天然跳过，现在得显式判，否则让位态下把手还在吃这根手指。
        guard !gripIsEffectivelyHidden(grip) else { return false }
        return grip.containsScreenPoint(point)
    }

    /// V0.2.85（AevonYieldPureAlphaV285）：把手的「藏」全部改成 alpha，**不再用 isHidden**。
    ///
    /// 两条路径都会在「手指还按着把手」的瞬间执行：
    ///   · `setVisible(false)` —— 手指左滑呼出圆盘，把手当场要藏；
    ///   · `setOverlayYield(true)` —— 手指刚下拉控制中心 / 通知中心。
    /// `isHidden = true` 让 UIKit **立刻 cancel 这根手指**并把 UITouch 从事件簿记里摘掉，
    /// 而 `AevonTouchHook` 的 sendEvent 钩子手里还握着同一个指针（0.2.82 注释里写的就是
    /// 这个 use-after-free，当时只修了浮窗那一半，把手这两处漏了）。
    /// alpha < 0.02 的视图不参与 hitTest，视觉与触摸语义等价，但**不 cancel 已在屏的手指**。
    static let gripHiddenAlpha: CGFloat = 0
    private static let gripVisibleAlpha: CGFloat = 0.85

    /* V0.3.13（AevonHandleHideV313）：把手可以**整体隐藏**（偏好 GripHandleHidden，默认开）。
     *
     * 用户 Aevon(92)：「Stheno 的边缘并没有显形的把手」—— 要同款。现在呼盘 100% 由
     * SB 侧自建识别器腿提供（0.3.12 抖音 27/27），把手对呼盘已经零贡献。
     *
     * 走的是同一套 alpha 通道（0.2.85 铁律：藏一律用 alpha，禁 isHidden —— isHidden 会
     * 让 UIKit 立刻 cancel 在屏手指并摘掉 UITouch，是 use-after-free 的老窝）。于是
     * `point(inside:)` / `hitTest` / `containsScreenPoint` / `hitTestScreenPoint` 里
     * 现成的 `alpha < 0.02` 判据全部自动让路，一个额外分支都不用加。
     *
     * fail-open：自建腿与借腿**都没就绪**时强制显形 —— 那种状态下没有任何识别器能呼盘，
     * 把手是最后一条命，再藏起来用户就彻底没有入口了。 */
    static var gripShownAlpha: CGFloat {
        guard AevonPrefs.bool("GripHandleHidden", default: true) else { return gripVisibleAlpha }
        let handsOn = aevonOwnLegReadyFlag() != 0 || aevonSystemLegReadyFlag() != 0
        return handsOn ? gripHiddenAlpha : gripVisibleAlpha
    }

    /// 当前是否「对外不见」（隐藏或全透明）。命中判定统一走这个。
    private static func gripIsEffectivelyHidden(_ view: UIView) -> Bool {
        return view.isHidden || view.alpha < 0.02
    }

    /// 圆盘展开时藏起来（避免它压在圆盘上），收起后再出来。
    static func setVisible(_ visible: Bool) {
        guard let grip = grip else { return }
        grip.alpha = visible ? gripShownAlpha : gripHiddenAlpha
    }

    /// V0.2.78（AevonOverlayYieldV278，用户 Aevon(50) #1）：系统浮层（控制中心 /
    /// 通知中心 / 切换器）在屏时把手一起让位 —— 否则把手会浮在控制中心上面，
    /// 而且是那块区域唯一还会吃触摸的东西。收起重置时按开关状态恢复。
    static func setOverlayYield(_ on: Bool) {
        guard let grip = grip else { return }
        // 收起时要回「按开关状态」：开关关着就是本来就不该有把手。
        let shouldShow = on ? false : AevonPrefs.bool("RingGripEnabled", default: true)
        grip.alpha = shouldShow ? gripShownAlpha : gripHiddenAlpha
    }

    static var isInstalled: Bool { return grip?.superview != nil }
}
