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
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                installEntries(reason: "didFinishLaunching")
            }
        }

        // 兜底：每次回到活跃态时检查一遍（首次没有场景 / 被系统回收 / 屏幕尺寸变化时补建与校正）
        // V0.0.39：延迟 1.5 → 3.0 秒 —— V0.0.38 在 didBecomeActive+1.5s 的窗口创建段
        // 出现 SIGSEGV（Aevon(32)），此时 SpringBoard 自身布局还没铺完，错峰降低竞态概率。
        _ = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil,
                               queue: .main) { _ in
            guard !AevonEdgeEntry.isVisible || !AevonEntryHost.isInstalled else {
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

    /// 建唯一入口窗口 → 装全局触摸通道（0.2.51 起没有手势条，呼盘只有把手）
    ///
    /// V0.0.39（AevonBootShieldV39）：每一步独立套 ObjC 异常保护并落面包屑日志 ——
    /// 任何一步抛 NSException 只记日志不中断启动，后续步骤照常；绝不再把异常抛回系统。
    private static func installEntries(reason: String) {
        guard AevonPrefs.bool("Enabled", default: true) else { return }

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

        exName = nil
        exReason = nil
        AevonTryExecute({
            installSceneHookIfNeeded()
        }, &exName, &exReason)
        if let name = exName {
            AevonLog.warn("[引导] 场景钩子安装抛异常（\(name): \(exReason ?? "无")），已拦截（AevonBootShieldV39）")
        }

        // V0.3.4（AevonGripSystemLegV304）：系统识别器腿 —— **常驻安装**，
        // 不受 GripHookProbe 开关影响（那开关只控制实例级细节日志）。
        // 右缘 began 由系统边沿识别器认领，呼盘不再依赖自建控件抢触摸。
        exName = nil
        exReason = nil
        AevonTryExecute({
            _ = AevonGripSystemLegInstall()
        }, &exName, &exReason)
        if let name = exName {
            AevonLog.warn("[引导] 系统识别器腿安装抛异常（\(name): \(exReason ?? "无")），已拦截，呼出退回把手通道（AevonGripSystemLegV304）")
        }

        // V0.3.9（AevonGripOwnLegV309）：自建识别器腿 —— 只有 GripOwnLeg 打开才装配。
        // V0.3.10（AevonOwnLegDefaultV310）：**默认转正**（false → true）。依据 Aevon(88)：
        // 63 次呼盘 100% 仍走借识别器腿（自建腿 0 条日志），抖音 24 次全部恰好 8pt 就呼盘 ——
        // 那 8pt 已经派给了 App，抖音 feed 是横向分页、8pt 就露出作者主页一截，
        // 而微信/QQ/B站/酷安的同类泄漏被交互式返回的回弹吃掉了，所以「只有抖音看得见」。
        // 装配改成主动重试（不等第一次滑动），失败一律 fail-open 回借识别器腿。
        exName = nil
        exReason = nil
        AevonTryExecute({
            // V0.3.15（AevonGripHardcodeV315）：第一参从「读 GripOwnLeg」改成常量 true。
            // 用户 Aevon(93) 定档：默认开启的呼出手势开关写进代码、设置页不再显示。
            // 第二参 GripHookProbe 仍读偏好 —— 只控制取证深度，UI 已移除（恒 false）。
            AevonGripOwnLegEnable(true,
                                  AevonPrefs.bool("GripHookProbe", default: false))
        }, &exName, &exReason)
        if let name = exName {
            AevonLog.warn("[引导] 自建识别器腿开关读取抛异常（\(name): \(exReason ?? "无")），已拦截，保持关闭（AevonGripOwnLegV309）")
        }

        // V0.2.99（AevonGripProbeV299）：SBGrabberTongue 探测骨架（默认关，@try 包裹 fail-open）。
        exName = nil
        exReason = nil
        AevonTryExecute({
            installGripProbeIfNeeded()
        }, &exName, &exReason)
        if let name = exName {
            AevonLog.warn("[引导] GripHook 探测安装抛异常（\(name): \(exReason ?? "无")），已拦截（AevonGripProbeV299）")
        }

        // V0.0.23：全局触摸通道 —— 浮窗窗外手势与圆盘指针喂料的唯一基础设施。
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
    }

    /// V0.2.99（AevonGripProbeV299）：SBGrabberTongue 探测骨架（方案 A 灰度）。
    /// 默认关（Prefs GripHookProbe）——用户在设置里显式打开才装。只观察不接管，
    /// 失败 fail-open（呼出走既有把手通道），为下一版呼出主通道切换取真机数据。
    private static var gripProbeInstalled = false
    static func installGripProbeIfNeeded() {
        guard !gripProbeInstalled else { return }
        gripProbeInstalled = true
        guard AevonPrefs.bool("GripHookProbe", default: false) else { return }
        _ = AevonGripHookProbeInstall()
    }
}
