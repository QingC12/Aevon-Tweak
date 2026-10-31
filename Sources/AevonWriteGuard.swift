import Foundation

/// V0.3.42（AevonWriteGuardV342）：写通道修正 —— 让承载中场景的 `foreground=NO`
/// **根本不落地**。真正的逻辑在 `Sources/AevonSceneWriteGuard.m`（ObjC：写 settings
/// 抛的是 NSException，Swift 抓不到，跑在 SpringBoard 里就是一次注销）。
///
/// 这里只做四件事：①读开关并安装 ②日志桥 ③镜像「哪些场景在浮窗里」④每拍续期。
enum AevonWriteGuard {
    /// 关闭开关（用户可写 `AevonWriteGuardOff342 = true` 回退到 0.3.41 行为）。
    static let disabled: Bool = {
        let v = UserDefaults.standard.object(forKey: "AevonWriteGuardOff342") as? Bool
        return v ?? false
    }()

    /// 安装（每进程一次）。返回是否装上（装上也得有承载场景才生效）。
    static func install() {
        AevonWriteGuardInstall(disabled ? 0 : 1)
    }

    /// 登记 / 注销一个承载场景。开窗时 add、关窗时 remove，由 AevonForegroundManager
    /// 统一镜像过来 —— 未开窗时集合为空，本模块与原生系统行为逐字一致。
    static func setScene(bundleID: String?, sceneID: String?, add: Bool) {
        let flag: Int32 = add ? 1 : 0
        AevonWriteGuardSetSceneEx(bundleID, sceneID, flag)
    }

    /// 续期：窗口看门计时器每拍调用。安全阀 6 秒，防登记泄漏导致永久强撑别人的场景。
    static func refresh() {
        AevonWriteGuardRefresh()
    }

    /// 立刻放行（关窗 / 全屏 App 出现 / 转正交接）。
    static func release() {
        AevonWriteGuardClear()
    }
}

// MARK: - C 桥（实现在 AevonSceneWriteGuard.m）

@_silgen_name("AevonWriteGuardInstall")
private func AevonWriteGuardInstall(_ enabled: Int32)

@_silgen_name("AevonWriteGuardSetScene")
private func AevonWriteGuardSetScene(_ bundleID: UnsafePointer<CChar>?,
                                     _ sceneID: UnsafePointer<CChar>?,
                                     _ add: Int32)

@_silgen_name("AevonWriteGuardRefresh")
private func AevonWriteGuardRefresh()

@_silgen_name("AevonWriteGuardClear")
private func AevonWriteGuardClear()

/// 字符串参数的版本：空串 / nil 都要能传（C 侧按 NULL 处理）。
private func AevonWriteGuardSetSceneEx(_ bundleID: String?, _ sceneID: String?, _ add: Int32) {
    let bid = (bundleID?.isEmpty == false) ? bundleID! : nil
    let sid = (sceneID?.isEmpty == false) ? sceneID! : nil
    if let b = bid, let s = sid {
        b.withCString { bp in s.withCString { sp in AevonWriteGuardSetScene(bp, sp, add) } }
    } else if let b = bid {
        b.withCString { bp in AevonWriteGuardSetScene(bp, nil, add) }
    } else if let s = sid {
        s.withCString { sp in AevonWriteGuardSetScene(nil, sp, add) }
    } else {
        AevonWriteGuardSetScene(nil, nil, add)
    }
}

@_cdecl("AevonWriteGuardLog")
public func AevonWriteGuardLog(_ detail: UnsafePointer<CChar>?) {
    guard let detail else { return }
    AevonLog.info("[拦写] \(String(cString: detail))")
}
