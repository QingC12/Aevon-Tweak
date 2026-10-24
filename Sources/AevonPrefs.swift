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

    /// V0.0.84（AevonPrefShieldV84）：把原始值打成人能看的一行，用于「开关明明是开却读到 false」这类排查。
    ///
    /// 只用来写日志，不进触摸判定路径（会多一次 NSNumber/NSString 装箱）。
    static func debugDescribe(_ key: String) -> String {
        guard let value = rawValue(key) else { return "缺省(nil)" }
        return "\(value) [\(type(of: value))]"
    }

    /// V0.0.84（AevonPrefShieldV84）：一次性自愈 —— `TouchEnabled` 为 false 时改回 true。
    ///
    /// 为什么必须自愈：这个开关一旦是 false，旧实现会把浮窗内容的宿主容器
    /// `isUserInteractionEnabled` 压成 false。容器一关，UIKit 的 hitTest 直接返回 nil，
    /// **SpringBoard 就不再接手这根手指**，事件被原样转投给背后的全屏 App —— 表现就是
    /// 「在悬浮窗里滑动，背后 App 自己滚到底」。这不是「浮窗内容被禁用」，是「浮窗整块透明」。
    /// 用户不会想要这种状态（浮窗里什么都点不动），而且 V0.0.84 起已经改成
    /// 「容器恒可交互 + 上方盖一层拦截层」，这个开关只决定拦截层开不开。
    /// 老版本可能把它写成了 false，这里做一次迁移，把状态摆回用户直觉的开。
    static func healTouchEnabledOnce() {
        let marker = "TouchEnabledHealV84"
        if rawValue(marker) != nil { return }
        let current = bool("TouchEnabled", default: true)
        if !current {
            set("TouchEnabled", true)
            AevonLog.warn("[设置] 浮窗内容触摸开关原来是**关**的（TouchEnabled=\(debugDescribe("TouchEnabled"))）"
                + " → 已一次性改回开；这个状态下浮窗内容完全收不到触摸，"
                + "所有滑动都会直接落到背后的全屏 App（AevonPrefShieldV84 TouchEnabledHealV84）")
        } else {
            AevonLog.info("[设置] 浮窗内容触摸开关=开（TouchEnabled=\(debugDescribe("TouchEnabled"))）"
                + "（AevonPrefShieldV84）")
        }
        set(marker, true)
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
