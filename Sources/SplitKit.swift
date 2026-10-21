import Foundation
import UIKit

/// SplitKit 版本号（与 control 保持一致）。
let SKVersion = "0.0.1"

/// dyld 构造函数入口（由 ctor.m 以 C 符号调用）。
/// 约定：本函数绝不抛出、绝不强制解包失败；任何异常路径只记录日志。
@_cdecl("splitkit_initialize")
func splitkitInitialize() {
    initializeSplitKit()
}

private func initializeSplitKit() {
    SKLog.info("SplitKit \(SKVersion) 开始加载 (iOS \(UIDevice.current.systemVersion), 进程 \(ProcessInfo.processInfo.processName))")

    // 1) 开机崩溃守卫必须最先执行
    let safeToContinue = SKCrashGuard.install()
    guard safeToContinue else { return }

    // 2) 总开关（V0.0.1 默认视为开启，因为本版本不 hook 任何系统类）
    let enabled = SKPrefs.bool("Enabled", default: true)
    if !enabled {
        SKLog.info("SplitKit 已在设置中停用，本次加载不执行任何操作。")
        return
    }

    // 3) V0.0.1：安全骨架版，不安装任何 hook，仅确认加载链路可用。
    SKLog.info("SpringBoard 类可用: \(NSClassFromString("SpringBoard") != nil)")
    SKLog.info("SplitKit \(SKVersion) 加载完成（安全骨架版，未启用任何 hook）。")
}
