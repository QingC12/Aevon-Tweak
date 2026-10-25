import UIKit
import ObjectiveC
import QuartzCore

/// V0.1.7（AevonProbeV107 / AevonMultiProbeV107）：**多组探针，一次部署一次收齐**。
///
/// 为什么要重写 V0.1.6 的探针 —— 它自己把 SpringBoard 打死了：
///
///   归档(13) / Aevon(74) 两次崩溃都紧跟在「识别器 ……另有 N 条未打」之后，
///   而下一组 `dumpGestureClassScan()` 的第一行日志从未出现。崩溃栈是
///     swift_dynamicCast → swift_getObjectType → _CF_forwarding_prep_0 → 陷阱(SIGTRAP)
///   反汇编定位到函数 0x1f988 里那条 `swift_dynamicCast`（x0/x1 指向栈上 Any）。
///   也就是说：**我们在 Swift 里遍历全进程类表、把 AnyClass 元类型当对象做动态转换，
///   撞上了某个不能这么用的类**。这条路上 Swift 一个 `as?` 就能让 SpringBoard 归西。
///
/// 所以这一版三条硬规矩：
///   ① 类表 / 方法名 / ivar 名 / 类名 全部交给 ObjC 垫片（`AevonProbeSupport.m`），
///      Swift 侧不再出现任何类表 API，也不再对陌生对象做 `as?`；
///   ② 每一组都从 `AevonShieldRun`（ObjC 的 @try）里过一道 —— Swift 的 do/catch
///      捕不到 `doesNotRecognizeSelector:`，@try 能捕，捕到就只写日志，SB 毫发无伤；
///   ③ 六组各自独立调度、间隔 0.8 秒，单组出问题不影响其它组，也绝不长时间占着主线程。
///
/// 用户要求「一次部署多个探针、一次拿多个结果」，所以这版一次装六组：
///   P1 系统手势管线（类 + 类方法 + 活的 manager 实例）
///   P2 手势识别器宿主（按类名聚合，只看系统私有类）
///   P3 桌面图标启动链（为「全屏拉起时自动关浮窗」找真名）
///   P4 事件路由 / 延迟层（触摸到底怎么归 SB 的）
///   P5 场景与浮窗状态（黑窗机制）
///   P6 配置快照（一眼看全当前开关）
///
/// 探针只读：不 swizzle、不改任何状态、不注册任何 hook、不写任何文件。
enum AevonProbeV107 {

    /// 本次 SpringBoard 进程内只跑一轮。
    private static var ran = false
    /// 启动后等多久再跑（避开启动最忙的那几秒）。
    private static let startDelay: TimeInterval = 8.0
    /// 组间隔：让主线程有喘息，也避免日志时间戳挤在同一毫秒里。
    private static let groupGap: TimeInterval = 0.8

    // MARK: - 入口

