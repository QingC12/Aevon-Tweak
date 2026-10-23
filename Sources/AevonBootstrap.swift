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
            AevonLog.info("[引导] 收到 didFinishLaunching，4 秒后创建入口（边缘手势条 / 圆盘）")
            // V0.0.75（AevonCrashFuseV75）：**第一件事**就是检查上一轮 P1 有没有把进程搞崩。
            // Aevon(67)：P1 第 4 步野指针 → SpringBoard 退出 → 重启后 20s 自检又跑 P1 又崩，
            // 5 次启动崩 4 次（用户完全没法测试）。这里读到残留面包屑就把开关写关，
            // 彻底断掉「一开机就注销」的死循环。
            AevonSceneDriver.consumeCrashFuse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                installEntries(reason: "didFinishLaunching")
            }
            // V0.0.70（AevonSceneProbeP0 同源通道）：P1 实验启动自检 ——
            // prefschanged 只在设置变化时触发；若用户上一版就把 P1 开关打开并
            // 一直保留（Aevon(63)：全程开着但实验从未排程），这里启动后补查一次。
            // maybeRunExperiment 自带防重入（跑过即跳过），不会重复实验。
            DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) {
                AevonSceneDriver.shared.maybeRunExperiment()
            }
        }

        // 兜底：每次回到活跃态时检查一遍（首次没有场景 / 被系统回收 / 屏幕尺寸变化时补建与校正）
        // V0.0.39：延迟 1.5 → 3.0 秒 —— V0.0.38 在 didBecomeActive+1.5s 的窗口创建段
        // 出现 SIGSEGV（Aevon(32)），此时 SpringBoard 自身布局还没铺完，错峰降低竞态概率。
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil,
                               queue: .main) { _ in
            let wantEdge = AevonPrefs.bool("EdgeGestureEnabled", default: true)
            let missingEdge = wantEdge && !AevonEdgeEntry.isVisible
            guard missingEdge || !AevonEntryHost.isInstalled else {
                AevonEntryHost.refreshLayout(reason: "didBecomeActive")
                AevonEntryHost.raise(reason: "回到桌面")
                diagnose("回到桌面")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
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

    /// 建唯一入口窗口 → 挂边缘手势条（V0.0.27：备用悬浮球已全部移除）
    ///
    /// V0.0.39（AevonBootShieldV39）：每一步独立套 ObjC 异常保护并落面包屑日志 ——
    /// 任何一步抛 NSException 只记日志不中断启动，后续步骤照常；绝不再把异常抛回系统。
    private static func installEntries(reason: String) {
        guard AevonPrefs.bool("Enabled", default: false) else { return }

        // V0.0.66（AevonSceneProbeP0）：真小胖屏 P0 运行时探测（开关 TrueResizeScene 默认关；
        // 只读探测不建对象，一次进程一遍，独立异常隔离，绝不影响入口安装）。
        var probeEx: NSString? = nil
        var probeWhy: NSString? = nil
        AevonTryExecute({
            AevonSceneProbe.runOnceIfNeeded()
        }, &probeEx, &probeWhy)
        if let n = probeEx {
            AevonLog.warn("[引导] 场景探测抛异常（\(n): \(probeWhy ?? "无")），已拦截（AevonSceneProbeP0）")
        }

        var exName: NSString?
        var exReason: NSString?
        var installed: UIView?
        AevonTryExecute({
            installed = AevonEntryHost.ensureInstalled(reason: reason)
        }, &exName, &exReason)
        if let name = exName {
            AevonLog.warn("[引导] 入口创建抛异常（\(name): \(exReason ?? "无")），已拦截（AevonBootShieldV39）")
        }
        guard installed != nil else {
            AevonLog.info("[引导] 入口窗口暂不可用，等待下一次活跃态重试（\(reason)）")
            return
        }

        AevonTryExecute({
            AevonEdgeEntry.install(attempt: 1, reason: reason)
        }, &exName, &exReason)
        if let name = exName {
            AevonLog.warn("[引导] 手势条挂载抛异常（\(name): \(exReason ?? "无")），已拦截（AevonBootShieldV39）")
        }

        exName = nil
        exReason = nil
        AevonTryExecute({
            installSceneHookIfNeeded()
        }, &exName, &exReason)
        if let name = exName {
            AevonLog.warn("[引导] 场景钩子安装抛异常（\(name): \(exReason ?? "无")），已拦截（AevonBootShieldV39）")
        }

        // V0.0.23：App 前台时视图层收不到边缘触摸（被 App 画面命中测试截走），
        // 补一条不经过命中测试的全局通道。
        exName = nil
        exReason = nil
        AevonTryExecute({
            _ = AevonEdgeEntry.installGlobalTouch()
        }, &exName, &exReason)
        if let name = exName {
            AevonLog.warn("[引导] 全局触摸通道安装抛异常（\(name): \(exReason ?? "无")），已拦截（AevonBootShieldV39）")
        }
    }

    /// V0.0.22：装 App 画面容器钩子（只 hook viewDidAppear / viewDidDisappear 两个方法）。
    /// 入口视图要压在全屏 App 之上，唯一的落点就是 `SBDeviceApplicationSceneViewController.view`，
    /// 其余位置（窗口层级 / 场景根视图）都被真机日志证明无效或会失效。
    private static var sceneHookInstalled = false
    private static func installSceneHookIfNeeded() {
        guard !sceneHookInstalled else { return }
        sceneHookInstalled = true
        guard AevonSceneHookAvailable() else {
            AevonLog.warn("[入口] 未找到 App 画面容器类（SBDeviceApplicationSceneViewController），跳过钩子——桌面入口不受影响")
            return
        }
        AevonSceneHookInstall()
        AevonLog.info("[入口] App 画面容器钩子已安装（viewDidAppear / viewDidDisappear，包装全屏 App 用）（AevonSceneVCHookV22）")
        // V0.0.54（AevonSwitcherHideV54）：上滑进后台卡片时把浮窗藏起来 ——
        // App 画面被 transform 缩小时 `viewDidDisappear` 并不触发，只能自己看「还铺满整屏吗」。
        AevonSwitcherGuard.shared.start()
        AevonLog.info("[入口] 后台卡片隐藏守卫已启动（切换器通知 + 0.15 秒兜底轮询）（AevonSwitcherHideV54）")
    }
}
