import Foundation
import UIKit

/// Aevon 版本号（与 control 保持一致；CI 会按 tag 覆盖本行）。
let AevonVersion = "0.0.40"

/// dyld 构造函数入口（由 AevonAssertionShim.m 以 C 符号调用）。
/// 约定：本函数绝不抛出、绝不强制解包失败；任何异常路径只记录日志。
@_cdecl("AevonInitialize")
func aevonInitialize() {
    initializeAevon()
}

private func initializeAevon() {
    AevonLog.info("Aevon \(AevonVersion) 开始加载 (iOS \(UIDevice.current.systemVersion), 进程 \(ProcessInfo.processInfo.processName))")

    // 1) 崩溃捕获最先安装：后续任何一行崩了都能留下原因
    AevonCrashCatcher.install()
    AevonCrashCatcher.harvestPreviousCrash()

    // 2) 开机崩溃守卫（上次没跑稳 → 自动禁用）
    let safeToContinue = AevonCrashGuard.install()
    guard safeToContinue else { return }

    // 3) 总开关（默认关闭）
    guard AevonPrefs.bool("Enabled", default: false) else {
        AevonLog.info("Aevon 未启用（默认关闭）。请在 设置 → Aevon 打开「启用插件」后注销生效。")
        return
    }

    /*
     * V0.0.7 的关键改动（针对 V0.0.6「长按桌面图标 → 自动注销」）：
     *
     * V0.0.6 用 hook 往 SBIconView 的长按菜单里塞「Open in Window」，
     * 日志显示 applicationShortcutItems 首次被调用后约 220ms SpringBoard 收到
     * SIGBUS 退出 —— 伪造的 SBSApplicationShortcutItem 触发了 SpringBoard
     * 内部对快捷菜单项的约束。
     *
     * 现在入口换成「悬浮球」：
     *   - 启动阶段零 hook，只注册两个 UIApplication 生命周期通知；
     *   - 桌面稳定后在自己创建的穿透窗口里放一个圆球，点它选 App 即可开窗；
     *   - 系统类（SBIconView / SBIconModel 等）完全不碰，长按图标恢复原样。
     */
    AevonBootstrap.start()

    // 4) 实验性 hook 一律延迟 10 秒，且必须用户显式打开对应开关
    let delay: TimeInterval = 10
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        guard AevonPrefs.bool("Enabled", default: false) else {
            AevonLog.info("[启动] 延迟期间插件被关闭，不安装实验 hook")
            return
        }
        installExperimentalHooks()
        AevonLog.info("Aevon \(AevonVersion) 加载完成（边缘圆盘入口已就绪）")
    }
}

private func installExperimentalHooks() {
    // 实验入口：多任务卡片长按开窗（默认关）
    if AevonPrefs.bool("SwitcherLongPress", default: false) {
        AevonSwizzle.install(targetClassName: "SBAppSwitcherPageView",
                             original: Selector(("initWithFrame:")),
                             replacementClass: AevonSwitcherCardHooks.self,
                             replacement: #selector(AevonSwitcherCardHooks.sk_sbaspv_initWithFrame(_:)))
        AevonLog.info("[启动] 已安装「多任务卡片长按」hook（实验）")
    }

    /*
     * V0.1.3（AevonGateRemovedV103）：**场景停用门控已整体删除**。
     * 归档(12)/(13) 两次真机实锤它是「安全模式 / 自动注销」的唯一来源：
     * 「浮窗开着设置 → 桌面点设置图标」的转正过渡期，拦截停用原因后 FrontBoard
     * 内部断言崩溃（SIGTRAP）。0.1.2 用 ObjC 异常保护包裹原始实现后依旧崩 ——
     * 因为炸点不在调用链，而在 FBS 自己的状态机不变量。这条路走不通，停止对赌。
     *
     * 下面保留的都是**不碰停用原因**的安全 hook：只改 foreground 标记与激活状态，
     * 让窗口化场景保持渲染与输入路由，不参与 deactivation 状态机。
     */
    // ① FBScene 设置更新：登记过的窗口化场景强制 foreground=true
    AevonSwizzle.install(targetClassName: "FBScene",
                         original: Selector(("updateSettings:withTransitionContext:completion:")),
                         replacementClass: AevonFBSceneHooks.self,
                         replacement: #selector(AevonFBSceneHooks.sk_fbscene_updateSettings(_:withTransitionContext:completion:)))
    // ④ 场景宿主激活状态组件：不让系统把窗口化场景的 foreground 拉回 false
    AevonSwizzle.install(targetClassName: "_UISceneHostingActivationStateHostComponent",
                         original: Selector(("setForeground:")),
                         replacementClass: AevonSceneHostingActivationHooks.self,
                         replacement: #selector(AevonSceneHostingActivationHooks.sk_shac_setForeground(_:)))
    // ⑤ 图层更新 → 浮窗布局刷新
    AevonSwizzle.install(targetClassName: "FBSceneLayerManager",
                         original: Selector(("_setLayers:")),
                         replacementClass: AevonSceneLayerManagerHooks.self,
                         replacement: #selector(AevonSceneLayerManagerHooks.sk_fbslm_setLayers(_:)))
    AevonLog.info("[启动] 已安装窗口化场景保障 hook（无停用门控，AevonGateRemovedV103）")

    /*
     * ⑥ V0.1.4（AevonIconLaunchV104）：桌面图标启动 → 先把浮窗交还系统。
     *    「浮窗开着设置 → 回桌面点设置图标 → 自动注销」在 0.1.1/0.1.2/0.1.3 三版都没治好，
     *    因为前面几版都在改「拦截停用原因 / 包异常保护」，而真正撞车的是**同一个场景
     *    正被 FrontBoard 全屏拉起时我们还握着它**。这一版改成在系统接手之前先松手。
     */
    var iconLaunchHooked = AevonSwizzle.install(
        targetClassName: "SBIconController",
        original: Selector(("iconManager:launchIconForIconView:withActions:")),
        replacementClass: AevonIconLaunchHooks.self,
        replacement: #selector(AevonIconLaunchHooks.sk_sbic_launchIcon(_:forIconView:withActions:)))
    if !iconLaunchHooked {
        // 兜底：不同 iOS 版本这条启动委托可能落在别的类上（只试确定存在的几个，
        // 全部失败就放弃，绝不对未知类做泛洪 hook）
        for className in ["SBHomeScreenController", "SBIconView"] {
            if AevonSwizzle.install(
                targetClassName: className,
                original: Selector(("iconManager:launchIconForIconView:withActions:")),
                replacementClass: AevonIconLaunchHooks.self,
                replacement: #selector(AevonIconLaunchHooks.sk_sbic_launchIcon(_:forIconView:withActions:))) {
                iconLaunchHooked = true
                break
            }
        }
    }
    if iconLaunchHooked {
        AevonLog.info("[启动] 已安装桌面图标启动 hook（先释放浮窗，再让系统全屏拉起）（AevonIconLaunchV104）")
    } else {
        AevonLog.warn("[启动] 桌面图标启动 hook 未安装（找不到启动委托），本次只靠 FBScene 透传保护（AevonIconLaunchV104）")
    }

    /*
     * ⑦ V0.1.4（AevonSystemGestureV104）：全屏 App 内的右缘改由系统手势窗口接管。
     *    原因见 AevonSystemGestureV104 头注释：App 的触摸由 backboardd 直投，
     *    SpringBoard 侧丢事件不影响 App，只有「从触摸落下那一刻就归 SpringBoard」
     *    才能让抖音既不翻页也不拖进度条。
     */
    AevonSystemGestureV104.shared.install()
}
