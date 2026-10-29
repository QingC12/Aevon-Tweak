import Foundation
import UIKit

/// 场景 settings 的单飞通道（路线 C 第二件）。
///
/// 抄的是 ScreenCore `sc_enqueueSettingsMutation:context:transitionContext:forceSend:completion:`
/// + `sc_drainPendingSettingsForContext:` 的「同一场景同时只允许一笔在飞」结构。
///
/// 为什么必须单飞（自家档案实锤）：每一次 `updateSettings` 都会让远程表面重建一次，
/// 屏幕上就是「黑一下 / 闪一下」。Aevon 历史上在开窗、切屏、保活三处各写各的，
/// 同一拍可能连写 2~3 笔 —— 那就是用户看到的闪。
///
/// 规则：
///   1. 同一 bundle 同时只有一笔 in-flight；
///   2. 期间的新请求一律合并成「一笔 pending」，只保留最后一次的目标值；
///   3. in-flight 回来的回调里再 drain pending（不在定时器里猜）；
///   4. 账本判定「账面已一致」时直接跳过，根本不写（AevonSceneLedger）。
final class AevonSettingsChannel {
    static let shared = AevonSettingsChannel()
    private init() {}

    private let lock = NSLock()

    private struct Slot {
        var inFlight = false
        var inFlightAt: CFTimeInterval = 0
        var pendingForeground: Bool? = nil
        var pendingReason = ""
        var sends = 0
        var merges = 0
        var timeouts = 0
    }

    private var slots: [String: Slot] = [:]
    private var totalSends = 0
    private var totalMerges = 0
    private var totalSkips = 0
    private var totalTimeouts = 0
    private var lastLogAt: [String: CFTimeInterval] = [:]

    /// in-flight 最长容忍时间。超过就认为 completion 丢了（系统不回调），强制放行下一笔，
    /// 否则整个 App 的写通道会被一笔不回来的请求永久堵死。
    private static let inFlightTimeout: CFTimeInterval = 0.9

    // MARK: - 对外入口

    /// 请求把某个场景写成前台/后台。
    /// - Parameter force: true = 跳过单飞合并，立即发（仅用于关窗收尾等必须立刻落地的场合）
    func request(bundleID: String,
                 scene: AnyObject?,
                 foreground: Bool,
                 reason: String,
                 force: Bool = false) {
        guard !bundleID.isEmpty else { return }

        lock.lock()
        var slot = slots[bundleID] ?? Slot()
        // 超时的 in-flight 视为已结束（系统丢了 completion）
        if slot.inFlight, CACurrentMediaTime() - slot.inFlightAt > AevonSettingsChannel.inFlightTimeout {
            slot.inFlight = false
            slot.timeouts += 1
            totalTimeouts += 1
            AevonLog.warn("[通道] \(bundleID) 上一笔超时未回，强制放行（AevonSettingsChannelV279）")
        }
        if slot.inFlight, !force {
            slot.pendingForeground = foreground
            slot.pendingReason = reason
            slot.merges += 1
            totalMerges += 1
            slots[bundleID] = slot
            lock.unlock()
            logThrottled("[通道] 合并 \(bundleID) → 待发 fg=\(foreground ? "YES" : "NO") 原因=\(reason)"
                + "（AevonSettingsChannelV279）", key: "merge-\(bundleID)")
            return
        }
        slot.inFlight = true
        slot.inFlightAt = CACurrentMediaTime()
        slots[bundleID] = slot
        lock.unlock()

        sendNow(bundleID: bundleID, scene: scene, foreground: foreground, reason: reason, force: force)
    }

    /// 收尾：关窗时若还有 pending，直接丢弃（App 已经不要了）
    func cancel(bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        guard var slot = slots[bundleID] else { return }
        slot.pendingForeground = nil
        slot.pendingReason = ""
        slots[bundleID] = slot
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return "发\(totalSends) 合\(totalMerges) 跳\(totalSkips) 超时\(totalTimeouts)"
    }

    // MARK: - 内部

