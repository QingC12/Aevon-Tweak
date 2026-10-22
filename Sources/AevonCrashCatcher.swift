import Foundation
import Darwin

/*
 * 崩溃捕获（V0.0.6 新增）
 * =====================================================================
 * 目的：插件一旦让 SpringBoard 崩溃，用户只能看到「安全模式」，日志里没有
 * 任何堆栈，无法定位。这里把两类致命信息写到 /var/mobile/Aevon.crash.log：
 *   1) Objective-C 未捕获异常（NSException）：名称、原因、完整调用栈；
 *   2) 致命信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGTRAP/SIGFPE）：只写信号编号。
 * 信号处理函数里只能调用 async-signal-safe 的 open/write/close，不能碰
 * NSString / NSLog / Swift 字符串插值，因此下面全部使用预分配的 C 字节数组。
 *
 * 下一次进程启动时，AevonCrashGuard 会把它并入 Aevon.log（然后改名为 .old），
 * 这样一次「安全模式」之后回传的日志里就能看到崩溃原因。
 * =====================================================================
 */

private let kCrashLogPath = "/var/mobile/Aevon.crash.log"
private let kCrashLogPathBytes: [CChar] = Array(kCrashLogPath.utf8CString)
private let kSignalTextBytes: [CChar] = Array("[崩溃] 捕获到致命信号，编号=".utf8CString)
private let kBacktraceTitleBytes: [CChar] = Array("[崩溃] 调用栈回溯（模块+偏移，供离线符号化；AevonCrashTraceV39）\n".utf8CString)
private let kSignalTailBytes: [CChar] = Array("（SpringBoard 即将退出）\n".utf8CString)

/// 致命信号处理：先落盘（信号编号 + 调用栈回溯），再恢复默认处理并重新抛出。
///
/// V0.0.39（AevonCrashTraceV39）：之前只写信号编号，SIGSEGV 完全无法定位
/// （真机 Aevon(32)：连续自动注销，崩溃记录只有一行「编号=11」）。
/// 这里在信号处理里调 `backtrace` + `backtrace_symbols_fd` 把当前线程调用栈
/// （模块 + 偏移）直接写进崩溃文件 —— `backtrace_symbols_fd` 官方保证不走 malloc，
/// 是信号处理里唯一安全的符号化方式；拿不到符号也有模块偏移可供离线对照。
private func aevonSignalHandler(_ signalNumber: Int32) {
    let fd = kCrashLogPathBytes.withUnsafeBufferPointer { buffer -> Int32 in
        guard let base = buffer.baseAddress else { return -1 }
        return open(base, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    if fd >= 0 {
        _ = kSignalTextBytes.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count - 1)
        }

        var value = signalNumber
        if value < 0 { value = 0 }
        var digits: [CChar] = [0, 0]
        var length = 1
        if value >= 10 {
            digits[0] = CChar(48 + (value / 10) % 10)
            digits[1] = CChar(48 + value % 10)
            length = 2
        } else {
            digits[0] = CChar(48 + value % 10)
        }
        _ = write(fd, digits, length)

        _ = kSignalTailBytes.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count - 1)
        }

        // 调用栈回溯：本线程 64 帧，模块+偏移直接写 fd（不走 malloc）
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, 64)
        if count > 0 {
            _ = kBacktraceTitleBytes.withUnsafeBufferPointer { buffer in
                write(fd, buffer.baseAddress, buffer.count - 1)
            }
            backtrace_symbols_fd(&frames, Int32(count), fd)
        }
        close(fd)
    }

    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// 未捕获异常处理：此时进程仍可正常调用 Foundation，直接写完整堆栈。
private func aevonExceptionHandler(_ exception: NSException) {
    let name = exception.name.rawValue
    let reason = exception.reason ?? "(无描述)"
    let symbols = exception.callStackSymbols.joined(separator: "\n")
    let text = "[崩溃] 未捕获异常 \(name): \(reason)\n调用栈:\n\(symbols)\n"
    AevonCrashCatcher.write(text)
}

enum AevonCrashCatcher {
    static let path = kCrashLogPath
    private static let backupPath = kCrashLogPath + ".old"
    private static let lock = NSLock()
    private static var installed = false

    /// 安装异常与信号捕获（幂等，最多执行一次）。
    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        NSSetUncaughtExceptionHandler(aevonExceptionHandler)
        let handler: @convention(c) (Int32) -> Void = aevonSignalHandler
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            _ = signal(sig, handler)
        }
    }

    /// 把上一次进程留下的崩溃记录并入主日志，并归档为 .old（只保留一份）。
    static func harvestPreviousCrash() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return }

        if let data = manager.contents(atPath: path),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            let head = String(text.prefix(4000))
            AevonLog.warn("[崩溃记录] 上次运行留下崩溃信息，摘录如下：\n\(head)")
        }

        try? manager.removeItem(atPath: backupPath)
        try? manager.moveItem(atPath: path, toPath: backupPath)
    }

    /// 正常路径下的写文件（带锁，失败静默）。
    static func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: path) {
            _ = manager.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}
