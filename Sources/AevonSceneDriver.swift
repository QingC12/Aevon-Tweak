import Foundation
import UIKit

/*
 * V0.0.68（AevonSceneDriverP1）：真小胖屏 P1 —— 自建场景概念验证。
 *
 * 依据（全部实证，见 stheno-逆向分析/analysis/）：
 *   · ScreenCore 2.1.0 逆向报告：小胖屏 = SB 侧为 App 新建正经主场景，
 *     创建时把小窗尺寸烙进 FBSSceneParameters（dc + sceneFrame + orientation），
 *     App 按小窗真重排（底栏天然在场、元素 1:1、无裁切）。
 *   · 本机 P0 探测 5/5 全过（Aevon(60) 日志）：SBDeviceApplicationSceneEntity 四段 init、
 *     FBSSceneParameters、FBSceneManager createSceneWithDefinition:initialParameters:、
 *     FBApplicationProcessLaunchTransaction、FBSDisplayConfiguration 全部存在。
 *
 * P1 目标：**只验证「创建链 + App 按小尺寸重排」**，不做显示挂层（P2 的事）、
 * 不碰现有浮窗。全程独立异常隔离，任何一步失败只写日志，绝不影响现有功能。
 *
 * 触发：设置页「真小胖屏 P1：自建场景实验」开关从关 → 开，
 * 延迟 5 秒对白名单 App（设置）执行一次；执行过后置位防重入，重开开关可再次触发。
 */

@objc(AevonSceneDriver)
final class AevonSceneDriver: NSObject {

    static let shared = AevonSceneDriver()

    /// 白名单：P1 只对「设置」实验（系统 App，崩溃代价最小、可观察性最好）
    static let experimentBundleID = "com.apple.Preferences"
    /// P1 参考画布：与浮窗 0.600 胖窗同比例
    static let canvasSize = CGSize(width: 266, height: 458)

    private var ranForThisToggle = false
    private var running = false

    // MARK: - V0.0.75（AevonCrashFuseV75）：崩溃熔断

    /// 本次启动是否已被熔断（上一轮 P1 把 SpringBoard 搞崩过）。
    static var crashFused = false

    /// 启动时调用一次（Bootstrap 早期）：检查上一轮 P1 是否留下未完成的面包屑。
    ///
    /// Aevon(67)：P1 第 4 步的诊断代码 `perform` 一个返回 BOOL 的方法后
    /// `String(describing:)`，把 1 当对象指针读野 isa → SpringBoard 退出（自动注销）。
    /// respring 不会清文件，所以「残留面包屑」= 上一轮死在这一步的铁证。
    /// 一旦读到残留，立刻把开关写成关，避免「每次开机都崩一次」的死循环。
    static func consumeCrashFuse() {
        let raw = AevonCrumbRead()
        let crumb: String = (raw != nil) ? String(cString: raw!) : ""
        AevonCrumbClear()
        guard !crumb.isEmpty else { return }
        crashFused = true
        AevonPrefs.set("AevonTrueResizeP1", false)
        AevonLog.warn("[场景] P1 崩溃熔断：上次实验崩在「\(crumb)」这一环，本次启动已自动关闭 P1 开关（要再试请在设置里把开关重开一次，会重新授权一轮）（AevonCrashFuseV75）")
    }

    /// prefschanged 回调入口：开关从关到开才触发（5s 错峰，给设置页留写盘时间）
    func maybeRunExperiment() {
        guard AevonPrefs.bool("AevonTrueResizeP1", default: false) else {
            ranForThisToggle = false
            return
        }
        /* 熔断期间不自动跑；但如果是用户**手动重新打开**开关（熔断时我们写的是关，
         * 现在又是开），视为「用户明确要求再试一次」，解除熔断放行一轮。 */
        if AevonSceneDriver.crashFused {
            AevonSceneDriver.crashFused = false
            AevonLog.info("[场景] P1 熔断已解除：用户重新打开了开关，本轮允许再试一次（AevonCrashFuseV75）")
        }
        guard !ranForThisToggle, !running else { return }
        ranForThisToggle = true
        AevonLog.info("[场景] P1 实验已排程：5 秒后对 \(AevonSceneDriver.experimentBundleID) 按小窗尺寸自建场景（AevonSceneDriverP1）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.runExperiment()
        }
    }

    /// 统一异常隔离壳
    private func tryRun(_ tag: String, _ body: @escaping () -> Void) {
        var exName: NSString? = nil
        var exReason: NSString? = nil
        AevonTryExecute(body, &exName, &exReason)
        if let n = exName {
            AevonLog.warn("[场景] P1 \(tag) 抛异常（\(n): \(exReason ?? "无")），已拦截（AevonSceneDriverP1）")
        }
    }

    // MARK: - 实验主体

    private func runExperiment() {
        guard !running else { return }
        running = true
        AevonLog.info("[场景] P1 实验开始：目标画布 \(Int(AevonSceneDriver.canvasSize.width))x\(Int(AevonSceneDriver.canvasSize.height))（AevonSceneDriverP1）")
        AevonCrumbWrite("开始")
        self.step1SceneManager()
        /* V0.0.75：step1~step5 是一条同步链，能崩的都在这里。
         * 走完（无论成败）就撤面包屑 —— 之后异步的取证段只做只读 KVC，不再有风险。 */
        AevonCrumbClear()
        self.running = false
    }

