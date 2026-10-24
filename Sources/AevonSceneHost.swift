import Foundation
import UIKit

/// 单个 App 场景的承载器（V0.0.10 重写）。
///
/// V0.0.9 的做法是错的，两处都被真机日志证明：
/// 1. 自己 alloc 系统的场景层宿主容器（LayerHostContainerView）再逐个建宿主视图。
///    这个类不会「要求 App 渲染」——客户端从来没收到呈现请求，场景的图层列表
///    永远是空的，所以浮窗只有外壳、里面全黑（日志：约 3 秒没收到任何图层）。
/// 2. 拿不到图层时又去 alloc 呈现管理器（PresentationManager）兜底，初始化失败后那个
///    对象被直接释放，它内部的呈现者持有者（ScenePresenterOwner）没 invalidate，dealloc 抛
///    `NSInternalInconsistencyException ... must be invalidated before it can be deallocated`，
///    在 SpringBoard 里就是自动注销（crash.log 的调用栈底部正是 Timer → 这段兜底）。
///
/// 正确路径（iOS 15–17，参考 LiveContainer / MilkyWay 的做法）：
///   scene.uiPresentationManager
///     → createPresenterWithIdentifier:           申请一个呈现者
///     → modifyPresentationContext: appearanceStyle = 2（只要内容，不要系统装饰）
///     → activate                                  这一步才会让 App 真正开始渲染
///     → presentationView                          把这张视图塞进浮窗
/// 关闭时必须 deactivate + invalidate，否则下次释放就是上面那条异常。
///
/// 上述私有调用全部走 `AevonPresenterShim`（ObjC，@try/@catch），异常不会冒到系统。
final class AevonSceneHost {
    let scene: AnyObject
    let sceneID: String
    let bundleID: String

    /// 屏幕尺寸的普通容器；浮窗只对它做等比缩放，不改它的尺寸。
    let container: UIView

    /// 首次检测到画面时回调一次（用于隐藏「等待画面」提示）。
    var onFirstContent: (() -> Void)?

    private(set) var hasContent = false

    private var presenter: AnyObject?
    private let presentationView: UIView
    private var probeTimer: Timer?
    /* V0.0.79（AevonContentGateV79）：内容触摸的**独立**守护定时器。
     * probe 在出画面两拍后就自己停了（省电），可内容触摸要处理的三件事都发生在之后：
     *   ① 系统在场景激活 / 重连时把 presentationView 改回可交互；
     *   ② Guard 比窗口晚登记（刚拉起的 App）；
     *   ③ 用户在设置里改「浮窗内容可点击」。
     * 所以单独跑 10 秒（20 拍 × 0.5s），每拍重施一遍 + 复检，到点自然收工。 */
    private var contentGateTimer: Timer?
    private var contentGateTicks = 0
    private var ticks = 0
    private var invalidated = false

    /// 用户是否允许浮窗内容接收触摸（设置里的 TouchEnabled）
    ///
    /// V0.0.79（AevonTouchLiveV79）：从 `let` 改成 `var` —— 用户 Aevon(71) 报
    /// 「设置里关掉浮窗内容可点击，内容就完全不接收触摸」。除了那一项本身的效果，
    /// 还有一个真 bug：这个值只在**开窗那一刻**读一次，之后改开关对已经开着的浮窗
    /// 毫无作用（关掉不生效、再打开也不恢复），于是表现成「开关坏了 / 怎么点都点不动」。
    /// 现在由 `refreshContentPref()` 在设置广播与 0.2 秒轮询里实时刷新。
    private var contentInteractiveByPref: Bool = true

    /// V0.0.79（AevonGuardGraceV79）：Guard 存活判定的宽限期。
    ///
    /// Aevon(71) 日志实锤一次误判：22:44:38.767 判 com.apple.Preferences「无 Guard」
    /// （那一秒 App 刚被我们拉起，Guard 还没登记），内容触摸被强制关掉，
    /// 22:44:39.281 复检才恢复 —— 中间这 0.5 秒里用户点浮窗什么都点不动。
    /// 现在判「无 Guard」后先给 1.5 秒宽限，宽限期内照设置走，到期才真的关。
    private var guardGraceDeadline: CFTimeInterval = 0

    /// 宽限期过后仍然没有 Guard → 才算真的没有
    private var guardHardAbsent: Bool {
        guardAbsent && CACurrentMediaTime() >= guardGraceDeadline
    }

    /// V0.0.77（AevonGuardAliveV77）：这个 App 进程里**没有** Guard。
    ///
    /// Aevon(69) 日志实锤：只有 tweak 加载之后新启动的 App 才有注入日志；
    /// 浮窗里的 GitHub（更新前就在跑的老进程）一条都没有。触摸由 presenter 的
    /// UI 连接转发进 App 进程，那边没有 Guard 就没人拦 —— App 自己合成一次点击。
    /// 这种进程只能从宿主侧断掉转发：内容触摸一律关掉，宁可不给滑，也不让点穿。
    private(set) var guardAbsent = false

