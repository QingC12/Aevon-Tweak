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

    /// 读场景当前的前台标记（V0.0.80，AevonFrontHealV80）。
    /// 返回 nil = 读不到（场景没有 settings / 没有 foreground 键），调用方不要据此做判断。
    static func isForeground(_ scene: AnyObject) -> Bool? {
        guard scene.responds(to: Selector(("settings"))) else { return nil }
        guard let settings = AevonRuntime.send(scene, Selector(("settings"))) else { return nil }
        return AevonRuntime.bool(settings, key: "foreground")
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

    // MARK: - 整窗触摸门（V0.0.81，AevonAppGateV81）

    /// 当前处于「关门」状态的 App（用来在关窗 / 看门狗里确保复位）。
    private static var gatedBundles: Set<String> = []

    /// 开关某个 App 的整窗触摸门。
    ///
    /// 为什么不再按坐标判：Aevon(73) 日志里，同一次轻点 SB 记 384,174、Guard 记
    /// 218,295，下一次 375,186 → 184,476，再下一次 197,680 → 235,768 —— App 进程
    /// 拿到的坐标会乱跳，停靠格 / 主窗矩形 / 热区判据必然漏。这里改成一个
    /// **持续状态**：门关着 = 该 App 进程丢弃所有触摸，与手指在哪无关，
    /// 也不存在「began 那一帧还没读到状态」的竞态（状态在停靠/还原那一刻就变了）。
    static func setAppGate(_ bundleID: String, blocked: Bool, reason: String) {
        guard !bundleID.isEmpty else { return }
        let changed: Bool
        if blocked {
            changed = gatedBundles.insert(bundleID).inserted
        } else {
            changed = gatedBundles.remove(bundleID) != nil
        }
        AevonNotifySetAppGate(bundleID, blocked ? 1 : 0)
        if changed {
            AevonLog.info("[窗口] 整窗触摸门"
                + (blocked
                   ? "关闭 —— 该 App 这段时间收不到任何触摸（\(reason)）"
                   : "打开 —— App 恢复正常触摸（\(reason)）")
                + "：\(bundleID)（AevonAppGateV81）")
        }
    }

    /// 兜底：没有浮窗的 App 不该被关着门（关窗异常 / 崩溃后残留都要能自愈）。
    static func clearStaleAppGates() {
        guard !gatedBundles.isEmpty else { return }
        for bid in Array(gatedBundles) where !AevonWindowManager.isWindowed(bid) {
            gatedBundles.remove(bid)
            AevonNotifySetAppGate(bid, 0)
            AevonLog.warn("[窗口] 整窗触摸门残留已复位：\(bid)（已经没有浮窗了，恢复 App 正常触摸）"
                + "（AevonAppGateV81）")
        }
    }

    // MARK: - 真 resize（V0.0.59，AevonTrueResizeV59）

    /// 场景标识 → 目标尺寸。由 `AevonSceneHost` 写入，
    /// `AevonFBSceneHooks` 在系统推送新 settings 时按它把 frame 顶回去
    /// （否则 SpringBoard 一次布局更新就会把场景重置回整屏）。
    private static var adaptiveFrames: [String: CGSize] = [:]

    /// 把场景改成指定逻辑尺寸（帧 + displayConfiguration 一起下发）。
    ///
    /// V0.0.55 的教训：只写 frame 只会裁渲染视口（App 的 UIWindow 仍整屏，
    /// 内容照旧按整屏排版 → 字变大右边被切）。V0.0.59 按 Mango 实证补上
    /// displayConfiguration 与 `setResizesHostedContext:` 三路杠杆，
    /// 结果位掩码原样落日志 —— 真机日志能直接看出哪一路生效（AevonTrueResizeV59）。
    @discardableResult
    static func applyDisplaySize(scene: AnyObject, sceneID: String, size: CGSize,
                                 floatMode: Bool) -> Int {
        guard !sceneID.isEmpty, size.width > 1, size.height > 1 else { return 0 }
        let bits32 = AevonSceneApplyDisplaySize(scene, size, floatMode)
        let bits = Int(bits32)
        // V0.0.60（AevonReflowGateV60）记录条件收紧：displayConfiguration 真正
        // 写进 settings 并下发（0x10）才记 —— 写不进时垫片整单放弃（不写 frame
        // 不推 diff），FBScene 钩子绝不顶回小窗 frame（那正是「内容放大 + 显示
        // 不全」的 V55 裁视口症状）。此时场景保持整屏，走 V58 等比缩放回退。
        if bits & 0x10 != 0 {
            adaptiveFrames[sceneID] = size
        } else {
            adaptiveFrames.removeValue(forKey: sceneID)
        }
        return bits
    }

    /// 最近一次 displayConfiguration 诊断（类名 + 能力表，垫片侧记录）。
    static func displayConfigDiag() -> String {
        String(cString: AevonDisplayConfigDiag())
    }

    /// V0.0.64：scene 方法表诊断（host/Context/resize 选择子 + context 取值类名，
    /// 垫片侧只 dump 一次）——下一版找 `setResizesHostedContext:` 正确调用对象用。
    static func sceneMethodDiag() -> String {
        String(cString: AevonSceneMethodDiag())
    }

    /// 位掩码 → 人话（真机日志可读）。
    static func describeApplyBits(_ bits: Int, target: CGSize) -> String {
        guard bits != 0 else { return "完全失败（settings 不可写）" }
        var parts: [String] = []
        if bits & 0x1 != 0 { parts.append("帧已写") }
        if bits & 0x2 != 0 { parts.append("旧显示配置在场") }
        if bits & 0x4 != 0 { parts.append("显示配置尺寸已改(size)") }
        if bits & 0x8 != 0 { parts.append("显示配置尺寸已改(sizeInPoints)") }
        if bits & 0x10 != 0 { parts.append("显示配置已随帧下发") }
        if bits & 0x20 != 0 { parts.append("托管上下文可resize已开") }
        if bits & 0x40 != 0 { parts.append("diff通道已推") } else { parts.append("diff通道不可用") }
        if bits & 0x80 != 0 { parts.append("回读一致") } else { parts.append("回读不一致") }
        // V0.0.60：写入策略（哪条路把尺寸写进去的）
        if bits & 0x100 != 0 { parts.append("策略=拷贝旧配置") }
        if bits & 0x200 != 0 { parts.append("策略=原对象直写") }
        if bits & 0x400 != 0 { parts.append("策略=新建配置") }
        if bits & 0x800 != 0 { parts.append("策略=ivar内存直写") }
        return "目标 \(Int(target.width))x\(Int(target.height))：\(parts.joined(separator: "·"))"
    }

    static func restoreSceneFrame(scene: AnyObject, sceneID: String) {
        if !sceneID.isEmpty { adaptiveFrames.removeValue(forKey: sceneID) }
        // V0.0.59：还原也带 displayConfiguration（floatMode=false 不再开 resize 开关）
        _ = AevonSceneApplyDisplaySize(scene, UIScreen.main.bounds.size, false)
        AevonLog.info("[场景] 场景几何已还原整屏（帧+显示配置一起下发，AevonTrueResizeV59）")
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
