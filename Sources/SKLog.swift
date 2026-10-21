import Foundation

/// 统一日志。写入系统日志（可用 `log stream` 或 Console.app 查看）。
/// 说明：不用 OSLog 的 Swift 字符串插值 API（`Logger` + `\(x, privacy:)`），
/// 该插值 API 在部分 SDK 版本上存在兼容问题；NSLog 在各版本 SDK 上行为一致。
enum SKLog {
    static func info(_ message: String) {
        NSLog("[SplitKit] %@", message as NSString)
    }

    static func warn(_ message: String) {
        NSLog("[SplitKit][警告] %@", message as NSString)
    }
}
