import UIKit

/* V0.3.20（AevonKeyframeHoverV320）→ V0.3.21（AevonHoverJumpV321）：
 * 圆盘图标的划过动画 —— **定长关键帧引擎**，本版把波形整体换成「一次起跳、必须触地」。
 *
 * ═══ 0.3.20 为什么「只在原地抖动」（Aevon(97) 取证）═══
 *
 * 帧率那一半已经满分：**119.8fps / 4083 帧 / 最大间隔 35.9ms / >16.7ms 只有 2 帧**。
 * 所以剩下的问题不在渲染，在**时间尺度与波形**：
 *
 * ① 时间尺度差 6.5 倍。
 *    34.09 秒里 494 次划过 ⇒ **平均 69ms 一个切换**；
 *    而 0.3.20 的 rise 200ms + land 250ms = 450ms。**每个图标的动画平均只播到 15%**
 *    就被改目标。谁都走不完一次起落，叠起来只剩抖动。
 *
 * ② 波形本身就是「抖」，不是「跳」。
 *    0.3.20 的 lift 轨道是 0 → 11(24ms) → 16(48ms) → 9.2 → 13.6 → 10.6 → 12.5 → 12：
 *    位移在 48ms 就到顶，之后 152ms 一直困在 9.2~16 之间以约 12Hz 往复（振幅 6.8pt），
 *    末态还停在 12pt 不落地 —— 没有「离地 → 触地」的对比，眼睛读到的就是原地高频抖。
 *
 * ③ **矩阵顺序把位移和缩放耦合在一起**（这一条最隐蔽）。
 *    `CATransform3DConcat(a, b)` 是 `a·b`，点按 `p' = p·a·b` 变换 ⇒ **a 先生效**。
 *    旧代码写 `Concat(Translation, Scale)` ⇒ 先平移再缩放 ⇒ **平移量被 sy 放大**，
 *    实际抬升 = `lift × sy`。而 sy 正好在以 12Hz 振荡（1.12~1.38），于是
 *    **垂直位置被叠了一层同频抖动，幅度比 6.8pt 还大**。这才是「抖」的放大来源。
 *    现在改成 `Concat(Scale, Translation)`：先缩放、再精确平移 ——
 *    `lift` 就是屏幕上的 pt 数，一个子像素都不差。
 *
 * ═══ 本版（用户 Aevon(97) 定档「方案 A · 单跳落地」）═══
 *
 *   · 起跳 → 触地 → 落定，**单峰、主形变 66ms 内收完**；
 *   · 峰值 **32pt**（图标 35pt 的 91%）在 t=34ms，t=66ms 已回到地面；
 *   · **触地时刻（66ms）早于下一次切换（69ms）** —— 被打断时 `sample()` 接住的姿态
 *     已接近地面，不会累积偏移。这是「抖」从结构上消失的原因；
 *   · 稳态 **不抬起**（`hoverLift = 0`）、放大 1.18：高亮靠蓝框 + 略微放大辨认，
 *     不再有「浮在半空」的常驻偏移；
 *   · 缩放全程放大幅度可见：起跳拉伸 1.26、触地压扁 0.81、回弹 1.24、落定 1.18。
 *
 * 关键帧的第二个好处不变：**可以纯数学求值**。中途改目标时用 `sample(_:at:)` 取当前值，
 * 不需要问渲染服务器，所以永远不会回到 `finishAnimation(at: .current)` 那个往返。
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
        /* ⛔ 顺序就是语义：`CATransform3DConcat(a, b)` = `a·b`，点走 `p' = p·a·b`，
         * 也就是 **a 先生效**。要「先绕中心缩放、再精确上移 lift pt」，必须是
         * `Concat(Scale, Translation)`。
         *
         * V0.3.21（AevonHoverJumpV321）修正：0.3.20 写的是 `Concat(Translation, Scale)`,
         * 等于先平移再缩放 ⇒ **平移量被 sy 乘了一遍**（实测抬升 = lift × sy）。
         * sy 在 1.12~1.38 之间以 12Hz 振荡，于是垂直位置被叠了一层同频抖动 ——
         * 这正是 Aevon(97)「只在原地抖动」的放大来源。改过来之后 lift 就是 pt 原值。 */
        return CATransform3DConcat(CATransform3DMakeScale(sx, sy, 1),
                                   CATransform3DMakeTranslation(0, -lift, 0))
    }
}

