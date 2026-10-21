import UIKit

/// 穿透窗口：未命中浮窗的触摸直接交给下层窗口。
final class SKPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// 宿主窗口管理：所有分屏浮窗都挂在这个窗口上。
enum SKHostWindow {
    private static var window: SKPassthroughWindow?

    /// 确保宿主窗口已创建（幂等）。
    static func ensureInstalled() {
        guard window == nil else { return }
        guard let scene = firstWindowScene() else {
            SKLog.warn("[窗口] 未找到 UIWindowScene，宿主窗口创建失败")
            return
        }
        let created = SKPassthroughWindow(windowScene: scene)
        created.frame = UIScreen.main.bounds
        created.backgroundColor = .clear
        // UIWindowLevelAlert = 2000.0（UIKit 公开常量）；用数值而非符号名，兼容各版本 SDK 的更名
        created.windowLevel = 1999.0
        created.isUserInteractionEnabled = true
        created.isHidden = false
        window = created
        SKLog.info("[窗口] 宿主窗口已创建（level=\(created.windowLevel)）")
    }

    static var hostView: UIView? { window }

    static func firstWindowScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene { return windowScene }
        }
        return nil
    }
}
