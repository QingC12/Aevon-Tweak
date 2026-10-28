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
    private typealias BoolArgVoidFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void

    private static func takeScreenshot() {
        // V0.2.63（AevonQuickSystemV263，用户 Aevon(37) #3「截图和录屏失效」）：
        // 0.2.62 走的 `UICreateScreenImage()` 在 SpringBoard 里拿到的是**空壳**
        // （跨进程远程表面抓不到，日志却照样报「已保存」）。
        // 参考 `其他插件逆向/ScreenCore`：它用的是 SpringBoard 自己的截图入口
        // `-[SBUIController _takeScreenshotAndEdit:]` —— 和按侧键 + 音量键、
        // 控制中心截图走的是同一条系统路径，存相册、带编辑界面都由系统负责。
        if runSystemScreenshot(edit: false) { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = screenImage()
            guard let image = image else {
                AevonLog.warn("[快捷] 截图失败：SBUIController / SBScreenShotter / "
                    + "UICreateScreenImage 三条路都拿不到画面（AevonQuickSystemV263）")
                return
            }
            DispatchQueue.main.async {
                UIImageWriteToSavedPhotosAlbum(image, AevonQuickActionSaver.shared,
                                               #selector(AevonQuickActionSaver.image(_:didFinishSavingWithError:contextInfo:)),
                                               nil)
            }
        }
    }

    /// 走系统截图（SpringBoard 自己的入口）。成功返回 true（截图由系统存相册）。
    @discardableResult
    private static func runSystemScreenshot(edit: Bool) -> Bool {
        // ① SBUIController -_takeScreenshotAndEdit:（ScreenCore 用的就是这条）
        if let cls = NSClassFromString("SBUIController") as? NSObject.Type {
            for accessor in ["sharedInstance", "sharedInstanceIfExists", "controller"] {
                let sel = NSSelectorFromString(accessor)
                guard cls.responds(to: sel),
                      let shared = cls.perform(sel)?.takeUnretainedValue() as? NSObject else { continue }
                let shot = NSSelectorFromString("_takeScreenshotAndEdit:")
                if shared.responds(to: shot),
                   let method = class_getInstanceMethod(type(of: shared), shot) {
                    let fn = unsafeBitCast(method_getImplementation(method), to: BoolArgVoidFn.self)
                    fn(shared, shot, ObjCBool(edit))
                    AevonLog.info("[快捷] 走系统截图：SBUIController \(accessor) "
                        + "-_takeScreenshotAndEdit:\(edit ? "YES" : "NO")"
                        + "（AevonQuickSystemV263）")
                    return true
                }
                let edit2 = NSSelectorFromString("takeScreenshotAndEdit:")
                if shared.responds(to: edit2),
                   let method = class_getInstanceMethod(type(of: shared), edit2) {
                    let fn = unsafeBitCast(method_getImplementation(method), to: BoolArgVoidFn.self)
                    fn(shared, edit2, ObjCBool(edit))
                    AevonLog.info("[快捷] 走系统截图：SBUIController \(accessor) "
                        + "-takeScreenshotAndEdit:（AevonQuickSystemV263）")
                    return true
                }
            }
        }
        // ② 老版 SBScreenShotter -saveScreenshot:（自带存相册）
        if let cls = NSClassFromString("SBScreenShotter") as? NSObject.Type {
            let sel = NSSelectorFromString("sharedInstance")
            if cls.responds(to: sel), let shared = cls.perform(sel)?.takeUnretainedValue() as? NSObject {
                for name in ["saveScreenshot:", "saveScreenshotInPhotoLibrary:"] {
                    let shot = NSSelectorFromString(name)
                    guard shared.responds(to: shot),
                          let method = class_getInstanceMethod(type(of: shared), shot) else { continue }
                    let fn = unsafeBitCast(method_getImplementation(method), to: BoolArgVoidFn.self)
                    fn(shared, shot, ObjCBool(true))
                    AevonLog.info("[快捷] 走系统截图：SBScreenShotter \(name)"
                        + "（AevonQuickSystemV263）")
                    return true
                }
            }
        }
        AevonLog.warn("[快捷] 本系统既没有 SBUIController 截图方法，也没有 SBScreenShotter"
            + " → 退回 UICreateScreenImage（AevonQuickSystemV263）")
        return false
    }

    private static func screenImage() -> UIImage? {
        // 最后兜底：UIKit 私有 C 函数（SpringBoard 里通常是空壳，只能算尽力）
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "UICreateScreenImage") {
            let fn = unsafeBitCast(symbol, to: CreateScreenImageFunc.self)
            if let cg = fn()?.takeUnretainedValue() {
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    // MARK: - 录屏

    private static var isRecording = false
    private typealias StartRecordFn = @convention(c) (AnyObject, Selector, ObjCBool, AnyObject?) -> Void
    private typealias StopRecordFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    /// 系统录屏服务（ScreenCore 里的 `startSystemRecordingWithMicrophoneEnabled:handler:`
    /// 与 `stopSystemRecording:`，与「控制中心 → 录屏」是同一条路径）。
    /// 类名在不同系统版本上会挪，这里按候选表找「既有 sharedInstance 又有这两个方法」的那个。
    private static func recordingService() -> NSObject? {
        let candidates = ["SBControlCenterController", "SBScreenRecordingService",
                          "SBRecordingService", "SBScreenRecordingController"]
        let accessors = ["sharedInstance", "sharedInstanceIfExists", "controller", "sharedController"]
        for name in candidates {
            guard let cls = NSClassFromString(name) as? NSObject.Type else { continue }
            for accessor in accessors {
                let sel = NSSelectorFromString(accessor)
                guard cls.responds(to: sel),
                      let shared = cls.perform(sel)?.takeUnretainedValue() as? NSObject else { continue }
                if shared.responds(to: NSSelectorFromString("startSystemRecordingWithMicrophoneEnabled:handler:"))
                    || shared.responds(to: NSSelectorFromString("stopSystemRecording:")) {
                    AevonLog.info("[快捷] 找到系统录屏服务：\(name) \(accessor)"
                        + "（AevonQuickSystemV263）")
                    return shared
                }
            }
        }
        return nil
    }

    private static func toggleRecording() {
        // V0.2.63（AevonQuickSystemV263，用户 Aevon(37) #3）：0.2.62 用 RPScreenRecorder，
        // 真机上 `startRecording` 直接回错「无法开始录制」—— ReplayKit 在 SpringBoard
        // 进程里没有录制宿主。改走系统录屏服务（和控制中心那颗录屏按钮同一条路）。
        if let service = recordingService() {
            if isRecording {
                let stop = NSSelectorFromString("stopSystemRecording:")
                if service.responds(to: stop),
                   let method = class_getInstanceMethod(type(of: service), stop) {
                    let fn = unsafeBitCast(method_getImplementation(method), to: StopRecordFn.self)
                    fn(service, stop, nil)
                    isRecording = false
                    AevonLog.info("[快捷] 已停止系统录屏（视频由系统存相册）"
                        + "（AevonQuickSystemV263）")
                    return
                }
            } else {
                let start = NSSelectorFromString("startSystemRecordingWithMicrophoneEnabled:handler:")
                if service.responds(to: start),
                   let method = class_getInstanceMethod(type(of: service), start) {
                    let fn = unsafeBitCast(method_getImplementation(method), to: StartRecordFn.self)
                    fn(service, start, ObjCBool(false), nil)
                    isRecording = true
                    AevonLog.info("[快捷] 已开始系统录屏（不录麦克风；再点一次「录屏」结束并保存）"
                        + "（AevonQuickSystemV263）")
                    return
                }
            }
        }
        // 兜底：ReplayKit（多数 SpringBoard 上会直接失败，只留日志）
        AevonLog.warn("[快捷] 没有可用的系统录屏服务 → 退回 RPScreenRecorder"
            + "（AevonQuickSystemV263）")
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            AevonLog.warn("[快捷] 录屏不可用：RPScreenRecorder.isAvailable = false"
                + "（AevonQuickSystemV263）")
            return
        }
        if isRecording {
            recorder.stopRecording { preview, error in
                isRecording = false
                if let error = error {
                    AevonLog.warn("[快捷] 停止录屏失败：\(error.localizedDescription)（AevonQuickSystemV263）")
                    return
                }
                AevonLog.info("[快捷] 录屏已停止（AevonQuickSystemV263）")
                if let preview = preview {
                    savePreview(preview)
                } else {
                    AevonLog.warn("[快捷] 录屏没有返回预览控制器，视频可能未落盘（AevonQuickSystemV263）")
                }
            }
            return
        }
        recorder.isMicrophoneEnabled = false
        recorder.startRecording { error in
            if let error = error {
                AevonLog.warn("[快捷] 开始录屏失败：\(error.localizedDescription)（AevonQuickSystemV263）")
                isRecording = false
                return
            }
            isRecording = true
            AevonLog.info("[快捷] 开始录屏（ReplayKit）（AevonQuickSystemV263）")
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
