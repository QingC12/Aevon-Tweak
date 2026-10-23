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
    private let reassertInterval: TimeInterval = 20

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
            startReassert()
        } else {
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
            AevonIdleSetActive(true)
        }
        RunLoop.main.add(timer, forMode: .common)
        reassertTimer = timer
    }

    private func stopReassert() {
        reassertTimer?.invalidate()
        reassertTimer = nil
    }
}