    /// V0.0.82：无 Guard 的「已知降级」只记一次日志
    private var guardAbsentLogged = false

    /// V0.0.78（AevonContentGateV78）：**宿主请求的**内容交互状态。
    ///
    /// 之前只有 `setContentInteraction(_:)` 把结果往两个视图上一写了事，而
    /// presentationView 是**系统拥有**的视图：场景激活 / 重连 / 重新挂载时，
    /// UIKit 会按自己的意愿把它重新设成 `isUserInteractionEnabled = true`，
    /// 还可能塞进新的交互子视图。一旦翻转，SB 侧又恢复了「触摸 → presenter UI
    /// 连接 → App 进程」的转发，而这条通道不经过 `UIApplication.sendEvent:` 的
    /// 常规判定顺序，Guard 那套吞摸判据未必来得及 —— 于是「小窗轻点还是点穿」。
    /// 所以把「想要的」状态记下来，每次探测都重新施加一遍，翻转本身也记日志。
    private var desiredInteractive = true
    private var enforcementCount = 0

    /// 开关内容的触摸（V0.0.55，AevonDockNoTouchV55）。
    ///
    /// 用户 Aevon(48) 第 4 条：「快速点击停靠小窗切换到主悬浮窗时，依旧会触发 app 内点击操作」。
    ///
    /// 根因不是 Guard 没吞（SB 侧那条全局通道确实吞掉了自己那一份），
    /// 而是浮窗里的内容本身就是一个**真的场景视图** —— 手指压在它上面时，
    /// UIKit 会把触摸通过 presenter 的 UI 连接转发进 App 进程，App 收到
    /// 「按下 + 抬起」就自己合成了一次点击（抖音于是暂停）。
    ///
    /// 停靠小窗根本不需要和内容交互（它的唯一操作是「轻点还原」），
    /// 所以停靠态直接把内容的触摸关掉，从源头断掉转发。
    func setContentInteraction(_ enabled: Bool) {
        desiredInteractive = enabled
        applyContentInteraction(reason: "显式切换")
    }

