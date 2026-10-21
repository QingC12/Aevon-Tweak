import Foundation
import UIKit

/*
 * 全部 hook 入口。
 *
 * %orig 等价机制（不依赖 Orion / Substrate / Logos）：
 * AESwizzle 把原始选择子与 sk_ 选择子交换后，系统类实例收到原始选择子时
 * 会执行本类中的 sk_ 方法（self 即系统类实例）；此时 sk_ 选择子上绑定的
 * 已是原始实现，用 AERuntime.sendVoid* 直接向 sk_ 选择子发消息即可调用
 * 原始实现（等价 Logos 的 %orig）。
 *
 * 安全约定：
 * - 每个 sk_ 方法都先用 responds/实现存在性守卫，再调用原始实现；
 * - 原始实现调用失败时只记录日志，不抛出、不崩溃；
 * - 自定义逻辑全部放在原始实现之后（或按条件短路），保证系统行为不被破坏。
 */

// MARK: - SpringBoard：安装宿主窗口

@objc final class AESpringBoardHooks: NSObject {
    @objc func sk_sb_applicationDidFinishLaunching(_ application: UIApplication) {
        // 先执行原始实现（SpringBoard 启动流程必须完整走完）
        AERuntime.sendVoid(self, Selector(("sk_sb_applicationDidFinishLaunching:")), application)
        // 再创建承载窗口
        AEHostWindow.ensureInstalled()
    }
}

// MARK: - 多任务卡片：长按开窗（SBAppSwitcherPageView / SBFluidSwitcherItemContainer）

@objc final class AESwitcherCardHooks: NSObject {
    @objc func sk_sbaspv_initWithFrame(_ frame: CGRect) -> Any? {
        let view = AERuntime.sendInitFrame(self, Selector(("sk_sbaspv_initWithFrame:")), frame)
        if let view = view as? UIView {
            AEGestureHandler.shared.attachLongPress(to: view)
        }
        return view
    }

    @objc func sk_sbfsic_initWithFrame(_ frame: CGRect) -> Any? {
        let view = AERuntime.sendInitFrame(self, Selector(("sk_sbfsic_initWithFrame:")), frame)
        if let view = view as? UIView {
            AEGestureHandler.shared.attachLongPress(to: view)
        }
        return view
    }
}

// MARK: - 主屏图标：添加快捷菜单 + 处理点击

@objc final class AEIconViewHooks: NSObject {
    private static let shortcutType = "com.aevon.tweak.openwindow"

    @objc func sk_iconview_applicationShortcutItems() -> [Any]? {
        let original = AERuntime.sendObject(self, Selector(("sk_iconview_applicationShortcutItems"))) as? [Any]
        guard AEPrefs.bool("Enabled", default: false) else { return original }
        guard let appID = appBundleID(self) else { return original }
        guard let allocated = AERuntime.allocate("SBSApplicationShortcutItem"),
              let item = AERuntime.sendOwned(allocated, Selector(("init"))) else {
            return original
        }
        AERuntime.setValue(item, key: "localizedTitle", value: "Open in Window")
        AERuntime.setValue(item, key: "bundleIdentifierToLaunch", value: appID)
        let typeSet = AERuntime.setValue(item, key: "type", value: AEIconViewHooks.shortcutType)
        // 只有 type 写入成功（说明该类支持这三个属性）才追加菜单项，避免出现空行
        guard typeSet else { return original }

        var items = original ?? []
        items.append(item)
        return items
    }

    @objc func sk_iconview_activateShortcut(_ item: Any,
                                            withBundleIdentifier bundleID: String,
                                            forIconView iconView: Any?) {
        let type: String? = {
            guard let object = item as? NSObject else { return nil }
            return AERuntime.send(object, Selector(("type"))) as? String
        }()
        if type == AEIconViewHooks.shortcutType {
            AELog.info("[图标] 收到窗口化快捷指令: \(bundleID)")
            launchAndWindow(bundleID: bundleID)
            return
        }
        AERuntime.sendVoid(self,
                           Selector(("sk_iconview_activateShortcut:withBundleIdentifier:forIconView:")),
                           item, bundleID as NSString, iconView)
    }

    /// 以挂起方式启动 App，轮询等待场景就绪后开窗。
    private func launchAndWindow(bundleID: String) {
        let application = UIApplication.shared
        let launchSelector = Selector(("launchApplicationWithIdentifier:suspended:"))
        guard application.responds(to: launchSelector) else {
            AELog.warn("[图标] 当前进程不支持 launchApplicationWithIdentifier:suspended:")
            return
        }
        AERuntime.sendVoid(application, launchSelector, bundleID as NSString, true)

        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            attempts += 1
            if attempts > 20 {
                AELog.warn("[图标] 等待场景超时: \(bundleID)")
                timer.invalidate()
                return
            }
            if AESceneHelper.scene(for: bundleID) != nil {
                timer.invalidate()
                AEWindowManager.open(bundleID: bundleID, sceneID: nil)
            }
        }
    }

    private func appBundleID(_ iconView: AnyObject) -> String? {
        let selectors = [Selector(("applicationBundleIdentifier")),
                         Selector(("applicationBundleIdentifierForShortcuts"))]
        for selector in selectors {
            if iconView.responds(to: selector),
               let id = AERuntime.send(iconView, selector) as? String {
                return id
            }
        }
        return nil
    }
}

