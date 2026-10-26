import Foundation
import UIKit

/// Aevon 版本号（与 control 保持一致；CI 会按 tag 覆盖本行）。
let AevonVersion = "0.0.40"

/// dyld 构造函数入口（由 AevonAssertionShim.m 以 C 符号调用）。
/// 约定：本函数绝不抛出、绝不强制解包失败；任何异常路径只记录日志。
@_cdecl("AevonInitialize")
func aevonInitialize() {
    initializeAevon()
}

private func initializeAevon() {
    AevonLog.info("Aevon \(AevonVersion) 开始加载 (iOS \(UIDevice.current.systemVersion), 进程 \(ProcessInfo.processInfo.processName))")

    // 1) 崩溃捕获最先安装：后续任何一行崩了都能留下原因
    AevonCrashCatcher.install()
    AevonCrashCatcher.harvestPreviousCrash()

    // 2) 开机崩溃守卫（上次没跑稳 → 自动禁用）
    let safeToContinue = AevonCrashGuard.install()
    guard safeToContinue else { return }

    // 3) 总开关（默认关闭）
    guard AevonPrefs.bool("Enabled", default: false) else {
        AevonLog.info("Aevon 未启用（默认关闭）。请在 设置 → Aevon 打开「启用插件」后注销生效。")
        return
    }

    /*
     * V0.0.7 的关键改动（针对 V0.0.6「长按桌面图标 → 自动注销」）：
     *
     * V0.0.6 用 hook 往 SBIconView 的长按菜单里塞「Open in Window」，
     * 日志显示 applicationShortcutItems 首次被调用后约 220ms SpringBoard 收到
     * SIGBUS 退出 —— 伪造的 SBSApplicationShortcutItem 触发了 SpringBoard
     * 内部对快捷菜单项的约束。
     *
     * 现在入口换成「悬浮球」：
     *   - 启动阶段零 hook，只注册两个 UIApplication 生命周期通知；
     *   - 桌面稳定后在自己创建的穿透窗口里放一个圆球，点它选 App 即可开窗；
     *   - 系统类（SBIconView / SBIconModel 等）完全不碰，长按图标恢复原样。
     */
    AevonBootstrap.start()

    /*
     * V0.2.0（AevonAppSideBridgeV200）：App 侧探针日志桥。
     * 路 B（把吞摸点搬进 App 进程）的第一版，只读、不改任何触摸行为。
     * App 进程把日志写进自己的偏好域，这里每 2 秒读一次转写进 Aevon.log；
     * App 侧总开关关着时这里连偏好都不读（零开销）。
     */
    AevonAppSideBridge.start()

    // 4) 实验性 hook 一律延迟 10 秒，且必须用户显式打开对应开关
    let delay: TimeInterval = 10
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        guard AevonPrefs.bool("Enabled", default: false) else {
            AevonLog.info("[启动] 延迟期间插件被关闭，不安装实验 hook")
            return
        }
        installExperimentalHooks()
        AevonLog.info("Aevon \(AevonVersion) 加载完成（边缘圆盘入口已就绪）")
    }
}

