import UIKit
import QuartzCore

/// V0.1.4（AevonSystemGestureV104）：用「系统手势窗口」接管全屏 App 内的右缘触摸。
///
/// 为什么要换一层：
///   0.1.0~0.1.3 全部在 `UIApplication -sendEvent:` 里做判定。归档(11)(12)(13) 与
///   Aevon(17)(22)(71)(72) 六轮真机日志把事实钉死了 —— **前台 App 的触摸由 backboardd
///   直接投给 App 进程**，我们在 SpringBoard 侧把事件丢掉只是「我们这一份不处理」，
///   App 手里那一份照旧，于是「圆盘开着、抖音进度条跟着手指拖」。这在纯 SB 侧无解：
///   只要手指是从 App 那儿开始的，任何事后补偿（吞事件 / 还原滚动位置 / 改锚点）都迟一步。
///
/// 系统手势为什么能做到：
///   下拉控制中心 / 底部横条上滑 / 便捷访问这些系统手势，在**全屏 App 上**同样生效，
///   而且它们识别期间 App 完全收不到触摸。原因是它们挂在 SpringBoard 的
///   `_UISystemGestureWindow`（类名含 SystemGesture）上 —— 这个窗口的命中测试在 App 之上，
///   触摸从落下那一刻就归 SpringBoard，App 那边压根没有这条 touch，自然没有「跟手」。
///   Stheno 逆向（第 51 轮报告 + Stheno.dylib 字符串）用的就是这条路：
///   `SBReachabilityGestureRecognizer` / `_SBFluidSwitcherPanGestureRecognizer` +
///   `gestureRecognizer:shouldReceiveTouch:` / `gestureRecognizerShouldBegin`
///   —— hook 系统手势识别器，而不是跟 App 抢触摸。
///
/// 本版做法（最小化）：
///   1. 找到系统手势窗口（场景窗口里类名含 SystemGesture，或从
///      SBMainDisplaySystemGestureManager 的 ivar 取），在其根视图上加一个
///      **右边缘** `UIScreenEdgePanGestureRecognizer`；
///   2. 只认「App 前台 + 落在右缘 22pt + 不在热区 + 不在浮窗上 + 圆盘未展开」的触摸；
///   3. 只认「向左横扫」（`gestureRecognizerShouldBegin`），上下滑 / 轻点直接在识别阶段失败；
///   4. 识别成功 → 呼出圆盘，并把后续 moved / ended 喂给圆盘（跟手旋转 / 松手开窗）。
///
/// 代价（诚实记录）：这条带内的触摸从落下起就归 SpringBoard，所以带内的轻点也不会
/// 传给 App。带只取最外侧 22pt —— 抖音右侧点赞 / 评论 / 分享按钮的图标中心在 30pt 开外，
/// 正常点击仍然有效，只有贴边缘的那一条细缝点不到。这是「App 不跟手」的必然取舍。
///
/// 安全边界：
///   · 任何一步取不到就只记日志、什么都不装（回到 0.1.3 的老通道）；
///   · 识别器除了上面那 5 个条件一律返回 false，其余区域的触摸完全不受影响；
///   · 装之前先核对宿主窗口类名含 SystemGesture，避免误挂到桌面上（那会把整个桌面点死）。
final class AevonSystemGestureV104: NSObject, UIGestureRecognizerDelegate {
    static let shared = AevonSystemGestureV104()

    /// 右缘接管带宽（pt）。宁可窄：带越宽，带内点不到的东西越多。
    static let bandWidth: CGFloat = 22

    private var recognizer: UIScreenEdgePanGestureRecognizer?
    private weak var hostView: UIView?
    /// 当前归本通道的那根手指（`AevonTouchHook.m` 里上报的 touchID 就是 UITouch 指针）
    private var touchPointer: UInt = 0
    /// shouldReceiveTouch 里认到的候选手指：等识别成功（began）才正式接管。
    /// 直接在这里认的话，一次失败的识别会留下一个「僵尸指针」，而 UITouch 指针会被系统复用。
    private var pendingPointer: UInt = 0
    private var pointerDeadline: CFTimeInterval = 0
    private var lastLogAt: CFTimeInterval = 0

    static var isInstalled: Bool { return shared.recognizer != nil }
    static var hostViewClass: String {
        return shared.hostView.map { AevonRuntime.className($0) ?? "?" } ?? "无"
    }

    /// 这根触摸是否已经归系统手势通道。
    /// 全局 sendEvent 通道据此让路：同一根手指不能既算「接管带候选」又算「系统手势」。
    static func isHandling(touchID: UInt) -> Bool {
        let channel = AevonSystemGestureV104.shared
        guard channel.recognizer != nil else { return false }
        guard channel.touchPointer != 0, channel.touchPointer == touchID else { return false }
        // 12 秒硬上限：万一 ended 丢了，也不会让这根指针永久「占着」某次复用的 UITouch
        guard CACurrentMediaTime() <= channel.pointerDeadline else { return false }
        return true
    }

    // MARK: - 安装

