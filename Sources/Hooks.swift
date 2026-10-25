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

// MARK: - 场景停用门控（V0.1.3 整体移除，AevonGateRemovedV103）
//
// 归档(12)/归档(13) 两次真机实锤：这个门控是「安全模式 / 自动注销」的唯一来源。
//   0.1.0：浮窗开着设置 → 桌面点设置图标 → 记「已拦截场景停用(com.apple.Preferences-default)」
//          → 0.24 秒后 SpringBoard 重启；崩溃栈 = 我们的 hook → Foundation → FBS → SIGTRAP。
//   0.1.2：同一路径加上 ObjC 异常保护（AevonTryExecute）后**依旧崩溃** —— 说明炸点不在
//          「我们调用原始实现」这一步，而在「我们把停用原因清零之后 FBS 自己的状态机断言」，
//          SIGTRAP 是陷阱不是 NSException，@try 天生捕不到。
//
// 结论：这不是可以靠加保护修好的 bug，而是这条路本身走不通 —— 拦截系统的场景停用状态机
// 会与 FrontBoard 的内部不变量冲突。停止拦截，回到「让系统按它自己的规则跑」。
// 历史上加它的理由是「全屏 App 前台时浮窗里的场景被停用、点不动」，那条需求改由
// 下面两个只改「前台标记」、不碰停用原因的安全 hook 承担（force foreground +
// 宿主激活状态），它们不参与 deactivation 状态机，因此不会引发断言。
//
// 历史 CI 校验串（AevonDeactivationGateV37）由 AevonAssertionShim.m 的 used 常量收容，
// 二进制里仍能查到，但运行期已无任何代码路径。

// MARK: - FBScene：已窗口化场景强制前台

@objc final class AevonFBSceneHooks: NSObject {
    @objc func sk_fbscene_updateSettings(_ settings: Any,
                                         withTransitionContext ctx: Any?,
                                         completion: Any?) {
        AevonTrace.once("fbscene.update", "FBScene updateSettings 首次调用")
        var finalSettings: Any = settings
        let identifier = AevonFBSceneHooks.sceneIdentifier(of: self)

        /*
         * V0.1.4（AevonIconLaunchV104）：这里原来无条件「把 settings 换成自己的
         * mutableCopy 再写 foreground=true」。归档(12)/(13) 与 Aevon(72) 的崩溃栈
         * 指向的就是这一步：FrontBoard 调进来 → 我们的 hook → Foundation（KVC 写属性）
         * → FrontBoardServices 内部断言（SIGTRAP，@try 兜不住）。
         *
         * 现在的三条约束，任何一条不满足就**原样透传原始对象**：
         *   ① 交接期（用户点了桌面图标要把这个 App 全屏拉起）一律不碰；
         *   ② 系统这次本来就给的是 foreground=true —— 我们没有任何要改的，不换对象；
         *   ③ 只有「登记在册 + 当前是 false」才补一次 true。
         * 换成别的对象交给 FrontBoard 本身就有风险（它可能按对象身份/内部 diff 判状态），
         * 能不换就不换。
         */
        if let settingsObject = settings as? NSObject,
           AevonForegroundManager.shared.shouldKeepForeground(identifier: identifier),
           AevonRuntime.bool(settingsObject, key: "foreground") != true,
           AevonRuntime.setBool(settingsObject, key: "foreground", true) {
            finalSettings = settingsObject
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

// MARK: - UIMutableApplicationSceneSettings：旧路径停用拦截（V0.1.3 移除）
//
// 与上面同一个理由：任何「把停用原因清零」的拦截都在跟 FrontBoard 的状态机对赌，
// iOS 17.3 上赌输的代价是 SpringBoard 断言崩溃（安全模式）。
// 这条旧路径在真机上从未真正命中过（日志里零 [场景] 拦截停用），一并删除，
// 避免以后被误当成可用开关重新启用。

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

// MARK: - 桌面图标启动：先把浮窗交还给系统（V0.1.4，AevonIconLaunchV104）
//
// 归档(12)(13) + Aevon(72) 三次实锤的现场：「浮窗里开着设置 → 回桌面点设置图标 →
// 自动注销（SIGTRAP）」。崩溃栈是 FrontBoard → 我们的 FBScene hook → Foundation(KVC)
// → FrontBoardServices 断言 —— 也就是**同一个场景**正被 FrontBoard 全屏拉起时，
// 我们还握着它的 presenter 并往里写 foreground。
//
// 唯一稳的解法是「在系统接手之前先松手」：图标被点的那一刻把同 bundle 的浮窗释放掉
// （摘 presenter、停前台保持、登记 5 秒交接期，期间连 foreground 都不再写），
// 之后全屏启动完全是系统自己的路径，我们零参与。
//
// Stheno 逆向里同样有 `iconManager:launchIconForIconView:withActions:` 这个选择子
// （见 Stheno.dylib 的 objc 选择子表），说明这条路在 iOS 17 上是通的。
@objc final class AevonIconLaunchHooks: NSObject {
    @objc func sk_sbic_launchIcon(_ manager: Any?,
                                  forIconView iconView: Any?,
                                  withActions actions: Any?) {
        if let bundleID = AevonIconLaunchHooks.bundleID(fromIconView: iconView),
           AevonWindowManager.isWindowed(bundleID) {
            AevonWindowManager.releaseForFullscreenLaunch(bundleID: bundleID)
        }
        AevonRuntime.sendVoid(self,
                              Selector(("sk_sbic_launchIcon:forIconView:withActions:")),
                              manager, iconView, actions)
    }

    /// 从 SBIconView 上取 bundleID（多条兜底链路，任一命中即返回）。
    static func bundleID(fromIconView iconView: Any?) -> String? {
        guard let view = iconView as? NSObject else { return nil }
        var nodes: [NSObject] = [view]
        for key in ["icon", "node"] {
            if let child = AevonRuntime.send(view, Selector(key)) as? NSObject {
                nodes.append(child)
            }
        }
        for node in nodes {
            for key in ["applicationBundleIdentifier", "bundleIdentifier"] {
                if let value = AevonRuntime.send(node, Selector(key)) as? String, !value.isEmpty {
                    return value
                }
            }
            if let inner = AevonRuntime.send(node, Selector("node")) as? NSObject,
               inner !== node {
                for key in ["applicationBundleIdentifier", "bundleIdentifier"] {
                    if let value = AevonRuntime.send(inner, Selector(key)) as? String, !value.isEmpty {
                        return value
                    }
                }
            }
        }
        return nil
    }
}
