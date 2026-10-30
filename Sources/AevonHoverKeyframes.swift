import UIKit

/* V0.3.20（AevonKeyframeHoverV320）：圆盘图标的划过动画 —— **定长关键帧引擎**。
 *
 * 为什么把弹簧整条换掉（Aevon(96) 取证）：
 *
 * ① 「上一个还在空中」不是它忘了落地，是它永远落不了地。
 *    0.3.19 的余韵按**队列下标**取振幅 [1.0, 0.60, 0.32, 0.14]、response 再乘
 *    [1, 1.25, 1.55, 1.85]，沉降到 1% 分别要 0.34 / 0.43 / 0.53 / 0.63 秒；
 *    而实测划过间隔中位数只有 72~100ms。**每个图标还没走到目标就被改目标**，
 *    身后于是形成一条永不落地的人形扇（10pt / 5pt / 2pt）。用户看到的就是这条扇。
 *
 * ② 「丢帧」= 每图标一条弹道 + `finishAnimation(at: .current)`。
 *    一次切换影响 5 个图标、×12 次/秒 = 60 次/秒重建 animator，每次 `stopAnimation(false)`
 *    + `finishAnimation(at: .current)` 都要取**当前呈现值**（渲染服务器往返）。
 *    120Hz 每帧预算 9.26ms，这一项本身就够造成可见顿挫。
 *
 * ③ animate.css 的 `rubberBand` / `shakeY` 之所以看着「Q 且顺」，不是因为数值，
 *    而是因为它们是**定长、一次播完、不 retarget** 的关键帧：
 *      · `shakeY`   = ±10px 定长上下抖，起止都回 0 —— 它一定会结束；
 *      · `rubberBand` = **非等比**的挤压往复（scaleX 1.25 / scaleY 0.75 → 0.75 / 1.25 …），
 *        「Q 弹」的物理来源就是这组体积守恒的 squash & stretch，等比放大只会「变大」。
 *
 * 所以这里同时用两者：**抬升走 shakeY 的衰减抖动，缩放走 rubberBand 的挤压往复**。
 * 手指扫过时 A 升起、B 在 72ms 后升起、A 同时开始落地 —— 真正的「先后起伏」，
 * 而且任意时刻最多两三个图标在空中。
 *
 * 关键帧的另一半好处：**可以纯数学求值**。中途改目标时用 `sample(_:at:)` 取当前值，
 * 不需要问渲染服务器，所以不会再出现 `finishAnimation(at: .current)` 那个往返。
 */

/// 一帧关键帧：上抬 pt + 非等比缩放。
struct AevonHoverKey {
    /// 相对动画起点的秒数（严格递增，首帧必须为 0）
    let t: CGFloat
    /// 上抬高度（pt，正值 = 向上）
    let lift: CGFloat
    let sx: CGFloat
    let sy: CGFloat
}

/// 某一时刻的姿态（可换算成 `CATransform3D`）。
struct AevonHoverSample {
    let lift: CGFloat
    let sx: CGFloat
    let sy: CGFloat

    /// 落地 / 未高亮状态
    static let ground = AevonHoverSample(lift: 0, sx: 1, sy: 1)

    func transform3D() -> CATransform3D {
        // 先缩放（绕 layer 锚点 = 中心）再上移 —— 顺序反了会绕左上角放大。
        return CATransform3DConcat(CATransform3DMakeTranslation(0, -lift, 0),
                                   CATransform3DMakeScale(sx, sy, 1))
    }
}

/// 关键帧的用途 —— 只影响分段缓动（下落要加速、触地要骤停）。
enum AevonHoverStyle {
    case rise
    case land
    case entrance
}

enum AevonHoverKeyframes {