    /// 把「想要的内容交互状态」施加到实际视图树（V0.0.78，AevonContentGateV78）。
    ///
    /// 只在 `allow == false` 时递归关子树：系统在场景激活后会重建 presentationView
    /// 的下级视图，只关根节点等于没关。
    private func applyContentInteraction(reason: String) {
        /* V0.0.82（AevonMainContentV82）：容器开关只看两件事 ——
         * 「设置里允许内容触摸」+「这是主窗（不是停靠小窗）」。
         *
         * 原来还叠了一条 `!guardHardAbsent`（该 App 进程里没有 Guard 就整块关掉内容），
         * Aevon(74) 现场证明这条的代价太大：GitHub 这类进程暂时拿不到 Guard 时，
         * **主悬浮窗里什么都点不动、也滑不动**，用户会认为整个插件坏了。
         * 而且它并不能真的防住穿透 —— 穿透那一份是 backboardd 直投给 App 的
         * （不经过我们的 presenter），关掉容器根本拦不到它，只是把好用的功能也关掉了。
         * 现在把它降级成一条警告（见下面 guardHardAbsent 分支的日志），内容照常可用。 */
        let allow = contentInteractiveByPref && desiredInteractive
        var flipped = 0
        /* V0.0.80（AevonNoSysViewGateV80）：**只关我们自己的宿主容器，
         * 绝不再去动 `presentationView` / 它的子树。**
         *
         * Aevon(72) 第 2 条：「关闭所有悬浮窗后全屏触摸完全失效，必须回桌面重开 App」。
         * V78 的写法是每 0.5 秒把 `presentationView.isUserInteractionEnabled` 压成 false
         * 并且递归关掉整棵子树。日志里那句「内容触摸被系统重新打开 → 已强制关闭」
         * 恰恰说明**这个 view 是系统在管**：它属于 scene 的呈现层，SpringBoard 自己
         * 显示这个 App 全屏时用的就是同一个呈现视图。我们把它压成 false 之后，
         * 关窗只停掉了定时器、**没有任何代码把 true 写回去** —— App 全屏了，
         * 画面在、触摸全被这个 view 吃掉，只有重开（系统新建一个呈现视图）才恢复。
         *
         * 语义上也不需要在别人的视图上动手：这块内容就在我们的 `container` 里，
         * `container.isUserInteractionEnabled = false` 已经让整棵子树收不到触摸
         * （UIKit 的 hitTest 在拿到 false 时直接返回 nil，不再往下递归）。 */
        if container.isUserInteractionEnabled != allow {
            container.isUserInteractionEnabled = allow
            flipped += 1
        }
        /* V0.0.81（AevonAppGateV81）：内容不接收触摸时，顺带把**整窗触摸门**关上 ——
         * App 进程里那一份 backboardd 直投的触摸也一并丢，停靠小窗被轻点就再也不可能
         * 在 App 里合成点击（Aevon(73) 报的正是这个）。
         *
         * V0.0.82（AevonMainContentV82）：**这扇门的唯一依据改成「这个窗是不是停靠态」**。
         *
         * Aevon(74) 的现场：门是关着的，于是「不穿透了，但主悬浮窗里什么都点不动、也滑不动」。
         * 根因是这里原来用 `!allow` 当依据，而 `allow` 里混了三件事：
         *   ① desiredInteractive —— 真正的「停靠 / 还原」状态（应该管这扇门）；
         *   ② contentInteractiveByPref —— 用户在设置里关掉内容触摸（只该关我们自己的容器）；
         *   ③ guardHardAbsent —— 该进程没有 Guard（同上，只该关容器，别锁整窗）。
         * ②③ 一旦成立，连**主窗**也被整窗锁死 —— 这就是「什么都点不动」。
         * 现在只有 ① 关门：停靠小窗的整块区域本来就不该把触摸给 App（它唯一操作是轻点还原），
         * 主窗永远开门，内容照常可点可滑。
         * 全屏 App 例外照旧：那种情况屏幕主体还是它，绝不能整窗锁死。 */
        let isFullscreenApp = (AevonEntryHost.appSceneIdentity?.contains(bundleID) ?? false)
        let gateBlocked = (!desiredInteractive && !isFullscreenApp)
        AevonSceneHelper.setAppGate(bundleID, blocked: gateBlocked, reason: reason)
        /* V0.0.82：把门的判定依据全量写进日志（限次）—— 上一版只有「开/关」两行，
         * 用户报「点不动」时无法区分是门关了还是容器关了，只能靠猜。 */
        if reason != "每拍复查" && reason != "宽限复检" {
            AevonLog.info("[场景] 内容交互判定：容器=\(allow ? "开" : "关")，整窗门=\(gateBlocked ? "关" : "开")"
                + "（主窗态=\(desiredInteractive)，设置开关=\(contentInteractiveByPref)，"
                + "无Guard=\(guardHardAbsent)，全屏App=\(isFullscreenApp)，依据=\(reason)）"
                + "（\(bundleID)，AevonMainContentV82）")
        }
        // 「设置变更 / 显式切换」两种是用户主动改的，单独记一行，不占强制计数
        if flipped > 0 && reason != "显式切换" && reason != "设置变更" {
            enforcementCount += 1
            if enforcementCount <= 6 || enforcementCount % 20 == 0 {
                AevonLog.warn("[场景] 内容触摸被系统重新打开 → 已强制关闭（第 \(enforcementCount) 次，"
                    + "\(reason)，bundle=\(bundleID)，本轮改动 \(flipped) 处）（AevonContentGateV78 AevonNoSysViewGateV80）")
            }
        }
    }

    /// 把系统呈现视图交还给系统（V0.0.80，AevonNoSysViewGateV80）。
    ///
    /// 两件事：
    ///   ① 修历史遗留 —— V78/V79 可能把这个 view 及其子树压成了
    ///      `isUserInteractionEnabled = false` 且再也没还原（就是全屏点不动的病灶）；
    ///   ② 开窗时先归零，确保我们自己的门控只作用在 `container` 上。
    private func restoreSystemPresentationInteraction(reason: String) {
        var n = 0
        if !presentationView.isUserInteractionEnabled {
            presentationView.isUserInteractionEnabled = true
            n += 1
        }
        n += enableInteractionTree(presentationView, depth: 0)
        if n > 0 {
            AevonLog.warn("[场景] 已把系统呈现视图的交互还原（\(reason)，\(bundleID)，还原 \(n) 处）"
                + "—— 上一版把它压成 false 后没有还原，会让 App 全屏点不动（AevonNoSysViewGateV80）")
        }
    }

    /// 设置里的「浮窗内可直接触摸操作」变了 → 立刻重新算一遍（AevonTouchLiveV79）。
    ///
    /// 关掉时的效果是**明确的**：内容不再接收触摸（不会转发给里面的 App），
    /// 但窗口本身照旧 —— 侧条拖动、底边拖动 / 双击关闭、下角缩放、轻点停靠还原
    /// 全都走容器那一层，不受这里影响。这一点也写进日志，免得下次又怀疑「是不是坏了」。
    func refreshContentPref() {
        let latest = AevonPrefs.bool("TouchEnabled", default: true)
        guard latest != contentInteractiveByPref else { return }
        contentInteractiveByPref = latest
        applyContentInteraction(reason: "设置变更")
        AevonLog.info("[场景] 内容触摸开关已更新：\(latest ? "开（浮窗里可直接操作 App）" : "关（内容不再接收触摸，不会转发进 App；窗口拖动 / 停靠 / 关闭 / 缩放照常）")"
            + "（\(bundleID)，即时生效，AevonTouchLiveV79）")
    }