    func install() {
        guard recognizer == nil else { return }
        guard AevonPrefs.bool("Enabled", default: false) else { return }
        guard let host = AevonSystemGestureV104.locateHostView() else {
            AevonLog.warn("[手势] 未找到系统手势窗口，右缘接管保持 0.1.3 老通道（AevonSystemGestureV104）")
            return
        }

        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.edges = .right
        pan.maximumNumberOfTouches = 1
        // 识别成功即取消带内触摸：这些触摸本来就在 SpringBoard 手里，App 从未收到过，
        // 这里只是把「识别后不再往别处派生事件」的语义写清楚。
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = true
        pan.delegate = self
        host.addGestureRecognizer(pan)

        recognizer = pan
        hostView = host
        AevonLog.info("[手势] 系统手势通道已装上（宿主 \(AevonSystemGestureV104.hostViewClass)，只认右缘 \(Int(AevonSystemGestureV104.bandWidth))pt 向左横扫；App 前台时由它接管，App 收不到触摸）（AevonSystemGestureV104 AevonTakeoverBandV103 AevonBandDeferV103）")
    }

    /// 找到系统手势窗口的根视图。
    ///
    /// 只接受「类名含 SystemGesture」的窗口 —— 挂错窗口的后果是那块区域点不动，
    /// 宁可这一次不装，也不能赌。
    private static func locateHostView() -> UIView? {
        if let window = findSystemGestureWindow() {
            if let root = window.rootViewController?.view {
                return root
            }
            return window
        }
        return nil
    }

    private static func findSystemGestureWindow() -> UIWindow? {
        // ① 场景窗口扫描
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                let name = AevonRuntime.className(window) ?? ""
                if name.contains("SystemGesture") {
                    return window
                }
            }
        }
        // ② 手势管理器上的 ivar / getter
        for className in ["SBMainDisplaySystemGestureManager", "SBSystemGestureManager"] {
            guard let manager = AevonRuntime.sendClass(className, Selector(("sharedInstance"))) else { continue }
            for key in ["_systemGestureWindow", "_window", "systemGestureWindow"] {
                if let window = AevonRuntime.ivarObject(manager, key) as? UIWindow {
                    return window
                }
                if manager.responds(to: Selector(key)),
                   let window = AevonRuntime.send(manager, Selector(key)) as? UIWindow {
                    return window
                }
            }
        }
        // ③ 最后再看一眼管理器里能枚举出来的窗口，挑类名对得上的（诊断信息一并交出）
        var names: [String] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                names.append(AevonRuntime.className(window) ?? "?")
            }
        }
        AevonLog.warn("[手势] 场景里的窗口类名：\(names.joined(separator: " / "))（AevonSystemGestureV104）")
        return nil
    }

    // MARK: - 识别条件

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard AevonPrefs.bool("Enabled", default: false),
              AevonPrefs.bool("EdgeGestureEnabled", default: true),
              AevonPrefs.bool("SystemGestureEdge", default: true) else { return false }
        // 只在全屏 App 前台时接管：桌面有自己的热区语义，不能被这条带盖住右侧图标
        guard AevonEntryHost.mountedInAppScene else { return false }
        // 圆盘已经开着：后续触摸归圆盘自己的通道
        guard AevonRingMenu.presented == nil else { return false }

        let screen = UIScreen.main.bounds
        let point = touch.location(in: nil)
        guard point.x >= screen.width - AevonSystemGestureV104.bandWidth else { return false }
        // 底部热区是老入口，优先级更高（按住即接管 + 轻点呼出都在那儿）
        guard !AevonTriggerZone.rect(in: screen).contains(point) else { return false }
        // 浮窗（含外侧手柄）压住的地方交给浮窗，否则贴边浮窗拖不动
        guard !AevonEntryHost.pointHitsFloatingWindow(at: point) else { return false }

        touchPointer = 0
        pendingPointer = UInt(bitPattern: Unmanaged.passUnretained(touch).toOpaque())
        pointerDeadline = CACurrentMediaTime() + 12
        let now = CACurrentMediaTime()
        if now - lastLogAt > 1.5 {
            lastLogAt = now
            AevonLog.info("[手势] 系统手势通道拿到右缘触摸 (x=\(Int(point.x)), y=\(Int(point.y)))（AevonSystemGestureV104）")
        }
        return true
    }

    /// 只认向左横扫：上下滑（刷抖音信息流）与轻点都在这一步直接失败。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let translation = pan.translation(in: nil)
        guard translation.x < 0, abs(translation.x) > abs(translation.y) else {
            return false
        }
        return true
    }

    /// 与系统其他手势共存：右缘手势不与系统手势互相排斥（否则容易把便捷访问 / 多任务手势挤掉）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }

    // MARK: - 手势分发

    @objc private func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let point = gesture.location(in: nil)
        switch gesture.state {
        case .began:
            touchPointer = pendingPointer
            pointerDeadline = CACurrentMediaTime() + 12
            AevonEdgeEntry.triggerFromSystemGesture(point: point)
        case .changed:
            AevonRingMenu.presented?.remoteMoved(to: point, source: "systemgesture")
        case .ended:
            AevonRingMenu.presented?.remoteEnded(at: point, source: "systemgesture")
            touchPointer = 0
            pendingPointer = 0
        case .cancelled, .failed:
            AevonRingMenu.presented?.remoteCancelled(source: "systemgesture")
            touchPointer = 0
            pendingPointer = 0
        default:
            break
        }
    }
}
