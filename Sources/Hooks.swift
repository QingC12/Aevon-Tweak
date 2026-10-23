import Foundation
import UIKit

/*
 * 全部 hook 入口。
 *
 * %orig 等价机制（不依赖 Orion / Substrate / Logos）：
 * AevonSwizzle 把原始选择子与 sk_ 选择子交换后，系统类实例收到原始选择子时
 * 会执行本类中的 sk_ 方法（self 即系统类实例）；此时 sk_ 选择子上绑定的
 * 已是原始实现，用 AevonRuntime.sendVoid* 直接向 sk_ 选择子发消息即可调用
 * 原始实现（等价 Logos 的 %orig）。
 *
 * 安全约定：
 * - 每个 sk_ 方法都先用 responds/实现存在性守卫，再调用原始实现；
 * - 原始实现调用失败时只记录日志，不抛出、不崩溃；
 * - 自定义逻辑全部放在原始实现之后（或按条件短路），保证系统行为不被破坏。
 */

// MARK: - 多任务卡片：长按开窗（SBAppSwitcherPageView）

@objc final class AevonSwitcherCardHooks: NSObject {
    @objc func sk_sbaspv_initWithFrame(_ frame: CGRect) -> Any? {
        AevonTrace.once("sbaspv", "SBAppSwitcherPageView initWithFrame 首次调用")
        let view = AevonRuntime.sendInitFrame(self, Selector(("sk_sbaspv_initWithFrame:")), frame)
        if let view = view as? UIView {
            AevonGestureHandler.shared.attachLongPress(to: view)
        }
        return view
    }
}

// MARK: - UIApplicationSceneDeactivationManager：窗口化场景停用门控（V0.0.37）
//
// 问题1（Aevon(30)）的根治点：全屏 App X 在前台时，系统会把浮窗里场景 Y 判为
// 非前台并停用，Y 的 UI 连接从此不收输入 —— 浮窗画面看得见、点不动。
// 桌面正常是因为没有别的 App 来抢前台。
//
// Stheno 逆向证据（Stheno.dylib.txt）：`UIApplicationSceneDeactivationManagerHook` +
// `_setDeactivationReasons:onScene:withSettings:reason:`（类型编码 v48@0:8q16@24@32@40）。
// Stheno 的浮动窗口正是 hook 这里把停用原因清零，触摸路由才不会断。
// 我们旧版 hook 的 `UIMutableApplicationSceneSettings setDeactivationReasons:`
// 在 iOS 17.3 上没有打中真正的停用入口，且挂在默认关闭的实验开关后面。
@objc final class AevonSceneDeactivationHooks: NSObject {
    @objc func sk_uasdm_setDeactivationReasons(_ reasons: UInt64,
                                               onScene scene: Any?,
                                               withSettings settings: Any?,
                                               reason reasonInfo: Any?) {
        var finalReasons = reasons
        if reasons != 0, let scene = scene as AnyObject? {
            let identifier = AevonSceneDeactivationHooks.sceneIdentifier(of: scene)
            if AevonForegroundManager.shared.shouldBlockDeactivation(identifier: identifier) {
                finalReasons = 0
                let now = ProcessInfo.processInfo.systemUptime
                if now - Self.lastBlockLog > 2.0 {
                    Self.lastBlockLog = now
                    AevonLog.info("[场景] 已拦截场景停用（\(identifier)，AevonDeactivationGateV37）")
                }
            }
        }
        AevonRuntime.sendVoid(self,
                              Selector(("sk_uasdm_setDeactivationReasons:onScene:withSettings:reason:")),
                              finalReasons, scene, settings, reasonInfo)
    }

    static var lastBlockLog: TimeInterval = 0

    /// 从 scene 对象多策略提取标识（UIScene / FBScene / SBScene 均覆盖）。
    static func sceneIdentifier(of scene: AnyObject) -> String {
        for name in ["persistentIdentifier", "identifier"] {
            if let value = AevonRuntime.send(scene, Selector((name))) as? String, !value.isEmpty {
                return value
            }
        }
        if let token = AevonRuntime.send(scene, Selector(("identityToken"))),
           let value = AevonRuntime.send(token, Selector(("identifier"))) as? String, !value.isEmpty {
            return value
        }
        for ivar in ["_persistentIdentifier", "_identifier", "_sceneIdentifier", "_bundleIdentifier"] {
            if let value = AevonRuntime.ivarString(scene, ivar), !value.isEmpty { return value }
        }
        return ""
    }
}

// MARK: - FBScene：已窗口化场景强制前台