    /// 递归关掉整棵子树的交互（返回实际改动数量）
    @discardableResult
    private func disableInteractionTree(_ view: UIView, depth: Int) -> Int {
        guard depth < 6 else { return 0 }
        var n = 0
        for sub in view.subviews {
            if sub.isUserInteractionEnabled {
                sub.isUserInteractionEnabled = false
                n += 1
            }
            n += disableInteractionTree(sub, depth: depth + 1)
        }
        return n
    }

    /// 递归打开整棵子树的交互（V0.0.80：修 V78/V79 留下的「全屏点不动」）
    @discardableResult
    private func enableInteractionTree(_ view: UIView, depth: Int) -> Int {
        guard depth < 6 else { return 0 }
        var n = 0
        for sub in view.subviews {
            if !sub.isUserInteractionEnabled {
                sub.isUserInteractionEnabled = true
                n += 1
            }
            n += enableInteractionTree(sub, depth: depth + 1)
        }
        return n
    }

    // MARK: - 真 resize（V0.0.59，AevonTrueResizeV59）

    /// V0.0.57 曾把这条路线整条停用（只改 frame = 只裁渲染视口）。
    /// V0.0.59 按 Mango 实证补齐 displayConfiguration + `setResizesHostedContext:`
    /// 三路杠杆重开 —— 且加了**探测自证**：场景写完之后，呈现视图里 App 的实际
    /// 画布尺寸若没有跟着变成目标尺寸（App 真的重排了），5 秒内自动回退到
    /// 整屏等比缩放（V58 形态），最坏情况 = 上一版行为，绝不会更糟。
    ///
    /// 「场景已按我们的请求改小」的目标尺寸（App 应当按它排版）。
    private(set) var adaptiveContentSize: CGSize = .zero

    /// 探测确认：App 的画布真的变成了 adaptiveContentSize（重排成功）。
    private(set) var contentReflowConfirmed = false

    var isAdaptiveContent: Bool { adaptiveContentSize != .zero && contentReflowConfirmed }

    /// 内容来源尺寸：确认重排后 = 场景逻辑尺寸（scale=1 原生显示）；
    /// 未确认 / 回退 = 整屏（V58 等比缩放路径）。
    var sourceSize: CGSize {
        if isAdaptiveContent { return adaptiveContentSize }
        return UIScreen.main.bounds.size
    }

    /// 请求场景按指定逻辑尺寸重排。bits=0 表示垫片层完全失败。
    ///
    /// V0.0.65（AevonTrueResizeWritesOffV65）：**几何写入整体停用**（运行时开关，
    /// 默认关）。V64 真机实锤：只关 1:1 显示分支不够——frame+dc 仍被写入时
    /// 场景 frame 变成小窗尺寸，而等比缩放分支的基准是整屏 430x932，两者矛盾
    /// = 大部分黑屏 + 左上角残留画面 + 状态栏放大；且 5 秒回退只清内容管线、
    /// 不还原场景 frame，错乱持续到关窗。V58 形态的正确前提 = **场景 frame
    /// 恒整屏**。真重排的 SB 侧通道已被三家逆向 + 三版真机彻底排除（FBScene
    /// 方法表 dump 亦无 resizesHosted 类选择子），剩下的 App 进程路线是独立
    /// 工程 —— 在它落地前，这里绝不碰场景几何。写入代码全部保留在本开关
    /// 之后（历史日志串随之保留，证据通道建立后开关一开即接上）。
    private static let trueResizeWritesEnabled =
        AevonPrefs.bool("TrueResizeWrites", default: false)

