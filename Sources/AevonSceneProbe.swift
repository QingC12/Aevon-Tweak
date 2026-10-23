import Foundation
import UIKit
import ObjectiveC

/// V0.0.66 P0 探测（AevonSceneProbeP0）：真小胖屏「自建场景」路线开工前的运行时判据收集。
///
/// 依据（ScreenCore 2.1.0 逆向，SB 侧为 App 新建正经主场景、创建时烙 dc ——
/// 见 stheno-逆向分析/analysis/Aevon真小胖屏实施方案-2026-10-23.md）：
///   ① SBDeviceApplicationSceneEntity + initWithApplication:generatingNewPrimarySceneIfRequired:
///      sceneHandleProvider:displayIdentity:（生成新主场景实体）
///   ② FBSSceneParameters / FBSMutableSceneDefinition（初始参数容器 + 场景定义）
///   ③ FBSceneManager createSceneWithDefinition:initialParameters:（官方创建 API）
///   ④ FBApplicationProcessLaunchTransaction（随场景拉起 App 进程）
///   ⑤ FBSDisplayConfiguration（主屏 dc 母本来源）
///
/// 安全设计：全部只读（类存在性 / 方法表 / ivar 名单），不创建对象、不调用任何私有方法；
/// 五项各自独立 AevonTryExecute（V62 教训：异常隔离必须逐段）；一次进程只跑一遍；
/// 由设置开关 TrueResizeScene 控制（默认关，关 = 与 V65 行为完全一致）。
enum AevonSceneProbe {
    private static var done = false

    /// 探测结果（供日志汇总）
    private static var r1 = false   // SBDeviceApplicationSceneEntity + 四段 init 选择子
    private static var r2 = false   // FBSSceneParameters + FBSMutableSceneDefinition
    private static var r3 = false   // FBSceneManager + createSceneWithDefinition:initialParameters:
    private static var r4 = false   // FBApplicationProcessLaunchTransaction
    private static var r5 = false   // FBSDisplayConfiguration

    static func runOnceIfNeeded() {
        guard !done else { return }
        done = true
        guard AevonPrefs.bool("TrueResizeScene", default: false) else {
            AevonLog.info("场景探测：TrueResizeScene 未开启，P0 探测跳过（AevonSceneProbeP0）")
            return
        }
        AevonLog.info("场景探测：P0 开始 —— 真小胖屏（自建场景路线）五项判据（AevonSceneProbeP0）")

        var ex: NSString? = nil
        var reason: NSString? = nil

        AevonTryExecute({ probeSceneEntity() }, &ex, &reason)
        if let n = ex { AevonLog.warn("场景探测：①异常 \(n) \(reason ?? "")") }
        ex = nil; reason = nil

        AevonTryExecute({ probeParametersAndDefinition() }, &ex, &reason)
        if let n = ex { AevonLog.warn("场景探测：②异常 \(n) \(reason ?? "")") }
        ex = nil; reason = nil

        AevonTryExecute({ probeSceneManager() }, &ex, &reason)
        if let n = ex { AevonLog.warn("场景探测：③异常 \(n) \(reason ?? "")") }
        ex = nil; reason = nil

        AevonTryExecute({ probeLaunchTransaction() }, &ex, &reason)
        if let n = ex { AevonLog.warn("场景探测：④异常 \(n) \(reason ?? "")") }
        ex = nil; reason = nil

        AevonTryExecute({ probeDisplayConfiguration() }, &ex, &reason)
        if let n = ex { AevonLog.warn("场景探测：⑤异常 \(n) \(reason ?? "")") }

        let pass = [r1, r2, r3, r4, r5].filter { $0 }.count
        AevonLog.info("场景探测：P0 判据汇总 通过\(pass)/5 ①实体=\(r1 ? "过" : "败") ②参数定义=\(r2 ? "过" : "败") ③管理器=\(r3 ? "过" : "败") ④拉起事务=\(r4 ? "过" : "败") ⑤dc=\(r5 ? "过" : "败")")
        AevonLog.info("场景探测：P0 结束（5/5 通过即可进 P1 自建场景概念验证）")
    }

