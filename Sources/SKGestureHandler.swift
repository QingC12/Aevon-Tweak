import Foundation
import UIKit

/// 长按手势处理（单例 target，避免手势与视图循环引用）。
final class SKGestureHandler {
    static let shared = SKGestureHandler()
    private init() {}

    func attachLongPress(to view: UIView) {
        let gesture = UILongPressGestureRecognizer(target: SKGestureHandler.shared,
                                                    action: #selector(handleLongPress(_:)))
        gesture.minimumPressDuration = 0.5
        view.addGestureRecognizer(gesture)
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        guard let view = gesture.view else { return }
        guard let layout = findAppLayout(from: view) else {
            SKLog.warn("[手势] 未找到 appLayout")
            return
        }
        guard let bundleID = SKAppLayout.bundleID(layout) else {
            SKLog.warn("[手势] 未找到 bundleID")
            return
        }
        guard SKAppInfo.isRunning(bundleID: bundleID) else {
            SKLog.info("[手势] \(bundleID) 未在运行，跳过（请先打开该 App 再切到多任务）")
            return
        }
        SKLog.info("[手势] 长按多任务卡片，窗口化 \(bundleID)")
        SKWindowManager.open(bundleID: bundleID, sceneID: SKAppLayout.sceneID(layout))
    }

    /// 沿父视图链向上寻找带有 appLayout 的视图。
    private func findAppLayout(from view: UIView) -> AnyObject? {
        var current: UIView? = view
        while let candidate = current {
            if candidate.responds(to: Selector(("appLayout"))),
               let layout = SKRuntime.send(candidate, Selector(("appLayout"))) {
                return layout
            }
            current = candidate.superview
        }
        return nil
    }
}
