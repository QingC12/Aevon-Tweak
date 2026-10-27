import QuartzCore
import Foundation
import UIKit

/// 浮窗管理（V0.1.5，AevonSingleWindowV105）：**全局只允许一个浮窗**。
///
/// 历史：0.1.0~0.1.4 支持多窗并存（`windows` 字典 + 开窗顺序数组），结果是
/// 「桌面上同时飘着好几个窗」，互相遮挡、拖拽抢手指、几何记忆互相覆盖。
/// 用户明确要求（归档(14)）只保留一个主浮窗：再通过圆盘打开另一个 App 时，
/// **直接切换主窗内的 App**，桌面上永远只有一个窗。
///
/// 单窗之后整套状态简单到只有两个变量（`currentView` + `currentBundleID`），
/// 多窗相关的排序、置顶、批量刷新全部消失。
///
/// 左右吸附（AevonSnap）也一并移除：单窗不需要并排，吸附只会把窗突然变形状。
enum AevonWindowManager {
    private static var currentView: AevonWindowView?
    private static var currentBundleID: String?

    /// 最近一次成功开窗的时间（`CACurrentMediaTime`）。
    ///
    /// V0.1.6（AevonFullscreenCloseV106）：开浮窗这个动作本身也会让 SpringBoard
    /// 建一个全屏的 `SBDeviceApplicationSceneViewController`（因为场景被推了前台），
    /// 于是 `viewDidAppear` 也会来一次。要区分「我们自己开窗的副作用」和
    /// 「用户从桌面点图标把这个 App 全屏拉起」，只能靠时间：开窗后头几秒内的
    /// 同 App 全屏画面一律认作副作用，不关窗。
    private static var lastOpenedAt: CFTimeInterval = 0

    /// App 全屏画面出现时调用（来自 `AevonEntryHost.appSceneAppeared`）。
    ///
    /// 背景：0.1.5 之后「浮窗开着设置 → 回桌面点设置图标」不再注销了，但浮窗会黑屏 ——
    /// 同一个场景被系统拿去全屏呈现，我们浮窗里的 presenter 拿不到画面，只剩一个
    /// 空壳子。用户要的语义很直接：**全屏打开时就把浮窗关掉**。
    ///
    /// 判定顺序（宁可漏关，不可误关）：
    ///   ① 没有浮窗 → 什么都不做；
    ///   ② 拿不到场景标识（KVC 全失败）→ 只记日志，**不动**（把未知当「未知」，
    ///      绝不能把 nil 当成「不是同一个 App」然后随便关别人的窗）；
    ///   ③ 标识里不含当前浮窗的 bundleID → 全屏进来的是别的 App，不动；
    ///   ④ 距开窗不足 5 秒 → 判定为开窗自身的副作用，不动；
    ///   ⑤ 其余情况 → 关窗（`releaseOnly`，不写任何场景状态，避免重演 SIGTRAP）。
    static func handleFullscreenSceneAppeared(sceneIdentifier: String) {
        guard let bundleID = openBundleID else { return }
        guard !sceneIdentifier.isEmpty else {
            AevonLog.warn("[窗口] 全屏 App 画面出现，但场景标识取不到（探针待补 KVC 路径）；本次不自动关窗（AevonFullscreenCloseV106）")
            return
        }
        guard sceneIdentifier.contains(bundleID) else { return }
        let age = CACurrentMediaTime() - lastOpenedAt
        if age < 5.0 {
            AevonLog.info("[窗口] 全屏画面（\(sceneIdentifier)）距开窗 \(String(format: "%.1f", age))s，判定为开窗自身副作用，保留浮窗（AevonFullscreenCloseV106）")
            return
        }
        AevonLog.info("[窗口] \(bundleID) 被系统全屏拉起（\(sceneIdentifier)，距开窗 \(String(format: "%.1f", age))s）→ 自动关闭浮窗，避免残留黑窗（AevonFullscreenCloseV106）")
        close(bundleID: bundleID, releaseOnly: true)
    }

