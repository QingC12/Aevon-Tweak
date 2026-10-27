import UIKit

/// 圆盘呼出把手（V0.2.50，AevonRingGripV250）。
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
/// 本版做法
/// --------
/// · 屏幕右缘中部一个 34×34 的圆角把手（半透明，SF Symbol 折线），
///   它的**命中区比视觉大**（向左扩 40pt、上下各扩 14pt，PullOver 的 `pointInside`
///   外扩同思路），所以实际可点范围 ≈ 74×62，比原来 18×247 的「盲带」好瞄得多；
/// · 点一下 = 呼出圆盘；左滑 ≥14pt = 呼出圆盘（两个识别器互斥，与 PullOver 的
///   tap / longPress 拆分同构）；
/// · 把手以外的地方一律 `nil` —— 系统继续往 App 派发，**不吞、不补投、不延迟**，
///   所以全屏 App 里右缘该有的系统手势一个都不少；
/// · 浮窗压在把手上时自动让路（隐藏），避免「点把手指令把窗拖走了」的观感。
final class AevonRingGripView: UIView {
    /// 视觉尺寸
    static let handleSize: CGFloat = 34
    /// 命中区外扩：向屏幕内侧 40pt、上下各 14pt
    static let hitOutsetX: CGFloat = 40
    static let hitOutsetY: CGFloat = 14
    /// 垂直位置（占屏幕高度）—— 放在中上部，避开底部手势条与顶部状态栏
    static let centerRatio: CGFloat = 0.45

    private let handle = UIView()
    private let glyph = UIImageView()
    private var didSummon = false

    var onSummon: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        isAccessibilityElement = false

        handle.isUserInteractionEnabled = false
        handle.backgroundColor = UIColor(white: 1.0, alpha: 0.14)
        handle.layer.cornerRadius = AevonRingGripView.handleSize * 0.28
        handle.layer.cornerCurve = .continuous
        handle.layer.borderWidth = 0.5
        handle.layer.borderColor = UIColor(white: 1.0, alpha: 0.22).cgColor
        addSubview(handle)

        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        glyph.image = UIImage(systemName: "chevron.left", withConfiguration: config)
        glyph.tintColor = UIColor(white: 1.0, alpha: 0.75)
        glyph.contentMode = .scaleAspectFit
        handle.addSubview(glyph)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        // 单击必须等拖动失败（拖动优先，和 PullOver 的 tap/longPress 次序同构）
        tap.require(toFail: pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = AevonRingGripView.handleSize
        let x = bounds.width - size
        let y = bounds.height * AevonRingGripView.centerRatio - size / 2
        handle.frame = CGRect(x: x, y: y, width: size, height: size)
        glyph.frame = handle.bounds
    }

    /// 命中区 = 把手矩形外扩（比视觉大得多，手指不用瞄）。
    private var hitRect: CGRect {
        let size = AevonRingGripView.handleSize
        let x = bounds.width - size
        let y = bounds.height * AevonRingGripView.centerRatio - size / 2
        return CGRect(x: x - AevonRingGripView.hitOutsetX,
                      y: y - AevonRingGripView.hitOutsetY,
                      width: size + AevonRingGripView.hitOutsetX,
                      height: size + AevonRingGripView.hitOutsetY * 2)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, alpha > 0.01 else { return false }
        return hitRect.contains(point)
    }

    override func hitTest(_ p: CGPoint, with event: UIEvent?) -> UIView? {
        // 把手之外一律 nil：系统继续往 App 派发，不产生任何争抢。
        // （参数叫 p 不叫 point：hitTest 的参数会遮蔽 UIView.point(inside:with:)）
        guard point(inside: p, with: event) else { return nil }
        return self
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !didSummon else { return }
        didSummon = true
        AevonLog.info("[圆盘] 把手被点 → 呼出圆盘（可见把手入口，不再靠右缘盲带判向）"
            + "（AevonRingGripV250）")
        onSummon?("ringgrip")
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            didSummon = false
            handle.alpha = 1.0
        case .changed:
            guard !didSummon else { break }
            let delta = gesture.translation(in: self)
            if delta.x < -14, abs(delta.y) < 30 {
                didSummon = true
                AevonLog.info("[圆盘] 把手被左滑 \(Int(delta.x))pt → 呼出圆盘"
                    + "（AevonRingGripV250）")
                onSummon?("ringgrip")
            }
        case .ended, .cancelled, .failed:
            handle.alpha = 0.85
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
    static func installIfNeeded(force: Bool = false) {
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
            + "命中区向外扩 \(Int(AevonRingGripView.hitOutsetX))pt，把手外一律不拦）"
            + "（AevonRingGripV250）")
    }

    /// 圆盘展开时藏起来（避免它压在圆盘上），收起后再出来。
    static func setVisible(_ visible: Bool) {
        guard let grip = grip else { return }
        if grip.isHidden != !visible { grip.isHidden = !visible }
    }

    static var isInstalled: Bool { return grip?.superview != nil }
}
