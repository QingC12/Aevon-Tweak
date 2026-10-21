import Foundation
import UIKit

/// 长按手势处理（单例 target，避免手势与视图循环引用）。
final class AevonGestureHandler {
    static let shared = AevonGestureHandler()
    private init() {}

    func attachLongPress(to view: UIView) {
        let gesture = UILongPressGestureRecognizer(target: AevonGestureHandler.shared,
                                                    action: #selector(handleLongPress(_:)))
        gesture.minimumPressDuration = 0.5
        view.addGestureRecognizer(gesture)
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        guard let view = gesture.view else { return }
        guard let layout = findAppLayout(from: view) else {
            AevonLog.warn("[手势] 未找到 appLayout")
            return
        }
        guard let bundleID = AevonAppLayout.bundleID(layout) else {
            AevonLog.warn("[手势] 未找到 bundleID")
            return
        }
        guard AevonAppInfo.isRunning(bundleID: bundleID) else {
            AevonLog.info("[手势] \(bundleID) 未在运行，跳过（请先打开该 App 再切到多任务）")
            return
        }
        AevonLog.info("[手势] 长按多任务卡片，窗口化 \(bundleID)")
        AevonWindowManager.open(bundleID: bundleID, sceneID: AevonAppLayout.sceneID(layout))
    }

    /// 沿父视图链向上寻找带有 appLayout 的视图。
    private func findAppLayout(from view: UIView) -> AnyObject? {
        var current: UIView? = view
        while let candidate = current {
            if candidate.responds(to: Selector(("appLayout"))),
               let layout = AevonRuntime.send(candidate, Selector(("appLayout"))) {
                return layout
            }
            current = candidate.superview
        }
        return nil
    }
}