    /// V0.2.47（AevonDarkGuardV247）：全屏 App 画面离场（回桌面 / 切 App）时调用。
    ///
    /// 浮窗里承载的是 App 自己的**主场景**（S2 路线）或自建场景，两种场景的前台
    /// 状态都跟着系统的 App 状态走。一上滑回桌面，这个 App 就被置后台、远程表面
    /// 被回收 → presenter 没东西可画 → 用户看到黑窗（关掉重开才恢复，因为开窗会
    /// 重新推一次前台）。这里把「离场」这个事件转给浮窗，让它布防 + 有界重申。
    ///
    /// 只在浮窗还在时动作；没有浮窗就是一次函数调用，零副作用。
    static func noteForegroundSceneLost() {
        guard let view = currentView else { return }
        view.armBackgroundGuard(reason: "全屏 App 画面离场")
    }

    /// 这个 App 是否正装在这个唯一浮窗里。
    static func isWindowed(_ bundleID: String) -> Bool {
        return currentView != nil && currentBundleID == bundleID
    }

    /// 当前浮窗里装的 App（没有浮窗时返回 nil）。
    static var openBundleID: String? {
        return currentView != nil ? currentBundleID : nil
    }

    /// 面板里的「已开窗口」列表 —— 单窗模式下最多一个元素。
    static var openBundleIDs: [String] {
        if let identifier = openBundleID { return [identifier] }
        return []
    }

    static func title(for bundleID: String) -> String {
        return AevonAppInfo.displayName(bundleID: bundleID) ?? bundleID
    }

    /// 把浮窗提到最前（单窗其实恒在最前，保留这个入口只为面板调用不改）。
    static func bringToFront(bundleID: String) {
        guard isWindowed(bundleID) else { return }
        currentView?.bringToFront()
    }

