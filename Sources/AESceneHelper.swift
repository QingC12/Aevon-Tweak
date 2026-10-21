import Foundation
import UIKit

/// FBScene 查找与场景承载（多策略，全部带运行时守卫）。
/// 参考 MilkyWayReborn 的现代 Scene 承载方案，Swift 重写。
enum AESceneHelper {
    // MARK: - 场景管理器

    private static func sceneManager() -> AnyObject? {
        // 策略 1：SBMainWorkspace.sharedInstance.sceneManager
        if let workspace = AERuntime.sendClass("SBMainWorkspace", Selector(("sharedInstance"))),
           workspace.responds(to: Selector(("sceneManager"))),
           let manager = AERuntime.send(workspace, Selector(("sceneManager"))) {
            return manager
        }
        // 策略 2：FBSceneManager.sharedInstance
        if let manager = AERuntime.sendClass("FBSceneManager", Selector(("sharedInstance"))) {
            return manager
        }
        return nil
    }

    // MARK: - 查找 FBScene

    static func scene(for identifier: String) -> AnyObject? {
        guard !identifier.isEmpty else { return nil }
        guard let manager = sceneManager() else { return nil }

        // 策略 1：管理器自身的场景字典
        for name in ["_scenesByID", "_scenes"] {
            if let dict = AERuntime.ivarObject(manager, name) as? [String: AnyObject] {
                if let scene = dict[identifier] { return scene }
                for (key, value) in dict where key.contains(identifier) { return value }
            }
        }

        // 策略 2：_workspace 子对象（iOS 15/16）
        if let workspace = AERuntime.ivarObject(manager, "_workspace") {
            for name in ["_allScenesByID", "_scenesByIdentifier", "_scenesByID"] {
                if let dict = AERuntime.ivarObject(workspace, name) as? [String: AnyObject] {
                    if let scene = dict[identifier] { return scene }
                    for (key, value) in dict where key.contains(identifier) { return value }
                }
            }
        }

        // 策略 3：allScenes（NSArray / NSSet 均可）
        if manager.responds(to: Selector(("allScenes"))),
           let collection = AERuntime.send(manager, Selector(("allScenes"))) {
            var scenes: [AnyObject] = []
            if let array = collection as? NSArray {
                scenes = array as? [AnyObject] ?? []
            } else if let set = collection as? NSSet {
                scenes = set.allObjects as? [AnyObject] ?? []
            }
            for scene in scenes {
                if let sid = AERuntime.send(scene, Selector(("identifier"))) as? String,
                   sid.contains(identifier) {
                    return scene
                }
            }
        }

        // 策略 4：深挖字典型 ivar
        if let scene = deepScan(manager, identifier: identifier) { return scene }

        // 策略 5：SBSceneManager 句柄查询
        if let identity = AERuntime.sendClass("SBSceneIdentityProvider",
                                              Selector(("identityForIdentifier:")),
                                              argument: identifier as NSString),
           let handle = AERuntime.sendClass("SBSceneManager",
                                            Selector(("existingSceneHandleForSceneIdentity:")),
                                            argument: identity),
           let scene = AERuntime.send(handle, Selector(("scene"))) {
            return scene
        }

        return nil
    }

