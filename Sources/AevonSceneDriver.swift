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

    /// prefschanged 回调入口：开关从关到开才触发（5s 错峰，给设置页留写盘时间）
    func maybeRunExperiment() {
        guard AevonPrefs.bool("AevonTrueResizeP1", default: false) else {
            ranForThisToggle = false
            return
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
        self.step1SceneManager()
        self.running = false
    }

    // MARK: 第 1 步：FBSceneManager 实例

    private func step1SceneManager() {
        var manager: NSObject? = nil
        tryRun("第1步") {
            manager = AevonSceneDriver.findSceneManager()
        }
        guard let manager else {
            AevonLog.warn("[场景] P1 第 1 步失败：拿不到 FBSceneManager 实例（AevonSceneDriverP1）")
            return
        }
        AevonLog.info("[场景] P1 第 1 步通过：FBSceneManager = \(String(describing: type(of: manager)))（AevonSceneDriverP1）")
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
                if let m = (ws as NSObject).perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? NSObject {
                    if String(describing: type(of: m)).contains("SceneManager") { return m }
                }
            }
        }
        return nil
    }

    private static func tryShared(classNamed: String, selector: String) -> NSObject? {
        guard let cls = NSClassFromString(classNamed) as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString(selector)
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    // MARK: 第 2 步：主屏显示配置母本

    private func step2MainDisplayConfig(manager: NSObject) {
        var dc: NSObject? = nil
        tryRun("第2步") {
            dc = AevonSceneDriver.findMainDisplayConfiguration(manager: manager)
        }
        if let dc {
            AevonLog.info("[场景] P1 第 2 步通过：主屏 dc 母本 = \(String(describing: type(of: dc)))（AevonSceneDriverP1）")
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
               let r = manager.perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? NSObject {
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
                       let r = dm.perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? NSObject {
                        if String(describing: type(of: r)).contains("DisplayConfiguration") { return r }
                        // SBFDisplay 之类再向下钻一层
                        for sel2 in ["displayConfiguration", "mainDisplayConfiguration"] {
                            if r.responds(to: NSSelectorFromString(sel2)),
                               let r2 = r.perform(NSSelectorFromString(sel2))?.takeUnretainedValue() as? NSObject,
                               String(describing: type(of: r2)).contains("DisplayConfiguration") {
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
                   let scene = ws.perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? NSObject,
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
           let settings = scene.perform(NSSelectorFromString("settings"))?.takeUnretainedValue() as? NSObject {
            for sel in ["displayConfiguration", "displayConfigurationLayout"] {
                if settings.responds(to: NSSelectorFromString(sel)),
                   let r = settings.perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? NSObject,
                   String(describing: type(of: r)).contains("DisplayConfiguration") {
                    return r
                }
            }
        }
        return nil
    }

    // MARK: 第 3 步：目标 App 的 SBApplication

    private func step3Application(manager: NSObject, mainDC: NSObject?) {
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
                       let a = ctrl.perform(sel, with: AevonSceneDriver.experimentBundleID)?
                           .takeUnretainedValue() as? NSObject {
                        app = a
                        break
                    }
                }
            }
        }
        if let app {
            AevonLog.info("[场景] P1 第 3 步通过：SBApplication = \(String(describing: type(of: app)))（AevonSceneDriverP1）")
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
               let c = (cls as AnyObject).perform(sel)?.takeUnretainedValue() as? NSObject {
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

    // MARK: 第 4 步：SBDeviceApplicationSceneEntity 四段 init

    private func step4SceneEntity(manager: NSObject, app: NSObject, mainDC: NSObject?) {
        var entity: NSObject? = nil
        tryRun("第4步") {
            guard let cls = NSClassFromString("SBDeviceApplicationSceneEntity") else { return }
            let sel = NSSelectorFromString("initWithApplication:generatingNewPrimarySceneIfRequired:sceneHandleProvider:displayIdentity:")
            guard let alloced = AevonSceneDriver.allocObj(cls) else { return }
            guard let method = class_getInstanceMethod(type(of: alloced), sel) else { return }
            let imp = method_getImplementation(method)
            // @convention(c)：receiver + SEL + (SBApplication, BOOL, provider?, identity?) → Unmanaged
            typealias Init4 = @convention(c) (NSObject, Selector, NSObject, Bool, NSObject?, NSObject?) -> Unmanaged<NSObject>?
            let fn = unsafeBitCast(imp, to: Init4.self)
            entity = fn(alloced, sel, app, true, nil, nil)?.takeRetainedValue()
        }
        guard let entity else {
            AevonLog.warn("[场景] P1 第 4 步失败：SBDeviceApplicationSceneEntity 四段 init 构造不出实体（AevonSceneDriverP1）")
            return
        }
        AevonLog.info("[场景] P1 第 4 步通过：sceneEntity 已构造（AevonSceneDriverP1）")
        self.step5Create(manager: manager, entity: entity, mainDC: mainDC)
    }

    // MARK: 第 5 步：场景设置（烙 dc + 小窗 frame）+ createScene

    private func step5Create(manager: NSObject, entity: NSObject, mainDC: NSObject?) {
        var created: NSObject? = nil
        tryRun("第5步") {
            let definition = entity.perform(NSSelectorFromString("sceneDefinition"))?
                .takeUnretainedValue() as? NSObject
            guard let definition else {
                AevonLog.warn("[场景] P1 第 5 步：entity 上拿不到 sceneDefinition（AevonSceneDriverP1）")
                return
            }
            let settings = self.makeMutableSettings()
            self.bakeGeometry(settings: settings, mainDC: mainDC)
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
                created = manager.perform(sel, with: definition, with: params)?
                    .takeUnretainedValue() as? NSObject
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
            AevonLog.info("[场景] P1 第 5 步通过：createScene 已调用，返回 \(String(describing: type(of: created)))——若创建链成立，屏幕应出现按 266x458 排版的设置场景（AevonSceneDriverP1）")
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
               let settings = created.perform(NSSelectorFromString("settings"))?
                   .takeUnretainedValue() as? NSObject {
                if let frame = settings.value(forKey: "frame") {
                    lines.append("frame=\(frame)")
                }
                if settings.responds(to: NSSelectorFromString("displayConfiguration")),
                   let dc = settings.perform(NSSelectorFromString("displayConfiguration"))?
                       .takeUnretainedValue() as? NSObject,
                   dc.responds(to: NSSelectorFromString("pixelSize")),
                   let px = dc.perform(NSSelectorFromString("pixelSize"))?
                       .takeUnretainedValue() {
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
        guard let obj = (cls as AnyObject).perform(sel)?.takeUnretainedValue() as? NSObject else { return nil }
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
            settings.perform(dcSel, with: smallDC)
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
            if mainDC.responds(to: sel), let c = mainDC.perform(sel)?.takeUnretainedValue() as? NSObject {
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
