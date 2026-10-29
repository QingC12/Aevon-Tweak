import Foundation
import UIKit

/// 一次「开窗 / 切屏 / 关窗」的显式事务（路线 C 第三件）。
///
/// 抄的是 ScreenCore `SCWSSwitch` 的**会话化**思路：一次切换是一个有开始、有步进、
/// 有截止时间、有终态的对象，而不是一串散落的 `asyncAfter`。
///
/// Aevon 这边真正要治的病是「迟到闭包」：
///   · 0.2.43 真机实锤（Aevon(18)）：关窗时已经还原了主场景尺寸，但开窗时排下的
///     +2.5s 复查闭包还在跑，读回发现「不是画布尺寸」→ 当回弹处理 → 又写回小画布，
///     结果 App 退出浮窗后全屏打开只剩一小块。
///   · 同类还有：关窗后 0.75s 的挂起闭包、显窗后的兜底闭包、保活定时器的补写。
/// 这些闭包在关窗之后依然会执行，把已经收干净的状态重新写脏。
///
/// 有了事务之后，每个延迟闭包只要问一句 `isCurrent(会话)`，关窗即失效，不需要到处
/// 手写 `guard !invalidated`。
final class AevonSwitchSession {
    enum Phase: String {
        case opening = "开窗"
        case revealing = "显窗"
        case active = "承载中"
        case closing = "关窗"
        case done = "结束"
        case aborted = "中止"
    }

    let id: String
    let bundleID: String
    let beganAt: CFTimeInterval
    let deadline: CFTimeInterval
    private(set) var phase: Phase = .opening
    private(set) var marks: [(String, CFTimeInterval)] = []
    private(set) var endedAt: CFTimeInterval = 0
    private(set) var endReason = ""

    init(bundleID: String, timeout: TimeInterval) {
        self.id = "txn-\(bundleID)-\(Int(CACurrentMediaTime() * 1000) % 100000)"
        self.bundleID = bundleID
        self.beganAt = CACurrentMediaTime()
        self.deadline = beganAt + timeout
    }

    /// 会话还活着吗（关窗 / 中止之后一律 false，迟到闭包拿它当闸门）
    var isValid: Bool { phase != .done && phase != .aborted }

    var elapsed: CFTimeInterval {
        (endedAt > 0 ? endedAt : CACurrentMediaTime()) - beganAt
    }

    func mark(_ step: String, _ phase: Phase? = nil) {
        if let phase { self.phase = phase }
        marks.append((step, CACurrentMediaTime()))
    }

    /// 落终态（private(set) 字段只能由自己改）
    func finish(_ phase: Phase, reason: String) {
        self.phase = phase
        self.endReason = reason
        self.endedAt = CACurrentMediaTime()
    }

    /// 步进链，形如「开窗@0.000→显窗@0.412→承载中@0.430」
    func trace() -> String {
        guard let base = marks.first?.1 else { return "无步进" }
        return marks.map { "\($0.0)@\(String(format: "%.3f", $0.1 - base))" }.joined(separator: "→")
    }
}

final class AevonSwitchCoordinator {
    static let shared = AevonSwitchCoordinator()
    private init() {}

    private let lock = NSLock()
    private var active: [String: AevonSwitchSession] = [:]
    private var history: [AevonSwitchSession] = []

    private var totalBegan = 0
    private var totalDone = 0
    private var totalAborted = 0
    private var totalOverdue = 0

    /// 开窗默认上限：超过这个时间还没显窗，就属于「事务超时」，打进日志等下次收敛。
    static let defaultTimeout: TimeInterval = 1.6

    // MARK: - 生命周期

    @discardableResult
    func begin(bundleID: String, reason: String, timeout: TimeInterval = AevonSwitchCoordinator.defaultTimeout) -> AevonSwitchSession {
        let session = AevonSwitchSession(bundleID: bundleID, timeout: timeout)
        session.mark("开窗")
        lock.lock()
        // 同一个 App 上一笔没结束（快速连开）→ 视为中止，避免两笔同时活着
        if let stale = active[bundleID] {
            stale.mark("被新事务顶替")
            stale.finish(.aborted, reason: "顶替")
            totalAborted += 1
            history.append(stale)
        }
        active[bundleID] = session
        totalBegan += 1
        lock.unlock()
        AevonLog.info("[事务] 开始 \(session.id) 原因=\(reason) 上限=\(String(format: "%.1f", timeout))s（AevonSwitchTxnV279）")
        // 顺手体检上一笔（开窗不频繁，代价可以忽略）
        auditOverdue()
        return session
    }

