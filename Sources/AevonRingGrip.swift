import UIKit

/// 圆盘呼出把手（V0.2.50，AevonRingGripV250；V0.2.55 物理化重构 AevonRingGripV255）。
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
/// V0.2.55（AevonRingGripV255）为什么把识别器从全屏宿主移到 handle 子视图上
/// ------------------------------------------------------------------------
/// 0.2.50 起把手是「一个 frame=容器全屏的宿主视图 + hitTest 只在把手矩形返回 self」，
/// 两个识别器（pan / tap）挂在**宿主**上。命中归属在教科书规则下没问题
/// （识别器只收 hitTest 命中链上的触摸），但 Aevon(29) 实测「tap 活、全系统 pan 死」
/// —— SB 进程里挂着「全屏视图 + 常驻识别器」是唯一的结构性异常，
/// PullOver 逆向（POHandle）与 PassThroughWindow（Livsy90）的成熟做法都是
/// **识别器挂在真实控件上、宿主不持有任何识别器**。本版照做：
///   · 宿主 view 依旧全屏透明，hitTest 只在命中区返回 handle（不返回宿主自身）；
///   · handle 是 frame = 命中区（74×62）的真实控件，pan / tap 都挂在它上面；
///   · 手势参与范围从「全屏宿主的 hitTest 链」收窄为「74×62 的 handle 一块」；
///   · 位置定档（用户 Aevon(29) #4）：屏幕右缘、**从底部起 30% 高度**处
///     （0.2.50 的 0.45 单手够不着）。
final class AevonRingGripView: UIView {
    /// 视觉尺寸
    static let handleSize: CGFloat = 34
    /// 命中区外扩：向屏幕内侧 40pt、上下各 14pt
    static let hitOutsetX: CGFloat = 40
    static let hitOutsetY: CGFloat = 14
    /// 垂直位置（占屏幕高度比例）—— V0.2.55 定档：从屏幕底部起 30%。
    /// （0.2.50 是 0.45，用户 Aevon(29) #4：「移动到屏幕右侧从下开始计算的 30% 处」。）
    static let centerRatio: CGFloat = 0.70

    /// 命中与手势的承载视图（V0.2.55）：frame = 命中区，识别器都挂在它上面。
    private let handle = UIView()
    /// 视觉块（34pt 圆角块 + 图标），挂在 handle 里居中，不参与交互。
    private let visual = UIView()
    private let glyph = UIImageView()
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
        visual.backgroundColor = UIColor(white: 1.0, alpha: 0.14)
        visual.layer.cornerRadius = AevonRingGripView.handleSize * 0.28
        visual.layer.cornerCurve = .continuous
        visual.layer.borderWidth = 0.5
        visual.layer.borderColor = UIColor(white: 1.0, alpha: 0.22).cgColor
        handle.addSubview(visual)

        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        glyph.image = UIImage(systemName: "chevron.left", withConfiguration: config)
        glyph.tintColor = UIColor(white: 1.0, alpha: 0.75)
        glyph.contentMode = .scaleAspectFit
        visual.addSubview(glyph)

        // V0.2.55（AevonRingGripV255）：识别器全部挂 handle（真实控件），
        // 全屏宿主不再持有任何识别器。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        handle.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        handle.addGestureRecognizer(tap)
        // 单击必须等拖动失败（拖动优先，和 PullOver 的 tap/longPress 次序同构）
        tap.require(toFail: pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = AevonRingGripView.handleSize
        // 命中区中心 = 屏幕右缘向内 (size+outset)/2、纵向 centerRatio 处
        let cy = bounds.height * AevonRingGripView.centerRatio
        let cx = bounds.width - (size + AevonRingGripView.hitOutsetX) / 2
        handle.frame = CGRect(x: cx - (size + AevonRingGripView.hitOutsetX) / 2,
                              y: cy - (size + AevonRingGripView.hitOutsetY * 2) / 2,
                              width: size + AevonRingGripView.hitOutsetX,
                              height: size + AevonRingGripView.hitOutsetY * 2)
        visual.frame = CGRect(x: handle.bounds.width - size,
                              y: (handle.bounds.height - size) / 2,
                              width: size, height: size)
        glyph.frame = visual.bounds
    }

    /// 命中区 = handle 的 frame（把手视觉矩形向左扩 40pt、上下各扩 14pt）。
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

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !didSummon else { return }
        didSummon = true
        AevonLog.info("[圆盘] 把手被点 → 呼出圆盘（可见把手入口，不再靠右缘盲带判向）"
            + "（AevonRingGripV250 AevonRingGripV255）")
        onSummon?("ringgrip")
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            didSummon = false
            visual.alpha = 1.0
        case .changed:
            guard !didSummon else { break }
            let delta = gesture.translation(in: self)
            if delta.x < -14, abs(delta.y) < 30 {
                didSummon = true
                AevonLog.info("[圆盘] 把手被左滑 \(Int(delta.x))pt → 呼出圆盘"
                    + "（AevonRingGripV250 AevonRingGripV255）")
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
    private static var lastInstalledAt: CFTimeInterval = 0

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
        AevonLog.info("[圆盘] 右缘可见把手已就位（\(Int(AevonRingGripView.handleSize))pt 圆角块，"
            + "命中区向外扩 \(Int(AevonRingGripView.hitOutsetX))pt，把手外一律不拦，"
            + "识别器挂在真实控件上，全屏宿主零识别器）"
            + "（AevonRingGripV250 AevonRingGripV255）")
    }

    /// 圆盘展开时藏起来（避免它压在圆盘上），收起后再出来。
    static func setVisible(_ visible: Bool) {
        guard let grip = grip else { return }
        if grip.isHidden != !visible { grip.isHidden = !visible }
    }

    static var isInstalled: Bool { return grip?.superview != nil }
}
