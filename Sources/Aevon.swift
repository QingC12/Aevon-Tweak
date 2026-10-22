import Foundation
import UIKit

/// Aevon 版本号（与 control 保持一致；CI 会按 tag 覆盖本行）。
let AevonVersion = "0.0.38"

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
     * V0.0.37（AevonDeactivationGateV37）：窗口化场景的核心保障 hook 不再挂在
     * 「强制前台保持（实验）」开关后面 —— 浮窗是本插件的主功能，这些 hook 就是
     * 主功能的一部分。Aevon(30) 日志铁证：这一族 hook 从未装上（零 [hook] 已安装行），
     * 全屏 App 抢前台时浮窗场景被系统停用 → 画面看得见、点不动。
     * Stheno 逆向数据佐证：其浮动窗口同样 hook UIApplicationSceneDeactivationManager
     * 的 `_setDeactivationReasons:onScene:withSettings:reason:` 保住输入路由。
     */
    // ① FBScene 设置更新：登记过的窗口化场景强制 foreground=true
    AevonSwizzle.install(targetClassName: "FBScene",
                         original: Selector(("updateSettings:withTransitionContext:completion:")),
                         replacementClass: AevonFBSceneHooks.self,
                         replacement: #selector(AevonFBSceneHooks.sk_fbscene_updateSettings(_:withTransitionContext:completion:)))
    // ② iOS 17 真正的停用入口：UIApplicationSceneDeactivationManager（Stheno 同款）
    AevonSwizzle.install(targetClassName: "UIApplicationSceneDeactivationManager",
                         original: Selector(("_setDeactivationReasons:onScene:withSettings:reason:")),
                         replacementClass: AevonSceneDeactivationHooks.self,
                         replacement: #selector(AevonSceneDeactivationHooks.sk_uasdm_setDeactivationReasons(_:onScene:withSettings:reason:)))
    // ③ 旧路径兜底：UIMutableApplicationSceneSettings 的停用原因（iOS 15/16 生效）
    AevonSwizzle.install(targetClassName: "UIMutableApplicationSceneSettings",
                         original: Selector(("setDeactivationReasons:")),
                         replacementClass: AevonSceneSettingsHooks.self,
                         replacement: #selector(AevonSceneSettingsHooks.sk_uimass_setDeactivationReasons(_:)))
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
    AevonLog.info("[启动] 已安装窗口化场景保障 hook（AevonDeactivationGateV37）")
}
