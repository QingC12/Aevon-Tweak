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

/// V0.2.35（AevonSceneRouteV235）：创建前分流判据 —— 目标 App 是否 scene 生命周期。
/// 查 LSApplicationProxy 的 Info.plist 有无 UIApplicationSceneManifest：
///   返回 1 = 有 manifest（scene App，UIKit 会为自建场景建 session → 自建场景可走）；
///   返回 0 = 无 manifest（老式单场景 App，UIKit 自动桥接只认主场景，自建场景
///           连接被 App 端拒绝 —— 0.2.34 真机实锤 + FrontBoardAppLauncher README
///           同款已知限制"Single-scene apps may not work yet"）；
///   返回 -1 = 探测不到（proxy nil / 类缺失），调用方按 1 处理（保持 0.2.34 行为）。
NSInteger AevonSelfSceneAppSceneSupport(NSString *bundleID);

/// V0.2.35（AevonSceneRouteV235）：连接取证 —— 只读 FBScene 的 client 相关字段
/// （client / clientPort，全 @try，取不到写 nil），区分「FB 层就没客户端」与
/// 「App 端 UIKit 拒绝」。返回串仅供日志。
NSString *AevonSelfSceneConnectionState(id scene);
