import Foundation
import UIKit

/*
 * 全部 hook 入口。
 *
 * %orig 等价机制（不依赖 Orion / Substrate / Logos）：
 * SKSwizzle 把原始选择子与 sk_ 选择子交换后，系统类实例收到原始选择子时
 * 会执行本类中的 sk_ 方法（self 即系统类实例）；此时 sk_ 选择子上绑定的
 * 已是原始实现，用 SKRuntime.sendVoid* 直接向 sk_ 选择子发消息即可调用
 * 原始实现（等价 Logos 的 %orig）。
 *
 * 安全约定：
 * - 每个 sk_ 方法都先用 responds/实现存在性守卫，再调用原始实现；
 * - 原始实现调用失败时只记录日志，不抛出、不崩溃；
 * - 自定义逻辑全部放在原始实现之后（或按条件短路），保证系统行为不被破坏。
 */

// MARK: - SpringBoard：安装宿主窗口

@objc final class SKSpringBoardHooks: NSObject {
    @objc func sk_sb_applicationDidFinishLaunching(_ application: UIApplication) {
        // 先执行原始实现（SpringBoard 启动流程必须完整走完）
        SKRuntime.sendVoid(self, Selector(("sk_sb_applicationDidFinishLaunching:")), application)
        // 再创建承载窗口
        SKHostWindow.ensureInstalled()
    }
}

// MARK: - 多任务卡片：长按开窗（SBAppSwitcherPageView / SBFluidSwitcherItemContainer）

@objc final class SKSwitcherCardHooks: NSObject {
    @objc func sk_sbaspv_initWithFrame(_ frame: CGRect) -> Any? {
        let view = SKRuntime.sendInitFrame(self, Selector(("sk_sbaspv_initWithFrame:")), frame)
        if let view = view as? UIView {
            SKGestureHandler.shared.attachLongPress(to: view)
        }
        return view
    }

    @objc func sk_sbfsic_initWithFrame(_ frame: CGRect) -> Any? {
        let view = SKRuntime.sendInitFrame(self, Selector(("sk_sbfsic_initWithFrame:")), frame)
        if let view = view as? UIView {
            SKGestureHandler.shared.attachLongPress(to: view)
        }
        return view
    }
}

// MARK: - 主屏图标：添加快捷菜单 + 处理点击

@objc final class SKIconViewHooks: NSObject {
    private static let shortcutType = "com.splitkit.tweak.openwindow"

    @objc func sk_iconview_applicationShortcutItems() -> [Any]? {
        let original = SKRuntime.sendObject(self, Selector(("sk_iconview_applicationShortcutItems"))) as? [Any]
        guard SKPrefs.bool("Enabled", default: false) else { return original }
        guard let appID = appBundleID(self) else { return original }
        guard let allocated = SKRuntime.allocate("SBSApplicationShortcutItem"),
              let item = SKRuntime.sendOwned(allocated, Selector(("init"))) else {
            return original
        }
        SKRuntime.setValue(item, key: "localizedTitle", value: "Open in Window")
        SKRuntime.setValue(item, key: "bundleIdentifierToLaunch", value: appID)
        let typeSet = SKRuntime.setValue(item, key: "type", value: SKIconViewHooks.shortcutType)
        // 只有 type 写入成功（说明该类支持这三个属性）才追加菜单项，避免出现空行
        guard typeSet else { return original }

        var items = original ?? []
        items.append(item)
        return items
    }

    @objc func sk_iconview_activateShortcut(_ item: Any,
                                            withBundleIdentifier bundleID: String,
                                            forIconView iconView: Any?) {
        let type = (item as? AnyObject).flatMap { SKRuntime.send($0, Selector(("type"))) } as? String
        if type == SKIconViewHooks.shortcutType {
            SKLog.info("[图标] 收到窗口化快捷指令: \(bundleID)")
            launchAndWindow(bundleID: bundleID)
            return
        }
        SKRuntime.sendVoid(self,
                           Selector(("sk_iconview_activateShortcut:withBundleIdentifier:forIconView:")),
                           item, bundleID as NSString, iconView)
    }

    /// 以挂起方式启动 App，轮询等待场景就绪后开窗。
    private func launchAndWindow(bundleID: String) {
        let application = UIApplication.shared
        let launchSelector = Selector(("launchApplicationWithIdentifier:suspended:"))
        guard application.responds(to: launchSelector) else {
            SKLog.warn("[图标] 当前进程不支持 launchApplicationWithIdentifier:suspended:")
            return
        }
        SKRuntime.sendVoid(application, launchSelector, bundleID as NSString, true)

        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            attempts += 1
            if attempts > 20 {
                SKLog.warn("[图标] 等待场景超时: \(bundleID)")
                timer.invalidate()
                return
            }
            if SKSceneHelper.scene(for: bundleID) != nil {
                timer.invalidate()
                SKWindowManager.open(bundleID: bundleID, sceneID: nil)
            }
        }
    }

    private func appBundleID(_ iconView: AnyObject) -> String? {
        let selectors = [Selector(("applicationBundleIdentifier")),
                         Selector(("applicationBundleIdentifierForShortcuts"))]
        for selector in selectors {
            if iconView.responds(to: selector),
               let id = SKRuntime.send(iconView, selector) as? String {
                return id
            }
        }
        return nil
    }
}