    static func runAll() {
        guard !ran else { return }
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        guard AevonPrefs.bool("ProbeV107", default: true) else {
            AevonLog.info("[探针] 设置里已关闭运行时探针（ProbeV107=关），本次跳过（AevonProbeV107）")
            return
        }
        ran = true

        let groups: [(String, () -> Void)] = [
            ("P1 手势管线", { groupPipeline() }),
            ("P2 识别器", { groupRecognizers() }),
            ("P3 启动链", { groupLaunchChain() }),
            ("P4 事件路由", { groupEventRouting() }),
            ("P5 场景浮窗", { groupScenes() }),
            ("P6 配置快照", { groupConfig() })
        ] + AevonProbeP7V114.groups()

        AevonLog.info("[探针] \(groups.count) 组探针已排队：\(Int(startDelay))s 后开始，组间隔 \(groupGap)s；全部走 ObjC @try 兜底（AevonProbeV107 AevonMultiProbeV107 AevonShieldV107）")

        for (index, group) in groups.enumerated() {
            let delay = startDelay + Double(index) * groupGap
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let title = group.0
                let reason = AevonShieldRun { group.1() }
                if let reason = reason, !reason.isEmpty {
                    // 兜住了就是胜利：SpringBoard 活着，而且异常文本本身往往就是答案
                    // （`-[__NSCFString xxx]: unrecognized selector` 会直接点出类名与选择子）。
                    AevonLog.warn("[探针] \(title) 抛异常但已兜住，SB 未受影响：\(reason)（AevonShieldV107）")
                }
            }
        }
    }

    // MARK: - P1 系统手势管线

    /// 找「系统手势到底挂在哪」：类名含 gesture 的类、它们身上带登记/接管语义的方法、
    /// 以及**能拿到活的 manager 实例**（这个最值钱：下一版直接向它登记识别器）。
    private static func groupPipeline() {
        let started = CACurrentMediaTime()
        let names = AevonAllClassNames() ?? []
        let gesture = names.filter { $0.lowercased().contains("gesture") }.sorted()
        AevonLog.info("[探针P1] 全进程类 \(names.count) 个，名字含 gesture 的 \(gesture.count) 个（AevonProbeP1V107）")

        let hooks = ["addgesture", "acquire", "defer", "register", "systemgesture", "shouldreceive", "shouldbegin"]
        var printed = 0
        var lines: [String] = []
        for name in gesture {
            if printed >= 14 { break }
            let methods = AevonMethodNamesForClass(name) ?? []
            let hits = methods.filter { selector in
                let lower = selector.lowercased()
                return hooks.contains { lower.contains($0) }
            }
            guard !hits.isEmpty else { continue }
            printed += 1
            lines.append("\(name) → \(joined(hits, limit: 8))")
        }
        for line in lines {
            AevonLog.info("[探针P1] \(line)")
        }

        // 活的 manager 实例：只对「类名同时含 gesture 与 manager」的类试无参工厂，
        // 且先验类方法存在再发消息（ObjC 侧已做，绝不对着类盲发）。
        var managers: [String] = []
        for name in gesture where name.lowercased().contains("manager") {
            for factory in ["sharedInstance", "_sharedInstance", "sharedManager", "defaultManager", "mainDisplayManager"] {
                guard let object = AevonClassFactoryObject(name, factory) else { continue }
                let cls = AevonSafeClassName(object) ?? "?"
                let two = AevonObjectResponds(object, "addGestureRecognizer:toDisplayWithIdentity:")
                let one = AevonObjectResponds(object, "addGestureRecognizer:")
                let acquire = AevonObjectResponds(object, "acquireSystemGestureDisableAssertionForReason:exceptSystemGestureTypes:")
                managers.append("\(name).\(factory)→\(cls)[two:\(two ? 1 : 0) one:\(one ? 1 : 0) acq:\(acquire ? 1 : 0)]")
                break
            }
        }
        AevonLog.info("[探针P1] 拿到活的手势管理器 \(managers.count) 个：\(joined(managers, limit: 12))（AevonProbeP1V107）")

        // 宿主单例的 ivar 里有没有夹带 gesture 对象（有些版本 manager 不暴露单例，只能从宿主挖）
        for host in ["SBMainWorkspace", "SBMainDisplaySceneManager", "SBSceneManager", "SBIconController", "SBApplicationController"] {
            let ivars = (AevonIvarNamesForClass(host) ?? []).filter { $0.lowercased().contains("gesture") }
            if !ivars.isEmpty {
                AevonLog.info("[探针P1] \(host) 的 gesture 相关 ivar：\(joined(ivars, limit: 10))")
            }
        }
        AevonLog.info("[探针P1] 完成，用时 \(Int((CACurrentMediaTime() - started) * 1000))ms（AevonProbeP1V107）")
    }

    // MARK: - P2 手势识别器宿主

    /// 按**类名聚合**统计所有窗口视图树里的识别器，只打系统私有类（UI 前缀是 UIKit 通用件）。
    /// 聚合而不是逐条打印：V0.1.6 就是逐条打了 637 条、还截断了 587 条，反而看不出重点。
    private static func groupRecognizers() {
        var counts: [String: Int] = [:]
        var windows = 0
        var budget = 2500          // 视图节点预算，防止某个巨型视图树把主线程拖住

        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                windows += 1
                guard let root = window.rootViewController?.view ?? window.subviews.first else { continue }
                walkRecognizers(root, depth: 0, budget: &budget, counts: &counts)
                if budget <= 0 { break }
            }
            if budget <= 0 { break }
        }

        let total = counts.values.reduce(0, +)
        AevonLog.info("[探针P2] 扫 \(windows) 窗 / \(2500 - max(budget, 0)) 个视图节点，识别器 \(total) 个、去重 \(counts.count) 种（AevonProbeP2V107）")

        let sorted = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        var printed = 0
        for (name, count) in sorted {
            if printed >= 22 { break }
            // UIKit 通用识别器（UI* / _UI*）不是我们要找的，跳过
            if name.hasPrefix("UI") || name.hasPrefix("_UI") { continue }
            printed += 1
            AevonLog.info("[探针P2] \(name) × \(count)")
        }
        AevonLog.info("[探针P2] 完成（AevonProbeP2V107）")
    }

    private static func walkRecognizers(_ view: UIView,
                                        depth: Int,
                                        budget: inout Int,
                                        counts: inout [String: Int]) {
        guard budget > 0 else { return }
        budget -= 1
        if let recognizers = view.gestureRecognizers, !recognizers.isEmpty {
            for recognizer in recognizers {
                let name = AevonSafeClassName(recognizer) ?? "?"
                counts[name, default: 0] += 1
            }
        }
        guard depth < 14 else { return }
        for subview in view.subviews {
            walkRecognizers(subview, depth: depth + 1, budget: &budget, counts: &counts)
            if budget <= 0 { return }
        }
    }

    // MARK: - P3 桌面图标启动链

    /// 为「全屏拉起浮窗里的 App 时自动关浮窗」找真正的启动委托方法名。
    /// 已知老选择子 `iconManager:launchIconForIconView:withActions:` 在 17.3.1 不存在，
    /// 这里把候选类的方法名全印出来，下一版按真名精确 hook（不再泛洪 hook）。
    private static func groupLaunchChain() {
        let names = AevonAllClassNames() ?? []
        let targets = names.filter { name in
            name.hasPrefix("SBIcon") || name.contains("IconController") || name.contains("IconView")
        }.sorted()
        AevonLog.info("[探针P3] 图标/启动相关类 \(targets.count) 个（AevonProbeP3V107）")

        let keywords = ["launch", "activate", "open", "select", "tap", "perform"]
        var printed = 0
        for name in targets {
            if printed >= 10 { break }
            let methods = AevonMethodNamesForClass(name) ?? []
            let hits = methods.filter { selector in
                let lower = selector.lowercased()
                return keywords.contains { lower.contains($0) }
            }
            guard !hits.isEmpty else { continue }
            printed += 1
            AevonLog.info("[探针P3] \(name) → \(joined(hits, limit: 10))")
        }

        for host in ["SBApplicationController", "SBWorkspace", "SBMainWorkspace", "SBApplication"] {
            let methods = (AevonMethodNamesForClass(host) ?? []).filter { selector in
                let lower = selector.lowercased()
                return lower.contains("launch") || lower.contains("activate") || lower.contains("open")
            }
            if !methods.isEmpty {
                AevonLog.info("[探针P3] \(host) → \(joined(methods, limit: 10))")
            }
        }
        AevonLog.info("[探针P3] 完成（AevonProbeP3V107）")
    }

    // MARK: - P4 事件路由 / 延迟层

    /// 回答「触摸凭什么从落下那一刻就归 SpringBoard」：
    /// iOS 17 的 HID 事件在 SB 里走 deferring（事件延迟）路由，谁被登记成 recipient 谁先拿。
    /// 这条比「找窗口」更接近本质 —— 窗口只是结果，路由才是原因。
    private static func groupEventRouting() {
        let names = AevonAllClassNames() ?? []
        let targets = names.filter { name in
            let lower = name.lowercased()
            return lower.contains("eventdeferring") || lower.contains("deferring")
                || lower.contains("hidevent") || lower.contains("eventrouter")
                || lower.contains("eventqueue") || lower.contains("hidrouting")
        }.sorted()
        AevonLog.info("[探针P4] 事件路由/延迟相关类 \(targets.count) 个（AevonProbeP4V107）")

        var printed = 0
        for name in targets {
            if printed >= 12 { break }
            let methods = (AevonMethodNamesForClass(name) ?? []).filter { selector in
                let lower = selector.lowercased()
                return lower.contains("defer") || lower.contains("route") || lower.contains("recipient")
                    || lower.contains("gate") || lower.contains("target") || lower.contains("resolve")
            }
            guard !methods.isEmpty else { continue }
            printed += 1
            AevonLog.info("[探针P4] \(name) → \(joined(methods, limit: 10))")
        }
        AevonLog.info("[探针P4] 完成（AevonProbeP4V107）")
    }

    // MARK: - P5 场景与浮窗

    /// 黑窗机制取证：窗口化之后同一个场景被系统拿去全屏呈现，我们的 presenter 就空了。
    /// 这里把「当前场景清单 + 浮窗正在承载谁」一并打出来，和 [窗口] 日志对得上就能确认。
    private static func groupScenes() {
        var index = 0
        for scene in UIApplication.shared.connectedScenes {
            index += 1
            let name = AevonSafeClassName(scene) ?? "?"
            let identifier = AevonRuntime.ivarString(scene, "_sceneIdentifier") ?? "?"
            var windows = -1
            if let windowScene = scene as? UIWindowScene { windows = windowScene.windows.count }
            AevonLog.info("[探针P5] 场景#\(index) \(name) id=\(identifier) state=\(scene.activationState.rawValue) 窗=\(windows)")
        }
        let open = AevonWindowManager.openBundleID ?? "无"
        AevonLog.info("[探针P5] 浮窗承载：\(open)；屏幕 \(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height))（AevonProbeP5V107）")
    }

    // MARK: - P6 配置快照

    /// 一眼看全当前开关，省掉「你开了吗」这类来回确认。
    private static func groupConfig() {
        // V0.1.11（AevonProbeDefaultV111）：每个开关按**自己的**默认值打印。
        // Aevon(78) 的 P6 打出 `EdgeGestureEnabled=0`，而当时右缘通道明明是装着的 ——
        // 因为这里一律用 default:false 读，键未落盘时就会把「默认开」的开关报成 0。
        // 探针报错一个数字，就能让人错判一整个版本。
        let keys: [(String, Bool)] = [("Enabled", false), ("EdgeGestureEnabled", true),
                                      ("RightEdgeTakeover", false), ("RightEdgeShowBand", false),
                                      ("TouchEnabled", true), ("SwitcherLongPress", false),
                                      ("CrashGuard", false), ("LogEnabled", true), ("ProbeV107", false)]
        let snapshot = keys.map { pair in "\(pair.0)=\(AevonPrefs.bool(pair.0, default: pair.1) ? 1 : 0)" }
        AevonLog.info("[探针P6] 开关：\(snapshot.joined(separator: " "))（AevonProbeP6V107 AevonProbeDefaultV111）")

        let zone = AevonTriggerZone.rect(in: UIScreen.main.bounds)
        let bottom = AevonPrefs.double("RingTriggerY", default: AevonTriggerZone.defaultBottomRatio)
        let width = AevonPrefs.double("RingTriggerWidth", default: AevonTriggerZone.defaultWidth)
        let height = AevonPrefs.double("RingTriggerHeight", default: AevonTriggerZone.defaultHeight)
        let bandMode = AevonRightEdge.enabled
            ? "右缘接管带·按下即接管（\(AevonRightEdge.summary(in: UIScreen.main.bounds))；带内起手需距右缘 ≤\(Int(AevonRightEdge.width))pt）"
            : "已关（整段交回 App）"
        AevonLog.info("[探针P6] 热区：底边 \(Int(bottom))% 宽 \(Int(width)) 高 \(Int(height)) → x \(Int(zone.minX))~\(Int(zone.maxX)) y \(Int(zone.minY))~\(Int(zone.maxY))；右缘归口=\(bandMode)，可视化=\(AevonRightEdge.showBand ? "开（按需提示条：开关变化 3 秒 / 接管成功 0.35 秒后自动消失）" : "关（想看范围请打开「显示右缘接管带」）")；系统手势通道 \(AevonSystemGestureV105.isInstalled ? "已装" : "未装")·本版停手不接收触摸（AevonSystemGestureV110 AevonBandHoldMovedV112 AevonBandTakeoverBeganV113 AevonPipelineStandDownV113 AevonRightEdgeTakeoverV115 AevonRightEdgeShowBandV116 AevonNoBandDrawV117 AevonBandHintV117 AevonRightEdgeDefaultV118 AevonRightEdgeMissHintV118）")
    }

    // MARK: - 供手势通道复用（AevonSystemGestureV105 的兜底路径）

    /// 给出手势管理器实例。硬编码类名全落空时，右缘通道从这里要候选。
    ///
    /// 只对「类名同时含 gesture 与 manager」的类试无参工厂，且由 ObjC 侧先验方法存在再发消息 ——
    /// 绝不对着类盲发（盲发会抛 unrecognized selector，Swift 兜不住，SB 当场死）。
    static func resolveManagers() -> [AnyObject] {
        let names = AevonAllClassNames() ?? []
        let candidates = names.filter { name in
            let lower = name.lowercased()
            return lower.contains("gesture") && lower.contains("manager")
        }
        var result: [AnyObject] = []
        for name in candidates {
            for factory in ["sharedInstance", "_sharedInstance", "sharedManager",
                            "defaultManager", "mainDisplayManager"] {
                guard let raw = AevonClassFactoryObject(name, factory) else { continue }
                let object = raw as AnyObject
                if !result.contains(where: { $0 === object }) { result.append(object) }
                break
            }
        }
        return result
    }

    // MARK: - 小工具

    /// 把数组压成一行：最多 `limit` 项，超出补「…共 N 项」。
    private static func joined(_ items: [String], limit: Int) -> String {
        guard !items.isEmpty else { return "（无）" }
        let head = items.prefix(limit).joined(separator: "  ")
        return items.count > limit ? "\(head)  …共 \(items.count) 项" : head
    }
}
