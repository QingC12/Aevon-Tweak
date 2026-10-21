import Foundation
import UIKit

/// 长按手势处理（单例 target，避免手势与视图循环引用）。
final class AEGestureHandler {
    static let shared = AEGestureHandler()
    private init() {}

    func attachLongPress(to view: UIView) {
        let gesture = UILongPressGestureRecognizer(target: AEGestureHandler.shared,
                                                    action: #selector(handleLongPress(_:)))
        gesture.minimumPressDuration = 0.5
        view.addGestureRecognizer(gesture)
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        guard let view = gesture.view else { return }
        guard let layout = findAppLayout(from: view) else {
            AELog.warn("[手势] 未找到 appLayout")
            return
        }
        guard let bundleID = AEAppLayout.bundleID(layout) else {
            AELog.warn("[手势] 未找到 bundleID")
            return
        }
        guard AEAppInfo.isRunning(bundleID: bundleID) else {
            AELog.info("[手势] \(bundleID) 未在运行，跳过（请先打开该 App 再切到多任务）")
            return
        }
        AELog.info("[手势] 长按多任务卡片，窗口化 \(bundleID)")
        AEWindowManager.open(bundleID: bundleID, sceneID: AEAppLayout.sceneID(layout))
    }

    /// 沿父视图链向上寻找带有 appLayout 的视图。
    private func findAppLayout(from view: UIView) -> AnyObject? {
        var current: UIView? = view
        while let candidate = current {
            if candidate.responds(to: Selector(("appLayout"))),
               let layout = AERuntime.send(candidate, Selector(("appLayout"))) {
                return layout
            }
            current = candidate.superview
        }
        return nil
    }
}
