import Foundation
import UIKit

/// 浮窗管理：开窗 / 关窗 / 已开窗集合 / 图层更新。
enum AevonWindowManager {
    private static var windows: [String: AevonWindowView] = [:]
    /// 开窗顺序（后开的在后面，也就是更靠上层）。面板里的「已开窗口」按这个顺序展示。
    private static var order: [String] = []

    static func isWindowed(_ bundleID: String) -> Bool {
        return windows[bundleID] != nil
    }

    /// 当前已开窗的 App（按开窗顺序）。
    static var openBundleIDs: [String] {
        return order.filter { windows[$0] != nil }
    }

    static func title(for bundleID: String) -> String {
        return AevonAppInfo.displayName(bundleID: bundleID) ?? bundleID
    }

    /// 把已开窗口提到最前。
    static func bringToFront(bundleID: String) {
        guard let windowView = windows[bundleID] else { return }
        windowView.bringToFront()
        if let index = order.firstIndex(of: bundleID) {
            order.remove(at: index)
            order.append(bundleID)
        }
    }

    /// 为指定 App 开窗（带场景就绪等待与全路径守卫，任何失败都静默放弃）。
    static func open(bundleID: String,
                     sceneID: String?,
                     slot: AevonSnapSlot = .free,
                     completion: ((Bool) -> Void)? = nil) {
        guard AevonPrefs.bool("Enabled", default: false) else {
            AevonLog.warn("[窗口] 插件未启用，忽略开窗请求")
            completion?(false)
            return
        }
        guard !isWindowed(bundleID) else {
            AevonLog.info("[窗口] \(bundleID) 已处于窗口化状态")
            completion?(true)
            return
        }

        // V0.0.36（AevonFloatInEntryV36）：浮窗外壳直接挂进唯一入口容器的浮窗层。
        // 旧路：独立宿主窗口 level 9,999,990 —— App 前台时画面在
        // SBDeviceApplicationSceneViewController.view（不是窗口），层级压不过，
        // 浮窗在全屏 App 里直接消失。入口容器会搬进 App 画面容器，
        // 浮窗作为浮窗层的子视图自然跟着走，App 前台也可见。
        // 宿主窗口保留为兜底（容器尚不存在时）。
        let host: UIView
        if let floatHost = AevonEntryHost.floatHost {
            host = floatHost
        } else {
            AevonHostWindow.ensureInstalled()
            guard let fallback = AevonHostWindow.hostView else {
                AevonLog.warn("[窗口] 入口容器与宿主窗口都不可用，放弃开窗")
                completion?(false)
                return
            }
            host = fallback
        }
        // 登记前台保活，唤醒场景
        AevonForegroundManager.shared.add(bundleID: bundleID, sceneID: sceneID)
        AevonSceneHelper.wakeUp(bundleID)

        // 等待场景就绪后再承载
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var scene = AevonSceneHelper.scene(for: bundleID)
            if scene == nil, let sid = sceneID {
                scene = AevonSceneHelper.scene(for: sid)
            }
            guard let scene = scene else {
                AevonLog.warn("[窗口] 未找到 \(bundleID) 的场景，放弃开窗")
                AevonForegroundManager.shared.remove(bundleID: bundleID, sceneID: sceneID)
                completion?(false)
                return
            }

            AevonSceneHelper.setForeground(scene, true)

            // 关键：`launchApplicationWithIdentifier:suspended:` 拉起的进程是挂起态，
            // 挂起的进程不会渲染 —— 必须显式恢复执行，否则 presenter 永远拿不到首帧。
            if let pid = AevonAppInfo.pid(bundleID: bundleID) {
                AevonAssertionShim.resumePID(Int32(pid))
                AevonLog.info("[窗口] 已恢复 \(bundleID) 进程执行（pid=\(pid)）")
            }

            let sceneIdentifier = (AevonRuntime.send(scene, Selector(("identifier"))) as? String) ?? sceneID ?? ""
            guard let sceneHost = AevonSceneHost(scene: scene, sceneID: sceneIdentifier, bundleID: bundleID) else {
                AevonLog.warn("[窗口] 无法创建场景承载容器，放弃开窗")
                AevonForegroundManager.shared.remove(bundleID: bundleID, sceneID: sceneID)
                completion?(false)
                return
            }

            let title = AevonWindowManager.title(for: bundleID)
            let windowView = AevonWindowView(sceneHost: sceneHost, bundleID: bundleID, title: title, slot: slot)
            host.addSubview(windowView)
            host.bringSubviewToFront(windowView)
            // V0.0.48（AevonFloatAnimV48）：入场动画 —— 从下方 22pt 处浮上来 + 淡入。
            // 只动位置和透明度、不动尺寸，所以不会触发内容缩放，第一帧不会闪黑。
            windowView.playEntryAnimation()
            windows[bundleID] = windowView
            if let index = order.firstIndex(of: bundleID) { order.remove(at: index) }
            order.append(bundleID)
            // V0.0.51（AevonSingleMainV51）：新窗是"唯一主窗"，旧的主窗自动吸附成停靠小窗。
            // 圆盘选图标开新窗走的正是这条路径，于是天然满足用户第 2 条要求。
            AevonEntryHost.demoteMainWindows(except: windowView)
            // V0.0.56：新窗成为主窗 → 立刻把它的矩形同步给 Guard
            AevonEntryHost.syncFloatRectToGuard()
            // 有新窗 → 需要压住系统空闲锁屏（看视频时不能黑屏）
            AevonIdleGuard.shared.refresh()

            // presenter 激活后画面是异步出来的，由承载器自己探测首帧
            sceneHost.startSyncing()
            AevonSceneHelper.startKeepAlive(bundleID)
            if AevonPrefs.bool("KeepAlive", default: false),
               let pid = AevonAppInfo.pid(bundleID: bundleID) {
                AevonAssertionShim.acquireKeepAlive(forPID: Int32(pid))
            }
            AevonLog.info("[窗口] \(bundleID) 窗口化成功")
            completion?(true)
        }
    }

    /// 悬浮球入口：必要时先把目标 App 的场景拉起来，再开窗。
    ///
    /// `launchApplicationWithIdentifier:suspended:` 只在 SpringBoard 里存在，
    /// 拉起的是「挂起态」，不会整屏盖住桌面；随后由 AevonSceneHelper 把场景推前台
    /// 并挂到我们的浮窗上。全程任何一步失败都只记日志，不做强制解包。
    static func launchAndOpen(bundleID: String,
                              slot: AevonSnapSlot = .free,
                              completion: ((Bool) -> Void)? = nil) {
        guard AevonPrefs.bool("Enabled", default: false) else {
            AevonLog.warn("[窗口] 插件未启用，忽略开窗请求")
            completion?(false)
            return
        }
        if isWindowed(bundleID) {
            AevonLog.info("[窗口] \(bundleID) 已在窗口中，改为吸附并置顶")
            windows[bundleID]?.snap(to: slot)
            bringToFront(bundleID: bundleID)
            completion?(true)
            return
        }

        if AevonSceneHelper.scene(for: bundleID) != nil {
            AevonLog.info("[窗口] \(bundleID) 已有场景，直接开窗")
            open(bundleID: bundleID, sceneID: nil, slot: slot, completion: completion)
            return
        }

        let application = UIApplication.shared
        let launchSelector = Selector(("launchApplicationWithIdentifier:suspended:"))
        guard application.responds(to: launchSelector) else {
            AevonLog.warn("[窗口] 当前进程不支持 launchApplicationWithIdentifier:suspended:，无法拉起 \(bundleID)")
            completion?(false)
            return
        }
        AevonLog.info("[窗口] 正在拉起 \(bundleID)")
        AevonRuntime.sendVoid(application, launchSelector, bundleID as NSString, true)

        var attempts = 0
        let timer = Timer(timeInterval: 0.4, repeats: true) { timer in
            attempts += 1
            if attempts > 25 {
                AevonLog.warn("[窗口] 等待 \(bundleID) 场景超时（10 秒）")
                timer.invalidate()
                completion?(false)
                return
            }
            if AevonSceneHelper.scene(for: bundleID) != nil {
                timer.invalidate()
                AevonLog.info("[窗口] \(bundleID) 场景已就绪（等待 \(attempts) 次）")
                open(bundleID: bundleID, sceneID: nil, slot: slot, completion: completion)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 左右分屏：先开左边，成功后再开右边并吸附。
    ///
    /// 两个 App 依次拉起而不是并行，是因为 `launchApplicationWithIdentifier:suspended:`
    /// 在同一个 tick 里连发两次时，第二个的进程恢复经常赶不上场景创建，容易只有一个窗。
    static func openSplit(left: String, right: String) {
        guard left != right else {
            AevonLog.warn("[分屏] 两侧选了同一个 App，忽略")
            return
        }
        AevonLog.info("[分屏] 左右分屏：\(left) ｜ \(right)（AevonSplitFlow）")
        launchAndOpen(bundleID: left, slot: .left) { ok in
            guard ok else {
                AevonLog.warn("[分屏] 左侧 \(left) 开窗失败，放弃本次分屏")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                launchAndOpen(bundleID: right, slot: .right) { rightOK in
                    if rightOK {
                        AevonLog.info("[分屏] 左右分屏已完成")
                    } else {
                        AevonLog.warn("[分屏] 右侧 \(right) 开窗失败，左侧保留")
                    }
                }
            }
        }
    }

    /// 关窗并清理全部相关状态。
    static func close(bundleID: String) {
        guard let windowView = windows.removeValue(forKey: bundleID) else { return }
        if let index = order.firstIndex(of: bundleID) { order.remove(at: index) }
        AevonSceneHelper.stopKeepAlive(bundleID)
        AevonForegroundManager.shared.remove(bundleID: bundleID, sceneID: nil)
        if let pid = AevonAppInfo.pid(bundleID: bundleID) {
            AevonAssertionShim.releaseKeepAlive(forPID: Int32(pid))
        }
        // V0.0.48（AevonFloatAnimV48）：先播退场动画，动画结束再休眠场景 + 拆视图。
        // 顺序不能反 —— 先把场景睡掉，动画中途画面就变黑了。
        windowView.playDismissAnimation {
            AevonSceneHelper.sleep(bundleID)
            windowView.teardown()
            // V0.0.56：视图已拆 → 必须重算主窗矩形重新下发。
            // 漏掉这一步，Guard 会一直以为那块屏幕还盖着浮窗，把 App 的触摸白白吞掉
            // （「关掉浮窗后某一块区域点不动」就是这么来的）。
            AevonEntryHost.syncFloatRectToGuard()
            // 真正拆完视图后再判定（退场动画期间窗还在，计数不能提前减）
            AevonIdleGuard.shared.refresh()
        }
        AevonLog.info("[窗口] \(bundleID) 已关闭（缩放缓出退场）（AevonFloatAnimV48）")
    }

    static func closeAll() {
        for bundleID in Array(windows.keys) {
            close(bundleID: bundleID)
        }
    }

    /// App 的图层列表更新时通知浮窗重排。
    ///
    /// 这个回调来自 `FBSceneLayerManager _setLayers`，随 App 自己的渲染帧率触发，
    /// 一秒可能几十次。以前每次都 `setNeedsLayout`，等于把 App 的每一帧都变成本进程
    /// 的一次完整布局 —— 缩放时尤其明显。这里做 0.3 秒节流，布局本身也有缓存短路。
    private static var lastLayerRefresh: TimeInterval = 0

    static func notifyLayersUpdated() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLayerRefresh >= 0.3 else { return }
        lastLayerRefresh = now
        for (_, windowView) in windows {
            windowView.setNeedsLayout()
        }
    }
}
