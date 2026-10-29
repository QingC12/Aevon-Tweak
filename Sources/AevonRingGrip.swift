import UIKit

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
///   · 命中区依旧向屏幕内侧外扩 40pt、上下各 14pt —— 可点性不因竖条变窄而缩水。
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
    /// 命中区外扩：向屏幕内侧 40pt、上下各 14pt（0.2.50 定档，不变）
    static let hitOutsetX: CGFloat = 40
    static let hitOutsetY: CGFloat = 14
    /// 长度可调区间（pt）与默认值
    static let lenMin: CGFloat = 36
    static let lenMax: CGFloat = 120
    static let lenDefault: CGFloat = 64
    /// 位置可调区间（占屏幕高度比例，从底部起）与默认值
    static let ratioMin: CGFloat = 0.10
    static let ratioMax: CGFloat = 0.90
    static let ratioDefault: CGFloat = 0.30

    /// 命中与手势的承载视图（V0.2.55）：frame = 命中区，识别器都挂在它上面。
    private let handle = UIView()
    /// 视觉竖条（5pt 宽 × 长可调），贴 handle 右缘 = 贴屏幕右缘，不参与交互。
    private let visual = UIView()
    private var didSummon = false

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
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        handle.addGestureRecognizer(pan)
        // V0.2.60（AevonGripSwipeOnlyV260，用户 Aevon(34) #3）：「移除触发条的点击显示
        // 圆盘功能，只保留滑动触发圆盘」—— 点击识别器整建制退役（含 require(toFail:)）。
        // 顺带解决一个老毛病：把手和右侧吸附边条在屏幕上挨着，点边条停靠时那一下
        // 也会被把手当点击吃掉（Aevon(34) 32.180 那次「边条轻点停靠」紧跟着
        // 「把手被点 → 呼出圆盘」就是它）。
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 自定义参数（V0.2.59，AevonGripCustomV259）

    /// 位置（从屏幕底部起的高度比例）。读偏好 GripY（10–90，默认 30）。
    private var bottomRatio: CGFloat {
        let raw = CGFloat(AevonPrefs.double("GripY", default: 30))
        let clamped = min(max(raw / 100.0, AevonRingGripView.ratioMin), AevonRingGripView.ratioMax)
        return clamped
    }

    /// 竖条长度（pt）。读偏好 GripLen（36–120，默认 64）。
    private var barLength: CGFloat {
        let raw = CGFloat(AevonPrefs.double("GripLen", default: 64))
        return min(max(raw, AevonRingGripView.lenMin), AevonRingGripView.lenMax)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let len = barLength
        let w = AevonRingGripView.barWidth
        // 命中区：竖条中心纵向 = 屏幕底部 bottomRatio 处；横向贴右缘向内扩 hitOutsetX
        let cy = bounds.height * (1.0 - bottomRatio)
        let hitW = w + AevonRingGripView.hitOutsetX
        let hitH = len + AevonRingGripView.hitOutsetY * 2
        handle.frame = CGRect(x: bounds.width - hitW,
                              y: cy - hitH / 2,
                              width: hitW,
                              height: hitH)
        // 竖条贴 handle 右缘（= 贴屏幕右缘），纵向以命中区中心居中
        visual.frame = CGRect(x: handle.bounds.width - w,
                              y: (handle.bounds.height - len) / 2,
                              width: w,
                              height: len)
    }

    /// 命中区 = handle 的 frame（竖条向内扩 40pt、上下各扩 14pt）。
    private var hitRect: CGRect {
        return handle.frame
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, alpha > 0.01 else { return false }
        return hitRect.contains(point)
    }

    override func hitTest(_ p: CGPoint, with event: UIEvent?) -> UIView? {
        // 把手之外一律 nil：系统继续往 App 派发，不产生任何争抢。
        // V0.2.55：命中时返回 handle（真实控件），不再返回全屏宿主自身 ——
        // touch.view 永远不会是这块全屏透明视图。
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
        view.alpha = 0.85
        guard AevonEntryHost.attachOverlay(view) else { return }
        grip = view
        installKbObserversIfNeeded()
        AevonLog.info("[圆盘] 右缘把手已就位（V0.2.59 起为贴边小短竖条，位置/长度可在设置页调，"
            + "命中区向外扩 \(Int(AevonRingGripView.hitOutsetX))pt，把手外一律不拦，"
            + "识别器挂在真实控件上，全屏宿主零识别器）"
            + "（AevonRingGripV250 AevonRingGripV255 AevonGripCustomV259"
            + " AevonGripSwipeOnlyV260 AevonGripFrontV260）")
    }

    /// V0.2.59（AevonGripCustomV259）：设置页改了 GripY / GripLen → 实时重排。
    /// 参数读取在 layoutSubviews 里做（每次现读偏好、带夹取），
    /// 这里只需让把手视图重排一次。位置不落盘状态、无缓存漂移。
    static func refreshFromPrefs() {
        guard let grip = grip, grip.superview != nil else { return }
        grip.setNeedsLayout()
        grip.layoutIfNeeded()
    }

    /// V0.2.60（AevonGripSwipeGlobalV260）：屏幕点是否落在把手命中区（给全局通道问）。
    static func hitTestScreenPoint(_ point: CGPoint) -> Bool {
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
    private static let gripHiddenAlpha: CGFloat = 0
    private static let gripShownAlpha: CGFloat = 0.85

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
