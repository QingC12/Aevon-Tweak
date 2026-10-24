import Foundation
import UIKit

/*
 * V0.0.68（AevonSceneDriverP1）：真小胖屏 P1 —— 自建场景概念验证。
 *
 * 依据（全部实证，见 stheno-逆向分析/analysis/）：
 *   · ScreenCore 2.1.0 逆向报告：小胖屏 = SB 侧为 App 新建正经主场景，
 *     创建时把小窗尺寸烙进 FBSSceneParameters（dc + sceneFrame + orientation），
 *     App 按小窗真重排（底栏天然在场、元素 1:1、无裁切）。
 *   · 本机 P0 探测 5/5 全过（Aevon(60) 日志）。
 *
 * V0.0.76（AevonSceneSafeObjV76）—— 两次自动注销的终审：
 *   Aevon(67)、Aevon(68) 两份崩溃栈一模一样，最内层都是
 *     swift_dynamicCast → swift_getObjectType → _CF_forwarding_prep_0 → SpringBoard 退出
 *   而栈里**一个 FrontBoard 帧都没有**：不是系统方法内部崩的，是我们自己 Swift 代码里的
 *   `as? NSObject` 动态转换崩的。`id` 在 Swift 里被桥成 `Any!`，每次赋值都要过一趟运行时
 *   转换；那个指针只要不是干净对象（BOOL 的 1、结构体、tagged pointer），立刻读野 isa。
 *
 *   本版两条硬规矩，从二进制层面掐掉这条崩溃路径：
 *     ① 调垫片一律走 `AevonSafeObj *`（返回类型写死 `NSObject *`）—— Swift 侧拿到的就是
 *        `NSObject?`，**编译期不再生成任何转换指令**；
 *     ② 本文件内**禁止**出现 `as?` / `as!` / `type(of:)` / `String(describing:)`，
 *        取类名走 `AevonSafeClassName`，取类走 `AevonClassOfObject`。
 *
 * 另外新增「前置体检」：provider / displayIdentity / 方法表任一不达标就**直接收工**，
 * 绝不带着半成品参数去调四段 init —— 让 266x458 能不能出来这件事，永远只由
 * 「创建链是否成立」决定，而不是由一次野指针决定。
 */

@objc(AevonSceneDriver)
final class AevonSceneDriver: NSObject {

    static let shared = AevonSceneDriver()

    /// 白名单：P1 只对「设置」实验（系统 App，崩溃代价最小、可观察性最好）
    static let experimentBundleID = "com.apple.Preferences"
    /// P1 参考画布：与浮窗 0.600 胖窗同比例
    static let canvasSize = CGSize(width: 266, height: 458)

    /// 四段 init 内部真正会调用的协议方法
    static let entityProviderSelector = "sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:"
    /// iOS 17.3.1 上 SBMainWorkspace 实际实现的「下划线变体」
    static let entityProviderAltSelector = "_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:"

    /// V0.0.79（AevonMainDisplayInitV79）：不需要 sceneHandleProvider 的两参 init。
    ///
    /// 出处：ScreenCore 字符串表里 `SBSceneManagerCoordinator` / `mainDisplaySceneManager`
    /// 紧跟其后的选择子就是它 —— 说明这条路自己会去主屏 scene manager，
    /// 调用方不必先把 provider 抠出来（我们卡了三轮的就是那一步）。
    static let mainDisplayInitSelector = "initWithApplicationForMainDisplay:generatingNewPrimarySceneIfRequired:"

    /// 连崩这么多次就锁定实验（连崩 = 用户开了开关就注销，体验不可接受）
    static let maxCrashesBeforeLock = 2

    private var ranForThisToggle = false
    private var running = false

    // MARK: - 崩溃熔断（V0.0.75 / V0.0.76 加固）

    static var crashFused = false
    static var locked = false

    /// 启动时调用一次（Bootstrap 早期）：检查上一轮 P1 是否留下未完成的面包屑。
    ///
    /// respring 不会清文件，所以「残留面包屑」= 上一轮死在这一步的铁证。
    /// 读到残留就：开关写关（断掉死循环）+ 崩溃计数 +1；计数达上限直接锁定实验。
    static func consumeCrashFuse() {
        let raw = AevonCrumbRead()
        let crumb: String = (raw != nil) ? String(cString: raw!) : ""
        AevonCrumbClear()
        guard !crumb.isEmpty else {
            let n = Int(AevonP1FuseCount())
            if n > 0 {
                AevonLog.info("[场景] P1 崩溃计数 = \(n)（上一轮没有留下面包屑，说明是正常收工）（AevonCrashFuseV75）")
            }
            return
        }
        // 面包屑格式是「<时间戳> <步骤名>」，日志里只留步骤名
        let stage: String = {
            if let sp = crumb.firstIndex(of: " ") {
                return String(crumb[crumb.index(after: sp)...])
            }
            return crumb
        }()
        AevonP1FuseBump()
        let count = Int(AevonP1FuseCount())
        crashFused = true
        AevonPrefs.set("AevonTrueResizeP1", false)
        if count >= maxCrashesBeforeLock {
            locked = true
            AevonLog.warn("[场景] P1 崩溃熔断：上次崩在「\(stage)」，累计已崩 \(count) 次 —— 实验**已锁定**，本版不再自动运行（请把日志发给开发者，修好后再放开）（AevonCrashFuseV75 AevonSceneSafeObjV76）")
        } else {
            AevonLog.warn("[场景] P1 崩溃熔断：上次崩在「\(stage)」，本次启动已自动关闭 P1 开关（累计第 \(count) 次；崩满 \(maxCrashesBeforeLock) 次将锁定实验）（AevonCrashFuseV75）")
        }
    }