    /// 划过升起：**shakeY 的抖动 × rubberBand 的挤压**，200ms 停在 (12pt, 1.30)。
    ///
    /// lift 轨道：0 → 16.0（冲过目标 4pt）→ 9.2（回落）→ 13.6 → 10.6 → 12.5 → 12.0，
    /// 三个来回、逐次收敛，就是 animate__shakeY 的「抖」。
    /// 缩放轨道：sx / sy 交替反向（1.20/1.12 → 1.12/1.30 → 1.34/1.22 → 1.22/1.38 …），
    /// `sx·sy` 从 1.34 稳步爬到 1.69 = 1.30²，**体积守恒** —— 这就是 rubberBand 的「捏」。
    static let riseKeys: [AevonHoverKey] = [
        AevonHoverKey(t: 0.000, lift: 0, sx: 1.00, sy: 1.00),
        AevonHoverKey(t: 0.024, lift: 11.0, sx: 1.20, sy: 1.12),
        AevonHoverKey(t: 0.048, lift: 16.0, sx: 1.12, sy: 1.30),
        AevonHoverKey(t: 0.080, lift: 9.2, sx: 1.34, sy: 1.22),
        AevonHoverKey(t: 0.112, lift: 13.6, sx: 1.22, sy: 1.38),
        AevonHoverKey(t: 0.144, lift: 10.6, sx: 1.30, sy: 1.28),
        AevonHoverKey(t: 0.172, lift: 12.5, sx: 1.28, sy: 1.32),
        AevonHoverKey(t: 0.200, lift: 12.0, sx: AevonRingMenu.hoverScale, sy: AevonRingMenu.hoverScale),
    ]

    /// 划过落地：**触地压扁 + 一记余弹**，250ms 归零。
    ///
    /// lift 走 12 → 3.0 → **−1.8**（沉到地面以下）→ 2.6 → −0.5 → 0.6 → 0；
    /// 缩放走 1.30 → 0.93/0.89（**压扁**，`sx·sy` = 0.83）→ 1.06（弹回）→ 0.98 → 1.00。
    /// 中间那记「压扁 → 弹起 → 再轻轻触一次」就是用户要的「落地再弹一次」，
    /// 也是唯一保留的余韵 —— 它会**一定结束**，不像 0.3.19 的队列那样挂在空中。
    static let landKeys: [AevonHoverKey] = [
        AevonHoverKey(t: 0.000, lift: 12.0, sx: AevonRingMenu.hoverScale, sy: AevonRingMenu.hoverScale),
        AevonHoverKey(t: 0.048, lift: 3.0, sx: 1.13, sy: 1.11),
        AevonHoverKey(t: 0.086, lift: -1.8, sx: 0.93, sy: 0.89),
        AevonHoverKey(t: 0.124, lift: 2.6, sx: 1.06, sy: 1.05),
        AevonHoverKey(t: 0.162, lift: -0.5, sx: 0.98, sy: 0.98),
        AevonHoverKey(t: 0.205, lift: 0.6, sx: 1.012, sy: 1.012),
        AevonHoverKey(t: 0.250, lift: 0.0, sx: 1.00, sy: 1.00),
    ]

    /// 展开入场：0.30 → 1.06（过冲）→ 0.975（回压）→ 1.00，520ms。
    ///
    /// V0.3.20（AevonKeyframeHoverV320，性能包 P5）：入场也从 `UIViewPropertyAnimator`
    /// 搬进这套引擎 —— 否则入场动画和划过动画会同时写 `layer.transform`，
    /// 呼盘后立刻划过就有一下跳变。现在 `layer.transform` 只有这一个主人。
    static let entranceKeys: [AevonHoverKey] = [
        AevonHoverKey(t: 0.000, lift: 0, sx: 0.30, sy: 0.30),
        AevonHoverKey(t: 0.300, lift: 0, sx: 1.06, sy: 1.06),
        AevonHoverKey(t: 0.405, lift: 0, sx: 0.975, sy: 0.975),
        AevonHoverKey(t: 0.520, lift: 0, sx: 1.00, sy: 1.00),
    ]

    static var riseDuration: CFTimeInterval { CFTimeInterval(riseKeys[riseKeys.count - 1].t) }
    static var landDuration: CFTimeInterval { CFTimeInterval(landKeys[landKeys.count - 1].t) }
    static var entranceDuration: CFTimeInterval { CFTimeInterval(entranceKeys[entranceKeys.count - 1].t) }

