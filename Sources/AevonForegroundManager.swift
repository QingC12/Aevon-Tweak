import Foundation

/// 前台保活管理：登记用户主动窗口化的 App / 场景。
/// 只有登记在册的场景才会被 hook 强制前台或拦截停用；
/// 未开窗时集合为空，hook 行为与原生生系统完全一致。
final class AevonForegroundManager {
    static let shared = AevonForegroundManager()
    private init() {}

    private let lock = NSLock()
    private var bundleIDs = Set<String>()
    private var sceneIDs = Set<String>()

    func add(bundleID: String?, sceneID: String?) {
        lock.lock(); defer { lock.unlock() }
        if let bid = bundleID, !bid.isEmpty { bundleIDs.insert(bid) }
        if let sid = sceneID, !sid.isEmpty { sceneIDs.insert(sid) }
    }

    func remove(bundleID: String?, sceneID: String?) {
        lock.lock(); defer { lock.unlock() }
        if let bid = bundleID { bundleIDs.remove(bid) }
        if let sid = sceneID { sceneIDs.remove(sid) }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        bundleIDs.removeAll()
        sceneIDs.removeAll()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return bundleIDs.isEmpty && sceneIDs.isEmpty
    }

    /// 场景标识是否命中已窗口化集合。要求正向匹配，绝不无故生效。
    func shouldKeepForeground(identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if sceneIDs.contains(identifier) { return true }
        for bid in bundleIDs where identifier.contains(bid) { return true }
        return false
    }

    /// 是否拦截场景停用（V0.1.3 起不再使用：停用门控整体移除，拦截思路已废弃）。
    /// 保留此函数仅为让历史调用点语义清晰 —— 任何**新增**代码都不要再走「清零停用原因」
    /// 这条路，它在 iOS 17.3 上与 FrontBoard 状态机冲突，会以 SIGTRAP 带走 SpringBoard。
    func shouldBlockDeactivation(identifier: String) -> Bool {
        return shouldKeepForeground(identifier: identifier)
    }
}
