import UIKit

/* V0.3.45（AevonFloatMotionV345，用户 Aevon(115)「这次好多了。没有黑屏和闪了，
 * 接下来开始为悬浮窗的所有交互制作动画」）。
 *
 * 浮窗交互动画的唯一入口。参数与圆盘同一族 —— 全部经 `AevonSpring.params`
 * 的 (response, ζ) 换算，这样浮窗和圆盘的手感是同一个物理模型，不是两套经验值。
 * 手感档位由用户 2026-10-31 定档：**轻弹 ζ0.85**。
 *
 * ⛔ 分三层不是审美分类，是**风险分类**：
 *
 *   A 装饰层（白条淡入、按压脉冲、光晕/投影淡变、触觉）
 *     只碰我方视图的 layer / alpha，零几何 ⇒ 不触发 layoutSubviews、
 *     不重设呈现层缩放 ⇒ 结构上不可能引起掉画或黑屏。
 *
 *   B 物理层（拖动惯性、越界橡皮筋、缩放回弹、停靠进出）
 *     每帧改 frame + layoutIfNeeded。这条路 0.2.50 起就在用（0.22s 停靠动画、
 *     0.30s 避让弹簧），历史未翻车；但动画期间**必须维持 `setMovingWindow(true)`
 *     那套降载**（暂停熄屏重申、取消抓帧），否则每帧合成会撞上运行时探测。
 *     另有一条硬纪律：落盘几何（persistFrame）只能在动画 completion 里做，
 *     中途落盘会把中间值写进「主窗位置记忆」。
 *
 *   C 内容层（关窗离场、开窗显形）
 *     关窗靠离场帧垫底（0.2.49 验证过的形状，但那次是 0.18s 淡出 + 0.97 缩小，
 *     与现在的画布恒定模型不冲突）；开窗**只许纯缩放、alpha 恒 1** ——
 *     0.2.85 的「缩放 0.965 + 0.34s 淡入」与 0.2.87 的「0.12s 淡入」都被用户
 *     打回过（「先闪一下悬浮窗，然后出现最终悬浮窗和内容」「从虚到实，很别扭」），
 *     淡入在这条链路上一律是负资产。
 *
 * 四个开关各自独立，出问题可以只关一层：
 *   AevonFloatMotionOff345（全关）/ AevonMotionPhysicsOff345 /
 *   AevonMotionDecorOff345 / AevonMotionRevealOff345 / AevonCloseFadeOff345
 */
enum AevonFloatMotion {

    // MARK: - 参数表

    /// 一组弹簧：`response` = 一个振荡周期（秒），`damping` = 阻尼比 ζ。
    struct Spec {
        let response: Double
        let damping: Double

        var timing: UISpringTimingParameters {
            return AevonSpring.params(response: response, dampingFraction: damping)
        }
    }

    /// 拖动落位。Apple 官方 PiP 重定位是 ζ1.0 / response 0.40（无过冲）；
    /// 用户选了轻弹档，ζ 取 0.88 —— 过冲约 1.2%，肉眼是「沉下去」而不是「弹起来」。
    static let settle = Spec(response: 0.40, damping: 0.88)

    /// 停靠吸附 / 装回主窗。比落位快一点、比它弹一点，「吸过去」那一下。
    static let snap = Spec(response: 0.34, damping: 0.85)

    /// 回弹（越界橡皮筋松手、预备态未达判据回位）。
    static let rebound = Spec(response: 0.32, damping: 0.78)

    /// 开窗整窗缩放。
    static let reveal = Spec(response: 0.34, damping: 0.85)

    /// 按压脉冲（停靠小窗轻点「点一下装回」）。
    static let press = Spec(response: 0.24, damping: 0.80)

    /// 拖动越界橡皮筋系数与最大越界量。
    ///
    /// 上限 24pt 是硬约束：0.2.48 修过「窗口可以停到只露 60pt → 手柄抓不到 → 拖丢」，
    /// 边条手柄的压边只有 10pt（向窗内），越界超过 24pt 时手柄仍在屏内，
    /// 但再往外就没有意义了 —— 手指继续推、窗口几乎不动，读作「到头了」。
    static let rubberFactor: CGFloat = 0.12
    static let rubberMax: CGFloat = 24

    /// 动量投影的减速率与位移上限。
    ///
    /// Apple 的 `project(initialVelocity:decelerationRate:)` 是
    /// `v/1000 × r/(1-r)`：0.998（系统滚动默认）→ 0.499，1000pt/s 会甩出半屏，
    /// 对一个整窗来说太远。0.996 → 0.249，再夹 220pt（约 1/4 屏高）。
    static let decelerationRate: Double = 0.996
    static let projectCap: CGFloat = 220