    /// prefschanged / 启动自检回调入口：开关从关到开才触发（5s 错峰，给设置页留写盘时间）
    func maybeRunExperiment() {
        guard !AevonSceneDriver.locked else {
            AevonLog.warn("[场景] P1 实验已锁定（累计崩溃 \(Int(AevonP1FuseCount())) 次），本轮不运行；需要重试请先换用新版本（AevonSceneSafeObjV76）")
            return
        }
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
        AevonLog.info("[场景] P1 实验开始：目标画布 \(Int(AevonSceneDriver.canvasSize.width))x\(Int(AevonSceneDriver.canvasSize.height))（AevonSceneDriverP1 AevonSceneSafeObjV76）")
        AevonCrumbWrite("开始")
        self.step1SceneManager()
        /* step1~step5 是一条同步链，能崩的都在这里。
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
        AevonLog.info("[场景] P1 第 1 步通过：FBSceneManager = \(AevonSafeClassName(manager) ?? "nil")（AevonSceneDriverP1）")
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
                if let m = AevonSafeObjCall(ws, sel) {
                    if (AevonSafeClassName(m) ?? "nil").contains("SceneManager") { return m }
                }
            }
        }
        return nil
    }

    /// `[SomeClass sharedInstance]` 的安全版（V0.0.76：全程无动态转换）
    private static func tryShared(classNamed: String, selector: String) -> NSObject? {
        guard let cls = AevonClassNamed(classNamed) else { return nil }
        guard AevonClassRespondsTo(cls, selector) else { return nil }
        return AevonSafeObjCallSel(cls as AnyObject, NSSelectorFromString(selector))
    }

    // MARK: 第 2 步：主屏显示配置母本

    private func step2MainDisplayConfig(manager: NSObject) {
        AevonCrumbWrite("第2步-主屏dc")
        var dc: NSObject? = nil
        tryRun("第2步") {
            dc = AevonSceneDriver.findMainDisplayConfiguration(manager: manager)
        }
        if let dc {
            AevonLog.info("[场景] P1 第 2 步通过：主屏 dc 母本 = \(AevonSafeClassName(dc) ?? "nil")（AevonSceneDriverP1）")
        } else {
            AevonLog.warn("[场景] P1 第 2 步降级：没拿到主屏 dc 母本，改走「从零构造小窗 dc」（ivar 直写，日志如实记录）（AevonSceneDriverP1）")
        }
        self.step3Application(manager: manager, mainDC: dc)
    }

    /// 主屏 dc 多路探测（ScreenCore 的 sc_mainDisplayConfiguration 对应物）
    static func findMainDisplayConfiguration(manager: NSObject) -> NSObject? {
        for sel in ["mainDisplayConfiguration", "displayConfiguration", "primaryDisplayConfiguration"] {
            if let r = AevonSafeObjCall(manager, sel) { return r }
        }
        // 路线 B：遍历管理器持有的全部场景，取任一 settings.displayConfiguration
        let selName = "enumerateScenesWithBlock:"
        if let cls = AevonClassOfObject(manager), AevonClassHasInstanceMethod(cls, selName),
           let enumMethod = class_getInstanceMethod(cls, NSSelectorFromString(selName)) {
            var found: NSObject? = nil
            let block: @convention(block) (NSObject?) -> Void = { scene in
                guard let scene else { return }
                if found == nil, let dc = AevonSceneDriver.displayConfigFromScene(scene) {
                    found = dc
                }
            }
            typealias EnumFn = @convention(c) (NSObject, Selector, @convention(block) (NSObject?) -> Void) -> Void
            unsafeBitCast(method_getImplementation(enumMethod), to: EnumFn.self)(manager, NSSelectorFromString(selName), block)
            if let found { return found }
        }
        for (clsName, selName) in [("SBFDisplayManager", "sharedInstance"), ("SBFDisplayManager", "mainDisplayManager")] {
            if let dm = tryShared(classNamed: clsName, selector: selName) {
                for sel in ["mainDisplayConfiguration", "displayConfiguration", "mainScreenDisplayConfiguration", "mainSBFDisplay"] {
                    if let r = AevonSafeObjCall(dm, sel) {
                        if (AevonSafeClassName(r) ?? "nil").contains("DisplayConfiguration") { return r }
                        // SBFDisplay 之类再向下钻一层
                        for sel2 in ["displayConfiguration", "mainDisplayConfiguration"] {
                            if let r2 = AevonSafeObjCall(r, sel2),
                               (AevonSafeClassName(r2) ?? "nil").contains("DisplayConfiguration") {
                                return r2
                            }
                        }
                    }
                }
            }
        }
        if let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance") {
            for sel in ["mainScene", "mainWorkspaceScene", "scene"] {
                if let scene = AevonSafeObjCall(ws, sel), let dc = displayConfigFromScene(scene) {
                    return dc
                }
            }
        }
        return nil
    }

    /// 从 FBScene 的 settings 里找 FBSDisplayConfiguration
    static func displayConfigFromScene(_ scene: NSObject) -> NSObject? {
        if let settings = AevonSafeObjCall(scene, "settings") {
            for sel in ["displayConfiguration", "displayConfigurationLayout"] {
                if let r = AevonSafeObjCall(settings, sel),
                   (AevonSafeClassName(r) ?? "nil").contains("DisplayConfiguration") {
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
            let ctrl = AevonSceneDriver.findApplicationController(diag: diag)
            if let ctrl {
                for selName in ["applicationWithBundleIdentifier:", "applicationWithDisplayIdentifier:", "runningApplicationWithBundleIdentifier:"] {
                    if let a = AevonSafeObjCall1(ctrl, selName, AevonSceneDriver.experimentBundleID) {
                        app = a
                        break
                    }
                }
            }
        }
        if let app {
            AevonLog.info("[场景] P1 第 3 步通过：SBApplication = \(AevonSafeClassName(app) ?? "nil")（AevonSceneDriverP1）")
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
        guard let cls = AevonClassNamed("SBApplicationController") else {
            diag.items.append("SBApplicationController 类不存在")
            return nil
        }
        for selName in ["sharedInstance", "sharedApplicationController", "defaultController", "sharedController"] {
            if AevonClassRespondsTo(cls, selName),
               let c = AevonSafeObjCallSel(cls as AnyObject, NSSelectorFromString(selName)) {
                return c
            }
        }
        // 全部失败：取样类方法名（下一轮按真实名补）
        var names: [String] = []
        var count: UInt32 = 0
        if let metaCls = AevonMetaClassNamed("SBApplicationController"),
           let list = class_copyMethodList(metaCls, &count) {
            for i in 0..<Int(count) {
                let n = NSStringFromSelector(method_getName(list[i]))
                if n.lowercased().contains("shared") || n.lowercased().contains("default") { names.append("+" + n) }
            }
            free(list)
        }
        diag.items.append(names.isEmpty ? "类方法里无 sharedInstance/default 系" : "类方法候选=\(names.prefix(5).joined(separator: ","))")
        return nil
    }

    // MARK: 第 4 步：SBDeviceApplicationSceneEntity 构造

    /// 读对象型 ivar（V62 教训：先查类型编码 '@' 才可用 object_getIvar）
    static func readObjectIvar(_ obj: NSObject, _ name: String) -> NSObject? {
        return AevonSafeObjIvar(obj, name)
    }

    /// provider 四路探测（ScreenCore 的 sc_mainDisplaySceneHandleProvider 对应物）
    private static func findSceneHandleProvider(diag: StringBox) -> NSObject? {
        if let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance") {
            for sel in ["sceneHandleProvider", "handleProvider"] {
                if let r = AevonSafeObjCall(ws, sel) {
                    diag.items.append("provider=WS.\(sel)")
                    return r
                }
            }
            diag.items.append("provider=CANDIDATE:SBMainWorkspace")
            return ws
        }
        if let m = tryShared(classNamed: "FBSceneManager", selector: "sharedInstance") {
            diag.items.append("provider=CANDIDATE:FBSceneManager")
            return m
        }
        for selName in ["sharedInstance", "defaultProvider", "sharedProvider"] {
            if let p = tryShared(classNamed: "FBSSceneHandleProvider", selector: selName) {
                diag.items.append("provider=CANDIDATE:FBSSceneHandleProvider")
                return p
            }
        }
        return nil
    }

    /// 解析 provider：在**整条 workspace / sceneManager 候选链**上找真正实现了协议方法的那个：
    ///   · 直接实现 `sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:` → 直接用
    ///   · 只实现下划线变体 → 用纯 ObjC 代理转调
    ///   · 全链都不响应 → 返回 nil（**不硬调**，这是 V0.0.73~75 反复崩在 init 里的教训）
    private static func resolveSceneEntityProvider(diag: StringBox) -> NSObject? {
        var candidates: [NSObject] = []
        var labels: [String] = []
        func add(_ obj: NSObject?, _ label: String) {
            guard let obj else { return }
            candidates.append(obj)
            labels.append(label)
        }
        let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance")
        add(ws, "SBMainWorkspace")
        // 属性式 provider（ScreenCore 的 sc_mainDisplaySceneHandleProvider 对应物）
        if let ws {
            for sel in ["sceneHandleProvider", "handleProvider"] {
                add(AevonSafeObjCall(ws, sel), "WS.\(sel)")
            }
            for sel in ["sceneManager", "sceneManagerCoordinator"] {
                if let r = AevonSafeObjCall(ws, sel) {
                    add(r, "WS.\(sel)")
                    for sel2 in ["mainDisplaySceneManager", "mainWindowSceneManager", "mainSwitcherSceneManager"] {
                        add(AevonSafeObjCall(r, sel2), "WS.\(sel).\(sel2)")
                    }
                }
            }
        }
        let coord = tryShared(classNamed: "SBSceneManagerCoordinator", selector: "sharedInstance")
        if let coord {
            add(coord, "SBSceneManagerCoordinator")
            for sel in ["mainDisplaySceneManager", "mainWindowSceneManager", "mainSwitcherSceneManager"] {
                add(AevonSafeObjCall(coord, sel), "Coord.\(sel)")
            }
        }
        // Stheno/ScreenCore 用的是 SBWorkspace +mainWorkspace（不是 SBMainWorkspace sharedInstance）
        add(tryShared(classNamed: "SBWorkspace", selector: "mainWorkspace"), "SBWorkspace.mainWorkspace")
        add(tryShared(classNamed: "FBSceneManager", selector: "sharedInstance"), "FBSceneManager")
        for selName in ["sharedInstance", "defaultProvider", "sharedProvider"] {
            add(tryShared(classNamed: "FBSSceneHandleProvider", selector: selName), "FBSSceneHandleProvider.\(selName)")
        }

        // 1) 优先：直接响应协议方法
        for (i, obj) in candidates.enumerated() where AevonObjRespondsTo(obj, entityProviderSelector) {
            diag.items.append("provider=直接响应协议（\(labels[i])）")
            return obj
        }
        // 2) 次选：只响应下划线变体 → 纯 ObjC 代理
        for (i, obj) in candidates.enumerated() where AevonObjRespondsTo(obj, entityProviderAltSelector) {
            if let proxy = AevonProviderProxyCreate(obj) {
                diag.items.append("provider=ObjC代理→\(labels[i])._sceneIdentity…")
                return proxy
            }
        }
        /* 2.5) V0.0.78（AevonProviderGraphV78）：**顺着对象图把 provider 找出来**。
         *
         * Aevon(70) 第 4 步预习已经把真实现类打出来了：
         *   实现类=…,SBSceneIdentityProvider,SBLayoutStateSceneIdentityProvider,
         *           SBSceneManager,SBSecureMainDisplaySceneManager
         * Stheno 蓝图 v3 也早写着 `SBSceneManager` 实现
         * `-sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:`
         * （编码 @36@0:8@16B24@28）。所以 provider 不是 SBMainWorkspace 本体
         * （iOS 17 挪到了 sceneManager 上），而我们按属性名取的 WS.sceneManager 等全是 nil。
         * 与其继续猜属性名，不如从 workspace / coordinator 出发做对象图 BFS
         * （深度 2、节点封顶 600、只走 '@' 编码的 ivar），把实例直接捞出来。 */
        let roots: [(NSObject?, String)] = [(ws, "SBMainWorkspace"),
                                            (tryShared(classNamed: "SBSceneManagerCoordinator", selector: "sharedInstance"), "SBSceneManagerCoordinator")]
        for (root, rootLabel) in roots {
            guard let root else { continue }
            for token in ["MainDisplay", "SceneManager", "SceneIdentity"] {
                if let hit = AevonFindResponderInGraph(root, entityProviderSelector, token, 2) {
                    diag.items.append("provider=对象图命中（\(rootLabel) 下 \(AevonSafeClassName(hit) ?? "nil")，优选=\(token)）")
                    return hit
                }
            }
        }
        for (root, rootLabel) in roots {
            guard let root else { continue }
            for token in ["MainDisplay", "SceneManager", "SceneIdentity"] {
                if let hit = AevonFindResponderInGraph(root, entityProviderAltSelector, token, 2),
                   let proxy = AevonProviderProxyCreate(hit) {
                    diag.items.append("provider=对象图命中→ObjC代理（\(rootLabel) 下 \(AevonSafeClassName(hit) ?? "nil")._sceneIdentity…）")
                    return proxy
                }
            }
        }
        for (root, rootLabel) in roots {
            guard let root else { continue }
            let rep = AevonGraphResponderReport(root, entityProviderSelector, 2, 6) ?? ""
            diag.items.append("图报告(\(rootLabel))=\(rep.isEmpty ? "无" : rep)")
        }

        /* 2.6) V0.0.79（AevonProviderIvarV79）：BFS 为什么全空？
         *
         * Aevon(71) 日志：图报告(SBMainWorkspace)=无；图报告(SBSceneManagerCoordinator)=无。
         * 而实现类里明明有 SBSceneManager。差别在 `AevonGraphSkipClass` ——
         * 它把 NSArray / NSDictionary / NSSet 整类跳过，而 iOS 17 的 scene manager
         * 正是躺在 `SBSceneManagerCoordinator` 的**字典**里（_sceneManagers，value=实例）。
         * 沿 ivar 一走到字典就断链，所以「无」。
         * 这里换成带容器展开的候选收集：ivar 是容器就摊开前 8 个元素，再下钻一层，
         * 拿到实例后逐个试协议方法。命中就直接用，顺便把 ivar 表打出来留证。 */
        for (root, rootLabel) in [(ws, "WS"), (coord, "Coord")] {
            guard let root else { continue }
            let dump = AevonIvarDumpReport(root, 22) ?? ""
            diag.items.append("ivar表(\(rootLabel))=\(dump.isEmpty ? "无" : dump)")
            let cands: [NSObject] = AevonIvarCandidates(root) ?? []
            diag.items.append("ivar候选(\(rootLabel))=\(cands.count)个（AevonProviderIvarV79）")
            for cand in cands where AevonObjRespondsTo(cand, entityProviderSelector) {
                diag.items.append("provider=ivar命中（\(rootLabel) 下 \(AevonSafeClassName(cand) ?? "nil")）")
                return cand
            }
            for cand in cands where AevonObjRespondsTo(cand, entityProviderAltSelector) {
                if let proxy = AevonProviderProxyCreate(cand) {
                    diag.items.append("provider=ivar命中→ObjC代理（\(rootLabel) 下 \(AevonSafeClassName(cand) ?? "nil")._sceneIdentity…）")
                    return proxy
                }
            }
        }

        /* 3) 全类扫描留证（下一轮按真实实现类补链路）
         * V0.0.77：整段下沉到 ObjC —— Aevon(69) 第二次自动注销就崩在这个循环里的
         * `swift_dynamicCast`（反汇编 img+0x51ad8 实锤）。这里只拿一个字符串。 */
        let exact = AevonClassScanForSelector(entityProviderSelector, 10) ?? ""
        let alt = AevonClassScanForSelector(entityProviderAltSelector, 10) ?? ""
        diag.items.append("实现类=\(exact.isEmpty ? "无" : exact)")
        diag.items.append("下划线实现类=\(alt.isEmpty ? "无" : alt)")
        diag.items.append("候选链=\(labels.isEmpty ? "空" : labels.joined(separator: ","))")
        return nil
    }

