import Foundation
import UIKit

/// 一条场景状态的「账面快照」。
///
/// 关键设计（对应逆向报告里 SCSystemSceneContext 的 previousForeground / previousBackgrounded /
/// changedDeactivationReasons 三组字段）：**读不到就记 nil，绝不当成 false**。
/// Aevon 历史上最大的坑就是「读不到 → 当成没前台 → 于是再写一次」，
/// 每写一次 = 一帧重提交 = 用户看到闪一下。
struct AevonSceneSnapshot {
    var foreground: Bool? = nil
    var backgrounded: Bool? = nil
    var deactivationReasons: UInt64? = nil

    var isEmpty: Bool { foreground == nil && backgrounded == nil && deactivationReasons == nil }

    var description: String {
        let fg = foreground.map { $0 ? "YES" : "NO" } ?? "?"
        let bg = backgrounded.map { $0 ? "YES" : "NO" } ?? "?"
        let dr = deactivationReasons.map { String($0) } ?? "?"
        return "fg=\(fg) bg=\(bg) dr=\(dr)"
    }
}

/// 账本判定结果。`skipSame` 就是「账面已经是这个值，不许再写」——
/// 这是路线 C 里最能直接消闪的一条。
struct AevonLedgerDecision {
    enum Kind: String {
        case write = "写"
        case skipSame = "账面已一致-跳过"
        case skipNoWish = "无期望-跳过"
    }

    let kind: Kind
    let snapshot: AevonSceneSnapshot
    let changedFields: [String]
    let detail: String

    var shouldWrite: Bool { kind == .write }
}

/// 单个 App 的账页。
final class AevonSceneBook {
    let bundleID: String
    var sceneID: String
    /// 上一笔我们写下去的值（写成功才更新）
    var lastKnown = AevonSceneSnapshot()
    /// 当前期望：nil = 不干预（关窗 / 交还全屏）
    var wantForeground: Bool?
    var wantDeactivationZero = false
    var reason = ""

    var writes = 0
    var skips = 0
    /// 系统把我们写下去的值又改回去的次数（重提交计数）
    var overrides = 0
    var lastWriteAt: CFTimeInterval = 0
    var openedAt: CFTimeInterval = CACurrentMediaTime()

    init(bundleID: String, sceneID: String) {
        self.bundleID = bundleID
        self.sceneID = sceneID
    }

    var summary: String {
        "\(bundleID) 写\(writes) 跳\(skips) 被改\(overrides) 面[\(lastKnown.description)] 愿[\(wantForeground.map { $0 ? "YES" : "NO" } ?? "-")]"
    }
}

/// 场景状态账本（路线 C 第一件）。
///
/// 抄的是 ScreenCore `SCSystemSceneContext` 的记账方式：
///   写之前先看一眼「账面已经是多少」，只把**差异**写下去；
///   写之后把系统回读到的值记下来，下一次比对用它，而不是靠猜。
///
/// 为什么要这么干（自家档案实锤）：round17「fg 保活三轮零收益，每次写=一帧重提交=一次闪」。
/// 当年是「读不到就写」，现在是「账面相同就不写」。
final class AevonSceneLedger {
    static let shared = AevonSceneLedger()
    private init() {}

    private let lock = NSLock()
    private var books: [String: AevonSceneBook] = [:]
    private var totalWrites = 0
    private var totalSkips = 0
    private var totalOverrides = 0
    private var lastSummaryAt: CFTimeInterval = 0

    // MARK: - 读系统当前值

    /// 从 FBScene 读一份当前快照。任何一个字段读不到就留 nil。
    static func snapshot(of scene: AnyObject) -> AevonSceneSnapshot {
        var snap = AevonSceneSnapshot()
        guard scene.responds(to: Selector(("settings"))),
              let settings = AevonRuntime.send(scene, Selector(("settings"))) else {
            return snap
        }
        snap.foreground = AevonRuntime.bool(settings, key: "foreground")
        snap.backgrounded = AevonRuntime.bool(settings, key: "backgrounded")
        snap.deactivationReasons = uint64(settings, key: "deactivationReasons")
        return snap
    }

    /// UInt64 字段读取：deactivationReasons 是 unsigned long long
    private static func uint64(_ target: AnyObject, key: String) -> UInt64? {
        let sel = NSSelectorFromString(key)
        guard target.responds(to: sel) else { return nil }
        guard let value = AevonRuntime.send(target, sel) else { return nil }
        if let number = value as? NSNumber { return number.uint64Value }
        return nil
    }

    // MARK: - 账页生命周期

