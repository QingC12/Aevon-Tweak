//
//  AevonQuickAction.swift
//  Aevon
//
//  V0.2.62（AevonQuickActionV262，用户 Aevon(36) #2）：
//  「添加系统的截图和录屏功能到圆盘的应用选择中」。
//
//  做法：在圆盘里插入两个「动作」槽 —— 它们不是 App，bundleID 用
//  `aevon.action.screenshot` / `aevon.action.recording` 这两个伪标识；
//  圆盘把它们当成普通图标布局（图标用 SF Symbol 画），选中时不分派给
//  `launchAndOpen`，而是走本文件的 `perform(bundleID:)`。
//
//  截图：优先 `UICreateScreenImage()`（UIKit 私有 C 函数，SpringBoard 里能
//        截到**合成后的整屏**，含所有窗口与会话内容）；取不到再退回私有类
//        `SBScreenShotter`。拿到图后写相册。
//  录屏：ReplayKit 的 `RPScreenRecorder`（SpringBoard 是系统 App，具备录制
//        权限）。开始 / 再点一次停止；停止时把录制结果写相册，失败则记日志。
//
//  纪律：任何一步失败都只记日志、绝不抛异常（圆盘是用户天天点的入口）；
//        不在主线程做重活（截图放到后台队列）。
//

import UIKit
import ReplayKit
import Photos

/// 截图保存完成的回调目标（`UIImageWriteToSavedPhotosAlbum` 需要一个 selector）
final class AevonQuickActionSaver: NSObject {
    static let shared = AevonQuickActionSaver()

    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            AevonLog.warn("[快捷] 截图保存相册失败：\(error.localizedDescription)（AevonQuickActionV262）")
        } else {
            AevonLog.info("[快捷] 截图已保存到相册（AevonQuickActionV262）")
        }
    }
}

enum AevonQuickAction {
    /// 标记（CI 用：必须落在编译产物里）
    static let markerScreenshot = "AevonQuickScreenshotV262"
    static let markerRecording = "AevonQuickRecordingV262"

    static let screenshotID = "aevon.action.screenshot"
    static let recordingID = "aevon.action.recording"

    static var allIDs: [String] { [screenshotID, recordingID] }

    static func isAction(_ bundleID: String) -> Bool {
        return bundleID == screenshotID || bundleID == recordingID
    }

    static func title(for bundleID: String) -> String? {
        switch bundleID {
        case screenshotID: return "截图"
        case recordingID: return "录屏"
        default: return nil
        }
    }

    static func symbolName(for bundleID: String) -> String? {
        switch bundleID {
        case screenshotID: return "camera.viewfinder"
        case recordingID: return "record.circle"
        default: return nil
        }
    }

    /// 圆盘图标：把 SF Symbol 渲染成白色实心图（和原生 App 图标一样铺满方框）
    static func symbolImage(bundleID: String, size: CGFloat) -> UIImage? {
        guard let name = symbolName(for: bundleID) else { return nil }
        let config = UIImage.SymbolConfiguration(pointSize: size * 0.56, weight: .medium)
        guard let image = UIImage(systemName: name, withConfiguration: config) else { return nil }
        return image.withTintColor(.white, renderingMode: .alwaysOriginal)
    }

    // MARK: - 分发

    static func perform(bundleID: String) {
        switch bundleID {
        case screenshotID:
            AevonLog.info("[快捷] 圆盘选择「截图」（AevonQuickScreenshotV262）")
            takeScreenshot()
        case recordingID:
            AevonLog.info("[快捷] 圆盘选择「录屏」（AevonQuickRecordingV262）")
            toggleRecording()
        default:
            break
        }
    }

    // MARK: - 截图

    private typealias CreateScreenImageFunc = @convention(c) () -> Unmanaged<CGImage>?

    private static func takeScreenshot() {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = screenImage()
            guard let image = image else {
                AevonLog.warn("[快捷] 截图失败：UICreateScreenImage / SBScreenShotter 都拿不到画面"
                    + "（AevonQuickActionV262）")
                return
            }
            DispatchQueue.main.async {
                UIImageWriteToSavedPhotosAlbum(image, AevonQuickActionSaver.shared,
                                               #selector(AevonQuickActionSaver.image(_:didFinishSavingWithError:contextInfo:)),
                                               nil)
            }
        }
    }

    private static func screenImage() -> UIImage? {
        // ① UIKit 私有 C 函数：截的是合成后的整屏
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "UICreateScreenImage") {
            let fn = unsafeBitCast(symbol, to: CreateScreenImageFunc.self)
            if let cg = fn()?.takeUnretainedValue() {
                return UIImage(cgImage: cg)
            }
        }
        // ② 退回 SpringBoard 私有类（老的 SBScreenShotter）
        if let cls = NSClassFromString("SBScreenShotter") as? NSObject.Type {
            let selector = NSSelectorFromString("sharedInstance")
            if cls.responds(to: selector) {
                let shared = cls.perform(selector)?.takeUnretainedValue() as? NSObject
                let shot = NSSelectorFromString("saveScreenshot:withCompletion:")
                if let shared = shared, shared.responds(to: shot) {
                    // 这个 API 自己存相册，没有返回值可用 —— 走不了就放弃，交给日志
                    AevonLog.info("[快捷] 改用 SBScreenShotter 截图（AevonQuickActionV262）")
                    _ = shared.perform(shot, with: nil, with: nil)
                }
            }
        }
        return nil
    }

    // MARK: - 录屏

    private static var isRecording = false

    private static func toggleRecording() {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            AevonLog.warn("[快捷] 录屏不可用：RPScreenRecorder.isAvailable = false"
                + "（本机 / 本进程不允许录制）（AevonQuickActionV262）")
            return
        }
        if isRecording {
            recorder.stopRecording { preview, error in
                isRecording = false
                if let error = error {
                    AevonLog.warn("[快捷] 停止录屏失败：\(error.localizedDescription)（AevonQuickActionV262）")
                    return
                }
                AevonLog.info("[快捷] 录屏已停止（AevonQuickActionV262）")
                if let preview = preview {
                    savePreview(preview)
                } else {
                    AevonLog.warn("[快捷] 录屏没有返回预览控制器，视频可能未落盘（AevonQuickActionV262）")
                }
            }
            return
        }
        recorder.isMicrophoneEnabled = false
        recorder.startRecording { error in
            if let error = error {
                AevonLog.warn("[快捷] 开始录屏失败：\(error.localizedDescription)（AevonQuickActionV262）")
                isRecording = false
                return
            }
            isRecording = true
            AevonLog.info("[快捷] 开始录屏（再点一次「录屏」结束并保存）（AevonQuickActionV262）")
        }
    }

    /// 把录制结果写相册：RPPreviewViewController 的公开接口只有分享面板（SpringBoard
    /// 里没有可用的宿主），所以直接调它的私有保存方法；取不到就如实记日志。
    private static func savePreview(_ controller: RPPreviewViewController) {
        let selectors = ["saveVideoToCameraRoll:", "savePreviewToCameraRoll:"]
        for name in selectors {
            let selector = NSSelectorFromString(name)
            if controller.responds(to: selector) {
                _ = controller.perform(selector, with: nil)
                AevonLog.info("[快捷] 录屏走 \(name) 存相册（AevonQuickActionV262）")
                return
            }
        }
        AevonLog.warn("[快捷] 录屏已生成但没有可用的存相册入口（RPPreviewViewController 无 "
            + selectors.joined(separator: " / ") + "）（AevonQuickActionV262）")
    }
}
