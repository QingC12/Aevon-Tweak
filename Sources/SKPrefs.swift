import Foundation

/// 偏好读写（CFPreferences，与设置界面 Preferences.framework 同一存储域）。
enum SKPrefs {
    static let domain = "com.splitkit.tweak" as CFString

    /// 读取布尔值；键不存在时返回 defaultValue。
    static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber {
            return value.boolValue
        }
        return defaultValue
    }

    /// 读取整数；键不存在时返回 defaultValue。
    static func int(_ key: String, default defaultValue: Int) -> Int {
        if let value = CFPreferencesCopyAppValue(key as CFString, domain) as? NSNumber {
            return value.intValue
        }
        return defaultValue
    }

    /// 写入并立即同步。
    static func set(_ key: String, _ value: Bool) {
        CFPreferencesSetAppValue(key as CFString, value ? true : false, domain)
        CFPreferencesAppSynchronize(domain)
    }

    static func set(_ key: String, _ value: Int) {
        CFPreferencesSetAppValue(key as CFString, NSNumber(value: value), domain)
        CFPreferencesAppSynchronize(domain)
    }
}