    private static func deepScan(_ object: AnyObject, identifier: String) -> AnyObject? {
        guard let cls = object_getClass(object) else { return nil }
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(cls, &count) else { return nil }
        defer { free(ivars) }
        for index in 0..<Int(count) {
            let ivar = ivars[index]
            guard let encoding = ivar_getTypeEncoding(ivar) else { continue }
            guard String(cString: encoding).hasPrefix("@") else { continue }
            guard let name = ivar_getName(ivar) else { continue }
            guard let value = AERuntime.ivarObject(object, String(cString: name)) else { continue }
            if let dict = value as? [String: AnyObject] {
                for (key, candidate) in dict {
                    guard key.contains(identifier) else { continue }
                    if candidate.responds(to: Selector(("layerManager"))) { return candidate }
                    if candidate.responds(to: Selector(("scene"))),
                       let scene = AERuntime.send(candidate, Selector(("scene"))) {
                        return scene
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 场景承载视图

    /// 用 _UISceneLayerHostContainerView 承载场景（iOS 15–26）。
    static func hostingView(for scene: AnyObject) -> UIView? {
        guard let allocated = AERuntime.allocate("_UISceneLayerHostContainerView") else {
            AELog.warn("[场景] _UISceneLayerHostContainerView 不存在")
            return nil
        }

        let container: AnyObject?
        if allocated.responds(to: Selector(("initWithScene:debugDescription:"))) {
            container = AERuntime.sendInit(allocated, Selector(("initWithScene:debugDescription:")),
                                           first: scene, second: "Aevon" as NSString)
        } else if allocated.responds(to: Selector(("initWithScene:"))) {
            container = AERuntime.sendInit(allocated, Selector(("initWithScene:")), argument: scene)
        } else {
            container = nil
        }

        guard let view = container as? UIView else {
            AELog.warn("[场景] 无法创建 _UISceneLayerHostContainerView")
            return nil
        }

        // iOS 15/16：为场景的每个 layer 手动创建 host view
        if let containerScene = AERuntime.send(view, Selector(("scene"))),
           containerScene.responds(to: Selector(("layerManager"))),
           let layerManager = AERuntime.send(containerScene, Selector(("layerManager"))),
           layerManager.responds(to: Selector(("layers"))),
           let layers = AERuntime.send(layerManager, Selector(("layers"))) as? [AnyObject] {
            for layer in layers {
                if view.responds(to: Selector(("_createHostViewForLayer:"))),
                   let hostView = AERuntime.send(view, Selector(("_createHostViewForLayer:")),
                                                 argument: layer) as? UIView {
                    hostView.frame = view.bounds
                    view.addSubview(hostView)
                }
            }
        }

        view.frame = UIScreen.main.bounds
        return view
    }

    // MARK: - 场景前台控制

    static func setForeground(_ scene: AnyObject, _ foreground: Bool) {
        guard scene.responds(to: Selector(("settings"))) else { return }
        guard let settings = AERuntime.send(scene, Selector(("settings"))),
              settings.responds(to: Selector(("mutableCopy"))) else { return }
        guard let mutable = AERuntime.sendOwned(settings, Selector(("mutableCopy"))) else { return }
        _ = AERuntime.setBool(mutable, key: "foreground", foreground)

        // FBScene 的两种 updateSettings 重载，按存在性选择（带类型签名直调，避开 perform 参数限制）
        if scene.responds(to: Selector(("updateSettings:withTransitionContext:completion:"))) {
            AERuntime.sendVoid(scene, Selector(("updateSettings:withTransitionContext:completion:")),
                               mutable, nil, nil)
        } else if scene.responds(to: Selector(("updateSettings:withTransitionContext:"))) {
            AERuntime.sendVoid(scene, Selector(("updateSettings:withTransitionContext:")), mutable, nil)
        }
    }

    static func wakeUp(_ bundleID: String) {
        guard let scene = scene(for: bundleID) else { return }
        setForeground(scene, true)
    }

    static func sleep(_ bundleID: String) {
        guard let scene = scene(for: bundleID) else { return }
        setForeground(scene, false)
    }

    // MARK: - 保活定时器（每秒把场景推回前台）

    private static var keepAliveTimers: [String: DispatchSourceTimer] = [:]

    static func startKeepAlive(_ bundleID: String) {
        stopKeepAlive(bundleID)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
        timer.setEventHandler {
            guard let scene = self.scene(for: bundleID) else { return }
            self.setForeground(scene, true)
        }
        timer.resume()
        keepAliveTimers[bundleID] = timer
        AELog.info("[保活] 已为 \(bundleID) 启动前台保持定时器")
    }

    static func stopKeepAlive(_ bundleID: String) {
        if let timer = keepAliveTimers.removeValue(forKey: bundleID) {
            timer.cancel()
        }
    }
}
