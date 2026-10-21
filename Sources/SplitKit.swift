import Foundation
import UIKit

/// SplitKit 版本号（与 control 保持一致）。
let SKVersion = "0.0.2"

/// dyld 构造函数入口（由 ctor.m 以 C 符号调用）。
/// 约定：本函数绝不抛出、绝不强制解包失败；任何异常路径只记录日志。
@_cdecl("splitkit_initialize")
func splitkitInitialize() {
    initializeSplitKit()
}

private func initializeSplitKit() {
    SKLog.info("SplitKit \(SKVersion) 开始加载 (iOS \(UIDevice.current.systemVersion), 进程 \(ProcessInfo.processInfo.processName))")

    // 1) 开机崩溃守卫必须最先执行
    let safeToContinue = SKCrashGuard.install()
    guard safeToContinue else { return }

    // 2) 总开关（V0.0.2 起默认关闭：首个带 hook 的版本需要用户在设置中显式开启）
    let enabled = SKPrefs.bool("Enabled", default: false)
    if !enabled {
        SKLog.info("SplitKit 未启用（默认关闭）。请在 设置 → SplitKit 打开「启用插件」后注销生效。")
        return
    }

    // 3) 安装全部 hook（每个 hook 都有类/方法存在性守卫）
    installHooks()

    SKLog.info("SplitKit \(SKVersion) 加载完成，hook 已安装。")
}

private func installHooks() {
    // 宿主窗口：SpringBoard 启动后创建
    SKSwizzle.install(targetClassName: "SpringBoard",
                      original: Selector(("applicationDidFinishLaunching:")),
                      replacementClass: SKSpringBoardHooks.self,
                      replacement: #selector(SKSpringBoardHooks.sk_sb_applicationDidFinishLaunching(_:)))

    // 入口一：多任务卡片长按开窗（两个候选类，运行时哪个存在用哪个）
    SKSwizzle.install(targetClassName: "SBAppSwitcherPageView",
                      original: Selector(("initWithFrame:")),
                      replacementClass: SKSwitcherCardHooks.self,
                      replacement: #selector(SKSwitcherCardHooks.sk_sbaspv_initWithFrame(_:)))
    SKSwizzle.install(targetClassName: "SBFluidSwitcherItemContainer",
                      original: Selector(("initWithFrame:")),
                      replacementClass: SKSwitcherCardHooks.self,
                      replacement: #selector(SKSwitcherCardHooks.sk_sbfsic_initWithFrame(_:)))

    // 入口二：主屏图标长按快捷菜单「Open in Window」
    SKSwizzle.install(targetClassName: "SBIconView",
                      original: Selector(("applicationShortcutItems")),
                      replacementClass: SKIconViewHooks.self,
                      replacement: Selector(("sk_iconview_applicationShortcutItems")))
    SKSwizzle.install(targetClassName: "SBIconView",
                      original: Selector(("activateShortcut:withBundleIdentifier:forIconView:")),
                      replacementClass: SKIconViewHooks.self,
                      replacement: #selector(SKIconViewHooks.sk_iconview_activateShortcut(_:withBundleIdentifier:forIconView:)),
                      isClassMethod: true)

    // 前台保持：只对已窗口化场景生效，未开窗时系统行为零改动
    SKSwizzle.install(targetClassName: "FBScene",
                      original: Selector(("updateSettings:withTransitionContext:completion:")),
                      replacementClass: SKFBSceneHooks.self,
                      replacement: #selector(SKFBSceneHooks.sk_fbscene_updateSettings(_:withTransitionContext:completion:)))
    SKSwizzle.install(targetClassName: "UIMutableApplicationSceneSettings",
                      original: Selector(("setDeactivationReasons:")),
                      replacementClass: SKSceneSettingsHooks.self,
                      replacement: #selector(SKSceneSettingsHooks.sk_uimass_setDeactivationReasons(_:)))
    SKSwizzle.install(targetClassName: "_UISceneHostingActivationStateHostComponent",
                      original: Selector(("setForeground:")),
                      replacementClass: SKSceneHostingActivationHooks.self,
                      replacement: #selector(SKSceneHostingActivationHooks.sk_shac_setForeground(_:)))

    // 图层变化刷新 + App 退出清理
    SKSwizzle.install(targetClassName: "FBSceneLayerManager",
                      original: Selector(("_setLayers:")),
                      replacementClass: SKSceneLayerManagerHooks.self,
                      replacement: #selector(SKSceneLayerManagerHooks.sk_fbslm_setLayers(_:)))
    SKSwizzle.install(targetClassName: "SBApplication",
                      original: Selector(("_didExitWithContext:")),
                      replacementClass: SKSBApplicationHooks.self,
                      replacement: #selector(SKSBApplicationHooks.sk_sbapp_didExitWithContext(_:)))
}
