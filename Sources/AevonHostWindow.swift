import UIKit

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
        // 高于普通窗口、低于系统警告的层级（等价旧常量 UIWindowLevelStatusBar）
        created.windowLevel = UIWindow.Level.statusBar

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
        overlay.windowLevel = UIWindow.Level.alert + 1000

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
}
