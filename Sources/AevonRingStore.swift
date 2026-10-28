import Foundation

/// 圆盘里的 App 收藏（数组顺序 = 圆盘上从下往上的顺序）。
///
/// Stheno 的证据：`Stheno.dylib` 里有 `_apps` / `_selected` / `_perAppData` / `AppSearcher` /
/// `TrashAppState` 这套数据模型 —— 圆盘里的 App 是一份用户自选的列表，可增可删。
/// 我们只做「有序列表 + 上限」，存在偏好域 com.Aevon 的 `RingApps` 键里。
enum AevonRingStore {
    /// 圆盘上最多放几个。V0.0.20 起是多圈布局：内圈 8 + 中圈 12 + 外圈 16 = 36。
    static let maxCount = 36

    private static let key = "RingApps"
    /// V0.0.31（AevonRingPinnedV31）：最后一份「可信快照」。
    /// 跨进程读 UserDefaults 偶尔会拿到空/残缺快照（用户 Aevon(24) 实测：同一分钟内
    /// 圆盘 App 数在 20/21/22/23 之间漂移、图标排序被打乱）—— 只有设置页真正
    /// 广播「列表改了」时才更新快照，圆盘打开时永远用同一份，位置因此固定并记忆。
    private static let snapshotKey = "RingAppsSnapshot"
    private static let suite = "com.Aevon"
    private static var cached: [String]?

    /// 非空、去重、不超上限 —— 满足才算可信列表
    private static func sanitize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in raw where !id.isEmpty && !seen.contains(id) {
            seen.insert(id)
            out.append(id)
            if out.count >= maxCount { break }
        }
        return out
    }

    private static func readList(forKey k: String) -> [String] {
        guard let store = UserDefaults(suiteName: suite),
              let raw = store.array(forKey: k) as? [String] else { return [] }
        return sanitize(raw)
    }

    static func bundleIDs() -> [String] {
        if let cached = cached { return withQuickActions(cached) }
        var list = readList(forKey: key)
        if list.isEmpty { list = readList(forKey: snapshotKey) }
        cached = list
        return withQuickActions(list)
    }

    /// V0.2.62（AevonQuickActionV262，用户 Aevon(36) #2）：圆盘里固定挂两个快捷动作
    /// （截图 / 录屏），永远排在最前两格 —— 收藏列表增删 App 不会影响它们。
    private static func withQuickActions(_ list: [String]) -> [String] {
        let apps = list.filter { !AevonQuickAction.isAction($0) }
        return AevonQuickAction.allIDs + apps
    }

    /// 设置页广播 prefschanged 后调用（**唯一**的跨进程刷新入口）。
    /// 读到可信列表就更新缓存并写快照；读到空列表时保留旧缓存（防漂移读）。
    static func refreshFromSettings() {
        let list = readList(forKey: key)
        if !list.isEmpty {
            cached = list
            UserDefaults(suiteName: suite)?.set(list, forKey: snapshotKey)
        } else if cached == nil {
            cached = readList(forKey: snapshotKey)
        }
    }

    static func save(_ list: [String]) {
        let out = sanitize(list)
        cached = out
        let store = UserDefaults(suiteName: suite)
        store?.set(out, forKey: key)
        store?.set(out, forKey: snapshotKey)
        store?.synchronize()
        AevonLog.info("[圆盘] 已保存 \(out.count) 个 App：\(out.joined(separator: ", "))")
    }

    /// V0.0.27：设置页改完圆盘列表后会广播 com.aevon.prefschanged。
    /// V0.0.31：改为 `refreshFromSettings()`（带快照与防漂移），只在真正改列表时刷新 ——
    /// 旧版 0.2 秒轮询里盲目清缓存是排序漂移的元凶，禁止改回。
    static func invalidateCache() {
        refreshFromSettings()
    }

    static func contains(_ bundleID: String) -> Bool {
        return bundleIDs().contains(bundleID)
    }

    /// 加入 / 移出，返回「现在是否在圆盘里」。
    @discardableResult
    static func toggle(_ bundleID: String) -> Bool {
        var list = bundleIDs()
        if let index = list.firstIndex(of: bundleID) {
            list.remove(at: index)
            save(list)
            return false
        }
        guard list.count < maxCount else {
            AevonLog.warn("[圆盘] 已达上限 \(maxCount) 个，忽略加入 \(bundleID)")
            return false
        }
        list.append(bundleID)
        save(list)
        return true
    }

    static func remove(_ bundleID: String) {
        var list = bundleIDs()
        guard let index = list.firstIndex(of: bundleID) else { return }
        list.remove(at: index)
        save(list)
    }

    /// 首次使用：用候选 App 填几个，保证呼出圆盘时不是空的。
    static func seedIfNeeded(from apps: [AevonAppEntry]) {
        guard bundleIDs().isEmpty, !apps.isEmpty else { return }
        let seed = Array(apps.prefix(10)).map { $0.bundleID }
        save(seed)
        AevonLog.info("[圆盘] 首次使用，已用 \(seed.count) 个 App 预填（可在面板「编辑圆盘」里改）")
    }
}
