#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// 自建场景驱动垫片（V0.2.28，AevonSelfSceneV228，P1 概念验证）。
///
/// 链路照抄 LiveContainer / FrontBoardAppLauncher（公开源码，iOS 15–17 实证）：
///   FBSMutableSceneDefinition（identity = 唯一 sceneID / clientIdentity = 运行中
///   App 进程 / specification = UIApplicationSceneSpecification）
///   + FBSMutableSceneParameters（UIMutableApplicationSceneSettings：
///     frame = 画布尺寸 ★创建时烙定 / foreground = YES / displayConfiguration =
///     主屏 dc 母本 / portrait / level = 1 / persistenceIdentifier = UUID）
///   → [FBSceneManager.sharedInstance createSceneWithDefinition:initialParameters:]
///   之后的 presenter 链（scene.uiPresentationManager → createPresenter → activate）
///   复用 AevonPresenterShim —— 自建场景上这条链与全屏接管完全同一体系。
///
/// 为什么这是「真重排」：App 进程在场景建立那一刻收到的画布就是浮窗尺寸
/// （事后改 dc 的路已被 V63/V64/V87 三重实锤判死，只有创建时烙定有效 ——
/// ScreenCore / Mango / TrollOpen 三家互证）。改画布 = scene.updateSettingsWithBlock
/// 改 settings.frame（自建场景上 settings 写入是受支持通路，App 随之重新布局）。
///
/// 安全纪律（归档 round7 教训，MultiFloat 同 identity 二次建场景 = FBSceneManager
/// 断言 = 安全模式）：
///   · sceneID 一律 `sceneID:com.aevon.float-<bundleID>` 前缀，绝不与 App 主场景
///     （`sceneID:<bundleID>-default`）撞 identity；
///   · 创建前先 destroyScene 同名遗留；关闭时 destroyScene 收尾；
///   · 全链 @try/@catch，任何一步失败返回 nil + 英文步骤串，调用方回退全屏接管路径，
///     绝不卡开机、绝不黑屏。

/// 创建自建场景（画布 w×h；pidHint = 调用方用 AevonAppInfo.pid 预取的进程号，
/// 0 = 未知由垫片自读）。成功返回 FBScene，*outSceneID 写场景标识；
/// 失败返回 nil，*outErr 写失败步骤（英文短串，调用方进 Aevon 日志）。
id AevonSelfSceneCreate(NSString *bundleID, NSInteger pidHint, double w, double h,
                        NSString * __autoreleasing *outSceneID,
                        NSString * __autoreleasing *outErr);

/// 已建场景改画布（真重排：updateSettingsWithBlock 内 frame = 0,0,w×h 且 foreground=YES）。
/// 返回 YES = 已提交。
BOOL AevonSelfSceneResize(id scene, double w, double h);

/// 销毁自建场景（destroyScene:withTransitionContext:）。
/// presenter 请先走 AevonPresenterDestroy（deactivate + invalidate）。
BOOL AevonSelfSceneDestroy(id scene);

/// V0.2.42（AevonMainSceneResizeV242）：S2 —— 改「已在运行的主场景」画布。
/// 只写 settings.frame（括号外不写 foreground / deactivationReasons，主场景前台状态
/// 归系统，写它就是抢状态机）。开源参照 MilkyWayReborn scaleMode 同一条
/// updateSettings 通路。返回 YES = 已提交（是否生效必须用 AevonMainSceneFrameState 复查）。
BOOL AevonMainSceneSetFrame(id scene, double w, double h);

/// V0.2.42（AevonMainSceneResizeV242）：只读取回 —— "frame=WxH fg=? cs=?"
/// 用于判 S2 是否提交成功、是否被 FrontBoard 回弹。
NSString *AevonMainSceneFrameState(id scene);

/// V0.2.32（AevonSelfSceneFGV232）：重申自建场景前台 —— updateSettings 内
/// foreground=YES + deactivationReasons=0（LiveContainer #942 同款：FBSSceneObserver
/// 会优先发 resignActive，必须重申）。只许对自建场景调用；主场景绝不碰。
BOOL AevonSelfSceneReassertForeground(id scene);

