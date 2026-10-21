import Foundation

/// 一个可窗口化的 App。
struct AevonAppEntry {
    let bundleID: String
    let name: String
}

/// 查询可窗口化的 App。
///
/// V0.0.7 的教训：只走 `LSApplicationWorkspace` 的 `allInstalledApplications` /
/// `allApplications`，在 iOS 17 的 SpringBoard 里这两条路可能返回空（或返回的对象
/// 取不到 bundleIdentifier），而代码里又用 `applicationType != 0` 做了二次过滤，
/// 结果一个都不剩 —— 日志只有「共 0 个」，看不出卡在哪一步。
///
/// V0.0.8 改成「多来源 + 逐来源计数」：
///   来源 A：SBApplicationController.sharedInstance → allApplications（SpringBoard 自己的 App 表，最可靠）
///   来源 B：SBIconController.sharedInstance → model → leafIcons（桌面图标模型，必然有用户 App）
///   来源 C：LSApplicationWorkspace → allInstalledApplications / allApplications
///   来源 D：LSApplicationWorkspace → enumerateApplicationsOfType:block:（A/B/C 全空时才试）
/// 每个来源读到多少、因为什么被跳过，全部写进日志，下一次就能直接定位。
/// 也不再按 applicationType 过滤（枚举值含义在各版本不一致），只排除 com.apple.*。
enum AevonAppList {
    private static var cached: [AevonAppEntry]?

    private static let bundleIDSelectors = [
        "bundleIdentifier",
        "applicationIdentifier",
        "applicationBundleIdentifier",
        "applicationBundleID",
        "canonicalName",
    ]
    private static let nameSelectors = ["localizedName", "displayName", "itemName", "label"]

    static func userApps(forceReload: Bool = false) -> [AevonAppEntry] {
        if !forceReload, let cached = cached, !cached.isEmpty {
            return cached
        }

        var sources: [(String, [AnyObject])] = []
        sources.append(("SBApplicationController", fromApplicationController()))
        sources.append(("SBIconModel", fromIconModel()))
        sources.append(("LSApplicationWorkspace", fromWorkspace()))
        if sources.allSatisfy({ $0.1.isEmpty }) {
            sources.append(("enumerateApplicationsOfType", fromEnumeration()))
        }

        var result: [AevonAppEntry] = []
        var seen = Set<String>()
        var systemSkipped = 0
        var noIDSkipped = 0
        var samples: [String] = []

        for (sourceName, objects) in sources {
            AevonLog.info("[应用列表] 来源 \(sourceName): 读到 \(objects.count) 个对象")
            for object in objects {
                guard let bundleID = bundleID(of: object), !bundleID.isEmpty else {
                    noIDSkipped += 1
                    if samples.count < 4, let className = AevonRuntime.className(object) {
                        samples.append(className)
                    }
                    continue
                }
                if bundleID.hasPrefix("com.apple.") {
                    systemSkipped += 1
                    continue
                }
                if seen.contains(bundleID) { continue }
                seen.insert(bundleID)
                let name = displayName(of: object)
                    ?? AevonAppInfo.displayName(bundleID: bundleID)
                    ?? bundleID
                result.append(AevonAppEntry(bundleID: bundleID, name: name))
            }
        }

        AevonLog.info("[应用列表] 跳过系统 App \(systemSkipped) 个，取不到 bundleID \(noIDSkipped) 个"
                      + (samples.isEmpty ? "" : "（示例类名：\(samples.joined(separator: ", "))）"))

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !result.isEmpty { cached = result }
        AevonLog.info("[应用列表] 共 \(result.count) 个可窗口化的 App"
                      + (result.isEmpty ? "" : "：\(result.prefix(8).map { $0.name }.joined(separator: "、"))"))
        return result
    }

    // MARK: - 来源 A：SpringBoard 的 App 表

