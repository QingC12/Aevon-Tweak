import UIKit
import ObjectiveC
import QuartzCore

/// V0.1.6（AevonProbeV106）：**运行时探针**。
///
/// 为什么必须有它 —— 两次「一口否认」的教训：
///
///   ① 0.1.4 的日志把 SpringBoard 的窗口列了一遍，看到
///      `SBStatusBarWindow / SBHomeScreenWindow / SBCoverSheetWindow / SBControlCenterWindow /
///       SBSystemApertureWindow …` 里没有 SystemGesture 窗口，就断言「系统上不存在这个窗口」。
///      但那行日志是 `sorted.suffix(8)` 打出来的 —— **15 个窗口只印了 8 个**，
///      剩下 7 个从来没被看过一眼。用被截断的证据去否定一个机制，是最典型的错误。
///
///   ② 0.1.5 只试了两个硬编码类名（`SBMainDisplaySystemGestureManager` /
///      `SBSystemGestureManager`）和三种工厂方法名，全落空就写「管理器/方法不存在」。
///      但 iOS 17 完全可能只是改了类名或工厂名 —— 系统手势（控制中心、底部上滑、
///      便捷访问）在真机上明明一直好使，说明这条管线**必然存在且在跑**，
///      问题只在于我们没找对入口。
///
/// 所以这一版不再靠记忆里的名字猜，而是：
///   · 把**全部**窗口一个不落地列出来（含每个场景的 sceneIdentifier）；
///   · 用 objc runtime 扫描全进程类表，把名字里带 `SystemGesture` / `GestureManager`
///     的类全部找出来，并 dump 它们的方法名（含 `addGesture` / `acquire` / `defer`）；
///   · 顺带扫一遍桌面图标启动链（`*IconController*` / `*Workspace*`）的方法名，
///     为「全屏启动」找一个可靠 hook 点。
///
/// 探针只读：只用 `class_copyMethodList` / `object_getIvar` / `responds(to:)` 这类只读 API，
/// 不改任何状态、不 swizzle、不发业务消息。唯一会「发消息」的是给候选管理器类发
/// `sharedInstance` 之类的无参工厂 —— 且类名必须先过严格筛选。
enum AevonProbeV106 {

    // MARK: - 入口

    private static var ran = false
    private static var cachedManagers: [AnyObject]?