/// V0.2.32（AevonForegroundProbeV232）：真渲染判据（MultiFloat round8 档案）——
/// contentState==2 或 layerManager.layers 数 > 0。
/// 结构性子视图（远程表面容器）创建即存在，不能证明 App 真画了（0.2.31 假首帧教训）。
/// 只许对自建场景调用。
BOOL AevonSelfSceneContentAlive(id scene);

/// V0.2.32（AevonForegroundProbeV232）：只读取证串
/// "fg=? cs=? layers=? dr=? idle=?"（全 @try，取不到写 "?"），供日志判黑在哪一层。
NSString *AevonSelfSceneDebugState(id scene);

/// V0.2.47（AevonDarkGuardV247）：只读 —— 场景 contentState。
/// 返回值语义（与 0.2.42 起日志里的 cs= 同一字段）：2 = 内容已就绪正在画；
/// 0/1 = 准备中或已被回收（App 被系统置后台时就是这一档）；
/// **-1 = 取不到**（调用方必须 fail-open：不许把「读不到」当成「没在画」）。
NSInteger AevonSceneContentState(id scene);

/// V0.2.47（AevonDarkGuardV247）：只读 —— layerManager.layers 的数量。
/// 返回 -1 = 取不到。0 = 远程表面已被回收（黑窗的直接形态）。
/// 与 contentState 交叉判读：两个都掉了才是真黑，单个掉了只记日志不动手。
NSInteger AevonSceneLayerCount(id scene);

/// V0.2.49（AevonNoAutoLockV249）：真正压住系统熄屏 / 自动锁定。
///
/// Aevon(24)：「悬浮窗打开期间，依旧会跟随系统时间暗屏锁屏」。0.2.48 写的是
/// `UIApplication.shared.isIdleTimerDisabled = true` —— 在 **SpringBoard 进程**里
/// 这一笔并不进 SpringBoard 自己的空闲计时器（它归 `SBIdleTimerGlobalCoordinator`
/// 管），所以日志写着「已禁用」、屏幕照样按时暗。
///
/// 这里走 SpringBoard 自己的全局协调器：优先 `resetIdleTimer`（每次调用 = 把
/// 空闲计时重新起表），退而求其次 `resetIdleTimerAndUndim:`；两者都不响应就退回
/// `isIdleTimerDisabled`（与 0.2.48 同一条写入，只当兜底）。
/// 调用方必须**有界**：浮窗存在期间每 20 秒一次，绝不无限次狂调。
/// 返回位掩码（进日志）：1 = 调到了 resetIdleTimer；2 = 调到了 resetIdleTimerAndUndim:；
/// 4 = isIdleTimerDisabled 写成功；0 = 全都没成功（调用方只记一次日志，不重试）。
NSInteger AevonIdleTimerKick(void);

/// V0.2.50（AevonLockBlockV250）：在锁屏真正发生的那一刻拦下「非电源键」的锁屏请求。
/// 只在浮窗还存在时生效（钩子内部查 `AevonFloatActive()`），电源键（source == 1）永远放行。
///   返回 YES = 至少挂上一个锁屏入口；NO = 本机没有该入口（日志里会写「不可用」）。
BOOL AevonInstallLockBlock(void);

/// V0.2.51（AevonDeactGateV251）：回桌面守画 —— 拦截浮窗场景的停用登记。
/// 幂等；类/方法不存在返回 NO（0.2.50 的黑屏守卫照常兜底）。
BOOL AevonInstallDeactivationGate(void);

/// V0.2.35/36/37（AevonSceneRouteV235/236/237）：创建前分流判据 —— 目标 App 是否 scene 生命周期。
/// 查 LSApplicationProxy 的 Info.plist，三档细判（0.2.37 权威判据 = App 侧 scene
/// 探针实锤：delegate 实现 configurationForConnecting 才会接受第二场景连接；
/// manifest 里写没写 UIApplicationSupportsMultipleScenes 都不算数 —— Sileo/Filza
/// 写了 YES 照样黑屏，因为 delegate 是老式自动桥接）：
///   返回 2 = manifest 带真 scene delegate 类名 + 多场景 → 自建场景可走；
///   返回 1 = 有 manifest 但无 scene delegate 类名（老式自动桥接）或单场景 → 旧路径；
///   返回 0 = 无 manifest（老式单场景 App）→ 走旧路径；
///   返回 -1 = 探测不到（proxy nil / 类缺失），调用方按 2 处理（保持旧版行为）。
NSInteger AevonSelfSceneAppSceneSupport(NSString *bundleID);

