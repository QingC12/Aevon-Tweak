import Foundation

/// 圆盘里的 App 收藏（数组顺序 = 圆盘上从下往上的顺序）。
///
/// Stheno 的证据：`Stheno.dylib` 里有 `_apps` / `_selected` / `_perAppData` / `AppSearcher` /
/// `TrashAppState` 这套数据模型 —— 圆盘里的 App 是一份用户自选的列表，可增可删。
/// 我们只做「有序列表 + 上限」，存在偏好域 com.Aevon 的 `RingApps` 键里。
enum AevonRingStore {
    /// 圆盘上最多放几个（V0.0.19 从 10 提到 16：用户反馈「显示的应用太少了」）。
    /// 半径 124 的整圆周长约 780pt，16 个图标间隔 48pt ≈ 图标 44pt + 4pt 缝隙，还是能点准。
    static let maxCount = 16

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
