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
        /* V0.2.68（AevonShotMgrV268，用户 Aevon(40) #4「截屏依旧无法触发联动」）：
         * Aevon(40) 16:05:04 实锤：`objc_getClass("SBScreenShotter")` 在本机
         * iOS 17.3.1 **返回 nil**（0.2.67 的警告日志），系统截图类早已换代 ——
         * The Apple Wiki（Updating extensions for iOS 9.3.3）明确记载：
         *   "SBScreenShotter has been replaced with SBScreenshotManager.
         *    An instance is available through SpringBoard's screenshotManager
         *    property. Use saveScreenshotsWithCompletion:."
         * 即：单例走 `SpringBoard.screenshotManager` 属性，方法是
         * `-saveScreenshotsWithCompletion:`（侧键+音量上那条真管线，
         * 快门音/闪光/缩略图/相册/第三方插件联动全由系统完成）。
         * 探测链（每一级都打日志，真机一测就能锁定命中级）：
         *   ① SpringBoard.screenshotManager + saveScreenshotsWithCompletion:
         *   ② SBScreenShotter.sharedInstance + saveScreenshot:（0.2.67 老路保留）
         * 两级全空才回落自抓帧。completion 传真空 block 最稳。
         * 装前照旧 method_getTypeEncoding 自检（fail-closed 铁律）。 */
        let sb = UIApplication.shared as NSObject
        if let mgr = sb.value(forKey: "screenshotManager") as? NSObject {
            let sel = NSSelectorFromString("saveScreenshotsWithCompletion:")
            if let m = class_getInstanceMethod(type(of: mgr), sel),
               let rawTypes = method_getTypeEncoding(m) {
                let types = String(cString: rawTypes)
                // v16@0:8@?16 = (void)(id self, SEL, block)
                if types.hasPrefix("v"), types.contains("@0:8@"), types.contains("@?") {
                    typealias ShotFn = @convention(c) (UnsafeRawPointer, Selector, AnyObject) -> Void
                    let fn = unsafeBitCast(msgSendRaw(), to: ShotFn.self)
                    let done: @convention(block) () -> Void = {}
                    fn(Unmanaged.passUnretained(mgr).toOpaque(), sel,
                       unsafeBitCast(done, to: AnyObject.self))
                    AevonLog.info("[快捷] 截图走系统管线 SBScreenshotManager"
                        + " -saveScreenshotsWithCompletion:（快门/闪光/相册/联动全由系统完成）"
                        + "（AevonShotMgrV268 AevonShotSysV267）")
                    return true
                }
                AevonLog.warn("[快捷] SBScreenshotManager.saveScreenshotsWithCompletion: "
                    + "编码不符（\(types)）→ 试老类（AevonShotMgrV268）")
            } else {
                AevonLog.warn("[快捷] SBScreenshotManager 在但无 saveScreenshotsWithCompletion:"
                    + " → 试老类（AevonShotMgrV268）")
            }
        } else {
            AevonLog.warn("[快捷] SpringBoard.screenshotManager 属性不可达 → 试老类"
                + "（AevonShotMgrV268）")
        }

        // 候选②：SBScreenShotter（0.2.67 原路；本机实测类不存在，保留防 iOS 回换）
        guard let cls = objc_getClass("SBScreenShotter") else {
            AevonLog.warn("[快捷] SBScreenShotter 类不存在 → 走自抓帧（AevonShotMgrV268）")
            return false
        }
        let sharedSel = sel_registerName("sharedInstance")
        typealias MsgSendId = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
        let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
            .map { unsafeBitCast($0, to: MsgSendId.self) }
        guard let send = msgSend, let sharedPtr = send(cls as AnyObject, sharedSel) else {
            AevonLog.warn("[快捷] SBScreenShotter sharedInstance 不可达 → 走自抓帧"
                + "（AevonShotMgrV268）")
            return false
        }
        let shared = Unmanaged<AnyObject>.fromOpaque(sharedPtr).takeUnretainedValue()
        let sel = NSSelectorFromString("saveScreenshot:")
        guard let m = class_getInstanceMethod(type(of: shared), sel),
              let rawTypes = method_getTypeEncoding(m) else {
            AevonLog.warn("[快捷] SBScreenShotter 无 saveScreenshot: → 走自抓帧"
                + "（AevonShotMgrV268）")
            return false
        }
        let types = String(cString: rawTypes)
        // v24@0:8@16B24 = (void)(id self, SEL, BOOL)
        guard types.hasPrefix("v"), types.contains("@0:8@"), types.contains("B") else {
            AevonLog.warn("[快捷] SBScreenShotter saveScreenshot: 编码不符（\(types)）→ 走自抓帧"
                + "（AevonShotMgrV268）")
            return false
        }
        typealias ShotFn = @convention(c) (UnsafeRawPointer, Selector, Bool) -> Void
        let fn = unsafeBitCast(msgSendRaw(), to: ShotFn.self)
        fn(sharedPtr, sel, true)
        AevonLog.info("[快捷] 截图走系统管线 SBScreenShotter -saveScreenshot:YES"
            + "（快门/闪光/相册/联动全由系统完成）（AevonShotMgrV268）")
        return true
    }

    private static func msgSendRaw() -> UnsafeMutableRawPointer {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")!
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


/// V0.2.68（AevonReplayRecV268，用户 Aevon(40) #1「为什么不按照系统中的录屏那样记录视频？
/// 系统中录制的视频是 94 帧，播放时很流畅」+ #4「录屏有时候会失败」）
///
/// 用户问到了根上：自绘管线（drawHierarchy 抓帧 → 软编）天生不可能流畅 ——
/// Aevon(40) 实测 18 秒只录到 **31 帧**（约 1.7fps，标称 8fps 全被主线程吃掉），
/// 而且收尾 `status=3 这项操作无法完成`：真凶是 0.2.66 起把 append 扔进
/// `DispatchQueue.global` —— **那是并发队列**，多帧并行 append 时 presentationTime
/// 乱序倒退，AVAssetWriter 直接置 failed，finishWriting 必然 status=3。
///
/// 主路改走 **RPScreenRecorder**（ReplayKit 公开框架，AevonQuickAction.swift 自
/// 0.2.62 就 import 了）：
///   · 逆向档案 `analysis/screencore`（ScreenCore 插件 strings）实锤它就是在
///     SpringBoard 进程里用 `RPScreenRecorder` + start/stop + NSError 回调做系统级
///     录屏 —— 硬件编码、帧率与系统录屏一致，正是用户要的那条管线；
///   · `startCapture(handler:completionHandler:)`（iOS 11+，Apple 文档实锤的
///     Swift 签名：handler = (CMSampleBuffer, RPSampleBufferType, Error?)）收
///     sample buffer（后台线程、硬件帧、零拷贝），串行队列 append 进
///     AVAssetWriter（H.264 硬编）。纯 Swift，无需 delegate 垫片。
///
/// 兜底：RPScreenRecorder 不可用/启动失败 → 回落自绘管线，但 append 改**专用串行
/// 队列** + 时间戳在 append 队列内现取（单调，永不倒退），status=3 不可能复发。
final class AevonFrameRecorder: NSObject {
    static let shared = AevonFrameRecorder()

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var appendQueue: DispatchQueue?
    private var timer: Timer?
    private var outputURL: URL?
    private var startTime = CACurrentMediaTime()
    private var frames = 0
    private var failedFrames = 0
    private var usingSystem = false
    private var stopRequested = false
    /* 自绘兜底档参数（V0.2.66/0.2.67 保留：主路失败才走，8fps/540 宽已够看）。 */
    private let fps: Double = 8
    private let recMaxWidth: CGFloat = 540

    var isRunning: Bool { writer != nil || usingSystem }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    private func start() {
        guard !isRunning else { return }
        frames = 0
        failedFrames = 0
        stopRequested = false
        outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Aevon-\(Int(Date().timeIntervalSince1970)).mp4")
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        // V0.2.68（AevonRecSerialV268）：append 只走这一条**串行**队列 ——
        // 时间戳永不倒退，status=3 从根上消灭（两条通路共用）。
        appendQueue = DispatchQueue(label: "com.aevon.recorder.append")
        if startSystemCapture() {
            AevonQuickToast.show("开始录屏")
            return
        }
        startOwnCapture()
    }

    // MARK: 主路：RPScreenRecorder（AevonReplayRecV268）

    private func startSystemCapture() -> Bool {
        let rec = RPScreenRecorder.shared()
        guard rec.isAvailable else {
            AevonLog.warn("[录屏] RPScreenRecorder 不可用（isAvailable=否）→ 走自绘兜底"
                + "（AevonReplayRecV268）")
            return false
        }
        usingSystem = true
        rec.startCapture(handler: { [weak self] sample, bufferType, error in
            guard let self, self.usingSystem, !self.stopRequested else { return }
            if let error {
                AevonLog.warn("[录屏] 系统抓屏帧错误：\(error.localizedDescription)"
                    + "（AevonReplayRecV268）")
                return
            }
            guard bufferType == .video else { return }
            self.appendQueue?.async { [weak self] in
                self?.appendSystemSample(sample)
            }
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error, self.usingSystem, !self.stopRequested {
                    AevonLog.warn("[录屏] RPScreenRecorder 启动失败：\(error.localizedDescription)"
                        + " → 走自绘兜底（AevonReplayRecV268）")
                    self.usingSystem = false
                    self.startOwnCapture()
                }
            }
        })
        AevonLog.info("[录屏] 主路启动：RPScreenRecorder 系统级抓屏（硬编、帧率与系统录屏"
            + "一致）（AevonReplayRecV268 AevonRecSerialV268）")
        return true
    }

    // MARK: 主路收帧（ReplayKit 内部队 → 串行 append 队列）

    private func appendSystemSample(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard let pb = CMSampleBufferGetImageBuffer(sb) else {
            failedFrames += 1
            return
        }
        // 首帧先建 writer（首帧时 writer 还是 nil，必须在 status 检查之前）。
        if writer == nil {
            guard ensureSystemWriter(pixelBuffer: pb, firstPTS: pts) else { return }
        }
        guard let assWriter = writer, assWriter.status == .writing else { return }
        guard let videoInput = input, videoInput.isReadyForMoreMediaData else {
            failedFrames += 1
            return
        }
        if adaptor?.append(sb, withPresentationTime: pts) == true {
            frames += 1
        } else {
            failedFrames += 1
            if assWriter.status == .failed, failedFrames <= 2 {
                AevonLog.warn("[录屏] 系统帧 append 失败：\(assWriter.error?.localizedDescription ?? "未知")"
                    + "（AevonReplayRecV268）")
            }
        }
    }

    /// 第一帧到达时才建 writer（RP 帧的尺寸/格式到那时才确定；会话起点 = 首帧 PTS）。
    private func ensureSystemWriter(pixelBuffer: CVPixelBuffer, firstPTS: CMTime) -> Bool {
        if writer != nil { return true }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 16, h > 16, let url = outputURL else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let assWriter: AVAssetWriter
        do {
            assWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            AevonLog.warn("[录屏] 建不了输出文件：\(error.localizedDescription)"
                + "（AevonReplayRecV268）")
            usingSystem = false
            return false
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        // 不钉像素格式（RP 给的帧格式由系统定），只给尺寸。
        let bufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard assWriter.canAdd(videoInput) else {
            AevonLog.warn("[录屏] 写入器不接受视频轨（AevonReplayRecV268）")
            usingSystem = false
            return false
        }
        assWriter.add(videoInput)
        guard assWriter.startWriting() else {
            AevonLog.warn("[录屏] startWriting 失败：\(assWriter.error?.localizedDescription ?? "未知")"
                + "（AevonReplayRecV268）")
            usingSystem = false
            return false
        }
        assWriter.startSession(atSourceTime: firstPTS)
        writer = assWriter
        input = videoInput
        adaptor = bufferAdaptor
        AevonLog.info("[录屏] 已开始录制（系统抓屏 \(w)x\(h)，再点一次「录屏」结束并存相册）"
            + "（AevonReplayRecV268）")
        return true
    }

    // MARK: 兜底：自绘抓帧（0.2.65 管线，append 改串行队列）

    private func startOwnCapture() {
        guard writer == nil, !usingSystem else { return }
        guard let first = AevonQuickAction.captureFrameForRecorder() else {
            AevonLog.warn("[录屏] 抓不到第一帧，取消录制（AevonOwnRecorderV265）")
            AevonQuickToast.show("录屏失败：抓不到画面")
            return
        }
        var w = first.width          // Int（CGImage 像素）
        var h = first.height
        if CGFloat(w) > recMaxWidth {
            let scale = recMaxWidth / CGFloat(w)
            w = Int((CGFloat(w) * scale).rounded(.down) / 2) * 2
            h = Int((CGFloat(h) * scale).rounded(.down) / 2) * 2
        }
        w -= w % 2
        h -= h % 2
        guard w > 16, h > 16 else { return }
        guard let url = outputURL else { return }
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
        startTime = CACurrentMediaTime()
        let ticker = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        AevonLog.info("[录屏] 开始录制（自绘兜底）：\(w)x\(h) @ \(Int(fps))fps → \(url.lastPathComponent)"
            + "（再点一次「录屏」结束并存相册）"
            + "（AevonOwnRecorderV265 AevonQuickSystemV263 AevonRecLightV266 AevonRecHdV267）")
        AevonQuickToast.show("开始录屏")
    }

    private func tick() {
        guard let assWriter = writer, assWriter.status == .writing else { return }
        guard let frame = AevonQuickAction.captureFrameForRecorder() else {
            failedFrames += 1
            return
        }
        // V0.2.68（AevonRecSerialV268）：帧丢进**串行** append 队列 —— 时间戳在队列内
        // 现取（单调），并发乱序导致的 status=3 从根上消灭。
        appendQueue?.async { [weak self] in
            self?.appendOwnFrame(frame)
        }
    }

    private func appendOwnFrame(_ image: CGImage) {
        guard let adaptor, let assWriter = writer, assWriter.status == .writing else { return }
        guard adaptor.assetWriterInput.isReadyForMoreMediaData else {
            failedFrames += 1
            return
        }
        let time = CMTime(seconds: CACurrentMediaTime() - startTime, preferredTimescale: 600)
        guard let pool = adaptor.pixelBufferPool else { return }
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
        } else {
            failedFrames += 1
        }
    }

    private func stop() {
        stopRequested = true
        timer?.invalidate()
        timer = nil
        if usingSystem {
            RPScreenRecorder.shared().stopCapture { _ in }
            usingSystem = false
            AevonLog.info("[录屏] 停止系统抓屏，正在收尾（\(frames) 帧，失败 \(failedFrames) 帧）"
                + "（AevonReplayRecV268）")
        }
        guard let assWriter = writer, let videoInput = input else { return }
        let url = outputURL
        let total = frames
        let missed = failedFrames
        // V0.2.68（AevonRecSerialV268）：markAsFinished / finishWriting 排在 append
        // 队列末尾 —— 飞行中的帧先落地，绝不在收尾后再 append（status=3 的另一半根因）。
        appendQueue?.async { [weak self] in
            guard let self else { return }
            videoInput.markAsFinished()
            self.writer = nil
            self.input = nil
            self.adaptor = nil
            self.outputURL = nil
            if total < 2 {
                AevonLog.warn("[录屏] 只有 \(total) 帧，当成失败处理（AevonReplayRecV268）")
                if let url { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async { AevonQuickToast.show("录屏失败：没抓到足够画面") }
                return
            }
            assWriter.finishWriting {
                let status = assWriter.status
                let failure = assWriter.error?.localizedDescription ?? "未知"
                DispatchQueue.main.async {
                    guard status == .completed, let url else {
                        AevonLog.warn("[录屏] 收尾失败：status=\(status.rawValue) \(failure)"
                            + "（AevonReplayRecV268）")
                        AevonQuickToast.show("录屏保存失败")
                        return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }, completionHandler: { ok, error in
                        DispatchQueue.main.async {
                            if ok {
                                AevonLog.info("[录屏] 已存相册（\(total) 帧，失败 \(missed) 帧）"
                                    + "（AevonReplayRecV268）")
                                AevonQuickToast.show("录屏已存相册")
                            } else {
                                AevonLog.warn("[录屏] 存相册失败：\(error?.localizedDescription ?? "未知")"
                                    + "（AevonReplayRecV268）")
                                AevonQuickToast.show("录屏已生成（相册保存失败）")
                            }
                        }
                    })
                }
            }
        }
        appendQueue = nil
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