    /// 主屏 dc 的 displayIdentity（四段 init 的第 5 个参数）
    private static func findDisplayIdentity(mainDC: NSObject?, app: NSObject?) -> NSObject? {
        // 路线 1：主屏 dc 母本的 _identity ivar（P0 dump 实锤存在）
        if let mainDC {
            if let id = AevonSafeObjIvar(mainDC, "_identity"),
               (AevonSafeClassName(id) ?? "nil").contains("DisplayIdentity") {
                return id
            }
            // FBSDisplayConfiguration 的 _identity 可能另叫 _displayIdentity
            if let id = AevonSafeObjIvar(mainDC, "_displayIdentity"),
               (AevonSafeClassName(id) ?? "nil").contains("DisplayIdentity") {
                return id
            }
        }
        // 路线 2：主场景 settings 上的 displayIdentity
        if let ws = tryShared(classNamed: "SBMainWorkspace", selector: "sharedInstance") {
            for sel in ["mainScene", "mainWorkspaceScene"] {
                if let scene = AevonSafeObjCall(ws, sel),
                   let settings = AevonSafeObjCall(scene, "settings"),
                   let id = AevonSafeObjCall(settings, "displayIdentity"),
                   (AevonSafeClassName(id) ?? "nil").contains("DisplayIdentity") {
                    return id
                }
            }
        }
        // 路线 3：App 自己身上的 displayIdentity
        if let app, let id = AevonSafeObjCall(app, "displayIdentity"),
           (AevonSafeClassName(id) ?? "nil").contains("DisplayIdentity") {
            return id
        }
        return nil
    }

