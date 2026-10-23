import Foundation
import UIKit

/// 空闲锁屏闸门（V0.0.51，AevonIdleNoLockV51）。
///
/// 用户 Aevon(44) 第 3 条：「用悬浮窗看抖音视频时，屏幕会按系统设置的 1~2 分钟黑屏锁屏」。
/// 浮窗画面是 SpringBoard 里的场景视图，不产生用户活动 → 系统空闲计时器照常到期。
/// 只要**还有浮窗**，就让 SpringBoard 声明「不允许空闲锁屏」；关掉最后一个窗立刻恢复。
///
/// 为什么要每 20 秒重申一次：系统在锁屏 / 亮屏 / 场景切换时会把 idleTimer 状态重置，
/// 单次设置会被冲掉。重申是幂等的（值没变就什么都不做），代价可以忽略。
final class AevonIdleGuard {
    static let shared = AevonIdleGuard()

    private var reassertTimer: Timer?
    private var lastApplied = false
    private var lastLogAt: CFTimeInterval = 0
    /// V0.0.54（AevonIdleResetV54）：20 → 12 秒。
    /// 系统最短的自动锁定档位是 30 秒，12 秒一次的重置足够把任何档位都顶住，
    /// 同时把跨进程调用频率压在可忽略的量级。
    private let reassertInterval: TimeInterval = 12
    /// 只打一次「reset 通道是否可用」的证据日志
    private var resetChannelLogged = false

    private init() {}

    /// 窗数变化（开窗 / 关窗 / 插件开关）后调用，重新判定要不要压住锁屏。
    func refresh() {
        let count = AevonEntryHost.floatingWindowCount
        let should = count > 0 && AevonPrefs.bool("Enabled", default: false)
        apply(should, count: count)
    }

    /// 插件被关掉时强制恢复（设置面板里切开关走这里）。
    func forceOff() {
        apply(false, count: 0)
    }

    private func apply(_ on: Bool, count: Int) {
        if on != lastApplied {
            lastApplied = on
            AevonIdleSetActive(on)
            let now = CACurrentMediaTime()
            if now - lastLogAt > 0.5 {
                lastLogAt = now
                if on {
                    AevonLog.info("[锁屏] 已压住系统空闲锁屏（当前 \(count) 个浮窗在显示内容）"
                        + "（AevonIdleNoLockV51）")
                } else {
                    AevonLog.info("[锁屏] 已恢复系统空闲锁屏（没有浮窗了）（AevonIdleNoLockV51）")
                }
            }
        }
        if on {
            // 立刻起算一次，别等第一个 12 秒周期（用户开窗就马上看视频的场景）
            if !resetChannelLogged {
                resetChannelLogged = true
                let channel = AevonIdleReassert()
                AevonLog.info("[锁屏] 已启用空闲计时器重置通道（resetIdleTimer "
                    + "\(channel ? "命中" : "未命中，仅保留 getter 兜底")，每 "
                    + "\(Int(reassertInterval)) 秒一次）—— 播放视频时不再按系统时间黑屏"
                    + "（AevonIdleResetV54）")
            } else {
                _ = AevonIdleReassert()
            }
            startReassert()
        } else {
            resetChannelLogged = false
            stopReassert()
        }
    }

    private func startReassert() {
        guard reassertTimer == nil else { return }
        let timer = Timer(timeInterval: reassertInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard AevonIdleIsActive() else { return }
            // 重申：窗已全关就顺手收掉，别让设备永远不锁屏
            if AevonEntryHost.floatingWindowCount == 0 {
                self.apply(false, count: 0)
                return
            }
            // V0.0.54（AevonIdleResetV54）：真正起作用的这一枪 —— 把空闲计时器重新起算。
            // 旧版只重申 setIdleTimerDisabled，真机上系统根本不读那条路径（Aevon(47) 第 2 条）。
            let channel = AevonIdleReassert()
            if !self.resetChannelLogged {
                self.resetChannelLogged = true
                AevonLog.info("[锁屏] 已启用空闲计时器重置通道（resetIdleTimer "
                    + "\(channel ? "命中" : "未命中，仅保留 getter 兜底")，每 "
                    + "\(Int(self.reassertInterval)) 秒一次）—— 播放视频时不再按系统时间黑屏"
                    + "（AevonIdleResetV54）")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reassertTimer = timer
    }

    private func stopReassert() {
        reassertTimer?.invalidate()
        reassertTimer = nil
    }
}