@objc final class AevonFBSceneHooks: NSObject {
    @objc func sk_fbscene_updateSettings(_ settings: Any,
                                         withTransitionContext ctx: Any?,
                                         completion: Any?) {
        AevonTrace.once("fbscene.update", "FBScene updateSettings 首次调用")
        var finalSettings: Any = settings
        let identifier = AevonFBSceneHooks.sceneIdentifier(of: self)

        if AevonForegroundManager.shared.shouldKeepForeground(identifier: identifier),
           let mutable = settings as? NSObject,
           AevonRuntime.setBool(mutable, key: "foreground", true) {
            finalSettings = mutable
        }

        // V0.0.55（AevonAdaptiveContentV55）：窗口化场景的尺寸必须一直是「窗口内容区」。
        // 系统每次推新 settings（布局更新 / 前台切换）都会把 frame 带回整屏 ——
        // 那一瞬间 App 就重排回整屏，之后我们下次请求再改小，画面会来回抖。
        // 这里在透传之前统一盖回去，语义等价于 Stheno 的
        // `setFrame:` + `updateSettings:withTransitionContext:completion:`。
        if let target = AevonSceneHelper.adaptiveFrame(for: identifier),
           let mutable = finalSettings as? NSObject,
           AevonSettingsSetFrame(mutable, CGRect(origin: .zero, size: target)) {
            finalSettings = mutable
        }

        AevonRuntime.sendVoid(self,
                           Selector(("sk_fbscene_updateSettings:withTransitionContext:completion:")),
                           finalSettings, ctx, completion)
    }

    static func sceneIdentifier(of scene: AnyObject) -> String {
        if let identifier = AevonRuntime.send(scene, Selector(("identifier"))) as? String {
            return identifier
        }
        return AevonRuntime.ivarString(scene, "_identifier") ?? ""
    }
}

// MARK: - UIMutableApplicationSceneSettings：拦截已窗口化场景的停用

@objc final class AevonSceneSettingsHooks: NSObject {
    @objc func sk_uimass_setDeactivationReasons(_ reasons: UInt64) {
        AevonTrace.once("scenesettings.deactivation", "UIMutableApplicationSceneSettings setDeactivationReasons 首次调用")
        if reasons != 0 {
            let identifier = selfIdentifier()
            if AevonForegroundManager.shared.shouldBlockDeactivation(identifier: identifier) {
                AevonLog.info("[场景] 拦截停用: \(identifier)")
                AevonRuntime.sendVoidUInt64(self, Selector(("sk_uimass_setDeactivationReasons:")), 0)
                return
            }
        }
        AevonRuntime.sendVoidUInt64(self, Selector(("sk_uimass_setDeactivationReasons:")), reasons)
    }

    private func selfIdentifier() -> String {
        for name in ["_identifier", "_sceneIdentifier", "_bundleIdentifier"] {
            if let value = AevonRuntime.ivarString(self, name) { return value }
        }
        if self.responds(to: Selector(("identifier"))),
           let value = AevonRuntime.send(self, Selector(("identifier"))) as? String {
            return value
        }
        return ""
    }
}

// MARK: - _UISceneHostingActivationStateHostComponent：已窗口化场景强制渲染

@objc final class AevonSceneHostingActivationHooks: NSObject {
    @objc func sk_shac_setForeground(_ foreground: Bool) {
        if !foreground {
            if let sceneID = hostSceneIdentifier(of: self),
               AevonForegroundManager.shared.shouldKeepForeground(identifier: sceneID) {
                AevonRuntime.sendVoidBool(self, Selector(("sk_shac_setForeground:")), true)
                return
            }
        }
        AevonRuntime.sendVoidBool(self, Selector(("sk_shac_setForeground:")), foreground)
    }

    private func hostSceneIdentifier(of component: AnyObject) -> String? {
        guard component.responds(to: Selector(("hostScene"))),
              let hostScene = AevonRuntime.send(component, Selector(("hostScene"))) else { return nil }
        if let identifier = AevonRuntime.send(hostScene, Selector(("persistentIdentifier"))) as? String {
            return identifier
        }
        if hostScene.responds(to: Selector(("identityToken"))),
           let token = AevonRuntime.send(hostScene, Selector(("identityToken"))),
           let identifier = AevonRuntime.send(token, Selector(("identifier"))) as? String {
            return identifier
        }
        return nil
    }
}

// MARK: - FBSceneLayerManager：图层变化时刷新浮窗

@objc final class AevonSceneLayerManagerHooks: NSObject {
    @objc func sk_fbslm_setLayers(_ layers: Any) {
        AevonTrace.once("layer.setLayers", "FBSceneLayerManager _setLayers 首次调用")
        AevonRuntime.sendVoid(self, Selector(("sk_fbslm_setLayers:")), layers)
        AevonWindowManager.notifyLayersUpdated()
    }
}

// MARK: - SBApplication：App 退出时清理窗口状态

@objc final class AevonSBApplicationHooks: NSObject {
    @objc func sk_sbapp_didExitWithContext(_ context: Any?) {
        AevonRuntime.sendVoid(self, Selector(("sk_sbapp_didExitWithContext:")), context)
        if self.responds(to: Selector(("bundleIdentifier"))),
           let bundleID = AevonRuntime.send(self, Selector(("bundleIdentifier"))) as? String {
            AevonWindowManager.close(bundleID: bundleID)
        }
    }
}
