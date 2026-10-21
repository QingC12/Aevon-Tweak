import Foundation

/// 统一日志：系统日志 + 文件日志。
///
/// 文件日志固定写入 `/var/mobile/PullOverMF.log`（Filza 直接可见，
/// 不受 roothide 路径重定向影响），超过 512 KB 自动轮转一个 `.old` 备份。
/// 该路径为项目约定，不随插件改名而变化。
///
/// 说明：不用 OSLog 的 Swift 字符串插值 API（`Logger` + `\(x, privacy:)`），
/// 该插值 API 在部分 SDK 版本上存在兼容问题；NSLog 在各版本 SDK 上行为一致。
enum SKLog {
    static let filePath = "/var/mobile/PullOverMF.log"
    private static let tag = "SplitKit"
    private static let maxBytes: UInt64 = 512 * 1024
    private static let lock = NSLock()
    /// 写盘不可用时置 false，避免每次写日志都重复失败（例如权限异常）。
    private static var fileLogAvailable = true

    static func info(_ message: String) {
        emit("信息", message)
    }

    static func warn(_ message: String) {
        emit("警告", message)
    }

    static func error(_ message: String) {
        emit("错误", message)
    }

    private static func emit(_ level: String, _ message: String) {
        NSLog("[%@][%@] %@", tag as NSString, level as NSString, message as NSString)
        guard SKPrefs.bool("LogEnabled", default: true) else { return }
        append("[\(timestamp())] [\(level)] \(message)\r\n")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard fileLogAvailable else { return }

        let manager = FileManager.default
        if !manager.fileExists(atPath: filePath) {
            guard manager.createFile(atPath: filePath, contents: nil) else {
                fileLogAvailable = false
                return
            }
        }
        rotateIfNeeded(incoming: UInt64(data.count), manager: manager)
        guard let handle = FileHandle(forWritingAtPath: filePath) else {
            fileLogAvailable = false
            return
        }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    /// 超过上限时把旧文件改名为 `.old`（只保留一份备份），保证长时间运行不会撑爆磁盘。
    private static func rotateIfNeeded(incoming: UInt64, manager: FileManager) {
        guard let attributes = try? manager.attributesOfItem(atPath: filePath),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        guard size + incoming > maxBytes else { return }
        let backup = filePath + ".old"
        try? manager.removeItem(atPath: backup)
        try? manager.moveItem(atPath: filePath, toPath: backup)
        _ = manager.createFile(atPath: filePath, contents: nil)
    }
}
