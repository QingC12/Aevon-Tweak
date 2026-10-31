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

/// V0.2.50（AevonLockBlockV250）：给 ObjC 垫片用的日志桥。
///
/// 锁屏拦截的钩子必须在 ObjC 里（`method_setImplementation` + @try），
/// 但它拦下的每一条都要进同一份日志，否则用户反馈「还是锁屏」时我们两头对不上。
/// Swift 的 `AevonLog` 自己有串行队列与文件句柄，这里只做一次字符串转换。
@_cdecl("AevonLogFromC")
func aevonLogFromC(_ text: UnsafePointer<CChar>) {
    AevonLog.info(String(cString: text))
}

private func initializeAevon() {
    AevonLog.info("Aevon \(AevonVersion) 开始加载 (iOS \(UIDevice.current.systemVersion), 进程 \(ProcessInfo.processInfo.processName))")

    // 1) 崩溃捕获最先安装：后续任何一行崩了都能留下原因
    AevonCrashCatcher.install()
    AevonCrashCatcher.harvestPreviousCrash()

    // 2) 开机崩溃守卫（上次没跑稳 → 自动禁用）
    let safeToContinue = AevonCrashGuard.install()
    guard safeToContinue else { return }

    // 3) 总开关（V0.2.17 起**默认开**：装上就生效，用户要停手时才去关）
    guard AevonPrefs.bool("Enabled", default: true) else {
        AevonLog.info("Aevon 未启用（偏好域 Enabled=否；崩溃保护或用户手动关闭）。请在 设置 → Aevon 打开「启用插件」后注销生效。")
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

    // 3.5) V0.2.59（AevonDockStageV259）：停靠集合广播启动清场（notify state 不随 SB
    //      重启清零，上次注销前的停靠 App 会被活着残留的进程误认为「还在停靠」）。
    AevonWindowManager.clearDockStagesOnBoot()

    // 3.6) V0.2.84（AevonStaleRectGateV284，Aevon(57) 死区实锤）：浮窗矩形与存活心跳
    //      的启动清场。notify state 活在 notifyd 里跨 respring 不消失、floatframe.txt
    //      也在磁盘上 —— 上一轮残留的矩形会让全屏 App 出现「点不动」的死区
    //      （Aevon(57) 设置里 44 次点击被吞、0 次合法吞）。这里先清零，再开心跳。
    AevonWindowManager.resetStaleFloatGateOnBoot()

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
        guard AevonPrefs.bool("Enabled", default: true) else {
            AevonLog.info("[启动] 延迟期间插件被关闭，不安装实验 hook")
            return
        }
        installExperimentalHooks()
        AevonLog.info("Aevon \(AevonVersion) 加载完成（边缘圆盘入口已就绪）")
    }
}