    // MARK: - 开关

    /// 一次读取全部开关。**只在动作起点调**（拖动开始 / 停靠 / 关窗 / 开窗），
    /// 不许进逐帧路径 —— `AevonPrefs` 走 CFPreferences，是跨进程 IPC。
    struct Switches {
        var physics = true
        var decor = true
        var reveal = true
        var closeFade = true
    }

    static func readSwitches() -> Switches {
        if AevonPrefs.bool("AevonFloatMotionOff345", default: false) {
            return Switches(physics: false, decor: false, reveal: false, closeFade: false)
        }
        return Switches(
            physics: !AevonPrefs.bool("AevonMotionPhysicsOff345", default: false),
            decor: !AevonPrefs.bool("AevonMotionDecorOff345", default: false),
            reveal: !AevonPrefs.bool("AevonMotionRevealOff345", default: false),
            closeFade: !AevonPrefs.bool("AevonCloseFadeOff345", default: false))
    }

    // MARK: - 物理量换算

    /// 动量投影：手指以 `velocity`(pt/s) 甩出，落到哪里。
    static func project(_ velocity: CGFloat) -> CGFloat {
        let r = CGFloat(min(max(decelerationRate, 0.90), 0.999))
        let d = (velocity / 1000.0) * r / (1.0 - r)
        return min(max(d, -projectCap), projectCap)
    }

    /// 弹簧的初始速度要的是**相对速度**（每秒走完剩余距离的多少倍），
    /// 单位 1/s。不做归一化的话，同样的手感在实际距离很短时会弹得像在抽搐。
    static func relativeVelocity(_ velocity: CGFloat, distance: CGFloat) -> CGFloat {
        guard abs(distance) > 0.5 else { return 0 }
        return min(max(velocity / distance, -60), 60)
    }

    // MARK: - 执行器

    /// 几何弹簧：把 `view` 的 frame 弹到 `target`。
    ///
    /// 传入的手势速度会被换算成相对速度；`animations` 里可以顺带改同一批次里
    /// 其它要跟帧插值的东西（圆角、光晕几何）。**completion 里才能落盘**。
    @discardableResult
    static func animateGeometry(_ view: UIView,
                                to target: CGRect,
                                spec: Spec,
                                velocity: CGPoint = .zero,
                                animations: (() -> Void)? = nil,
                                completion: (() -> Void)? = nil) -> UIViewPropertyAnimator {
        let dx = target.midX - view.center.x
        let dy = target.midY - view.center.y
        let v = CGVector(dx: relativeVelocity(velocity.x, distance: dx),
                         dy: relativeVelocity(velocity.y, distance: dy))
        let params = AevonSpring.params(response: spec.response,
                                        dampingFraction: spec.damping,
                                        initialVelocity: v)
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: params)
        animator.addAnimations {
            view.frame = target
            animations?()
        }
        animator.addCompletion { _ in completion?() }
        animator.startAnimation()
        return animator
    }

    /// transform 弹簧（不碰 frame）—— 按压脉冲、开窗缩放都走这条。
    @discardableResult
    static func animateTransform(_ view: UIView,
                                 to transform: CGAffineTransform,
                                 spec: Spec,
                                 completion: (() -> Void)? = nil) -> UIViewPropertyAnimator {
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: spec.timing)
        animator.addAnimations { view.transform = transform }
        animator.addCompletion { _ in completion?() }
        animator.startAnimation()
        return animator
    }

    /// 纯时间曲线（淡变）。**只给装饰层用** —— 显形链路不许走这条。
    static func animateAlpha(_ view: UIView,
                             to alpha: CGFloat,
                             duration: TimeInterval,
                             curve: UIView.AnimationCurve = .easeOut,
                             completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: duration, delay: 0,
                       options: [curve.asOptions, .allowUserInteraction, .beginFromCurrentState],
                       animations: { view.alpha = alpha },
                       completion: { _ in completion?() })
    }

    // MARK: - 触觉

    /// 与圆盘同一套发生器用法（SB 里不需要 prepare/一实例复用，圆盘就是这样）。
    static func hapticLight() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func hapticMedium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

private extension UIView.AnimationCurve {
    var asOptions: UIView.AnimationOptions {
        switch self {
        case .easeInOut: return .curveEaseInOut
        case .easeIn: return .curveEaseIn
        case .easeOut: return .curveEaseOut
        case .linear: return .curveLinear
        @unknown default: return .curveEaseOut
        }
    }
}
