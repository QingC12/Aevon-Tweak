import Foundation
import UIKit

/// FBScene 查找与场景承载（多策略，全部带运行时守卫）。
/// 参考 MilkyWayReborn 的现代 Scene 承载方案，Swift 重写。
enum AevonSceneHelper {
    // MARK: - 场景管理器

    private static func sceneManager() -> AnyObject? {
        // 策略 1：SBMainWorkspace.sharedInstance.sceneManager
        if let workspace = AevonRuntime.sendClass("SBMainWorkspace", Selector(("sharedInstance"))),
           workspace.responds(to: Selector(("sceneManager"))),
           let manager = AevonRuntime.send(workspace, Selector(("sceneManager"))) {
            return manager
        }
        // 策略 2：FBSceneManager.sharedInstance
        if let manager = AevonRuntime.sendClass("FBSceneManager", Selector(("sharedInstance"))) {
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
            if let dict = AevonRuntime.ivarObject(manager, name) as? [String: AnyObject] {
                if let scene = dict[identifier] { return scene }
                for (key, value) in dict where key.contains(identifier) { return value }
            }
        }

        // 策略 2：_workspace 子对象（iOS 15/16）
        if let workspace = AevonRuntime.ivarObject(manager, "_workspace") {
            for name in ["_allScenesByID", "_scenesByIdentifier", "_scenesByID"] {
                if let dict = AevonRuntime.ivarObject(workspace, name) as? [String: AnyObject] {
                    if let scene = dict[identifier] { return scene }
                    for (key, value) in dict where key.contains(identifier) { return value }
                }
            }
        }

        // 策略 3：allScenes（NSArray / NSSet 均可）
        if manager.responds(to: Selector(("allScenes"))),
           let collection = AevonRuntime.send(manager, Selector(("allScenes"))) {
            var scenes: [AnyObject] = []
            if let array = collection as? NSArray {
                scenes = array as? [AnyObject] ?? []
            } else if let set = collection as? NSSet {
                scenes = set.allObjects as? [AnyObject] ?? []
            }
            for scene in scenes {
                if let sid = AevonRuntime.send(scene, Selector(("identifier"))) as? String,
                   sid.contains(identifier) {
                    return scene
                }
            }
        }

        // 策略 4：深挖字典型 ivar
        if let scene = deepScan(manager, identifier: identifier) { return scene }

        // 策略 5：SBSceneManager 句柄查询
        if let identity = AevonRuntime.sendClass("SBSceneIdentityProvider",
                                              Selector(("identityForIdentifier:")),
                                              argument: identifier as NSString),
           let handle = AevonRuntime.sendClass("SBSceneManager",
                                            Selector(("existingSceneHandleForSceneIdentity:")),
                                            argument: identity),
           let scene = AevonRuntime.send(handle, Selector(("scene"))) {
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
            guard let value = AevonRuntime.ivarObject(object, String(cString: name)) else { continue }
            if let dict = value as? [String: AnyObject] {
                for (key, candidate) in dict {
                    guard key.contains(identifier) else { continue }
                    if candidate.responds(to: Selector(("layerManager"))) { return candidate }
                    if candidate.responds(to: Selector(("scene"))),
                       let scene = AevonRuntime.send(candidate, Selector(("scene"))) {
                        return scene
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 场景前台控制

    static func setForeground(_ scene: AnyObject, _ foreground: Bool) {
        guard scene.responds(to: Selector(("settings"))) else { return }
        guard let settings = AevonRuntime.send(scene, Selector(("settings"))),
              settings.responds(to: Selector(("mutableCopy"))) else { return }
        guard let mutable = AevonRuntime.sendOwned(settings, Selector(("mutableCopy"))) else { return }
        _ = AevonRuntime.setBool(mutable, key: "foreground", foreground)

        // FBScene 的两种 updateSettings 重载，按存在性选择（带类型签名直调，避开 perform 参数限制）
        if scene.responds(to: Selector(("updateSettings:withTransitionContext:completion:"))) {
            AevonRuntime.sendVoid(scene, Selector(("updateSettings:withTransitionContext:completion:")),
                               mutable, nil, nil)
        } else if scene.responds(to: Selector(("updateSettings:withTransitionContext:"))) {
            AevonRuntime.sendVoid(scene, Selector(("updateSettings:withTransitionContext:")), mutable, nil)
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

    // MARK: - 保活定时器（只在前台状态掉了时才补一次）

    private static var keepAliveTimers: [String: DispatchSourceTimer] = [:]

    static func startKeepAlive(_ bundleID: String) {
        stopKeepAlive(bundleID)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
        timer.setEventHandler {
            guard let scene = self.scene(for: bundleID) else { return }
            // 先看场景当前的前台标记：已经是前台就什么都不做。
            // 以前每秒无条件 setForeground 一次，等于每秒一次跨进程状态写入，
            // 在缩放这种主线程密集的场景里是白花掉的开销。
            let settings = AevonRuntime.send(scene, Selector(("settings")))
            if let foreground = settings.flatMap({ AevonRuntime.bool($0, key: "foreground") }),
               foreground {
                return
            }
            self.setForeground(scene, true)
        }
        timer.resume()
        keepAliveTimers[bundleID] = timer
        AevonLog.info("[保活] 已为 \(bundleID) 启动前台保持定时器")
    }

    static func stopKeepAlive(_ bundleID: String) {
        if let timer = keepAliveTimers.removeValue(forKey: bundleID) {
            timer.cancel()
        }
    }

    // MARK: - 自适应场景尺寸（V0.0.55，AevonAdaptiveContentV55）

    /// 场景标识 → 目标尺寸。由 `AevonSceneHost.updateAdaptiveSize` 写入，
    /// `AevonFBSceneHooks` 在系统推送新 settings 时按它把 frame 顶回去
    /// （否则 SpringBoard 一次布局更新就会把场景重置回整屏）。
    private static var adaptiveFrames: [String: CGSize] = [:]

    static func applyAdaptiveFrame(scene: AnyObject, sceneID: String, size: CGSize) -> Bool {
        guard !sceneID.isEmpty, size.width > 1, size.height > 1 else { return false }
        let ok = AevonSceneSetFrameSize(scene, size)
        if ok {
            adaptiveFrames[sceneID] = size
        }
        return ok
    }

    static func restoreSceneFrame(scene: AnyObject, sceneID: String) {
        if !sceneID.isEmpty { adaptiveFrames.removeValue(forKey: sceneID) }
        _ = AevonSceneSetFrameSize(scene, UIScreen.main.bounds.size)
    }

    /// 按场景标识查目标尺寸（identifier 各系统版本前缀不同，做双向包含匹配）。
    static func adaptiveFrame(for identifier: String) -> CGSize? {
        guard !identifier.isEmpty else { return nil }
        if let exact = adaptiveFrames[identifier] { return exact }
        for (key, value) in adaptiveFrames
        where identifier.contains(key) || key.contains(identifier) {
            return value
        }
        return nil
    }
}
