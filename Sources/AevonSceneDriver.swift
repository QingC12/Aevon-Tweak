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
    private func tryRun(_ tag: String, _ body: () -> Void) {
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
            AevonLog.warn("[场景] P1 第 2 步降级：没拿到主屏 dc 母本，走「创建参数不携带 dc」的裸创建（App 大概率仍整屏重排，日志如实记录）（AevonSceneDriverP1）")
        }
        self.step3Application(manager: manager, mainDC: dc)
    }

    /// 主屏 dc 多路探测（ScreenCore 的 sc_mainDisplayConfiguration 对应物）
    static func findMainDisplayConfiguration(manager: NSObject) -> NSObject? {
        for sel in ["mainDisplayConfiguration", "displayConfiguration", "primaryDisplayConfiguration"] {
            if manager.responds(to: NSSelectorFromString(sel)),
               let r = manager.perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? NSObject {
                return r
            }
        }
        for (clsName, selName) in [("SBFDisplayManager", "sharedInstance"), ("SBFDisplayManager", "mainDisplayManager")] {
            if let dm = tryShared(classNamed: clsName, selector: selName) {
                for sel in ["mainDisplayConfiguration", "displayConfiguration", "mainScreenDisplayConfiguration"] {
                    if dm.responds(to: NSSelectorFromString(sel)),
                       let r = dm.perform(NSSelectorFromString(sel))?.takeUnretainedValue() as? NSObject {
                        return r
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
        tryRun("第3步") {
            let ctrlSel = NSSelectorFromString("sharedApplicationController")
            if let cls = NSClassFromString("SBApplicationController") as? NSObject.Type,
               cls.responds(to: ctrlSel),
               let ctrl = cls.perform(ctrlSel)?.takeUnretainedValue() as? NSObject {
                app = ctrl.perform(NSSelectorFromString("applicationWithBundleIdentifier:"),
                                   with: AevonSceneDriver.experimentBundleID)?
                    .takeUnretainedValue() as? NSObject
            }
        }
        if let app {
            AevonLog.info("[场景] P1 第 3 步通过：SBApplication = \(String(describing: type(of: app)))（AevonSceneDriverP1）")
        } else {
            AevonLog.warn("[场景] P1 第 3 步失败：拿不到 \(AevonSceneDriver.experimentBundleID) 的 SBApplication（AevonSceneDriverP1）")
            return
        }
        self.step4SceneEntity(manager: manager, app: app, mainDC: mainDC)
    }

    // MARK: 第 4 步：SBDeviceApplicationSceneEntity 四段 init

    private func step4SceneEntity(manager: NSObject, app: NSObject, mainDC: NSObject?) {
        var entity: NSObject? = nil
        tryRun("第4步") {
            guard let cls = NSClassFromString("SBDeviceApplicationSceneEntity") as? NSObject.Type else { return }
            let sel = NSSelectorFromString("initWithApplication:generatingNewPrimarySceneIfRequired:sceneHandleProvider:displayIdentity:")
            let alloced = cls.alloc()
            guard let imp = type(of: alloced).instanceMethod(for: sel) else { return }
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
                if let pcls = NSClassFromString("FBSSceneParameters") as? NSObject.Type {
                    let single = NSSelectorFromString("initWithSettings:")
                    let alloced = pcls.alloc()
                    if let imp = type(of: alloced).instanceMethod(for: single) {
                        typealias Fn1 = @convention(c) (NSObject, Selector, NSObject?) -> Unmanaged<NSObject>?
                        params = unsafeBitCast(imp, to: Fn1.self)(alloced, single, settings)?.takeRetainedValue()
                    }
                    if params == nil { params = alloced }
                }
                created = manager.perform(sel, with: definition, with: params)?
                    .takeUnretainedValue() as? NSObject
            }
            // 私有全家桶兜底（P0 dump 到的 7 参版）
            if created == nil {
                let sel2 = NSSelectorFromString("_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:")
                if let imp = type(of: manager).instanceMethod(for: sel2) {
                    typealias C7 = @convention(c) (NSObject, Selector, NSObject, NSObject?, NSObject?, NSObject?, Bool, NSObject?, NSObject?) -> Unmanaged<NSObject>?
                    let fn = unsafeBitCast(imp, to: C7.self)
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
            if let cls = NSClassFromString(clsName) as? NSObject.Type {
                return cls.alloc()
            }
        }
        return NSObject()
    }

    /// 把 dc 母本 + 小窗尺寸烙进 settings（创建时烙定 = ScreenCore 路线）
    private func bakeGeometry(settings: NSObject, mainDC: NSObject?) {
        let dcSel = NSSelectorFromString("setDisplayConfiguration:")
        if settings.responds(to: dcSel), let mainDC {
            settings.perform(dcSel, with: mainDC)
            AevonLog.info("[场景] P1 已把主屏 dc 母本烙进 settings.displayConfiguration（创建时拷贝定尺寸）（AevonSceneDriverP1）")
        } else {
            AevonLog.warn("[场景] P1 settings 无 setDisplayConfiguration: 入口或无 dc 母本（AevonSceneDriverP1）")
        }
        let size = AevonSceneDriver.canvasSize
        let frame = CGRect(origin: .zero, size: size)
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
}
