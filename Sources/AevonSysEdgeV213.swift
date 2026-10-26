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

    /// 是否启用：关掉即整条通道不装（右缘回到 0.2.12 的老通道）。
    ///
    /// V0.2.14：**默认翻转为关**。Aevon(100) 的真机数据（2 分 34 秒、15 次呼盘）：
    ///   · 本通道呼盘 **0 次**（`来源 systemedge` = 0；12 次 appedge + 3 次 global）；
    ///   · 识别器只 began 过 1 次，并在 began 里**扣了 2.03 秒**才 Failed；
    ///   · began 落点 (390,778) 距右缘 40pt —— 远超设定的 30pt 边缘区，
    ///     说明 `edges` / `_setEdgeRegionSize:` 对私有 init 造出来的这个识别器并不成立；
    ///   · 判向时 `translation(in:)` 给出 dx=-421 dy=-796（手指根本到不了的值），读数不可用。
    ///
    /// 结论：`addGestureRecognizer:withType:` 这个接口在 17.3.1 上是**通的**（登记成功、
    /// 识别器真的收到触摸），但用它来抢右缘这只手，比它带来的干扰更贵。
    /// 保留实现与开关，默认关；以后要再研究，打开就能复现这次的取证。
    private var enabled: Bool {
        return AevonPrefs.bool("SysEdgeEnabled", default: false)
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
        if attempt == 0 { Self.migrateOffOnceV214() }
        guard enabled else {
            if attempt == 0 {
                AevonLog.info("[系统手势] 已关闭（SysEdgeEnabled=否），右缘走全局通道老路（AevonSysEdgeV213）")
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
            AevonLog.info("[系统手势] 登记成功 via \(path)；type=\(typeValue) 边缘区=\(Int(edgeRegion))pt 判向=\(Int(distance))pt 放行hook=\(allowOK ? "是" : "否")（AevonSysEdgeV213 AevonSysEdgeWithTypeV213 AevonSysEdgeAllowTypeV213 AevonSysEdgeRegionV213）")
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
                ring.remoteMoved(to: point, source: "systemedge")
            }

        case .ended, .recognized:
            cancelBegunGuard()
            tracking = false
            if fired, let ring = AevonRingMenu.presented {
                ring.remoteEnded(at: point, source: "systemedge")
            }
            fired = false

        case .cancelled:
            cancelBegunGuard()
            tracking = false
            if fired, let ring = AevonRingMenu.presented {
                ring.remoteCancelled(source: "systemedge")
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

    // MARK: - 老用户一次性迁移（V0.2.14 / AevonSysEdgeOffMigrateV214）

    /// 0.2.13 的默认值是「开」，装过那版的设备里这个键可能已经被写成年 true。
    /// 只改代码里的 default 只影响「从没写过这个键」的设备 —— 老用户必须写盘一次。
    /// 与 0.1.18 抬带宽、0.1.17 复位是同一种做法：标记键 + 一次性写盘。
    private static func migrateOffOnceV214() {
        let marker = "SysEdgeOffMigratedV214"
        if AevonPrefs.bool(marker, default: false) { return }
        AevonPrefs.set("SysEdgeEnabled", false)
        AevonPrefs.set(marker, true)
        AevonLog.info("[系统手势] 老用户一次性迁移：SysEdgeEnabled → 关（0.2.13 默认开，本版默认关）（AevonSysEdgeOffMigrateV214）")
    }

    // MARK: - 诊断

    /// 是否已装（供探针 / 日志自述）。
    var isInstalled: Bool { return recognizer != nil }

    /// 是否登记成功（false 时右缘实际仍走全局通道）。
    var pipelineRegistered: Bool { return registered }

    /// 一行自述，给 P6 配置快照用。
    func summary() -> String {
        if recognizer == nil {
            return AevonPrefs.bool("SysEdgeEnabled", default: false)
                ? "未装（造不出识别器或管理器未就绪）"
                : "已关闭"
        }
        return "已装·登记=\(registered ? (AevonSysEdgeLastRegisterPath() ?? "") : "失败")·type=\(typeValue)·边缘区=\(Int(edgeRegion))pt"
    }
}