    private func step4SceneEntity(manager: NSObject, app: NSObject, mainDC: NSObject?) {
        AevonCrumbWrite("第4步-场景实体")
        var entity: NSObject? = nil
        let diag = StringBox()

        // ── 前置体检（V0.0.76 新增）：不达标就收工，绝不带半成品参数进 init ──
        guard let cls = AevonClassNamed("SBDeviceApplicationSceneEntity") else {
            AevonLog.warn("[场景] P1 第 4 步失败：类 SBDeviceApplicationSceneEntity 不存在（AevonSceneDriverP1 AevonSceneP1V73）")
            return
        }
        let candidates: [(String, Int)] = [
            ("initWithApplication:generatingNewPrimarySceneIfRequired:sceneHandleProvider:displayIdentity:", 4),
            ("initWithApplication:sceneHandleProvider:displayIdentity:", 3),
            ("initWithApplicationForMainDisplay:", 1),
            ("initWithApplication:uniqueIdentifier:targetContentIdentifier:sceneHandleProvider:displayIdentity:", 5),
        ]
        var usable: [(String, Int)] = []
        for (selName, argc) in candidates where AevonClassHasInstanceMethod(cls, selName) {
            usable.append((selName, argc))
        }
        guard !usable.isEmpty else {
            AevonLog.warn("[场景] P1 第 4 步失败：实体类上三个 init 候选一个都没有（AevonSceneDriverP1 AevonSceneP1V73）")
            return
        }

        AevonCrumbWrite("第4步-provider")
        var provider: NSObject? = nil
        tryRun("第4步-provider") {
            provider = AevonSceneDriver.resolveSceneEntityProvider(diag: diag)
        }
        AevonCrumbWrite("第4步-identity")
        var displayID: NSObject? = nil
        tryRun("第4步-identity") {
            displayID = AevonSceneDriver.findDisplayIdentity(mainDC: mainDC, app: app)
        }

        // App 状态只取布尔（历史崩点一：BOOL 被当对象指针）
        for s in ["isRunning", "running", "isLaunchable"] {
            var ok: ObjCBool = false
            if AevonObjRespondsTo(app, s) {
                let v = AevonSafeBoolCall(app, s, &ok)
                if ok.boolValue { diag.items.append("app.\(s)=\(v ? 1 : 0)") }
            }
        }
        diag.items.append("entity=\(AevonClassNameOfClass(cls) ?? "nil")")
        diag.items.append("app=\(AevonSafeClassName(app) ?? "nil")")
        let displayName: String = displayID.map { AevonSafeClassName($0) ?? "nil" } ?? "nil"
        let providerName: String = provider.map { AevonSafeClassName($0) ?? "nil" } ?? "nil"
        diag.items.append("displayID=\(displayName)")
        diag.items.append("provider=\(providerName)")

        // provider 是关键参数：没有就停（带 nil 硬调 = Aevon(65) 的断言异常）
        /* V0.0.79（AevonMainDisplayInitV79）：provider 解析不到时的兜底路。
         *
         * ScreenCore 的字符串表里，紧跟在 `SBSceneManagerCoordinator` /
         * `mainDisplaySceneManager` 之后还有一条：
         *   `initWithApplicationForMainDisplay:generatingNewPrimarySceneIfRequired:`
         * 两参、**不需要 provider**（SpringBoard 内部自己去取主屏 scene manager）。
         * 我们从 V0.0.77 起连着三轮卡在 provider=nil 上，先让场景真的建起来：
         * 这条走通就等于拿到「App 在 266x458 画布里重排」的第一手证据。 */
        let effProvider = provider
        var hasMainDisplayInit = false
        if effProvider == nil, AevonClassHasInstanceMethod(cls, AevonSceneDriver.mainDisplayInitSelector) {
            usable.append((AevonSceneDriver.mainDisplayInitSelector, 2))
            hasMainDisplayInit = true
            diag.items.append("兜底=主屏两参 init（无需 provider，AevonMainDisplayInitV79）")
        }
        if effProvider == nil && !hasMainDisplayInit {
            AevonLog.warn("[场景] P1 第 4 步失败：解析不到 sceneHandleProvider，本轮不调 init（避免断言异常 / 野指针）｜\(diag.items.joined(separator: "；"))（AevonSceneDriverP1 AevonSceneP1V73）")
            return
        }

        /* V0.0.80（AevonProviderProbeV80）：上一版三个 init 全 nil，但 provider 已经命中
         * `SBMainDisplaySceneManager`。返回 nil 只能来自 init 内部拿不到 sceneHandle ——
         * 也就是 provider 的 identity 链给我们回了 nil。这里把整条链的**真实返回值**
         * 打出来（identity 两种选择子 × create 真假 + handle + App 的 sceneIdentifier +
         * 多场景声明），下一轮一眼能定死是「单场景 App 建不了第二个场景」还是「参数传错」。
         * 同时把 provider 类（含父类）的方法表按 create/application/scene 过滤 dump 一次，
         * 直接看它到底提供了哪些「给 App 建场景」的官方入口。 */
        if let p = effProvider {
            AevonCrumbWrite("第4步-provider探测")
            var probe = ""
            tryRun("第4步-provider探测") {
                probe = AevonProviderProbeReport(p, app) ?? ""
            }
            diag.items.append("链探测=\(probe.isEmpty ? "空" : probe)")
            let clsName = AevonSafeClassName(p) ?? ""
            if !clsName.isEmpty {
                var dump = ""
                tryRun("第4步-方法表") {
                    dump = AevonClassMethodDump(clsName, "create,application,scene") ?? ""
                }
                diag.items.append("方法表(\(clsName))=\(dump.isEmpty ? "空" : dump)")
            }
        }

        AevonCrumbWrite("第4步-init")
        AevonLog.info("[场景] P1 第 4 步预习：将尝试 \(usable.count) 个 init（\(usable.map { $0.0 }.joined(separator: " / "))）｜\(diag.items.joined(separator: "；"))（AevonSceneDriverP1 AevonSceneP1V73 AevonProviderProbeV80）")
        tryRun("第4步") {
            typealias Init4 = @convention(c) (NSObject, Selector, NSObject, Bool, NSObject?, NSObject?) -> Unmanaged<NSObject>?
            typealias Init3 = @convention(c) (NSObject, Selector, NSObject, NSObject?, NSObject?) -> Unmanaged<NSObject>?
            typealias Init5 = @convention(c) (NSObject, Selector, NSObject, NSObject, NSObject?, NSObject?, NSObject?) -> Unmanaged<NSObject>?
            typealias Init2Main = @convention(c) (NSObject, Selector, NSObject, Bool) -> Unmanaged<NSObject>?
            typealias Init1Main = @convention(c) (NSObject, Selector, NSObject) -> Unmanaged<NSObject>?
            for (selName, argc) in usable {
                let sel = NSSelectorFromString(selName)
                let short = selName.components(separatedBy: ":")[0]
                guard let method = class_getInstanceMethod(cls, sel) else { continue }
                let imp = method_getImplementation(method)
                var attempt: NSObject? = nil
                /* 每个候选**独立异常隔离 + 各自 fresh alloc**（Aevon(66) 教训：整段共用一个
                 * @try 时，第一个候选抛异常会把后面所有候选一起跳过）。 */
                self.tryRun("第4步-\(short)") {
                    guard let fresh = AevonAllocInstance(cls) else { return }
                    var result: Unmanaged<NSObject>? = nil
                    switch argc {
                    case 1:
                        result = unsafeBitCast(imp, to: Init1Main.self)(fresh, sel, app)
                    case 2:
                        result = unsafeBitCast(imp, to: Init2Main.self)(fresh, sel, app, true)
                    case 4:
                        guard let p = effProvider else { return }
                        result = unsafeBitCast(imp, to: Init4.self)(fresh, sel, app, true, p, displayID)
                    case 3:
                        guard let p = effProvider else { return }
                        result = unsafeBitCast(imp, to: Init3.self)(fresh, sel, app, p, displayID)
                    case 5:
                        guard let p = effProvider else { return }
                        guard let uid = AevonSafeObjCall(app, "uniqueIdentifier") else { return }
                        result = unsafeBitCast(imp, to: Init5.self)(fresh, sel, app, uid, nil, p, displayID)
                    default:
                        return
                    }
                    if let r = result {
                        let obj = r.takeRetainedValue()
                        if AevonClassOfObject(obj) != nil { attempt = obj }
                    }
                }
                if let attempt {
                    entity = attempt
                    diag.items.append("成功=\(selName)")
                    break
                }
                diag.items.append("返回nil=\(selName)")
            }
        }
        guard let entity else {
            let d = diag.items.isEmpty ? "" : "｜诊断：\(diag.items.joined(separator: "；"))"
            AevonCrumbClear()
            AevonLog.warn("[场景] P1 第 4 步失败：SBDeviceApplicationSceneEntity 全部候选 init 都构造不出实体\(d)（AevonSceneDriverP1 AevonSceneP1V73）")
            return
        }
        AevonLog.info("[场景] P1 第 4 步通过：sceneEntity 已构造（代理命中 \(Int(AevonProviderProxyHitCount())) 次）（AevonSceneDriverP1 AevonSceneP1V73）")
        self.step5Create(manager: manager, entity: entity, mainDC: mainDC)
    }