    func updateAdaptiveSize(_ size: CGSize, reason: String) {
        guard size.width > 1, size.height > 1 else { return }
        guard Self.trueResizeWritesEnabled else {
            AevonLog.info("[场景] 真重排写入已停用（\(reason)，场景保持整屏，"
                + "显示走整屏等比缩放；App 进程证据通道未建立前不碰场景几何，"
                + "AevonTrueResizeWritesOffV65）")
            return
        }
        let bits = AevonSceneHelper.applyDisplaySize(scene: scene, sceneID: sceneID,
                                                     size: size, floatMode: true)
        if bits == 0 {
            AevonLog.warn("[场景] 真重排请求被垫片拒绝（\(reason)，AevonTrueResizeV59）")
            return
        }
        // V0.0.60（AevonReflowGateV60）硬闸门：displayConfiguration 没写进
        // settings（0x10 未置位）= App 进程拿不到小窗显示配置，**绝不会重排**。
        // 垫片此时也已整单放弃（没写 frame、没推 diff），场景保持整屏 ——
        // 这里直接回退 V58 整屏等比缩放，绝不进入 1:1 分支。
        // （V0.0.59 的「内容放大 + 显示不全」= 探测假阳性 + 只推 frame 的组合：
        //   presentationView 首子视图是我们自己的承载容器，永远等于目标尺寸，
        //   第 1 次探测就假确认，于是 1:1 分支吃到了 430x932 的整屏画面。）
        guard bits & 0x10 != 0 else {
            adaptiveContentSize = .zero
            contentReflowConfirmed = false
            reflowChecking = false
            AevonLog.warn("[场景] displayConfiguration 未能写入场景（\(reason)，"
                + "\(AevonSceneHelper.describeApplyBits(bits, target: size))，"
                + "诊断 \(AevonSceneHelper.displayConfigDiag())）"
                + "—— 场景保持整屏，回退整屏等比缩放（AevonTrueResizeV60）")
            onReflowChanged?()
            return
        }
        adaptiveContentSize = size
        contentReflowConfirmed = false
        reflowCheckTicks = 0
        reflowCheckTarget = size
        reflowChecking = true
        // 探测定时器可能早已停止（首帧确认后就停了）：重启它，确认/回退后自然再停。
        startSyncing()
        AevonLog.info("[场景] 真重排请求已下发（\(AevonSceneHelper.describeApplyBits(bits, target: size))"
            + "，\(reason)，等探测确认，AevonTrueResizeV59）")
        // V0.0.64：首次下发时带出 scene 方法表诊断（找 setResizesHostedContext: 的
        // 正确调用对象 —— Stheno 实锤该选择子存在，但我们手里的 FBScene 不响应）。
        if bits & 0x20 == 0 {
            AevonLog.warn("[场景] 托管上下文开关未被 scene 接受（\(AevonSceneHelper.sceneMethodDiag())"
                + "，AevonReflowAppGateV64）")
        }
    }

    /// 关窗 / 还原：场景恢复整屏（帧+显示配置一起还原）。
    func resetAdaptiveSize() {
        guard adaptiveContentSize != .zero || AevonSceneHelper.adaptiveFrame(for: sceneID) != nil else {
            AevonNotifySetWindowSize(0, 0)
            return
        }
        adaptiveContentSize = .zero
        contentReflowConfirmed = false
        reflowChecking = false
        AevonSceneHelper.restoreSceneFrame(scene: scene, sceneID: sceneID)
        AevonNotifySetWindowSize(0, 0)
    }

    /// 探测状态（probe 每 0.5s 一次）
    private var reflowChecking = false
    private var reflowCheckTicks = 0
    private var reflowCheckTarget: CGSize = .zero

    /// probe 里调用：确认 App 画布是否真的变成了目标尺寸。
    /// 确认 → contentReflowConfirmed = true（内容管线切 1:1 原生）；
    /// 10 次探测（5 秒）仍未确认 → 自动回退整屏等比缩放（V58 形态）。
    ///
    /// V0.0.64（AevonReflowAppGateV64）终审结论：**SB 侧没有任何信号能证明
    /// App 进程真的重排了。** presentationView 的子树 frame 全部由系统按我们
    /// 写入的 settings 直接设置（恒等于目标）——V59/V60 的「首子视图 ≈ 目标 +
    /// 无超尺寸视图」两道检查都是假阳性；V63 dc ivar 直写成功 + diff 下发 +
    /// 回读一致，App 进程照样没重排（画面放大 = 整屏画面被 1:1 塞进小窗）。
    /// 远程场景事后改 dc 只影响 SB 侧布局（Stheno/TrollOpen/Mango 三家逆向
    /// 交叉印证：真重排必须 App 进程内动手）。
    /// 所以：确认门 = **App 进程证据**（本版证据源尚未建立，开关恒关），
    /// 关着的时候内容恒走整屏等比缩放（V58 形态）——绝不再放大。
    private static let appProcessConfirmEnabled =
        AevonPrefs.bool("AppProcessReflowConfirm", default: false)

    /// 画布证据（每轮探测第 1 次采样，落日志供下一版判断）。
    private var evidenceLogged = false