/// 关键帧的用途 —— 只影响分段缓动（下落要加速、触地要骤停）。
enum AevonHoverStyle {
    case rise
    case land
    case entrance
}

enum AevonHoverKeyframes {

    /// 划过起跳：**一次单峰起落**，90ms 回到地面（V0.3.21 AevonHoverJumpV321）。
    ///
    /// lift 轨道：0 → 19.0(16ms 起跳拉伸) → **32.0(34ms 顶点)** → 5.0(56ms 下落)
    ///          → 0(66ms **触地**) → 0 → 0。
    /// **只有一个峰、必然触地** —— 这是「向上跳起然后回落」的字面实现。
    /// 66ms 触地早于 69ms 的平均切换间隔，被打断时接住的姿态已经在地面附近。
    ///
    /// 缩放轨道：起跳时 **竖向拉长**（1.10/1.26，sx·sy = 1.39 体积膨胀），
    /// 顶点横向铺开（1.26/1.16），触地 **压扁**（0.92/0.88，sx·sy = 0.81），
    /// 回弹 1.24/1.22，落定 1.18 = `hoverScale`。放大幅度全程可见 —— 用户点名要的
    /// 「跳起来时有放大效果」就在这条轨道上，不靠抬升制造存在感。
    static let riseKeys: [AevonHoverKey] = [
        AevonHoverKey(t: 0.000, lift: 0.0, sx: 1.00, sy: 1.00),
        AevonHoverKey(t: 0.016, lift: 19.0, sx: 1.10, sy: 1.26),
        AevonHoverKey(t: 0.034, lift: 32.0, sx: 1.26, sy: 1.16),
        AevonHoverKey(t: 0.056, lift: 5.0, sx: 1.04, sy: 0.99),
        AevonHoverKey(t: 0.066, lift: 0.0, sx: 0.92, sy: 0.88),
        AevonHoverKey(t: 0.082, lift: 0.0, sx: 1.24, sy: 1.22),
        AevonHoverKey(t: 0.090, lift: 0.0, sx: AevonRingMenu.hoverScale, sy: AevonRingMenu.hoverScale),
    ]

    /// 划过落地（离开该图标）：**只有缩放回落，没有位移**，60ms 归零。
    ///
    /// 因为方案 A 的稳态本来就在地面（`hoverLift = 0`），起跳那 32pt 已经在 `rise`
    /// 里完整地「上去又下来」了。所以 land 只剩「把 1.18 的放大收回去」，
    /// 顺手带一点点回压 —— 再给它加位移就会变成第二次跳，又回到「抖」。
    static let landKeys: [AevonHoverKey] = [
        AevonHoverKey(t: 0.000, lift: 0.0, sx: AevonRingMenu.hoverScale, sy: AevonRingMenu.hoverScale),
        AevonHoverKey(t: 0.030, lift: 0.0, sx: 0.99, sy: 0.99),
        AevonHoverKey(t: 0.060, lift: 0.0, sx: 1.00, sy: 1.00),
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

    /// 高亮稳态（划过之后停住的样子）。
    ///
    /// V0.3.21（AevonHoverJumpV321）：`hoverLift` 从 12 改成 **0** —— 用户 Aevon(97)
    /// 要的是「向上跳起然后回落」，落下来就该在地面上；常驻的 12pt 抬起读起来像
    /// 「一直浮着」。跳跃感全部由 `riseKeys` 那 90ms 提供，稳态只留 1.18 的放大 + 蓝框。
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

    /// 分段缓动：**起手要快、下落要加速、触地要骤停** —— 这三条就是「重量感」。
    ///
    /// V0.3.21（AevonHoverJumpV321）：rise 的 6 段按新波形重排 ——
    ///   段 0（0→19 起跳）easeOut 快速出手；
    ///   段 1（19→32 到顶）easeOut 减速；
    ///   段 2、3（32→5→0 下落并触地）easeIn **加速**，这是重力；
    ///   段 4（触地压扁→回弹）easeBoth；
    ///   段 5（回弹→落定）easeOut。
    /// 0.3.20 那版下落段用的是 easeInEaseOut，起步慢、落下来软，读起来像「飘」。
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
                if index == 0 { return easeOut }
                if index == 1 { return easeOut }
                if index == 2 || index == 3 { return easeIn }
                if index == count - 1 { return easeOut }
                return easeBoth
            case .entrance:
                return index < 2 ? easeOut : easeBoth
            }
        }
    }
}