    /// 开窗时开账（同 bundleID 重复开窗只重置期望，不丢历史计数）。
    @discardableResult
    func open(bundleID: String, sceneID: String, reason: String) -> AevonSceneBook {
        lock.lock(); defer { lock.unlock() }
        let book: AevonSceneBook
        if let existing = books[bundleID] {
            book = existing
            if !sceneID.isEmpty { book.sceneID = sceneID }
            book.wantForeground = nil
            book.wantDeactivationZero = false
            book.reason = reason
            book.openedAt = CACurrentMediaTime()
        } else {
            book = AevonSceneBook(bundleID: bundleID, sceneID: sceneID)
            book.reason = reason
            books[bundleID] = book
        }
        AevonLog.info("[账本] 开账 \(bundleID) scene=\(sceneID.isEmpty ? "-" : sceneID) 原因=\(reason)（AevonSceneLedgerV279）")
        return book
    }

    /// 关窗 / 交还全屏时释放期望：此后系统想写 foreground=NO 一律放行。
    func release(bundleID: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let book = books[bundleID] else { return }
        let was = book.wantForeground.map { $0 ? "YES" : "NO" } ?? "-"
        book.wantForeground = nil
        book.wantDeactivationZero = false
        book.reason = reason
        AevonLog.info("[账本] 释放 \(bundleID)（原期望 \(was)）原因=\(reason) 结算 \(book.summary)（AevonSceneLedgerV279）")
    }

    /// 完整注销（App 被关掉、不再关心它）。
    // MARK: - 期望登记

    /// 登记「我希望这个 App 是前台」。
    func wishForeground(_ bundleID: String, reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard let book = books[bundleID] else { return }
        book.wantForeground = true
        book.wantDeactivationZero = true
        book.reason = reason
    }

    // MARK: - 写前判定

    /// 核心：写之前先比对账面。返回的 decision 决定「要不要真的写这一笔」。
    func decide(bundleID: String,
                scene: AnyObject?,
                wantForeground: Bool,
                reason: String) -> AevonLedgerDecision {
        let live: AevonSceneSnapshot
        if let scene {
            live = AevonSceneLedger.snapshot(of: scene)
        } else {
            live = AevonSceneSnapshot()
        }

        lock.lock()
        let book = books[bundleID]
        let lastKnown = book?.lastKnown ?? AevonSceneSnapshot()
        lock.unlock()

        // 优先用实时读到的；读不到再退回上一笔写下去的值（账面记忆）
        let effective = AevonSceneSnapshot(
            foreground: live.foreground ?? lastKnown.foreground,
            backgrounded: live.backgrounded ?? lastKnown.backgrounded,
            deactivationReasons: live.deactivationReasons ?? lastKnown.deactivationReasons
        )

        guard let currentForeground = effective.foreground else {
            // 完全读不到 → 保守写一笔（宁可写，也不能让画面停住），但要标出来
            return AevonLedgerDecision(kind: .write, snapshot: effective,
                                       changedFields: ["foreground(未知)"],
                                       detail: "系统值读不到，保守写")
        }

        if currentForeground == wantForeground {
            var fields: [String] = ["foreground已=\(wantForeground ? "YES" : "NO")"]
            // 前台已就位时，若还要求 deactivationReasons=0 且已知非 0，仍需要补一笔
            if wantForeground, let dr = effective.deactivationReasons, dr != 0 {
                return AevonLedgerDecision(kind: .write, snapshot: effective,
                                           changedFields: ["deactivationReasons=\(dr)"],
                                           detail: "前台已就位但停用原因非 0")
            }
            if let dr = effective.deactivationReasons, dr == 0 {
                fields.append("dr=0")
            } else if effective.deactivationReasons == nil {
                fields.append("dr=?")
            }
            return AevonLedgerDecision(kind: .skipSame, snapshot: effective,
                                       changedFields: fields,
                                       detail: "账面已一致，不写（省一次重提交）")
        }

        // 值不一致：说明系统把它改回去了（或我们还没写过）
        var fields = ["foreground(现值\(currentForeground ? "YES" : "NO")→\(wantForeground ? "YES" : "NO"))"]
        if wantForeground, let dr = effective.deactivationReasons, dr != 0 {
            fields.append("deactivationReasons=\(dr)→0")
        }
        return AevonLedgerDecision(kind: .write, snapshot: effective,
                                   changedFields: fields,
                                   detail: "需要对齐")
    }

    // MARK: - 写后记账

