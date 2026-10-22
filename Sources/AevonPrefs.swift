import Foundation

/// 偏好读写（CFPreferences，与设置界面 Preferences.framework 同一存储域）。
enum AevonPrefs {
    static let domain = "com.Aevon" as CFString

    /// 读取原始值；键不存在时返回 nil。
    static func rawValue(_ key: String) -> Any? {
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    /// 让进程内的 CFPreferences 缓存失效，重新从 cfprefsd 取最新值。
    ///
    /// 设置 App 是**另一个进程**，它改完 `com.Aevon` 之后 SpringBoard 这边的
    /// `CFPreferencesCopyAppValue` 可能还在吐老值 —— 表现就是「设置里拖了滑杆，
    /// 触发条位置纹丝不动」。只在**低频轮询 / 收到变更通知**时调用，
    /// 不要放进每次触摸的判定路径（那是 IPC，会拖慢触摸响应）。
    static func synchronize() {
        CFPreferencesAppSynchronize(domain)
    }

    /// 读取布尔值；键不存在时返回 defaultValue。
    static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = rawValue(key) as? NSNumber {
            return value.boolValue
        }
        return defaultValue
    }

    /// 读取整数；键不存在时返回 defaultValue。
    static func int(_ key: String, default defaultValue: Int) -> Int {
        if let value = rawValue(key) as? NSNumber {
            return value.intValue
        }
        return defaultValue
    }

    /// 读取浮点；同时兼容设置页滑杆写进来的 NSNumber 与被手工改成的字符串。
    static func double(_ key: String, default defaultValue: Double) -> Double {
        if let value = rawValue(key) as? NSNumber {
            return value.doubleValue
        }
        if let text = rawValue(key) as? String, let parsed = Double(text) {
            return parsed
        }
        return defaultValue
    }

    /// 写入布尔值并立即同步（经 Objective-C 垫片调用 CFPreferences）。
    static func set(_ key: String, _ value: Bool) {
        AevonPrefSetBool(key, value)
    }

    /// 写入整数并立即同步（经 Objective-C 垫片调用 CFPreferences）。
    static func set(_ key: String, _ value: Int) {
        AevonPrefSetInt(key, value)
    }

    /// 写入浮点并立即同步（V0.0.30：触发区底边语义迁移用）。
    static func set(_ key: String, _ value: Double) {
        AevonPrefSetDouble(key, value)
    }
}
