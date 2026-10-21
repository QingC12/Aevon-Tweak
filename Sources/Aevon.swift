import Foundation
import UIKit

/// Aevon 版本号（与 control 保持一致）。
let AEVersion = "0.0.3"

/// dyld 构造函数入口（由 ctor.m 以 C 符号调用）。
/// 约定：本函数绝不抛出、绝不强制解包失败；任何异常路径只记录日志。
@_cdecl("aevon_initialize")
func aevonInitialize() {
    initializeAevon()
}

private func initializeAevon() {
    AELog.info("Aevon \(AEVersion) 开始加载 (iOS \(UIDevice.current.systemVersion), 进程 \(ProcessInfo.processInfo.processName))")

    // 1) 开机崩溃守卫必须最先执行
    let safeToContinue = AECrashGuard.install()
    guard safeToContinue else { return }

    // 2) 总开关（V0.0.2 起默认关闭：首个带 hook 的版本需要用户在设置中显式开启）
    let enabled = AEPrefs.bool("Enabled", default: false)
    if !enabled {
        AELog.info("Aevon 未启用（默认关闭）。请在 设置 → Aevon 打开「启用插件」后注销生效。")
        return
    }

    // 3) 安装全部 hook（每个 hook 都有类/方法存在性守卫）
    installHooks()

    AELog.info("Aevon \(AEVersion) 加载完成，hook 已安装。")
}

private func installHooks() {
    // 宿主窗口：SpringBoard 启动后创建
    AESwizzle.install(targetClassName: "SpringBoard",
                      original: Selector(("applicationDidFinishLaunching:")),
                      replacementClass: AESpringBoardHooks.self,
                      replacement: #selector(AESpringBoardHooks.sk_sb_applicationDidFinishLaunching(_:)))

    // 入口一：多任务卡片长按开窗（两个候选类，运行时哪个存在用哪个）
    AESwizzle.install(targetClassName: "SBAppSwitcherPageView",
                      original: Selector(("initWithFrame:")),
                      replacementClass: AESwitcherCardHooks.self,
                      replacement: #selector(AESwitcherCardHooks.sk_sbaspv_initWithFrame(_:)))
    AESwizzle.install(targetClassName: "SBFluidSwitcherItemContainer",
                      original: Selector(("initWithFrame:")),
                      replacementClass: AESwitcherCardHooks.self,
                      replacement: #selector(AESwitcherCardHooks.sk_sbfsic_initWithFrame(_:)))

    // 入口二：主屏图标长按快捷菜单「Open in Window」
    AESwizzle.install(targetClassName: "SBIconView",
                      original: Selector(("applicationShortcutItems")),
                      replacementClass: AEIconViewHooks.self,
                      replacement: Selector(("sk_iconview_applicationShortcutItems")))
    AESwizzle.install(targetClassName: "SBIconView",
                      original: Selector(("activateShortcut:withBundleIdentifier:forIconView:")),
                      replacementClass: AEIconViewHooks.self,
                      replacement: #selector(AEIconViewHooks.sk_iconview_activateShortcut(_:withBundleIdentifier:forIconView:)),
                      isClassMethod: true)

    // 前台保持：只对已窗口化场景生效，未开窗时系统行为零改动
    AESwizzle.install(targetClassName: "FBScene",
                      original: Selector(("updateSettings:withTransitionContext:completion:")),
                      replacementClass: AEFBSceneHooks.self,
                      replacement: #selector(AEFBSceneHooks.sk_fbscene_updateSettings(_:withTransitionContext:completion:)))
    AESwizzle.install(targetClassName: "UIMutableApplicationSceneSettings",
                      original: Selector(("setDeactivationReasons:")),
                      replacementClass: AESceneSettingsHooks.self,
                      replacement: #selector(AESceneSettingsHooks.sk_uimass_setDeactivationReasons(_:)))
    AESwizzle.install(targetClassName: "_UISceneHostingActivationStateHostComponent",
                      original: Selector(("setForeground:")),
                      replacementClass: AESceneHostingActivationHooks.self,
                      replacement: #selector(AESceneHostingActivationHooks.sk_shac_setForeground(_:)))

    // 图层变化刷新 + App 退出清理
    AESwizzle.install(targetClassName: "FBSceneLayerManager",
                      original: Selector(("_setLayers:")),
                      replacementClass: AESceneLayerManagerHooks.self,
                      replacement: #selector(AESceneLayerManagerHooks.sk_fbslm_setLayers(_:)))
    AESwizzle.install(targetClassName: "SBApplication",
                      original: Selector(("_didExitWithContext:")),
                      replacementClass: AESBApplicationHooks.self,
                      replacement: #selector(AESBApplicationHooks.sk_sbapp_didExitWithContext(_:)))
}
