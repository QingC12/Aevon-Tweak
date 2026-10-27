import UIKit
import QuartzCore

/// V0.1.14（AevonProbeP7V114）：**宿主审计五组** —— 只读，不改任何行为。
///
/// 为什么要有这一版：0.1.5~0.1.13 九个版本都在「右缘呼不出 / 呼出了抖音也跟着动」上打转，
/// 每一版都在改**策略**（延迟接管 → 扣移动帧 → 系统手势管线 → 停手），而从没量过一件事：
/// **我们自己的视图，在右缘那个坐标上到底有没有被窗口问过。**
///
/// Stheno 之所以能用「自己的视图/识别器」拿到触摸，是因为它的识别器有真宿主视图
/// （`SBFluidSwitcherGestureManager` / `SBGrabberTongue` / reachability 那些本来就享有
/// 「先于 App 裁决」的识别器）。我们的识别器登记进 `_UISystemGestureManager` 之后
/// 九个版本一次 `began` 都没有 —— 强烈指向「没有宿主，所以没进触摸流」。
///
/// 所以这一版五组，全部只回答「宿主」这一个问题：
///   P7-1 窗口命中链：在三个落点上，按层级从高到低找「哪个窗口认领了这个点」。
///   P7-2 入口宿主：我们自己的入口窗口 / 容器 / App 画面容器三者现在是什么关系，
///        容器的父视图是谁、在兄弟里第几个（这决定它和 App 画面谁先被命中）。
///   P7-3 系统识别器宿主：既有系统手势识别器挂在哪个视图、覆盖哪块区域、delegate 是谁。
///   P7-4 自己的识别器：我们登记的那个识别器有没有宿主视图；两条判据在右缘是否愿意接。
///   P7-5 延迟路由能力：`BKSHIDEventDeferringPredicate` 到底能不能表达「几何区域」
///        （能 → 有第三条路；不能 → 那条路直接判死，不再浪费版本）。
///
/// 硬纪律（与 P1~P6 同一套，不许破）：
///   · 每组从 `AevonShieldRun`（ObjC @try）里过一道，Swift 的 do/catch 捕不到
///     `doesNotRecognizeSelector:`，只有 @try 能；
///   · 类名 / ivar / 识别器扫描全部在 ObjC 侧（`AevonProbeSupport.m`），
///     Swift 不对陌生对象做任何 `as?`；
///   · 只读：不 swizzle、不加识别器、不改 delegate、不写任何文件。
enum AevonProbeP7V114 {

    /// 三个落点：右缘中部（问题现场）、热区内（一直干净的那条）、屏幕中心（对照）。
    private static let probePoints: [(String, CGPoint)] = [
        ("右缘中部", CGPoint(x: 424, y: 400)),
        ("热区内", CGPoint(x: 424, y: 750)),
        ("屏幕中心", CGPoint(x: 215, y: 466))
    ]

    static func groups() -> [(String, () -> Void)] {
        return [
            ("P7-1 窗口命中链", { windowHitChain() }),
            ("P7-2 入口宿主", { entryHost() }),
            ("P7-3 系统识别器宿主", { systemRecognizerHosts() }),
            ("P7-5 延迟路由能力", { deferringCapability() })
        ]
    }

    // MARK: - P7-1 窗口命中链