private func installExperimentalHooks() {
    // 实验入口：多任务卡片长按开窗（默认关）
    if AevonPrefs.bool("SwitcherLongPress", default: false) {
        AevonSwizzle.install(targetClassName: "SBAppSwitcherPageView",
                             original: Selector(("initWithFrame:")),
                             replacementClass: AevonSwitcherCardHooks.self,
                             replacement: #selector(AevonSwitcherCardHooks.sk_sbaspv_initWithFrame(_:)))
        AevonLog.info("[启动] 已安装「多任务卡片长按」hook（实验）")
    }

    /*
     * V0.1.5（AevonNoFBSWriteV105）：**FBScene updateSettings 的写入 hook 已整体删除**。
     * 归档(14) 的崩溃栈把我方位置钉死在「FrontBoard 调进来 → 我们 KVC 写 foreground →
     * FBS 断言」这一链上，四个版本反复栽在这里。既然炸点就是我们自己那一次写入，
     * 最稳的修法就是**不写**：窗口化 App 的存活交给 ①有限次前台补偿 + ②RBSAssertion
     * 进程保活，两条都不碰 FrontBoard 的场景状态机。
     *
     * 下面保留的都是只读 / 只影响渲染层的安全 hook。
     */
    // ④ 场景宿主激活状态组件：不让系统把窗口化场景的 foreground 拉回 false
    //    （iOS 17.3.1 上该类已不存在，安装会被跳过并记一条日志，保留只为兼容旧系统）
    AevonSwizzle.install(targetClassName: "_UISceneHostingActivationStateHostComponent",
                         original: Selector(("setForeground:")),
                         replacementClass: AevonSceneHostingActivationHooks.self,
                         replacement: #selector(AevonSceneHostingActivationHooks.sk_shac_setForeground(_:)))
    // ⑤ 图层更新 → 浮窗布局刷新
    AevonSwizzle.install(targetClassName: "FBSceneLayerManager",
                         original: Selector(("_setLayers:")),
                         replacementClass: AevonSceneLayerManagerHooks.self,
                         replacement: #selector(AevonSceneLayerManagerHooks.sk_fbslm_setLayers(_:)))
    AevonLog.info("[启动] 已安装渲染层 hook（未写任何场景设置，AevonNoFBSWriteV105）")

    /*
     * ⑥ V0.1.4（AevonIconLaunchV104）：桌面图标启动 → 先把浮窗交还系统。
     *    「浮窗开着设置 → 回桌面点设置图标 → 自动注销」在 0.1.1/0.1.2/0.1.3 三版都没治好，
     *    因为前面几版都在改「拦截停用原因 / 包异常保护」，而真正撞车的是**同一个场景
     *    正被 FrontBoard 全屏拉起时我们还握着它**。这一版改成在系统接手之前先松手。
     */
    var iconLaunchHooked = AevonSwizzle.install(
        targetClassName: "SBIconController",
        original: Selector(("iconManager:launchIconForIconView:withActions:")),
        replacementClass: AevonIconLaunchHooks.self,
        replacement: #selector(AevonIconLaunchHooks.sk_sbic_launchIcon(_:forIconView:withActions:)))
    if !iconLaunchHooked {
        // 兜底：不同 iOS 版本这条启动委托可能落在别的类上（只试确定存在的几个，
        // 全部失败就放弃，绝不对未知类做泛洪 hook）
        for className in ["SBHomeScreenController", "SBIconView"] {
            if AevonSwizzle.install(
                targetClassName: className,
                original: Selector(("iconManager:launchIconForIconView:withActions:")),
                replacementClass: AevonIconLaunchHooks.self,
                replacement: #selector(AevonIconLaunchHooks.sk_sbic_launchIcon(_:forIconView:withActions:))) {
                iconLaunchHooked = true
                break
            }
        }
    }
    if iconLaunchHooked {
        AevonLog.info("[启动] 已安装桌面图标启动 hook（先释放浮窗，再让系统全屏拉起）（AevonIconLaunchV104）")
    } else {
        AevonLog.warn("[启动] 桌面图标启动 hook 未安装（找不到启动委托）；本版已不再写场景设置，注销风险随之消失（AevonIconLaunchV104 AevonNoFBSWriteV105）")
    }

    /*
     * ⑦ V0.1.4 → V0.1.5（AevonSystemGestureV105）：全屏 App 内的右缘改由
     *    **SpringBoard 系统手势管线**接管（`SBMainDisplaySystemGestureManager
     *    -addGestureRecognizer:toDisplayWithIdentity:`，ScreenCore 同款）。
     *    0.1.4 找 `_UISystemGestureWindow` 的路已被归档(14) 的窗口清单证伪。
     */
    AevonSystemGestureV105.shared.install()

    /*
     * ⑦-2 V0.2.13（AevonSysEdgeV213）：右缘呼出**再试一次系统手势管线**。
     *
     * 与上面 0.1.5~0.1.13 那条的本质区别（那次失败的前提本轮全部变了）：
     *   · 登记接口换成本轮才发现的 `-addGestureRecognizer:withType:` ——
     *     真机探针（Aevon(75)）只测过 toDisplayWithIdentity:，这个带 type 的重载
     *     **从未验证过**，而 Triggr（iOS 15–18）用的正是它；
     *   · 识别器换成 `UIScreenEdgePanGestureRecognizer`（私有 init，type=2）——
     *     它是系统自己的边缘识别器，从边缘落手就进入判定，失败时由 UIKit 归还触摸，
     *     不需要我们再「补投」任何一帧（0.1.19 判定补投不可做的那条死路）；
     *   · 触摸开关回到 UIKit 默认（delaysTouchesBegan=NO / cancelsTouchesInView=YES），
     *     也就是 Apple 给左缘返回手势用的那套。
     *
     * 任何一步失败都只记日志、什么都不做 —— 右缘继续由全局通道 + 热区负责，
     * 行为与 0.2.12 完全一致。可用设置里的「右缘系统手势通道」一键关掉。
     */
    AevonSysEdgeV213.shared.install()

    /*
     * ⑧ V0.1.7（AevonProbeV107）：运行时探针。六组一次装齐，8 秒后开始、组间隔 0.8 秒：
     *    P1 系统手势管线 / P2 识别器宿主 / P3 桌面图标启动链 /
     *    P4 事件路由延迟层 / P5 场景与浮窗 / P6 配置快照。
     *
     * V0.1.6 的探针自己把 SpringBoard 打死了（归档(13)：崩溃栈落在
     * swift_dynamicCast → _CF_forwarding_prep_0，位置就在「遍历全进程类表」那一步）。
     * 这一版把类表扫描整块搬进 ObjC，并且每组都从 ObjC 的 @try 里过 ——
     * 探针再出问题最多是「这一组没结果」，绝不再是「手机自动注销」。
     */
    AevonProbeV107.runAll()
}
