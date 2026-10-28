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
import AudioToolbox

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

    /// 圆盘图标：V0.2.64（AevonActionIconV264）改成**画成一张完整的图标**
    /// （彩色圆角底 + 白色 SF Symbol）。用户 Aevon(38) #5.4「圆盘中的截图和录屏没有图标」——
    /// 上一版只把 SF Symbol 当图片塞进去，底色是透明的，在白/浅色圆盘底上等于看不见。
    /// 现在自己渲染：底色按动作区分（截图=蓝、录屏=红），符号居中，圆角率与 App 图标一致。
    static func symbolImage(bundleID: String, size: CGFloat) -> UIImage? {
        guard let name = symbolName(for: bundleID), size > 8 else { return nil }
        let side = max(size, 12)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.2237)
            path.addClip()
            let colors: [UIColor]
            switch bundleID {
            case screenshotID:
                colors = [UIColor(red: 0.29, green: 0.52, blue: 1.00, alpha: 1),
                          UIColor(red: 0.13, green: 0.31, blue: 0.86, alpha: 1)]
            case recordingID:
                colors = [UIColor(red: 1.00, green: 0.35, blue: 0.31, alpha: 1),
                          UIColor(red: 0.78, green: 0.12, blue: 0.14, alpha: 1)]
            default:
                colors = [UIColor(white: 0.35, alpha: 1), UIColor(white: 0.18, alpha: 1)]
            }
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors.map { $0.cgColor } as CFArray,
                                         locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient,
                                                     start: CGPoint(x: 0, y: 0),
                                                     end: CGPoint(x: 0, y: side),
                                                     options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.46, weight: .semibold)
            guard let glyph = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
            let glyphSize = glyph.size
            glyph.draw(at: CGPoint(x: (side - glyphSize.width) / 2,
                                   y: (side - glyphSize.height) / 2))
        }
        return image
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
    private typealias ScreenUIImageFn = @convention(c) (CGFloat) -> Unmanaged<AnyObject>?
    private typealias BoolArgVoidFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void

    /* V0.2.64（AevonQuickShotV264，用户 Aevon(38) #5.4「截图成功但没有提示、
     * 也无法和 Snapper 等工具接力」）：
     *
     * 上一版先试 `SBUIController -_takeScreenshotAndEdit:`，Aevon(38) 日志证明它在
     * 本机**根本不存在**（「本系统既没有 SBUIController 截图方法」），最后落到
     * `UICreateScreenImage` —— 那条在 SpringBoard 里是空壳（能拿到图但抓的是空白）。
     *
     * 改回逆向档案里 ScreenCore 的做法：`_UICreateScreenUIImageWithRotation(0)`，
     * 这是 UIKit 的私有截图函数，返回 UIImage（不经过 CGImage 转换），在 SpringBoard
     * 里能拿到**合成后的整屏**。拿到图之后：
     *   ① 写相册（PHPhotoLibrary，有成功回调，不会「假成功」）；
     *   ② 同时复制到剪贴板 —— Snapper / 长截图这类工具都从剪贴板接图；
     *   ③ 弹一个自己的提示条（SB 里没有系统截图缩略图，只能自己给反馈）。
     */
    @discardableResult
    private static func captureScreenImage() -> UIImage? {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_UICreateScreenUIImageWithRotation") {
            let fn = unsafeBitCast(symbol, to: ScreenUIImageFn.self)
            if let image = fn(0)?.takeUnretainedValue() as? UIImage, image.size.width > 10 {
                AevonLog.info("[快捷] 截图走 _UICreateScreenUIImageWithRotation：\(Int(image.size.width))x\(Int(image.size.height))（AevonQuickShotV264）")
                return image
            }
        }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "UICreateScreenImage") {
            let fn = unsafeBitCast(symbol, to: CreateScreenImageFunc.self)
            if let cg = fn()?.takeUnretainedValue() {
                AevonLog.info("[快捷] 截图走 UICreateScreenImage 兜底（AevonQuickShotV264）")
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    private static func takeScreenshot() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = captureScreenImage() else {
                AevonLog.warn("[快捷] 截图失败：_UICreateScreenUIImageWithRotation / UICreateScreenImage "
                    + "都拿不到画面（AevonQuickShotV264）")
                DispatchQueue.main.async { AevonQuickToast.show("截图失败") }
                return
            }
            DispatchQueue.main.async {
                UIPasteboard.general.image = image
                AudioServicesPlaySystemSound(1108)   // 快门音（系统的截图音在 SB 里放不出来）
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { ok, error in
                DispatchQueue.main.async {
                    if ok {
                        AevonLog.info("[快捷] 截图已存相册 + 已复制到剪贴板（AevonQuickShotV264）")
                        AevonQuickToast.show("截图已保存 · 已复制")
                    } else {
                        AevonLog.warn("[快捷] 截图存相册失败：\(error?.localizedDescription ?? "未知")"
                            + "（已放进剪贴板）（AevonQuickShotV264）")
                        AevonQuickToast.show("截图已复制（相册保存失败）")
                    }
                }
            })
        }
    }

    // MARK: - 录屏

    private static var isRecording = false
    private typealias StopRecordFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    /// V0.2.64（AevonRecorderFindV264）：在整个进程里找「能开始/停止系统录屏」的对象。
    ///
    /// Aevon(38) 日志证明上一版的四个候选类名（SBControlCenterController 等）**一个都不存在**
    /// （「没有可用的系统录屏服务」→ 退回 ReplayKit → 「无法开始录制」）。
    /// 这次不再猜类名：直接遍历本进程所有类，挑类名含 `Record`、且能拿到单例、
    /// 且实例上有 `startSystemRecording*` / `startRecording` / `stopSystemRecording:` 的，
    /// 命中就把**真实类名**写进日志（下一版可以按它硬编码，省掉遍历）。
    private typealias StartSystemRecordFn = @convention(c) (AnyObject, Selector, ObjCBool, AnyObject?) -> Void
    private typealias StartRecordFn = @convention(c) (AnyObject, Selector) -> Void

    private static var cachedRecordingService: NSObject?
    private static var recordingServiceSearched = false

    private static func dynamicRecordingService() -> NSObject? {
        if recordingServiceSearched { return cachedRecordingService }
        recordingServiceSearched = true
        let accessors = ["sharedInstance", "sharedInstanceIfExists", "controller",
                         "sharedController", "sharedRecorder", "defaultService"]
        let startSels = ["startSystemRecordingWithMicrophoneEnabled:handler:",
                         "startSystemRecordingWithMicrophoneEnabled:",
                         "startRecording", "startRecordingWithHandler:"]
        let stopSels = ["stopSystemRecording:", "stopSystemRecording", "stopRecording"]
        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count), count > 0 else {
            AevonLog.warn("[快捷] 录屏探测：拿不到类表（AevonRecorderFindV264）")
            return nil
        }
        defer { free(UnsafeMutableRawPointer(list)) }
        var seen: [String] = []
        for index in 0..<Int(count) {
            let cls: AnyClass = list[index]
            let name = NSStringFromClass(cls)
            guard name.lowercased().contains("record") else { continue }
            guard let meta = cls as? NSObject.Type else { continue }
            for accessor in accessors {
                let sel = NSSelectorFromString(accessor)
                guard meta.responds(to: sel),
                      let shared = meta.perform(sel)?.takeUnretainedValue() as? NSObject else { continue }
                let hasStart = startSels.contains { shared.responds(to: NSSelectorFromString($0)) }
                let hasStop = stopSels.contains { shared.responds(to: NSSelectorFromString($0)) }
                if hasStart || hasStop {
                    AevonLog.info("[快捷] 录屏服务命中：\(name) \(accessor)"
                        + "（start=\(hasStart) stop=\(hasStop)）（AevonRecorderFindV264）")
                    cachedRecordingService = shared
                    return shared
                }
            }
            if seen.count < 8 { seen.append(name) }
        }
        AevonLog.warn("[快捷] 录屏探测：没有命中（候选类："
            + (seen.isEmpty ? "无" : seen.joined(separator: ", "))
            + "）（AevonRecorderFindV264）")
        return nil
    }

    @discardableResult
    private static func startSystemRecording(_ service: NSObject) -> Bool {
        let specialized = NSSelectorFromString("startSystemRecordingWithMicrophoneEnabled:handler:")
        if service.responds(to: specialized),
           let method = class_getInstanceMethod(type(of: service), specialized) {
            let fn = unsafeBitCast(method_getImplementation(method), to: StartSystemRecordFn.self)
            fn(service, specialized, ObjCBool(false), nil)
            isRecording = true
            AevonLog.info("[快捷] 已开始系统录屏（不录麦克风；再点一次「录屏」结束并保存）"
                + "（AevonQuickShotV264 AevonRecorderFindV264）")
            return true
        }
        let candidates = ["startSystemRecordingWithMicrophoneEnabled:", "startRecording"]
        for name in candidates {
            let sel = NSSelectorFromString(name)
            guard service.responds(to: sel),
                  let method = class_getInstanceMethod(type(of: service), sel) else { continue }
            let fn = unsafeBitCast(method_getImplementation(method), to: BoolArgVoidFn.self)
            fn(service, sel, ObjCBool(false))
            isRecording = true
            AevonLog.info("[快捷] 已开始系统录屏：\(name)（AevonRecorderFindV264）")
            return true
        }
        let simple = NSSelectorFromString("startRecording")
        if service.responds(to: simple),
           let method = class_getInstanceMethod(type(of: service), simple) {
            let fn = unsafeBitCast(method_getImplementation(method), to: StartRecordFn.self)
            fn(service, simple)
            isRecording = true
            AevonLog.info("[快捷] 已开始系统录屏：startRecording（AevonRecorderFindV264）")
            return true
        }
        return false
    }

    @discardableResult
    private static func stopSystemRecording(_ service: NSObject) -> Bool {
        let candidates = ["stopSystemRecording:", "stopSystemRecording", "stopRecording"]
        for name in candidates {
            let sel = NSSelectorFromString(name)
            guard service.responds(to: sel),
                  let method = class_getInstanceMethod(type(of: service), sel) else { continue }
            let fn = unsafeBitCast(method_getImplementation(method), to: StopRecordFn.self)
            fn(service, sel, nil)
            isRecording = false
            AevonLog.info("[快捷] 已停止系统录屏：\(name)（视频由系统存相册）（AevonRecorderFindV264）")
            return true
        }
        return false
    }

    private static func toggleRecording() {
        // V0.2.64（AevonRecorderFindV264）：先动态找系统录屏服务（不再猜类名）。
        if let service = dynamicRecordingService() {
            if isRecording {
                if stopSystemRecording(service) {
                    AevonQuickToast.show("录屏已结束")
                    return
                }
            } else if startSystemRecording(service) {
                AevonQuickToast.show("已开始录屏")
                return
            }
        }
        // 兜底：ReplayKit（多数 SpringBoard 上会直接失败，只留日志）
        AevonLog.warn("[快捷] 没有可用的系统录屏服务 → 退回 RPScreenRecorder"
            + "（AevonQuickShotV264）")
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

/// V0.2.64（AevonQuickShotV264）：SpringBoard 里没有系统截图缩略图，自己给一条提示。
/// 用户 Aevon(38) #5.4：「截图成功了，但是没有提示」—— 存相册是静默的，
/// 这里在屏幕底部弹一条 1.6 秒的提示条（不接管触摸，不挡浮窗）。
final class AevonQuickToast {
    private static var window: UIWindow?
    private static let tag = 0x7A37

    static func show(_ text: String) {
        DispatchQueue.main.async {
            guard Thread.isMainThread else { return }
            var overlay = window
            if overlay == nil { overlay = AevonHostWindow.makeOverlayWindow() }
            guard let panel = overlay else { return }
            window = panel
            panel.isHidden = false
            panel.frame = UIScreen.main.bounds
            panel.windowLevel = AevonWindowLevels.overlay + 2
            guard let host = panel.rootViewController?.view else { return }
            host.subviews.filter { $0.tag == tag }.forEach { $0.removeFromSuperview() }

            let screen = UIScreen.main.bounds
            let label = UILabel()
            label.tag = tag
            label.text = text
            label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 2
            label.backgroundColor = UIColor(white: 0.08, alpha: 0.86)
            label.layer.cornerRadius = 14
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            let maxWidth = screen.width - 64
            let fitting = label.sizeThatFits(CGSize(width: maxWidth, height: 200))
            let width = min(max(fitting.width + 36, 132), maxWidth)
            let height = max(fitting.height + 20, 44)
            label.frame = CGRect(x: (screen.width - width) / 2,
                                 y: screen.height - height - 120,
                                 width: width, height: height)
            host.addSubview(label)

            label.alpha = 0
            label.transform = CGAffineTransform(translationX: 0, y: 8)
            UIView.animate(withDuration: 0.18, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction],
                           animations: {
                label.alpha = 1
                label.transform = .identity
            }, completion: { _ in
                UIView.animate(withDuration: 0.28, delay: 1.5,
                               options: [.curveEaseIn, .allowUserInteraction],
                               animations: {
                    label.alpha = 0
                    label.transform = CGAffineTransform(translationX: 0, y: -6)
                }, completion: { _ in
                    label.removeFromSuperview()
                })
            })
        }
    }
}
