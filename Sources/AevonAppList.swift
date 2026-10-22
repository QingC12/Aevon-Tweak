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
        var systemIncluded = 0
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
                // V0.0.22：系统 App 也要出现在列表里（设置 / 相机 / 照片 / 时钟…都会用到），
                // 只排除「不是 App 的东西」：插件、小组件、扩展、后台守护进程等。
                if !isUserFacingApp(object, bundleID: bundleID) {
                    if bundleID.hasPrefix("com.apple.") { systemSkipped += 1 }
                    continue
                }
                if seen.contains(bundleID) { continue }
                seen.insert(bundleID)
                if bundleID.hasPrefix("com.apple.") { systemIncluded += 1 }
                let name = displayName(of: object)
                    ?? AevonAppInfo.displayName(bundleID: bundleID)
                    ?? bundleID
                result.append(AevonAppEntry(bundleID: bundleID, name: name))
            }
        }

        AevonLog.info("[应用列表] 系统 App 收录 \(systemIncluded) 个，排除非 App 对象 \(systemSkipped) 个，"
                      + "取不到 bundleID \(noIDSkipped) 个"
                      + (samples.isEmpty ? "" : "（示例类名：\(samples.joined(separator: ", "))）"))

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !result.isEmpty { cached = result }
        AevonLog.info("[应用列表] 共 \(result.count) 个可窗口化的 App"
                      + (result.isEmpty ? "" : "：\(result.prefix(8).map { $0.name }.joined(separator: "、"))"))
        return result
    }

    /// 是否「用户能看到、能点开的 App」。
    ///
    /// 判定顺序（任何一步能确定就返回）：系统禁启动 / 隐藏 → 否；bundle 不是 .app → 否；
    /// 名字里带 widget / extension / appex / plugin 等 → 否；其余都收（含系统 App）。
    private static func isUserFacingApp(_ object: AnyObject, bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        for banned in ["widget", "extension", "appex", "plugin", "watchkit", "watchapp",
                       "xpc", "diagnostic", "springboard", "placeholder", "purplebuddy"] where lower.contains(banned) {
            return false
        }
        // 对象自身 + 它包着的 application / applicationProxy 都查一遍
        var targets: [AnyObject] = [object]
        for name in ["application", "applicationProxy"] {
            if let nested = AevonRuntime.send(object, Selector(name)) { targets.append(nested) }
        }
        for target in targets {
            if let prohibited = AevonRuntime.bool(target, key: "isLaunchProhibited"), prohibited { return false }
            if let hidden = AevonRuntime.bool(target, key: "isHidden"), hidden { return false }
            if let placeholder = AevonRuntime.bool(target, key: "isPlaceholder"), placeholder { return false }
            if let path = bundlePath(of: target) {
                // 有路径就以路径说话：只认 .app
                return path.hasSuffix(".app")
            }
        }
        return true
    }

    /// 读 App 的 .app 路径（不同来源的对象属性名不同，逐个试）
    private static func bundlePath(of object: AnyObject) -> String? {
        for name in ["bundleURL", "applicationBundleURL", "containerURL", "bundleContainerURL"] {
            let selector = Selector(name)
            guard object.responds(to: selector), let value = AevonRuntime.send(object, selector) else { continue }
            if let url = value as? URL { return url.path }
            if let url = value as? NSURL, let path = url.path { return path }
            if let path = value as? String, path.hasPrefix("/") { return path }
        }
        return nil
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
