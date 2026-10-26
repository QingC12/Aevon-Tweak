import UIKit
import QuartzCore

/// V0.2.13（AevonSysEdgeV213）：右缘「左滑呼圆盘」改走 **系统手势管线 withType 接口**。
///
/// ## 为什么值得再试一次
///
/// 这条路的失败前提在本轮全部变了：
///
/// | | 0.1.5 ~ 0.1.13（当年放弃） | 本版 V0.2.13 |
/// |---|---|---|
/// | 识别器 | `UIPanGestureRecognizer` | `UIScreenEdgePanGestureRecognizer`（系统边缘识别器） |
/// | 登记接口 | `-addGestureRecognizer:toDisplayWithIdentity:` | **`-addGestureRecognizer:withType:`**（从未验证过） |
/// | 触摸开关 | 手动 `delaysTouchesBegan = true` | **UIKit 默认**（`delaysTouchesBegan=NO` / `cancelsTouchesInView=YES`） |
/// | 失败归还 | 自己「整段补投」（0.1.19 判定不可做） | **UIKit 自己 failed 后归还**，一帧都不用补 |
///
/// 关键差别是最后一行：`UIPanGestureRecognizer` 需要位移才 began，在它 began 之前
/// App 已经拿到 began 和位移，抖音的横滑就成立了；而系统边缘识别器从**边缘落手那一刻**
/// 就进入判定，失败时由 UIKit 归还、成功时由 `cancelsTouchesInView` 取消 App 那条触摸。
/// 这正是 Apple 给左缘返回手势用的那套 —— 本版只是把同样的待遇搬到右缘。
///
/// ## 回退
///
/// 任何一步失败（造不出识别器 / 登记不成功）→ 打日志后**什么都不做**，
/// 右缘继续由 0.2.12 的全局通道 + 热区负责，功能不丢、行为不变。
/// 设置里关掉「右缘系统手势通道」→ 整条失效（下次 install 时移除识别器）。
final class AevonSysEdgeV213: NSObject {

    static let shared = AevonSysEdgeV213()

    /// 自编 type 段（远离 iOS 自己的编号；放行 hook 认的就是这个区间）。
    static let customTypeBase: UInt64 = 0x7467_000
    static let customTypeCount: UInt64 = 4

    private var recognizer: UIGestureRecognizer?
    private var registered = false
    private var installedLogged = false
    private var fired = false
    private var tracking = false
    /// V0.2.14：began 那一帧的落点。判向一律用**自己记的位移**，不用 `translation(in:)`。
    /// Aevon(100) 实测 `translation(in:)` 在这个私有 init 造出来的识别器上给出
    /// dx=-421 dy=-796（屏幕只有 430x932，手指不可能走出这个位移），读数完全不可用。
    private var beganPoint: CGPoint = .zero
    /// V0.2.14：began 之后的「必须尽快定向」看门狗。
    /// Aevon(100) 12:10:59.792 began → 12:11:01.827 才 Failed，中间 2.03 秒一直挂在 began 上；
    /// 那 2 秒里它是 SpringBoard 眼里的「进行中的系统手势」，别的系统手势全被它挡着。
    private var guardWork: DispatchWorkItem?
    /// began 后允许多久完成定向。0.12 秒 ≈ 7 帧，足够看清方向；超过就必须 Failed 归还。
    private let begunBudget: Double = 0.12

    /// 是否启用：**V0.2.17 起常开**（设置页不再提供开关，只留偏好域这个逃生口）。
    ///
    /// 沿革：
    ///   · 0.2.13 默认开（首次试验）；Aevon(100) 判读后 0.2.14 翻成默认关 —— 那一轮它
    ///     呼盘 0 次，却有一次在 began 上扣了 2.03 秒，把同期的系统手势全排在后面；
    ///   · 0.2.14 补了两处（位移改用自己的 began 落点、began 后 0.12 秒看门狗），
    ///     0.2.16 再加「圆盘一开就只喂指针、不再判向」；
    ///   · Aevon(103) 的 12 次呼盘里这条通道 6 次当先（判向成立用时 15~49ms，
    ///     零次长扣、零次「began 后 120ms 未定向」）—— 它已经是最稳的一条。
    ///
    /// 用户看不到这个开关就等于不会被误关（0.2.14~0.2.16 的文案还写着「0 次呼盘、
    /// 实验」，照那个说明关掉它，右缘会直接少掉一条最快通道）。
    /// 真要关：`defaults write com.Aevon SysEdgeEnabled -bool NO`。
    private var enabled: Bool {
        return AevonPrefs.bool("SysEdgeEnabled", default: true)
    }

