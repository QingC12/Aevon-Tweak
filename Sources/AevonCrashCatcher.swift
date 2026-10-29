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
private let kOwnerPath = "/var/mobile/Aevon.crash.owner"

/* V0.2.83（AevonCrashPCV283）：老的「一参数 signal + backtrace」处理器整体退休，
 * 处理器搬去 AevonAssertionShim.m 的 C 实现（sigaction + SA_SIGINFO + ucontext）。
 *
 * 退休理由（不是重构癖，是 0.2.82 崩溃日志实打实核对出来的）：
 * 老 handler 只拿得到信号编号，栈靠 `backtrace()`。而 backtrace 在信号处理器里
 * 走的是**处理器自己的 fp 链**，0.2.82 那份日志反汇编后是：
 *     帧0 0xf6fc = `bl AevonBacktrace` 的返回点
 *     帧1 0xf700 = handler 里 `mov x23,x0`（调用 AevonBacktrace 的那一行）
 *     帧2        = libsystem_platform（sigtramp）
 *     帧3..      = 0x43c54 一带反复跳（根本不是调用链）
 * 于是「归因：Aevon 参与崩溃」这条结论本身也没有依据 —— 它只是在一堆假的帧里
 * 找到了一条恰好落在自己地址段内的记录。两版都在这上面猜，白烧时间。
 *
 * 现在 handler 直接读 ucontext 的 pc（就是触发 SIGSEGV 的那条指令）、lr、sp、fp，
 * 并自己遍历 fp 链；每帧标 [A]（在 Aevon 内）/ [.]（不在）。归因文件规则不变。
 * 上面这些常量仅 `write(_:)`（ObjC 异常路径）还在用，保留。 */


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
        /* V0.2.83（AevonCrashPCV283）：信号处理器改由 C 侧 `sigaction + SA_SIGINFO`
         * 安装（读 ucontext 拿崩溃指令 pc / lr / sp / fp）。这里不再装 `signal()`。 */
        AevonCrashInstall()
        // V0.0.40（AevonCrashAttrV40）：先算好自身地址段，信号处理里做纯指针归因
        AevonCrashAttrPrepare()
    }

    /// 读崩溃归因标记（信号处理写下的 owner 文件）："aevon" / "external" / nil。
    /// 读完即删——一次崩溃只归因一次。
    static func takeCrashAttribution() -> String? {
        let manager = FileManager.default
        guard let data = manager.contents(atPath: kOwnerPath),
              let text = String(data: data, encoding: .utf8) else { return nil }
        try? manager.removeItem(atPath: kOwnerPath)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
