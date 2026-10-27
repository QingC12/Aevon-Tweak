import Foundation

/// App 侧探针日志桥（V0.2.0，AevonAppSideBridgeV200）
///
/// 背景：App 进程受沙盒限制，写不了 `/var/mobile/Aevon.log`。所以 App 侧把日志写进
/// **自己 bundleID 的偏好域**（`AevonAppProbe` 全量文本 + `AevonAppProbeSeq` 序号），
/// 这个域就是 App 自己的偏好文件，沙盒 100% 允许。SpringBoard 是特权进程、能读任意域，
/// 这里每 2 秒读一次，按「已输出行数」把新增部分转写进 `/var/mobile/Aevon.log`。
///
/// 为什么不用 Darwin 通知：Darwin 通知带不了文本。路 B 的下一步（判向成功 → 呼圆盘）
/// 确实要靠通知，那是 0.2.1 的事；这一版先把「App 侧到底看到了什么」这条链路打通。
///
/// 两条读取路径都保留：CFPreferences 走 cfprefsd 缓存（最新），
/// plist 文件是缓存异常时的兜底 —— 这是 0.2.0 唯一需要验证的「读侧」能力。
enum AevonAppSideBridge {
    /// 只有这两个域会有人写（与 AevonApp.plist 的 Filter 一致）
    private static let watchedDomains = ["com.apple.mobilesafari", "com.apple.Preferences"]
    /// V0.2.5（AevonAppProbeWideV205）：0.2.4 起 App 侧注入全部 App，沙盒 App
    /// 写不了 /var/mobile/Aevon.log，只会写**自己 bundleID 的域** —— 桥必须跟着
    /// 扩容，否则第三方 App 的 App 侧行为全程不可见（Aevon(91) 实证：威锋 / Turrit
    /// 开了浮窗却一条日志都没有）。域来源 = SB 场景钩子解析出的前台 bundleID。
    private static var extraDomains: Set<String> = []
    private static var lastSeq: [String: Int] = [:]
    private static var lastLineCount: [String: Int] = [:]
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
            drain()
        }
        RunLoop.main.add(timer, forMode: .common)
        AevonLog.info("[App侧桥接] 已启动：每 2 秒读一次 \(watchedDomains.joined(separator: " / ")) 的 AevonAppProbe（AevonAppSideBridgeV200 AevonAppProbeWideV205）")
    }

    /// SB 场景钩子解析出的前台 App bundleID → 加入监听（幂等）
    static func noteDomain(_ domain: String) {
        guard !domain.isEmpty,
              domain != "com.apple.springboard",
              !watchedDomains.contains(domain),
              extraDomains.insert(domain).inserted else { return }
        AevonLog.info("[App侧桥接] 监听域 +\(domain)（AevonAppProbeWideV205）")
    }

    private static func drain() {
        // V0.2.51（AevonGripOnlyV251）：AppSideEnabled 闸已随 App 侧识别器退役 ——
        // App 侧只剩日志桥 + scene takeover/screen fit（无开关），桥保持常开。
        let domains = watchedDomains + extraDomains.sorted()
        for domain in domains {
            guard let text = probeText(domain: domain) else { continue }
            let seq = probeSeq(domain: domain)
            guard seq > (lastSeq[domain] ?? 0) else { continue }
            lastSeq[domain] = seq
            emit(text: text, domain: domain, seq: seq)
        }
    }

    private static func probeText(domain: String) -> String? {
        // ① cfprefsd 缓存（最新，跨进程实时）
        if let value = CFPreferencesCopyAppValue("AevonAppProbe" as CFString, domain as CFString) {
            if let text = value as? String, !text.isEmpty { return text }
        }
        // ② plist 文件兜底
        let path = "/var/mobile/Library/Preferences/\(domain).plist"
        if let dict = NSDictionary(contentsOfFile: path),
           let text = dict["AevonAppProbe"] as? String,
           !text.isEmpty {
            return text
        }
        return nil
    }

    private static func probeSeq(domain: String) -> Int {
        if let value = CFPreferencesCopyAppValue("AevonAppProbeSeq" as CFString, domain as CFString),
           let number = value as? NSNumber {
            return number.intValue
        }
        let path = "/var/mobile/Library/Preferences/\(domain).plist"
        if let dict = NSDictionary(contentsOfFile: path),
           let number = dict["AevonAppProbeSeq"] as? NSNumber {
            return number.intValue
        }
        return 0
    }

    private static func emit(text: String, domain: String, seq: Int) {
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let already = lastLineCount[domain] ?? 0
        // 缓冲区到上限会裁掉最早的三分之一，行数会回退 —— 此时只补最后 10 行，不做重放
        let start = lines.count >= already ? already : max(0, lines.count - 10)
        guard start < lines.count else {
            lastLineCount[domain] = lines.count
            return
        }
        AevonLog.info("[App侧桥接] \(domain) 新增 \(lines.count - start) 行（序号 \(seq)）")
        for line in lines[start...] {
            AevonLog.info(line)
        }
        lastLineCount[domain] = lines.count
    }
}