    /// 边缘区宽度（pt）。**默认 30**：
    ///   · Triggr 用 20（它在 iOS 16.2 上手测过）；
    ///   · Aevon 历史落点分布在距右缘 12 / 19 / 25 / 42pt；
    ///   · 取 30 覆盖到多数落点，又不把 46 那一整条细缝的轻点全部吃掉。
    /// 这一项只影响「从多远开始算边缘」，不影响识别成功后的取消语义，可按真机数据再调。
    private var edgeRegion: Double {
        let value = AevonPrefs.double("SysEdgeRegion", default: 30)
        return max(8, min(60, value))
    }

    /// 私有 init 的 type 编号。默认 2 —— Triggr 注释原文：
    /// `type 2 as SpringBoard's own: real fingers work (verified by hand on iOS 16.2)`。
    private var typeValue: Int {
        return AevonPrefs.int("SysEdgeType", default: 2)
    }

    /// 判向阈值（pt）。系统边缘识别器已经帮我们过滤了「必须从边缘起手」，
    /// 所以这里不需要像全局通道那样等到 30pt —— 14pt 足够区分「左扫」与「竖滚」。
    private var distance: CGFloat {
        let value = AevonPrefs.double("SysEdgeDistance", default: 14)
        return CGFloat(max(8, min(60, value)))
    }

    /// 斜率判据：横向必须明显大于纵向（1.2 倍），与 App 侧、SB 热区保持同一套语义。
    private let slopeRatio: CGFloat = 1.2

    // MARK: - 安装