private func installExperimentalHooks() {
    /*
     * 「多任务卡片长按开窗」入口已删除（V0.2.17 / AevonPrefsSlimV217）。
     *
     * 它 hook `SBAppSwitcherPageView -initWithFrame:` 给每张卡片挂 0.5 秒长按，
     * 然后要求该 App **已经在运行** 才能窗口化 —— 从 0.1.x 起就没在任何一版真机日志里
     * 成功打开过一次（日志里只有 `[手势] …未在运行，跳过` 这一类）。设置里留着一个
     * 永远不生效的「（实验）」开关，比没有更糟：用户打开它、试几次、什么也没发生。
     * 这里停掉的是安装入口，AevonSwitcherCardHooks / AevonGestureHandler 的实现留在
     * 仓库里只作参考，运行期不再有任何代码路径。
     */

    /*
     * V0.1.5（AevonNoFBSWriteV105）：**FBScene updateSettings 的写入 hook 已整体删除**。
     * 归档(14) 的崩溃栈把我方位置钉死在「FrontBoard 调进来 → 我们 KVC 写 foreground →
     * FBS 断言」这一链上，四个版本反复栽在这里。既然炸点就是我们自己那一次写入，
     * 最稳的修法就是**不写**：窗口化 App 的存活交给 ①有限次前台补偿 + ②RBSAssertion
     * 进程保活，两条都不碰 FrontBoard 的场景状态机。
     *
     * 下面保留的都是只读 / 只影响渲染层的安全 hook。
     */
    /* V0.3.42（AevonWriteGuardV342）：写通道修正 —— 承载中场景的 `foreground=NO`
     * 会在**落地之前**被改成 `foreground=YES / deactivationReasons=0`。
     *
     * 依据（0.3.41 普查 + Aevon(112) 日志）：三次回桌面掉画的现场全是
     * `fg=0 dr=0 active=1 cs=0`，而 `pm` / 呈现层 / `clientProcess` 一直健康 ——
     * 掉的是「内容」这一档，唯一变化的就是 `settings.foreground` 1→0。
     * 且第三次掉画此前 1.1 秒内**零写入**，证明「我们写得太多」不是原因，
     * 真正的原因是「系统那一笔 NO 落地了，我们事后才追着改」。
     * 修法即 Stheno / TrollOpen 的同款：只改系统本来就要交出去的那份 settings，
     * 不新增任何写入（V0.1.5 归档(14) 的 SIGTRAP 是自发写入，不是这一条）。 */
    AevonWriteGuard.install()

    /* V0.2.78（AevonSceneFgGuardV278，用户 Aevon(50) #2/#3）：
     * 切屏 / 回桌面时浮窗黑屏的老根因（档案 round13）是「系统把 scene 的 foreground
     * 写回 NO → 进程挂起 → layers=0」。开源 MilkyWayReborn（iOS 17-26）的解法是
     * **改写系统本来就要写的那一笔**，而不是自己再发一次 updateSettings（那才是
     * 归档(14) SIGTRAP 炸点）。这里照做：拦 `FBScene -updateSettings:…`，
     * 只对浮窗承载中的场景把 settings 的 foreground 改 YES 后原样放行。 */
    let sceneGuardSel = Selector(("updateSettings:withTransitionContext:completion:"))
    let sceneGuardSafe: Bool = {
        // 铁律：hook 私有方法前先做类型编码自检，签名不符一律不装（fail-closed）。
        guard let cls = NSClassFromString("FBScene"),
              let method = class_getInstanceMethod(cls, sceneGuardSel),
              let encoding = method_getTypeEncoding(method) else { return false }
        let text = String(cString: encoding)
        let args = NSStringFromSelector(sceneGuardSel).filter { $0 == ":" }.count
        return text.hasPrefix("v") && args == 3
    }()
    if !sceneGuardSafe {
        AevonLog.warn("[启动] FBScene updateSettings 签名不符（或方法缺失），场景前台拦截不装"
            + "（fail-closed，AevonSceneFgGuardV278）")
    }
    let sceneGuardHooked = sceneGuardSafe && AevonSwizzle.install(
        targetClassName: "FBScene",
        original: sceneGuardSel,
        replacementClass: AevonSceneSettingsGuardHooks.self,
        replacement: #selector(AevonSceneSettingsGuardHooks.sk_scene_updateSettings(_:withTransitionContext:completion:)))
    if sceneGuardHooked {
        AevonLog.info("[启动] 已安装场景前台拦截（改写系统写入的那一笔，不额外发起 updateSettings）"
            + "（AevonSceneFgGuardV278 AevonNoFBSWriteV105）")
    }

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
     * ⑦（0.2.51 移除，AevonGripOnlyV251）：右缘呼盘手势全部退役 ——
     *    AevonSystemGestureV105 / AevonSysEdgeV213 / 边缘手势条 / App 侧右缘识别器
     *    一并删除（用户 Aevon(26) #2：「移除现在的所有圆盘触发手势代码和开关，
     *    只保留新添加的圆盘把手」）。呼盘唯一入口 = AevonRingGrip 可见把手。
     *    历史标记 AevonSystemGestureV104/V106/V108/V110、AevonSysEdge* 全部
     *    收容在 AevonAssertionShim.m 的 used 常量里。
     */

    /*
     * ⑧ V0.2.81 移除（AevonDeadCodeV281）：V0.1.7 的六组启动探针（AevonProbeV107）与
     *    V0.1.14 的宿主审计五组（AevonProbeP7V114）整体退役。
     *
     *    理由（三条，缺一条都不该删）：
     *      ① 它们的主干「全进程类表扫描」自 0.2.72 起被永久封印
     *         （AevonSealP1V276：SB 进程 objc_copyClassList → 全类 +initialize →
     *         swift_dynamicCast SIGTRAP = 手机自动注销，Aevon(44)/Aevon(38) 两次实锤），
     *         封印后 AevonAllClassNames 恒返回 nil，P1~P5 组退化成了空跑；
     *      ② 剩下还能出结果的定向探测（宿主链 / 识别器宿主 / ivar 摘要）结论已经
     *         全部落进逆向报告与历史日志，不再需要每次启动重采一遍；
     *      ③ Aevon(54) 日志实测：每次启动 [探针P7-3] 40 行、[诊断] 97 行，
     *         占总日志量约 30%，纯噪声。
     *    历史标记 AevonProbeV107 / AevonProbeP7V114 / AevonGestureProbeV2V256 /
     *    AevonProbeSupport / AevonSealP1V276 全部收容在 AevonAssertionShim.m 的
     *    used 常量里（「历史标记只加不改，删日志串前先收容标记」）。
     */
}