    /// 启动后跑一次（默认延迟 6 秒，避开启动最忙的那几秒）。
    static func runOnce(after delay: TimeInterval = 6.0) {
        guard !ran else { return }
        ran = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            dumpWindowPanorama()
            dumpGestureRecognizerHosts()
            dumpGestureClassScan()
            dumpLaunchClassScan()
        }
    }

    // MARK: - 一、窗口全景（不截断）

    /// 把所有场景的所有窗口**逐行**打出来，一个都不省。
    ///
    /// 0.1.0~0.1.5 的那行「窗口栈」诊断用的是 `sorted.suffix(8)`：场景里窗口一多
    /// （APP 场景稳定 15 个），最上面 8 个之外的窗口就永远看不到 —— 手势窗口如果
    /// 排在中低层级，一次都印不出来。这里先按层级全列，再单独点名「可疑窗口」。
    static func dumpWindowPanorama() {
        var lines: [String] = []
        var total = 0
        var suspicious: [String] = []

        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let sceneName = AevonRuntime.className(scene) ?? "\(type(of: scene))"
            let identifier = AevonRuntime.ivarString(scene, "_sceneIdentifier") ?? "?"
            let sorted = scene.windows.sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
            total += sorted.count
            lines.append("场景[\(sceneName)] role=\(scene.session.role.rawValue) state=\(scene.activationState.rawValue) id=\(identifier) 共\(sorted.count)窗")
            for (index, w) in sorted.enumerated() {
                let className = AevonRuntime.className(w) ?? "\(type(of: w))"
                let controller = w.rootViewController.map { AevonRuntime.className($0) ?? "\(type(of: $0))" } ?? "无"
                let tags = "level=\(Int(w.windowLevel.rawValue))\(w.isHidden ? " hidden" : "")\(w.alpha < 0.99 ? " alpha=\(String(format: "%.2f", w.alpha))" : "")"
                lines.append("  #\(index) \(className) \(tags) rvc=\(controller)")
                // 可疑：类名/根控制器里带手势语义，或者层级夹在系统窗口之间
                let probe = (className + " " + controller).lowercased()
                if probe.contains("gesture") || probe.contains("swipe") || probe.contains("edge") {
                    suspicious.append("\(className)(\(Int(w.windowLevel.rawValue)))")
                }
            }
        }

        if lines.isEmpty { lines.append("没有任何 UIWindowScene 可枚举") }
        AevonLog.info("[探针] 窗口全景（完整，不截断）：\(total) 个窗口 / \(UIApplication.shared.connectedScenes.count) 个场景（AevonProbeV106 AevonWinDumpFullV106）")
        for line in lines.prefix(60) {
            AevonLog.info("[探针] 窗口 \(line)")
        }
        if lines.count > 60 {
            AevonLog.info("[探针] 窗口 ……另有 \(lines.count - 60) 行未打（已超 60 行上限）")
        }
        if suspicious.isEmpty {
            AevonLog.info("[探针] 手势语义窗口：本进程 UIWindowScene 里没有（不等于系统没有 —— 见类扫描结果）")
        } else {
            AevonLog.info("[探针] 手势语义窗口：\(suspicious.joined(separator: ", "))")
        }
    }

    // MARK: - 二、系统手势识别器挂在哪

    /// 遍历所有窗口的视图树，把「挂了手势识别器的视图」全部列出来。
    ///
    /// 这是回答「系统手势到底怎么进行」最直接的一条证据：
    /// 控制中心下拉、底部上滑、便捷访问、侧滑返回必然各有一个识别器实例活在 SB 进程里，
    /// 它们一定挂在**某个视图**上。找到那个视图，就等于找到了「触摸从落下就归 SB」
    /// 的那一层 —— 比按类名猜窗口靠谱得多（窗口类名可以不含 gesture，识别器却照样在）。
    ///
    /// 只读：只访问 `view.gestureRecognizers`，不 add / remove / swizzle。
    static func dumpGestureRecognizerHosts() {
        var lines: [String] = []
        var budget = 6000          // 全进程视图节点预算，防止某个巨型视图树把主线程拖住
        var windowCount = 0
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                let windowClass = AevonRuntime.className(window) ?? "\(type(of: window))"
                guard let root = window.rootViewController?.view ?? window.subviews.first else { continue }
                windowCount += 1
                walkGestures(root, depth: 0, budget: &budget, lines: &lines, windowClass: windowClass)
                if budget <= 0 { break }
            }
            if budget <= 0 { break }
        }
        AevonLog.info("[探针] 手势识别器宿主：扫了 \(windowCount) 个窗口的视图树，找到 \(lines.count) 个识别器（AevonProbeV106）")
        for line in lines.prefix(50) {
            AevonLog.info("[探针] 识别器 \(line)")
        }
        if lines.count > 50 {
            AevonLog.info("[探针] 识别器 ……另有 \(lines.count - 50) 条未打")
        }
        if lines.isEmpty {
            AevonLog.warn("[探针] 一个识别器都没扫到 —— 说明 SB 的系统手势不在 UIWindow 视图树里，得换扫法（AevonProbeV106）")
        }
    }

    private static func walkGestures(_ view: UIView,
                                     depth: Int,
                                     budget: inout Int,
                                     lines: inout [String],
                                     windowClass: String) {
        guard budget > 0 else { return }
        budget -= 1
        if let recognizers = view.gestureRecognizers, !recognizers.isEmpty {
            let host = AevonRuntime.className(view) ?? "\(type(of: view))"
            for recognizer in recognizers {
                let name = AevonRuntime.className(recognizer) ?? "\(type(of: recognizer))"
                lines.append("\(name) @ \(host) ← \(windowClass)")
            }
        }
        guard depth < 14 else { return }
        for subview in view.subviews {
            walkGestures(subview, depth: depth + 1, budget: &budget, lines: &lines, windowClass: windowClass)
            if budget <= 0 { return }
        }
    }

    // MARK: - 三、手势类扫描

    private static var gestureClassNames: [String] = []

    /// 扫全进程类表，找名字带手势语义的类，并 dump 关键方法名。
    ///
    /// 这一步就是「系统手势到底怎么进行的」的答案来源：
    /// 只要有一个 `*SystemGestureManager*` 类活着，就说明管线在本进程里，
    /// 我们在 0.1.5 里的「不存在」是**名字问题**而不是机制问题。
    static func dumpGestureClassScan() {
        let names = allClassNames()
        var gestureClasses: [String] = []
        for name in names {
            let lower = name.lowercased()
            if lower.contains("systemgesture") || lower.contains("gesturemanager")
                || (lower.contains("gesturerecognizer") && lower.contains("sb")) {
                gestureClasses.append(name)
            }
        }
        gestureClassNames = gestureClasses
        AevonLog.info("[探针] 全进程类 \(names.count) 个；名字含手势管理的 \(gestureClasses.count) 个：\(gestureClasses.prefix(24).joined(separator: ", "))（AevonProbeV106）")

        for name in gestureClasses.prefix(10) {
            let keywords = ["addGesture", "acquire", "defer", "shared", "manager", "Recognizer", "gesture"]
            let methods = methodNames(of: name).filter { selector in
                keywords.contains { selector.localizedCaseInsensitiveContains($0) }
            }
            var line = "[探针] \(name) → \(methods.prefix(24).joined(separator: " "))"
            if methods.count > 24 { line += " …共 \(methods.count) 个" }
            AevonLog.info(line)
        }

        // 候选管理器实例（供右缘接管直接使用）
        let managers = resolveGestureManagers()
        if managers.isEmpty {
            AevonLog.warn("[探针] 仍取不到任何手势管理器实例（类表扫描后依旧为空）—— 下一版改从 SBWorkspace 的 ivar 里挖（AevonProbeV106）")
        } else {
            let detail = managers.enumerated().map { index, manager in
                let className = AevonRuntime.className(manager) ?? "?"
                let two = manager.responds(to: Selector(("addGestureRecognizer:toDisplayWithIdentity:")))
                let one = manager.responds(to: Selector(("addGestureRecognizer:")))
                return "#\(index):\(className)[two=\(two ? 1 : 0) one=\(one ? 1 : 0)]"
            }
            AevonLog.info("[探针] 可用手势管理器实例：\(detail.joined(separator: " "))（AevonProbeV106）")
        }
    }

    // MARK: - 三、桌面图标启动链扫描

    /// 扫启动链类的方法名，为「全屏启动时自动关浮窗」找可靠 hook 点。
    ///
    /// 0.1.4 试过 `SBIconController -iconManager:launchIconForIconView:withActions:`，
    /// 归档(14) 实锤这个方法在 iOS 17.3.1 不存在。这里把 `*IconController*` 里
    /// 名字带 launch/activate/tap/open/select 的方法全印出来，下一版按真名 hook。
    static func dumpLaunchClassScan() {
        let names = allClassNames()
        var targets: [String] = []
        for name in names {
            let lower = name.lowercased()
            if lower.contains("iconcontroller") || lower.hasSuffix("iconview") || lower.contains("iconviewcontroller") {
                targets.append(name)
            }
        }
        AevonLog.info("[探针] 启动链候选类 \(targets.count) 个：\(targets.prefix(16).joined(separator: ", "))（AevonProbeV106 AevonLaunchProbeV106）")
        for name in targets.prefix(6) {
            let keywords = ["launch", "activate", "tap", "open", "select", "perform"]
            let methods = methodNames(of: name).filter { selector in
                keywords.contains { selector.localizedCaseInsensitiveContains($0) }
            }
            AevonLog.info("[探针] \(name) → \(methods.prefix(20).joined(separator: " "))\(methods.count > 20 ? " …" : "")")
        }
    }

    // MARK: - 管理器解析（供 AevonSystemGestureV105 调用）

    /// 用类表扫描去找真正可用的手势管理器实例。
    ///
    /// 只认类名里带 `systemgesturemanager` / `gesturemanager` 的类，并且只给它发
    /// 无参工厂方法消息（`sharedInstance` 之类）—— 绝不向任意类发消息。
    /// 三条路：① 硬编码候选类名 ② 类表正则扫描 ③ 从常驻单例的 ivar 里挖
    /// （`SBMainWorkspace` / `SBMainDisplaySceneManager` 这类对象可能直接持有管理器）。
    static func resolveGestureManagers() -> [AnyObject] {
        if let cached = cachedManagers, !cached.isEmpty { return cached }
        if gestureClassNames.isEmpty {
            gestureClassNames = allClassNames().filter {
                let lower = $0.lowercased()
                return lower.contains("systemgesturemanager") || lower.contains("gesturemanager")
            }
        }
        var result: [AnyObject] = []
        let factories = ["sharedInstance", "_sharedInstance", "sharedManager", "defaultManager",
                         "mainDisplayManager", "mainDisplaySystemGestureManager"]
        for name in gestureClassNames {
            for factory in factories {
                guard let manager = AevonRuntime.sendClass(name, Selector((factory))) else { continue }
                if !result.contains(where: { $0 === manager }) { result.append(manager) }
            }
        }
        // ③ 从常驻单例的 ivar 里挖
        for className in ["SBMainWorkspace", "SBMainDisplaySceneManager", "SBSceneManager", "SBIconController"] {
            guard let host = AevonRuntime.sendClass(className, Selector(("sharedInstance"))) else { continue }
            for candidate in ivarObjects(of: host, nameContains: "gesture") {
                if !result.contains(where: { $0 === candidate }) { result.append(candidate) }
            }
        }
        // 只有非空才缓存：第一轮为空可能只是时候未到，允许后面再扫一次。
        if !result.isEmpty { cachedManagers = result }
        return result
    }

    /// 从对象的 ivar 里按名字挖对象（只读，且严格先看类型编码是不是 `@`）。
    ///
    /// `object_getIvar` 对非对象类型（int / struct）是未定义行为，必须先验类型编码 ——
    /// 这条坑在 0.0.x 的圆盘图标抓取上踩过一次。
    private static func ivarObjects(of object: AnyObject, nameContains needle: String) -> [AnyObject] {
        var result: [AnyObject] = []
        guard let cls = object_getClass(object) else { return result }
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(cls, &count) else { return result }
        defer { free(ivars) }
        for index in 0..<Int(count) {
            let ivar = ivars[index]
            guard let namePointer = ivar_getName(ivar),
                  let typePointer = ivar_getTypeEncoding(ivar) else { continue }
            let name = String(cString: namePointer)
            guard name.lowercased().contains(needle) else { continue }
            guard String(cString: typePointer).hasPrefix("@") else { continue }
            if let value = object_getIvar(object, ivar) {
                result.append(value as AnyObject)
            }
        }
        return result
    }

    // MARK: - runtime 工具

    /// 全进程类名（objc runtime 类表）。
    ///
    /// SpringBoard 里通常一两万个类。`objc_copyClassList` 返回的指针必须自己 free，
    /// 否则每次调用泄漏几十 KB —— 我们只调一次，但该 free 还是要 free。
    private static func allClassNames() -> [String] {
        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count), count > 0 else { return [] }
        defer { free(UnsafeMutableRawPointer(list)) }
        var names: [String] = []
        names.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let name = String(cString: class_getName(list[index]))
            if !name.isEmpty, !name.hasPrefix("_$") { names.append(name) }
        }
        return names
    }

    /// 某个类的实例方法 + 类方法名（只读）。
    private static func methodNames(of className: String) -> [String] {
        guard let cls = NSClassFromString(className) else { return [] }
        var names: [String] = []
        var count: UInt32 = 0
        if let list = class_copyMethodList(cls, &count) {
            defer { free(list) }
            for index in 0..<Int(count) {
                names.append(NSStringFromSelector(method_getName(list[index])))
            }
        }
        if let meta = object_getClass(cls), let list = class_copyMethodList(meta, &count) {
            defer { free(list) }
            for index in 0..<Int(count) {
                names.append("+" + NSStringFromSelector(method_getName(list[index])))
            }
        }
        return names
    }
}
