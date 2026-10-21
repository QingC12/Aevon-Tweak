import Foundation

/// 一个可窗口化的 App。
struct AevonAppEntry {
    let bundleID: String
    let name: String
}

/// 查询用户安装的 App（LSApplicationWorkspace）。
///
/// 只读系统公开/半公开接口，全部带存在性守卫；
/// 不取图标（图标要跨进程取渲染数据，异常风险高），只显示名称 + bundleID。
enum AevonAppList {
    private static var cached: [AevonAppEntry]?

    static func userApps(forceReload: Bool = false) -> [AevonAppEntry] {
        if !forceReload, let cached = cached, !cached.isEmpty {
            return cached
        }
        guard let workspace = AevonRuntime.sendClass("LSApplicationWorkspace",
                                                    Selector(("defaultWorkspace"))) else {
            AevonLog.warn("[应用列表] LSApplicationWorkspace 不可用")
            return []
        }

        var proxies: [AnyObject] = []
        for selector in [Selector(("allInstalledApplications")), Selector(("allApplications"))] {
            guard let collection = AevonRuntime.send(workspace, selector) else { continue }
            if let array = collection as? [AnyObject] {
                proxies = array
            } else if let set = collection as? NSSet {
                proxies = set.allObjects as? [AnyObject] ?? []
            }
            if !proxies.isEmpty { break }
        }

        var result: [AevonAppEntry] = []
        var seen = Set<String>()
        for proxy in proxies {
            guard let bundleID = AevonRuntime.send(proxy, Selector(("bundleIdentifier"))) as? String,
                  !bundleID.isEmpty else { continue }
            // 系统 App 不列（避免把设置、桌面之类的拿去做浮窗）
            if bundleID.hasPrefix("com.apple.") { continue }
            // applicationType: 0 = 用户安装，1 = 系统
            if let type = AevonRuntime.int(proxy, Selector(("applicationType"))), type != 0 { continue }
            if seen.contains(bundleID) { continue }
            seen.insert(bundleID)

            let name = (AevonRuntime.send(proxy, Selector(("localizedName"))) as? String)
                ?? AevonAppInfo.displayName(bundleID: bundleID)
                ?? bundleID
            result.append(AevonAppEntry(bundleID: bundleID, name: name))
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        cached = result
        AevonLog.info("[应用列表] 共 \(result.count) 个可窗口化的 App")
        return result
    }
}