// MARK: - FBScene：已窗口化场景强制前台

@objc final class AEFBSceneHooks: NSObject {
    @objc func sk_fbscene_updateSettings(_ settings: Any,
                                         withTransitionContext ctx: Any?,
                                         completion: Any?) {
        var finalSettings: Any = settings
        let identifier = AEFBSceneHooks.sceneIdentifier(of: self)

        if AEForegroundManager.shared.shouldKeepForeground(identifier: identifier),
           let mutable = settings as? NSObject,
           AERuntime.setBool(mutable, key: "foreground", true) {
            finalSettings = mutable
        }

        AERuntime.sendVoid(self,
                           Selector(("sk_fbscene_updateSettings:withTransitionContext:completion:")),
                           finalSettings, ctx, completion)
    }

    static func sceneIdentifier(of scene: AnyObject) -> String {
        if let identifier = AERuntime.send(scene, Selector(("identifier"))) as? String {
            return identifier
        }
        return AERuntime.ivarString(scene, "_identifier") ?? ""
    }
}

// MARK: - UIMutableApplicationSceneSettings：拦截已窗口化场景的停用

@objc final class AESceneSettingsHooks: NSObject {
    @objc func sk_uimass_setDeactivationReasons(_ reasons: UInt64) {
        if reasons != 0 {
            let identifier = selfIdentifier()
            if AEForegroundManager.shared.shouldBlockDeactivation(identifier: identifier) {
                AELog.info("[场景] 拦截停用: \(identifier)")
                AERuntime.sendVoidUInt64(self, Selector(("sk_uimass_setDeactivationReasons:")), 0)
                return
            }
        }
        AERuntime.sendVoidUInt64(self, Selector(("sk_uimass_setDeactivationReasons:")), reasons)
    }

    private func selfIdentifier() -> String {
        for name in ["_identifier", "_sceneIdentifier", "_bundleIdentifier"] {
            if let value = AERuntime.ivarString(self, name) { return value }
        }
        if self.responds(to: Selector(("identifier"))),
           let value = AERuntime.send(self, Selector(("identifier"))) as? String {
            return value
        }
        return ""
    }
}

// MARK: - _UISceneHostingActivationStateHostComponent：已窗口化场景强制渲染

@objc final class AESceneHostingActivationHooks: NSObject {
    @objc func sk_shac_setForeground(_ foreground: Bool) {
        if !foreground {
            if let sceneID = hostSceneIdentifier(of: self),
               AEForegroundManager.shared.shouldKeepForeground(identifier: sceneID) {
                AERuntime.sendVoidBool(self, Selector(("sk_shac_setForeground:")), true)
                return
            }
        }
        AERuntime.sendVoidBool(self, Selector(("sk_shac_setForeground:")), foreground)
    }

    private func hostSceneIdentifier(of component: AnyObject) -> String? {
        guard component.responds(to: Selector(("hostScene"))),
              let hostScene = AERuntime.send(component, Selector(("hostScene"))) else { return nil }
        if let identifier = AERuntime.send(hostScene, Selector(("persistentIdentifier"))) as? String {
            return identifier
        }
        if hostScene.responds(to: Selector(("identityToken"))),
           let token = AERuntime.send(hostScene, Selector(("identityToken"))),
           let identifier = AERuntime.send(token, Selector(("identifier"))) as? String {
            return identifier
        }
        return nil
    }
}

// MARK: - FBSceneLayerManager：图层变化时刷新浮窗

@objc final class AESceneLayerManagerHooks: NSObject {
    @objc func sk_fbslm_setLayers(_ layers: Any) {
        AERuntime.sendVoid(self, Selector(("sk_fbslm_setLayers:")), layers)
        AEWindowManager.notifyLayersUpdated()
    }
}

// MARK: - SBApplication：App 退出时清理窗口状态

@objc final class AESBApplicationHooks: NSObject {
    @objc func sk_sbapp_didExitWithContext(_ context: Any?) {
        AERuntime.sendVoid(self, Selector(("sk_sbapp_didExitWithContext:")), context)
        if self.responds(to: Selector(("bundleIdentifier"))),
           let bundleID = AERuntime.send(self, Selector(("bundleIdentifier"))) as? String {
            AEWindowManager.close(bundleID: bundleID)
        }
    }
}