    private static func fromApplicationController() -> [AnyObject] {
        guard let controller = AevonRuntime.sendClass("SBApplicationController",
                                                      Selector(("sharedInstance"))) else {
            return []
        }
        for name in ["allApplications", "applications"] {
            if let value = AevonRuntime.send(controller, Selector(name)),
               let objects = arrayLike(value), !objects.isEmpty {
                return objects
            }
        }
        return []
    }

    // MARK: - 来源 B：桌面图标模型

    private static func fromIconModel() -> [AnyObject] {
        guard let controller = AevonRuntime.sendClass("SBIconController",
                                                      Selector(("sharedInstance"))),
              let model = AevonRuntime.send(controller, Selector(("model"))) else {
            return []
        }
        for name in ["leafIcons", "allIcons", "visibleIcons"] {
            if let value = AevonRuntime.send(model, Selector(name)),
               let objects = arrayLike(value), !objects.isEmpty {
                return objects
            }
        }
        for name in ["_leafIcons", "_icons"] {
            if let value = AevonRuntime.ivarObject(model, name),
               let objects = arrayLike(value), !objects.isEmpty {
                return objects
            }
        }
        return []
    }

    // MARK: - 来源 C：LSApplicationWorkspace 数组接口

    private static func fromWorkspace() -> [AnyObject] {
        guard let workspace = AevonRuntime.sendClass("LSApplicationWorkspace",
                                                     Selector(("defaultWorkspace"))) else {
            AevonLog.warn("[应用列表] LSApplicationWorkspace 不可用")
            return []
        }
        for name in ["allInstalledApplications", "allApplications"] {
            if let value = AevonRuntime.send(workspace, Selector(name)),
               let objects = arrayLike(value), !objects.isEmpty {
                return objects
            }
        }
        return []
    }

    // MARK: - 来源 D：enumerateApplicationsOfType:block:

    private static func fromEnumeration() -> [AnyObject] {
        guard let workspace = AevonRuntime.sendClass("LSApplicationWorkspace",
                                                     Selector(("defaultWorkspace"))) else {
            return []
        }
        let selector = Selector(("enumerateApplicationsOfType:block:"))
        guard workspace.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(workspace), selector) else {
            return []
        }
        var collected: [AnyObject] = []
        // type 0 = 用户安装的 App
        let block: @convention(block) (AnyObject) -> Void = { proxy in
            collected.append(proxy)
        }
        typealias EnumerateFn = @convention(c) (AnyObject, Selector, UInt64, AnyObject) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: EnumerateFn.self)
        function(workspace, selector, 0, unsafeBitCast(block, to: AnyObject.self))
        return collected
    }

    // MARK: - 工具

    private static func arrayLike(_ value: AnyObject) -> [AnyObject]? {
        if let array = value as? [AnyObject] { return array }
        if let set = value as? NSSet { return set.allObjects as? [AnyObject] }
        return nil
    }

    /// bundleID：先读对象自身，读不到再看它包着的 application / applicationProxy
    /// （SBIcon 系对象上的 App 信息常常挂在这两个属性后面）。
    private static func bundleID(of object: AnyObject) -> String? {
        if let direct = firstString(object, bundleIDSelectors) { return direct }
        for name in ["application", "applicationProxy"] {
            let selector = Selector(name)
            guard object.responds(to: selector),
                  let nested = AevonRuntime.send(object, selector) else { continue }
            if let nestedID = firstString(nested, bundleIDSelectors) { return nestedID }
        }
        return nil
    }

    private static func displayName(of object: AnyObject) -> String? {
        if let direct = firstString(object, nameSelectors) { return direct }
        for name in ["application", "applicationProxy"] {
            let selector = Selector(name)
            guard object.responds(to: selector),
                  let nested = AevonRuntime.send(object, selector) else { continue }
            if let nestedName = firstString(nested, nameSelectors) { return nestedName }
        }
        return nil
    }

    private static func firstString(_ object: AnyObject, _ selectors: [String]) -> String? {
        for name in selectors {
            let selector = Selector(name)
            guard object.responds(to: selector),
                  let value = AevonRuntime.send(object, selector) else { continue }
            if let string = value as? String, !string.isEmpty { return string }
        }
        return nil
    }
}
