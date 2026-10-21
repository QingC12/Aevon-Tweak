import Foundation
import UIKit

/// 单个 App 场景的承载器（V0.0.9 重写）。
///
/// 与 V0.0.8 的差别（V0.0.8 的现象：浮窗外壳能拖能缩，但里面什么也没有）：
/// 1. 图层的到达是**异步**的。创建 `_UISceneLayerHostContainerView` 的那一刻，
///    `layerManager.layers` 往往是空的；V0.0.8 只同步了一次，所以一个宿主视图都没建出来。
///    现在改为每 0.5 秒轮询，图层一出现就建宿主视图。
/// 2. `layerManager.layers` 不保证是 NSArray（也可能是 NSSet）。V0.0.8 用
///    `as? [AnyObject]` 强转，遇到 NSSet 会静默得到空数组。现在两种都能读。
/// 3. 外部图层（`_UIExternalSceneLayerHostView`，键盘/浮层一类）必须放进独立的高层级窗口，
///    直接塞进浮窗里不显示。
/// 4. 容器释放前必须调用 `invalidate`，否则 UIKit 抛
///    `NSInternalInconsistencyException: Must be invalidated before deallocating`，
///    在 SpringBoard 里就是注销重启（用户回传的崩溃日志正是这一条）。
final class AevonSceneHost {
    let scene: AnyObject
    let sceneID: String
    let bundleID: String
    let container: UIView

    /// 首次真正拿到宿主视图时回调一次（用于隐藏「等待画面」提示）。
    var onFirstContent: (() -> Void)?

    private(set) var createdHostCount = 0
    private(set) var layerCount = 0

    private var syncTimer: Timer?
    private var tickCount = 0
    private var emptyTicks = 0
    private var lastSignature = ""
    private var didNotify = false
    private var invalidated = false
    private var presenterFallbackTried = false

    /// presenter 兜底路径必须自己持有，否则 +0 返回的对象会被释放。
    private var presenter: AnyObject?

    private var externalWindow: UIWindow?
    private var externalViews: [UIView] = []

    init?(scene: AnyObject, sceneID: String, bundleID: String) {
        guard let allocated = AevonRuntime.allocate("_UISceneLayerHostContainerView") else {
            AevonLog.warn("[场景] 系统缺少 _UISceneLayerHostContainerView，无法承载画面")
            return nil
        }

        var built: AnyObject?
        if allocated.responds(to: Selector(("initWithScene:debugDescription:"))) {
            built = AevonRuntime.sendInit(allocated,
                                          Selector(("initWithScene:debugDescription:")),
                                          first: scene,
                                          second: "Aevon" as NSString)
        } else if allocated.responds(to: Selector(("initWithScene:"))) {
            built = AevonRuntime.sendInit(allocated, Selector(("initWithScene:")), argument: scene)
        }

        guard let view = built as? UIView else {
            AevonLog.warn("[场景] _UISceneLayerHostContainerView 初始化失败")
            return nil
        }

        self.scene = scene
        self.sceneID = sceneID
        self.bundleID = bundleID
        self.container = view

        // 容器自身按整屏尺寸布局；浮窗只负责整体缩放，不改容器尺寸。
        view.frame = UIScreen.main.bounds
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        AevonLog.info("[场景] 承载容器已创建（\(AevonRuntime.className(view) ?? "?")，场景 \(sceneID)）")
    }

    deinit {
        // 兜底：上层即使忘记调用 invalidate，也不能让容器裸释放
        if !invalidated {
            stopEverything()
        }
    }

    // MARK: - 同步

    func startSyncing() {
        guard syncTimer == nil, !invalidated else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
        tick()
    }

    private func tick() {
        guard !invalidated else { return }
        tickCount += 1

        let layers = layersArray()
        layerCount = layers.count

        if layers.isEmpty {
            emptyTicks += 1
            if emptyTicks == 6 {
                AevonLog.warn("[图层] 约 3 秒没收到任何图层：App 进程可能没有渲染（pid=\(AevonAppInfo.pid(bundleID: bundleID) ?? -1)）")
                logDiagnostics()
                tryPresenterFallback()
            }
            return
        }

        emptyTicks = 0
        rebuildIfNeeded(layers)
    }

    /// 读取场景当前图层。数组 / 集合 / 快速枚举三种形态都兼容。
    private func layersArray() -> [Any] {
        guard scene.responds(to: Selector(("layerManager"))),
              let manager = AevonRuntime.send(scene, Selector(("layerManager"))) else { return [] }
        guard manager.responds(to: Selector(("layers"))),
              let raw = AevonRuntime.send(manager, Selector(("layers"))) else { return [] }
        if let array = raw as? [Any] { return array }
        if let set = raw as? NSSet { return set.allObjects }
        if let array = raw as? NSArray { return array.map { $0 } }
        return []
    }

