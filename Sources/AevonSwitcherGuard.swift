import Foundation
import UIKit

/// 后台卡片视图（App Switcher）里隐藏浮窗（V0.0.54，AevonSwitcherHideV54）。
///
/// 用户 Aevon(47) 第 3 条：「手机解锁时，上滑到后台卡片时，会出现悬浮窗和停靠小窗」。
///
/// 根因：浮窗容器为了压过全屏 App，被塞进了 `SBDeviceApplicationSceneViewController.view`
/// （见 `AevonSceneHook.m`）。上滑进切换器时，系统并不会立刻让这个控制器
/// `viewDidDisappear` —— 它只是被 `SBAppSwitcherPageView` 带着做 transform 缩小，
/// 于是容器跟着缩成一小块出现在卡片上（连停靠小窗一起）。
///
/// 修法：判断「容器所在的 App 画面是否仍然真的铺满整屏」，
/// 一旦被缩小（Switcher / 后台 / 分屏）就把容器整块隐藏，恢复全屏再显示回来。
///
/// 两条通道：
///   ① 系统通知 `SBSwitcherWillBeginPresentationNotification` —— 能**提前**藏起来，
///      赶在系统给 App 拍快照之前，所以卡片上不会留下浮窗残影；
///   ② 0.15s 轮询兜底 —— 通知名变动 / 某些入口不广播时，最多 0.15 秒也能收掉。
final class AevonSwitcherGuard {
    static let shared = AevonSwitcherGuard()

    private var timer: Timer?
    private var lastHidden = false
    private var lastLogAt: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard timer == nil else { return }

        // ① 系统通知（名字在 SBSwitcherController 里定义；取不到就只靠轮询）
        let names = ["SBSwitcherWillBeginPresentationNotification",
                     "SBSwitcherWillEndPresentationNotification"]
        for raw in names {
            let name = Notification.Name(raw)
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { note in
                let beginning = note.name.rawValue.contains("WillBegin")
                AevonSwitcherGuard.shared.apply(hidden: beginning, reason: "切换器通知")
            }
            observers.append(token)
        }

        // ② 轮询兜底
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // 容器挂在 App 画面里、而那块画面已经不再铺满整屏 → 说明被缩成卡片了
        guard AevonEntryHost.mountedInAppScene else {
            // 回到桌面 / 入口窗口：浮窗该照常显示
            if lastHidden { apply(hidden: false, reason: "容器已离开 App 画面") }
            return
        }
        let fullscreen = AevonEntryHost.appSceneCoversScreen()
        apply(hidden: !fullscreen, reason: fullscreen ? "App 画面恢复全屏" : "App 画面被缩小（后台卡片）")
    }

    /// 应用隐藏 / 显示（幂等，只在真正翻转时写日志）。
    private func apply(hidden: Bool, reason: String) {
        guard hidden != lastHidden else { return }
        lastHidden = hidden
        guard let box = AevonEntryHost.activeRoot else { return }
        box.isHidden = hidden
        if !hidden {
            // 藏起来这段时间布局可能变了：恢复时按当前 bounds 重新落位一次
            AevonEntryHost.refreshLayout(reason: "从后台卡片恢复显示")
        }
        let now = CACurrentMediaTime()
        if now - lastLogAt > 0.5 {
            lastLogAt = now
            if hidden {
                AevonLog.info("[入口] 已隐藏浮窗（\(reason)）—— 后台卡片与缩略图里不再出现"
                    + "悬浮窗和停靠小窗（AevonSwitcherHideV54）")
            } else {
                AevonLog.info("[入口] 已恢复显示浮窗（\(reason)）（AevonSwitcherHideV54）")
            }
        }
    }
}