    // MARK: 第 5 步：场景设置（烙 dc + 小窗 frame）+ createScene

    private func step5Create(manager: NSObject, entity: NSObject, mainDC: NSObject?) {
        AevonCrumbWrite("第5步-创建场景")
        var created: NSObject? = nil
        tryRun("第5步") {
            guard let definition = AevonSafeObjCall(entity, "sceneDefinition") else {
                AevonLog.warn("[场景] P1 第 5 步：entity 上拿不到 sceneDefinition（AevonSceneDriverP1）")
                return
            }
            // 小窗 dc 只造一次：definition 路线和 settings 路线共用
            var smallDC: NSObject? = nil
            if let mainDC {
                smallDC = AevonSceneDriver.smallDisplayConfig(from: mainDC, canvas: AevonSceneDriver.canvasSize)
            }
            guard let settings = self.makeMutableSettings() else {
                AevonLog.warn("[场景] P1 第 5 步失败：没有可用的可变场景设置类（UIMutableApplicationSceneSettings / FBMutableSceneSettings）（AevonSceneDriverP1）")
                return
            }
            self.bakeGeometry(settings: settings, smallDC: smallDC)
            /* ScreenCore 那个 sc_configureInitialParameters:displayConfiguration:sceneFrame:
             * interfaceOrientation: 是 **ScreenCore 自家 SCSystemSceneDriver 上的方法**，
             * 系统类上根本没有 —— V0.0.71~75 那句 definition.responds(to:) 恒为 false，
             * 属于死代码。本版改为在 FBSSceneParameters 上直接烙（KVC / setter）。 */
            AevonLog.info("[场景] P1 第 5 步：跳过 sc_configureInitialParameters（那是 ScreenCore 私有方法，系统类无实现），改在 FBSSceneParameters 上烙 dc+frame（AevonSceneDriverP1）")
            let params = AevonSceneDriver.makeSceneParameters(definition: definition,
                                                             settings: settings,
                                                             smallDC: smallDC)
            /* ScreenCore 的 sc_configureInitialParameters:displayConfiguration:sceneFrame:
             * interfaceOrientation: 是 **ScreenCore 自己的方法**（SCSystemSceneDriver 上），
             * 系统类上根本没有 —— V0.0.71~75 那句 definition.responds(to:) 恒为 false，
             * 属于死代码，本版删掉，改为在 FBSSceneParameters 上直接烙（KVC）。 */
            created = AevonSafeObjCall2(manager, "createSceneWithDefinition:initialParameters:", definition, params)
            // 私有全家桶兜底（P0 dump 到的 7 参版）
            if created == nil {
                let selName = "_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:"
                if let mcls = AevonClassOfObject(manager), AevonClassHasInstanceMethod(mcls, selName),
                   let method = class_getInstanceMethod(mcls, NSSelectorFromString(selName)) {
                    typealias C7 = @convention(c) (NSObject, Selector, NSObject, NSObject?, NSObject?, NSObject?, Bool, NSObject?, NSObject?) -> Unmanaged<NSObject>?
                    let fn = unsafeBitCast(method_getImplementation(method), to: C7.self)
                    if let r = fn(manager, NSSelectorFromString(selName), definition, settings, nil, nil, false, nil, nil) {
                        let obj = r.takeRetainedValue()
                        if AevonClassOfObject(obj) != nil { created = obj }
                    }
                }
            }
        }
        AevonCrumbClear()
        if let created {
            AevonLog.info("[场景] P1 第 5 步通过：createScene 已调用，返回 \(AevonSafeClassName(created) ?? "nil")——若创建链成立，屏幕应出现按 266x458 排版的设置场景（AevonSceneDriverP1）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.step6Verify(created: created)
            }
        } else {
            AevonLog.warn("[场景] P1 第 5 步失败：createScene 两路都没走通（本轮到此为止，现有功能不受影响）（AevonSceneDriverP1）")
        }
    }