    func noteApplied(bundleID: String,
                     wantForeground: Bool,
                     readBack: AevonSceneSnapshot?,
                     reason: String) {
        lock.lock()
        defer { lock.unlock() }
        totalWrites += 1
        guard let book = books[bundleID] else { return }
        book.writes += 1
        book.wantForeground = wantForeground
        book.reason = reason
        book.lastWriteAt = CACurrentMediaTime()
        if let readBack {
            // 回读优先，读不到就把「我们刚写的」记成账面
            book.lastKnown = AevonSceneSnapshot(
                foreground: readBack.foreground ?? wantForeground,
                backgrounded: readBack.backgrounded ?? (wantForeground ? false : true),
                deactivationReasons: readBack.deactivationReasons ?? (wantForeground ? 0 : nil)
            )
        } else {
            book.lastKnown = AevonSceneSnapshot(
                foreground: wantForeground,
                backgrounded: wantForeground ? false : true,
                deactivationReasons: wantForeground ? 0 : book.lastKnown.deactivationReasons
            )
        }
    }

    func noteSkipped(bundleID: String, reason: String) {
        lock.lock(); defer { lock.unlock() }
        totalSkips += 1
        guard let book = books[bundleID] else { return }
        book.skips += 1
        book.reason = reason
    }

    /// 系统把我们写下去的前台值又改回去了。计数用于「到底被改了几次」的判据。
    func noteOverridden(bundleID: String, identifier: String) {
        lock.lock(); defer { lock.unlock() }
        totalOverrides += 1
        guard let book = books[bundleID] else { return }
        book.overrides += 1
        book.lastKnown.foreground = false
        book.reason = "系统改写 \(identifier.prefix(28))"
    }

    // MARK: - 给 Hook 层查

    /// 这个场景「我们现在还希望它前台吗」。
    /// 返回 false = 交接期 / 已释放 / 没开账 → Hook 必须放行系统原本的写入（包括写 NO）。
    func wantsForeground(identifier: String) -> Bool {
        lock.lock()
        let booksCopy = books
        lock.unlock()
        for (bundleID, book) in booksCopy {
            guard book.wantForeground == true else { continue }
            if identifier.contains(bundleID) || book.sceneID == identifier || identifier.contains(book.sceneID) {
                return true
            }
        }
        return false
    }

    /// 让 Hook 在拦下系统写 NO 时能记到对应账页。
    func bookID(matching identifier: String) -> String? {
        lock.lock()
        let keys = Array(books.keys)
        lock.unlock()
        for bundleID in keys {
            if identifier.contains(bundleID) { return bundleID }
        }
        return nil
    }

    func book(bundleID: String) -> AevonSceneBook? {
        lock.lock(); defer { lock.unlock() }
        return books[bundleID]
    }

    // MARK: - 汇总（节流，只用来给日志一行结论）

    func summaryIfDue(force: Bool = false) -> String? {
        lock.lock()
        let now = CACurrentMediaTime()
        guard force || now - lastSummaryAt > 5.0 else { lock.unlock(); return nil }
        lastSummaryAt = now
        let snapshot = books.values.map { $0.summary }.sorted()
        let head = "写\(totalWrites) 跳\(totalSkips) 被改\(totalOverrides)"
        lock.unlock()
        if snapshot.isEmpty { return head }
        return head + " | " + snapshot.prefix(4).joined(separator: " ; ")
    }
}

/// 自建场景（路线 B）的学习式降级名单（V0.2.80，AevonSelfSceneLearnV280）。
///
/// 为什么要它：cap=1 是 0.2.31~0.41 五轮真机矩阵里唯一 100% 对齐的判据，但真机仍有
/// 极小概率「场景建出来了、App 端却没连上」（`AevonSelfSceneConnectionState` 恒 client=nil）
/// —— 表现就是黑窗。用户不愿反复试，所以这里把失败过的 App 记进内存名单，
/// **下一次**开窗直接走 S2，不黑第二次。
///
/// 只存内存：SB 重启即清空，不落盘、不污染日志目录，也不会把一次偶发失败永久钉死
///（重启后还会再试一次自建）。
final class AevonSelfSceneLearn {
    static let shared = AevonSelfSceneLearn()
    private init() {}

    private let lock = NSLock()
    private var failed: Set<String> = []

    func markFailed(_ bundleID: String) {
        lock.lock(); defer { lock.unlock() }
        failed.insert(bundleID)
    }

    func hasFailed(_ bundleID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed.contains(bundleID)
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        return failed.isEmpty ? "无" : failed.sorted().joined(separator: ",")
    }
}
