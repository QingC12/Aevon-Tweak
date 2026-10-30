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

    // MARK: - 自建场景登记（V0.2.32，AevonSelfSceneFGV232）

    /// bundleID → 自建场景（开窗登记、关窗注销）。
    /// 保活/重申前台必须打在**自建场景**上：scene(for:) 永远排除自建场景，
    /// 0.2.31 的保活 8 次全打在主场景上 = 和自建场景抢 App 端 activation。
    private static var selfSceneRegistry: [String: AnyObject] = [:]

    static func registerSelfScene(_ bundleID: String, _ scene: AnyObject) {
        selfSceneRegistry[bundleID] = scene
    }

    static func unregisterSelfScene(_ bundleID: String) {
        selfSceneRegistry.removeValue(forKey: bundleID)
    }

    static func selfScene(for bundleID: String) -> AnyObject? {
        return selfSceneRegistry[bundleID]
    }

    // MARK: - 场景前台控制

    /// 写场景前台标记。
    ///
    /// V0.2.79（AevonSettingsChannelV279 / AevonSceneLedgerV279，路线 C「抄记账体系」）：
    /// **所有 foreground 写入统一收口到这里 → 单飞通道 → 账本判定**。
    /// 以前每个调用点各写各的（开窗、切屏、保活、回桌面），同一拍可能连写 2~3 笔；
    /// 每写一笔都让远程表面重建一次 = 用户看到的一次闪。现在：
    ///   · 账本说「账面已经是这个值」→ 根本不写；
    ///   · 同一场景上一笔还没回来 → 合并成一笔 pending，不并发写。
    /// force = 绕过账本强制写一笔。只有「补救路径」（看门重申 / 定格自愈）该用 true；
    /// 平时一律 false，否则账本省下的重提交白省（0.2.79 的收益会全丢）。
    static func setForeground(_ scene: AnyObject, _ foreground: Bool, reason: String = "场景前台",
                              force: Bool = false) {
        guard scene.responds(to: Selector(("settings"))) else { return }

        // 拿 sceneIdentifier 反查账页；查不到（没开账）就按 identifier 单独记一页
        var bundleID = ""
        if let identifier = AevonRuntime.send(scene, Selector(("identifier"))) as? String,
           !identifier.isEmpty {
            bundleID = AevonSceneLedger.shared.bookID(matching: identifier) ?? identifier
        }
        if bundleID.isEmpty {
            directWrite(scene, foreground)
            return
        }
        AevonSettingsChannel.shared.request(bundleID: bundleID, scene: scene,
                                            foreground: foreground, reason: reason, force: force)
    }

    /// 老路直写：只在拿不到场景标识时兜底用（不能因为记账出问题就完全不写）。
    private static func directWrite(_ scene: AnyObject, _ foreground: Bool) {
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
        setForeground(scene, true, reason: "唤醒 \(bundleID)")
    }

    static func sleep(_ bundleID: String) {
        guard let scene = scene(for: bundleID) else { return }
        setForeground(scene, false, reason: "挂起 \(bundleID)")
    }

    // MARK: - 保活定时器（V0.1.5：有限次，只补开窗后的头几秒）

    private static var keepAliveTimers: [String: DispatchSourceTimer] = [:]

    /// 开窗后补前台。
    ///
    /// V0.1.5（AevonSoftKeepAliveV105）：以前是**每秒一次、永远不停**地检查并补写
    /// `updateSettings(foreground=true)` —— 那是持续往 FrontBoard 的场景状态机里写东西，
    /// 归档(14) 的 SIGTRAP 就出在这条写入链上。现在只补开窗后的头 8 次（约 6 秒），
    /// 够撑过 presenter 激活那段；之后进程存活交给 RBSAssertion 保活，不再碰场景设置。
    ///
    /// V0.2.32（AevonSelfSceneFGV232，0.2.31 真机实锤）：自建场景模式下补前台目标
    /// 改为**自建场景**（原来 8 次全打主场景 = 与自建场景抢 activation），且自建场景
    /// 用重申写入（foreground=YES + deactivationReasons=0，LiveContainer #942 同款，
    /// 对抗 FBSSceneObserver 的 resignActive / SB 重算）。主场景补写保持原样不升级
    /// ——主场景的 deactivation 状态机绝不碰（归档(14) SIGTRAP 教训）。
    static func startKeepAlive(_ bundleID: String) {
        stopKeepAlive(bundleID)
        var remaining = 8
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.8)
            timer.setEventHandler {
                guard remaining > 0 else {
                    self.stopKeepAlive(bundleID)
                    let ledger = AevonSceneLedger.shared.summaryIfDue(force: true) ?? "-"
                    AevonLog.info("[保活] \(bundleID) 前台补偿结束（共 8 次，之后不再写场景设置）"
                        + " 账本[\(ledger)] 通道[\(AevonSettingsChannel.shared.summary())]"
                        + "（AevonSoftKeepAliveV105 AevonSettingsChannelV279）")
                    return
                }
                remaining -= 1
                // 自建场景优先；没有自建场景（0.2.27 全屏接管形态）保持主场景原逻辑
                if let selfScene = self.selfScene(for: bundleID) {
                    let ok = AevonSelfSceneReassertForeground(selfScene)
                    if !ok {
                        AevonLog.warn("[保活] 自建场景重申前台失败（\(bundleID)）（AevonSelfSceneFGV232）")
                    }
                    return
                }
                guard let scene = self.scene(for: bundleID) else { return }
                // V0.2.79：不再自己判断「已经是前台就跳过」—— 这层判断已经下沉到账本，
                // 而且账本比它多知道「系统把值改回去了」这件事（读实时值 + 上一笔账面双路）。
                self.setForeground(scene, true, reason: "保活补前台")
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

/// V0.3.24（AevonSceneOwnedV324）：**同一 FBScene 在本进程只允许一个呈现者**。
///
/// 用户 Aevon(98) #3「主悬浮窗有概率黑屏，并且同时出现两个黑屏的主悬浮窗」的结构成因：
/// 两次开窗交错时，两扇 AevonWindowView 各自持一个 `AevonSceneHost`，而 `AevonSceneHost.init`
/// 只用 UUID 保证 presenter 标识唯一，**从不检查这个场景是否已经被另一扇窗占着**。
/// 两个 presenter 去呈现同一个 FBScene，结果是谁都拿不到远程层 —— 两扇一起黑。
///
/// Stheno 对照（SCFloatingSceneManager）：`__sessionsByBundleID` / `__hostingScenePointers`
/// / `__hostingSceneIdentifiers` / `__hostingBundleIdentifiers` 四张表，配
/// `sc_sessionForBundleIdentifier:` / `sc_isHostingSceneIdentifier:`。它的「一个场景一个会话」
/// 是**表约束**，不是时序运气。
///
/// 这里做最小等价物：按 sceneID 登记占用者令牌。已被占用 → 拒绝创建（fail-closed，
/// 上层走「复用现有窗」而不是新建），从结构上堵死双黑。
///
/// 失效保护：占用记录带续期时间戳，`AevonSceneHost` 每 0.5s 探测时续期一次；
/// 超过 30s 没续期视为旧主已死（进程内异常路径未走 invalidate），可被接管 ——
/// 宁可偶发接管，也不能让某个 App 因为一次漏注销永远开不了窗。
enum AevonSceneOwnership {
    private final class Entry {
        let token: UUID
        let bundleID: String
        var renewedAt: CFTimeInterval
        init(token: UUID, bundleID: String, renewedAt: CFTimeInterval) {
            self.token = token
            self.bundleID = bundleID
            self.renewedAt = renewedAt
        }
    }

    private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()
    /// 超过这么久没续期 → 视为旧主已死，可接管
    private static let staleAfter: CFTimeInterval = 30

    /// 申请占用。返回 false = 该场景正在被另一扇窗呈现（调用方应放弃新建）。
    static func claim(sceneID: String, bundleID: String) -> UUID? {
        guard !sceneID.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        if let existing = entries[sceneID], now - existing.renewedAt < staleAfter {
            AevonLog.warn("[场景] 场景 \(sceneID) 已被 \(existing.bundleID) 占用 → 拒绝第二扇窗"
                + "（请求方 \(bundleID)）（AevonSceneOwnedV324）")
            return nil
        }
        if entries[sceneID] != nil {
            AevonLog.warn("[场景] 场景 \(sceneID) 的旧占用已 \(Int(now - (entries[sceneID]?.renewedAt ?? now)))s "
                + "未续期 → 判失效，由 \(bundleID) 接管（AevonSceneOwnedV324）")
        }
        let token = UUID()
        entries[sceneID] = Entry(token: token, bundleID: bundleID, renewedAt: now)
        return token
    }

    /// 续期（由 AevonSceneHost 的 0.5s 探测循环调用）。
    static func renew(sceneID: String, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[sceneID], entry.token == token else { return }
        entry.renewedAt = CACurrentMediaTime()
    }

    /// 注销（invalidate / deinit）。
    static func release(sceneID: String, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[sceneID], entry.token == token else { return }
        entries.removeValue(forKey: sceneID)
        AevonLog.info("[场景] 场景 \(sceneID) 占用已释放（\(entry.bundleID)）（AevonSceneOwnedV324）")
    }

    /// 诊断串（窗口栈 / 取证用）。
    static func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        if entries.isEmpty { return "无占用" }
        return entries.map { "\($0.key)=\($0.value.bundleID)" }.sorted().joined(separator: ",")
    }
}
