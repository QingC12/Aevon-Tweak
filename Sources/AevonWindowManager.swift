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
    /// V0.3.24（AevonOpenSingleFlightV324）：开窗单飞的单调令牌 —— 每次真正要建窗时自增，
    /// 所有异步闭包里对不上 `openingToken` 就是过期链，直接中止。`close()` 也会自增，
    /// 关窗即作废所有在途开窗链（否则关窗后 1.3 秒的兜底显窗会把刚关掉的窗又显出来）。
    private static var openingToken: UInt64 = 0
    private static var openingBundleID: String?
    /// V0.3.1（AevonKickSkipV301，用户 Aevon(79) #1 + 确认「抖踢前置幂等闸」）：
    /// **抖踢账面判据** —— 记「上一次被浮窗承载、画布被改成 430x737 的 App」。只有
    /// 真的被我们改过画布的 App，进程才可能仍按旧画布排版，才需要抖动踢把它逼回来；
    /// 从没被承载过的 App（画布一直是整屏）踢它纯粹是往刚进前台的进程上写怪尺寸
    /// —— Aevon(75)/(77)/(78)/(79) 四次抖音卡屏（cs=2 死锁）全部发生在「抖音刚进
    /// 全屏 + 被写了 4 笔抖踢」，而每次读回都已是 430x932。踢一次即消费掉。
    private static var lastFloatCanvasBundle = ""

    // MARK: - 停靠列（V0.2.50，AevonDockColumnV250）
    //
    // 历史：0.1.0 重制时把 0.0.x 的「吸附 + 停靠列」整体删掉了（单窗模式）。
    // Aevon(25) 第 3 条要把它拿回来：「更新一下屏幕左右边缘的吸附停靠小窗……
    // 小窗吸附后的尺寸按照我们的小胖屏等比例缩小……停靠位置优先从顶部开始，依次向下排列」。
    //
    // 这一版的实现刻意**不动**主窗那条链路：
    //   · 主窗仍然是唯一「活」的窗口（`currentView` / `openBundleID` 语义完全不变）；
    //   · 停靠小窗 = 把**已经开好的那个主窗**降级成边缘小窗（同一个 AevonWindowView、
    //     同一个 scene host、同一个 presenter）—— 不新建场景、不新建画布、不重排 App；
    //   · 所以「拖到边缘 → 变停靠小窗 → 圆盘再开另一个 App → 再拖到边缘」可以一路叠到 5 个，
    //     每个都是活的画面，而主窗位置始终只有一个。
    // 之所以不用「每个停靠窗都自建场景」：一台机器上 App 侧只有**一个**
    // `AevonFloatBundle` 承载信号（UIScreen 覆盖靠它），多场景并存会互相抢这个信号，
    // 反而把已经修好的抖音重排又弄坏。
    private static var dockedViews: [AevonWindowView] = []

    /// 现在有没有浮窗（主窗或任意停靠小窗）—— 给 ObjC 的锁屏拦截钩子用。
    static var hasAnyWindow: Bool {
        return currentView != nil || !dockedViews.isEmpty
    }

    /// 全部浮窗（主窗在前，停靠列按加入顺序）。
    static var allWindows: [AevonWindowView] {
        var list: [AevonWindowView] = []
        if let view = currentView { list.append(view) }
        list.append(contentsOf: dockedViews)
        return list
    }

    // MARK: - 系统浮层让位（V0.2.78，AevonOverlayYieldV278）
    //
    // 用户 Aevon(50) #1：「悬浮窗打开时下拉控制中心时，悬浮窗依旧显示，无法操作控制中心的按钮」。
    // Aevon(50) 窗口栈实锤：`1080:SBControlCenterWindow` 与我们 `10000000:AevonEntryWindow` ——
    // 入口窗口比控制中心高近一万倍，浮窗那一块必然压在控制中心之上，并且把落在浮窗上的
    // 触摸吃掉（控制中心按钮点不到）。
    //
    // 参考实现（开源 MilkyWayReborn，iOS 17-26）：宿主窗口放 `UIWindowLevelAlert - 1`，
    // 系统瞬时浮层自然覆盖在窗口之上 —— 它**不跟系统抢层级**。
    // 我们不能再降 level（1e7 是历次为压住状态栏/横幅调出来的，动它要重验一整条触摸链），
    // 所以采用**让位**：控制中心 / 通知中心 / 多任务切换器在屏时，浮窗外壳与把手整体藏起来，
    // 系统浮层收起后原样恢复。视觉与触摸两条都干净。
    private static var overlayYielded = false

    /// 系统浮层（控制中心 / 通知中心 / 切换器）在屏 → 浮窗让位。
    static func setSystemOverlayYield(_ yielding: Bool) {
        guard overlayYielded != yielding else { return }
        overlayYielded = yielding
        let windows = allWindows
        for view in windows {
            /* V0.2.82（AevonYieldAlphaV282，Aevon(55)「自动注销」）：让位从 `isHidden`
             * 改成「alpha=0 + 关交互」。
             *
             * 0.2.78 用的是 `view.isHidden = YES`，而 UIKit 在窗口被隐藏的那一刻会
             * **立刻 cancel 该窗口上的所有触摸，并把对应 UITouch 从事件簿记里摘掉**；
             * 我们的 sendEvent 钩子（AevonTouchHook.m）还握着同一个 UITouch 指针，
             * 下一帧读 `touch.phase` / `[touch locationInView:nil]` 就是 use-after-free。
             * Aevon(55) 两次 SIGSEGV 分别落在「让位后 0.28 秒」和「开窗完成 0.53 秒」，
             * 同一批手指还在屏上 —— 与崩溃栈（帧1 = sendEvent 钩子）吻合。
             *
             * alpha=0 同样达到「让出画面与触摸」：alpha ≤ 0.01 的视图不参与 hitTest，
             * 新触摸天然穿透；但它**不会 cancel 已经在屏上的手指**，钩子手里的指针
             * 始终有效。而 `pointHitsFloatingWindow` / `grabFloatingWindow` 本来就以
             * `alpha > 0.01` 过滤，让位态下这一整套判定自动失效，不需要额外分支。 */
            /* V0.2.85（AevonYieldPureAlphaV285）：**不再碰 `isUserInteractionEnabled`**。
             *
             * 0.2.82 只把 `isHidden` 换成了 alpha，把「UIKit 当场 cancel 手指」这条堵了
             * 一半 —— 但 `isUserInteractionEnabled = false` 是**同一个后果**：UIKit 一样
             * 会立刻 cancel 该窗口上的所有触摸，并把 UITouch 从事件簿记里摘掉，而
             * `AevonTouchHook` 的 sendEvent 钩子还握着那个指针。
             *
             * Aevon(57) 崩溃点 2 的时序正好是这条：20.370 让位（手指刚下拉完通知中心）
             * → 20.902 SpringBoard 没了（0.53 秒）。0.2.82 那条「手指在屏不让位」闸门
             * 靠 `AevonEdgeEntry.hasActiveTouches`，而它对**落在系统浮层上的手指**是
             * 计不到的（那根手指根本不到我们的 sendEvent）→ 闸门形同虚设。
             *
             * alpha ≤ 0.01 的视图本来就不参与 hitTest：画面让出去了，新触摸天然穿透，
             * 而已经在屏的手指不会被 cancel。要的语义一个不少，风险归零。 */
            view.alpha = yielding ? 0 : 1
        }
        AevonRingGrip.setOverlayYield(yielding)
        AevonLog.info("[窗口] 系统浮层让位 \(yielding ? "开" : "关")："
            + "\(windows.count) 扇浮窗\(yielding ? "淡出隐藏（控制中心/通知中心在屏，让出触摸与画面）" : "恢复显示")"
            + "（AevonOverlayYieldV278 AevonYieldAlphaV282）")
    }

    /// 当前是否处于让位态（给入口巡检做去重）。
    static var isOverlayYielded: Bool { overlayYielded }

    /// 最近一次成功开窗的时间（`CACurrentMediaTime`）。
    ///
    /// V0.1.6（AevonFullscreenCloseV106）：开浮窗这个动作本身也会让 SpringBoard
    /// 建一个全屏的 `SBDeviceApplicationSceneViewController`（因为场景被推了前台），
    /// 于是 `viewDidAppear` 也会来一次。要区分「我们自己开窗的副作用」和
    /// 「用户从桌面点图标把这个 App 全屏拉起」，只能靠时间：开窗后头几秒内的
    /// 同 App 全屏画面一律认作副作用，不关窗。
    private static var lastOpenedAt: CFTimeInterval = 0

    // ── V0.2.53（AevonDockArbiterV253，用户 Aevon(27) #2）：停靠/装回手势仲裁 ──
    // 症状（真机日志 17:42:34.570→34.582 实锤）：边条轻点 → 停靠成功，12ms 后立刻
    // 「已从停靠列装回主窗」；拖到边缘松手吸附后也一样被装回。根因是**同一次手势
    // 被两条路各处理一次**：全局通道（sendEvent）与视图层手势识别器先后到达，
    // 第二条路看到 isDocked 已被第一条路翻成 true，就执行了相反的动作（装回）。
    // 修法 = 状态机防抖：dock 落地后 0.8 秒内的 restore 请求一律拒绝
    // （人手不可能在 0.8 秒内完成「点停靠→再点装回」，0.8s 内来的必然是同一次
    // 手势的重复响应）。restore 后同样防抖 dock。
    private static var lastDockAt: CFTimeInterval = 0
    private static var lastDockedBundleID: String = ""
    private static var lastRestoreAt: CFTimeInterval = 0
    private static var lastRestoredBundleID: String = ""
    /// 同一 App 两次停靠/装回动作的最小间隔（人手节奏下限）。
    ///
    /// V0.2.60（AevonDockArbiterNarrowV260，用户 Aevon(34) #2「点击吸附小窗内不会还原」）：
    /// 0.8 → 0.30 秒。0.8 秒是为了吸收「同一次手势被两条路各响应一次」，而真机日志
    /// 实锤重复响应只隔 **12 毫秒**（34.570 停靠 → 34.582 装回）；0.8 秒的窗口却把
    /// 用户随后正常的「点小窗装回」一起吃了 —— 停靠完 0.8 秒内点什么都没反应。
    /// 0.30 秒足够罩住重复响应，同时远大于人手「看到小窗再点它」的反应时间。
    private static let dockArbiterWindow: CFTimeInterval = 0.30

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
        guard !sceneIdentifier.isEmpty else {
            AevonLog.warn("[窗口] 全屏 App 画面出现，但场景标识取不到（探针待补 KVC 路径）；本次不自动关窗（AevonFullscreenCloseV106）")
            return
        }
        /* V0.2.65（AevonLiveWakeV265，用户 Aevon(38) #9「桌面开启悬浮窗时，打开全屏 App 时，
         * 浮窗内容会卡住，必须点一下或者多下才能显示实时画面」）：
         *
         * 全屏 App 一上场，系统会把**其它** App 的场景压到后台，我们浮窗里那个场景的
         * 远程表面就不再刷新 —— 窗口上留着的其实是最后一帧，看起来就是「卡住」。
         * 用户点一下能好，是因为点击让场景又拿到一次渲染机会。
         *
         * 这里在全屏画面出现的这一刻主动把它叫醒（重申前台 + 必要时垫帧 + 0.9 秒补一次），
         * 不依赖用户去点。 */
        if let bundle = currentBundleID, !bundle.isEmpty, !sceneIdentifier.contains(bundle) {
            currentView?.refreshLiveContent(reason: "全屏出现 \(sceneIdentifier)")
        }
        // ── V0.2.63（AevonFullscreenRecoverV263，用户 Aevon(37) #5）──────────────
        // 「悬浮窗打开设置，双击关闭浮窗后，点桌面设置图标 → 黑屏，浮窗也没自动关」。
        //
        // 这条路上我们**已经没有浮窗了**（currentView / dockedViews 都空），所以下面的
        // 自动关窗逻辑直接 `guard let openBundleID` 返回，什么都没做：而 App 的主场景
        // 还留着上一次「按画布 430x737 排版」的状态（App 侧承载标记可能也还挂着），
        // 系统按整屏把它拉起来时就只有一小块有画面，其余全黑。
        //
        // 兜底：全屏画面一出现，先看「承载标记是不是这个 App」—— 是就当场清标记 +
        // 把主场景画布写回整屏。清标记那一刻 App 进程 10ms 内就会自己改回真实尺寸
        // （AevonAppScreenFitV249 的事件驱动），再补一次画布写入是双保险。
        let marked = AevonPrefs.string("AevonFloatBundle") ?? ""
        if !marked.isEmpty, sceneIdentifier.contains(marked),
           currentView == nil,
           !dockedViews.contains(where: { $0.bundleID == marked }) {
            AevonLog.warn("[窗口] \(marked) 以全屏身份出现，但还挂着浮窗承载标记（浮窗早已关闭）"
                + "→ 清标记 + 主场景画布写回整屏，避免残留黑屏（AevonFullscreenRecoverV263）")
            AevonPrefs.set("AevonFloatBundle", "")
            AevonNotifySetFloatStage("")
            let screen = UIScreen.main.bounds.size
            if let scene = AevonSceneHelper.scene(for: marked), screen.height > 200 {
                let ok = AevonMainSceneSetFrame(scene, Double(screen.width), Double(screen.height))
                AevonLog.info("[窗口] 残留黑屏兜底：\(marked) 主场景画布写回 "
                    + "\(Int(screen.width))x\(Int(screen.height))（\(ok ? "已提交" : "失败")，"
                    + "读回 \(AevonMainSceneFrameState(scene) ?? "")）"
                    + "（AevonFullscreenRecoverV263）")
            }
            enforceSingleMainWindow(reason: "全屏恢复 \(marked)")
            return
        }
        /* V0.2.64（AevonFullscreenRecoverV264，用户 Aevon(38) #5.1「这次完美触发，然后
         * 第二次继续黑屏」）：第一次靠上面的「承载标记还在」兜住了；第二次标记已经被清掉，
         * 于是这条分支不成立、一路走到自动关窗逻辑 —— 但 App 的场景画布可能仍是 430×737
         * （上一次浮窗留下的），系统按整屏拉起来就是黑的。
         * 判据改成「我们手上什么都没拿」：没有主窗、没有停靠窗时，这个 App 的场景就该是整屏，
         * 无条件再写一次整屏画布（幂等；真已是整屏时读回值不变）。 */
        if currentView == nil, dockedViews.isEmpty {
            let screen = UIScreen.main.bounds.size
            if screen.height > 200, let scene = AevonSceneHelper.scene(for: sceneIdentifier) {
                /* V0.3.0（AevonKickThrottleV300，用户 Aevon(78) #1 三版同现场 + 确认「抖动踢限流」）：
                 * Aevon(75)/(77)/(78) 三次抖音卡屏（cs=2 进程内死锁型）全是同一场景：
                 * App 刚进全屏的 1 秒内吃了一顿场景写入 —— 「全屏出现兜底」画布写 1 笔
                 * + 两轮抖动踢 4 笔（其中 2 笔是 429x931 怪尺寸），全落在 cs=1（进场半途）。
                 * Aevon(78) 实锤：09:33:36.5~37.5 五笔连写后用户呼圆盘 12 次逃生态；
                 * 且每次读回都已是 430x932 —— 很多笔是幂等浪费。Stheno 独立场景路线
                 * 从不写前台 App 场景 = 结构性免疫。限流三刀：
                 *   ① 画布写前读回，已是整屏就跳过（幂等闸）；
                 *   ② 首踢 0.30s → 1.2s（cs=1 正常只 0.3~0.5s，+1.2s 时 App 已稳定前台）；
                 *   ③ 第二轮 +0.35s → +1.3s（绝对 +2.5s），保留防断层。 */
                let fullText = "frame=\(Int(screen.width))x\(Int(screen.height))"
                if (AevonMainSceneFrameState(scene) ?? "").contains(fullText) {
                    AevonLog.info("[窗口] 全屏出现兜底：读回已是整屏 \(Int(screen.width))x"
                        + "\(Int(screen.height))，跳过画布写（AevonFullscreenRecoverV264"
                        + " AevonKickThrottleV300）")
                } else {
                    _ = AevonMainSceneSetFrame(scene, Double(screen.width), Double(screen.height))
                    AevonLog.info("[窗口] 全屏出现兜底：确认主场景画布 = 整屏 "
                        + "\(Int(screen.width))x\(Int(screen.height))（读回 "
                        + "\(AevonMainSceneFrameState(scene) ?? "")）"
                        + "（AevonFullscreenRecoverV264 AevonKickThrottleV300）")
                }
                // V0.2.66（AevonFullKickV266，用户 Aevon(39) #11「关闭悬浮窗后全屏打开抖音
                // 会出现断层」）：画布写回整屏只改了 scene frame —— App 进程可能仍按
                // 上一轮浮窗画布 737 排版（frame 写入不必然触发 relayout）。这里不依赖
                // sceneHost（浮窗已关、承载器可能已 invalidate），直接对场景做一次
                // 「429x931 → 430x932」抖动写入，逼 App 用真实屏幕尺寸重排一遍。
                // V0.2.71（AevonFullKick2V271，用户 Aevon(43) #6/#7「重复开关后断层 /
                // 桌面再开黑屏」）：一轮抖动踢不够 —— Aevon(43) 里 FullKick 完成后全屏
                // 仍黑。补第二轮（+0.35s 再抖一次）并在每轮后打画布读回，下一份日志
                // 直接能看到「写回 932 后读回还是不是 932」。
                // V0.3.0（AevonKickThrottleV300）：首踢 0.30s→1.2s —— 别在 App 进场半途
                //（cs=1）往它场景上写怪尺寸，(78) 实锤这是 cs=2 死锁的头号嫌疑。
                /* V0.3.1（AevonKickSkipV301，用户 Aevon(79) #1 + 确认「抖踢前置幂等闸」）：
                 * 0.3.0 只把抖踢延后到 1.3s/2.5s —— Aevon(79) 实锤踢照样执行 4 笔
                 * （10:12:54.265 / 54.534 / 55.621 / 55.898，读回全是 fg=0 cs=2），
                 * 因为抖踢的目标尺寸是故意的 429x931，读回 430x932 永远不相等，幂等闸
                 * 管不到它。真正的闸是**账面判据**：只有被我们改过浮窗画布的 App 才可能
                 * 仍按旧画布排版。从没承载过的 App（抖音从桌面进全屏）+ 读回已是整屏
                 * → 一笔都不写。踢一次即消费记账。 */
                let frameIsFull = (AevonMainSceneFrameState(scene) ?? "").contains(fullText)
                let needKick = (lastFloatCanvasBundle == sceneIdentifier) || !frameIsFull
                if !needKick {
                    AevonLog.info("[窗口] 抖踢跳过：\(sceneIdentifier) 从未被浮窗改过画布且读回已是整屏 "
                        + "\(Int(screen.width))x\(Int(screen.height)) → 一笔都不写"
                        + "（AevonKickSkipV301）")
                } else {
                    lastFloatCanvasBundle = ""   // 踢一次即消费记账
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let w = screen.width, h = screen.height
                    _ = AevonMainSceneSetFrame(scene, Double(w - 1), Double(h - 1))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        _ = AevonMainSceneSetFrame(scene, Double(w), Double(h))
                        AevonLog.info("[窗口] 全屏兜底抖动踢完成：\(Int(w - 1))x\(Int(h - 1)) → "
                            + "\(Int(w))x\(Int(h))（逼 App 按真实屏幕重排，读回 "
                            + "\(AevonMainSceneFrameState(scene) ?? "")）"
                            + "（AevonFullKickV266 AevonFullKick2V271 AevonKickThrottleV300）")
                    }
                    // 第二轮：有些 App 第一轮抖动时还没进渲染（场景刚转前台），白抖。
                    // V0.3.0：+0.35s → +1.3s（绝对 +2.5s），保留防断层但离开进场窗口。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                        _ = AevonMainSceneSetFrame(scene, Double(w - 1), Double(h - 1))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            _ = AevonMainSceneSetFrame(scene, Double(w), Double(h))
                            AevonLog.info("[窗口] 全屏兜底第二轮抖动踢完成：读回 "
                                + "\(AevonMainSceneFrameState(scene) ?? "")"
                                + "（AevonFullKick2V271 AevonKickThrottleV300）")
                        }
                    }
                }
                }   // V0.3.1（AevonKickSkipV301）needKick 分支结束
            }
        }
        // V0.2.61（AevonDockFullscreenCloseV261，用户 Aevon(35) #2「悬浮窗打开设置后，
        // 全屏启动设置有概率黑屏，必须上滑关掉后台卡片才能恢复」）：
        // 停靠小窗**同样持有那个 App 的主场景 presenter**，而 openBundleID 在停靠态恒为
        // nil（主窗变量已归零）—— 0.2.60 及以前这条自动关窗逻辑对停靠小窗完全不生效，
        // 于是应用场景被两个主人抢：我们的小窗还在呈现它，App 自己的全屏窗口就拿不到
        // 画面 → 黑屏，只有杀掉进程才恢复。这里先把停靠列也纳进来。
        if let docked = dockedViews.first(where: { sceneIdentifier.contains($0.bundleID) }) {
            AevonLog.info("[窗口] \(docked.bundleID) 在停靠列里被系统全屏拉起（\(sceneIdentifier)）"
                + "→ 关掉小窗、释放 presenter 并还原画布，让 App 自己呈现（AevonDockFullscreenCloseV261）")
            // V0.2.62（AevonHandoffFastV262，用户 Aevon(36) #6「设置黑屏依然存在」）：
            // 先**同步清承载标记**再关窗。Aevon(36) 日志 11:05:12.849 自动关窗、
            // 12.963 才「屏幕贴合：关」—— 中间 110 毫秒 App 仍按画布 430×737 报告自己的
            // 屏幕尺寸，而系统这一刻正在把它的主场景拉成全屏：窗口按 737 高建好，之后
            // 再怎么重排都少一截，用户看到的就是黑屏。清标记会让 App 10ms 内自己恢复。
            AevonPrefs.set("AevonFloatBundle", "")
            AevonNotifySetFloatStage("")
            closeDocked(bundleID: docked.bundleID, reason: "被系统全屏拉起")
            return
        }
        guard let bundleID = openBundleID else { return }
        guard sceneIdentifier.contains(bundleID) else { return }
        let age = CACurrentMediaTime() - lastOpenedAt
        if age < 5.0 {
            AevonLog.info("[窗口] 全屏画面（\(sceneIdentifier)）距开窗 \(String(format: "%.1f", age))s，判定为开窗自身副作用，保留浮窗（AevonFullscreenCloseV106）")
            return
        }
        AevonLog.info("[窗口] \(bundleID) 被系统全屏拉起（\(sceneIdentifier)，距开窗 \(String(format: "%.1f", age))s）→ 自动关闭浮窗，避免残留黑窗（AevonFullscreenCloseV106）")
        AevonLog.info("[窗口] 交接给系统全屏：先同步清承载标记（App 侧 10ms 内恢复真实屏幕），"
            + "再关窗释放 presenter（AevonHandoffFastV262）")
        // V0.2.62（AevonHandoffFastV262）：同上 —— 交接前先清承载标记，App 侧立刻
        // 放弃画布尺寸，系统全屏那一帧就按整屏建窗口。
        AevonPrefs.set("AevonFloatBundle", "")
        AevonNotifySetFloatStage("")
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
        // V0.2.66（AevonGripFastV266，用户 Aevon(39) #6）：回桌面那一刻容器多半还挂在
        // 离场 App 的画面视图里（SB 主屏不触发「App 场景消失」），右缘把手跟着不可摸，
        // 要等看门狗（3s 周期归位）才回来 = 「触发条慢 1 秒左右」。布防这拍（桌面出现
        // 之前）立刻搬回窗口根，把手即时就位。无浮窗时也执行（把手归位与浮窗无关）。
        AevonLog.info("[入口] 回桌面布防 → 把手容器立即归位到窗口根（AevonGripFastV266）")
        AevonEntryHost.attachToWindowRoot(reason: "回桌面把手归位")
        guard let view = currentView else { return }
        view.armBackgroundGuard(reason: "全屏 App 画面离场")
    }

    /// V0.2.91（AevonHomeFreezeV291）：回桌面过渡哨命中 → 对当前浮窗**无条件**装
    /// 根级冻结帧。此时容器已被哨兵拉回窗口根，冻结帧 convert 到窗口坐标后与把手
    /// 同层，存活整段回桌面动画（AevonRootFreezeV290 已验证的挂载方式）。
    static func noteTransitionFreeze() {
        guard let view = currentView else { return }
        view.installTransitionFreeze(reason: "回桌面过渡哨")
        // V0.3.27（AevonKeepAliveEarlyV327）：同一拍起跑场景保活探针。
        // 布防要等 0.95 秒之后才来，那时候先手已经丢了。
        view.kickKeepAliveProbeOnTransition()
        /* V0.3.34（AevonArmEarlyV334）：布防也前移到这一拍（+0.2s）。
         * Aevon(99) 实测布防比哨晚 0.900 秒，那 0.9 秒里 cs 已经是 0 且没有任何
         * 守卫拍在跑。reason 必须含「画面离场」—— armBackgroundGuard 用它决定
         * 走「让位期 1 发预算」，写成别的会退化成三拍重申 = 自己制造三次黑。 */
        view.armBackgroundGuardSoon(reason: "全屏 App 画面离场（过渡哨前移）", delay: 0.2)
    }

    /// V0.3.27：过渡哨误报（控制中心半拉等）→ 收掉保活探针，别留悬空断言。
    static func cancelTransitionProbe() {
        currentView?.cancelKeepAliveProbe()
    }

    /// 这个 App 是否正装在我们某个浮窗里（主窗或停靠小窗）。
    static func isWindowed(_ bundleID: String) -> Bool {
        if currentView != nil, currentBundleID == bundleID { return true }
        return dockedViews.contains { $0.bundleID == bundleID }
    }

    /// 当前浮窗里装的 App（没有主窗时返回 nil；停靠小窗不算主窗）。
    static var openBundleID: String? {
        return currentView != nil ? currentBundleID : nil
    }

    /// V0.2.98（AevonStuckRescueV298，用户 Aevon(75) #2「抖音卡屏还在」+ 现场实锤：
    /// 21:50:12.698 前台哨 cs=1，卡 18 秒到 21:50:30 才恢复；期间全屏兜底 6 笔抖动踢
    /// 踢完就停，没有任何后续救援）：**cs=1 停滞救援**。cs=1 = 场景 connected 但不在画
    /// （正常激活 0.3~0.5s 内必回 cs=2）——停在 cs=1 = 场景激活卡死，SB 侧唯一实证
    /// 有效的手段 = launchApplicationWithIdentifier 真激活（0.2.92 起抖音修复实证，
    /// 等价用户点图标）。由 AevonEntryHost watchdog（3s 拍）在 cs=1 连续 ≥2 拍时调用，
    /// 浮窗开着/圆盘展开时不救（避免抢前台）。每次卡滞事件最多救 2 次（计数由
    /// EntryHost 管理，bundle 离开 cs=1 状态即清零）。
    static func rescueStuckScene(_ bundleID: String, round: Int) {
        guard !isWindowed(bundleID) else { return }
        let launchSel = Selector(("launchApplicationWithIdentifier:suspended:"))
        guard UIApplication.shared.responds(to: launchSel) else {
            AevonLog.warn("[窗口] 卡滞救援第 \(round) 轮：launch 通道不可用 → 放弃 \(bundleID)"
                + "（AevonStuckRescueV298）")
            return
        }
        AevonLog.warn("[窗口] 卡滞救援第 \(round) 轮：\(bundleID) cs=1 停滞 ≥6s → launchApplicationWithIdentifier"
            + "（suspended:false，等价点图标真激活）（AevonStuckRescueV298）")
        AevonRuntime.sendVoid(UIApplication.shared, launchSel, bundleID as NSString, false)
    }

    /// 面板里的「已开窗口」列表 —— 单窗模式下最多一个元素。
    static var openBundleIDs: [String] {
        if let identifier = openBundleID { return [identifier] }
        return []
    }

    /// V0.2.65（AevonEdgeShieldV265，用户 Aevon(38) #1 #2）：
    /// 把主浮窗的**屏幕矩形**写进偏好域，给 App 进程的吞咽判定用。
    ///
    /// 为什么不用通知传：`notify_set_state` 只有 64 位，装不下四个坐标；而每根手指
    /// 都发一次跨进程通知又太贵。浮窗几何变化很少（拖动松手 / 缩放 / 停靠 / 关闭），
    /// 写一次偏好让 App 侧缓存 0.5 秒，够用且零时序风险。
    static func publishFloatFrame(_ rect: CGRect) {
        let text = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        AevonPrefs.set("AevonFloatFrame", text)
        // V0.2.66（AevonFrameFileV266，用户 Aevon(39) #12「双击浮窗底边关窗，全屏 App
        // 依旧被带动」）：偏好域通道被日志证伪 —— Aevon(39) 整篇零条「浮窗手势区落点」，
        // App 侧 AevonFloatFrameRect() 读到的恒为零矩形（CFPreferences 跨进程在
        // roothide 的 App 进程里读不到 SB 刚写的值，cfprefsd 缓存/域映射不可靠）。
        // 加一条**文件通道**双保险：直接写 /var/mobile/Library/Aevon/floatframe.txt
        // （与我们自己日志同一个可写区），App 侧优先读文件、读不到再回落偏好。
        let dir = "/var/mobile/Library/Aevon"
        let path = dir + "/floatframe.txt"
        FileManager.default.createFile(atPath: path, contents: text.data(using: .utf8),
                                       attributes: nil)
        // V0.2.73（AevonRectNotifyV273，用户 Aevon(45) #4/#6）：第三通道 = notify state
        //（与 bit39 圆盘位同基建）。Aevon(45) 实锤 mqq 全篇 0 条 App 侧边带日志且
        // 用户实测边带失效 —— 文件通道在 QQ 等带 container 沙盒约束的 App 进程里
        // 读不到 /var/mobile/Library 下的文件，偏好域更早被证伪（0.2.66）。notifyd
        // 的 token state 全进程可达，无沙盒、无路径依赖，零矩形过不了范围校验。
        AevonFloatRectPublish(Float(rect.minX), Float(rect.minY),
                              Float(rect.width), Float(rect.height))
        /* V0.2.84（AevonStaleRectGateV284）：矩形一变就把存活心跳也顶一拍 ——
         * 只靠 0.5 秒定时器的话，开窗后最初的半秒里 App 侧还没看到心跳，
         * 那半秒滑把手会漏给 App。零矩形 = 窗没了 = 心跳归零。 */
        if rect.width < 40 || rect.height < 40 {
            floatAliveSeq = 0
            AevonFloatAlivePublish(0)
        } else {
            floatAliveSeq &+= 1
            AevonFloatAlivePublish(floatAliveSeq)
        }
    }

    /// V0.2.84（AevonContentSettledV284，Aevon(57)「悬浮窗打开时又出现闪一下」）：
    /// 定稿回调之后再补一道「内容真的排完了」的确认，然后才显形。
    ///
    /// 为什么 0.2.83 的「等定稿回调」还不够：那条回调只代表**画布写完已提交**，
    /// 而 App 进程下一次布局要再过一到两帧。Aevon(57) 时序账（设置）：
    ///   14.554 kick 尾笔写回 430x737 → 14.556 就显窗 → 14.778 自查才读到
    ///   「内容宿主 430x737 已贴合」 —— 中间那 220ms 展示的是按旧尺寸排好的画面，
    ///   这就是用户看到的那一下闪。四条 App 全部复现（+234~+249ms）。
    ///
    /// 判据直接用 0.2.60 断层自查的同一条（内容宿主尺寸不再大于画布），不新造口径。
    /// 纪律：**最多等 6 拍（≈360ms）就 fail-open 显形** —— 宁可闪一下，
    /// 也绝不能让窗永远藏着（那是 0.2.76 的「出现→消失→1 秒后再现」）。
    private static func revealWhenContentSettled(sceneHost: AevonSceneHost,
                                                 canvas: CGSize,
                                                 bundleID: String,
                                                 switchTxn: AevonSwitchSession,
                                                 completeReason: String,
                                                 attempt: Int = 0) {
        guard currentBundleID == bundleID else { return }
        guard AevonSwitchCoordinator.shared.isAlive(switchTxn) else {
            AevonLog.info("[窗口] 显形延后中窗已关 → 放弃（\(bundleID)）（AevonContentSettledV284）")
            return
        }
        let host = sceneHost.contentHostSize
        let settled = sceneHost.contentLayoutSettled(width: canvas.width, height: canvas.height)
        if !settled && attempt < 6 {
            if attempt == 0 {
                AevonLog.info("[窗口] 内容宿主还没按画布排完（宿主 \(Int(host.width))x\(Int(host.height))"
                    + " vs 画布 \(Int(canvas.width))x\(Int(canvas.height))）→ 显形延后，每 60ms 复查一次"
                    + "（最多 6 拍后 fail-open）（AevonContentSettledV284）")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                revealWhenContentSettled(sceneHost: sceneHost, canvas: canvas, bundleID: bundleID,
                                         switchTxn: switchTxn, completeReason: completeReason,
                                         attempt: attempt + 1)
            }
            return
        }
        AevonLog.info("[窗口] 内容已定稿（宿主 \(Int(host.width))x\(Int(host.height))，"
            + "第 \(attempt) 次复查）→ 显形（AevonContentSettledV284 AevonNoPlaceholderV286）")
        /* V0.2.86（AevonNoPlaceholderV286）：这里原本紧跟一句 settleReopenPlaceholder()
         * —— 把上一关的旧帧 crossfade 掉。窗从出生起就 alpha=0（AevonNoFlashBirthV286），
         * 淡入时看到的**已经是活画面**，旧帧从头到尾没露过面，再 crossfade 只是让画面
         * 从「活」变成「旧再变活」= 新的闪。整条占位图链一起退役。 */
        currentView?.revealEntryNow("画布定稿回调（AevonRevealEventV271 AevonRevealLateV269 AevonNoShroudV283 AevonNoPlaceholderV286）")
        AevonSwitchCoordinator.shared.complete(switchTxn, reason: completeReason)
    }

    static func title(for bundleID: String) -> String {
        // V0.2.62（AevonQuickActionV262）：截图 / 录屏是圆盘里的动作槽，不是 App。
        if let action = AevonQuickAction.title(for: bundleID) { return action }
        return AevonAppInfo.displayName(bundleID: bundleID) ?? bundleID
    }

    /// 把浮窗提到最前（主窗恒在最前，停靠窗按点击顺序提到列内最前）。
    static func bringToFront(bundleID: String) {
        if let view = currentView, currentBundleID == bundleID {
            view.bringToFront()
            return
        }
        if let index = dockedViews.firstIndex(where: { $0.bundleID == bundleID }) {
            let view = dockedViews.remove(at: index)
            dockedViews.append(view)
            view.superview?.bringSubviewToFront(view)
            relayoutDock(side: view.dockedSide)
        }
    }

    /// 为指定 App 开窗（带场景就绪等待与全路径守卫，任何失败都静默放弃）。
    ///
    /// 单窗语义：已经有窗且装的是别的 App → 先关掉旧窗再开新窗；装的是同一个 App
    /// → 直接置顶，不重复开。
    static func open(bundleID: String,
                     sceneID: String?,
                     warmupFullscreenFirst: Bool = false,
                     completion: ((Bool) -> Void)? = nil) {
        guard AevonPrefs.bool("Enabled", default: true) else {
            AevonLog.warn("[窗口] 插件未启用，忽略开窗请求")
            completion?(false)
            return
        }
        // V0.2.91（AevonCloseReviveV291）：记录「被这次开窗覆盖的全屏 App」。
        // Aevon(60) 视频逐帧 + 日志对齐实锤：抖音全屏 → 圆盘开浮窗 → 关浮窗 →
        // 抖音 100% 卡死（17:09:05 关窗 → 17:09:18 杀进程，13 秒画面静止 + 手势全灭）。
        // 机制 = presenter 销毁后，被覆盖 App 的场景**没有人重新激活**（渲染停 + 场景
        // 失活）；「全屏出现兜底」只认「场景出现」事件，关窗时不触发 → 必须关窗时
        // 主动唤醒。这里在开窗第 0 拍记录前台全屏 App（此刻 B 的场景还没出现，
        // currentForegroundBundleID 仍指向被覆盖者），关窗时对它补两轮前台唤醒。
        let coveredNow = AevonEntryHost.currentForegroundBundleID
        if coveredNow.isEmpty || coveredNow == bundleID {
            coveredFullscreenBundleID = ""
        } else {
            coveredFullscreenBundleID = coveredNow
            AevonLog.info("[窗口] 记录被覆盖 App：\(coveredNow)（本窗承载 \(bundleID)，"
                + "关窗时唤醒）（AevonCloseReviveV291）")
        }
        // V0.2.66（AevonCleanSlateV266，用户 Aevon(39) #3「多次开关主悬浮窗后有概率黑屏」）：
        // 开窗前把「还没收干净的上一扇窗」扫一遍 —— 上一次 teardown 若被开窗打断
        // （连续快开快关），旧窗视图可能残留在入口容器上（alpha 0 的入场窗尤其看不见、
        // 摸不着、也不报错），新窗一盖上去就是一块黑。这里开窗前统一清扫。
        enforceSingleMainWindow(reason: "开窗清扫 \(bundleID)", incomingBundleID: bundleID)

        // V0.2.50（AevonDockColumnV250）：目标 App 正在停靠列里 → 不重新开窗，
        // 直接把它装回主窗（同一个 presenter，画面不中断）。
        if dockedViews.contains(where: { $0.bundleID == bundleID }) {
            AevonLog.info("[窗口] \(bundleID) 正在停靠列里 → 装回主窗（不重复开窗）（AevonDockColumnV250）")
            restoreDocked(bundleID: bundleID)
            completion?(true)
            return
        }
        if let existingID = openBundleID {
            if existingID == bundleID {
                AevonLog.info("[窗口] \(bundleID) 已在浮窗里，直接置顶（单窗模式）（AevonSingleWindowV105）")
                currentView?.bringToFront()
                completion?(true)
                return
            }
            AevonLog.info("[窗口] 单主窗语义：\(existingID) 转成停靠小窗（不关掉），"
                + "\(bundleID) 占用主窗（AevonSwapDockV264）")
            let rightColumn = dockedViews.filter { $0.dockedSide == .right }.count
            let leftColumn = dockedViews.filter { $0.dockedSide == .left }.count
            let side: AevonDockSide = rightColumn <= leftColumn ? .right : .left
            if !dockCurrent(side: side, force: true), !dockedViews.contains(where: { $0.bundleID == existingID }) {
                AevonLog.warn("[窗口] \(existingID) 转停靠失败 → 只能关掉它（AevonSwapDockV264）")
                close(bundleID: existingID)
            }
        }
        // V0.2.49（AevonCloseSettleV249）：这个 App 若刚被关窗、正等着挂起，先撤销 ——
        // 否则 0.75 秒后它会在浮窗里被挂起（画面停住 / 断层）。
        cancelPendingSleep(bundleID: bundleID)

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
        // V0.2.49（AevonAppScreenFitV249）：**先置位「浮窗里装的是谁」，再唤醒场景**。
        // App 侧 0.2.49 起在浮窗承载期间把 `UIScreen.main.bounds` 报成画布尺寸
        // （这是抖音分享面板 / 视频区按小胖屏重排的唯一办法），生效判据就是这条信号。
        // 若等唤醒之后再写，App 的**第一遍布局**（画布刚变那一刻）读到的还是整屏尺寸
        // → 又回到「要等 1.5 秒 / 上滑一下才重排」。所以顺序是：置位 → 唤醒 → 改画布。
        AevonPrefs.set("AevonFloatBundle", bundleID)
        lastFloatCanvasBundle = bundleID   // V0.3.1（AevonKickSkipV301）记账：这个 App 的画布被改过
        // 同一条信息再发一份到共享内存 —— 沙盒最严的 App（抖音）读不到 com.Aevon 域，
        // 而它正是最需要「UIScreen = 画布」的那个 App。
        AevonNotifySetFloatStage(bundleID)
        AevonForegroundManager.shared.add(bundleID: bundleID, sceneID: sceneID)
        /* V0.2.79（AevonSwitchTxnV279 + AevonSceneLedgerV279，路线 C「抄记账体系」）：
         * 开窗从这里起变成一笔**显式事务**：
         *   · 账本开账（记下这个 App 的账面：fg/bg/停用原因）；
         *   · 登记期望「我要它前台」—— Hook 层拦不拦系统写 NO，就看这条期望；
         *   · 事务对象串起整条链（唤醒→遮罩→改画布→显窗），并给所有延迟闭包
         *     一个统一失效闸门：关窗即 isCurrent=false，迟到的复查/挂起闭包写不回来。
         * 依据：ScreenCore `SCWSSwitch` 的会话化 + `SCSystemSceneContext` 的前后值记账。 */
        let switchTxn = AevonSwitchCoordinator.shared.begin(bundleID: bundleID, reason: "开窗")
        AevonSceneLedger.shared.open(bundleID: bundleID, sceneID: sceneID ?? "", reason: "开窗")
        AevonSceneLedger.shared.wishForeground(bundleID, reason: "开窗")
        /* V0.2.83（AevonNoShroudV283，用户 Aevon(56)：「我们是否需要摘除之前版本中悬浮窗的
         * 遮罩，并且在 stheno 等逆向数据中并没有明确显示切换悬浮窗时拥有遮罩」+「选中图标后
         * 需要等 2 秒左右才会出现悬浮窗」）—— **两代开窗遮罩全部摘除**。
         *
         * 先回答「要不要摘」：要摘，但理由不是「Stheno 没有」—— 遮罩本来就不是抄来的，
         * 是 0.2.73 为「罩住推前台冒帧」自己加的补丁，之后每一版都在给它打补丁
         * （0.2.74 挪到 presenter 之前 / 0.2.75 提到 wakeUp 之前 / 0.2.82 提到窗口之上）。
         * 真正的问题是它治的是我们**自己制造的**抖动：kickRelayout 的两笔
         *（-1pt → 写回）和主场景改画布都发生在窗口已经可见之后。
         *
         * 代价账（Aevon(56) 12:54:08 与 12:55:31 两段）：
         *   08.117 截图走 _UICreateScreenUIImageWithRotation（整屏快照，同步，几百 ms）
         *   08.118 遮罩盖上 → 用户看到的是**静止的旧画面**
         *   08.293 窗其实已经显形了，但被遮罩盖着 → 用户看不见
         *   08.760 画布定稿才淡出遮罩 → 这时候才「出现」浮窗
         * 也就是「等 2 秒」里至少有 0.6~1.3 秒是遮罩在挡着，而且每次都白做一次整屏截图。
         *
         * 摘掉之后怎么保证不闪：把「显形」从「创建窗口时」推迟到「画布定稿回调」——
         * kick 的两笔画布写回都发生在窗还藏着的时候，用户看到的第一次画面就是终态。
         * 见下面 onCanvasSettled 与 revealEntryNow 的调用点。 */
        AevonSceneHelper.wakeUp(bundleID)

        // 开窗失败要把这条信号清掉，否则该 App 的右缘识别器会一直处于「浮窗里」的
        // 退让状态（全屏时右缘呼不出圆盘），同时 UIScreen 也会一直报画布尺寸。
        let clearFloatMarkIfNeeded = {
            if AevonPrefs.string("AevonFloatBundle") == bundleID, currentView == nil {
                AevonPrefs.set("AevonFloatBundle", "")
                AevonNotifySetFloatStage("")
            }
        }

        // V0.3.24（AevonOpenSingleFlightV324，用户 Aevon(98) #3「主悬浮窗有概率黑屏，
        // 并且同时出现两个黑屏的主悬浮窗」）：**开窗单飞**。
        //
        // 病根：open() 从入口到 `currentView = windowView` 之间隔着 asyncAfter（场景快门）
        // 与场景准备。这段窗口里 `currentBundleID` 仍是旧值/nil，若再触发一次开窗
        //（圆盘连点两个图标、呼盘后立刻再呼、图标双击），两次 open 都会走到创建视图那一拍，
        // host 上就出现两扇窗：后者覆盖 currentView，前者变野窗；两扇又各自持一个 presenter
        // 去抢同一个 FBScene —— 谁都拿不到远程层，于是「两个黑屏的主悬浮窗」。
        //
        // Stheno 对照：SCFloatingSceneManager 有 __sessionsByBundleID / __hostingScenePointers
        // / __hostingSceneIdentifiers 三张表 + sc_reconcileSingleActiveWindowKeepingSession:
        // / sc_enforceFloatingWindowLimit / sc_evictOldestSessionForIncomingWindowIfNeeded，
        // 语义就是「后到者作废先到者」。这里用单调 token 等价实现：每次真正要建窗时自增，
        // 闭包里对不上就是过期链，一律中止（不改任何状态、不建视图）。
        openingToken &+= 1
        let myToken = openingToken
        openingBundleID = bundleID

        // 等待场景就绪后再承载
        // ── V0.2.95（AevonSceneFastGateV295）：0.2.49 的固定 0.15s 保守延迟退役 ──
        // Aevon(72) 六次开窗全部白付这 0.15s：走到这里之前「场景已就绪」poll 已经
        // 确认场景存在，固定延迟违反 SCWSSwitch 事务纪律（deadline+poll，从不固定
        // 延迟）。场景已就绪 → asyncAfter(0) 下一拍直通；未就绪才保留 0.15s 兜底。
        var gateScene = AevonSceneHelper.scene(for: bundleID)
        if gateScene == nil, let sid = sceneID {
            gateScene = AevonSceneHelper.scene(for: sid)
        }
        let gateDelay: TimeInterval = gateScene != nil ? 0 : 0.15
        AevonLog.info("[窗口] 开窗快门：\(bundleID) 场景\(gateScene != nil ? "已就绪 → 0 延迟直通" : "未到 → 0.15s 兜底延迟")（AevonSceneFastGateV295）")
        DispatchQueue.main.asyncAfter(deadline: .now() + gateDelay) {
            // V0.3.24（AevonOpenSingleFlightV324）：过期链一律中止（后一次开窗已接管）
            guard myToken == openingToken else {
                AevonLog.info("[窗口] 开窗链已过期（\(bundleID) token \(myToken)≠\(openingToken)）"
                    + "→ 中止，不建视图（AevonOpenSingleFlightV324）")
                completion?(false)
                return
            }
            var scene = AevonSceneHelper.scene(for: bundleID)
            if scene == nil, let sid = sceneID {
                scene = AevonSceneHelper.scene(for: sid)
            }
            guard let scene = scene else {
                AevonLog.warn("[窗口] 未找到 \(bundleID) 的场景，放弃开窗")
                AevonForegroundManager.shared.remove(bundleID: bundleID, sceneID: sceneID)
                clearFloatMarkIfNeeded()
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
            // ── V0.2.95（AevonCapSkipV295）：cap 表只在自建场景开启时才有消费方 ──
            // Aevon(72) 六次开窗事务账实锤：设置/Sileo（cap=0 已落盘）事务段 0.22~0.25s；
            // 微信/酷安/抖音（cap=-1，App 侧从未写 caps.txt）每次开窗白付 0.65s 等表
            //（AevonSelfSceneAppCapWait）+ routeDump 二进制扫描（微信 477MB 实测 ~0.35s），
            // 事务段拉到 0.88~1.24s —— 而这两样唯一的消费方是 routeSelf 判据，
            // 自建场景 0.2.81 起默认关（六次全走 S2），等待结果根本没人读。
            // 整体挪进「自建开启」分支：默认档零成本跳过；路线 B 复活
            //（SelfBuiltScene=YES / SceneRouteForceSelf=YES）时行为与 0.2.80~94 完全一致。
            // 历史标记收容：AevonSceneCapWaitV280 / AevonSceneCapsV241 / AevonSceneRouteV238
            // 原本寄生在被挪动的日志串里，这条无条件日志串给它们保底。
            let selfSceneOn = AevonPrefs.bool("SelfBuiltScene", default: false)
            let forceSelf = AevonPrefs.bool("SceneRouteForceSelf", default: false)
            let capWaitNeeded = selfSceneOn || forceSelf
            var capVerdict = AevonSelfSceneAppCapVerdict(bundleID)
            var routeDump = "自建场景关闭，未做取证扫描"
            if capWaitNeeded {
                // ── V0.2.80（AevonSceneCapWaitV280）：cap=-1 时短轮询，别再把路线 B 判死 ──
                // Aevon(52) 日志实锤断链：SB 侧读到 cap=-1（App 侧明明算出 cap=1，但 0.2.65
                // 起「仅进程内不落盘」）→ `cap==1 || forceSelf` 恒假 → 自建场景全灭 →
                // 19 个版本全挤在 S2（主场景改画布）。S2 必然「整屏渲染 → 跳 430x737」，
                // 这一跳就是用户看到的闪。这里等表：App 刚被拉起时它 +0.2s/+0.6s 才落盘。
                if capVerdict == -1 {
                    capVerdict = AevonSelfSceneAppCapWait(bundleID, 0.65)
                    AevonLog.info("[场景] 能力表等表结束：\(bundleID) cap=\(capVerdict)"
                        + "（等 0.65s 上限；仍 -1 就走 S2，绝不把未知当可自建）"
                        + "（AevonSceneCapWaitV280 AevonCapsPersistV280）")
                }
                AevonLog.info("[场景] 能力登记：\(bundleID) cap=\(capVerdict)（1=scene App 可自建，0=老式必拒，-1=未登记）（AevonSceneCapsV241）")
                routeDump = AevonSelfSceneRouteDump(bundleID)
            } else {
                AevonLog.info("[场景] 能力表跳过：自建场景关闭，0.65s 等表 + 大二进制取证扫描无消费方"
                    + "（Aevon(72) 微信事务段 1.24→约 0.25s 的实测依据）"
                    + "（AevonCapSkipV295 AevonSceneCapWaitV280 AevonSceneCapsV241 AevonSceneRouteV238）")
            }
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
            // V0.2.81（AevonSelfSceneOffV281）：**自建场景默认关闭**。
            //
            // 0.2.80 把路线 B 重新接通后，Aevon(54) 给出六次完整反证：
            //   11:51:14.789 分流 → 自建场景（设置 cap=1）
            //   11:51:14.794 自建场景已创建 画布=430x737
            //   11:51:16.367 连接取证 +1.5s：client=FBWorkspace clientPort=nil
            //   11:51:18.465 连接取证 +3.5s：client=FBWorkspace clientPort=nil
            //   11:51:22.693 App 侧：8 秒内自建场景未连上 App 端 = 连接被 App 端 UIKit 拒绝
            // 六次尝试（设置 ×6）全部同一结果。也就是说：场景**建得出来**，App 端**永远不接**
            // —— 呈现层拿到的只有一个 `_UISceneLayerHostContainerView` 空壳，用户看到的就是
            // 「窗在那儿、里面什么都没有」。cap 判据只看 delegate 有没有实现配置方法，
            // 而真正决定许不许第二场景的是 `UIApplication.supportsMultipleScenes`
            //（单场景 App 恒 NO）。本版 App 侧已把判据收紧成「两个条件都成立」，
            // 同时这里把默认档关掉：**先把画面显示对（回 S2），再谈自建** ——
            // 用户 Aevon(54) 的诉求顺序就是「先修闪和黑屏」。
            // 试验入口仍在：偏好域 SelfBuiltScene=YES 或 SceneRouteForceSelf=YES 都能开。
            // V0.2.95：selfSceneOn / forceSelf 的读取已上移到 cap 等表块之前
            //（AevonCapSkipV295 —— 等表只在它们为真时才执行）。
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
            // V0.2.80（AevonSelfSceneLearnV280）：失败过的 App 不再走自建（学习式降级）
            let selfSceneLearnedBad = AevonSelfSceneLearn.shared.hasFailed(bundleID)
            let routeSelf = selfSceneOn && !screenAspectOn && !selfSceneLearnedBad
                && (capVerdict == 1 || forceSelf)
            let routeMain = !routeSelf && (screenAspectOn || mainResizeOn)
            let routeName = routeSelf
                ? "自建场景"
                : (screenAspectOn ? "整屏等比缩放（屏幕比例档）" : (routeMain ? "主场景改画布(S2)" : "全屏接管旧路径"))
            AevonLog.info("[场景] 分流：\(bundleID) cap=\(capVerdict) 档=\(forceSelf ? "S1 试验（强制自建）" : "自动") → \(routeName)"
                + (selfSceneLearnedBad ? "（该 App 上次自建连接未建立，已降级）" : "")
                + (selfSceneOn ? "" : "（自建场景默认关：Aevon(54) 六次 clientPort=nil 实锤，先保画面）")
                + "（S2 主场景改画布已定档常开，设置页开关已移除）"
                + "（AevonSceneRouteV242 AevonScreenAspectV244 AevonMainSceneFixedV248"
                + " AevonCapsPersistV280 AevonSelfSceneLearnV280 AevonSelfSceneOffV281）")
            if !routeSelf && capWaitNeeded {
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
                    //
                    // V0.2.54（AevonReassertGuardV254，用户 Aevon(28)「开过一次浮窗，
                    // 系统手势失效只能点屏幕」）：三拍是裸 asyncAfter，**关窗不撤销** ——
                    // 用户 3 秒内关窗（底边双击是常态操作）时，+1.2s/+3.0s 两拍会落在
                    // 「自建场景已销毁」**之后**，对已销毁 FBScene 继续写
                    // updateSettings{foreground=YES, deactivationReasons=0}
                    // （Aevon(28) 日志 19.920「已销毁」→ 19.980「+1.2s 已提交」铁证）。
                    // 这是关窗后唯一还在碰 FrontBoard 场景状态机的路径：场景已不存在，
                    // 这笔幽灵更新会把场景呈现/激活状态卡住 → 主屏翻页、上滑回桌面、
                    // 通知中心/控制中心这些**系统手势**（全部经场景呈现层判定）失效，
                    // 而普通点按走 hit-test 直达图标，不受影响 —— 与用户症状逐字吻合。
                    // 修法：弱持有 + 开火前核对登记表身份。关窗已注销登记 / 已换新场景
                    // （快速关开）→ 直接哑火；停靠不注销登记，行为不变。
                    for delay in [0.3, 1.2, 3.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak hostScene] in
                            guard let hs = hostScene,
                                  AevonSceneHelper.selfScene(for: bundleID) === hs else { return }
                            let ok = AevonSelfSceneReassertForeground(hs)
                            AevonLog.info("[场景] 重申自建场景前台（+\(delay)s，\(ok ? "已提交" : "失败")）（AevonSelfSceneFGV232 AevonReassertGuardV254）")
                        }
                    }
                    // V0.2.35（AevonSceneRouteV235）：连接取证（只读）。
                    // client 非空 = App 端已连上 FB 层；恒空 = 分流误判（有 manifest
                    // 仍被拒）或连接更早环节被卡 —— 下一版按这串定界。弱引用：场景
                    // 先销毁时自动跳过，绝不摸悬挂对象。
                    for delay in [1.5, 3.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak hostScene] in
                            guard let hs = hostScene else { return }
                            let state = AevonSelfSceneConnectionState(hs) ?? ""
                            AevonLog.info("[场景] 连接取证（+\(delay)s）：\(state)（AevonSceneRouteV235）")
                            // ── V0.2.80（AevonSelfSceneLearnV280）：学习式降级 ──────────
                            // cap=1 是历史对齐的判据，但真机仍会被 App 端拒
                            //（连接永远不建立 = 画面黑）。这里把「连不上」记进内存黑名单，
                            // **下次**开同一个 App 直接走 S2（不再黑第二次）。
                            // 只在本进程生命期内有效，SB 重启自动清空 —— 不落盘、不污染。
                            //
                            // V0.2.81（AevonLearnFixV281）：判据串写错过一次 ——
                            // 实际输出是 `client=FBWorkspace clientPort=nil`，
                            // 0.2.80 判的是 `client=nil`（永远不命中），于是设置的六次
                            // 自建失败一次都没被记进黑名单、每次都重试。改判 clientPort。
                            if delay == 1.5, state.contains("clientPort=nil") {
                                AevonSelfSceneLearn.shared.markFailed(bundleID)
                                AevonLog.warn("[场景] 自建场景连接未建立（clientPort=nil）→ "
                                    + "\(bundleID) 下次开窗改走 S2（AevonSelfSceneLearnV280 AevonLearnFixV281）")
                            }
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
            // V0.2.51（AevonDouyinWarmupV251，用户 Aevon(26) #4）：抖音不经「全屏打开
            // 一次」、直接浮窗打开会断层 —— 差别就在 App 进程有没有以整屏画布完成过
            // 第一遍排版。刚由 launchAndOpen 拉起的场景是「生」的：这里先按整屏画布让
            // App 渲染一拍（等价用户先全屏开一次），1.0 秒后再切浮窗画布。
            // V0.2.53（AevonDouyinWarmupFixV253，用户 Aevon(27) #3）：预热只对
            // **主场景路线**有意义 —— 那里的 App 刚被拉起、主场景还是整屏、App 按
            // 整屏排过一拍。真机日志实锤（17:42:31.380）：自建场景路线下这段代码
            // 不进 `!usedSelfScene && routeMain`，mainCanvas 恒为 0x0，1.0s 后把
            // 0x0 写给主场景（失败），且 `!warmupCanvas` 把开窗时的 kickRelayout
            // 也跳了 → 真重排根本没发生 → 抖音断层。0.2.49 正常正因为没有预热。
            // 自建场景的画布在创建时就是 430x737，App 第一遍排版就在小画布上，
            // 不需要也不允许「先整屏一拍」。
            let warmupCanvas = warmupFullscreenFirst && !screenAspectOn
                && !usedSelfScene
            if !usedSelfScene && routeMain {
                // V0.2.43（AevonCanvasScaleV243）：画布 = 窗口 × k（不再等于窗口本身）
                // V0.2.44（AevonScreenAspectV244）：屏幕比例档 → 画布 = 整屏原生尺寸
                let windowSize = AevonWindowView.plannedContentSize()
                let size = AevonWindowView.canvasSize(for: windowSize)
                let expected = "frame=\(Int(size.width))x\(Int(size.height))"
                let stateNow = AevonMainSceneFrameState(scene) ?? ""
                if warmupCanvas {
                    // 预热：不写小画布（场景此刻本来就是整屏），mainCanvas 仍记小画布
                    // —— 复查与后续流程都认它；真正的切换在 +0.30s 那一拍做（0.2.90）。
                    mainResized = true
                    mainCanvas = size
                    // V0.2.62（AevonWarmupForegroundV262，用户 Aevon(36) #8「抖音刚打开
                    // 真重排了，一秒后内容上移、下面黑」）：预热一直形同虚设的真因 ——
                    // Aevon(36) 日志 11:06:42.453 明确写着 `frame=430x932 fg=0 cs=2`：
                    // 画布是整屏没错，但 **fg=0 = 场景根本没在前台**，App 不会渲染，
                    // 所谓「先按整屏渲染一拍」这一拍从来没发生，切到 737 时抖音拿到的
                    // 还是它自己缓存的旧布局 → 内容上移 + 底部黑。
                    // 修法：预热期把主场景推一次前台（presenter 已激活，不会真上屏），
                    // 让它真的按整屏渲染一帧，再切画布 —— 这才是用户说的「先全屏开一次」。
                    AevonSceneHelper.setForeground(scene, true)
                    AevonLog.info("[场景] 画布预热：\(bundleID) 先按整屏画布**推前台**渲染一拍"
                        + "（fg 必须为 1，否则预热等于没做），0.30 秒后切浮窗画布 "
                        + "\(Int(size.width))x\(Int(size.height))（AevonDouyinWarmupV251"
                        + " AevonWarmupForegroundV262 AevonWarmupSoloV290）")
                } else if screenAspectOn && stateNow.contains(expected) {
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

            /* V0.2.83（AevonNoShroudV283）：这一段的第二代遮罩（tag 0xAE274，无占位帧时
             * 现场抓一张整屏快照盖住 presenter 冒帧）随 0.2.73 的第一代一起摘除。
             *
             * 顺带削掉一次**多余的整屏截图**：原来一次再开窗最多会截两张整屏
             *（入口 0.2.75 一张 + 这里一张），`_UICreateScreenUIImageWithRotation` 是
             * 同步调用、几百毫秒，全部记在用户「等 2 秒」的账上。现在只剩占位帧
             * （关窗时缓存的那一张，零成本）。
             *
             * 没有占位帧时不显形、不截图 —— 等画布定稿回调再淡入（见 onCanvasSettled）。 */
            var reopenPlaceholder: UIImage?
            if !warmupCanvas {
                reopenPlaceholder = reopenPlaceholders.removeValue(forKey: bundleID)
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
                                                 mainResized: mainResized,
                                                 canvasWarmupDelay: warmupCanvas ? 0.30 : 0) else {
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
                clearFloatMarkIfNeeded()
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
            // V0.2.49（AevonRelayoutKickV249）：画布写下去 ≠ App 已重排。
            // 抖音这类深层级 App 往往要等下一次滚动才吃新尺寸（Aevon(24) 原话：
            // 「需要等待 1.5 秒或者上滑一下视频才能完整真重排」）。
            // 这里做一次有界微扰（-1pt → 恢复），强制它多走一遍布局。
            if !warmupCanvas {
                let kickCanvas = AevonWindowView.canvasSize(for: AevonWindowView.plannedContentSize())
                sceneHost.kickRelayout(width: kickCanvas.width, height: kickCanvas.height,
                                       tag: "开窗 \(bundleID)")
            }

            let title = AevonWindowManager.title(for: bundleID)
            let windowView = AevonWindowView(sceneHost: sceneHost, bundleID: bundleID, title: title)
            host.addSubview(windowView)
            host.bringSubviewToFront(windowView)
            /* V0.2.83（AevonNoShroudV283，Aevon(56)）—— 遮罩全部摘除，这里只剩两件事。
             *
             * 【为什么摘】0.2.73 起三代遮罩（0xAE273 预热档 / 0xAE274 入口提前档 /
             * 0xAE274 无占位帧回退档）遮的都是**我们自己制造的抖动**：kickRelayout 的
             * 两笔画布写回、主场景改画布的回弹，全都发生在窗口已经可见之后。
             * 遮罩只是把这些丑盖住，代价是用户什么都看不见 —— Aevon(56) 两段时序账：
             *   08.117 整屏截图（同步，几百 ms）→ 08.118 遮罩盖上 → 08.293 窗其实已显形
             *   但被盖着 → 08.760 定稿才淡出 → 他看到的「等 2 秒」里至少 0.6~1.3 秒是遮罩。
             *
             * 【摘了怎么不闪】把「显形」整体推迟到画布定稿回调（onCanvasSettled）：
             * kick 的两笔、主场景回弹、预热复刻全部发生在 alpha=0 的窗背后，
             * 用户看到的第一个画面就是终态。省下来的还有每次开窗 1~2 次整屏截图。
             *
             * 【垫底图】只用关窗时缓存的最后一帧（零成本、内容正确），
             * **不再现场抓 windowRegionSnapshot** —— 那也是一次同步快照，而且抓到转场
             * 瞬间必判黑（Aevon(56) 12:55:41.744「窗口区域快照判黑（转场瞬间抓帧）」），
             * 抓了也白抓。没有缓存就干脆不铺，等定稿。 */
            /* V0.2.86（AevonNoPlaceholderV286）—— **垫底图整条链退役**（0.2.76/0.2.77/0.2.78 三版）。
             *
             * 它要解决的是「窗已经 alpha=1，但画布还没定稿 → 面板里是空的或旧内容」。
             * 现在窗从出生就 alpha=0（AevonNoFlashBirthV286），根本不存在「可见的空窗」，
             * 垫底图失去意义 —— 留着反而有害：定稿后 0.12s 淡入的是**活画面**，
             * 紧接着 crossfade 把旧帧压上来再淡出，用户看到的就是「先新的、又旧一下、再新」
             *（Aevon(59) 说的「闪一下悬浮窗，然后再出现最终悬浮窗和内容」）。
             * 顺带省掉关窗时那一次同步整屏截图（placeholderSnapshot）。
             *
             * 变量 reopenPlaceholder 与缓存字典保留但不再写入 —— 便于日后回滚时对照。 */
            windowView.alpha = 0
            /* V0.2.85（AevonRevealPlainV285）：**不再预置 0.965 缩放**。
             * 原来这里压一个缩放，等显形时再弹回 1.0 —— 摘掉遮罩以后，这段缩放
             * 就是用户看到的「闪一下悬浮窗」（Aevon(58)：窗先小一号出现、再变大、
             * 内容才到位）。藏着的窗不需要任何视觉参数，位置与尺寸从第一帧就是终态。 */
            windowView.transform = .identity
            if reopenPlaceholder != nil {
                _ = AevonSwitchCoordinator.shared.mark(switchTxn, "铺垫底图已退役", phase: .revealing)
                AevonLog.info("[窗口] 有旧帧缓存但不再铺（窗出生即隐形，垫底图已退役）"
                    + "（AevonNoPlaceholderV286）")
            } else {
                AevonLog.info("[窗口] 无占位帧 → 不铺垫底图、不截图，窗出生即隐形，等画布定稿再淡入"
                    + "（AevonNoShroudV283 AevonNoPlaceholderV286 AevonNoFlashBirthV286）")
            }
            /* V0.2.64（AevonFloatTransitionV264，用户 Aevon(38) #3「动画更流畅真实，
             * 而不是突然出现的」）：开窗补一段入场动画 —— 淡入 + 从 0.965 弹到 1.0。
             * 之前是 addSubview 之后 alpha 直接就是 1，视觉上「啪」地出现一块窗。
             *
             * **V0.2.77（AevonRevealOnceV277）**：这段「先藏着」的 alpha 复位已经
             * 上移到 addSubview 之后紧邻的位置（必须早于占位显形，否则会把刚显形的
             * 面板又压回 0 —— 0.2.76 的「出现 → 消失 → 1 秒后再现」就是这么来的）。
             * 这里只剩日志与兜底，不再动 alpha。 */
            AevonLog.info("[窗口] 开窗入场：\(bundleID) 立刻显形（垫底图打底），画布定稿后"
                + "crossfade 到活画面 + 0.965→1.0 弹簧 0.34s"
                + "（AevonFloatTransitionV264 AevonEntryRevealV265 AevonRevealOnceV277）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak windowView] in
                // V0.3.24（AevonOpenSingleFlightV324）：这条兜底也必须过单飞闸 ——
                // 两次开窗交错时，先到的那条会在 1.3s 后把**已被新链取代**的窗显出来。
                guard myToken == openingToken else {
                    AevonLog.info("[窗口] 兜底显窗跳过（\(bundleID) 开窗链已过期）"
                        + "（AevonOpenSingleFlightV324）")
                    return
                }
                // V0.2.79（AevonSwitchTxnV279）：兜底显窗也要过事务闸门 ——
                // 用户在 1.3 秒内把窗关掉的话，这条闭包以前会把**已经关掉的窗**又显出来。
                guard AevonSwitchCoordinator.shared.isAlive(switchTxn) else {
                    AevonLog.info("[事务] 兜底显窗跳过（\(bundleID) 已关窗）（AevonSwitchTxnV279）")
                    return
                }
                windowView?.revealEntryNow("兜底上限到达")
                AevonSwitchCoordinator.shared.complete(switchTxn, reason: "兜底显窗")
            }
            currentView = windowView
            currentBundleID = bundleID
            lastOpenedAt = CACurrentMediaTime()
            // V0.2.65（AevonEdgeShieldV265）：开窗即发布浮窗矩形，App 侧从第一根手指起
            // 就能判「这一点是不是浮窗的手势区」。
            publishFloatFrame(windowView.frame)
            // V0.2.64（AevonMainAvoidV264）：开窗后若左右某一侧已有停靠列 → 主窗让开那一侧。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                AevonWindowManager.avoidDockColumns(reason: "开窗 \(bundleID)")
            }
            // V0.2.61（AevonDouyinRepairV261，用户 Aevon(35) #9）：开窗 2.2 秒后按画面
            // 自查一次断层（下半截整块黑），命中就做一次「全屏往返」逼 App 重排。
            //
            // V0.2.62（AevonSeamRepairFixedV262，用户 Aevon(36) #8「真重排了一秒后内容
            // 上移、下面黑」）：**画面采样判定被日志证伪** —— Aevon(36) 11:06:43.859
            // 「下半截黑点占比 0.000 → 画面正常」，而用户肉眼看的是断层。原因很简单：
            // drawHierarchy 抓不到跨进程远程表面的像素（0.2.26 已有定论），抓到的是浮窗
            // 自己的底色 → 黑点占比永远是 0。所以「按画面判定」这条路彻底走不通。
            // V0.2.66（AevonNoReplayV266）：非预热档的 2.2s 定时往返同样退役 ——
            // Aevon(39) 里它对设置等 App 只制造一次可见闪（画布 932→737→932→737），
            // 几何自查（healStaleLayoutIfNeeded）继续兜底真断层。
            AevonLog.info("[场景] 开窗定时往返已退役：几何自查继续兜底（AevonNoReplayV266）")            // V0.2.9（AevonFloatStandDownV209）：把「浮窗里装的是谁」写到偏好域。
            // App 侧识别器读它 —— 等于自己的 bundleID 就整体退让（不扣 began、不建失败要求），
            // 浮窗内的滑动才不会被右缘判向延迟到抬手。
            // V0.2.49：已经在进入开窗流程时提前写过一次（App 侧 UIScreen 覆盖要用），
            // 这里再确认一次（幂等），保证「窗口已存在」与「键已置位」同时成立。
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
            // V0.2.91（AevonHomeFreezeV291）：开窗成功 → 刷新过渡哨的开窗豁免窗
            // （1.0s 内的几何变化是画布布局抖动，不是回桌面过渡）并布哨。
            AevonTransitionSentry.shared.lastOpenAt = CACurrentMediaTime()
            AevonTransitionSentry.shared.arm()
            // V0.2.51（AevonDouyinWarmupV251）：预热切换 —— App 已按整屏画布渲染一拍，
            // 现在把画布切到浮窗尺寸并踢一次重排。只在「还是这同一个开窗会话」时执行。
            if warmupCanvas {
                let warmupScene = scene
                // V0.2.62（AevonWarmupFastV262，用户 Aevon(36) #1「圆盘选中图标后要等
                // 1~2 秒才打开浮窗」）：预热 1.0→0.42 秒。日志里首帧在拉起后 **8ms**
                // 就到了（41.545 预热 → 41.553 首帧），1.0 秒纯粹在等空气；再加上
                // 原来 kickRelayout 的 0.45 秒起手，开窗到内容可用要 1.5 秒以上。
                // V0.2.90（AevonWarmupSoloV290，用户 Aevon(63) #1「选中图标后需要等待
                // 2 秒才能出现悬浮窗」）：Aevon(59) 冷开窗时序账（52.328 选中 → 54.112
                // 显形 = 1.78s）：拉起 0.42 + 预热等待 0.42 + 复刻往返尾排 0.72。首帧
                // 8ms 就到、0.42 是纯等待 → 压到 0.30（约 18 帧，足够渲染一拍）。
                // V0.2.91（AevonWarmupPollV291，用户定档「按 Stheno 的步骤重新设置
                // 开窗等待时间」）：**固定 0.30s → 就绪 poll（Stheno 事务纪律）**。
                // SCWSSwitch 的结构 = deadline + poll 就绪 + presentReady，从不固定
                // 延迟；显形闸（AevonContentSettledV284）已经是 poll，只剩预热这一段
                // 还在死等。0.2.90 已实锤 0.30 是纯等空气（首帧 8ms 就到）→ 推前台后
                // 每 30ms 查一次 contentState（cs=2 = 已就绪在画），就绪立即进预热
                // 切换；0.6s（20 拍）deadline fail-open，到点也继续（等价旧固定档，
                // 最坏不变慢）。canvasWarmupDeadline 仍按 0.30 计，防回弹复查在预热
                // 期不补写的保护不变。
                var warmupPolls = 0
                func warmupProceed(via: String) {
                    // currentBundleID 已变 = 窗口已关 / 已换 App（承载器 invalidate 会随之发生）
                    guard currentBundleID == bundleID else {
                        AevonLog.info("[场景] 画布预热切换作废（窗口已关 / 已换 App）（AevonDouyinWarmupV251）")
                        return
                    }
                    let ok = AevonMainSceneSetFrame(warmupScene, Double(mainCanvas.width), Double(mainCanvas.height))
                    AevonLog.info("[场景] 画布预热完成：\(bundleID) 已切到浮窗画布 \(Int(mainCanvas.width))x\(Int(mainCanvas.height))"
                        + "（\(ok ? "已提交" : "失败")，读回 \(AevonMainSceneFrameState(warmupScene) ?? "")，"
                        + "就绪方式=\(via)）"
                        + "（AevonDouyinWarmupV251 AevonWarmupFastV262 AevonKickExactV262 AevonWarmupPollV291）")
                    /* V0.2.71（AevonRevealEventV271，用户 Aevon(43) #5「闪屏，闪好几下」）：
                     * 显窗挂进画布定稿回调（onCanvasSettled），写完才显 —— 画布没定稿
                     * 前用户看不到窗。1.3s 兜底不变。
                     * V0.2.94（AevonRevealOrderFixV294，用户 Aevon(71) #1「冷启动的 app
                     * 很慢超过 2 秒，开过的很快」）：**回调赋值必须先于单笔直写**。
                     * Aevon(71) 实锤：冷启动 txn 1.505/1.498/1.490/2.185s 全走「兜底显窗」
                     * （1.3s 定时），开过的 0.47s 走「画布定稿」。根因 = 0.2.93 把 kick
                     * 双笔（异步 0.12s 起手）换成单笔直写（**同步 fire**）后，writeCanvas
                     * → fireCanvasSettled 那一刻 onCanvasSettled 还是 nil（赋值在 1110 行、
                     * 直写在 1086 行）→ 显形链整条丢失，只能等兜底。开过的 App 走非预热
                     * 路径（赋值先于 fire）所以快——两个数字都与代码结构完全对上。 */
                    sceneHost.onCanvasSettled = { [weak sceneHost] in
                        guard currentBundleID == bundleID, let sceneHost else { return }
                        AevonLog.info("[窗口] 显窗时机 = 画布定稿回调（单笔直写已提交，开窗即终态；"
                            + "历史链 AevonRevealLateV269 显窗+0.85 定时版被本回调取代）"
                            + "（AevonRevealEventV271 AevonRevealOrderFixV294）")
                        /* V0.2.84（AevonContentSettledV284）：定稿回调只代表「画布写完已提交」，
                         * 再补一道「内容宿主已按画布排完」的确认才显形 —— Aevon(57) 实测
                         * 设置 14.556 显窗、14.778 内容宿主才贴合 = 中间 220ms 是旧尺寸画面。 */
                        revealWhenContentSettled(sceneHost: sceneHost, canvas: mainCanvas,
                                                 bundleID: bundleID, switchTxn: switchTxn,
                                                 completeReason: "画布定稿(预热档)")
                    }
                    // V0.2.93（AevonSingleShotCanvasV293，用户 Aevon(62)「依旧不是秒开」
                    // + 用户确认按 Stheno 方案 X）：**kick 双笔退役（预热路径）**。
                    // Stheno SCWSSwitch 提交链 = poll 就绪 → presentReady → commit，结构上
                    // 没有「人为等 App 反应」的第二拍。0.2.49 时代的双笔微扰防的是「App 漏掉
                    // 第一次尺寸变化」——那时预热固定 1.0s、切画布与首帧渲染挤在一起；现在
                    // poll 就绪（cs=2 整屏已在画）才切画布，App 必然收到完整 size change，
                    // 防回弹复查（0.35/1.2/2.5 三拍）与 2.2s 断层自查兜底都在。
                    // Aevon(62) 账目：txn 0.560s 里 kick 双笔占 0.30s → 单笔后预期 ≈0.30s。
                    sceneHost.writeCanvasDirect(width: mainCanvas.width, height: mainCanvas.height,
                                                tag: "预热切换 \(bundleID)")
                    /* V0.2.67（AevonWarmBounceV267，用户 Aevon(40) #5「抖音真重排速度
                     * 没有上一版快，会显示几秒断层才自动真重排」）：0.2.66 把预热复刻
                     * 往返整建制退役（当时它在窗口显出**之后**跑 = 必闪一下）。现在把
                     * 往返挪回窗口还藏着的时候做。
                     * V0.2.90（AevonWarmupSoloV290，用户 Aevon(63) #1「圆盘选中图标后
                     * 需要等待 2 秒才能出现悬浮窗」）：**预热隐形复刻二次往返退役**。
                     * Aevon(59) 冷开窗时序实锤（52.328 选中 → 54.112 显形 = 1.78s）：
                     * 预热本体（整屏推前台渲染一拍 → 切画布）已经是那一次「全屏打开
                     * 一次」的模拟，紧随其后的复刻往返（+0.12 起手 → 写回 → 再踢一条
                     * kick 链，尾笔 54.106 才落）把定稿回调拖慢 0.24 秒，纯属重复劳动。
                     * 真重排交给预热切换 kick 链（429x736 微扰）；真断层仍有 2.2s
                     * 断层自查兜底（WindowView 侧全屏往返保留）。
                     * V0.2.94（AevonRevealOrderFixV294）：旧版「先直写、后赋回调」的两段
                     * 已合并重排 —— 回调赋值在前（同步 fire 才有人接）、单笔直写在尾。 */
                    // 历史标记收容位（SeamRepairFixedV262/NoReplayV266/WarmBounceV267/
                    // WarmupSoloV290 的二进制锚），语义已并入上方注释，串本体保留：
                    AevonLog.info("[场景] 预热隐形复刻退役：预热本体已含「整屏 → 画布」往返，"
                        + "不再二次往返、kick 尾笔即定稿即显"
                        + "（AevonSeamRepairFixedV262 AevonNoReplayV266 AevonWarmBounceV267"
                        + " AevonWarmupSoloV290）")
                }
                func warmupPoll() {
                    warmupPolls += 1
                    guard currentBundleID == bundleID else {
                        AevonLog.info("[场景] 画布预热切换作废（窗口已关 / 已换 App）（AevonDouyinWarmupV251）")
                        return
                    }
                    let cs = Int(AevonSceneContentState(warmupScene))
                    if cs == 2 {
                        AevonLog.info("[场景] 预热就绪 poll：第 \(warmupPolls) 拍 cs=2（整屏已在画）"
                            + " → 立即切画布（AevonWarmupPollV291）")
                        warmupProceed(via: "poll第\(warmupPolls)拍就绪")
                    } else if warmupPolls >= 20 {
                        // 20 拍 × 30ms = 0.6s deadline：fail-open，等价旧固定档
                        AevonLog.warn("[场景] 预热就绪 poll 到 deadline（\(warmupPolls) 拍，cs=\(cs)）"
                            + " → fail-open 继续（等价旧固定档）（AevonWarmupPollV291）")
                        warmupProceed(via: "deadline fail-open")
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { warmupPoll() }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { warmupPoll() }
            } else {
                // 非预热档：画布在开窗前就已经写好了，但 kick 微扰还有两笔
                //（+0.20 / +0.45）——同样等定稿回调，不再固定 +0.25。
                sceneHost.onCanvasSettled = { [weak sceneHost] in
                    guard currentBundleID == bundleID, let sceneHost else { return }
                    AevonLog.info("[窗口] 显窗时机 = 画布定稿回调（kick 尾笔已写回，开窗即终态）"
                        + "（AevonRevealEventV271 AevonRevealLateV269）")
                    revealWhenContentSettled(sceneHost: sceneHost, canvas: mainCanvas,
                                             bundleID: bundleID, switchTxn: switchTxn,
                                             completeReason: "画布定稿")
                }
            }
            // V0.2.60（AevonDouyinHealV260，用户 Aevon(34) #4）：断层自愈。
            // Aevon(34)：「打开抖音大概率断层（下半部分黑屏），必须多次重开、或者
            // 全屏打开一次并关掉后台卡片才有可能恢复」。成因是 App 没把新画布吃进
            // 布局（画布改了 ≠ 重排完成，0.2.49 已有定论）。这里在踢完重排之后自查
            // 一次：内容宿主仍按整屏排版 → 再踢一次（一次开窗只补踢一次）。
            if sceneHost.mainResized {
                let healAt: TimeInterval = warmupCanvas ? 1.1 : 1.5
                let healWidth = mainCanvas.width
                let healHeight = mainCanvas.height
                DispatchQueue.main.asyncAfter(deadline: .now() + healAt) { [weak sceneHost] in
                    guard currentBundleID == bundleID else { return }
                    sceneHost?.healStaleLayoutIfNeeded(width: healWidth, height: healHeight,
                                                       tag: "开窗 \(bundleID)")
                }
                /* V0.2.65（AevonCenterPresentV265，用户 Aevon(38) #7）：
                 * 抖音进程里没有 App 侧 dylib（日志无任何 Aweme 行），只能在我们自己的
                 * 进程里对呈现层做视觉对中。两次机会：重排踢完之后 / 再晚 0.6 秒。 */
                for delay in [healAt + 0.15, healAt + 0.75] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak sceneHost] in
                        guard currentBundleID == bundleID else { return }
                        sceneHost?.centerStaleContentIfNeeded(canvasSize: mainCanvas,
                                                              tag: "开窗 \(bundleID)")
                    }
                }
            }
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
        // V0.2.62（AevonQuickActionV262）：截图 / 录屏这类动作槽被别处（面板、其他手势）
        // 当 App 调进来时，直接执行动作，绝不去拉起一个不存在的 bundle。
        if AevonQuickAction.isAction(bundleID) {
            AevonQuickAction.perform(bundleID: bundleID)
            completion?(true)
            return
        }
        if isWindowed(bundleID) {
            // V0.2.61（AevonDockRestoreOnPickV261，用户 Aevon(35) #6）：在停靠列里就不是
            // 「置顶」—— 停在角落的 92x158 小窗再怎么置顶也还是小窗，用户要的是**装回主窗**。
            // 0.2.60 这里对停靠态只打了「已在浮窗里，置顶」，于是圆盘再选同一个 App 永远
            // 只能看到角落里那块小窗（Aevon(35) 10:22:28 / 10:22:39 两条日志）。
            if dockedViews.contains(where: { $0.bundleID == bundleID }) {
                AevonLog.info("[窗口] \(bundleID) 在停靠列里 → 装回主窗（圆盘再选 = 还原）"
                    + "（AevonDockRestoreOnPickV261）")
                restoreDocked(bundleID: bundleID)
                completion?(true)
                return
            }
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
        // V0.2.96（AevonScenePollFastV296）：拍间隔 0.4 → 0.1s。Aevon(73) 实锤微信冷启动
        // 「等待 2 次」= 场景在 0.4~0.8s 之间出现，0.4s 拍平均白等 0.2~0.3s；0.1s 拍
        // 把这段等待压到 <0.1s。上限次数 25 → 100（10 秒超时不变）。
        let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
            attempts += 1
            if attempts > 100 {
                AevonLog.warn("[窗口] 等待 \(bundleID) 场景超时（10 秒）")
                timer.invalidate()
                completion?(false)
                return
            }
            if AevonSceneHelper.scene(for: bundleID) != nil {
                timer.invalidate()
                AevonLog.info("[窗口] \(bundleID) 场景已就绪（等待 \(attempts) 次，0.1s 拍）（AevonScenePollFastV296）")
                // V0.2.51（AevonDouyinWarmupV251）：这个场景是刚拉起的「生」场景，
                // App 还没以整屏画布排版过 → 先预热（等价用户先全屏开一次）再切浮窗画布。
                open(bundleID: bundleID, sceneID: nil,
                     warmupFullscreenFirst: true, completion: completion)
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
    // V0.2.76（AevonReopenSwapV276）：再开窗占位帧缓存（bundleID → 上一关最后一帧）。
    // SB 进程内存缓存：关窗抓、再开窗用；SB 重启后自然为空 → 回退 0.2.75 遮罩档。
    private static var reopenPlaceholders: [String: UIImage] = [:]

    /// V0.2.91（AevonCloseReviveV291）：本次开窗覆盖的全屏 App（空串 = 无，桌面开窗）。
    /// 开窗第 0 拍记录、关窗消费；用户在浮窗开着时又全屏拉起了别的 App 的话，
    /// appSceneAppeared 会自动关浮窗走 releaseOnly，不进唤醒分支。
    private static var coveredFullscreenBundleID = ""

    static func close(bundleID: String, releaseOnly: Bool = false) {
        // V0.3.24（AevonOpenSingleFlightV324）：关窗即作废所有在途开窗链 ——
        // 否则 0.6~1.3s 后到达的兜底闭包会把刚关掉的窗又建出来（叠加成两个黑窗）。
        openingToken &+= 1
        openingBundleID = nil
        // V0.2.50（AevonDockColumnV250）：停靠小窗有自己的关闭路径（主窗变量不指向它）
        if currentBundleID != bundleID, dockedViews.contains(where: { $0.bundleID == bundleID }) {
            closeDocked(bundleID: bundleID, reason: "用户关闭停靠小窗")
            return
        }
        guard let windowView = currentView, currentBundleID == bundleID else { return }
        // V0.2.67（AevonFrameGuardV267）：先把「关窗中」钉在窗上再清 0 矩形 ——
        // teardown 的收尾动画 completion 会再进 persistFrame，不钉住就会把矩形复活。
        windowView.isClosing = true
        // V0.2.50（AevonFloatRestoreV250）：关窗收尾要多写一拍整屏画布，
        // 先把这个 App 的主场景抓在手上（teardown 之后 AevonSceneHelper 还能查到，但抓早更稳）。
        let mainScene = AevonSceneHelper.scene(for: bundleID)
        let wasSelfBuilt = windowView.usesSelfScene
        currentView = nil
        currentBundleID = nil
        // V0.2.9（AevonFloatStandDownV209）：浮窗没了 → 清掉「浮窗里装的是谁」，
        // App 侧识别器立刻恢复常态（空串 = 不在浮窗里）。
        AevonPrefs.set("AevonFloatBundle", "")
        // V0.2.49（AevonAppScreenFitV249）：共享内存那份同步清掉 ——
        // App 下一遍布局立刻拿到真实屏幕尺寸（否则关窗后仍按画布排）。
        AevonNotifySetFloatStage("")
        // V0.2.65（AevonEdgeShieldV265）：窗没了 → 让 App 侧的边条吞噬判定立刻失效
        // （留一个 0x0 矩形，App 侧看到宽度 <40 就整段跳过）。
        publishFloatFrame(.zero)
        /* V0.2.86（AevonNoPlaceholderV286）：**关窗不再抓「最后一帧」**。
         * 这里是 `_UICreateScreenUIImageWithRotation` 的一次**同步**整屏截图（几百 ms，
         * 全在主线程）。垫底图链路退役之后没人再读它，留着纯粹是白付这笔钱 ——
         * 而且关窗瞬间正在转场，抓到的经常是过渡帧（0.2.56 日志就有「窗口区域快照判黑」）。 */
        windowView.teardown()
        // V0.2.56（AevonCloseDisarmV256）：窗没了 → 拖拽吞咽状态必须一并解除，
        // 残留 floatTouchID 只会误吞同槽位的新触摸（pan 死、点按活）。
        AevonEdgeEntry.forceDisarmFloatGesture(reason: "关窗 \(bundleID)")
        AevonSceneHelper.stopKeepAlive(bundleID)
        /* V0.2.79（AevonSwitchTxnV279 + AevonSceneLedgerV279，路线 C）：
         * 关窗 = 事务立刻中止 + 账本释放期望。中止是「迟到闭包写脏状态」的根治法 ——
         * 0.2.43 那次「关窗后 +2.5s 的复查闭包又把画布写回小尺寸，导致 App 之后
         * 全屏打开只剩一小块」就是少了这层闸门。释放期望之后，Hook 层不再拦
         * 系统写 foreground=NO（该交还的转场要让它走）。 */
        AevonSwitchCoordinator.shared.abort(bundleID: bundleID,
                                            reason: releaseOnly ? "释放窗口" : "关窗")
        if !releaseOnly {
            AevonSettingsChannel.shared.cancel(bundleID: bundleID)
            AevonSceneLedger.shared.release(bundleID: bundleID, reason: "关窗")
        }
        // V0.2.32（AevonSelfSceneFGV232）：自建场景已随 teardown 销毁，登记必须同步
        // 注销（保活定时器若还查到悬空场景对象会写进已销毁场景）。
        AevonSceneHelper.unregisterSelfScene(bundleID)
        if !releaseOnly {
            // V0.2.49（AevonCloseSettleV249）：**挂起要等还原抖动走完**。
            // Aevon(24)：「关闭浮窗后再打开浮窗，抖音有概率出现断层」；
            // Aevon(23)：「关浮窗后全屏打开设置会黑屏」—— 同一个成因：
            // `invalidate()` 把画布还原成整屏后还有两拍抖动（+0.15s / +0.40s），
            // 而旧代码紧接着就把 App 挂起（sleep），那两拍根本没被执行 → App 留在
            // 「浮窗尺寸的布局」上，下次无论全屏打开还是再开浮窗，看到的都是残局。
            // 现在把 sleep 推迟到 1.05 秒（> 0.40s + 一帧余量 + 第 1 条那次补写），期间若又开窗则取消。
            // 同时把「释放 RBS 保活断言」也一起推迟 —— 断言一旦释放，系统随时可以把
            // App 挂起，那 1 秒的等待就白等了（断言是唯一能按住它的东西）。
            //
            // V0.2.50（AevonFloatRestoreV250）：再多写一拍**整屏画布**。
            // Aevon(25) 第 1 条：「悬浮窗打开过的应用关闭悬浮窗后全屏打开时依旧会黑屏，
            // 只能通过关闭后台卡片重新打开才会恢复」—— 历史档案里同一现象出现过：
            // 「改 keyWindow / 场景尺寸会让 App 真的变成小窗，关窗后残留 → 全屏打开大面积黑屏」。
            // 现在的链路是：关窗还原整屏（0s）→ 抖动（0.15/0.40）→ **App 侧那一刻才收到
            // 「不再是浮窗承载」**（UIScreen 改回真实尺寸）→ App 需要**再一次**尺寸变化
            // 才会按真实屏幕重排。少了这一拍，App 就停在「按 430x737 排版、窗口却 430x932」
            // 的状态里，全屏打开就是黑的，只有杀进程重来才重建。
            // 所以 0.75s（App 侧信号已清）再写一次整屏画布 —— 有界、只一次、只在关窗时。
            // V0.2.100（AevonSuspendDelayV2100，用户 Aevon(77) 抖音 cs=2 卡屏 18s 现场
            // （08:30:00 无前台记录→08:30:18 Aweme cs=2，呼盘 4 次开设置逃生）+ 确认
            // 低风险行为规避实验）：挂起再延 1.0s。现场判读 cs=2 = 进程内死锁，救援闸
            // （cs=1 专用）管不到；嫌疑最大的一笔 = App 刚恢复整屏、还没渲染完新布局
            // 就被 fg=NO 挂起，再唤醒时 UI 死锁。挂起推迟到关窗后 ~2.05s，给 App 完整
            // 渲染窗口；代价仅是多保活 1s，无视觉影响（挂起前后都是最后一帧）。
            scheduleSleep(bundleID: bundleID, after: 2.05)
            // V0.2.91（AevonCloseReviveV291）：关窗唤醒被覆盖的全屏 App —— 两轮
            // setForeground(force)（+0.45s / +0.85s）。等 0.45s 是让 teardown 的
            // 画布还原抖动（0.15/0.40s）先走完，别跟我们的唤醒写入挤在同一拍；
            // force = 绕过记账账本（这是补救路径，0.2.79 的 force 语义）。被覆盖
            // App 的画布我们从未动过（它一直整屏），不需要抖动踢，只要前台。
            // 守卫：用户已又开了别的窗（covered 正被承载）→ 不抢前台。
            // V0.2.92（AevonLaunchReviveV292，Aevon(61) #1「抖音卡死的问题依旧存在，
            // 相同触发方式」）：Aevon(61) 日志实锤两轮 settings 写入都触发了、读回
            // fg=0 —— **裸写 FBScene.settings.foreground 系统不认**（没有
            // transitionContext，FrontBoard 不把它当激活请求；对照报告
            // 《-_didUpdateClientSettingsWithDiff:transitionContext:》）。而用户
            // 「划掉后台从图标重开」100% 能恢复 = **launchApplicationWithIdentifier
            // 这条 SB 官方激活链必然有效**。第 1 轮（+0.45s）改走它（suspended:false
            // = 等价用户点图标，对已存在场景的 App 就是重新激活）；第 2 轮（+0.85s）
            // 保留 settings 写入兜底（第 1 轮已成功的场合被
            // currentForegroundBundleID 守卫拦住，不会重复打扰）。
            let covered = coveredFullscreenBundleID
            coveredFullscreenBundleID = ""
            /* V0.2.98（AevonDeskNoReviveV298，用户 Aevon(75) #3「全屏 app 时开悬浮窗后
             * 返回桌面后，双击关闭悬浮窗后会自己全屏打开刚才退出的 app」+ 日志铁证
             * 21:50:08.852 launch mqq / 21:51:03.046 launch Aweme）：**桌面态免唤醒**。
             * 根因：covered 记录在开窗时落笔（全屏 App 上开浮窗），回桌面时只清了
             * currentForegroundBundleID 没清 covered → 用户回桌面后双击关浮窗，唤醒链
             * 判「covered 没恢复（currentForeground 为空 ≠ covered）」→ launch 把
             * 用户刚刚退出的 App 又全屏拉起。修法：关窗时容器不在任何 App 场景里
             *（appSceneView == nil = 桌面态）→ 被覆盖关系已随回桌面解除（App 退后台
             * 是用户自己的操作），清空 covered 不唤醒。全屏 App 上关浮窗的原修复场景
             *（0.2.91 关窗卡死）不受影响——那时容器正挂在 App 场景视图里。 */
            if !covered.isEmpty, AevonEntryHost.appSceneView == nil {
                AevonLog.info("[窗口] 桌面态关窗 → 不唤醒 \(covered)（回桌面已解除覆盖，用户主动关窗）"
                    + "（AevonDeskNoReviveV298）")
            }
            let reviveTarget = (covered.isEmpty || AevonEntryHost.appSceneView == nil) ? "" : covered
            if !reviveTarget.isEmpty, reviveTarget != bundleID {
                for (delay, round) in [(0.45, 1), (0.85, 2)] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard !isWindowed(reviveTarget) else { return }
                        // 已自行回到前台（用户从图标重新全屏拉起 / 第 1 轮已生效）→ 不再补
                        guard reviveTarget != AevonEntryHost.currentForegroundBundleID else { return }
                        guard let coveredScene = AevonSceneHelper.scene(for: reviveTarget) else {
                            AevonLog.info("[窗口] 关窗唤醒第 \(round) 轮：\(reviveTarget) 场景取不到（已不在后台？）跳过"
                                + "（AevonCloseReviveV291）")
                            return
                        }
                        if round == 1 {
                            let launchSel = Selector(("launchApplicationWithIdentifier:suspended:"))
                            if UIApplication.shared.responds(to: launchSel) {
                                AevonLog.info("[窗口] 关窗唤醒第 1 轮：\(reviveTarget) 走 launchApplicationWithIdentifier"
                                    + "（suspended:false，等价点图标真激活；settings 裸写已证不生效）"
                                    + "（AevonLaunchReviveV292）")
                                AevonRuntime.sendVoid(UIApplication.shared, launchSel,
                                                       reviveTarget as NSString, false)
                                return
                            }
                            AevonLog.info("[窗口] 关窗唤醒第 1 轮：launch 通道不可用 → 退回 settings 写入"
                                + "（AevonLaunchReviveV292）")
                        }
                        AevonSceneHelper.setForeground(coveredScene, true,
                                                       reason: "关窗唤醒被覆盖 App 第\(round)轮",
                                                       force: true)
                        AevonLog.info("[窗口] 关窗唤醒第 \(round) 轮：\(reviveTarget) 已补前台（force，"
                            + "读回 \(AevonMainSceneFrameState(coveredScene) ?? "")）"
                            + "（AevonCloseReviveV291）")
                    }
                }
            }
            if let scene = mainScene, !wasSelfBuilt {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    guard !isWindowed(bundleID) else { return }
                    let screen = UIScreen.main.bounds.size
                    let ok = AevonMainSceneSetFrame(scene, Double(screen.width), Double(screen.height))
                    AevonLog.info("[场景] 关窗收尾：承载信号已清，再写一次整屏画布 "
                        + "\(Int(screen.width))x\(Int(screen.height))（\(ok ? "已提交" : "失败")，"
                        + "读回 \(AevonMainSceneFrameState(scene) ?? "")；"
                        + "App 这一遍布局用的就是真实屏幕尺寸）（AevonFloatRestoreV250）")
                }
            }
        }
        AevonForegroundManager.shared.remove(bundleID: bundleID, sceneID: nil)
        if releaseOnly, let pid = AevonAppInfo.pid(bundleID: bundleID) {
            // 交接给系统全屏拉起：这一刻必须立刻放手，不能拖（FrontBoard 正在接管）
            AevonAssertionShim.releaseKeepAlive(forPID: Int32(pid))
        }
        AevonLog.info("[窗口] \(bundleID) 已关闭\(releaseOnly ? "（交接给系统全屏拉起，未写场景前台标记）" : "")")
    }

    // MARK: - 停靠列动作（V0.2.50，AevonDockColumnV250）

    /// 把当前主窗降级成停靠小窗。
    ///
    /// 用户操作 = 拖主窗贴住左/右边缘松手（26pt 内）。名额只有 5 格，
    /// 满了就把该侧**最早进来的**那个关掉（历史 V0.0.50 定档：一列 5 个）。
    @discardableResult
    static func dockCurrent(side: AevonDockSide, force: Bool = false) -> Bool {
        guard let view = currentView else { return false }
        let bundleID = view.bundleID
        // V0.2.53（AevonDockArbiterV253）：刚装回主窗 0.8 秒内的停靠请求 = 同一次
        // 手势的重复响应（restore 完，另一条路的 .ended 又看见 !isDocked）→ 拒绝。
        //
        // V0.2.63（AevonDockNoVanishV263，用户 Aevon(37) #2「多个停靠小窗切换到主悬浮窗时，
        // 快速点击会自动关掉停靠小窗」）：`force = true` 时跳过这道仲裁 —— 内部
        // 「装回 A 之前先把旧主窗 B 降级」是**我们自己发起的**，不是同一次手势的
        // 重复响应。原来这里被仲裁拒掉后返回 false，上一版又把 false 当成
        // 「降级失败」把 B 直接关掉 → 用户眼里就是「点一下，另一个小窗没了」。
        let now0 = CACurrentMediaTime()
        if !force, bundleID == lastRestoredBundleID, now0 - lastRestoreAt < dockArbiterWindow {
            AevonLog.info("[停靠] \(bundleID) 装回后 \(String(format: "%.2f", now0 - lastRestoreAt))s 内的停靠请求被仲裁吸收"
                + "（同一次手势的重复响应，AevonDockArbiterV253 AevonDockArbiterNarrowV260）")
            return false
        }
        var column = dockedViews.filter { $0.dockedSide == side }
        if column.count >= AevonDock.maxCount {
            if let oldest = column.first {
                AevonLog.info("[停靠] \(side.title)侧 5 格已满 → 先关掉最早那个 \(oldest.bundleID)"
                    + "（AevonDockColumnV250）")
                closeDocked(bundleID: oldest.bundleID, reason: "该侧已满")
            }
            column = dockedViews.filter { $0.dockedSide == side }
        }
        // 主窗位清空（主窗变量归零，停靠窗活在 dockedViews 里）
        currentView = nil
        currentBundleID = nil
        dockedViews.removeAll { $0 === view }
        dockedViews.append(view)
        // V0.2.71（AevonDockSideFirstV271，用户 Aevon(43) #1「已开的悬浮窗有概率不自动吸附，
        // 点边缘吸附会一下出现两个吸附小窗」）：**先钉死 dockedSide 再重排**。
        // relayoutDock 按 dockedSide 过滤，而旧时序里 dockedSide 要等 enterDock 里才写 ——
        // 过滤时用的还是旧值/默认值(.right)：目标侧列过滤为空（Aevon(43) 18:25:20.202
        // 「已吸附到屏幕左侧（该侧现有 0 个）」实锤）→ 窗根本没进目标列（不吸附）；
        // 随后另一侧的 relayout 又把它按旧值扫进那一列（18:25:20.208 BatteryInfo 左刚停、
        // 右侧第 2 格又出现同一个窗）= 双吸附小窗。
        // V0.3.34（AevonDockCoverV334）：**先抓一帧当停靠封面** —— 此刻窗口还是大尺寸、
        // 画面还是活的；一旦 relayout 的 0.22s 动画开始，呈现视图就跟着缩，
        // 抓回来的只会是重采样后的缩略帧。顺序反了（先缩再抓）等于白抓。
        view.installDockCover()
        view.dockedSide = side
        relayoutDock(side: side, animated: true)
        // App 侧「浮窗承载」信号清掉：停靠窗只是一块缩略图，不该再让 App 按画布尺寸
        // 覆盖 UIScreen（那个信号全机只有一份，留给真正的主窗）。
        AevonPrefs.set("AevonFloatBundle", "")
        AevonNotifySetFloatStage("")
        AevonLog.info("[停靠] \(bundleID) 已吸附到屏幕\(side.title)侧"
            + "（该侧现有 \(dockedViews.filter { $0.dockedSide == side }.count) 个，"
            + "尺寸 \(Int(AevonDock.size.width))x\(Int(AevonDock.size.height))，顶部起依次向下）"
            + "（AevonDockColumnV250 AevonDockDropV250 AevonDockSideFirstV271）")
        // V0.2.53（AevonDockArbiterV253）：记录本次停靠，供 0.8s 防抖窗用。
        lastDockAt = CACurrentMediaTime()
        lastDockedBundleID = bundleID
        // V0.2.59（AevonDockStageV259）：停靠集合广播 —— App 侧据此把主窗口交互关掉，
        // 拦掉 backboardd 直投的触摸（点停靠小窗不再触发小窗里 App 的内容点击）。
        publishDockStages()
        /* V0.3.34（AevonDockSleepV334）：封面已就位 → 把场景主动置后台。
         * 停靠小窗不显示实时画面（封面顶住），继续占着前台身份只会和用户正在用的
         * 全屏 App 抢同一个前台位，两边都在 cs 0/1 之间抖 = 小窗黑屏的直接来源。 */
        view.suspendSceneForDock()
        return true
    }

    /// 把某个停靠小窗装回主窗（点它 / 圆盘再选它 / 拖它）。
    ///
    /// 如果主窗里已经有别的 App，先把它降到它现在更靠近的那一侧（不丢窗）。
    static func restoreDocked(bundleID: String) {
        guard let view = dockedViews.first(where: { $0.bundleID == bundleID }) else { return }
        // V0.2.53（AevonDockArbiterV253）：刚停靠成功 0.8 秒内的装回请求 = 同一次
        // 手势的重复响应（真机日志实锤：17:42:34.570 停靠成功 → 34.582 装回主窗，
        // 12ms，全局通道 dock 完、视图层 .ended 又看见 isDocked）→ 拒绝。
        let now0 = CACurrentMediaTime()
        if bundleID == lastDockedBundleID, now0 - lastDockAt < dockArbiterWindow {
            AevonLog.info("[停靠] \(bundleID) 停靠后 \(String(format: "%.2f", now0 - lastDockAt))s 内的装回请求被仲裁吸收"
                + "（同一次手势的重复响应，AevonDockArbiterV253 AevonDockArbiterNarrowV260）")
            return
        }
        let columnSide = view.dockedSide
        if let main = currentView, main.bundleID != bundleID {
            // V0.2.74（AevonDemoteSideFixV274，用户 Aevon(46) #1「吸附停靠时切回主悬浮窗
            // 后会自动乱排序，左右随机吸附」）：降级侧定档。
            // Aevon(46) 日志三连实锤（20:58:32~36）：装回 BatteryInfo 时 Preferences
            // 被降到左（它明明是从右列停靠的）、装回 SileoStore 时 BatteryInfo 降到左、
            // 装回 Preferences 时 SileoStore 降到右 —— 旧判据
            // `AevonDock.side(forDropAt: main.frame)` 按主窗**当前落点**判侧，主窗被
            // 用户拖到哪半屏、前主窗就被挤到哪侧 = 左右随机横跳。
            // 定档：前主窗降回**它自己上次停靠的那一侧**（dockedSide 记忆），列内格位
            // 由 relayoutDock 顶部补齐 —— 用户视觉 = 装回谁、其余小窗在原侧依次补位，
            // 永不横跳。从未停靠过的主窗 dockedSide 默认 .right，与全局默认一致。
            let side: AevonDockSide = main.dockedSide
            AevonLog.info("[停靠] 主窗里还有 \(main.bundleID) → 先把它降到\(side.title)侧，"
                + "把主窗位让给 \(bundleID)（AevonDockColumnV250 AevonDemoteSideFixV274）")
            // V0.2.62（AevonDockNoOrphanV262，用户 Aevon(36) #4「多个吸附小窗时快速点击还原，
            // 会有概率出现多个主悬浮窗，并且无法关闭」）：降级失败（停靠列满 5 格 / 场景
            // 已失效）时原来只是 `_ = dockCurrent(...)` 丢掉返回值 —— 那个窗口既不是
            // currentView、也不在 dockedViews 里，成了一只没人认领的野窗：看着像第二个
            // 主窗，点它没人管、底边双击也轮不到它（因为全局通道只认「当前主窗」）。
            // 降级失败就直接关掉，绝不留野窗。
            //
            // V0.2.63（AevonDockNoVanishV263，Aevon(37) #2）：`force: true` 跳过仲裁，
            // 并且**只在真的没进停靠列时**才关 —— 上一版把「被仲裁拒掉」也当成失败，
            // 快速连点时会把好好的小窗直接关掉（用户看到的就是「小窗自动消失」）。
            if !dockCurrent(side: side, force: true), !dockedViews.contains(where: { $0 === main }) {
                AevonLog.warn("[停靠] \(main.bundleID) 降级失败（停靠列已满 / 场景失效）→ 直接关掉，"
                    + "不留野窗（AevonDockNoOrphanV262 AevonDockNoVanishV263）")
                close(bundleID: main.bundleID, releaseOnly: false)
            }
        }
        dockedViews.removeAll { $0 === view }
        currentView = view
        currentBundleID = bundleID
        lastOpenedAt = CACurrentMediaTime()
        view.leaveDock(animated: true)
        relayoutDock(side: columnSide, animated: true)
        cancelPendingSleep(bundleID: bundleID)
        // 主窗重新拿到承载信号（App 侧 UIScreen 才会改报画布尺寸）
        AevonPrefs.set("AevonFloatBundle", bundleID)
        AevonNotifySetFloatStage(bundleID)
        AevonSceneHelper.wakeUp(bundleID)
        // V0.3.34（AevonDockCoverLiftV334）：场景已推回前台 → 开始判「实时画面真的
        // 回来了没有」，连续 2 拍 cs=2 且过了 0.42s 地板才撤封面（上限 1.5s 必撤）。
        view.beginDockCoverLift()
        if let pid = AevonAppInfo.pid(bundleID: bundleID) {
            AevonAssertionShim.resumePID(Int32(pid))
            AevonAssertionShim.acquireKeepAlive(forPID: Int32(pid))
        }
        AevonLog.info("[窗口] \(bundleID) 已从停靠列装回主窗（画面不中断，未重建场景，"
            + "装回后不再自动避让）（AevonDockColumnV250 AevonRestoreNoAvoidV271）")
        // V0.2.53（AevonDockArbiterV253）：记录本次装回，供 0.8s 防抖窗用。
        lastRestoreAt = CACurrentMediaTime()
        lastRestoredBundleID = bundleID
        // V0.2.59（AevonDockStageV259）：该 App 已离开停靠集合 → App 侧恢复主窗口交互。
        publishDockStages()
        // V0.2.62（AevonDockNoOrphanV262）：装回之后立刻做一次一致性清扫。
        enforceSingleMainWindow(reason: "装回 \(bundleID)")
        /* V0.2.71（AevonRestoreNoAvoidV271，用户 Aevon(43) #2「每次小窗还原时都会自动避让，
         * 改变手动挪动后的位置」）：装回路径的 avoidDockColumns 整建制撤除。
         * 装回 = 几何回到主窗记忆（用户手动摆的位置就在里面），此时再避让等于
         * 每次还原都把主窗从用户摆的位置上推开。避让保留在「开窗」那一拍
         * （AevonMainAvoidV264 语义不变），装回后位置完全归用户。 */
    }

    /// V0.2.62（AevonDockNoOrphanV262）：单窗铁律的兜底 —— 承载层里只许有
    /// 「当前主窗」和「停靠列里的窗」，其它一律视为野窗收掉。
    ///
    /// Aevon(36) #4：多个小窗在列时快速连点，装回路径要先把旧主窗降级（dockCurrent），
    /// 降级失败就会留下第三只窗：它既不响应点击（不是 currentView），也不在停靠列里
    /// （不会重排），用户看到「多个主悬浮窗且无法关闭」。这里按身份做一次清扫，
    /// 与降级成功与否无关 —— 只要谁是野的就关谁。
    static func enforceSingleMainWindow(reason: String, incomingBundleID: String? = nil) {
        guard let host = AevonEntryHost.floatHost else { return }
        let views = host.subviews.compactMap { $0 as? AevonWindowView }
        guard !views.isEmpty else { return }
        /* V0.3.24（AevonOpenDedupV324）：判据从「currentView / dockedViews 名单」改成
         * **按 bundleID 判定**。旧写法的致命处在于它拿状态做真相源，而野窗之所以是野窗，
         * 恰恰因为 currentView 已经漂移（指向后来那扇窗）—— 用漂移后的名单清扫，等于
         * 保护错对象、留下真野窗（用户看到的「两个黑屏主悬浮窗」）。
         * 现在：① 与本次开窗同 bundleID 的视图**无论谁是 currentView** 一律清掉；
         *      ② 既不是主窗、也不在停靠列的孤儿照旧清掉；
         *      ③ 清主窗时同步把 currentView/currentBundleID 置空，避免 open 误判「已在浮窗里」。 */
        /* 只有「同目标 App 在 host 上**不止一扇**」时才算重复。
         * 单扇且就是主窗 → 不动它（这条 open 会走「已在浮窗里 → 置顶」，保持既有行为；
         * 若在这里拆掉，同一 App 再点一次就会变成「拆了重建」= 白闪一下 + 重新加载）。 */
        let incomingCount = incomingBundleID.map { id in views.filter { $0.bundleID == id }.count } ?? 0
        var removed = 0
        var removedDocked = false
        for view in views {
            let isMain = (currentView === view)
            let isDocked = dockedViews.contains(where: { $0 === view })
            let duplicatesIncoming = (incomingCount > 1 && view.bundleID == incomingBundleID)
            let orphan = !isMain && !isDocked
            guard duplicatesIncoming || orphan else { continue }
            if isMain {
                currentView = nil
                currentBundleID = nil
            }
            if isDocked {
                dockedViews.removeAll { $0 === view }
                removedDocked = true
            }
            AevonLog.warn("[窗口] 清理重复/野窗 \(view.bundleID)"
                + "（主窗=\(isMain ? "是" : "否") 停靠=\(isDocked ? "是" : "否") "
                + "同目标=\(duplicatesIncoming ? "是" : "否")）→ 收掉"
                + "（\(reason)）（AevonDockNoOrphanV262 AevonCleanSlateV266 AevonOpenDedupV324）")
            view.teardown()
            view.removeFromSuperview()
            removed += 1
        }
        if removed > 0 {
            AevonLog.info("[窗口] 单窗清扫完成：收掉 \(removed) 扇（\(reason)）"
                + "（AevonDockNoOrphanV262 AevonCleanSlateV266 AevonOpenDedupV324）")
            if removedDocked { publishDockStages() }
        }
    }

    /// 关掉一个停靠小窗（满员挤掉 / 面板关闭 / 插件停用）。
    static func closeDocked(bundleID: String, reason: String) {
        guard let view = dockedViews.first(where: { $0.bundleID == bundleID }) else { return }
        let side = view.dockedSide
        dockedViews.removeAll { $0 === view }
        AevonSceneHelper.stopKeepAlive(bundleID)
        AevonSceneHelper.unregisterSelfScene(bundleID)
        view.teardown()
        // V0.2.56（AevonCloseDisarmV256）：停靠小窗关闭同样强制解除拖拽吞咽状态。
        AevonEdgeEntry.forceDisarmFloatGesture(reason: "关闭停靠小窗 \(bundleID)")
        scheduleSleep(bundleID: bundleID, after: 1.75)   // V0.2.100（AevonSuspendDelayV2100）+1.0s 同主窗路径
        AevonForegroundManager.shared.remove(bundleID: bundleID, sceneID: nil)
        relayoutDock(side: side, animated: true)
        AevonLog.info("[停靠] \(bundleID) 已从停靠列关闭（\(reason)，该侧剩 "
            + "\(dockedViews.filter { $0.dockedSide == side }.count) 个）（AevonDockColumnV250）")
        // V0.2.59（AevonDockStageV259）：该 App 已不在停靠集合 → App 侧恢复交互。
        publishDockStages()
    }

    /// V0.2.59（AevonDockStageV259）：把当前停靠集合广播给各 App 进程。
    /// 幂等：集合没变时 App 侧的状态比对会吸收（只在翻转时动作）。
    private static func publishDockStages() {
        AevonNotifyPublishDockStages(dockedViews.map { $0.bundleID })
    }

    /// V0.2.59（AevonDockStageV259）：SpringBoard 启动时清掉停靠集合的 notify 残留。
    /// notify state 是内核共享内存，SB 重启不会自动清零 —— 上次注销前如果还有停靠窗，
    /// 那几个 App 的进程（若还活着）会一直以为自己「正在停靠」而交互关闭。
    /// SB 启动 = 停靠列必空（视图都没了），直接广播空集合。
    static func clearDockStagesOnBoot() {
        AevonNotifyPublishDockStages([String]())
        AevonLog.info("[停靠] 启动清场：停靠集合广播已复位（AevonDockStageV259）")
    }

    // MARK: - 浮窗存活性心跳（V0.2.84，AevonStaleRectGateV284）
    //
    // 病根（Aevon(57) 日志铁证）：浮窗矩形通道只有「最后已知几何」，**没有存活信号**。
    // notify state 活在 notifyd 里、跨 respring 不消失，floatframe.txt 也在磁盘上 ——
    // 于是 respring 之后浮窗从来没打开过，App 侧照样拿到上一轮的 {{63,160},{336,577}}
    // 去判「这是浮窗手势区」→ 整根丢弃。设置 App 里 13:25:01~13:25:40 共 **44 次点击
    // 被吞、0 次合法吞**（第一次开窗是 13:26:13）：右上角开关 x≈355~399 / y≈148~180
    // 撞「右边带 44pt + 顶带 20pt」，左侧列表 x≈63~107 撞「左边带 44pt」。
    // 用户看到的就是「全屏 App 触摸失效 / 开关点很多次才生效」。
    //
    // 药方两层，缺一不可：
    //   ①**启动即清零**（下面这个函数）—— 把上一轮残留的矩形置 0，App 侧看到
    //     宽度 <40 就整段跳过；
    //   ②**心跳闸门**（startFloatHeartbeat）—— 光清零不够：万一某次关窗路径被打断
    //      （崩溃 / 强杀 / 中途 respring），矩形还会残留。心跳只由 SB 写，App 侧要求
    //     「seq≠0 且 2.5 秒内变过」，拿不到就当作浮窗不存在 → 不吞。
    //     方向永远 fail-open：漏吞的代价是「滑把手带动 App 滚动」，
    //     误吞的代价是「全屏 App 点不动」，后者严重得多。
    private static var floatAliveSeq: UInt64 = 0
    private static var floatHeartbeatTimer: Timer?

    /// 启动清场：把上一轮残留的矩形与心跳一起清零，然后开心跳。
    static func resetStaleFloatGateOnBoot() {
        publishFloatFrame(.zero)
        AevonFloatAlivePublish(0)
        AevonLog.info("[窗口] 启动清场：浮窗矩形已置零、存活心跳已清零"
            + "（上一轮残留的矩形会让全屏 App 出现点击死区）（AevonStaleRectGateV284）")
        startFloatHeartbeat()
    }

    /// 0.5 秒一拍：有窗 → seq++；无窗 → 写 0。
    /// 只写 notify state（不 notify_post、不写文件），每拍成本可忽略。
    private static func startFloatHeartbeat() {
        floatHeartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            if hasAnyWindow {
                floatAliveSeq &+= 1
                AevonFloatAlivePublish(floatAliveSeq)
            } else if floatAliveSeq != 0 {
                floatAliveSeq = 0
                AevonFloatAlivePublish(0)
                AevonLog.info("[窗口] 浮窗已全部关闭 → 存活心跳归零"
                    + "（App 侧从下一拍起不再按浮窗边带吞触摸）（AevonStaleRectGateV284）")
            }
        }
        // .common 模式：滚动 / 转场期间也要跑，否则用户一滑列表心跳就断。
        RunLoop.main.add(timer, forMode: .common)
        floatHeartbeatTimer = timer
        AevonLog.info("[窗口] 浮窗存活心跳已启动（0.5 秒一拍；无窗时写 0；"
            + "App 侧 2.5 秒未见跳动即判浮窗不存在）（AevonStaleRectGateV284）")
    }

    /// 重排某一侧：按加入顺序重新分配 0..n 号槽位（顶部起依次向下）。
    ///
    /// V0.0.50 的历史教训：排序不能用 `frame.minY` —— 动画途中它是中间值，
    /// 会出现「每格错位、1 秒后自愈」。这里直接用数组顺序（加入顺序）当槽位号。
    static func relayoutDock(side: AevonDockSide, animated: Bool = true) {
        let column = dockedViews.filter { $0.dockedSide == side }
        // V0.2.73（AevonDockDiagV273，用户 Aevon(45) #1「吸附停靠会自动乱排序，左右
        // 随机吸附」）：本轮日志没有乱序实锤（只有一次正常的「右侧第 1 格」）——
        // 这里把重排全程摊开：每窗的 dockedSide、目标格位、目标 frame、left/right
        // 两列各几个。复发时直接对出「哪个窗被排错了侧/格」。
        let leftN = dockedViews.filter { $0.dockedSide == .left }.count
        let rightN = dockedViews.filter { $0.dockedSide == .right }.count
        AevonLog.info("[停靠] 重排 \(side.title)列（该侧 \(column.count) 个；全表：左 \(leftN) 右 \(rightN)，"
            + column.map { "\($0.bundleID)=\($0.dockedSide.title)" }.joined(separator: " ")
            + "）（AevonDockDiagV273）")
        for (index, view) in column.enumerated() {
            view.enterDock(side: side, index: index, animated: animated)
        }
    }

    /// V0.2.64（AevonMainAvoidV264，用户 Aevon(38) #2）：主窗避让停靠栏。
    ///
    /// 规则（按用户原话）：
    ///   · 只有某一侧有停靠小窗、另一侧空着时才避让（两侧都有 = 无处可躲，保持原样）；
    ///   · 主窗与那一列**真的重叠**才挪，不重叠不动（避免用户手动摆好后被莫名推开）；
    ///   · 挪的位置 = 贴到另一侧留 8pt 边距，纵向位置保持不变；
    ///   · 避让是一次性的：之后用户手动拖到哪就记哪（`persistFrame` 照常落盘），
    ///     下一次有新停靠时才重新判一次。
    static func avoidDockColumns(reason: String) {
        guard let view = currentView, !view.isDocked else { return }
        let screen = UIScreen.main.bounds
        guard screen.width > 200 else { return }
        let rightCount = dockedViews.filter { $0.dockedSide == .right }.count
        let leftCount = dockedViews.filter { $0.dockedSide == .left }.count
        guard (rightCount > 0) != (leftCount > 0) else { return }
        let slot = AevonDock.size.width
        let occupiedOnRight = rightCount > 0
        var frame = view.frame
        let columnMinX = occupiedOnRight ? screen.width - slot : 0
        let columnMaxX = occupiedOnRight ? screen.width : slot
        let overlaps = frame.maxX > columnMinX + 2 && frame.minX < columnMaxX - 2
        guard overlaps else { return }
        let margin: CGFloat = 8
        if occupiedOnRight {
            frame.origin.x = margin
        } else {
            frame.origin.x = screen.width - margin - frame.width
        }
        frame.origin.x = max(margin, min(frame.origin.x, screen.width - margin - frame.width))
        guard abs(frame.origin.x - view.frame.origin.x) > 1 else { return }
        view.nudgeForDockAvoidance(to: frame)
        let busySide = occupiedOnRight ? "右" : "左"
        AevonLog.info("[窗口] 主窗避让停靠栏（\(reason)）：\(busySide)侧有 "
            + "\(max(rightCount, leftCount)) 个停靠小窗 → 主窗移到 x=\(Int(frame.origin.x))"
            + "（AevonMainAvoidV264）")
    }

    /// V0.2.49（AevonCloseSettleV249）：延迟挂起（等画布还原 + 抖动完成）。
    /// 同一 App 只保留最后一个待执行项；重开这个 App 时先取消
    /// （见 `cancelPendingSleep`），绝不允许「刚开窗又被上一个关窗任务挂起」。
    private static var pendingSleep: [String: DispatchWorkItem] = [:]

    private static func scheduleSleep(bundleID: String, after delay: TimeInterval) {
        pendingSleep[bundleID]?.cancel()
        let work = DispatchWorkItem {
            pendingSleep[bundleID] = nil
            // 期间又被装回浮窗（或装进了停靠列）→ 不挂了（画面在上面），断言留给那一侧
            guard !isWindowed(bundleID) else {
                AevonLog.info("[窗口] \(bundleID) 在挂起前又被装回浮窗 → 取消挂起（AevonCloseSettleV249）")
                return
            }
            // 顺序：先放手（释放 RBS 断言）→ 再挂起。反过来会在「还按着断言」时
            // 挂起，FrontBoard 与 RunningBoard 各持一个立场，容易留下悬挂状态。
            if let pid = AevonAppInfo.pid(bundleID: bundleID) {
                AevonAssertionShim.releaseKeepAlive(forPID: Int32(pid))
            }
            AevonSceneHelper.sleep(bundleID)
            AevonLog.info("[窗口] \(bundleID) 场景已挂起（画布还原与抖动都已完成，再开窗不会断层；"
                + "挂起已延至关窗后 ~2s，防 App 刚恢复整屏就被挂起诱发 UI 死锁）"
                + "（AevonCloseSettleV249 AevonSuspendDelayV2100）")
        }
        pendingSleep[bundleID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func cancelPendingSleep(bundleID: String) {
        guard let work = pendingSleep.removeValue(forKey: bundleID) else { return }
        work.cancel()
        // 任务被撤销 = 这个 App 马上要重新开窗：断言还挂在它身上，这里先放一次，
        // 由 open() 末尾重新获取 —— 不放会留下一条永不释放的保活（App 永远不睡）。
        if let pid = AevonAppInfo.pid(bundleID: bundleID) {
            AevonAssertionShim.releaseKeepAlive(forPID: Int32(pid))
        }
        AevonLog.info("[窗口] 取消 \(bundleID) 的待挂起任务（马上要重新开窗，保活断言转交新窗口）"
            + "（AevonCloseSettleV249）")
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
        // V0.2.50：停靠列一起收（插件停用 / 注销前清理）
        for view in dockedViews {
            AevonSceneHelper.stopKeepAlive(view.bundleID)
            AevonSceneHelper.unregisterSelfScene(view.bundleID)
            view.teardown()
            scheduleSleep(bundleID: view.bundleID, after: 1.6)   // V0.2.100（AevonSuspendDelayV2100）+1.0s 统一语义
        }
        dockedViews.removeAll()
        // V0.2.59（AevonDockStageV259）：集合清空必须广播（notify state 不随清理自动归零）。
        publishDockStages()
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
        // V0.2.50：停靠小窗也要跟着 App 的图层变化重排（否则小窗里画面会停在旧比例）
        for view in allWindows { view.setNeedsLayout() }
    }
}

/// V0.2.50（AevonLockBlockV250）：给 ObjC 锁屏拦截钩子用的「浮窗还在吗」。
///
/// 钩子必须在 ObjC 里（`method_setImplementation` + @try 包住），但它需要的这个判断
/// 只有 Swift 侧知道 —— 用 C 符号桥一下，比在 ObjC 里再维护一套镜像状态安全得多。
@_cdecl("AevonFloatActive")
func aevonFloatActive() -> Bool {
    return AevonWindowManager.hasAnyWindow
}