// MARK: - FBScene：已窗口化场景强制前台

@objc final class SKFBSceneHooks: NSObject {
    @objc func sk_fbscene_updateSettings(_ settings: Any,
                                         withTransitionContext ctx: Any?,
                                         completion: Any?) {
        var finalSettings: Any = settings
        let identifier = sceneIdentifier(of: self)

        if SKForegroundManager.shared.shouldKeepForeground(identifier: identifier),
           let mutable = settings as? NSObject,
           SKRuntime.setBool(mutable, key: "foreground", true) {
            finalSettings = mutable
        }

        SKRuntime.sendVoid(self,
                           Selector(("sk_fbscene_updateSettings:withTransitionContext:completion:")),
                           finalSettings, ctx, completion)
    }

    static func sceneIdentifier(of scene: AnyObject) -> String {
        if let identifier = SKRuntime.send(scene, Selector(("identifier"))) as? String {
            return identifier
        }
        return SKRuntime.ivarString(scene, "_identifier") ?? ""
    }
}

// MARK: - UIMutableApplicationSceneSettings：拦截已窗口化场景的停用

@objc final class SKSceneSettingsHooks: NSObject {
    @objc func sk_uimass_setDeactivationReasons(_ reasons: UInt64) {
        if reasons != 0 {
            let identifier = selfIdentifier()
            if SKForegroundManager.shared.shouldBlockDeactivation(identifier: identifier) {
                SKLog.info("[场景] 拦截停用: \(identifier)")
                SKRuntime.sendVoidUInt64(self, Selector(("sk_uimass_setDeactivationReasons:")), 0)
                return
            }
        }
        SKRuntime.sendVoidUInt64(self, Selector(("sk_uimass_setDeactivationReasons:")), reasons)
    }

    private func selfIdentifier() -> String {
        for name in ["_identifier", "_sceneIdentifier", "_bundleIdentifier"] {
            if let value = SKRuntime.ivarString(self, name) { return value }
        }
        if self.responds(to: Selector(("identifier"))),
           let value = SKRuntime.send(self, Selector(("identifier"))) as? String {
            return value
        }
        return ""
    }
}

// MARK: - _UISceneHostingActivationStateHostComponent：已窗口化场景强制渲染

@objc final class SKSceneHostingActivationHooks: NSObject {
    @objc func sk_shac_setForeground(_ foreground: Bool) {
        if !foreground {
            if let sceneID = hostSceneIdentifier(of: self),
               SKForegroundManager.shared.shouldKeepForeground(identifier: sceneID) {
                SKRuntime.sendVoidBool(self, Selector(("sk_shac_setForeground:")), true)
                return
            }
        }
        SKRuntime.sendVoidBool(self, Selector(("sk_shac_setForeground:")), foreground)
    }

    private func hostSceneIdentifier(of component: AnyObject) -> String? {
        guard component.responds(to: Selector(("hostScene"))),
              let hostScene = SKRuntime.send(component, Selector(("hostScene"))) else { return nil }
        if let identifier = SKRuntime.send(hostScene, Selector(("persistentIdentifier"))) as? String {
            return identifier
        }
        if hostScene.responds(to: Selector(("identityToken"))),
           let token = SKRuntime.send(hostScene, Selector(("identityToken"))),
           let identifier = SKRuntime.send(token, Selector(("identifier"))) as? String {
            return identifier
        }
        return nil
    }
}

// MARK: - FBSceneLayerManager：图层变化时刷新浮窗

@objc final class SKSceneLayerManagerHooks: NSObject {
    @objc func sk_fbslm_setLayers(_ layers: Any) {
        SKRuntime.sendVoid(self, Selector(("sk_fbslm_setLayers:")), layers)
        SKWindowManager.notifyLayersUpdated()
    }
}

// MARK: - SBApplication：App 退出时清理窗口状态

@objc final class SKSBApplicationHooks: NSObject {
    @objc func sk_sbapp_didExitWithContext(_ context: Any?) {
        SKRuntime.sendVoid(self, Selector(("sk_sbapp_didExitWithContext:")), context)
        if self.responds(to: Selector(("bundleIdentifier"))),
           let bundleID = SKRuntime.send(self, Selector(("bundleIdentifier"))) as? String {
            SKWindowManager.close(bundleID: bundleID)
        }
    }
}
