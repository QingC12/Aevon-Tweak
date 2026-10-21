import Foundation

/// 开机崩溃守卫（卡开机保护）：
///
/// 1. 插件加载时把状态置为 `loading`；
/// 2. SpringBoard 稳定运行 20 秒后把状态置为 `healthy`；
/// 3. 若本次加载时发现上次状态仍是 `loading`，说明上次加载后 SpringBoard 崩溃了，
///    立即自动禁用插件（Enabled=NO）并恢复 healthy，从而阻断「崩溃→重启→再崩溃」的死循环。
///
/// 用户可在 设置 → Aevon 中重新打开开关。
enum AevonCrashGuard {
    private static let stateKey = "AevonGuardState"
    private static let enabledKey = "Enabled"
    private static let guardKey = "CrashGuard"

    private enum State: Int {
        case unknown = 0
        case loading = 1
        case healthy = 2
    }

    private static var current: State {
        let raw = AevonPrefs.rawValue(stateKey) as? NSNumber
        return State(rawValue: raw?.intValue ?? 0) ?? .unknown
    }

    /// 在插件构造函数中最早调用。返回 false 表示本次加载应当整体中止（已自动禁用）。
    @discardableResult
    static func install() -> Bool {
        let previous = current

        if previous == .loading {
            // 上次加载后 SpringBoard 未能稳定运行 → 判定为插件导致崩溃，自动禁用。
            AevonPrefs.set(enabledKey, false)
            AevonPrefs.set(stateKey, State.healthy.rawValue)
            AevonLog.warn("[崩溃保护] 检测到上次加载后 SpringBoard 未稳定运行，已自动禁用 Aevon；如需重新启用请前往 设置 → Aevon。")
            return false
        }

        guard AevonPrefs.bool(guardKey, default: true) else {
            AevonPrefs.set(stateKey, State.healthy.rawValue)
            return true
        }

        AevonPrefs.set(stateKey, State.loading.rawValue)

        // 主队列延迟执行：若 20 秒内 SpringBoard 崩溃，状态停留在 loading，
        // 下一次加载就会触发自动禁用。
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            AevonPrefs.set(stateKey, State.healthy.rawValue)
            AevonLog.info("[崩溃保护] 本次加载已标记为健康。")
        }
        return true
    }
}