    private func rebuildIfNeeded(_ layers: [Any]) {
        var signatureParts: [String] = []
        for layer in layers {
            let object = layer as AnyObject
            let name = AevonRuntime.className(object) ?? "?"
            let level = AevonRuntime.int(object, Selector(("level"))) ?? -1
            signatureParts.append("\(name)#\(level)")
        }
        let signature = signatureParts.joined(separator: ",")
        if signature == lastSignature && (container.subviews.count > 0 || !externalViews.isEmpty) { return }
        lastSignature = signature

        for sub in container.subviews { sub.removeFromSuperview() }
        for view in externalViews { view.removeFromSuperview() }
        externalViews.removeAll()

        guard container.responds(to: Selector(("_createHostViewForLayer:"))) else {
            AevonLog.warn("[图层] 承载容器不支持 _createHostViewForLayer:")
            return
        }

        var created = 0
        var hostClasses: [String] = []
        for layer in layers {
            guard let host = AevonRuntime.send(container,
                                               Selector(("_createHostViewForLayer:")),
                                               argument: layer) as? UIView else { continue }
            created += 1
            let className = AevonRuntime.className(host) ?? "?"
            if !hostClasses.contains(className) { hostClasses.append(className) }

            if className.contains("External") {
                // 外部图层（键盘等）单独放高层级窗口，否则不显示
                adoptExternal(host)
            } else {
                host.frame = container.bounds
                host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(host)
            }
        }

        createdHostCount = created
        AevonLog.info("[图层] 第 \(tickCount) 次同步：图层 \(layers.count) 个 → 宿主视图 \(created) 个（\(hostClasses.joined(separator: ","))）")

        if created > 0 && !didNotify {
            didNotify = true
            onFirstContent?()
        }
    }

    private func adoptExternal(_ host: UIView) {
        if externalWindow == nil {
            externalWindow = AevonHostWindow.makeOverlayWindow()
            if externalWindow == nil { AevonLog.warn("[图层] 无法创建外部图层窗口") }
        }
        guard let window = externalWindow else { return }
        host.frame = UIScreen.main.bounds
        window.addSubview(host)
        externalViews.append(host)
    }

    // MARK: - 诊断

    private func logDiagnostics() {
        let settings = AevonRuntime.send(scene, Selector(("settings")))
        let foreground = settings.flatMap { boolValue($0, ["isForeground", "foreground"]) }
        let active = boolValue(scene, ["isActive"])
        let running = AevonAppInfo.isRunning(bundleID: bundleID)
        AevonLog.warn("[诊断] scene=\(sceneID) 类=\(AevonRuntime.className(scene) ?? "?") foreground=\(foreground.map { String($0) } ?? "?") isActive=\(active.map { String($0) } ?? "?") 进程运行=\(running)")
    }

    private func boolValue(_ object: AnyObject, _ names: [String]) -> Bool? {
        for name in names where object.responds(to: Selector(name)) {
            if let value = AevonRuntime.bool(object, key: name) { return value }
        }
        return nil
    }

    // MARK: - presenter 兜底（容器拿不到图层时尝试）

    private func tryPresenterFallback() {
        guard !presenterFallbackTried, !invalidated else { return }
        presenterFallbackTried = true

        guard let allocated = AevonRuntime.allocate("UIScenePresentationManager") else {
            AevonLog.warn("[兜底] 系统缺少 UIScenePresentationManager")
            return
        }
        var manager: AnyObject?
        if allocated.responds(to: Selector(("_initWithScene:"))) {
            manager = AevonRuntime.sendInit(allocated, Selector(("_initWithScene:")), argument: scene)
        } else if allocated.responds(to: Selector(("initWithScene:"))) {
            manager = AevonRuntime.sendInit(allocated, Selector(("initWithScene:")), argument: scene)
        }
        guard let presentationManager = manager,
              presentationManager.responds(to: Selector(("_createPresenterWithIdentifier:"))) else {
            AevonLog.warn("[兜底] UIScenePresentationManager 初始化失败")
            return
        }
        guard let createdPresenter = AevonRuntime.send(presentationManager,
                                                       Selector(("_createPresenterWithIdentifier:")),
                                                       argument: "AevonPresenter" as NSString) else {
            AevonLog.warn("[兜底] 无法创建 scene presenter")
            return
        }
        presenter = createdPresenter
        AevonRuntime.sendVoid(createdPresenter, Selector(("activate")))

        guard let presentationView = AevonRuntime.send(createdPresenter, Selector(("presentationView"))) as? UIView else {
            AevonLog.warn("[兜底] presenter 没有 presentationView")
            return
        }
        for sub in container.subviews { sub.removeFromSuperview() }
        presentationView.frame = container.bounds
        presentationView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(presentationView)

        createdHostCount = max(createdHostCount, 1)
        AevonLog.info("[兜底] 已改用 UIScenePresentationManager 呈现场景")
        if !didNotify {
            didNotify = true
            onFirstContent?()
        }
    }

    // MARK: - 释放

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        stopEverything()
        AevonLog.info("[场景] 承载容器已 invalidate 并释放（\(bundleID)）")
    }

    private func stopEverything() {
        syncTimer?.invalidate()
        syncTimer = nil

        for view in externalViews { view.removeFromSuperview() }
        externalViews.removeAll()
        externalWindow?.isHidden = true
        externalWindow = nil

        if let createdPresenter = presenter {
            if createdPresenter.responds(to: Selector(("invalidate"))) {
                AevonRuntime.sendVoid(createdPresenter, Selector(("invalidate")))
            }
            presenter = nil
        }

        // 关键：先 invalidate 再释放，否则 dealloc 会抛异常（SpringBoard 注销）
        if container.responds(to: Selector(("invalidate"))) {
            AevonRuntime.sendVoid(container, Selector(("invalidate")))
        }
        for sub in container.subviews { sub.removeFromSuperview() }
        container.removeFromSuperview()
    }
}