    // MARK: 第 1 步：FBSceneManager 实例

    private func step1SceneManager() {
        AevonCrumbWrite("第1步-场景管理器")
        var manager: NSObject? = nil
        tryRun("第1步") {
            manager = AevonSceneDriver.findSceneManager()
        }
        guard let manager else {
            AevonLog.warn("[场景] P1 第 1 步失败：拿不到 FBSceneManager 实例（AevonSceneDriverP1）")
            return
        }
        AevonLog.info("[场景] P1 第 1 步通过：FBSceneManager = \(AevonSafeClassName(manager))（AevonSceneDriverP1）")
        self.step2MainDisplayConfig(manager: manager)
    }

    static func findSceneManager() -> NSObject? {
        let attempts: [(String, String)] = [
            ("FBSceneManager", "sharedInstance"),
            ("FBSceneManager", "sharedManager"),
            ("FBSceneManager", "mainSceneManager"),
            ("FBSceneManager", "defaultManager"),
        ]
        for (clsName, selName) in attempts {
            if let obj = tryShared(classNamed: clsName, selector: selName) { return obj }
        }
        if let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance") {
            for sel in ["sceneManager", "workspaceSceneCoordinator", "sceneCoordinator"] {
                if let m = AevonSafeCallObject(ws, sel) as? NSObject {
                    if AevonSafeClassName(m).contains("SceneManager") { return m }
                }
            }
        }
        return nil
    }

    private static func tryShared(classNamed: String, selector: String) -> NSObject? {
        guard let cls = NSClassFromString(classNamed) as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString(selector)
        guard cls.responds(to: sel) else { return nil }
        return AevonSafeCallObject(cls, sel) as? NSObject
    }

    // MARK: 第 2 步：主屏显示配置母本

    private func step2MainDisplayConfig(manager: NSObject) {
        AevonCrumbWrite("第2步-主屏dc")
        var dc: NSObject? = nil
        tryRun("第2步") {
            dc = AevonSceneDriver.findMainDisplayConfiguration(manager: manager)
        }
        if let dc {
            AevonLog.info("[场景] P1 第 2 步通过：主屏 dc 母本 = \(AevonSafeClassName(dc))（AevonSceneDriverP1）")
        } else {
            AevonLog.warn("[场景] P1 第 2 步降级：没拿到主屏 dc 母本，改走「从零构造小窗 dc」（ivar 直写，日志如实记录）（AevonSceneDriverP1）")
        }
        self.step3Application(manager: manager, mainDC: dc)
    }

    /// 主屏 dc 多路探测（ScreenCore 的 sc_mainDisplayConfiguration 对应物）
    /// V0.0.69 新增：FBSceneManager enumerateScenes 路线（P0 dump 实锤管理器上有
    /// enumerateScenesWithBlock:/scenesPassingTest:）+ 失败时诊断输出，帮助下一轮定位。
    static func findMainDisplayConfiguration(manager: NSObject) -> NSObject? {
        for sel in ["mainDisplayConfiguration", "displayConfiguration", "primaryDisplayConfiguration"] {
            if manager.responds(to: NSSelectorFromString(sel)),
               let r = AevonSafeCallObject(manager, sel) as? NSObject {
                return r
            }
        }
        // 路线 B（新）：遍历管理器持有的全部场景，取任一 settings.displayConfiguration
        let enumSel = NSSelectorFromString("enumerateScenesWithBlock:")
        if manager.responds(to: enumSel),
           let enumMethod = class_getInstanceMethod(type(of: manager), enumSel) {
            var found: NSObject? = nil
            let block: @convention(block) (NSObject) -> Void = { scene in
                if found == nil, let dc = AevonSceneDriver.displayConfigFromScene(scene) {
                    found = dc
                }
            }
            typealias EnumFn = @convention(c) (NSObject, Selector, @convention(block) (NSObject) -> Void) -> Void
            unsafeBitCast(method_getImplementation(enumMethod), to: EnumFn.self)(manager, enumSel, block)
            if let found { return found }
        }
        for (clsName, selName) in [("SBFDisplayManager", "sharedInstance"), ("SBFDisplayManager", "mainDisplayManager")] {
            if let dm = tryShared(classNamed: clsName, selector: selName) {
                for sel in ["mainDisplayConfiguration", "displayConfiguration", "mainScreenDisplayConfiguration", "mainSBFDisplay"] {
                    if dm.responds(to: NSSelectorFromString(sel)),
                       let r = AevonSafeCallObject(dm, sel) as? NSObject {
                        if AevonSafeClassName(r).contains("DisplayConfiguration") { return r }
                        // SBFDisplay 之类再向下钻一层
                        for sel2 in ["displayConfiguration", "mainDisplayConfiguration"] {
                            if r.responds(to: NSSelectorFromString(sel2)),
                               let r2 = AevonSafeCallObject(r, sel2) as? NSObject,
                               AevonSafeClassName(r2).contains("DisplayConfiguration") {
                                return r2
                            }
                        }
                    }
                }
            }
        }
        if let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance") {
            for sel in ["mainScene", "mainWorkspaceScene", "scene"] {
                if ws.responds(to: NSSelectorFromString(sel)),
                   let scene = AevonSafeCallObject(ws, sel) as? NSObject,
                   let dc = displayConfigFromScene(scene) {
                    return dc
                }
            }
        }
        return nil
    }

    /// 从 FBScene 的 settings 里找 FBSDisplayConfiguration
    static func displayConfigFromScene(_ scene: NSObject) -> NSObject? {
        if scene.responds(to: NSSelectorFromString("settings")),
           let settings = AevonSafeCallObject(scene, "settings") as? NSObject {
            for sel in ["displayConfiguration", "displayConfigurationLayout"] {
                if settings.responds(to: NSSelectorFromString(sel)),
                   let r = AevonSafeCallObject(settings, sel) as? NSObject,
                   AevonSafeClassName(r).contains("DisplayConfiguration") {
                    return r
                }
            }
        }
        return nil
    }

    // MARK: 第 3 步：目标 App 的 SBApplication

    private func step3Application(manager: NSObject, mainDC: NSObject?) {
        AevonCrumbWrite("第3步-SBApplication")
        var app: NSObject? = nil
        let diag = StringBox()
        tryRun("第3步") {
            // V0.0.69 修复：V68 用的类方法是 "sharedApplicationController" —— 这个选择子
            // 在 SBApplicationController 上不存在（经典路径是 sharedInstance），
            // responds(to:) 恒 false → app 恒 nil → 第 3 步必然失败。
            let ctrl = AevonSceneDriver.findApplicationController(diag: diag)
            if let ctrl {
                for selName in ["applicationWithBundleIdentifier:", "applicationWithDisplayIdentifier:", "runningApplicationWithBundleIdentifier:"] {
                    let sel = NSSelectorFromString(selName)
                    if ctrl.responds(to: sel),
                       let a = AevonSafeCallObject1(ctrl, selName, AevonSceneDriver.experimentBundleID) as? NSObject {
                        app = a
                        break
                    }
                }
            }
        }
        if let app {
            AevonLog.info("[场景] P1 第 3 步通过：SBApplication = \(AevonSafeClassName(app))（AevonSceneDriverP1）")
        } else {
            let d = diag.items.isEmpty ? "" : "｜诊断：\(diag.items.joined(separator: "；"))"
            AevonLog.warn("[场景] P1 第 3 步失败：拿不到 \(AevonSceneDriver.experimentBundleID) 的 SBApplication\(d)（AevonSceneDriverP1）")
            return
        }
        guard let app else { return }
        self.step4SceneEntity(manager: manager, app: app, mainDC: mainDC)
    }

    /// @escaping 闭包可变捕获用的小盒子
    final class StringBox {
        var items: [String] = []
    }

    /// SBApplicationController 多路获取 + 失败诊断（方法表取样）
    static func findApplicationController(diag: StringBox) -> NSObject? {
        let cls = NSClassFromString("SBApplicationController")
        guard let cls else {
            diag.items.append("SBApplicationController 类不存在")
            return nil
        }
        for selName in ["sharedInstance", "sharedApplicationController", "defaultController", "sharedController"] {
            let sel = NSSelectorFromString(selName)
            if (cls as AnyObject).responds(to: sel),
               let c = AevonSafeCallObject(cls as AnyObject, selName) as? NSObject {
                return c
            }
        }
        // 全部失败：取样类方法名（下一轮按真实名补）
        var names: [String] = []
        var count: UInt32 = 0
        if let metaCls = objc_getMetaClass("SBApplicationController") as? AnyClass,
           let list = class_copyMethodList(metaCls, &count) {
            for i in 0..<Int(count) {
                let n = NSStringFromSelector(method_getName(list[i]))
                if n.lowercased().contains("shared") || n.lowercased().contains("default") { names.append("+" + n) }
            }
        }
        diag.items.append(names.isEmpty ? "类方法里无 sharedInstance/default 系" : "类方法候选=\(names.prefix(5).joined(separator: ","))")
        return nil
    }

    // MARK: 第 4 步：SBDeviceApplicationSceneEntity 构造（V0.0.71 诊断增强版）

    /// V0.0.72：读对象型 ivar（V62 教训：先查类型编码 '@' 才可用 object_getIvar）
    static func readObjectIvar(_ obj: NSObject, _ name: String) -> NSObject? {
        guard let ivar = class_getInstanceVariable(type(of: obj) as AnyClass, name),
              let enc = ivar_getTypeEncoding(ivar), String(cString: enc).hasPrefix("@") else { return nil }
        return object_getIvar(obj, ivar) as? NSObject
    }

    /// 多路找 sceneHandleProvider —— 四段 init 有断言 `sceneHandleProvider != nil`
    /// （Aevon(65) 实锤异常：Invalid parameter not satisfying: sceneHandleProvider）。
    ///
    /// ScreenCore 逆向实锤（SCSystemSceneDriver.sc_mainDisplaySceneHandleProvider）：
    /// provider 就是 **SBMainWorkspace 本体**（iOS 17 上 SBMainWorkspace 实现了
    /// FBSSceneHandleProvider 协议），其次是 FBSceneManager 本体。
    private static func findSceneHandleProvider() -> NSObject? {
        // 路线 1：SBMainWorkspace 实例（本体即 provider，ScreenCore 同款）
        if let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance") {
            // 若 workspace 上有 sceneHandleProvider 属性则优先用属性值
            for sel in ["sceneHandleProvider", "handleProvider"] {
                let s = NSSelectorFromString(sel)
                if ws.responds(to: s),
                   let r = AevonSafeCallObject(ws, s) as? NSObject {
                    return r
                }
            }
            return ws
        }
        // 路线 2：FBSceneManager 本体
        if let m = tryShared(classNamed: "FBSceneManager", selector: "sharedInstance") {
            return m
        }
        // 路线 3：FBSSceneHandleProvider 自身的 sharedInstance 系
        for selName in ["sharedInstance", "defaultProvider", "sharedProvider"] {
            if let p = tryShared(classNamed: "FBSSceneHandleProvider", selector: selName) { return p }
        }
        return nil
    }

    // MARK: - V0.0.73：provider 协议方法解析（第 4 步唯一死因）

    /// 四段 init 内部真正会调用的协议方法（Aevon(66) 实锤异常）：
    /// `-[SBMainWorkspace sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:]:
    ///   unrecognized selector` —— provider 断言过了，但方法没实现。
    static let entityProviderSelector = "sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:"
    /// 代理转发目标（响应「下划线变体」的真实对象，通常是 SBMainWorkspace 本体）
    static var proxyForwardTarget: NSObject?

    /// 全类扫描：哪些类实现了某个选择子（只在候选全失败时跑，日志留证）
    static func classesResponding(to selName: String, limit: Int = 6) -> [String] {
        var out: [String] = []
        let sel = NSSelectorFromString(selName)
        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count) else { return out }
        defer { free(UnsafeMutableRawPointer(list)) }
        for i in 0..<Int(count) {
            let cls: AnyClass = list[i]
            if class_getInstanceMethod(cls, sel) != nil {
                out.append(NSStringFromClass(cls))
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// 造一个运行时子类，实现四段 init 需要的那个协议方法，转调目标对象的「下划线变体」。
    static func ensureProviderProxy() -> NSObject? {
        let clsName = "AevonSceneProviderProxy"
        if let existing = NSClassFromString(clsName) as? NSObject.Type {
            return existing.init()
        }
        guard let newCls = objc_allocateClassPair(NSObject.self, clsName, 0) else { return nil }
        let sel = NSSelectorFromString(entityProviderSelector)
        /* V0.0.75：参数一律 optional —— objc 侧传 nil 时，`AnyObject` 形参会因
         * 隐式解包 nil 而崩（编译器在 ABI 层仍是裸指针，AnyObject? 与之等价）。
         * 同时 `type(of:)` 换 object_getClass：不经过 Swift 元类型机制。 */
        let block: @convention(block) (AnyObject?, AnyObject?, Bool, AnyObject?) -> AnyObject? = { _, app, create, role in
            guard let target = AevonSceneDriver.proxyForwardTarget else { return nil }
            let alt = NSSelectorFromString("_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:")
            guard let m = class_getInstanceMethod(object_getClass(target), alt) else { return nil }
            typealias Fn = @convention(c) (NSObject, Selector, NSObject?, Bool, NSObject?) -> Unmanaged<NSObject>?
            let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
            return fn(target, alt, app as? NSObject, create, role as? NSObject)?.takeUnretainedValue()
        }
        let imp = imp_implementationWithBlock(block)
        class_addMethod(newCls, sel, imp, "@@:@B@")
        objc_registerClassPair(newCls)
        return (newCls as? NSObject.Type)?.init()
    }

    /// 解析 provider：先找**直接实现协议方法**的实例，其次用代理转调下划线变体，
    /// 最后全类扫描留证（下一轮即使仍失败，日志里也有「谁实现了」的答案）。
    private static func findSceneEntityProvider(diag: StringBox) -> NSObject? {
        let sel = NSSelectorFromString(entityProviderSelector)
        var candidates: [NSObject] = []
        var labels: [String] = []
        func add(_ obj: NSObject?, _ label: String) {
            guard let obj else { return }
            candidates.append(obj)
            labels.append(label)
        }
        let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance")
        add(ws, "SBMainWorkspace")
        var coord: NSObject? = nil
        if let ws {
            for s in ["sceneManagerCoordinator", "sceneManager"] {
                let ss = NSSelectorFromString(s)
                if ws.responds(to: ss), let r = AevonSafeCallObject(ws, ss) as? NSObject {
                    coord = r
                    add(r, "WS.\(s)")
                    break
                }
            }
        }
        if coord == nil {
            coord = tryShared(classNamed: "SBSceneManagerCoordinator", selector: "sharedInstance")
            add(coord, "SBSceneManagerCoordinator")
        }
        if let coord {
            for s in ["mainDisplaySceneManager", "mainWindowSceneManager", "mainSwitcherSceneManager"] {
                let ss = NSSelectorFromString(s)
                if coord.responds(to: ss), let r = AevonSafeCallObject(coord, ss) as? NSObject {
                    add(r, "Coord.\(s)")
                }
            }
        }
        // 1) 直接响应协议方法
        for (i, obj) in candidates.enumerated() where obj.responds(to: sel) {
            diag.items.append("provider=\(labels[i])（响应协议）")
            return obj
        }
        // 2) 响应下划线变体 → 代理转调
        let altSel = NSSelectorFromString("_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:")
        for (i, obj) in candidates.enumerated() where obj.responds(to: altSel) {
            proxyForwardTarget = obj
            if let proxy = ensureProviderProxy() {
                diag.items.append("provider=代理→\(labels[i])._sceneIdentity…")
                return proxy
            }
        }
        // 3) 全类扫描留证 + 能用 sharedInstance 取到的直接上
        let exact = classesResponding(to: entityProviderSelector)
        let alt = classesResponding(to: "_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:")
        diag.items.append("实现类=\(exact.isEmpty ? "无" : exact.joined(separator: ","))")
        diag.items.append("下划线实现类=\(alt.isEmpty ? "无" : alt.joined(separator: ","))")
        for name in exact {
            guard let cls = NSClassFromString(name) else { continue }
            for selName in ["sharedInstance", "sharedManager", "defaultManager"] {
                let s = NSSelectorFromString(selName)
                if (cls as AnyObject).responds(to: s),
                   let inst = AevonSafeCallObject(cls as AnyObject, selName) as? NSObject,
                   inst.responds(to: sel) {
                    diag.items.append("provider=扫描取到 \(name)")
                    return inst
                }
            }
        }
        diag.items.append("provider=nil（候选=\(labels.joined(separator: ","))）")
        return nil
    }

    private static func findDisplayIdentity(mainDC: NSObject?) -> NSObject? {
        // 路线 1（V0.0.72）：主屏 dc 母本的 _identity ivar（P0 dump 实锤存在）
        if let mainDC, let id = readObjectIvar(mainDC, "_identity") {
            return id
        }
        // 路线 2：主屏 SBFDisplay 的 displayIdentity
        if let dm = tryShared(classNamed: "SBFDisplayManager", selector: "sharedInstance") {
            for sel in ["mainDisplay", "mainSBFDisplay"] {
                let s = NSSelectorFromString(sel)
                if dm.responds(to: s),
                   let d = AevonSafeCallObject(dm, s) as? NSObject {
                    let s2 = NSSelectorFromString("displayIdentity")
                    if d.responds(to: s2),
                       let id = AevonSafeCallObject(d, s2) as? NSObject {
                        return id
                    }
                }
            }
        }
        // 路线 3：主场景 settings 上的 displayIdentity
        if let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance") {
            for sel in ["mainScene", "mainWorkspaceScene"] {
                let s = NSSelectorFromString(sel)
                if ws.responds(to: s),
                   let scene = AevonSafeCallObject(ws, s) as? NSObject,
                   let settings = displaySettings(scene),
                   settings.responds(to: NSSelectorFromString("displayIdentity")),
                   let id = AevonSafeCallObject(settings, "displayIdentity") as? NSObject {
                    return id
                }
            }
        }
        return nil
    }

    private static func displaySettings(_ scene: NSObject) -> NSObject? {
        if scene.responds(to: NSSelectorFromString("settings")),
           let s = AevonSafeCallObject(scene, "settings") as? NSObject {
            return s
        }
        return nil
    }

    private func step4SceneEntity(manager: NSObject, app: NSObject, mainDC: NSObject?) {
        /* V0.0.75：进第 4 步先落面包屑 —— Aevon(67) 就崩在这里（BOOL 被当成对象指针），
         * 下次若还崩，启动日志会直接指名道姓。 */
        AevonCrumbWrite("第4步-场景实体")
        var entity: NSObject? = nil
        let diag = StringBox()
        tryRun("第4步") {
            guard let cls = NSClassFromString("SBDeviceApplicationSceneEntity") else {
                diag.items.append("类不存在")
                return
            }
            guard let alloced = AevonSceneDriver.allocObj(cls) else {
                diag.items.append("alloc 失败")
                return
            }
            /* V0.0.75（AevonCrashFuseV75）：这里原来写的是
             *   let r = app.perform(sel)?.takeUnretainedValue()
             *   diag.items.append("app.\(s)=\(String(describing: r))")
             * 而 isRunning 返回 BOOL —— `perform:` 把 1 包装成「对象指针」，
             * `String(describing:)` 随即读野 isa（崩溃栈里的
             * swift_dynamicCast / swift_getObjectType / _CF_forwarding_prep_0，
             * 垃圾地址 0xffff8001b301dd2c），SpringBoard 当场退出 = 用户看到的自动注销。
             * 现在只要「App 是否在跑」这个布尔，绝不碰对象指针。 */
            for s in ["isRunning", "running", "isLaunchable"] {
                var ok: ObjCBool = false
                if app.responds(to: NSSelectorFromString(s)) {
                    let v = AevonSafeBoolCall(app, s, &ok)
                    if ok.boolValue { diag.items.append("app.\(s)=\(v ? 1 : 0)") }
                }
            }
            let provider = AevonSceneDriver.findSceneEntityProvider(diag: diag)
            let displayID = AevonSceneDriver.findDisplayIdentity(mainDC: mainDC)
            diag.items.append("displayID=\(AevonSafeClassName(displayID))")
            // 依次尝试 P0 方法表里确认存在的全部 init 候选
            typealias Init4 = @convention(c) (NSObject, Selector, NSObject, Bool, NSObject?, NSObject?) -> Unmanaged<NSObject>?
            typealias Init3 = @convention(c) (NSObject, Selector, NSObject, NSObject?, NSObject?) -> Unmanaged<NSObject>?
            typealias Init5 = @convention(c) (NSObject, Selector, NSObject, NSObject, NSObject?, NSObject?, NSObject?) -> Unmanaged<NSObject>?
            let candidates: [(String, Int)] = [
                ("initWithApplication:generatingNewPrimarySceneIfRequired:sceneHandleProvider:displayIdentity:", 4),
                ("initWithApplication:sceneHandleProvider:displayIdentity:", 3),
                ("initWithApplication:uniqueIdentifier:targetContentIdentifier:sceneHandleProvider:displayIdentity:", 5),
            ]
            for (selName, argc) in candidates {
                let sel = NSSelectorFromString(selName)
                let short = selName.components(separatedBy: ":").count > 1
                    ? selName.components(separatedBy: ":")[1] : selName
                guard let method = class_getInstanceMethod(type(of: alloced), sel) else {
                    diag.items.append("无方法 \(short)")
                    continue
                }
                let imp = method_getImplementation(method)
                var attempt: NSObject? = nil
                /* V0.0.73：每个候选**独立异常隔离 + 各自 fresh alloc**。
                 * 旧实现整段共用一个 @try：第一个候选抛异常（Aevon(66)：provider 不响应
                 * sceneIdentityForApplication…）就把后面所有候选一起跳过了。 */
                self.tryRun("第4步-\(short)") {
                    guard let fresh = AevonSceneDriver.allocObj(cls) else { return }
                    var result: Unmanaged<NSObject>? = nil
                    switch argc {
                    case 4:
                        let fn = unsafeBitCast(imp, to: Init4.self)
                        result = fn(fresh, sel, app, true, provider, displayID)
                    case 3:
                        let fn = unsafeBitCast(imp, to: Init3.self)
                        result = fn(fresh, sel, app, provider, displayID)
                    case 5:
                        guard let uid = AevonSafeCallObject(app, "uniqueIdentifier") as? NSObject else { return }
                        let fn = unsafeBitCast(imp, to: Init5.self)
                        result = fn(fresh, sel, app, uid, nil, provider, displayID)
                    default:
                        return
                    }
                    if let r = result { attempt = r.takeRetainedValue() as NSObject? }
                }
                if let attempt {
                    entity = attempt
                    diag.items.append("成功=\(short)")
                    break
                }
                diag.items.append("返回nil=\(short)")
            }
        }
        guard let entity else {
            let d = diag.items.isEmpty ? "" : "｜诊断：\(diag.items.joined(separator: "；"))"
            AevonLog.warn("[场景] P1 第 4 步失败：SBDeviceApplicationSceneEntity 全部候选 init 都构造不出实体\(d)（AevonSceneDriverP1 AevonSceneP1V73）")
            return
        }
        AevonLog.info("[场景] P1 第 4 步通过：sceneEntity 已构造（AevonSceneDriverP1 AevonSceneP1V73）")
        self.step5Create(manager: manager, entity: entity, mainDC: mainDC)
    }

    // MARK: 第 5 步：场景设置（烙 dc + 小窗 frame）+ createScene

    private func step5Create(manager: NSObject, entity: NSObject, mainDC: NSObject?) {
        AevonCrumbWrite("第5步-创建场景")
        var created: NSObject? = nil
        tryRun("第5步") {
            let definition = AevonSafeCallObject(entity, "sceneDefinition") as? NSObject
            guard let definition else {
                AevonLog.warn("[场景] P1 第 5 步：entity 上拿不到 sceneDefinition（AevonSceneDriverP1）")
                return
            }
            let settings = self.makeMutableSettings()
            self.bakeGeometry(settings: settings, mainDC: mainDC)
            // 小窗 dc 单独备好：definition 路线（ScreenCore 正路）和 settings 路线共用
            var smallDC: NSObject? = nil
            if let mainDC {
                smallDC = AevonSceneDriver.smallDisplayConfig(from: mainDC, canvas: AevonSceneDriver.canvasSize)
            }
            // V0.0.71：ScreenCore 正路 —— 在 FBSMutableSceneDefinition 上直接烙
            // initialParameters + displayConfiguration + sceneFrame + orientation。
            // 逆向报告实锤 ScreenCore 调 sc_configureInitialParameters:displayConfiguration:sceneFrame:interfaceOrientation:
            let cfgSel = NSSelectorFromString("sc_configureInitialParameters:displayConfiguration:sceneFrame:interfaceOrientation:")
            if definition.responds(to: cfgSel) {
                var params: NSObject? = nil
                if let pcls = NSClassFromString("FBSSceneParameters"),
                   let alloced = AevonSceneDriver.allocObj(pcls) {
                    params = alloced
                }
                let frame = NSValue(cgRect: CGRect(origin: .zero, size: AevonSceneDriver.canvasSize))
                let orient = NSNumber(value: 1)   // UIInterfaceOrientationPortrait = 1
                if let method = class_getInstanceMethod(type(of: definition), cfgSel), let params {
                    typealias Cfg = @convention(c) (NSObject, Selector, NSObject?, NSObject?, NSValue?, NSNumber?) -> Unmanaged<NSObject>?
                    let fn = unsafeBitCast(method_getImplementation(method), to: Cfg.self)
                    _ = fn(definition, cfgSel, params, smallDC, frame, orient)
                    AevonLog.info("[场景] P1 已走 ScreenCore 正路：definition.sc_configureInitialParameters（dc=\(smallDC != nil)）（AevonSceneDriverP1）")
                }
            } else {
                AevonLog.info("[场景] P1 definition 上无 sc_configureInitialParameters（走 settings 烙法，AevonSceneDriverP1）")
            }
            // 公开创建 API（P0 确认存在）
            let sel = NSSelectorFromString("createSceneWithDefinition:initialParameters:")
            if manager.responds(to: sel) {
                // initialParameters：FBSSceneParameters 构造（多路），失败给裸 alloc
                var params: NSObject? = nil
                if let pcls = NSClassFromString("FBSSceneParameters"),
                   let alloced = AevonSceneDriver.allocObj(pcls) {
                    let single = NSSelectorFromString("initWithSettings:")
                    if let method = class_getInstanceMethod(type(of: alloced), single) {
                        typealias Fn1 = @convention(c) (NSObject, Selector, NSObject?) -> Unmanaged<NSObject>?
                        params = unsafeBitCast(method_getImplementation(method), to: Fn1.self)(alloced, single, settings)?.takeRetainedValue()
                    }
                    if params == nil { params = alloced }
                }
                created = AevonSafeCallObject2(manager, "createSceneWithDefinition:initialParameters:",
                                               definition, params) as? NSObject
            }
            // 私有全家桶兜底（P0 dump 到的 7 参版）
            if created == nil {
                let sel2 = NSSelectorFromString("_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:")
                if let method = class_getInstanceMethod(type(of: manager), sel2) {
                    typealias C7 = @convention(c) (NSObject, Selector, NSObject, NSObject?, NSObject?, NSObject?, Bool, NSObject?, NSObject?) -> Unmanaged<NSObject>?
                    let fn = unsafeBitCast(method_getImplementation(method), to: C7.self)
                    created = fn(manager, sel2, definition, settings, nil, nil, false, nil, nil)?
                        .takeRetainedValue()
                }
            }
        }
        if let created {
            AevonLog.info("[场景] P1 第 5 步通过：createScene 已调用，返回 \(AevonSafeClassName(created))——若创建链成立，屏幕应出现按 266x458 排版的设置场景（AevonSceneDriverP1）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.step6Verify(created: created)
            }
        } else {
            AevonLog.warn("[场景] P1 第 5 步失败：createScene 两路都没走通（本轮到此为止，现有功能不受影响）（AevonSceneDriverP1）")
        }
    }

    // MARK: 第 6 步：创建后取证

    private func step6Verify(created: NSObject) {
        tryRun("取证") {
            var lines: [String] = []
            if created.responds(to: NSSelectorFromString("settings")),
               let settings = AevonSafeCallObject(created, "settings") as? NSObject {
                if let frame = settings.value(forKey: "frame") {
                    lines.append("frame=\(frame)")
                }
                /* V0.0.75：pixelSize 返回 CGSize **结构体**，`perform` + takeUnretainedValue
                 * 会把结构体当对象指针（同类野指针风险，见 Aevon(67) 崩溃栈），
                 * 这里改走 KVC（NSValue 包装，类型安全）。 */
                if let px = settings.value(forKeyPath: "displayConfiguration.pixelSize") {
                    lines.append("dc.pixelSize=\(px)")
                }
            }
            let joined = lines.isEmpty ? "（无可读字段）" : lines.joined(separator: " ")
            AevonLog.info("[场景] P1 取证：创建后 3s 场景状态 → \(joined)（AevonSceneDriverP1）")
        }
    }

    // MARK: - 辅助

    /// 可变场景设置构造（UIMutableApplicationSceneSettings 系）
    private func makeMutableSettings() -> NSObject {
        for clsName in ["UIMutableApplicationSceneSettings", "FBMutableSceneSettings"] {
            if let cls = NSClassFromString(clsName), let obj = AevonSceneDriver.allocObj(cls) {
                return obj
            }
        }
        return NSObject()
    }

    /// Swift 里 NSObject.alloc() 不可用 —— 走 ObjC 运行时 alloc（全工程统一走这里）
    static func allocObj(_ cls: AnyClass) -> NSObject? {
        let sel = NSSelectorFromString("alloc")
        guard (cls as AnyObject).responds(to: sel) else { return nil }
        guard let obj = AevonSafeCallObject(cls as AnyObject, "alloc") as? NSObject else { return nil }
        return obj
    }

    /// 把「小窗尺寸的 dc」烙进 settings（创建时烙定 = ScreenCore/Mango 路线）
    private func bakeGeometry(settings: NSObject, mainDC: NSObject?) {
        let size = AevonSceneDriver.canvasSize
        let frame = CGRect(origin: .zero, size: size)

        // 1) 造小窗 dc：优先拷贝主屏母本后按小窗尺寸改写几何 ivar；无母本则从零构造
        var smallDC: NSObject? = nil
        if let mainDC {
            smallDC = AevonSceneDriver.smallDisplayConfig(from: mainDC, canvas: size)
        }
        if smallDC == nil, let dcls = NSClassFromString("FBSDisplayConfiguration"),
           let fresh = AevonSceneDriver.allocObj(dcls) {
            let initSel = NSSelectorFromString("init")
            if let m = class_getInstanceMethod(type(of: fresh), initSel) {
                typealias Fn0 = @convention(c) (NSObject, Selector) -> Unmanaged<NSObject>?
                _ = unsafeBitCast(method_getImplementation(m), to: Fn0.self)(fresh, initSel)
            }
            AevonSceneDriver.writeCGRectIvar(fresh, "_nativeBounds", frame)
            AevonSceneDriver.writeCGRectIvar(fresh, "_bounds", frame)
            AevonSceneDriver.writeCGSizeIvar(fresh, "_pixelSize",
                                             CGSize(width: size.width * 3, height: size.height * 3))
            smallDC = fresh
            AevonLog.info("[场景] P1 小窗 dc 从零构造（无母本，ivar 直写 266x458 / 3x 像素）（AevonSceneDriverP1）")
        }

        // 2) 烙进 settings
        let dcSel = NSSelectorFromString("setDisplayConfiguration:")
        if settings.responds(to: dcSel), let smallDC {
            _ = AevonSafeCallObject1(settings, "setDisplayConfiguration:", smallDC) as? NSObject
            AevonLog.info("[场景] P1 已把小窗 dc（266x458）烙进 settings.displayConfiguration（AevonSceneDriverP1）")
        } else {
            AevonLog.warn("[场景] P1 settings 无 setDisplayConfiguration: 入口或小窗 dc 构造失败（AevonSceneDriverP1）")
        }
        var baked = false
        for (selName, key) in [("setFrame:", "frame"), ("setSceneFrame:", "sceneFrame"), ("setSize:", "size")] {
            if settings.responds(to: NSSelectorFromString(selName)) {
                let value: NSValue = (key == "size") ? NSValue(cgSize: size) : NSValue(cgRect: frame)
                settings.setValue(value, forKey: key)
                AevonLog.info("[场景] P1 已烙 settings.\(key) = \(value)（AevonSceneDriverP1）")
                baked = true
                break
            }
        }
        if !baked {
            AevonLog.warn("[场景] P1 settings 无 frame/sceneFrame/size 写入口（本轮裸创建，下一轮按取证名单补）（AevonSceneDriverP1）")
        }
    }

    /// 拷贝母本 dc 并把几何 ivar 改写成小窗尺寸（保持 mode/scale 等字段与主屏一致）
    static func smallDisplayConfig(from mainDC: NSObject, canvas: CGSize) -> NSObject? {
        var copyObj: NSObject? = nil
        for selName in ["mutableCopy", "copy"] {
            let sel = NSSelectorFromString(selName)
            if mainDC.responds(to: sel), let c = AevonSafeCallObject(mainDC, sel) as? NSObject {
                copyObj = c
                break
            }
        }
        guard let dc = copyObj else { return nil }
        // 从母本读出像素比（pixelSize.width / bounds.width），小窗按同比例换算像素尺寸
        var scale: CGFloat = 3.0
        if let b = readCGRectIvar(mainDC, "_bounds"), b.width > 1,
           let p = readCGSizeIvar(mainDC, "_pixelSize"), p.width > 1 {
            scale = p.width / b.width
        }
        let frame = CGRect(origin: .zero, size: canvas)
        let ok1 = writeCGRectIvar(dc, "_nativeBounds", frame)
        let ok2 = writeCGRectIvar(dc, "_bounds", frame)
        let ok3 = writeCGSizeIvar(dc, "_pixelSize",
                                  CGSize(width: canvas.width * scale, height: canvas.height * scale))
        AevonLog.info("[场景] P1 小窗 dc：母本拷贝 + ivar 改写 nativeBounds/bounds=\(ok1 && ok2) pixelSize=\(ok3)（scale=\(String(format: "%.2f", scale))）（AevonSceneDriverP1）")
        return (ok1 || ok2) ? dc : nil
    }

    // MARK: ivar 直写/直读（V63 技术链：先查类型编码再动字节）

    private static func ivarPtr(_ obj: NSObject, _ name: String, expectPrefix: String) -> (UnsafeMutableRawPointer, Int)? {
        guard let ivar = class_getInstanceVariable(type(of: obj) as AnyClass, name),
              let enc = ivar_getTypeEncoding(ivar), String(cString: enc).hasPrefix(expectPrefix) else { return nil }
        let off = ivar_getOffset(ivar)
        guard off >= 0 else { return nil }
        let raw = unsafeBitCast(obj, to: UnsafeMutableRawPointer.self)
        return (raw.advanced(by: off), off)
    }

    static func writeCGRectIvar(_ obj: NSObject, _ name: String, _ value: CGRect) -> Bool {
        guard let (ptr, _) = ivarPtr(obj, name, expectPrefix: "{CGRect") else { return false }
        withUnsafeBytes(of: value) { memcpy(ptr, $0.baseAddress, MemoryLayout<CGRect>.size) }
        return true
    }

    static func writeCGSizeIvar(_ obj: NSObject, _ name: String, _ value: CGSize) -> Bool {
        guard let (ptr, _) = ivarPtr(obj, name, expectPrefix: "{CGSize") else { return false }
        withUnsafeBytes(of: value) { memcpy(ptr, $0.baseAddress, MemoryLayout<CGSize>.size) }
        return true
    }

    static func readCGRectIvar(_ obj: NSObject, _ name: String) -> CGRect? {
        guard let (ptr, _) = ivarPtr(obj, name, expectPrefix: "{CGRect") else { return nil }
        return ptr.load(as: CGRect.self)
    }

    static func readCGSizeIvar(_ obj: NSObject, _ name: String) -> CGSize? {
        guard let (ptr, _) = ivarPtr(obj, name, expectPrefix: "{CGSize") else { return nil }
        return ptr.load(as: CGSize.self)
    }
}