/// V0.2.39（AevonSceneRouteV239）：创建前分流判据 —— 主路线换 SB 内部数据源。
/// 0.2.38 取证实锤：LSApplicationProxy.infoDictionary 在 roothide SB 进程调用即抛
/// NSInvalidArgumentException，黑屏组与成功组三版全 -1（同路），分流从未生效。
/// 新主路线 = SBApplicationController.sharedInstance → applicationWithBundleIdentifier:
/// （AevonAppInfo 已验证同款链路）→ SBApplication 的 sceneSpecification /
/// applicationSceneSpecification（选择子探测），SB 自己解析好的 manifest：
///   返回 2 = spec 非 nil（SB 认为它是 scene App）→ 自建场景可走；
///   返回 0 = spec 为 nil（老式 App，Sileo/Filza 类）→ 走旧路径；
///   返回 -1 = 链路断点 → 调用方保守走旧路径（白名单制）。
NSInteger AevonSelfSceneAppSceneSupport(NSString *bundleID);

/// V0.2.39（AevonSceneRouteV239）：分流取证 —— 双路线各段拼串 + 异常 reason。
/// A 路线 = SBApplication sceneSpecification；B 路线 = bundleURL 直读 Info.plist
/// （infoDictionary 抛异常的备选，只取证）。返回串仅供日志。
NSString *AevonSelfSceneRouteDump(NSString *bundleID);

/// V0.2.40（AevonSceneRouteV240）：二进制扫描判据（现行主路线）。
/// 0.2.39 真机定论：SBApplication 两个 spec 选择子都不响应（全 -1）；设置的
/// manifest 无 scene delegate 类名（uiSceneDel=no uiMulti=0）却实现了
/// configurationForConnecting → 判据在 App 可执行文件不在 manifest。
/// 读 App 二进制（LSApplicationProxy.bundleURL→Info.plist→CFBundleExecutable，
/// 直读文件通路 0.2.39 真机已验证可用）分块 memmem 扫
/// "configurationForConnectingSceneSession"（__objc_methname 明文）：
///   返回 2 = 含（delegate 实现该选择子 → 自建场景可走）；
///   返回 0 = 读毕未含（老式 App → 旧路径）；
///   返回 -1 = 判不了（proxy/plist/exe/读文件任一失败，含加密扫不到的形态）→
///           调用方保守走旧路径（白名单制）。结果按 bundleID 缓存。
NSInteger AevonSelfSceneAppBinarySupport(NSString *bundleID);

/// V0.2.41（AevonSceneCapsV241）：读 App 侧能力登记表（进程内权威判据的落地）。
/// App 侧 AevonAppSceneCapRegistry 在启动时算「delegate 是否实现
/// application:configurationForConnectingSceneSession:options:」并合并写
/// /var/mobile/aevon_caps.txt（`bundleID=1/0` 逐行）——该判据与 0.2.31~0.40
/// 五轮真机成败 100% 对齐（静态判据全翻车：设置 manifest 无 delegate 类名却成功、
/// Sileo 二进制含该选择子串却被拒、贴吧纯净版扫不到却成功）。
///   返回 1 = 该 App 能接受自建场景 → 自建（真重排）；
///   返回 0 = 老式 App（必拒）→ 旧路径（画面即刻出现）；
///   返回 -1 = 该 App 从未登记（未知）→ 调用方维持自建（旧行为，下次开窗即准）。
NSInteger AevonSelfSceneAppCapVerdict(NSString *bundleID);

/// V0.2.35（AevonSceneRouteV235）：连接取证 —— 只读 FBScene 的 client 相关字段
/// （client / clientPort，全 @try，取不到写 nil），区分「FB 层就没客户端」与
/// 「App 端 UIKit 拒绝」。返回串仅供日志。
NSString *AevonSelfSceneConnectionState(id scene);