    private func checkReflow() {
        guard reflowChecking, adaptiveContentSize != .zero else { return }
        reflowCheckTicks += 1
        let inner = presentationView.subviews.first?.frame.size ?? .zero
        let target = reflowCheckTarget
        // 证据采样（不参与判定）：子树里超过目标一圈的视图 = App 仍按整屏渲染的
        // 残留痕迹（如果 App 真重排了，这类视图应消失）。只在第 1 次落日志。
        var oversizedDesc = "无"
        var queue = presentationView.subviews
        var visited = 0
        while visited < 64, let view = queue.popLast() {
            visited += 1
            if view.frame.width > target.width + 20 || view.frame.height > target.height + 20 {
                oversizedDesc = "\(AevonRuntime.className(view) ?? "?") \(Int(view.frame.width))x\(Int(view.frame.height))"
                break
            }
            queue.append(contentsOf: view.subviews)
        }
        if !evidenceLogged {
            evidenceLogged = true
            AevonLog.info("[场景] 画布证据收集：首子=\(presentationView.subviews.first.flatMap { AevonRuntime.className($0) } ?? "?")"
                + " \(Int(inner.width))x\(Int(inner.height))，超尺寸视图=\(oversizedDesc)"
                + "（SB 侧信号不作为确认依据，AevonReflowAppGateV64）")
        }
        let innerOK = inner.width > 1 && abs(inner.width - target.width) <= 2
            && abs(inner.height - target.height) <= 2
        // 确认门：只有 App 进程证据通道建立（开关打开）时才允许确认。
        // 本版恒关 —— innerOK 只说明系统把 SB 侧 frame 设成了目标，不代表
        // App 进程重排（V59/V60/V63 三版真机实证），绝不据此切 1:1。
        if innerOK && Self.appProcessConfirmEnabled {
            contentReflowConfirmed = true
            reflowChecking = false
            AevonLog.info("[场景] App 已按小窗尺寸重新排版（画布 \(Int(inner.width))"
                + "x\(Int(inner.height)) ≈ 目标 \(Int(target.width))x\(Int(target.height))"
                + "，顶栏/底栏/右侧工具栏原生在场，内容 1:1 显示）（AevonReflowCheckV59）")
            onReflowChanged?()
            return
        }
        if reflowCheckTicks >= 10 {
            reflowChecking = false
            adaptiveContentSize = .zero
            contentReflowConfirmed = false
            AevonLog.warn("[场景] 5 秒内未确认 App 重排（画布 \(Int(inner.width))x\(Int(inner.height))"
                + " ≠ 目标 \(Int(target.width))x\(Int(target.height))），自动回退整屏等比缩放"
                + "（场景拒绝真 resize：帧+显示配置+托管开关三路都未让 App 重排）（AevonReflowCheckV59）")
            onReflowChanged?()
        }
    }

    /// 重排状态翻转时回调（窗口视图据此重算内容管线）。
    var onReflowChanged: (() -> Void)?

    init?(scene: AnyObject, sceneID: String, bundleID: String) {
        // presenter 标识必须唯一：系统的 SpringBoard 自己也在为这个场景建 presenter，
        // 用同一个 id 会撞车。
        let identifier = "Aevon-\(bundleID)-\(UUID().uuidString.prefix(8))"
        // 垫片返回 ObjC id，桥接过来是 Any；统一按 AnyObject 持有
        guard let created = AevonPresenterCreate(scene, identifier) as AnyObject? else {
            AevonLog.warn("[场景] 无法为 \(bundleID) 创建 presenter（uiPresentationManager 不可用）")
            return nil
        }
        let presenter: AnyObject = created
        guard let view = AevonPresenterView(presenter) as? UIView else {
            AevonPresenterDestroy(presenter)
            AevonLog.warn("[场景] presenter 没有 presentationView，放弃承载")
            return nil
        }

        self.scene = scene
        self.sceneID = sceneID
        self.bundleID = bundleID
        self.presenter = presenter
        self.presentationView = view

        let host = UIView(frame: UIScreen.main.bounds)
        host.backgroundColor = .clear
        // V0.0.13：浮窗里的 App 要能直接点。
        // 以前这里硬关掉交互，等于只能看画面。presentationView 的触摸会由 UIKit
        // 通过 presenter 的 UI 连接转发进 App 进程，不需要我们自己造触摸事件。
        // 开关默认开，若怀疑触摸引发异常可在 设置 → Aevon 关掉。
        let interactive = AevonPrefs.bool("TouchEnabled", default: true)
        self.contentInteractiveByPref = interactive
        /* V0.0.77（AevonGuardAliveV77）：先问一句「这个 App 进程里有没有 Guard」。
         * 有 → 正常（App 进程自己拦得住）；没有 → 内容触摸直接关掉，
         * 否则触摸经 presenter 的 UI 连接转发进去，App 自己合成一次点击
         * —— 这就是「轻点停靠小窗还原主窗，App 内被点一下」活过多版本的真身。 */
        let alivePid = AevonGuardAliveState(bundleID)
        let absent = (alivePid <= 0)
        self.guardAbsent = absent
        if absent {
            /* V0.0.79：先给 1.5 秒宽限再复检（见 guardGraceDeadline 注释）
             * V0.0.82（AevonMainContentV82）：**不再因此关掉内容触摸**。
             * 关掉它换不来防穿透（那一份是 backboardd 直投，不经过 presenter），
             * 只会让主悬浮窗彻底点不动 —— Aevon(74) 报的就是这个。
             * 现在只记警告，内容照常可用。 */
            self.guardGraceDeadline = CACurrentMediaTime() + 1.5
            AevonLog.warn("[场景] Guard 存活探测：\(bundleID) → **暂无 Guard**（该 App 是 tweak 加载前就在跑的老进程，"
                + "或注入被拦）；内容触摸**照常放行**，不因此锁死浮窗，"
                + "停靠小窗被轻点时该 App 可能收到一次直投点击（AevonGuardAliveV77 AevonMainContentV82）")
        } else {
            AevonLog.info("[场景] Guard 存活探测：\(bundleID) → 有（pid=\(alivePid)），内容触摸跟随设置（AevonGuardAliveV77）")
        }
        host.isUserInteractionEnabled = interactive
        host.clipsToBounds = true
        view.frame = host.bounds
        view.autoresizingMask = [UIView.AutoresizingMask.flexibleWidth,
                                 UIView.AutoresizingMask.flexibleHeight]
        // V0.0.80：**系统呈现视图恒可交互**。门控只做在 `host` 上 ——
        // 这个 view 同时被 SpringBoard 用来全屏显示该 App，压成 false 会连累全屏触摸。
        view.isUserInteractionEnabled = true
        host.addSubview(view)
        self.container = host
        applyContentInteraction(reason: "初始化")
        // V0.0.80：把系统呈现视图的交互交还给系统（修上一版残留的「全屏点不动」）
        restoreSystemPresentationInteraction(reason: "开窗")
        startContentGate()

        AevonLog.info("[场景] presenter 已激活（presenter=\(AevonRuntime.className(presenter) ?? "?")，视图=\(AevonRuntime.className(view) ?? "?")，场景 \(sceneID)，触摸=\(container.isUserInteractionEnabled ? "开" : "关")）")

        // 激活 presenter 之后再把场景推一次前台：只有场景处于前台，App 才会持续渲染。
        AevonSceneHelper.setForeground(scene, true)
    }

