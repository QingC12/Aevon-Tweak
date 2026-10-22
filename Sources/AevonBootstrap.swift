import UIKit
import QuartzCore

/// 启动引导：只用通知监听，不做任何系统方法交换。
///
/// V0.0.7 的核心安全设计：
/// 入口完全靠 UIApplication 的生命周期通知驱动，启动阶段 SpringBoard 的系统方法上一个 hook 都没有，
/// 因此不可能再出现「长按图标 → 注销」这类系统路径崩溃。
///
/// V0.0.18：入口从「两个窗口」收敛成「一个统一窗口」——
/// `AevonEntryHost` 先建好唯一窗口，再把边缘手势条和备用悬浮球挂进去。
/// 之前两个同级窗口的表现不一致（悬浮球能收触摸、手势条收不到），合并后从结构上消除差异。
enum AevonBootstrap {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default

        // 启动完成 → 等 4 秒（让桌面把图标、Widget 都铺好）再挂入口
        _ = center.addObserver(forName: UIApplication.didFinishLaunchingNotification,
                               object: nil,
                               queue: .main) { _ in
            AevonLog.info("[引导] 收到 didFinishLaunching，4 秒后创建入口（边缘手势 / 备用悬浮球）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                installEntries(reason: "didFinishLaunching")
            }
        }

        // 兜底：每次回到活跃态时检查一遍（首次没有场景 / 被系统回收 / 屏幕尺寸变化时补建与校正）
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil,
                               queue: .main) { _ in
            let wantEdge = AevonPrefs.bool("EdgeGestureEnabled", default: true)
            let wantBall = AevonPrefs.bool("BubbleEnabled", default: false)
            let missingEdge = wantEdge && !AevonEdgeEntry.isVisible
            let missingBall = wantBall && !AevonBubble.shared.isVisible
            guard missingEdge || missingBall || !AevonEntryHost.isInstalled else {
                AevonEntryHost.refreshLayout(reason: "didBecomeActive")
                AevonEntryHost.raise(reason: "回到桌面")
                diagnose("回到桌面")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                installEntries(reason: "didBecomeActive")
            }
        }

        // V0.0.19：App 进入前台时 SpringBoard 可能新建了更高的窗口把入口压住，
        // 这里监听 SpringBoard 自己的通知（只观察，不做任何 hook），收到就重新顶一次。
        // 通知名是 SpringBoard 内部字符串，拿不到也无害 —— 只是少一次主动重设。
        for name in ["SBApplicationDidBecomeActiveNotification",
                     "SBApplicationWillActivateNotification",
                     "SBApplicationDidLaunchNotification"] {
            _ = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                guard AevonEntryHost.isInstalled else { return }
                AevonEntryHost.raise(reason: "App 激活")
                diagnose("App 激活")
            }
        }

        // V0.0.20：UIScene 级监听（可靠 API，不依赖 SpringBoard 私有通知名）。
        // 只做两件事：把场景激活/失活写进日志（判断「App 前台时是不是换了场景」），
        // 以及顺手把入口窗口重顶一次。
        let activateName = UIScene.didActivateNotification
        let deactivateName = UIScene.willDeactivateNotification
        for (name, label) in [(activateName, "激活"), (deactivateName, "失活")] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let scene = note.object as? UIScene else { return }
                AevonLog.info("[场景] \(label) \(type(of: scene)) 角色 \(scene.session.role.rawValue) 状态 \(scene.activationState.rawValue)")
                guard AevonEntryHost.isInstalled else { return }
                AevonEntryHost.raise(reason: "场景\(label)")
                diagnose("场景\(label)")
            }
        }

        AevonLog.info("[引导] 已注册启动通知（入口不依赖任何 hook）")
    }
    /// 窗口栈诊断（限流 8 秒，避免刷爆日志）
    private static var lastDiagnoseAt: CFTimeInterval = 0
    private static func diagnose(_ tag: String) {
        guard AevonPrefs.bool("LogEnabled", default: true) else { return }
        let now = CACurrentMediaTime()
        guard now - lastDiagnoseAt > 8.0 else { return }
        lastDiagnoseAt = now
        AevonEntryHost.dumpWindowStack(tag)
    }

    /// 建唯一入口窗口 → 挂手势条 → 挂备用悬浮球（顺序：先条后球，球在最上层便于拖动）
    private static func installEntries(reason: String) {
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        guard AevonEntryHost.ensureInstalled(reason: reason) != nil else {
            AevonLog.info("[引导] 入口窗口暂不可用，等待下一次活跃态重试（\(reason)）")
            return
        }
        AevonEdgeEntry.install(attempt: 1, reason: reason)
        AevonBubble.shared.install(attempt: 1, reason: reason)
    }
}