    // MARK: - ① SBDeviceApplicationSceneEntity
    private static func probeSceneEntity() {
        guard let cls = NSClassFromString("SBDeviceApplicationSceneEntity") else {
            AevonLog.warn("场景探测：①SBDeviceApplicationSceneEntity 类不存在")
            return
        }
        let sel = NSSelectorFromString("initWithApplication:generatingNewPrimarySceneIfRequired:sceneHandleProvider:displayIdentity:")
        let has = class_getInstanceMethod(cls, sel) != nil
        AevonLog.info("场景探测：①实体类=在 四段init选择子=\(has ? "在" : "缺") 实例方法=\(methodNames(cls, containing: ["scene", "init"], limit: 18).joined(separator: " | "))")
        r1 = has
    }

    // MARK: - ② FBSSceneParameters / FBSMutableSceneDefinition
    private static func probeParametersAndDefinition() {
        guard let params = NSClassFromString("FBSSceneParameters") else {
            AevonLog.warn("场景探测：②FBSSceneParameters 类不存在")
            return
        }
        let def = NSClassFromString("FBSMutableSceneDefinition") != nil
        let ivars = ivarNames(params, limit: 40)
        let displayMethods = methodNames(params, containing: ["display", "init", "size", "frame"], limit: 18)
        AevonLog.info("场景探测：②参数类=在 定义类(FBSMutableSceneDefinition)=\(def ? "在" : "缺") 参数类ivar=\(ivars.joined(separator: ",")) 参数类方法=\(displayMethods.joined(separator: " | "))")
        r2 = def
    }

    // MARK: - ③ FBSceneManager
    private static func probeSceneManager() {
        guard let mgr = NSClassFromString("FBSceneManager") else {
            AevonLog.warn("场景探测：③FBSceneManager 类不存在")
            return
        }
        // class_getInstanceMethod 会沿父类链找（FBSceneManager 可能继承自基类）
        let sel = NSSelectorFromString("createSceneWithDefinition:initialParameters:")
        let has = class_getInstanceMethod(mgr, sel) != nil
        AevonLog.info("场景探测：③管理器类=在 创建API=\(has ? "在" : "缺") createScene系方法=\(methodNames(mgr, containing: ["createscene", "scene"], limit: 16).joined(separator: " | "))")
        r3 = has
    }

    // MARK: - ④ FBApplicationProcessLaunchTransaction
    private static func probeLaunchTransaction() {
        let cls = NSClassFromString("FBApplicationProcessLaunchTransaction")
        let base = NSClassFromString("FBProcessLaunchTransaction")
        AevonLog.info("场景探测：④拉起事务类=\(cls != nil ? "在" : "缺") 基类(FBProcessLaunchTransaction)=\(base != nil ? "在" : "缺")")
        r4 = (cls != nil)
    }

    // MARK: - ⑤ FBSDisplayConfiguration（主屏 dc 母本来源）
    private static func probeDisplayConfiguration() {
        guard let cls = NSClassFromString("FBSDisplayConfiguration") else {
            AevonLog.warn("场景探测：⑤FBSDisplayConfiguration 类不存在")
            return
        }
        // 类方法（元类）里找「取主屏 dc」的入口，供 P1 直接接线（只 dump 不调用）
        let meta = object_getClass(cls)
        let classMethods = meta != nil ? methodNames(meta!, containing: ["main", "current", "display", "screen"], limit: 20) : []
        let ivars = ivarNames(cls, limit: 40)
        AevonLog.info("场景探测：⑤dc类=在 类方法=\(classMethods.joined(separator: " | ")) dcivar=\(ivars.joined(separator: ","))")
        r5 = true
    }

    // MARK: - 运行时只读辅助
    private static func methodNames(_ cls: AnyClass, containing keys: [String], limit: Int) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [] }
        var out: [String] = []
        for i in 0..<Int(count) {
            let name = NSStringFromSelector(method_getName(list[i]))
            if keys.isEmpty || keys.contains(where: { name.lowercased().contains($0) }) {
                out.append(name)
            }
        }
        return Array(out.prefix(limit))
    }

    private static func ivarNames(_ cls: AnyClass, limit: Int) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyIvarList(cls, &count) else { return [] }
        var out: [String] = []
        for i in 0..<Int(count) {
            if let n = ivar_getName(list[i]) { out.append(String(cString: n)) }
        }
        return Array(out.prefix(limit))
    }
}