    /// FBSSceneParameters 构造 + 把 dc / sceneFrame / orientation / settings 全部烙进去
    static func makeSceneParameters(definition: NSObject, settings: NSObject, smallDC: NSObject?) -> NSObject? {
        guard let pcls = AevonClassNamed("FBSSceneParameters"), let params = AevonAllocInstance(pcls) else {
            AevonLog.warn("[场景] P1 第 5 步：FBSSceneParameters 类不存在（createScene 会收到 nil 参数）（AevonSceneDriverP1）")
            return nil
        }
        // settings（FBSSceneParameters 的 ivar 实锤 _settings / _clientSettings / _specification）
        if AevonObjRespondsTo(params, "setSettings:") {
            _ = AevonSafeObjCall1(params, "setSettings:", settings)
        }
        if AevonObjRespondsTo(params, "setClientSettings:") {
            if let client = AevonSafeObjCall(settings, "mutableCopy") {
                _ = AevonSafeObjCall1(params, "setClientSettings:", client)
            }
        }
        if AevonObjRespondsTo(params, "setSpecification:"),
           let spec = AevonSafeObjCall(definition, "specification") {
            _ = AevonSafeObjCall1(params, "setSpecification:", spec)
        }
        // dc 直接烙在 parameters 上（ScreenCore 的 sc_configureInitialParameters 就在做这件事）
        if let smallDC, AevonObjRespondsTo(params, "setDisplayConfiguration:") {
            _ = AevonSafeObjCall1(params, "setDisplayConfiguration:", smallDC)
            AevonLog.info("[场景] P1 已把 266x458 的 dc 烙进 FBSSceneParameters（AevonSceneDriverP1）")
        }
        // sceneFrame / interfaceOrientation 走 KVC（结构体用 NSValue，@try 内）
        let frame = CGRect(origin: .zero, size: AevonSceneDriver.canvasSize)
        let frameValue = NSValue(cgRect: frame)
        var frameDone = false
        for key in ["sceneFrame", "frame"] {
            let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
            if AevonObjRespondsTo(params, setter) {
                _ = AevonSafeObjCall1(params, setter, frameValue)
                frameDone = true
                break
            }
        }
        if !frameDone {
            frameDone = AevonSafeSetValueForKey(params, frameValue, "sceneFrame")
                || AevonSafeSetValueForKey(params, frameValue, "frame")
        }
        var orientationDone = false
        if AevonObjRespondsTo(params, "setInterfaceOrientation:") {
            /* setter 返回 void，垫片按「对象返回」调会拿不到值 —— 调用本身成功即可信，
             * 再用 KVC 补一遍（同一个键，幂等）。 */
            _ = AevonSafeObjCall1(params, "setInterfaceOrientation:", NSNumber(value: 1))
            orientationDone = AevonSafeSetValueForKey(params, NSNumber(value: 1), "interfaceOrientation")
        } else {
            orientationDone = AevonSafeSetValueForKey(params, NSNumber(value: 1), "interfaceOrientation")
        }
        AevonLog.info("[场景] P1 parameters 烙参数：settings/dc/frame=\(frameDone) orientation=\(orientationDone)（AevonSceneDriverP1）")
        return params
    }

