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
    private static let suite = "com.Aevon"
    private static var cached: [String]?

    static func bundleIDs() -> [String] {
        if let cached = cached { return cached }
        guard let store = UserDefaults(suiteName: suite),
              let raw = store.array(forKey: key) as? [String] else {
            cached = []
            return []
        }
        let list = raw.filter { !$0.isEmpty }
        cached = list
        return list
    }

    static func save(_ list: [String]) {
        var seen = Set<String>()
        var out: [String] = []
        for id in list where !seen.contains(id) {
            seen.insert(id)
            out.append(id)
            if out.count >= maxCount { break }
        }
        cached = out
        let store = UserDefaults(suiteName: suite)
        store?.set(out, forKey: key)
        store?.synchronize()
        AevonLog.info("[圆盘] 已保存 \(out.count) 个 App：\(out.joined(separator: ", "))")
    }

    /// V0.0.27：设置页改完圆盘列表后会广播 com.aevon.prefschanged，
    /// SpringBoard 这边必须清掉进程内缓存，否则圆盘永远显示旧顺序。
    static func invalidateCache() {
        cached = nil
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
