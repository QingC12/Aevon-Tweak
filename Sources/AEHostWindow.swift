import UIKit

/// 穿透窗口：未命中浮窗的触摸直接交给下层窗口。
final class AEPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// 宿主窗口管理：所有分屏浮窗都挂在这个窗口上。
enum AEHostWindow {
    private static var window: AEPassthroughWindow?

    /// 确保宿主窗口已创建（幂等）。
    static func ensureInstalled() {
        guard window == nil else { return }
        guard let scene = firstWindowScene() else {
            AELog.warn("[窗口] 未找到 UIWindowScene，宿主窗口创建失败")
            return
        }
        let created = AEPassthroughWindow(windowScene: scene)
        created.frame = UIScreen.main.bounds
        created.backgroundColor = .clear
        // 高于普通窗口、低于系统警告的层级（等价旧常量 UIWindowLevelStatusBar）
        created.windowLevel = UIWindow.Level.statusBar
        created.isUserInteractionEnabled = true
        created.isHidden = false
        window = created
        AELog.info("[窗口] 宿主窗口已创建（level=\(created.windowLevel)）")
    }

    static var hostView: UIView? { window }

    static func firstWindowScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene { return windowScene }
        }
        return nil
    }
}
