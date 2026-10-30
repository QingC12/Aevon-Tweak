import Foundation

/// 统一日志：系统日志 + 文件日志。
///
/// 文件日志固定写入 `/var/mobile/Aevon.log`（Filza 直接可见，
/// 不受 roothide 路径重定向影响），超过 512 KB 自动轮转一个 `.old` 备份。
///
/// 说明：不用 OSLog 的 Swift 字符串插值 API（`Logger` + `\(x, privacy:)`），
/// 该插值 API 在部分 SDK 版本上存在兼容问题；NSLog 在各版本 SDK 上行为一致。
enum AevonLog {
    static let filePath = "/var/mobile/Aevon.log"
    private static let tag = "Aevon"
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
        guard AevonPrefs.bool("LogEnabled", default: true) else { return }
        /* V0.3.19（AevonHoverTrailV319）：时间戳与落盘合并到同一把锁内。
         * 以前 `timestamp()` 每次 `DateFormatter()` 新建一个（分配 + 解析一遍格式串），
         * `append` 又各自加锁 —— Aevon(95) 峰值 62 行/秒全在触摸热路径上。
         * 现在 formatter 是静态单例、一次锁住整条写路径。 */
        lock.lock()
        defer { lock.unlock() }
        guard fileLogAvailable else { return }
        append("[\(timestampLocked())] [\(level)] \(message)\r\n")
    }

    /// V0.3.19（AevonHoverTrailV319）：复用同一个 formatter（`DateFormatter` 的构造
    /// 是重活，每条日志新建一次在 60~120Hz 的触摸路径上足以掉帧）。
    /// ⛔ 只能在持有 `lock` 时调 —— `DateFormatter` 的格式化不是线程安全的。
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func timestampLocked() -> String {
        return formatter.string(from: Date())
    }

    /// ⛔ 调用方必须已持有 `lock`。
    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
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

/// 关键路径首次触发记录：只写第一次，既能定位「崩溃前最后走到哪一步」，又不会刷屏。
enum AevonTrace {
    private static var seen = Set<String>()
    private static let lock = NSLock()

    static func once(_ key: String, _ message: @autoclosure () -> String) {
        lock.lock()
        if seen.contains(key) {
            lock.unlock()
            return
        }
        seen.insert(key)
        lock.unlock()
        AevonLog.info("[触发] \(message())")
    }
}
