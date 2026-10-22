import UIKit

/// 全局窗口层级表（V0.0.19）。
///
/// 依据 V0.0.18 真机日志：桌面能呼出圆盘，全屏 App 里连右侧触发条都看不见 ——
/// 窗口没被销毁、触摸也没进窗口，说明整层被前景 App 的画面盖住了。
/// SpringBoard 里前台 App 的画面同样挂在窗口树上（我们自己的浮窗就是证据），
/// 只是层级高于原来的 alert − 1 = 1999。这里不再猜「App 承载窗口是第几级」，
/// 直接占住 1e7 这一段：系统常规窗口最高只到 alert(2000)，1e7 只在极端场景才被占用。
///
/// 三个档位保持相对关系：浮窗外壳 < 入口（手势条/圆盘/面板） < 外部图层（键盘）。
/// 窗口本身是穿透的（hitTest 未命中就返回 nil），高层级不会吞掉系统触摸。
enum AevonWindowLevels {
    /// 浮窗外壳（App 画面载体）
    static let floating = UIWindow.Level(rawValue: 9_999_990)
    /// 入口窗口：手势条 / 圆盘 / 应用面板
    static let entry = UIWindow.Level(rawValue: 10_000_000)
    /// 键盘等外部图层
    static let overlay = UIWindow.Level(rawValue: 10_000_100)
}

/// 穿透窗口：未命中的触摸直接交给下层，不吞掉系统手势。
/// 非 final：`AevonEntryWindow` 需要继承它并重写 `sendEvent` 做触摸探针。
class AevonPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// 宿主窗口管理：所有分屏浮窗都挂在这个窗口上。
///
/// V0.0.6 改动：
/// - 不再在 SpringBoard 启动时创建窗口（那是 V0.0.5 崩溃的现场），改为首次开窗时懒创建；
/// - 选 scene 时只接受 foregroundActive/foregroundInactive 的 UIWindowScene，
///   避免把窗口挂到即将销毁的系统场景上（挂错场景会在系统回收场景时崩）；
/// - 补一个空的 rootViewController，规避「窗口无根控制器」相关的布局断言。
enum AevonHostWindow {
    private static var window: AevonPassthroughWindow?

    /// 确保宿主窗口已创建（幂等）。只有真正要开窗时才调用。
    @discardableResult
    static func ensureInstalled() -> Bool {
        if window != nil { return true }
        guard let scene = firstWindowScene() else {
            AevonLog.warn("[窗口] 未找到可用的前台 UIWindowScene，宿主窗口创建失败")
            return false
        }
        let created = AevonPassthroughWindow(windowScene: scene)
        created.frame = UIScreen.main.bounds
        created.backgroundColor = .clear
        // V0.0.19：提到前景 App 画面之上（旧值 statusBar=1000 会被 App 盖住）
        created.windowLevel = AevonWindowLevels.floating

        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        created.rootViewController = root

        created.isHidden = false
        window = created
        AevonLog.info("[窗口] 宿主窗口已创建（level=\(created.windowLevel)，scene=\(scene.activationState.rawValue)）")
        return true
    }

    static var hostView: UIView? { window }

    /// 外部图层（键盘、系统浮层）专用窗口：层级最高、完全透明、不接管触摸。
    /// 这类宿主视图不能嵌进浮窗里，只能单独挂一个窗口，否则不显示。
    static func makeOverlayWindow() -> UIWindow? {
        guard let scene = firstWindowScene() else {
            AevonLog.warn("[窗口] 创建外部图层窗口失败：没有可用的前台场景")
            return nil
        }
        let overlay = AevonPassthroughWindow(windowScene: scene)
        overlay.frame = UIScreen.main.bounds
        overlay.backgroundColor = .clear
        overlay.windowLevel = AevonWindowLevels.overlay

        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        overlay.rootViewController = root
        overlay.isHidden = false
        return overlay
    }

    /// 只挑「当前确实在前台/非激活」的窗口场景，优先主屏。
    static func firstWindowScene() -> UIWindowScene? {
        var active: [UIWindowScene] = []
        var inactive: [UIWindowScene] = []
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            switch scene.activationState {
            case .foregroundActive: active.append(scene)
            case .foregroundInactive: inactive.append(scene)
            default: break
            }
        }
        let candidates = active.isEmpty ? inactive : active
        guard !candidates.isEmpty else { return nil }
        if let main = candidates.first(where: { $0.screen === UIScreen.main }) { return main }
        return candidates.first
    }

    /// 选「最适合承载全局浮层」的窗口场景（V0.0.20）。
    ///
    /// 背景：V0.0.19 把入口窗口层级抬到 1e7 之后，桌面正常、全屏 App 里仍然看不见 ——
    /// 说明问题不在层级，而在**窗口挂错了场景**：App 进前台后，SpringBoard 可能切到
    /// 另一个窗口场景（系统 UI 用的那个）来承载可见画面，挂在家屏场景上的窗口自然不显示。
    /// 这里按「系统 UI 场景 > 前台活跃 > 窗口层级更高 > 主屏」打分挑一个，
    /// 再由 `AevonEntryHost` 的看门狗在场景切换时把窗口搬过去。
    static func preferredScene() -> UIWindowScene? {
        var best: UIWindowScene?
        var bestScore = Int.min
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let score = sceneScore(scene)
            guard score > Int.min else { continue }
            if score > bestScore {
                bestScore = score
                best = scene
            }
        }
        return best
    }

    /// 单个场景的「适合承载浮层」得分；不可用的场景返回 `Int.min`。
    static func sceneScore(_ scene: UIWindowScene) -> Int {
        guard scene.activationState == .foregroundActive
            || scene.activationState == .foregroundInactive else { return Int.min }
        var score = 0
        if scene.activationState == .foregroundActive { score += 20 }
        if scene.screen === UIScreen.main { score += 5 }
        let role = scene.session.role.lowercased()
        if role.contains("system") || role.contains("shell") { score += 100 }
        if scene.windows.contains(where: { $0.windowLevel.rawValue >= UIWindow.Level.alert.rawValue }) {
            score += 10
        }
        // 窗口越多，越可能是「真正在显示系统 UI」的那个场景
        score += min(scene.windows.count, 8)
        return score
    }
}