    deinit {
        if !invalidated {
            teardownPresenter()
        }
    }

    // MARK: - 首帧探测

    /// 内容触摸守护（AevonContentGateV79）：每 0.5 秒重施一遍，持续 10 秒。
    private func startContentGate() {
        guard contentGateTimer == nil else { return }
        contentGateTicks = 0
        AevonLog.info("[场景] 内容触摸守护已启动（10 秒内每 0.5 秒复查：系统重开 / Guard 晚登记 / 设置变更）"
            + "（\(bundleID)，AevonContentGateV79）")
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.invalidated else { self.stopContentGate(); return }
            self.contentGateTicks += 1
            if self.contentGateTicks > 20 { self.stopContentGate(); return }
            // ① 用户改过设置 → 立刻跟上（不必等 0.2 秒轮询）
            self.refreshContentPref()
            // ② Guard 晚登记 → 一登记上就放开
            if self.guardAbsent && AevonGuardAliveState(self.bundleID) > 0 {
                self.guardAbsent = false
                self.guardGraceDeadline = 0
                let pid = AevonGuardAliveState(self.bundleID)
                AevonLog.info("[场景] Guard 存活复检：\(self.bundleID) 已登记（pid=\(pid)），内容触摸恢复跟随设置（AevonGuardAliveV77）")
            }
            // ③ 系统又改回来了 → 再关一次
            self.applyContentInteraction(reason: self.guardAbsent ? "宽限复检" : "每拍复查")
            /* V0.0.82：宽限期过了仍然没有 Guard → 明确记一条「已知降级」。
             * 内容照常可用（见 applyContentInteraction 的 allow），但停靠小窗被轻点时
             * App 侧没人拦直投的那一份触摸。下轮先查该进程为什么没注入
             * （App Store App / 老进程 / 架构都可能，日志里 alive 文件是判据）。 */
            if self.guardAbsent, !self.guardAbsentLogged, self.guardHardAbsent {
                self.guardAbsentLogged = true
                AevonLog.warn("[场景] \(self.bundleID) 宽限期过后仍无 Guard：内容触摸照常放行"
                    + "（停靠小窗被轻点时 App 可能收到一次直投点击，只能靠注入解决）"
                    + "—— 请先彻底退出该 App 再重开浮窗，若仍无 Guard 说明注入被拦"
                    + "（AevonMainContentV82）")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        contentGateTimer = timer
    }

    private func stopContentGate() {
        contentGateTimer?.invalidate()
        contentGateTimer = nil
    }

    func startSyncing() {
        guard probeTimer == nil, !invalidated else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.probe()
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
        probe()
    }

    private func probe() {
        guard !invalidated else { return }
        ticks += 1

        /* V0.0.78（AevonContentGateV78）：每拍重新施加一次内容交互状态。
         * presentationView 归系统所有，场景激活 / 重连 / 重新挂载时 UIKit 会把它
         * 变回可交互 —— 那正是「小窗轻点还是点穿」的复活通道。 */
        applyContentInteraction(reason: "每拍复查")

        /* V0.0.77（AevonGuardAliveV77）：Guard 存活复检。
         * 刚拉起的 App 里 Guard 可能比这层晚几十毫秒才登记，别把它误判成「没有 Guard」
         * 而永久关掉内容触摸。前 4 秒（8 次探测）每隔一拍复查一次，一旦登记上就放开。 */
        if guardAbsent && ticks <= 8 {
            let pid = AevonGuardAliveState(bundleID)
            if pid > 0 {
                guardAbsent = false
                guardGraceDeadline = 0
                applyContentInteraction(reason: "存活复检")
                AevonLog.info("[场景] Guard 存活复检：\(bundleID) 已登记（pid=\(pid)），内容触摸恢复跟随设置（AevonGuardAliveV77）")
            }
        }

        // V0.0.59（AevonReflowCheckV59）：真重排确认走这里 —— 每 0.5s 看一眼
        // App 的画布有没有真的变成目标尺寸，确认或超时回退都会翻转状态。
        checkReflow()

        if !hasContent && contentLooksAlive() {
            hasContent = true
            // 记下呈现视图与首个子视图的实际尺寸：两者比例不一致就说明系统在内部留边
            // （letterbox），那是浮窗缩放怎么调都消不掉的黑边，只能靠场景尺寸解决。
            let outer = presentationView.bounds.size
            let inner = presentationView.subviews.first?.frame.size ?? .zero
            AevonLog.info("[场景] 首帧已到达（第 \(ticks) 次探测，子视图 \(presentationView.subviews.count) 个，"
                + "呈现视图 \(Int(outer.width))x\(Int(outer.height))，"
                + "首个子视图 \(Int(inner.width))x\(Int(inner.height))）")
            onFirstContent?()
        }

        if hasContent {
            // V0.0.59：重排确认期内不能停探测（确认/回退后这里自然变 false）
            if reflowChecking { return }
            if ticks >= 2 { stopProbing() }
            return
        }

        switch ticks {
        case 4:
            logDiagnostics("2 秒")
        case 8:
            logDiagnostics("4 秒")
            // 兜底：再恢复一次进程执行并推前台（suspended 拉起的 App 偶尔会漏恢复）
            if let pid = AevonAppInfo.pid(bundleID: bundleID) {
                AevonAssertionShim.resumePID(Int32(pid))
            }
            AevonSceneHelper.setForeground(scene, true)
        case 16:
            logDiagnostics("8 秒")
            stopProbing()
        default:
            break
        }
    }

    private func stopProbing() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    /// presentationView 里只要有子视图或子图层，就认为画面已经出来了。
    private func contentLooksAlive() -> Bool {
        if !presentationView.subviews.isEmpty { return true }
        if let sublayers = presentationView.layer.sublayers, !sublayers.isEmpty { return true }
        return false
    }

    // MARK: - 诊断

    private func logDiagnostics(_ tag: String) {
        let settings = AevonRuntime.send(scene, Selector(("settings")))
        let foreground = settings.flatMap { AevonRuntime.bool($0, key: "foreground") }
        let active = AevonRuntime.bool(scene, key: "isActive")
        let running = AevonAppInfo.isRunning(bundleID: bundleID)
        let subviews = presentationView.subviews.count
        let sublayers = presentationView.layer.sublayers?.count ?? 0
        AevonLog.warn("[诊断] \(tag)无画面：foreground=\(foreground.map { String($0) } ?? "?")"
            + " isActive=\(active.map { String($0) } ?? "?")"
            + " 进程运行=\(running)"
            + " 呈现视图子视图=\(subviews) 子图层=\(sublayers)"
            + " 视图尺寸=\(Int(presentationView.bounds.width))x\(Int(presentationView.bounds.height))")
    }

    // MARK: - 释放

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        onFirstContent = nil
        onReflowChanged = nil
        teardownPresenter()
        AevonLog.info("[场景] 已释放 presenter（\(bundleID)）")
    }

    private func teardownPresenter() {
        stopProbing()
        stopContentGate()
        hasContent = false

        /* V0.0.80（AevonNoSysViewGateV80）：拆之前把系统呈现视图的交互交还回去。
         * 关窗之后这个 view 可能还被系统用来全屏显示这个 App —— 留着 false
         * 就是「关掉所有浮窗后全屏点不动」的直接原因。 */
        restoreSystemPresentationInteraction(reason: "关窗")

        /* V0.0.81（AevonAppGateV81）：拆呈现者就把门打开 —— 浮窗没了，
         * App 必须能正常收触摸。漏掉这一步等于把 App 永久锁死（用户只能重开）。 */
        AevonSceneHelper.setAppGate(bundleID, blocked: false, reason: "关窗拆呈现者")

        // 先摘视图，再 deactivate + invalidate（顺序错了会留下悬挂的呈现者）
        presentationView.removeFromSuperview()

        if let presenter = presenter {
            AevonPresenterDestroy(presenter)
            self.presenter = nil
        }
    }
}
