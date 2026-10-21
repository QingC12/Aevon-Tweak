import Foundation
import OSLog

/// 统一日志。使用系统 os_log，可通过 `log stream` 或控制台查看。
enum SKLog {
    static let logger = Logger(subsystem: "com.splitkit.tweak", category: "SplitKit")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func warn(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