    /// 「哪个窗口认领了这个点」—— 只打真命中的前两个窗口层级，避免 60 行噪音。
    ///
    /// 这一组是整版的地基：如果右缘那个点最高命中落在 App 场景的宿主上，
    /// 说明我们的视图根本不在命中链里（改多少策略都没用）；
    /// 如果最高命中落在我们自己的窗口/视图上，那问题就在别处。
    private static func windowHitChain() {
        let started = CACurrentMediaTime()
        var sceneCount = 0
        var allWindows: [UIWindow] = []
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            sceneCount += 1
            allWindows.append(contentsOf: scene.windows)
        }
        let ordered = allWindows.sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }

        for (label, point) in probePoints {
            var printed = 0
            for window in ordered {
                if printed >= 2 { break }
                let windowName = AevonSafeClassName(window) ?? "?"
                let level = Int(window.windowLevel.rawValue)
                let hidden = window.isHidden
                let alpha = window.alpha
                var hitName = "nil"
                var chain = "—"
                let reason = AevonShieldRun {
                    let local = window.convert(point, from: nil)
                    if let hit = window.hitTest(local, with: nil) {
                        hitName = AevonSafeClassName(hit) ?? "?"
                        chain = AevonViewHostChain(hit, 4) ?? "?"
                    }
                }
                if let reason = reason, !reason.isEmpty {
                    AevonLog.info("[探针P7-1] \(label) \(windowName) 命中测试抛异常已兜住：\(reason)（AevonWindowHitV114）")
                    continue
                }
                if hitName == "nil" { continue }
                printed += 1
                AevonLog.info("[探针P7-1] \(label)(\(Int(point.x)),\(Int(point.y))) 候选#\(printed) 窗口=\(windowName) level=\(level) hidden=\(hidden ? 1 : 0) alpha=\(String(format: "%.2f", alpha)) 命中=\(hitName) 链=\(chain)（AevonWindowHitV114）")
            }
            if printed == 0 {
                AevonLog.info("[探针P7-1] \(label)(\(Int(point.x)),\(Int(point.y))) 没有任何窗口认领该点（AevonWindowHitV114）")
            }
        }
        AevonLog.info("[探针P7-1] 扫 \(sceneCount) 个场景 / \(ordered.count) 个窗口，\(probePoints.count) 个落点，用时 \(Int((CACurrentMediaTime() - started) * 1000))ms（AevonProbeP7V114）")
    }

    // MARK: - P7-2 入口宿主

    /// 我们自己的宿主结构：窗口还在不在、容器挂在谁下面、在兄弟里第几个。
    private static func entryHost() {
        let snapshot = AevonEntryHost.debugHostSnapshot
        for line in snapshot.split(separator: "\n") {
            AevonLog.info("[探针P7-2] \(line)（AevonHostAuditV114）")
        }
        AevonLog.info("[探针P7-2] 完成（AevonProbeP7V114 AevonHostAuditV114）")
    }

    // MARK: - P7-3 系统识别器宿主

    /// 既有系统手势识别器在哪里 —— Stheno 借的就是它们。
    private static func systemRecognizerHosts() {
        let candidates = ["SBFluidSwitcherGestureManager", "SBGrabberTongue",
                          "SBReachabilityManager", "SBMainDisplaySystemGestureManager",
                          "_UISystemGestureManager"]
        for name in candidates {
            var found = false
            for factory in ["sharedInstance", "mainDisplayManager", "sharedManager"] {
                guard let object = AevonClassFactoryObject(name, factory) else { continue }
                let manager = object as AnyObject
                found = true
                let managerName = AevonSafeClassName(manager) ?? name
                AevonLog.info("[探针P7-3] \(managerName).\(factory) ivar：\(AevonObjectIvarSummary(manager) ?? "?")（AevonRecognizerHostV114）")
                let lines = AevonDescribeRecognizersOfObject(manager) ?? []
                if lines.isEmpty {
                    AevonLog.info("[探针P7-3] \(managerName) 身上没挖到识别器（可能挂在它的子管理器里）（AevonRecognizerHostV114）")
                } else {
                    for (index, line) in lines.prefix(14).enumerated() {
                        AevonLog.info("[探针P7-3] \(managerName)#\(index) \(line)（AevonRecognizerHostV114）")
                    }
                }
            }
            if !found {
                AevonLog.info("[探针P7-3] \(name) 取不到活实例（AevonRecognizerHostV114）")
            }
        }
        AevonLog.info("[探针P7-3] 完成（AevonProbeP7V114 AevonRecognizerHostV114）")
    }

    // MARK: - P7-5 延迟路由能力

    /// `BKSHIDEventDeferringPredicate` 能不能表达几何区域。
    ///
    /// 能 → 有机会在 BackBoard 层按「右缘」筛事件（真正「先于 App 裁决」）；
    /// 不能 → 只能整屏延迟（等于让手机没法用），这条路当场判死。
    private static func deferringCapability() {
        let names = ["BKSHIDEventDeferringPredicate", "BKSHIDEventDeferringRule",
                     "BKSHIDEventDeferringEnvironment", "BKSHIDEventDeferringToken",
                     "BKSHIDEventDeliveryManager", "BKSHIDEventDeliveryPolicyObserver"]
        for name in names {
            let methods = AevonMethodNamesForClass(name) ?? []
            if methods.isEmpty {
                AevonLog.info("[探针P7-5] \(name) 无方法（类不存在或本进程不可见）（AevonDeferProbeV114）")
                continue
            }
            var instanceMethods: [String] = []
            var classMethods: [String] = []
            for selector in methods {
                if selector.hasPrefix("+") {
                    classMethods.append(String(selector.dropFirst()))
                } else {
                    instanceMethods.append(selector)
                }
            }
            AevonLog.info("[探针P7-5] \(name) 实例 \(instanceMethods.count) 个：\(instanceMethods.prefix(12).joined(separator: " "))（AevonDeferProbeV114）")
            AevonLog.info("[探针P7-5] \(name) 类方法 \(classMethods.count) 个：\(classMethods.prefix(12).joined(separator: " "))（AevonDeferProbeV114）")
        }
        AevonLog.info("[探针P7-5] 完成（AevonProbeP7V114 AevonDeferProbeV114）")
    }
}