    /// 推进/打点。会话已失效时返回 false，调用方据此跳过后续写入。
    @discardableResult
    func mark(_ session: AevonSwitchSession?, _ step: String, phase: AevonSwitchSession.Phase? = nil) -> Bool {
        guard let session else { return false }
        guard session.isValid else {
            AevonLog.warn("[事务] 迟到步进「\(step)」被丢弃（\(session.id) 已 \(session.phase.rawValue)）"
                + "（AevonSwitchTxnV279）")
            return false
        }
        session.mark(step, phase)
        return true
    }

    /// 会话是否仍是当前这一个 —— 所有会**写状态**的延迟闭包的第一道闸门。
    func isCurrent(_ session: AevonSwitchSession?) -> Bool {
        guard let session, session.isValid else { return false }
        lock.lock()
        let current = active[session.bundleID]
        lock.unlock()
        return current === session
    }

    /// 会话是否「没被关窗打断」—— 收尾类闭包（撤遮罩、去占位图、让位停靠列）用它。
    /// 和 isCurrent 的区别：complete 之后 isCurrent 为 false（已经结算），但收尾还该做；
    /// 只有 abort（关窗）之后才必须全部停手。
    func isAlive(_ session: AevonSwitchSession?) -> Bool {
        guard let session else { return false }
        return session.phase != .aborted
    }

    /// 事务完成：显窗成功 / 进入承载。
    func complete(_ session: AevonSwitchSession?, reason: String) {
        guard let session, session.isValid else { return }
        session.mark("承载", .active)
        guard isCurrent(session) else { return }
        session.mark("完成")
        session.finish(.done, reason: reason)
        lock.lock()
        if active[session.bundleID] === session { active.removeValue(forKey: session.bundleID) }
        totalDone += 1
        let overdue = session.endedAt > session.deadline
        if overdue { totalOverdue += 1 }
        history.append(session)
        if history.count > 40 { history.removeFirst(history.count - 40) }
        lock.unlock()
        AevonLog.info("[事务] 完成 \(session.id) 原因=\(reason) 耗时=\(String(format: "%.3f", session.elapsed))s"
            + (overdue ? " ⚠️超时" : "") + " 链=\(session.trace())（AevonSwitchTxnV279）")
    }

    /// 关窗 / 放弃：立刻失效，之后所有迟到闭包都会被 `mark` / `isCurrent` 挡掉。
    func abort(bundleID: String, reason: String) {
        lock.lock()
        guard let session = active.removeValue(forKey: bundleID) else { lock.unlock(); return }
        totalAborted += 1
        session.mark("关窗", .closing)
        session.mark(reason)
        session.finish(.aborted, reason: reason)
        history.append(session)
        if history.count > 40 { history.removeFirst(history.count - 40) }
        lock.unlock()
        AevonLog.info("[事务] 中止 \(session.id) 原因=\(reason) 存活=\(String(format: "%.3f", session.elapsed))s"
            + " 链=\(session.trace())（AevonSwitchTxnV279）")
    }

    func active(bundleID: String) -> AevonSwitchSession? {
        lock.lock(); defer { lock.unlock() }
        return active[bundleID]
    }

    // MARK: - 汇总

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        let alive = active.values.map { "\($0.bundleID):\($0.phase.rawValue)" }.sorted().joined(separator: ",")
        return "开\(totalBegan) 完\(totalDone) 止\(totalAborted) 超\(totalOverdue)"
            + (alive.isEmpty ? "" : " 在途[\(alive)]")
    }

    /// 检查在途事务有没有超时（由巡检调用，只报告不推进 —— 推进必须靠事件）。
    func auditOverdue(now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        let overdue = active.values.filter { now > $0.deadline }
        lock.unlock()
        for session in overdue {
            AevonLog.warn("[事务] 在途超时 \(session.id) 已 \(String(format: "%.2f", session.elapsed))s"
                + " 阶段=\(session.phase.rawValue) 链=\(session.trace())（AevonSwitchTxnV279）")
        }
    }
}