    // MARK: 第 6 步：创建后取证

    private func step6Verify(created: NSObject) {
        tryRun("取证") {
            var lines: [String] = []
            if let settings = AevonSafeObjCall(created, "settings") {
                if let frame = AevonSafeValueForKey(settings, "frame") {
                    lines.append("frame=\(frame)")
                }
                /* pixelSize 返回 CGSize **结构体**，走 KVC 取（NSValue 包装，类型安全）。 */
                if let px = AevonSafeValueForKeyPath(settings, "displayConfiguration.pixelSize") {
                    lines.append("dc.pixelSize=\(px)")
                }
            }
            let joined = lines.isEmpty ? "（无可读字段）" : lines.joined(separator: " ")
            AevonLog.info("[场景] P1 取证：创建后 3s 场景状态 → \(joined)（AevonSceneDriverP1）")
        }
    }

    // MARK: - 辅助

    /// 可变场景设置构造（UIMutableApplicationSceneSettings 系）
    private func makeMutableSettings() -> NSObject? {
        for clsName in ["UIMutableApplicationSceneSettings", "FBMutableSceneSettings"] {
            if let cls = AevonClassNamed(clsName), let obj = AevonAllocInstance(cls) {
                return obj
            }
        }
        return nil
    }

    /// 把「小窗尺寸的 dc」烙进 settings（创建时烙定 = ScreenCore/Mango 路线）
    private func bakeGeometry(settings: NSObject, smallDC: NSObject?) {
        let size = AevonSceneDriver.canvasSize
        let frame = CGRect(origin: .zero, size: size)

        // 1) 小窗 dc：优先用母本拷贝；无母本则从零构造（ivar 直写）
        var dc = smallDC
        if dc == nil, let dcls = AevonClassNamed("FBSDisplayConfiguration"),
           let fresh = AevonAllocInstance(dcls) {
            let initSel = NSSelectorFromString("init")
            if let cls = AevonClassOfObject(fresh), let m = class_getInstanceMethod(cls, initSel) {
                typealias Fn0 = @convention(c) (NSObject, Selector) -> Unmanaged<NSObject>?
                _ = unsafeBitCast(method_getImplementation(m), to: Fn0.self)(fresh, initSel)
            }
            _ = AevonSceneDriver.writeCGRectIvar(fresh, "_nativeBounds", frame)
            _ = AevonSceneDriver.writeCGRectIvar(fresh, "_bounds", frame)
            _ = AevonSceneDriver.writeCGSizeIvar(fresh, "_pixelSize",
                                             CGSize(width: size.width * 3, height: size.height * 3))
            dc = fresh
            AevonLog.info("[场景] P1 小窗 dc 从零构造（无母本，ivar 直写 266x458 / 3x 像素）（AevonSceneDriverP1）")
        }

        // 2) 烙进 settings
        if let dc, AevonObjRespondsTo(settings, "setDisplayConfiguration:") {
            _ = AevonSafeObjCall1(settings, "setDisplayConfiguration:", dc)
            AevonLog.info("[场景] P1 已把小窗 dc（266x458）烙进 settings.displayConfiguration（AevonSceneDriverP1）")
        } else {
            AevonLog.warn("[场景] P1 settings 无 setDisplayConfiguration: 入口或小窗 dc 构造失败（AevonSceneDriverP1）")
        }
        var baked = false
        for (selName, key) in [("setFrame:", "frame"), ("setSceneFrame:", "sceneFrame"), ("setSize:", "size")] {
            if AevonObjRespondsTo(settings, selName) {
                let value: NSValue = (key == "size") ? NSValue(cgSize: size) : NSValue(cgRect: frame)
                _ = AevonSafeObjCall1(settings, selName, value)
                // setter 返回 void（垫片拿不到返回值），KVC 再补一遍同键，幂等
                _ = AevonSafeSetValueForKey(settings, value, key)
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
            if let c = AevonSafeObjCall(mainDC, selName) {
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
        guard let cls = AevonClassOfObject(obj),
              let ivar = class_getInstanceVariable(cls, name),
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