    /// 抬起稳态（划过之后停住的样子）。
    static let lifted = AevonHoverSample(lift: AevonRingMenu.hoverLift,
                                         sx: AevonRingMenu.hoverScale,
                                         sy: AevonRingMenu.hoverScale)

    /// 纯数学求值 —— **不碰 `layer.presentation()`**，这是本版不掉帧的关键。
    ///
    /// 关键帧是自己定的表，任意时刻的值就是个分段线性函数；分段内不套缓动
    ///（与 `timingFunctions` 有一点点差），差值在 8~16ms 的一帧里不到 0.3pt，
    /// 肉眼不可见，换来的是「中途改目标时不需要向渲染服务器要呈现值」。
    static func sample(_ keys: [AevonHoverKey], at time: CGFloat) -> AevonHoverSample {
        guard let first = keys.first, let last = keys.last else { return .ground }
        if time <= first.t {
            return AevonHoverSample(lift: first.lift, sx: first.sx, sy: first.sy)
        }
        if time >= last.t {
            return AevonHoverSample(lift: last.lift, sx: last.sx, sy: last.sy)
        }
        var index = 1
        while index < keys.count {
            let a = keys[index - 1]
            let b = keys[index]
            if time <= b.t {
                let span = b.t - a.t
                let k = span > 0.0001 ? (time - a.t) / span : 1
                return AevonHoverSample(lift: a.lift + (b.lift - a.lift) * k,
                                        sx: a.sx + (b.sx - a.sx) * k,
                                        sy: a.sy + (b.sy - a.sy) * k)
            }
            index += 1
        }
        return AevonHoverSample(lift: last.lift, sx: last.sx, sy: last.sy)
    }

    /// 造一条 `CAKeyframeAnimation(keyPath: "transform")`。
    ///
    /// `from` 替换掉表里第一帧：中途改目标时用它接住「此刻的姿态」，线段因此连续，
    /// 不需要 `stopAnimation` / `finishAnimation`，也就没有那次渲染服务器往返。
    static func animation(_ keys: [AevonHoverKey],
                          from: AevonHoverSample,
                          style: AevonHoverStyle) -> CAKeyframeAnimation {
        var samples: [AevonHoverSample] = [from]
        var times: [CGFloat] = [0]
        for key in keys.dropFirst() {
            samples.append(AevonHoverSample(lift: key.lift, sx: key.sx, sy: key.sy))
            times.append(key.t)
        }
        let total = keys[keys.count - 1].t
        let denom = total > 0.0001 ? total : 1

        let anim = CAKeyframeAnimation(keyPath: "transform")
        // ⛔ 必须包成 NSValue(caTransform3D:)：`transform` 这条 keyPath 只认 NSValue，
        // 直接塞 `[CATransform3D]` 会被当成一堆无法解释的 Any，动画不生效（静默）。
        anim.values = samples.map { NSValue(caTransform3D: $0.transform3D()) }
        anim.keyTimes = times.map { NSNumber(value: Double($0 / denom)) }
        anim.duration = CFTimeInterval(total)
        anim.timingFunctions = timingFunctions(count: samples.count - 1, style: style)
        anim.fillMode = .forwards
        // 模型值在动手之前就已经写成「终点」，所以动画结束即可摘掉，不会闪。
        anim.isRemovedOnCompletion = true
        return anim
    }

    /// 分段缓动：落下要**加速**（easeIn），触地弹起要**骤停**（easeOut），
    /// 其余用 easeInEaseOut。这条规则就是「重量感」的来源。
    private static func timingFunctions(count: Int, style: AevonHoverStyle) -> [CAMediaTimingFunction] {
        let easeIn = CAMediaTimingFunction(name: .easeIn)
        let easeOut = CAMediaTimingFunction(name: .easeOut)
        let easeBoth = CAMediaTimingFunction(name: .easeInEaseOut)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            switch style {
            case .land:
                if index < 2 { return easeIn }
                if index == 2 { return easeOut }
                return easeBoth
            case .rise:
                return index == 0 ? easeOut : easeBoth
            case .entrance:
                return index < 2 ? easeOut : easeBoth
            }
        }
    }
}
