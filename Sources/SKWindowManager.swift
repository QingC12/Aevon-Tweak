import Foundation
import UIKit

/// 浮窗管理：开窗 / 关窗 / 已开窗集合 / 图层更新。
enum SKWindowManager {
    private static var windows: [String: SKWindowView] = [:]

    static func isWindowed(_ bundleID: String) -> Bool {
        return windows[bundleID] != nil
    }

    /// 为指定 App 开窗（带场景就绪等待与全路径守卫，任何失败都静默放弃）。
    static func open(bundleID: String, sceneID: String?) {
        guard SKPrefs.bool("Enabled", default: false) else {
            SKLog.warn("[窗口] 插件未启用，忽略开窗请求")
            return
        }
        guard !isWindowed(bundleID) else {
            SKLog.info("[窗口] \(bundleID) 已处于窗口化状态")
            return
        }

        SKHostWindow.ensureInstalled()
        guard let host = SKHostWindow.hostView else {
            SKLog.warn("[窗口] 宿主窗口不可用，放弃开窗")
            return
        }

        // 登记前台保活，唤醒场景
        SKForegroundManager.shared.add(bundleID: bundleID, sceneID: sceneID)
        SKSceneHelper.wakeUp(bundleID)

        // 等待场景就绪后再承载
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var scene = SKSceneHelper.scene(for: bundleID)
            if scene == nil, let sid = sceneID {
                scene = SKSceneHelper.scene(for: sid)
            }
            guard let scene = scene else {
                SKLog.warn("[窗口] 未找到 \(bundleID) 的场景，放弃开窗")
                SKForegroundManager.shared.remove(bundleID: bundleID, sceneID: sceneID)
                return
            }

            SKSceneHelper.setForeground(scene, true)
            guard let content = SKSceneHelper.hostingView(for: scene) else {
                SKLog.warn("[窗口] 无法创建场景承载视图，放弃开窗")
                SKForegroundManager.shared.remove(bundleID: bundleID, sceneID: sceneID)
                return
            }

            let title = SKAppInfo.displayName(bundleID: bundleID) ?? bundleID
            let windowView = SKWindowView(contentView: content, bundleID: bundleID, title: title)
            host.addSubview(windowView)
            windows[bundleID] = windowView

            SKSceneHelper.startKeepAlive(bundleID)
            if SKPrefs.bool("KeepAlive", default: true),
               let pid = SKAppInfo.pid(bundleID: bundleID) {
                SKAssertionShim.acquireKeepAlive(forPID: Int32(pid))
            }
            SKLog.info("[窗口] \(bundleID) 窗口化成功")
        }
    }

    /// 关窗并清理全部相关状态。
    static func close(bundleID: String) {
        guard let windowView = windows.removeValue(forKey: bundleID) else { return }
        windowView.teardown()
        SKSceneHelper.stopKeepAlive(bundleID)
        SKSceneHelper.sleep(bundleID)
        SKForegroundManager.shared.remove(bundleID: bundleID, sceneID: nil)
        if let pid = SKAppInfo.pid(bundleID: bundleID) {
            SKAssertionShim.releaseKeepAlive(forPID: Int32(pid))
        }
        SKLog.info("[窗口] \(bundleID) 已关闭")
    }

    static func closeAll() {
        for bundleID in Array(windows.keys) {
            close(bundleID: bundleID)
        }
    }

    static func notifyLayersUpdated() {
        for (_, windowView) in windows {
            windowView.setNeedsLayout()
        }
    }
}
