import Foundation
import UIKit

/// 浮窗显示策略（V0.0.55，AevonOverlayPolicyV55 / AevonSwitcherHideV54）。
///
/// 用户 Aevon(48) 的 1、5 两条：
///   ① 「在全屏应用中吸附停靠小窗后，上滑后台回到桌面时，小窗也会跟着消失，
///      然后回到桌面时，小窗出现」—— 上滑过程中不该消失；
///   ② 「如果开启悬浮窗时锁屏，亮屏后锁屏页面中间会显示黑屏的主悬浮窗
///      （应该只在桌面和全屏 App 中显示，而不是锁屏、控制中心、通知中心）」。
///
/// V0.0.54 的做法是「判断 App 画面是否还铺满整屏，不铺满就隐藏」——
/// Aevon(48) 日志把它的抖动打得很清楚：
///   11:47:39 隐藏（画面被缩小）→ 11:47:41 显示 → 11:47:41.6 又隐藏 → 11:47:42.5 显示。
/// 因为上滑手势期间 App 画面是被**连续缩小**的，这个判据必然一路误判。
///
/// 现在改成按「用户到底在哪个界面」判定：
///   · 锁屏 / 通知中心 / 控制中心（`SBCoverSheetWindow`、`SBControlCenterWindow` 等可见）→ 隐藏；
///   · App 切换器（后台卡片）→ 隐藏（赶在系统给 App 拍快照前）；
///   · 其它情况（桌面、全屏 App、正在上滑回家的过程）→ **一直显示**。
///
/// 上滑回家时容器还挂在 App 画面里，会被系统带着缩小 —— 所以这时把它
/// **立刻搬回桌面窗口**（而不是隐藏），浮窗就稳稳留在原处不动了。
final class AevonSwitcherGuard {
    static let shared = AevonSwitcherGuard()

    private var timer: Timer?
    private var lastHidden = false
    private var lastLogAt: CFTimeInterval = 0
    private var lastReason = ""
    /// 切换器「已开始展示」标志：通知先到，用来抢在系统截图之前隐藏
    private var switcherForced = false
    private var switcherForcedAt: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    /// 通知抢跑之后，如果协调器一直查不到「切换器可见」，最多等这么久就解除，
    /// 避免某些系统版本没广播结束通知时浮窗一直不回来。
    private let switcherForceTimeout: CFTimeInterval = 6.0

    private init() {}

    func start() {
        guard timer == nil else { return }

        // ① 切换器通知：WillBegin 立刻藏（赶在快照前），WillEnd / DidEnd 解除
        let names = ["SBSwitcherWillBeginPresentationNotification",
                     "SBSwitcherWillEndPresentationNotification",
                     "SBSwitcherDidEndPresentationNotification",
                     "SBSwitcherWillDismissNotification"]
        for raw in names {
            let token = NotificationCenter.default.addObserver(
                forName: Notification.Name(raw), object: nil, queue: .main
            ) { note in
                let name = note.name.rawValue
                let beginning = name.contains("WillBegin")
                AevonSwitcherGuard.shared.switcherForced = beginning
                AevonSwitcherGuard.shared.switcherForcedAt = CACurrentMediaTime()
            }
            observers.append(token)
        }

        // ② 0.15s 轮询：覆盖层（锁屏 / 控制中心 / 通知中心）+ 切换器 + 回家过渡
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // ---- ① 覆盖层：锁屏 / 通知中心 / 控制中心 ----
        if AevonOverlayCoverSheetVisible() {
            apply(hidden: true, reason: "锁屏 / 通知中心 / 控制中心")
            return
        }

        // ---- ② 切换器：通知抢跑 + 协调器确认 ----
        if switcherForced {
            if CACurrentMediaTime() - switcherForcedAt > switcherForceTimeout {
                switcherForced = false
            } else {
                apply(hidden: true, reason: "App 切换器（后台卡片）")
                return
            }
        }
        if AevonOverlaySwitcherVisible() || hostedInSwitcherCard() {
            apply(hidden: true, reason: "App 切换器（后台卡片）")
            return
        }

        // ---- ③ 其它情况一律显示 ----
        // 上滑回家途中：容器还挂在被缩小的 App 画面里，搬回桌面窗口，
        // 浮窗就不会跟着缩成一张卡片再弹回来（Aevon(48) 第 1 条）。
        // 只在画面已经缩到不足半屏时搬 —— 太早会在 App 还占满视野时换宿主。
        if AevonEntryHost.mountedInAppScene && AevonEntryHost.appSceneVisibleHeightRatio() < 0.45 {
            AevonEntryHost.detachFromAppScene(reason: "App 画面正在缩小（上滑回家）")
        }
        AevonEntryHost.reattachAppSceneIfPossible()
        apply(hidden: false, reason: "桌面 / 全屏 App")
    }

    /// App 画面容器是否已经被塞进切换器卡片里（`SBAppSwitcherPageView` 之类的祖先）。
    private func hostedInSwitcherCard() -> Bool {
        guard let view = AevonEntryHost.appSceneView else { return false }
        var node: UIView? = view.superview
        var depth = 0
        while let current = node, depth < 12 {
            let name = NSStringFromClass(type(of: current))
            if name.contains("Switcher") || name.contains("PageView") || name.contains("Card") {
                return true
            }
            node = current.superview
            depth += 1
        }
        return false
    }

    /// 应用隐藏 / 显示（幂等，只在真正翻转时写日志）。
    private func apply(hidden: Bool, reason: String) {
        guard hidden != lastHidden else {
            lastReason = reason
            return
        }
        lastHidden = hidden
        lastReason = reason
        guard let box = AevonEntryHost.activeRoot else { return }
        box.isHidden = hidden
        if !hidden {
            // 藏起来这段时间布局可能变了：恢复时按当前 bounds 重新落位一次
            AevonEntryHost.refreshLayout(reason: "覆盖层消失，恢复显示")
        }
        let now = CACurrentMediaTime()
        if now - lastLogAt > 0.5 {
            lastLogAt = now
            if hidden {
                AevonLog.info("[入口] 已隐藏浮窗（\(reason)）—— 浮窗只在桌面与全屏 App 中显示"
                    + "（AevonOverlayPolicyV55）")
            } else {
                AevonLog.info("[入口] 已恢复显示浮窗（\(reason)）（AevonOverlayPolicyV55）")
            }
        }
    }
}
