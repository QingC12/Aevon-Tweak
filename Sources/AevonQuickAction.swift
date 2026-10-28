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
import AVFoundation

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
    /* V0.2.66（AevonSysShotV266，用户 Aevon(39) #9「截图依旧不会联动其他插件」）：
     * 主路改走**系统截图管线** `SBScreenShotter -saveScreenshot:` —— 快门音、缩放
     * 动画、相册落库全部由系统完成，hook 了截图完成事件的插件（Snapper 等）随之联动；
     * 这是 home+电源键那一条真管线（cycript 实锤 `[[SBScreenShotter sharedInstance]
     * saveScreenshot:YES]` 就是系统截图）。装前用 method_getTypeEncoding 自检
     * （0.2.52 安全模式铁律），类或方法不存在、编码不符就回落自抓帧老路。 */
    private static func takeSystemScreenshot() -> Bool {
        guard let cls = NSClassFromString("SBScreenShotter") as? NSObject.Type,
              let shared = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue()
        else { return false }
        let sel = NSSelectorFromString("saveScreenshot:")
        guard let m = class_getInstanceMethod(type(of: shared), sel),
              let rawTypes = method_getTypeEncoding(m) else { return false }
        let types = String(cString: rawTypes)
        // v24@0:8@16B24 = (void)(id self, SEL, BOOL)
        guard types.hasPrefix("v"), types.contains("@0:8@"), types.contains("B") else {
            AevonLog.warn("[快捷] SBScreenShotter saveScreenshot: 编码不符（\(types)）→ 走自抓帧（AevonSysShotV266）")
            return false
        }
        shared.perform(sel, with: NSNumber(value: true))
        AevonLog.info("[快捷] 截图走系统管线 SBScreenShotter -saveScreenshot:YES"
            + "（快门/闪光/相册/联动全由系统完成）（AevonSysShotV266）")
        return true
    }

    @discardableResult
    static func captureScreenImage() -> UIImage? {
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
        // V0.2.66（AevonSysShotV266）：先试系统管线（联动达成）；失败回落自抓帧老路。
        if takeSystemScreenshot() { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = captureScreenImage() else {
                AevonLog.warn("[快捷] 截图失败：系统管线不可用且自抓帧拿不到画面（AevonSysShotV266）")
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

    // MARK: - 录屏（V0.2.65：自己录，不再碰系统录屏服务）

    private static func toggleRecording() {
        AevonFrameRecorder.shared.toggle()
    }

    /// 给录制器用的抓帧入口（和截图同一条已验证通路）。
    static func captureFrameForRecorder() -> CGImage? {
        return captureScreenImage()?.cgImage
    }

}


/// V0.2.65（AevonOwnRecorderV265，用户 Aevon(38) #5「录屏依旧不可用（并且点击录屏时会自动注销）」）
///
/// 前面三版都在找「系统那个录屏服务」：
///   0.2.63 硬编码四个类名 → 本机一个都不存在；
///   0.2.64 改成遍历所有类、`perform` 取单例 → **一点就注销**。
/// 崩溃栈给了答案：`swift_dynamicCast` ← `_CF_forwarding_prep_0` ← dispatch 主队列，
/// 就是给某些类发 `perform(sharedInstance)` 拿回一个非 NSObject 的返回值（NSProxy 之类），
/// 再 `as? NSObject` 时走了消息转发 → 陷阱。这条路本身就不该走。
///
/// 现在自己录：每 1/6 秒用 `_UICreateScreenUIImageWithRotation`（和截图同一条已验证通路）
/// 抓一帧，AVAssetWriter 写 H.264 MP4，停止时存相册。不碰任何系统私有服务，
/// 也就不可能把 SpringBoard 带走。
final class AevonFrameRecorder {
    static let shared = AevonFrameRecorder()

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: Timer?
    private var outputURL: URL?
    private var startTime = CACurrentMediaTime()
    private var frames = 0
    private var failedFrames = 0
    /* V0.2.66（AevonRecLightV266，用户 Aevon(39) #9「录屏可以开关，但开启期间手机
     * 非常卡顿」）：6fps → 3fps。卡顿主因是每帧 `_UICreateScreenUIImageWithRotation`
     * 全屏合成渲染 —— 6fps 下主线程每秒被吃掉 6 次；3fps 减半。像素搬运
     * （CGContext 绘制 + CVPixelBuffer 填充）同时挪到后台队列，主线程只剩抓帧本身。
     * 顺滑度换流畅度：录教程/存证 3fps 够用，追求丝滑需要系统录屏（不可用）。 */
    private let fps: Double = 3

    var isRunning: Bool { writer != nil }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    private func start() {
        guard writer == nil else { return }
        guard let first = AevonQuickAction.captureFrameForRecorder() else {
            AevonLog.warn("[录屏] 抓不到第一帧，取消录制（AevonOwnRecorderV265）")
            AevonQuickToast.show("录屏失败：抓不到画面")
            return
        }
        var w = first.width
        var h = first.height
        w -= w % 2
        h -= h % 2
        guard w > 16, h > 16 else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Aevon-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let assWriter: AVAssetWriter
        do {
            assWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            AevonLog.warn("[录屏] 建不了输出文件：\(error.localizedDescription)（AevonOwnRecorderV265）")
            AevonQuickToast.show("录屏失败：无法建文件")
            return
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        let bufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard assWriter.canAdd(videoInput) else {
            AevonLog.warn("[录屏] 写入器不接受视频轨（AevonOwnRecorderV265）")
            return
        }
        assWriter.add(videoInput)
        guard assWriter.startWriting() else {
            AevonLog.warn("[录屏] startWriting 失败：\(assWriter.error?.localizedDescription ?? "未知")"
                + "（AevonOwnRecorderV265）")
            return
        }
        assWriter.startSession(atSourceTime: .zero)
        writer = assWriter
        input = videoInput
        adaptor = bufferAdaptor
        outputURL = url
        startTime = CACurrentMediaTime()
        frames = 0
        failedFrames = 0
        let ticker = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        appendOffMain(first, at: CMTime(seconds: 0, preferredTimescale: 600))
        AevonLog.info("[录屏] 开始录制：\(w)x\(h) @ \(Int(fps))fps → \(url.lastPathComponent)"
            + "（再点一次「录屏」结束并存相册）（AevonOwnRecorderV265 AevonQuickSystemV263）")
        AevonQuickToast.show("开始录屏")
    }

    private func tick() {
        guard let assWriter = writer, assWriter.status == .writing else { return }
        guard let frame = AevonQuickAction.captureFrameForRecorder() else {
            failedFrames += 1
            return
        }
        let elapsed = CACurrentMediaTime() - startTime
        // V0.2.66（AevonRecLightV266）：像素搬运挪后台，主线程只留抓帧一次调用。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.appendOffMain(frame, at: CMTime(seconds: elapsed, preferredTimescale: 600))
        }
    }

    private func appendOffMain(_ image: CGImage, at time: CMTime) {
        guard let adaptor, let pool = adaptor.pixelBufferPool else { return }
        guard adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            if let context = CGContext(data: base, width: width, height: height,
                                       bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: bitmapInfo) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: time) {
            frames += 1
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        guard let assWriter = writer, let videoInput = input else { return }
        let url = outputURL
        let total = frames
        let missed = failedFrames
        videoInput.markAsFinished()
        writer = nil
        input = nil
        adaptor = nil
        outputURL = nil
        if total < 2 {
            AevonLog.warn("[录屏] 只有 \(total) 帧，当成失败处理（AevonOwnRecorderV265）")
            if let url { try? FileManager.default.removeItem(at: url) }
            AevonQuickToast.show("录屏失败：没抓到足够画面")
            return
        }
        AevonLog.info("[录屏] 停止录制，正在收尾（\(total) 帧，失败 \(missed) 帧）"
            + "（AevonOwnRecorderV265）")
        assWriter.finishWriting {
            let status = assWriter.status
            let failure = assWriter.error?.localizedDescription ?? "未知"
            DispatchQueue.main.async {
                guard status == .completed, let url else {
                    AevonLog.warn("[录屏] 收尾失败：status=\(status.rawValue) \(failure)"
                        + "（AevonOwnRecorderV265）")
                    AevonQuickToast.show("录屏保存失败")
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }, completionHandler: { ok, error in
                    DispatchQueue.main.async {
                        if ok {
                            AevonLog.info("[录屏] 已存相册（\(total) 帧 / \(String(format: "%.1f", Double(total) / 6.0)) 秒）"
                                + "（AevonOwnRecorderV265）")
                            AevonQuickToast.show("录屏已存相册")
                        } else {
                            AevonLog.warn("[录屏] 存相册失败：\(error?.localizedDescription ?? "未知")"
                                + "（AevonOwnRecorderV265）")
                            AevonQuickToast.show("录屏已生成（相册保存失败）")
                        }
                    }
                })
            }
        }
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