    func install(attempt: Int = 0) {
        if attempt == 0 { Self.migrateOnOnceV217() }
        guard enabled else {
            if attempt == 0 {
                AevonLog.info("[系统手势] 已被偏好域手动关闭（SysEdgeEnabled=否），右缘只走热区 + App 侧通道（AevonSysEdgeV213）")
            }
            return
        }
        if recognizer != nil { return }

        // 管理器要等 SpringBoard 自己先建好，否则取到 nil（Triggr 在 iOS 17 上踩过：
        // 自己抢先构造会 abort）。这里用重试代替 hook `-_init`，侵入性更小。
        let managerReady = NSClassFromString("SBSystemGestureManager") != nil
            || NSClassFromString("_UISystemGestureManager") != nil
        if !managerReady, attempt < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.install(attempt: attempt + 1)
            }
            return
        }

        // ① 放行自编 type（若用 type=2 借系统编号，这一步不影响；用自编编号时必须成功）。
        let allowOK = AevonSysEdgeAllowTypes(Self.customTypeBase, Self.customTypeCount)

        // ② 造识别器（私有 init）。
        guard let result = AevonSysEdgeCreateRecognizer(self,
                                                        #selector(handle(_:)),
                                                        typeValue,
                                                        edgeRegion) else {
            AevonLog.warn("[系统手势] 造不出 UIScreenEdgePanGestureRecognizer（私有 init 两条重载都不在）→ 放弃本通道，右缘走全局通道（AevonSysEdgeV213 AevonSysEdgePrivInitV213）")
            return
        }

        // ③ 触摸策略：**保持 UIKit 默认值，一个都不改**。
        //
        // 这是与 0.1.5~0.1.13 最大的差别。当年手动设 `delaysTouchesBegan = true`，
        // 结果 began 被扣住、失败后要我们自己把 began + 全部 moved 补投 —— 而补投时
        // phase 已经变成 Moved，App 永远收不到 Began（0.1.19 方案书的定论）。
        // 系统边缘识别器不需要这套：它在边缘落手就进入判定，UIKit 负责失败归还。
        //
        // 只显式声明 `cancelsTouchesInView = true`（其实就是默认值），
        // 因为它正是「识别成功后 App 那条触摸被取消」的开关 —— 也是 App 不再跟着动的唯一依据。
        result.cancelsTouchesInView = true
        result.delaysTouchesBegan = false

        if let pan = result as? UIScreenEdgePanGestureRecognizer {
            pan.edges = .right
            pan.maximumNumberOfTouches = 1
        }

        // ④ 登记进系统手势管线。
        let registeredNow = AevonSysEdgeRegister(result, Self.customTypeBase)
        let path = AevonSysEdgeLastRegisterPath() ?? ""

        recognizer = result
        registered = registeredNow

        guard !installedLogged else { return }
        installedLogged = true

        if registeredNow {
            AevonLog.info("[系统手势] 登记成功 via \(path)；type=\(typeValue) 边缘区=\(Int(edgeRegion))pt 判向=\(Int(distance))pt 放行hook=\(allowOK ? "是" : "否")（AevonSysEdgeV213 AevonSysEdgeWithTypeV213 AevonSysEdgeAllowTypeV213 AevonSysEdgeRegionV213 AevonSysEdgeAlwaysOnV217）")
        } else {
            AevonLog.warn("[系统手势] 登记失败（\(path)）→ 本通道不生效，右缘走全局通道（AevonSysEdgeV213 AevonSysEdgeWithTypeV213）")
        }
    }

    // MARK: - 识别器回调

    @objc private func handle(_ gesture: UIPanGestureRecognizer) {
        guard enabled else { return }

        // V0.2.14：位移用自己记的 began 落点算，**不再读 `translation(in:)`**。
        // 理由见 `beganPoint` 的注释（那个读数在私有 init 的识别器上不可信）。
        let point = gesture.location(in: nil)
        let dx = point.x - beganPoint.x
        let dy = point.y - beganPoint.y

        switch gesture.state {
        case .began:
            fired = false
            tracking = true
            beganPoint = point
            AevonLog.info("[系统手势] 边缘识别器 began，落点 (\(Int(point.x)),\(Int(point.y)))（AevonSysEdgeV213）")
            startBegunGuard()

        case .changed:
            // V0.2.16（AevonRingPointerHandoffV216）：圆盘一开，这个识别器只剩「喂指针」一个职责。
            //
            // Aevon(102) 的账：手指从右缘往圆心（215,699）走，本来就是「左上斜向」，
            // 而下面那段判向会把它判成纵向 → 主动 Failed → 之后一条 moved / ended 都发不出来。
            // 9 次 `systemgesture` 呼盘的日志里，紧接着的都是「判为纵向 → Failed」，
            // 圆盘从那一刻起就断粮 —— 手指继续滑没有任何反应，这就是「选不中图标」。
            if fired, let ring = AevonRingMenu.presented {
                ring.remoteMoved(to: point, source: "systemgesture")
                return
            }
            // 判向：向左（负 dx）且横向明显大于纵向。
            // 纵向 / 斜向 → 立刻 Failed，把触摸还给 App —— 这是「右缘竖滑照样滚屏」的保证。
            if abs(dy) > abs(dx), abs(dy) >= 6 {
                cancelBegunGuard()
                AevonSysEdgeForceFail(gesture)
                tracking = false
                AevonLog.info("[系统手势] 判为纵向（dx=\(Int(dx)) dy=\(Int(dy))）→ Failed 归还 App（AevonSysEdgeV213）")
                return
            }
            if !fired, dx <= -distance, abs(dx) >= abs(dy) * slopeRatio {
                fired = true
                cancelBegunGuard()
                AevonLog.info("[系统手势] 判向成立 dx=\(Int(dx)) dy=\(Int(dy)) 落点 (\(Int(point.x)),\(Int(point.y))) → 呼圆盘（AevonSysEdgeV213）")
                AevonEdgeEntry.triggerFromSystemGesture(point: point)
                return
            }
            // 圆盘已出：后续移动直接驱动圆盘跟手 / 旋转，不再走全局通道。
            if fired, let ring = AevonRingMenu.presented {
                ring.remoteMoved(to: point, source: "systemgesture")
            }

        case .ended, .recognized:
            cancelBegunGuard()
            tracking = false
            // 圆盘开着就一定要把抬手送到 —— 漏掉这一帧圆盘就收不到 ended，
            // 只能等 1.2 秒超时后的新触摸，表现就是「必须抬手再摸一次」。
            if let ring = AevonRingMenu.presented {
                ring.remoteEnded(at: point, source: "systemgesture")
            }
            fired = false

        case .cancelled:
            cancelBegunGuard()
            tracking = false
            if fired, let ring = AevonRingMenu.presented {
                ring.remoteCancelled(source: "systemgesture")
            }
            fired = false

        case .failed:
            cancelBegunGuard()
            tracking = false
            fired = false

        default:
            break
        }
    }

    // MARK: - began 看门狗（V0.2.14 / AevonSysEdgeBegunBudgetV214）

    /// began 之后 0.12 秒还没定向 → 主动 Failed。
    ///
    /// 这是本版对 Aevon(100) 那次 2.03 秒长扣的直接修补：识别器挂在 began 上时，
    /// SpringBoard 会认为「有一个系统手势正在进行」，同时期的顶部下拉 / 底部上滑
    /// 就都排在它后面。0.12 秒到期无条件归还，宁可漏一次呼盘，也不让系统手势被挡。
    private func startBegunGuard() {
        cancelBegunGuard()
        let work = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            guard let target = strongSelf.recognizer else { return }
            guard strongSelf.tracking, !strongSelf.fired else { return }
            strongSelf.tracking = false
            AevonSysEdgeForceFail(target)
            AevonLog.info("[系统手势] began 后 \(Int(strongSelf.begunBudget * 1000))ms 未定向 → 主动 Failed 归还（AevonSysEdgeV213 AevonSysEdgeBegunBudgetV214）")
        }
        guardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + begunBudget, execute: work)
    }

    private func cancelBegunGuard() {
        guardWork?.cancel()
        guardWork = nil
    }

    // MARK: - 老用户一次性迁移（V0.2.14 关闭 → V0.2.17 常开 / AevonSysEdgeAlwaysOnV217）

    /// 0.2.13 默认开、0.2.14 默认关，两版都写过盘 —— 装过它们的设备里这个键可能是
    /// `false`，只改代码里的 default 救不了（CFPreferences 里已有值优先）。
    /// 0.2.17 把开关从设置页撤掉之后，用户已无途径自己翻回来，所以这里**一次性写 true**，
    /// 并立新标记；此后 `defaults write com.Aevon SysEdgeEnabled -bool NO` 仍可长期关掉它
    /// （标记只跑一次，不会把用户的选择顶回去）。
    ///
    /// 历史标记 `AevonSysEdgeOffMigrateV214`（0.2.14 那条「写了一辈子 false」的迁移）
    /// 已作废，实现删除，标记由 AevonAssertionShim.m 的 used 常量继续收容。
    private static func migrateOnOnceV217() {
        let marker = "SysEdgeOnMigratedV217"
        if AevonPrefs.bool(marker, default: false) { return }
        AevonPrefs.set("SysEdgeEnabled", true)
        AevonPrefs.set(marker, true)
        AevonLog.info("[系统手势] 一次性迁移：SysEdgeEnabled → 开（0.2.17 起常开、设置页不再提供开关）（AevonSysEdgeAlwaysOnV217）")
    }

    // MARK: - 诊断

    /// 是否已装（供探针 / 日志自述）。
    var isInstalled: Bool { return recognizer != nil }

    /// 是否登记成功（false 时右缘实际仍走全局通道）。
    var pipelineRegistered: Bool { return registered }

    /// 一行自述，给 P6 配置快照用。
    func summary() -> String {
        if recognizer == nil {
            return AevonPrefs.bool("SysEdgeEnabled", default: true)
                ? "未装（造不出识别器或管理器未就绪）"
                : "已关闭"
        }
        return "已装·登记=\(registered ? (AevonSysEdgeLastRegisterPath() ?? "") : "失败")·type=\(typeValue)·边缘区=\(Int(edgeRegion))pt"
    }
}
