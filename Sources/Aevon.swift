import Foundation
import UIKit

/// Aevon 版本号（与 control 保持一致）。
let AevonVersion = "0.0.6"

/// dyld 构造函数入口（由 ctor.m 以 C 符号调用）。
/// 约定：本函数绝不抛出、绝不强制解包失败；任何异常路径只记录日志。
@_cdecl("AevonInitialize")
func aevonInitialize() {
    initializeAevon()
}

private func initializeAevon() {
    AevonLog.info("Aevon \(AevonVersion) 开始加载 (iOS \(UIDevice.current.systemVersion), 进程 \(ProcessInfo.processInfo.processName))")

    // 1) 崩溃捕获最先安装：后面任何一行代码崩了都能留下原因
    AevonCrashCatcher.install()
    AevonCrashCatcher.harvestPreviousCrash()

    // 2) 开机崩溃守卫（上次是否没跑稳 → 自动禁用）
    let safeToContinue = AevonCrashGuard.install()
    guard safeToContinue else { return }

    // 3) 总开关（默认关闭）
    let enabled = AevonPrefs.bool("Enabled", default: false)
    if !enabled {
        AevonLog.info("Aevon 未启用（默认关闭）。请在 设置 → Aevon 打开「启用插件」后注销生效。")
        return
    }

    /*
     * V0.0.6 关键改动：不再在启动瞬间装 hook、也不再在启动瞬间创建宿主窗口。
     *
     * V0.0.5 的现象是：开启后注销 → SpringBoard 启动约 10 秒内崩溃 → 安全模式。
     * 日志最后一条停在「宿主窗口已创建」，说明崩溃发生在启动阶段的窗口/hook 路径上。
     * 现在把安装动作整体推迟到启动完成之后，开机阶段系统路径上没有任何 Aevon 代码，
     * 即使后续仍出问题，也不会再让手机起不来，而且崩溃原因会被 crash.log 记录下来。
     */
    let delay: TimeInterval = 8
    AevonLog.info("[启动] 将在 \(Int(delay)) 秒后安装 hook（先让 SpringBoard 完成启动）")
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        // 延迟期间用户可能在设置里关掉了开关，这里再确认一次
        guard AevonPrefs.bool("Enabled", default: false) else {
            AevonLog.info("[启动] 延迟期间插件被关闭，放弃安装 hook")
            return
        }
        AevonLog.info("[启动] 开始安装 hook")
        installHooks()
        AevonLog.info("Aevon \(AevonVersion) 加载完成，hook 已安装。")
    }
}

private func installHooks() {
    /*
     * V0.0.6 默认只安装「主屏图标长按 → Open in Window」这一条入口的 hook。
     * 其余 hook 全部改为设置里的实验开关，默认不装 —— 这是本次避免安全模式的核心。
     */

    // 入口一（默认启用）：主屏图标长按快捷菜单
    AevonSwizzle.install(targetClassName: "SBIconView",
                         original: Selector(("applicationShortcutItems")),
                         replacementClass: AevonIconViewHooks.self,
                         replacement: Selector(("sk_iconview_applicationShortcutItems")))
    AevonSwizzle.install(targetClassName: "SBIconView",
                         original: Selector(("activateShortcut:withBundleIdentifier:forIconView:")),
                         replacementClass: AevonIconViewHooks.self,
                         replacement: #selector(AevonIconViewHooks.sk_iconview_activateShortcut(_:withBundleIdentifier:forIconView:)),
                         isClassMethod: true)

    // 入口二（实验，默认关）：多任务卡片长按开窗
    if AevonPrefs.bool("SwitcherLongPress", default: false) {
        AevonSwizzle.install(targetClassName: "SBAppSwitcherPageView",
                             original: Selector(("initWithFrame:")),
                             replacementClass: AevonSwitcherCardHooks.self,
                             replacement: #selector(AevonSwitcherCardHooks.sk_sbaspv_initWithFrame(_:)))
        AevonLog.info("[启动] 已安装「多任务卡片长按」hook（实验）")
    }

    // 前台保持（实验，默认关）：会改写系统场景状态，风险最高，只在用户显式开启时才装
    if AevonPrefs.bool("ForceForeground", default: false) {
        AevonSwizzle.install(targetClassName: "FBScene",
                             original: Selector(("updateSettings:withTransitionContext:completion:")),
                             replacementClass: AevonFBSceneHooks.self,
                             replacement: #selector(AevonFBSceneHooks.sk_fbscene_updateSettings(_:withTransitionContext:completion:)))
        AevonSwizzle.install(targetClassName: "UIMutableApplicationSceneSettings",
                             original: Selector(("setDeactivationReasons:")),
                             replacementClass: AevonSceneSettingsHooks.self,
                             replacement: #selector(AevonSceneSettingsHooks.sk_uimass_setDeactivationReasons(_:)))
        AevonSwizzle.install(targetClassName: "FBSceneLayerManager",
                             original: Selector(("_setLayers:")),
                             replacementClass: AevonSceneLayerManagerHooks.self,
                             replacement: #selector(AevonSceneLayerManagerHooks.sk_fbslm_setLayers(_:)))
        AevonLog.info("[启动] 已安装「强制前台保持」hook（实验）")
    }
}