    /// 为指定 App 开窗（带场景就绪等待与全路径守卫，任何失败都静默放弃）。
    ///
    /// 单窗语义：已经有窗且装的是别的 App → 先关掉旧窗再开新窗；装的是同一个 App
    /// → 直接置顶，不重复开。
    static func open(bundleID: String,
                     sceneID: String?,
                     completion: ((Bool) -> Void)? = nil) {
        guard AevonPrefs.bool("Enabled", default: true) else {
            AevonLog.warn("[窗口] 插件未启用，忽略开窗请求")
            completion?(false)
            return
        }
        if let existingID = openBundleID {
            if existingID == bundleID {
                AevonLog.info("[窗口] \(bundleID) 已在浮窗里，直接置顶（单窗模式）（AevonSingleWindowV105）")
                currentView?.bringToFront()
                completion?(true)
                return
            }
            AevonLog.info("[窗口] 单窗模式：先关掉 \(existingID)，再把 \(bundleID) 装进同一个窗（AevonSingleWindowV105）")
            close(bundleID: existingID)
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

            // ── V0.2.28（AevonSelfSceneV228，P1 概念验证）────────────────────
            // 自建场景路线：创建时烙定画布（LiveContainer / FrontBoardAppLauncher 链，
            // 真机 P0 探测 AevonPiPProbeV226 六项判据全通；V63/V64/V87 已证明
            // 「接管已有全屏场景后改尺寸」永不重排，创建时烙定是唯一通路）。
            // 成功 → 用自建场景承载（App 按浮窗尺寸原生重排，内容 1:1）；
            // 失败 → 原全屏接管路径原样兜底，行为与 0.2.27 完全一致。
            var hostScene: AnyObject = scene
            var usedSelfScene = false
            var selfSceneIDOut: NSString?
            // V0.2.35（AevonSceneRouteV235）：创建前分流。
            // 0.2.34 真机实锤：scene 感知 App（设置/GitHub/Safari）自建场景全通；
            // 老式单场景 App（Sileo）App 端 connectedScenes 8 秒无自建场景 = 连接被
            // App 端 UIKit 拒绝（创建链与开源参照逐字段一致，FrontBoardAppLauncher
            // README 同款已知限制）。无 scene manifest 的 App 直接走全屏接管旧路径：
            // 不自建、不广播、不进 8 秒黑窗 —— 画面即刻出现（0.2.27 行为）。
            // V0.2.38（AevonSceneRouteV238）：白名单制。0.2.37 真机翻车 + Sileo
            // 源码破案：Sileo 的 Info.plist 根本没有 UIApplicationSceneManifest
            // （老式 storyboard App），本应 return 0 走旧路径，但 0.2.35~37 三版
            // 真机 Sileo/Filza/抖音/QQ 全走自建且分流零行 = 三版全返回 -1（取证链
            // proxy/info 段断点）而 -1 一直被放行。改为只有确证 2 才自建，
            // -1 一律保守旧路径（画面优先）；每次开窗打取证串定断点。
            // 历史判据（AevonSceneRouteV235 / AevonSceneRouteV236 / AevonSceneRouteV237）：
            // 0=无 manifest；1=有 manifest 单场景或无 scene delegate 类名；
            // 2=manifest 带真 scene delegate 类名 + 多场景。
            // V0.2.39（AevonSceneRouteV239）：0.2.38 取证实锤 infoDictionary 在
            // roothide SB 进程调用即抛 NSInvalidArgumentException（三版全 -1 同路，
            // 0.2.38 白名单制因此全回退）。主路线换 SBApplication.sceneSpecification
            // （SB 自己解析的 manifest，AevonAppInfo 已验证链路），Swift 判据不变。
            // V0.2.40（AevonSceneRouteV240）：0.2.39 真机定论 SBApplication 两个 spec
            // 选择子都不响应（仍全 -1 全回退）；且设置的 manifest uiSceneDel=no
            // uiMulti=0 却实现了 configurationForConnecting → 判据在 App 二进制不在
            // manifest。垫片内部升级为 A 路线（SBApplication，其他版本兜底）+ B 路线
            // （二进制扫 configurationForConnectingSceneSession，主路线），Swift 判据
            // 仍只有确证 2 才自建（AevonSelfSceneAppBinarySupport 已由垫片内部调用）。
            // V0.2.41（AevonSceneCapsV241）：判据改成「App 侧进程内能力登记表」。
            // 静态判据连错五版（0.2.35 manifest 有无 / 0.2.36 supportsMultipleScenes /
            // 0.2.37 delegate 类名 / 0.2.39 SBApplication spec / 0.2.40 二进制扫描）：
            // 0.2.40 真机 Sileo/Filza 二进制扫到该选择子串仍黑屏，贴吧纯净版扫不到
            // 却本可真重排；设置 manifest 无 delegate 类名却成功。唯一与五轮真机成败
            // 100% 对齐的判据是 App 进程内「delegate 是否实现
            // application:configurationForConnectingSceneSession:options:」——
            // 由 App 侧 AevonAppSceneCapRegistry 算完写 /var/mobile/aevon_caps.txt，
            // 这里只读表：0 → 旧路径；1 → 自建；-1（未登记）→ 维持自建（旧行为）。
            let routeDump = AevonSelfSceneRouteDump(bundleID)
            let capVerdict = AevonSelfSceneAppCapVerdict(bundleID)
            AevonLog.info("[场景] 能力登记：\(bundleID) cap=\(capVerdict)（1=scene App 可自建，0=老式必拒，-1=未登记）（AevonSceneCapsV241）")
            // ── V0.2.42（AevonSceneRouteV242 / AevonMainSceneResizeV242）──────────
            // 0.2.41 真机（Aevon(17)）三点判读：
            //   ① 能力登记表工作正常（/var/mobile/aevon_caps.txt：Sileo/Filza/
            //      BatteryInfo=0，设置/Spotlight=1），cap=0 的 App 全走旧路径、无黑屏。
            //   ② 但 cap=-1（该 App 进程还是旧版 dylib 起的，没登记）照样走自建场景，
            //      老式 App 于是又黑一次（Sileo 10:00:42 建场景、2 秒后销毁、13 秒后
            //      才读到 cap=0）—— -1 不能再当「可自建」用。
            //   ③ 旧路径形态问题依旧：整屏渲染顶左裁切 = 用户说的「内容显示不全」。
            // 本版同时验两条从未试过的通路（开源交叉调研 2026-10-27 报告）：
            //   S2（主刀，默认开｜MainSceneResize）：改「已在运行的主场景」settings.frame
            //     —— MilkyWayReborn scaleMode 同一条 updateSettings 通路，不需要第二场景，
            //     与「App 是否接受第二场景」完全无关；老式单场景 App 也能收到这次 resize
            //     （系统 Slide Over 就是这么让它重排的）。关窗还原全屏画布。
            //   S1（试验档｜SceneRouteForceSelf，默认关）：连老式 App 也走自建场景，
            //     同时 App 侧打开场景请求闸（AevonSceneGateV242：supportsMultipleScenes
            //     强制 YES + 补 configurationForConnecting），硬判据 = App 端
            //     connectedScenes 出现自建场景（0.2.34 窗口搬家的前提）。
            // 历史分流判据链（AevonSceneRouteV235/V236/V237/V238/V239/V240）：
            // 五版静态判据（manifest 有无 / supportsMultipleScenes / delegate 类名 /
            // SBApplication.sceneSpecification / 二进制扫描）全被真机证伪，统一收敛到
            // AevonSelfSceneAppCapVerdict 读进程内登记表。
            let selfSceneOn = AevonPrefs.bool("SelfBuiltScene", default: true)
            let forceSelf = AevonPrefs.bool("SceneRouteForceSelf", default: false)
            // V0.2.48（AevonMainSceneFixedV248）：Aevon(23)「设置中的主场景改画布开关也
            // 默认写入代码中，并且移除开关项」→ 从偏好读取降级为常量 true。
            // 这个开关本来默认就是开、且是「真重排」唯一可用通路（cap=-1 的老式 App 只能走它），
            // 暴露在设置里只会让用户把它关掉、然后觉得浮窗「内容显示不全」。
            let mainResizeOn = true
            // ── V0.2.44（AevonScreenAspectV244）：内容比例跟随屏幕档 ──────────────
            // 这一档的画布 = **整屏原生尺寸**，App 的排版与全屏逐像素一致，呈现层只做
            // 等比缩进窗口。所以自建场景（第二场景）在这档没有任何意义：它的画布也是
            // 整屏，等于把整屏塞进浮窗，还多一层「App 是否接受第二场景」的风险。
            // 一律走主场景整屏呈现：画布写一次屏尺寸（幂等，能从任何残留小画布恢复）。
            let screenAspectOn = AevonWindowView.usesScreenAspect
            let routeSelf = selfSceneOn && !screenAspectOn && (capVerdict == 1 || forceSelf)
            let routeMain = !routeSelf && (screenAspectOn || mainResizeOn)
            let routeName = routeSelf
                ? "自建场景"
                : (screenAspectOn ? "整屏等比缩放（屏幕比例档）" : (routeMain ? "主场景改画布(S2)" : "全屏接管旧路径"))
            AevonLog.info("[场景] 分流：\(bundleID) cap=\(capVerdict) 档=\(forceSelf ? "S1 试验（强制自建）" : "自动") → \(routeName)"
                + "（S2 主场景改画布已定档常开，设置页开关已移除）（AevonSceneRouteV242 AevonScreenAspectV244 AevonMainSceneFixedV248）")
            if !routeSelf {
                AevonLog.info("[场景] 分流：\(bundleID) 不走自建；取证：\(routeDump)（AevonSceneRouteV238）")
            }
            if routeSelf {
                // V0.2.43（AevonCanvasScaleV243）：自建场景的烙定画布同样是「窗口 × k」
                let windowSize = AevonWindowView.plannedContentSize()
                let size = AevonWindowView.canvasSize(for: windowSize)
                // V0.2.29（AevonSelfSceneRetryV229）：`launchApplicationWithIdentifier:suspended:`
                // 刚拉起的进程，processHandle 可能还没在 SBApplication 上登记好
                // → 短重试等登记，共 4 次尝试 × 0.3s；其余 step 串不重试（重试也不会好）。
                // V0.2.30（AevonSelfSceneRBSV230）：路线 B（RBSProcessHandle）后，
                // 可重试串补 pid-nil / rb-handle-nil（RunningBoard 登记也有冷启动期）。
                // V0.2.31（AevonSelfScenePidV231）：0.2.30 全卡 pid-nil 但 AevonAppInfo.pid
                // 同刻取到 → 调用方用已验证路径（AevonAppInfo.pid）预取 pidHint 直传垫片。
                var created: AnyObject? = nil
                var errOut: NSString? = nil
                for attempt in 1...4 {
                    let pidHint = AevonAppInfo.pid(bundleID: bundleID) ?? 0
                    created = AevonSelfSceneCreate(bundleID,
                                                   pidHint,
                                                   Double(size.width), Double(size.height),
                                                   &selfSceneIDOut, &errOut) as AnyObject?
                    if created != nil { break }
                    let step = errOut as String? ?? "?"
                    let retryable = step == "app-object-nil" || step == "process-handle-nil"
                        || step == "pid-nil" || step == "rb-handle-nil"
                    if attempt < 4 && retryable {
                        AevonLog.info("[场景] 自建场景重试 \(attempt)/3（step=\(step)，AppInfo pid=\(pidHint)，等进程登记）（AevonSelfSceneRetryV229）")
                        Thread.sleep(forTimeInterval: 0.3)
                    } else {
                        break
                    }
                }
                if let created = created {
                    hostScene = created
                    usedSelfScene = true
                    AevonLog.info("[场景] 自建场景已创建：bundleID=\(bundleID) 画布=\(Int(size.width))x\(Int(size.height)) sceneID=\(selfSceneIDOut as String? ?? "?")（AevonSelfSceneV228）")
                    // ── V0.2.32（AevonSelfSceneFGV232）───────────────────────
                    // ① 登记自建场景：保活/重申前台从此打在自建场景上
                    //   （0.2.31 保活 8 次全打主场景 = 与自建场景抢 activation）。
                    AevonSceneHelper.registerSelfScene(bundleID, hostScene)
                    // ② 主场景交割：把主场景 foreground 写 NO，App 端 activation
                    //   唯一落在自建场景（两个 foreground 场景并存 = 单场景 App 把
                    //   UI 留在主场景，自建场景黑屏）。关窗时恢复（见 close）。
                    AevonSceneHelper.setForeground(scene, false)
                    // ③ 三拍重申前台（LiveContainer #942 同款）：FBSSceneObserver 会
                    //   优先发 resignActive / SB 重算会把 foreground 写回 0（round8
                    //   档案：cs 2→0、layers 2→0 = 黑），三拍对抗。
                    for delay in [0.3, 1.2, 3.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            let ok = AevonSelfSceneReassertForeground(hostScene)
                            AevonLog.info("[场景] 重申自建场景前台（+\(delay)s，\(ok ? "已提交" : "失败")）（AevonSelfSceneFGV232）")
                        }
                    }
                    // V0.2.35（AevonSceneRouteV235）：连接取证（只读）。
                    // client 非空 = App 端已连上 FB 层；恒空 = 分流误判（有 manifest
                    // 仍被拒）或连接更早环节被卡 —— 下一版按这串定界。弱引用：场景
                    // 先销毁时自动跳过，绝不摸悬挂对象。
                    for delay in [1.5, 3.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak hostScene] in
                            guard let hs = hostScene else { return }
                            let state = AevonSelfSceneConnectionState(hs)
                            AevonLog.info("[场景] 连接取证（+\(delay)s）：\(state)（AevonSceneRouteV235）")
                        }
                    }
                } else {
                    AevonLog.warn("[场景] 自建场景创建失败（step=\(errOut as String? ?? "?")）→ 回退全屏接管路径（AevonSelfSceneV228）")
                }
            }

            // ── V0.2.42（AevonMainSceneResizeV242）：S2 主场景改画布 ──────────────
            // 生效条件：本轮没走自建（cap=0/-1、或 S1 档未开、或自建创建失败）。
            // 只写 settings.frame（主场景前台状态机归系统，绝不写）；FrontBoard 可能
            // 把 frame 重算回全屏，三拍复查 + 补写（防回弹）。关窗由承载器还原。
            var mainResized = false
            var mainCanvas: CGSize = .zero
            if !usedSelfScene && routeMain {
                // V0.2.43（AevonCanvasScaleV243）：画布 = 窗口 × k（不再等于窗口本身）
                // V0.2.44（AevonScreenAspectV244）：屏幕比例档 → 画布 = 整屏原生尺寸
                let windowSize = AevonWindowView.plannedContentSize()
                let size = AevonWindowView.canvasSize(for: windowSize)
                let expected = "frame=\(Int(size.width))x\(Int(size.height))"
                let stateNow = AevonMainSceneFrameState(scene) ?? ""
                if screenAspectOn && stateNow.contains(expected) {
                    // 屏幕比例档 + 画布本来就是整屏 → 一个字节都不用写
                    // （多余的 updateSettings 会让 App 白重排一次，画面闪一下）
                    AevonLog.info("[场景] 整屏画布：\(bundleID) 已是 \(expected)，跳过写入"
                        + "（App 本就按整屏排版，呈现层等比缩进窗口）（AevonScreenAspectV244）")
                } else {
                    let ok = AevonMainSceneSetFrame(scene, Double(size.width), Double(size.height))
                    mainResized = ok
                    mainCanvas = size
                    if screenAspectOn {
                        AevonLog.info("[场景] 整屏画布：\(bundleID) 窗口=\(Int(windowSize.width))x\(Int(windowSize.height))"
                            + " → 画布=\(Int(size.width))x\(Int(size.height))（与整屏一致，App 原生排版后等比缩进浮窗）"
                            + "（\(ok ? "已提交" : "失败")，读回 \(AevonMainSceneFrameState(scene) ?? "")）"
                            + "（AevonScreenAspectV244）")
                    } else {
                        // V0.2.46（AevonCanvasHandoffV246）：这一行就是「App 拿到一块独立画布
                        // 自己重排」的正面证据 —— 对所有走 S2 的 App 一视同仁（不分系统 / 第三方）。
                        AevonLog.info("[场景] 主场景改画布：\(bundleID) 窗口=\(Int(windowSize.width))x\(Int(windowSize.height))"
                            + " × \(String(format: "%.2f", AevonWindowView.canvasScale)) → 画布=\(Int(size.width))x\(Int(size.height))"
                            + "（App 拿到 \(Int(size.width))x\(Int(size.height)) 的独立画布自己排版，不是缩放/裁切；"
                            + "\(ok ? "已提交" : "失败")，读回 \(AevonMainSceneFrameState(scene) ?? "")）"
                            + "（AevonMainSceneResizeV242 AevonCanvasScaleV243 AevonCanvasHandoffV246）")
                    }
                }
                // 三拍复查（0.35 / 1.2 / 2.5s）由承载器持有：关窗 invalidate 之后
                // 一律不再补写 —— 0.2.42 把闭包排在这里，关窗后 2.5s 那一拍又把
                // 已还原的 430x932 写回画布尺寸（Aevon(18) 真机日志两处）。
            }

            AevonSceneHelper.setForeground(hostScene, true)

            // 关键：`launchApplicationWithIdentifier:suspended:` 拉起的进程是挂起态，
            // 挂起的进程不会渲染 —— 必须显式恢复执行，否则 presenter 永远拿不到首帧。
            if let pid = AevonAppInfo.pid(bundleID: bundleID) {
                AevonAssertionShim.resumePID(Int32(pid))
                AevonLog.info("[窗口] 已恢复 \(bundleID) 进程执行（pid=\(pid)）")
            }

            let sceneIdentifier = usedSelfScene
                ? ((selfSceneIDOut as String?) ?? "sceneID:com.aevon.float-\(bundleID)")
                : ((AevonRuntime.send(scene, Selector(("identifier"))) as? String) ?? sceneID ?? "")
            guard let sceneHost = AevonSceneHost(scene: hostScene, sceneID: sceneIdentifier,
                                                 bundleID: bundleID, isSelfBuilt: usedSelfScene,
                                                 mainResized: mainResized) else {
                AevonLog.warn("[窗口] 无法创建场景承载容器，放弃开窗")
                if mainResized {
                    // V0.2.42（AevonMainSceneResizeV242）：承载不了就把主场景画布还原，
                    // 不能把 App 的主场景留在浮窗尺寸上
                    let screen = UIScreen.main.bounds.size
                    _ = AevonMainSceneSetFrame(scene, Double(screen.width), Double(screen.height))
                }
                if usedSelfScene {
                    _ = AevonSelfSceneDestroy(hostScene)
                    AevonSceneHelper.unregisterSelfScene(bundleID)
                    // 主场景交割回滚：自建场景没了，主场景重新拿回前台
                    AevonSceneHelper.setForeground(scene, true)
                }
                AevonForegroundManager.shared.remove(bundleID: bundleID, sceneID: sceneID)
                completion?(false)
                return
            }

            // V0.2.43（AevonMainCanvasGuardV243）：防回弹三拍交给承载器 ——
            // 它无效化（关窗 / 换 App）之后，这些闭包一个都不会再写主场景画布。
            if sceneHost.mainResized {
                for delay in [0.35, 1.2, 2.5] {
                    sceneHost.verifyMainCanvasKeep(width: mainCanvas.width,
                                                   height: mainCanvas.height,
                                                   delay: delay)
                }
            }

            let title = AevonWindowManager.title(for: bundleID)
            let windowView = AevonWindowView(sceneHost: sceneHost, bundleID: bundleID, title: title)
            host.addSubview(windowView)
            host.bringSubviewToFront(windowView)
            currentView = windowView
            currentBundleID = bundleID
            lastOpenedAt = CACurrentMediaTime()
            // V0.2.9（AevonFloatStandDownV209）：把「浮窗里装的是谁」写到偏好域。
            // App 侧识别器读它 —— 等于自己的 bundleID 就整体退让（不扣 began、不建失败要求），
            // 浮窗内的滑动才不会被右缘判向延迟到抬手。
            AevonPrefs.set("AevonFloatBundle", bundleID)

            // presenter 激活后画面是异步出来的，由承载器自己探测首帧
            sceneHost.startSyncing()
            AevonSceneHelper.startKeepAlive(bundleID)
            // V0.1.5：进程保活不再是开关项 —— 它是「单窗里那个 App 别被系统挂起」的必需品，
            // 而且它走 RBSAssertion（不动 FrontBoard 的场景状态机），比写 FBScene 设置安全。
            if let pid = AevonAppInfo.pid(bundleID: bundleID) {
                AevonAssertionShim.acquireKeepAlive(forPID: Int32(pid))
            }
            AevonLog.info("[窗口] \(bundleID) 窗口化成功（单窗模式）（AevonSingleWindowV105）")
            completion?(true)
        }
    }

    /// 悬浮球 / 圆盘入口：必要时先把目标 App 的场景拉起来，再开窗。
    ///
    /// `launchApplicationWithIdentifier:suspended:` 只在 SpringBoard 里存在，
    /// 拉起的是「挂起态」，不会整屏盖住桌面；随后由 AevonSceneHelper 把场景推前台
    /// 并挂到我们的浮窗上。全程任何一步失败都只记日志，不做强制解包。
    static func launchAndOpen(bundleID: String,
                              completion: ((Bool) -> Void)? = nil) {
        guard AevonPrefs.bool("Enabled", default: true) else {
            AevonLog.warn("[窗口] 插件未启用，忽略开窗请求")
            completion?(false)
            return
        }
        if isWindowed(bundleID) {
            AevonLog.info("[窗口] \(bundleID) 已在浮窗里，置顶（单窗模式）")
            bringToFront(bundleID: bundleID)
            completion?(true)
            return
        }

        if AevonSceneHelper.scene(for: bundleID) != nil {
            AevonLog.info("[窗口] \(bundleID) 已有场景，直接开窗")
            open(bundleID: bundleID, sceneID: nil, completion: completion)
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
                open(bundleID: bundleID, sceneID: nil, completion: completion)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 关窗并清理全部相关状态。
    ///
    /// `releaseOnly = true`（AevonIconLaunchV104）：只释放浮窗与前台保持，
    /// **不写场景的 foreground 标记**。用于「用户点桌面图标要把这个 App 全屏拉起」——
    /// 那一刻 FrontBoard 正在自己接管这个场景，我们再往里写一次 settings 就是抢
    /// 同一份状态机（归档(12)/(13) 的 SIGTRAP 来源），所以这一步只放手、不置位。
    static func close(bundleID: String, releaseOnly: Bool = false) {
        guard let windowView = currentView, currentBundleID == bundleID else { return }
        currentView = nil
        currentBundleID = nil
        // V0.2.9（AevonFloatStandDownV209）：浮窗没了 → 清掉「浮窗里装的是谁」，
        // App 侧识别器立刻恢复常态（空串 = 不在浮窗里）。
        AevonPrefs.set("AevonFloatBundle", "")
        windowView.teardown()
        AevonSceneHelper.stopKeepAlive(bundleID)
        // V0.2.32（AevonSelfSceneFGV232）：自建场景已随 teardown 销毁，登记必须同步
        // 注销（保活定时器若还查到悬空场景对象会写进已销毁场景）。
        AevonSceneHelper.unregisterSelfScene(bundleID)
        if !releaseOnly {
            AevonSceneHelper.sleep(bundleID)
        }
        AevonForegroundManager.shared.remove(bundleID: bundleID, sceneID: nil)
        if let pid = AevonAppInfo.pid(bundleID: bundleID) {
            AevonAssertionShim.releaseKeepAlive(forPID: Int32(pid))
        }
        AevonLog.info("[窗口] \(bundleID) 已关闭\(releaseOnly ? "（交接给系统全屏拉起，未写场景前台标记）" : "")")
    }

    /// V0.1.4（AevonIconLaunchV104）：桌面图标被点、要把这个 App 全屏拉起时调用。
    ///
    /// 「浮窗开着设置 → 回桌面点设置图标 → 自动注销」的唯一稳定解法是**先松手**：
    /// 释放 presenter、摘掉浮窗、停前台保持，再登记 5 秒交接期。
    static func releaseForFullscreenLaunch(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        AevonForegroundManager.shared.beginFullscreenHandoff(bundleID: bundleID)
        let wasWindowed = isWindowed(bundleID)
        close(bundleID: bundleID, releaseOnly: true)
        AevonLog.info("[窗口] \(bundleID) 即将全屏拉起 → 已释放浮窗与前台保持（\(wasWindowed ? "原浮窗已关" : "本来没开窗")，交接期 5 秒内不写场景前台标记）（AevonIconLaunchV104）")
    }

    static func closeAll() {
        if let identifier = openBundleID {
            close(bundleID: identifier)
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
        currentView?.setNeedsLayout()
    }
}
