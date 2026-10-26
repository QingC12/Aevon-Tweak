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

    /// V0.2.28（AevonSelfSceneV228）：自建场景的标识前缀。
    /// `scene(for:)` **永不返回**自建场景 —— 保活 / 前台控制 / 回退必须始终作用在
    /// 主场景上；自建场景由 AevonSceneDriverShim 创建、承载器直接持有引用，
    /// 它的标识里含 bundleID，不加排除的话 `contains` 匹配会把它误当成主场景。
    static let selfScenePrefix = "sceneID:com.aevon.float-"

    static func isSelfSceneIdentifier(_ sid: String) -> Bool {
        sid.hasPrefix(selfScenePrefix)
    }

    private static func isSelfScene(_ scene: AnyObject) -> Bool {
        if let sid = AevonRuntime.send(scene, Selector(("identifier"))) as? String,
           isSelfSceneIdentifier(sid) { return true }
        return false
    }

    static func scene(for identifier: String) -> AnyObject? {
        guard !identifier.isEmpty else { return nil }
        guard let manager = sceneManager() else { return nil }

        // 策略 1：管理器自身的场景字典
        for name in ["_scenesByID", "_scenes"] {
            if let dict = AevonRuntime.ivarObject(manager, name) as? [String: AnyObject] {
                if let scene = dict[identifier], !isSelfScene(scene) { return scene }
                for (key, value) in dict where key.contains(identifier) {
                    if !isSelfScene(value) { return value }
                }
            }
        }

        // 策略 2：_workspace 子对象（iOS 15/16）
        if let workspace = AevonRuntime.ivarObject(manager, "_workspace") {
            for name in ["_allScenesByID", "_scenesByIdentifier", "_scenesByID"] {
                if let dict = AevonRuntime.ivarObject(workspace, name) as? [String: AnyObject] {
                    if let scene = dict[identifier], !isSelfScene(scene) { return scene }
                    for (key, value) in dict where key.contains(identifier) {
                        if !isSelfScene(value) { return value }
                    }
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
                if isSelfScene(scene) { continue }
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
                    if isSelfScene(candidate) { continue }
                    if candidate.responds(to: Selector(("layerManager"))) { return candidate }
                    if candidate.responds(to: Selector(("scene"))),
                       let scene = AevonRuntime.send(candidate, Selector(("scene"))) {
                        if isSelfScene(scene) { continue }
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

    // MARK: - 保活定时器（V0.1.5：有限次，只补开窗后的头几秒）

    private static var keepAliveTimers: [String: DispatchSourceTimer] = [:]

    /// 开窗后补前台。
    ///
    /// V0.1.5（AevonSoftKeepAliveV105）：以前是**每秒一次、永远不停**地检查并补写
    /// `updateSettings(foreground=true)` —— 那是持续往 FrontBoard 的场景状态机里写东西，
    /// 归档(14) 的 SIGTRAP 就出在这条写入链上。现在只补开窗后的头 8 次（约 6 秒），
    /// 够撑过 presenter 激活那段；之后进程存活交给 RBSAssertion 保活，不再碰场景设置。
    static func startKeepAlive(_ bundleID: String) {
        stopKeepAlive(bundleID)
        var remaining = 8
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.8)
        timer.setEventHandler {
            guard remaining > 0 else {
                self.stopKeepAlive(bundleID)
                AevonLog.info("[保活] \(bundleID) 前台补偿结束（共 8 次，之后不再写场景设置）（AevonSoftKeepAliveV105）")
                return
            }
            remaining -= 1
            guard let scene = self.scene(for: bundleID) else { return }
            // 先看场景当前的前台标记：已经是前台就什么都不做。
            let settings = AevonRuntime.send(scene, Selector(("settings")))
            if let foreground = settings.flatMap({ AevonRuntime.bool($0, key: "foreground") }),
               foreground {
                return
            }
            self.setForeground(scene, true)
        }
        timer.resume()
        keepAliveTimers[bundleID] = timer
        AevonLog.info("[保活] 已为 \(bundleID) 启动前台补偿定时器（最多 8 次）（AevonSoftKeepAliveV105）")
    }

    static func stopKeepAlive(_ bundleID: String) {
        if let timer = keepAliveTimers.removeValue(forKey: bundleID) {
            timer.cancel()
        }
    }
}