    private func sendNow(bundleID: String, scene: AnyObject?, foreground: Bool, reason: String,
                         force: Bool = false) {
        guard let scene else {
            finish(bundleID: bundleID, sent: false)
            return
        }

        // 写前先问账本：账面一致就根本不写（省一次重提交 = 少闪一次）
        let decision = AevonSceneLedger.shared.decide(bundleID: bundleID, scene: scene,
                                                     wantForeground: foreground, reason: reason)
        /* V0.2.86（AevonForceWriteV286）—— **force 必须能穿透账本**，这是「定格」的根治点。
         *
         * 账本记的是「我上次写下去的值」。系统事后把场景压回后台、而**实时读又读不到**时
         *（`snapshot(of:)` 返回 nil → 退回 lastKnown=YES），decide 就判「账面已一致」
         * → 通道永远跳过 → 看门每 0.5 秒喊一次「重申」，一次都发不出去。
         * 归档(20) 抖音那段正是这个形态：`重申浮窗场景前台` 连发两次，前后
         * `fg=? cs=0 layers=-1` 一模一样 —— 因为压根没写进去。
         * 补救路径（看门 / 定格自愈）必须能强制写一笔，否则「读不到」就等于「永久定格」。 */
        if force && !decision.shouldWrite {
            /* 这条日志有两个用途：① 让「强制写」在真机上可观察（否则只能看「跳过」条数变少）；
             * ② 让标记 AevonForceWriteV286 真的进二进制 —— 只写在注释里的标记永远查不到
             *（0.2.68 / 0.2.81 / 0.2.83 / 0.2.85 四次同坑，第五次不能再犯）。 */
            logThrottled("[通道] 强制写 \(bundleID)（账面说已一致，补救路径不许跳过）"
                + " 面[\(decision.snapshot.description)] 原因=\(reason)（AevonForceWriteV286）",
                key: "force-\(bundleID)")
        }
        if !decision.shouldWrite && !force {
            AevonSceneLedger.shared.noteSkipped(bundleID: bundleID, reason: reason)
            lock.lock(); totalSkips += 1; lock.unlock()
            logThrottled("[通道] 跳过 \(bundleID) \(decision.kind.rawValue) 面[\(decision.snapshot.description)]"
                + " 原因=\(reason)（AevonSettingsChannelV279）", key: "skip-\(bundleID)")
            finish(bundleID: bundleID, sent: false)
            return
        }

        guard scene.responds(to: Selector(("settings"))),
              let settings = AevonRuntime.send(scene, Selector(("settings"))),
              settings.responds(to: Selector(("mutableCopy"))),
              let mutable = AevonRuntime.sendOwned(settings, Selector(("mutableCopy"))) else {
            AevonLog.warn("[通道] \(bundleID) settings 不可用，放弃这一笔（AevonSettingsChannelV279）")
            finish(bundleID: bundleID, sent: false)
            return
        }

        let okSet = AevonRuntime.setBool(mutable, key: "foreground", foreground)
        if !okSet {
            AevonLog.warn("[通道] \(bundleID) 写 foreground 字段失败（AevonSettingsChannelV279）")
            finish(bundleID: bundleID, sent: false)
            return
        }

        lock.lock()
        totalSends += 1
        slots[bundleID]?.sends += 1
        let sends = slots[bundleID]?.sends ?? 0
        lock.unlock()

        AevonLog.info("[通道] 写 \(bundleID) fg=\(foreground ? "YES" : "NO") 字段=\(decision.changedFields.joined(separator: ","))"
            + " 第\(sends)笔 原因=\(reason)（AevonSettingsChannelV279）")

        /* 不放 completion block（V0.2.79 定案）：
         * `updateSettings:withTransitionContext:completion:` 的 completion 要跨到 ObjC，
         * 用 unsafeBitCast 传 block 必须自己持有它，而持有 block = 间接强引用 scene，
         * 会拖住建好的场景不释放（关窗后场景回收不掉，正是黑屏类问题的温床）。
         * 这里改成「发出去就算占用 0.12 秒」的时隙式单飞 —— 目的只是「同一拍不并发写」，
         * 不需要知道系统什么时候真正写完。 */
        if scene.responds(to: Selector(("updateSettings:withTransitionContext:completion:"))) {
            AevonRuntime.sendVoid(scene,
                                  Selector(("updateSettings:withTransitionContext:completion:")),
                                  mutable, nil, nil)
            AevonSceneLedger.shared.noteApplied(bundleID: bundleID,
                                                wantForeground: foreground,
                                                readBack: nil,
                                                reason: reason)
            releaseSlotLater(bundleID: bundleID)
        } else if scene.responds(to: Selector(("updateSettings:withTransitionContext:"))) {
            AevonRuntime.sendVoid(scene, Selector(("updateSettings:withTransitionContext:")), mutable, nil)
            AevonSceneLedger.shared.noteApplied(bundleID: bundleID,
                                                wantForeground: foreground,
                                                readBack: nil,
                                                reason: reason)
            releaseSlotLater(bundleID: bundleID)
        } else {
            AevonLog.warn("[通道] \(bundleID) 场景不支持 updateSettings，本笔作废（AevonSettingsChannelV279）")
            finish(bundleID: bundleID, sent: false)
        }
    }

    /// 时隙结束：把 in-flight 放开，并补发合并期间的最后一笔。
    private func releaseSlotLater(bundleID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.finish(bundleID: bundleID, sent: true)
        }
    }

    private func finish(bundleID: String, sent: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.finish(bundleID: bundleID, sent: sent)
            }
            return
        }
        var drain: (Bool, String)?
        lock.lock()
        guard var slot = slots[bundleID] else { lock.unlock(); return }
        slot.inFlight = false
        slot.inFlightAt = 0
        if let next = slot.pendingForeground {
            drain = (next, slot.pendingReason)
            slot.pendingForeground = nil
            slot.pendingReason = ""
        }
        slots[bundleID] = slot
        lock.unlock()

        if let drain {
            logThrottled("[通道] 排空 \(bundleID) → 补发最后一笔 fg=\(drain.0 ? "YES" : "NO")"
                + " 原因=\(drain.1)（AevonSettingsChannelV279）", key: "drain-\(bundleID)")
            let scene = AevonSceneHelper.selfScene(for: bundleID)
                ?? AevonSceneHelper.scene(for: bundleID)
            request(bundleID: bundleID, scene: scene, foreground: drain.0, reason: drain.1, force: true)
        }
    }

    private func logThrottled(_ message: String, key: String) {
        let now = CACurrentMediaTime()
        lock.lock()
        let last = lastLogAt[key] ?? 0
        let allow = now - last > 2.0
        if allow { lastLogAt[key] = now }
        lock.unlock()
        if allow { AevonLog.info(message) }
    }
}
