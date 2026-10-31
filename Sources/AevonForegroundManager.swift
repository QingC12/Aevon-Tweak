import Foundation
import QuartzCore

/// 前台保活管理：登记用户主动窗口化的 App / 场景。
/// 只有登记在册的场景才会被 hook 强制前台或拦截停用；
/// 未开窗时集合为空，hook 行为与原生生系统完全一致。
final class AevonForegroundManager {
    static let shared = AevonForegroundManager()
    private init() {}

    private let lock = NSLock()
    private var bundleIDs = Set<String>()
    private var sceneIDs = Set<String>()

    /// V0.1.4（AevonIconLaunchV104）：转正交接期。
    ///
    /// 场景：浮窗里开着某个 App，用户回到桌面点了它的图标 → 系统要把同一个场景
    /// 全屏拉起。这一小段时间里如果还继续替这个场景写 `foreground=true`，
    /// 就是在跟 FrontBoard 的激活状态机抢同一份 settings（归档(12)/(13) 的
    /// SIGTRAP 就是这类冲突）。所以「图标被点」那一刻先登记交接，交接期内
    /// 一律不再替它写前台标记；窗口本身也已经在这一刻释放掉了。
    private var handoff: [String: CFTimeInterval] = [:]
    private static let handoffWindow: CFTimeInterval = 5.0

    func beginFullscreenHandoff(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        handoff[bundleID] = CACurrentMediaTime() + AevonForegroundManager.handoffWindow
        /* V0.3.42（AevonWriteGuardV342）：转正交接期**必须**把拦写一起撤掉。
         * 这一小段是 FrontBoard 自己在把同一个场景全屏拉起 —— 我们再去把
         * `foreground` 改回 YES 就是在跟它的激活状态机抢同一份 settings，
         * 归档(12)/(13) 的 SIGTRAP 正是这类冲突。宁可让它闪，也不能撞。 */
        AevonWriteGuard.setScene(bundleID: bundleID, sceneID: nil, add: false)
        AevonWriteGuard.release()
    }

    private func handoffActiveLocked(_ identifier: String) -> Bool {
        guard !handoff.isEmpty else { return false }
        let now = CACurrentMediaTime()
        let expired = handoff.filter { now > $0.value }.map { $0.key }
        for key in expired {
            handoff.removeValue(forKey: key)
        }
        for (bid, _) in handoff where identifier.contains(bid) {
            return true
        }
        return false
    }

    func add(bundleID: String?, sceneID: String?) {
        lock.lock(); defer { lock.unlock() }
        if let bid = bundleID, !bid.isEmpty { bundleIDs.insert(bid) }
        if let sid = sceneID, !sid.isEmpty { sceneIDs.insert(sid) }
        /* V0.3.42（AevonWriteGuardV342）：同一份集合镜像给写通道修正模块 ——
         * 只有登记在册的场景才会被拦下「前台回收」这一笔。 */
        AevonWriteGuard.setScene(bundleID: bundleID, sceneID: sceneID, add: true)
    }

    func remove(bundleID: String?, sceneID: String?) {
        lock.lock(); defer { lock.unlock() }
        if let bid = bundleID { bundleIDs.remove(bid) }
        if let sid = sceneID { sceneIDs.remove(sid) }
        AevonWriteGuard.setScene(bundleID: bundleID, sceneID: sceneID, add: false)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        let oldBundles = bundleIDs
        let oldScenes = sceneIDs
        bundleIDs.removeAll()
        sceneIDs.removeAll()
        for bid in oldBundles { AevonWriteGuard.setScene(bundleID: bid, sceneID: nil, add: false) }
        for sid in oldScenes { AevonWriteGuard.setScene(bundleID: nil, sceneID: sid, add: false) }
        AevonWriteGuard.release()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return bundleIDs.isEmpty && sceneIDs.isEmpty
    }

    /// 场景标识是否命中已窗口化集合。要求正向匹配，绝不无故生效。
    func shouldKeepForeground(identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        // V0.1.4（AevonIconLaunchV104）：正在被全屏拉起的场景一律不碰 —— 这一小段
        // 时间由 FrontBoard 自己接管状态，我们任何一次 foreground 写入都可能撞上
        // 它的激活断言（安全模式）。
        if handoffActiveLocked(identifier) { return false }
        if sceneIDs.contains(identifier) { return true }
        for bid in bundleIDs where identifier.contains(bid) { return true }
        return false
    }

    /// 是否拦截场景停用（V0.1.3 起不再使用：停用门控整体移除，拦截思路已废弃）。
    /// 保留此函数仅为让历史调用点语义清晰 —— 任何**新增**代码都不要再走「清零停用原因」
    /// 这条路，它在 iOS 17.3 上与 FrontBoard 状态机冲突，会以 SIGTRAP 带走 SpringBoard。
}
