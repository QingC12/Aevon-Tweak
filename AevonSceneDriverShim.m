#import "AevonSceneDriverShim.h"
#import <objc/message.h>
#import <stdio.h>
#import <string.h>

/*
 * 自建场景驱动垫片（V0.2.28，AevonSelfSceneV228，P1 概念验证）。
 *
 * 为什么用 ObjC：整条链全是 FrontBoard / UIKit 私有 API，没有头文件；Swift 捕获
 * 不到 ObjC 异常，所以全部调用必须在 @try/@catch 内（AevonPresenterShim 同款）。
 *
 * 参考实现（公开源码，逐行对照）：
 *   LiveContainer AppSceneViewController.m（2025-05 版）
 *   FrontBoardAppLauncher AppDelegate.m / AppSceneViewController.m
 *   逆向互证：MultiFloat round6（route 4 = 唯一有公开源码背书「能出画面」的路线）、
 *   ScreenCore SCSystemSceneDriver（创建时烙 dc）、Aevon P0 探测（六项判据全通）。
 */

typedef NSInteger (*AevonSDIntFn0)(id, SEL);
typedef id (*AevonSDIdFn0)(id, SEL);
typedef id (*AevonSDIdFn1)(id, SEL, id);
typedef id (*AevonSDIdFn2)(id, SEL, id, id);
typedef void (*AevonSDVoidFn0)(id, SEL);
typedef void (*AevonSDVoidFnBool1)(id, SEL, BOOL);
typedef void (*AevonSDVoidFnInt1)(id, SEL, NSInteger);
typedef void (*AevonSDVoidFnRect1)(id, SEL, CGRect);
typedef CGRect (*AevonSDRectFn0)(id, SEL);
typedef void (*AevonSDVoidFnInsets1)(id, SEL, UIEdgeInsets);
typedef void (*AevonSDVoidFnBlock1)(id, SEL, void (^)(id));

/* V0.2.33（AevonSelfSceneAuditV233）：audit_token_t = 32 字节（8×uint32）。
 * arm64 上 >16B 的结构体返回走 sret（x8 隐藏指针）、结构体参数按引用传 ——
 * 用与真实签名一致的 typedef 调 objc_msgSend，编译器自动生成正确 ABI。 */
typedef struct { uint32_t val[8]; } AevonSDAuditToken;
typedef AevonSDAuditToken (*AevonSDAuditTokenGetter)(id, SEL);
typedef void (*AevonSDAuditTokenRegister)(id, SEL, AevonSDAuditToken);

/// CI 标记锚（used 常量；ObjC used 常量是 strings 检查的最可靠载体）
__attribute__((used)) static const char AevonSelfSceneV228Marker[] = "AevonSelfSceneV228";
__attribute__((used)) static const char AevonSelfSceneFallbackV228Marker[] = "AevonSelfSceneFallbackV228";
__attribute__((used)) static const char AevonSelfSceneFixV229Marker[] = "AevonSelfSceneFixV229";
__attribute__((used)) static const char AevonSelfSceneRBSV230Marker[] = "AevonSelfSceneRBSV230";
__attribute__((used)) static const char AevonSelfScenePidV231Marker[] = "AevonSelfScenePidV231";
__attribute__((used)) static const char AevonSelfSceneFGV232Marker[] = "AevonSelfSceneFGV232";
/* V0.2.34（AevonSelfSceneTakeoverV234）：创建成功/销毁前发 Darwin 通知
 * （com.aevon.selfscene.created / .destroyed），App 侧据以把主 UIWindow
 * setWindowScene 搬入/搬出自建场景 —— 单场景 App 不为第二场景建 window
 * 是黑屏直接原因（0.2.33 真机判型），窗口搬家是根治刀。 */
__attribute__((used)) static const char AevonSelfSceneTakeoverV234Marker[] = "AevonSelfSceneTakeoverV234";
__attribute__((used)) static const char AevonForegroundProbeV232Marker[] = "AevonForegroundProbeV232";
/* V0.2.33（Aevon(8) 日志：系统 App 显示、第三方 Sileo 黑屏，SB 侧链路完全一致）：
 * clientIdentity 换 FrontBoardAppLauncher（LiveContainer 同作者、SB 内呈现任意 App）
 * 的 identityForBundleID: 路线 + FBProcessManager registerProcessForAuditToken:。 */
__attribute__((used)) static const char AevonSelfSceneBundleIDV233Marker[] = "AevonSelfSceneBundleIDV233";
__attribute__((used)) static const char AevonSelfSceneAuditV233Marker[] = "AevonSelfSceneAuditV233";
/* V0.2.35（AevonSceneRouteV235）：0.2.34 真机判读 —— scene 感知 App（设置/GitHub/Safari）
 * 自建场景全通；老式单场景 App（Sileo）App 端 connectedScenes 8 秒无自建场景 =
 * 连接被 App 端 UIKit 拒绝（创建链与 LiveContainer/FrontBoardAppLauncher 逐字段一致，
 * 参照项目 README 同样标注 "Single-scene apps may not work yet" —— 路线已知限制，
 * 不是我们接错线）。修法 = 创建前分流：无 scene manifest 的 App 直接走全屏接管旧路径。 */
__attribute__((used)) static const char AevonSceneRouteV235Marker[] = "AevonSceneRouteV235";
/* V0.2.36（AevonSceneRouteV236）：0.2.35 真机矩阵 —— 成功（设置/GitHub/Gmail/
 * 贴吧纯净版/WPForumClient）vs 黑屏（Sileo/抖音/微信，全被 0.2.35 判「有 manifest」
 * 走了自建场景）。iOS 文档语义：UIApplicationSupportsMultipleScenes 缺省 NO，
 * 有 manifest 的单场景 App UIKit 同样只认主场景、第二场景连接照拒。
 * 分流细判：只有多场景 App 才走自建场景，其余一律旧路径。 */
__attribute__((used)) static const char AevonSceneRouteV236Marker[] = "AevonSceneRouteV236";
/* V0.2.37（AevonSceneRouteV237）：0.2.36 真机翻车 —— Sileo/Filza/抖音/微信的
 * manifest 里 UIApplicationSupportsMultipleScenes=YES（Xcode 模板常见）骗过了
 * 细判，仍走自建场景黑屏。App 侧 scene 探针实锤权威判型：
 *   delegate 实现 configurationForConnecting（设置）→ 显示成功；
 *   delegate 未实现 = 老式 AppDelegate 自动桥接（Sileo/Filza）→ 连接必拒。
 * SB 侧创建前近似：manifest 里必须真的写了 scene delegate 类名
 * （UISceneConfigurations…UISceneDelegateClassName 或 UIApplicationSceneDelegateClassName）
 * —— 老式 App 的 manifest 就算写满 supportsMultipleScenes 也没有这些键。 */
__attribute__((used)) static const char AevonSceneRouteV237Marker[] = "AevonSceneRouteV237";
/* V0.2.38（AevonSceneRouteV238）：0.2.37 真机翻车 + Sileo 源码破案 ——
 * Sileo 的 Info.plist 根本没有 UIApplicationSceneManifest（UIMainStoryboardFile=Main
 * 老式 storyboard App），按判据本应 return 0 走旧路径，但 0.2.35~37 三版真机
 * Sileo/Filza/抖音/QQ 全部走自建且分流零行 = 三版全返回 -1（取证链 proxy/info
 * 段断点），而 -1 一直被放行进自建场景。两刀：
 * ① 白名单制：只有确证 2 才自建，-1 从「维持自建」改「保守旧路径」；
 * ② AevonSelfSceneRouteDump 把链路每一段拼串打进日志，一回定终判。 */
__attribute__((used)) static const char AevonSceneRouteV238Marker[] = "AevonSceneRouteV238";
/* V0.2.39（AevonSceneRouteV239）：0.2.38 取证实锤 —— LSApplicationProxy.infoDictionary
 * 在 roothide SB 进程调用即抛 NSInvalidArgumentException（proxy 在、选择子响应、
 * 调用就炸），三版黑屏组与成功组全部 -1 同路，分流从未生效；0.2.38 白名单制把
 * -1 全挡旧路径 = 真重排全部回退（用户实测）。主路线换 SB 内部数据源：
 * SBApplicationController.sharedInstance → applicationWithBundleIdentifier:
 * （AevonAppInfo 已验证同款链路）→ SBApplication 的 sceneSpecification ——
 * SB 自己解析好的 manifest，老式 App 为 nil，与 roothide 文件系统补丁无关。 */
__attribute__((used)) static const char AevonSceneRouteV239Marker[] = "AevonSceneRouteV239";
__attribute__((used)) static const char AevonSceneRouteV240Marker[] = "AevonSceneRouteV240";
__attribute__((used)) static const char AevonSceneCapsV241Marker[] = "AevonSceneCapsV241";
/* V0.2.42（AevonMainSceneResizeV242）：S2 —— 改「已在运行的主场景」画布。
 * 开源参照 MilkyWayReborn（34306，开源 iOS 17~26）scaleMode 通路：
 *   [scene mutableSettings] → setFrame: → updateSettings:withTransitionContext:completion:
 * 本项目此前所有「事后改尺寸」失败的记录（V63/V64/V87）改的是
 * displayConfiguration（显示配置）与呈现上下文开关，不是场景自身 settings.frame；
 * S2 走的是另一层，二者不构成互证。老式单场景 App 也能收到——不需要第二场景。 */
__attribute__((used)) static const char AevonMainSceneResizeV242Marker[] = "AevonMainSceneResizeV242";
/* V0.2.43（AevonCanvasScaleV243 / AevonMainCanvasGuardV243 / AevonContentTreeV243）：
 * Aevon(18) 真机定论 —— S2 主场景改画布 = 真重排成立（所有 App 都重排了），
 * 剩下两个问题都在「画布尺寸」这一层，不在场景路线层：
 *   ① 画布 = 窗口（272pt 逻辑宽，比任何 iPhone 都窄）→ 字号 pt 固定 = 字大内容少。
 *      修法：逻辑画布 = 窗口 × k（1.00 / 1.30 / 1.58），呈现时容器 scale(1/k) 缩回，
 *      同面积装下 k 倍宽排版。画布宽上限 = 屏宽，5:3 不变 → 无变形无黑边。
 *   ② 抖音右侧点赞 / 头像栏不显示 → 一级子视图比画布宽 = App 按 UIScreen 全屏宽度
 *      排版，右侧落在画布外被裁；只有把画布宽提到接近屏宽（1.58 档）才治得了。
 * 另修一处真 bug（AevonMainCanvasGuardV243）：0.2.42 的防回弹三拍排在
 * WindowManager 里、捕获裸 scene，关窗还原 430x932 后 +2.5s 那拍仍在跑，
 * 读回「不是画布」→ 又写回 272x454（Aevon(18) 10:23:14 / 10:24:03 两处置实）。
 * 三拍已挪进 AevonSceneHost，invalidated 后一律不写。 */
__attribute__((used)) static const char AevonCanvasScaleV243Marker[] = "AevonCanvasScaleV243";
__attribute__((used)) static const char AevonMainCanvasGuardV243Marker[] = "AevonMainCanvasGuardV243";
__attribute__((used)) static const char AevonContentTreeV243Marker[] = "AevonContentTreeV243";
/* V0.2.44（AevonScreenAspectV244）：内容比例档 —— 窗口比例跟随屏幕。
 * 0.2.43 真机（Aevon(19)）判读：1.58 档后抖音右侧栏回来了（画布宽 = 屏宽），
 * 但画面「整体上移、视频不在正中、底部黑一大片」。根因在比例不在倍数：
 * 5:3 竖窗的逻辑画布 430×716，比整屏 430×932 矮 216pt，抖音这类「整页按整屏
 * 高度排版」的 App 只能露出上半页（首个子视图 430x716 就是证据）。
 * 5:3（0.6）与「整屏完整可见」（0.4614）在数学上互斥 —— 本档把**窗口比例**换成
 * 屏幕比例：画布 = 整屏原生尺寸，App 与全屏逐像素一致地排版（顶栏 / 底栏 /
 * 右侧栏全在位、视频在原生位置居中、上下黑边天然等量），呈现层按 1/k 等比缩进
 * 窗口（X/Y 系数天然相等 → 不裁切、不变形、不留 letterbox）。关掉 = 5:3 真重排。 */
__attribute__((used)) static const char AevonScreenAspectV244Marker[] = "AevonScreenAspectV244";
/* V0.2.45（AevonRatio58V245 / AevonCornerRadiusV245 / AevonFloatFadeInV245）：
 * 按参考视频逐像素实测定档（交付/分析-主悬浮窗比例与圆角-2026-10-27/）。
 *
 * 实测：主窗 470×754 px（多帧一致，0.623 ≈ 5:8）、圆角 52px ≈ 35/38pt
 * = 窗宽的 11.1%（被拉大到 567px 宽时仍是 54~60px → 近似固定 pt 量级）。
 * 窗内抖音各区块高度全部落在原生 pt 上（顶栏 33 / 底栏 33 / 底部安全区 36 /
 * 右侧图标列 48）→ App 拿到 313×503 pt 的画布**自己排了一次版**，
 * 不是整屏缩放、也不是裁切。这就是 0.2.42 验证过的 S2 真重排，只是当时
 * 比例用了 5:3（窄 4%）、画布只有 272pt。
 *
 * 本版四刀：
 *   ① 生效比例 5:3 → 5:8（contentAspect58）；历史 5:3 常量原样保留（CI 1785 钉住）
 *   ② 画布倍数默认 1.30 → 1.00（画布 = 窗口，App 拿到 344×550 的原生尺寸）
 *   ③ 默认窗宽 0.62 → 0.80 屏宽 + 几何记忆一次性迁移（老记忆停在 319 宽）
 *   ④ 圆角 12pt 写死 → 窗宽 × 11.1%（夹 20~44），随缩放跟随 + 0.2s 隐式过渡；
 *      开窗 0.18s 淡入（只动 alpha，不触发布局与画布提交） */
__attribute__((used)) static const char AevonRatio58V245Marker[] = "AevonRatio58V245";
__attribute__((used)) static const char AevonCornerRadiusV245Marker[] = "AevonCornerRadiusV245";
__attribute__((used)) static const char AevonFloatFadeInV245Marker[] = "AevonFloatFadeInV245";
/* V0.2.46（AevonCanvasScaleV246 / AevonRatioTallV246 / AevonFloatGlowV246 /
 * AevonFloatGripGlobalV246 / AevonCanvasHandoffV246）：Aevon(21) 真机四项。
 *
 *  ① 画布倍数默认 1.00 → **1.30**（AevonCanvasScaleV246）。
 *     用户三档对测：1.00（画布 = 窗口 315×504）字依旧很大、一屏装不下；
 *     1.30（画布被屏宽夹到 430×688，k = 0.80）字正常、内容确实重排；1.60 与 1.30
 *     同一张 430 宽画布（只是缩放更糊）。字号是固定 pt —— 画布逻辑宽越接近真机 430，
 *     排出来的字越和全屏一致。老用户旧值 1.00 一次性回写（用户自选档不动）。
 *  ② 窗比例 5:8（0.625）→ **7:12（0.5833，高 +7%）**（AevonRatioTallV246）。
 *     用户：5:8 看着「有点胖」，高度加 5%~10%。画布仍 = 窗口 × 倍数、按 1/k 等比缩回
 *     → 比例不变形、不出黑边；画布高 688 → 737，抖音视频区跟着变高、更靠中间。
 *  ③ 深色模式浮窗四周看不清 → **外缘发光圈**（AevonFloatGlowV246）。
 *     Stheno / ScreenCore 侧证据：`SCFloatingContainerView` 有整只 `_sceneGlowView`
 *     （配 sceneGlow 居中/定尺寸约束）+ `sc_isDarkAppearance` +
 *     `sc_updateCornerRadiusAndShadowPath` —— 发光圈跟几何、按深浅外观切换。
 *  ④ 全屏 App 上开浮窗时窗外手柄全失效（拖不动/关不掉/缩不了）
 *     （AevonFloatGripGlobalV246）。根因：浮窗父视图是全屏 App 画面容器，
 *     其命中测试不把窗外的点交给我们（V0.0.23 / V0.0.41 两度实锤），手柄 pan 永不 begun。
 *     修法：全局触摸通道在「交回浮窗」早退之前先做手柄判定并整段接管（吞 SB 份事件，
 *     不会与 pan 双触发）。
 *  AevonCanvasHandoffV246：主场景改画布日志里点名「App 拿到 WxH 独立画布自己排版」，
 *  作为「所有走 S2 的 App 都能自排版」的正面证据。 */
__attribute__((used)) static const char AevonCanvasScaleV246Marker[] = "AevonCanvasScaleV246";
__attribute__((used)) static const char AevonRatioTallV246Marker[] = "AevonRatioTallV246";
__attribute__((used)) static const char AevonFloatGlowV246Marker[] = "AevonFloatGlowV246";
__attribute__((used)) static const char AevonFloatGripGlobalV246Marker[] = "AevonFloatGripGlobalV246";
__attribute__((used)) static const char AevonCanvasHandoffV246Marker[] = "AevonCanvasHandoffV246";
/* V0.2.47（AevonDarkGuardV247 / AevonGlowEdgeV247 / AevonPrefsFixedV247 /
 * AevonRingGripGuardV247）：Aevon(22) 真机四项。
 *
 *  ① **回桌面后浮窗黑屏**（AevonDarkGuardV247）。现象：全屏 App 里开浮窗 →
 *     上滑回桌面 → 浮窗有概率整块变黑，必须关掉重开才恢复。
 *     机制：S2 路线承载的是 App 的**主场景**，它的前台状态全归 SpringBoard ——
 *     一上滑回桌面，这个 App 就被系统置后台，远程表面被回收（cs / layers 归 0），
 *     presenter 立刻没东西可画；而 0.1.5 的前台补偿只补开窗后 8 次（约 7 秒），
 *     之后再不写，所以「开窗 7 秒内回桌面」能活、「过一会儿再回桌面」就黑 ——
 *     这正是用户说的「有概率」。修法两段：
 *       · 事件驱动：`appSceneDisappeared`（全屏 App 画面离场 = 回桌面 / 切 App）
 *         时对浮窗场景重申一次前台（+0 / +0.75 / +2.0s 三拍，全部有界）；
 *       · 兜底：布防 4 秒内若 contentState 真的不在了（连续两拍 cs<2 且 cs 可读）
 *         → 把最后一帧快照盖上去（永不黑屏），点一下浮窗即撤销并再重申。
 *  ② **发光圈太扎眼**（AevonGlowEdgeV247）：0.2.46 的 12pt 外扩 + 白 0.90/半径 9
 *     被用户判为「太明显、不贴边」。改为贴边 2pt、亮度 0.42、半径 5，只留
 *     shadowPath 光晕（浅色 0.12/半径 4），窗内一个像素都不占。
 *  ③ **偏好定档**（AevonPrefsFixedV247）：用户要求「画布倍数等开关改回默认状态，
 *     并把设置里的开关移除」。画布倍数写死 1.30、内容比例写死 7:12 真重排档，
 *     Detail.plist 删掉这两组单元，盘上旧值一次性回写（含 0.2.46 迁移留下的 1.30）。
 *  ④ **拖右下角缩放误呼圆盘**（AevonRingGripGuardV247）：圆盘有三条触发通道
 *     （桌面手势条 / 系统手势管线 / 全局通道），前两条都做了浮窗让路，唯独
 *     **系统手势管线那条没有** —— 它由 BackBoard 直投，不经过我们的 hitTest。
 *     右下角角块正好压在右缘 30pt 边缘区里，拖动时 dx 为负 → 判向成立 → 呼盘。
 *     修法：该通道 `.began` 时先问「起手是否落在浮窗（含外侧手柄）范围内」，
 *     是则立刻 Failed 归还，一根头发都不扣。 */
__attribute__((used)) static const char AevonDarkGuardV247Marker[] = "AevonDarkGuardV247";
__attribute__((used)) static const char AevonGlowEdgeV247Marker[] = "AevonGlowEdgeV247";
__attribute__((used)) static const char AevonPrefsFixedV247Marker[] = "AevonPrefsFixedV247";
__attribute__((used)) static const char AevonRingGripGuardV247Marker[] = "AevonRingGripGuardV247";

/// 给类发无参工厂消息。
static id AevonSDClassFactory(NSString *clsName, NSString *selName) {
    Class cls = NSClassFromString(clsName);
    if (cls == nil) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![cls respondsToSelector:sel]) return nil;
    return ((AevonSDIdFn0)objc_msgSend)((id)cls, sel);
}

/// 给类发单参工厂消息。
static id AevonSDClassFactory1(NSString *clsName, NSString *selName, id arg) {
    Class cls = NSClassFromString(clsName);
    if (cls == nil) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![cls respondsToSelector:sel]) return nil;
    return ((AevonSDIdFn1)objc_msgSend)((id)cls, sel, arg);
}

/// 属性 setter 兜底（respondsToSelector 先验）。
static void AevonSDSetBool(id obj, const char *prop, BOOL v) {
    SEL sel = NSSelectorFromString([NSString stringWithFormat:@"set%c%s:",
                                   (char)(prop[0] >= 'a' && prop[0] <= 'z' ? prop[0] - 32 : prop[0]), prop + 1]);
    if ([obj respondsToSelector:sel]) ((AevonSDVoidFnBool1)objc_msgSend)(obj, sel, v);
}
static void AevonSDSetInt(id obj, const char *prop, NSInteger v) {
    SEL sel = NSSelectorFromString([NSString stringWithFormat:@"set%c%s:",
                                   (char)(prop[0] >= 'a' && prop[0] <= 'z' ? prop[0] - 32 : prop[0]), prop + 1]);
    if ([obj respondsToSelector:sel]) ((AevonSDVoidFnInt1)objc_msgSend)(obj, sel, v);
}
static void AevonSDSetRect(id obj, const char *prop, CGRect v) {
    SEL sel = NSSelectorFromString([NSString stringWithFormat:@"set%c%s:",
                                   (char)(prop[0] >= 'a' && prop[0] <= 'z' ? prop[0] - 32 : prop[0]), prop + 1]);
    if ([obj respondsToSelector:sel]) ((AevonSDVoidFnRect1)objc_msgSend)(obj, sel, v);
}
static void AevonSDSetInsets(id obj, const char *prop, UIEdgeInsets v) {
    SEL sel = NSSelectorFromString([NSString stringWithFormat:@"set%c%s:",
                                   (char)(prop[0] >= 'a' && prop[0] <= 'z' ? prop[0] - 32 : prop[0]), prop + 1]);
    if ([obj respondsToSelector:sel]) ((AevonSDVoidFnInsets1)objc_msgSend)(obj, sel, v);
}
static void AevonSDSetObject(id obj, const char *prop, id v) {
    SEL sel = NSSelectorFromString([NSString stringWithFormat:@"set%c%s:",
                                   (char)(prop[0] >= 'a' && prop[0] <= 'z' ? prop[0] - 32 : prop[0]), prop + 1]);
    if ([obj respondsToSelector:sel]) ((AevonSDIdFn1)objc_msgSend)(obj, sel, v);
}

/// 取运行中 App 的进程句柄（clientIdentity 用的 identity 载体）。
///
/// V0.2.29 修复（AevonSelfSceneFixV229，0.2.28 真机 step=app-not-running 实锤）：
/// `applicationWithBundleIdentifier:` 是 SBApplicationController 的 **实例方法**，
/// 必须先 +sharedInstance 再对实例发消息（发类上 = respondsToSelector 查类方法表必失败）。
///
/// V0.2.30（AevonSelfSceneRBSV230，0.2.29 真机实锤）：路线 A 的 KVC processHandle
/// 在 iOS 17.3.1 上**永远取不到**——进程跑了 9 秒 + 前台（com.apple.Preferences pid=68619）
/// 仍 process-handle-nil。改用 LiveContainer AppSceneViewController.m（2025-05 版）
/// 的 iOS 17 主通路（源码逐行对照）：
///   RBSProcessPredicate *p = [RBSProcessPredicate predicateMatchingIdentifier:@(pid)];
///   RBSProcessHandle   *h = [RBSProcessHandle handleForPredicate:p error:nil];
///   → identityForProcessIdentity:h.identity
/// 路线 A 保留为第一路（老系统可能还有），路线 B 是 iOS 17 正解。
/// 注：LiveContainer 还调 FBProcessManager registerProcessForAuditToken:，
/// 那是因为它自己 spawn 的进程 FrontBoard 不认识；我们的 App 是 FrontBoard 正常
/// 拉起的，SB 的 FBProcessManager 本来就管理着它，无需注册。
///
/// V0.2.31（AevonSelfScenePidV231，0.2.30 真机实锤）：0.2.30 全部卡 pid-nil，
/// 但同一时刻 AevonAppInfo.pid（先 pid 选择子、败则 processState.pid）立刻取到
/// pid=68883（间隔 4ms）→ pid 读出链与已验证路径没对齐。本次：
///   ① 调用方用 AevonAppInfo.pid 预取 pidHint 直传（主通路，逐选择子对齐成功路径）；
///   ② 垫片自读兜底改为 AevonAppInfo 同款双段（pid → processState.pid）。
static id AevonSDAppProcessHandle(NSString *bundleID, NSInteger pidHint,
                                  NSString * __autoreleasing *outStep) {
    // ── 路线 A：SBApplication.processHandle（老通路）──
    id controller = AevonSDClassFactory(@"SBApplicationController", @"sharedInstance");
    if (controller == nil) { if (outStep) { *outStep = @"controller-nil"; } return nil; }
    SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (![controller respondsToSelector:appSel]) { if (outStep) { *outStep = @"app-sel-missing"; } return nil; }
    id app = ((AevonSDIdFn1)objc_msgSend)(controller, appSel, bundleID);
    if (app == nil) { if (outStep) { *outStep = @"app-object-nil"; } return nil; }
    for (NSString *key in @[@"processHandle", @"_processHandle"]) {
        id handle = nil;
        @try { handle = [app valueForKey:key]; } @catch (NSException *exception) { handle = nil; }
        if (handle != nil) return handle;
    }

    // 默认结论：两条路线都没拿到句柄（0.2.29 step 串保留，Swift 侧按此重试）
    if (outStep) { *outStep = @"process-handle-nil"; }

    // ── pid 解析：pidHint（AevonAppInfo 预取）→ pid 选择子 → processState.pid ──
    NSInteger pid = pidHint > 0 ? pidHint : 0;
    if (pid <= 0) {
        SEL pidSel = NSSelectorFromString(@"pid");
        if ([app respondsToSelector:pidSel]) {
            pid = ((AevonSDIntFn0)objc_msgSend)(app, pidSel);
        }
    }
    if (pid <= 0) {
        // AevonAppInfo.pid 的兜底段：SBApplication.processState.pid
        SEL stateSel = NSSelectorFromString(@"processState");
        if ([app respondsToSelector:stateSel]) {
            id state = ((AevonSDIdFn0)objc_msgSend)(app, stateSel);
            SEL statePidSel = NSSelectorFromString(@"pid");
            if (state != nil && [state respondsToSelector:statePidSel]) {
                pid = ((AevonSDIntFn0)objc_msgSend)(state, statePidSel);
            }
        }
    }
    if (pid <= 0) { if (outStep) { *outStep = @"pid-nil"; } return nil; }

    // ── 路线 B：pid → RBSProcessPredicate → RBSProcessHandle（iOS 17 主通路）──
    Class predCls = NSClassFromString(@"RBSProcessPredicate");
    Class handleCls = NSClassFromString(@"RBSProcessHandle");
    SEL predSel = NSSelectorFromString(@"predicateMatchingIdentifier:");
    if (predCls == nil || handleCls == nil || ![predCls respondsToSelector:predSel]) {
        if (outStep) { *outStep = @"rb-predicate-missing"; } return nil;
    }
    id predicate = ((AevonSDIdFn1)objc_msgSend)(predCls, predSel, @(pid));
    if (predicate == nil) { if (outStep) { *outStep = @"rb-predicate-nil"; } return nil; }
    SEL handleSel = NSSelectorFromString(@"handleForPredicate:error:");
    if (![handleCls respondsToSelector:handleSel]) {
        if (outStep) { *outStep = @"rb-handle-sel-missing"; } return nil;
    }
    id handle = ((AevonSDIdFn2)objc_msgSend)(handleCls, handleSel, predicate, nil);
    if (handle == nil) { if (outStep) { *outStep = @"rb-handle-nil"; } return nil; }
    return handle;
}

static id AevonSelfSceneCreateInner(NSString *bundleID, NSInteger pidHint, double w, double h,
                                    NSString * __autoreleasing *outSceneID,
                                    NSString * __autoreleasing *outErr);

id AevonSelfSceneCreate(NSString *bundleID, NSInteger pidHint, double w, double h,
                        NSString * __autoreleasing *outSceneID,
                        NSString * __autoreleasing *outErr) {
    @try {
        return AevonSelfSceneCreateInner(bundleID, pidHint, w, h, outSceneID, outErr);
    } @catch (NSException *exception) {
        if (outErr) { *outErr = [NSString stringWithFormat:@"exception:%@", exception.name]; }
        return nil;
    }
}

/// 创建主体（ARC 下 goto 跨 __strong 局部变量初始化是编译错误 —— 全部 early-return）。
static id AevonSelfSceneCreateInner(NSString *bundleID, NSInteger pidHint, double w, double h,
                                    NSString * __autoreleasing *outSceneID,
                                    NSString * __autoreleasing *outErr) {
    if (outErr) { *outErr = nil; }
    if (outSceneID) { *outSceneID = nil; }
    if (bundleID.length == 0) { if (outErr) { *outErr = @"bundleID-empty"; } return nil; }
    if (w < 50 || h < 50) { if (outErr) { *outErr = @"size-invalid"; } return nil; }

    // ── 1. 运行中 App 的进程身份（clientIdentity 必须指向已存在的进程）──
    NSString *handleStep = nil;
    id handle = AevonSDAppProcessHandle(bundleID, pidHint, &handleStep);
    if (handle == nil) { if (outErr) { *outErr = handleStep ?: @"app-not-running"; } return nil; }
    id processIdentity = nil;
    for (NSString *key in @[@"identity", @"processIdentity"]) {
        @try { processIdentity = [handle valueForKey:key]; } @catch (NSException *exception) { processIdentity = nil; }
        if (processIdentity != nil) break;
    }
    if (processIdentity == nil) { if (outErr) { *outErr = @"process-identity"; } return nil; }

    // ── 1.5. FBProcessManager 进程注册（AevonSelfSceneAuditV233，FrontBoardAppLauncher 同款）──
    // 注册失败绝不阻断（App 是 FrontBoard 正常拉起的，理论上 SB 已管理；注册是补齐对齐项）。
    @try {
        Class pmCls = NSClassFromString(@"FBProcessManager");
        id pm = (pmCls != nil) ? AevonSDClassFactory(@"FBProcessManager", @"sharedInstance") : nil;
        SEL auditSel = NSSelectorFromString(@"auditToken");
        SEL regSel = NSSelectorFromString(@"registerProcessForAuditToken:");
        if (pm != nil && handle != nil &&
            [handle respondsToSelector:auditSel] && [pm respondsToSelector:regSel]) {
            AevonSDAuditToken token = ((AevonSDAuditTokenGetter)objc_msgSend)(handle, auditSel);
            ((AevonSDAuditTokenRegister)objc_msgSend)(pm, regSel, token);
        }
    } @catch (NSException *exception) {
        // 静默：这条注册是锦上添花，任何异常都不值得中断场景创建
    }

    // ── 2. 场景管理器 ──
    id manager = AevonSDClassFactory(@"FBSceneManager", @"sharedInstance");
    if (manager == nil) { if (outErr) { *outErr = @"fb-manager-nil"; } return nil; }

    // ── 3. 唯一身份（绝不与主场景 sceneID:<bid>-default 撞，round7 教训）──
    NSString *sceneID = [NSString stringWithFormat:@"sceneID:com.aevon.float-%@", bundleID];

    // 遗留场景先销毁（respring 后我们没来得及收尾的情况）
    SEL sceneByIdSel = NSSelectorFromString(@"sceneWithIdentifier:");
    if ([manager respondsToSelector:sceneByIdSel]) {
        id leftover = ((AevonSDIdFn1)objc_msgSend)(manager, sceneByIdSel, sceneID);
        if (leftover != nil) {
            SEL destroySel = NSSelectorFromString(@"destroyScene:withTransitionContext:");
            if ([manager respondsToSelector:destroySel]) {
                ((AevonSDIdFn2)objc_msgSend)(manager, destroySel, sceneID, nil);
            }
        }
    }

    // ── 4. 场景定义（identity / clientIdentity / specification）──
    id definition = AevonSDClassFactory(@"FBSMutableSceneDefinition", @"definition");
    if (definition == nil) { if (outErr) { *outErr = @"definition-nil"; } return nil; }
    id sceneIdentity = AevonSDClassFactory1(@"FBSSceneIdentity",
                                            @"identityForIdentifier:", sceneID);
    if (sceneIdentity == nil) { if (outErr) { *outErr = @"scene-identity-nil"; } return nil; }
    AevonSDSetObject(definition, "identity", sceneIdentity);
    /* V0.2.33（AevonSelfSceneBundleIDV233）：clientIdentity 双路线。
     * 0.2.30~0.2.32 用 identityForProcessIdentity:（LiveContainer 路线）：系统 App
     * 全部渲染成功，但第三方（Sileo）黑屏且 SB 侧取证串与系统 App 完全一致 ——
     * 卡点在 App 端 scene session 连接。FrontBoardAppLauncher（khanhduytran0，
     * LiveContainer 同作者，SB 内呈现任意 App 场景，公开源码 ViewController.m_sb）
     * 用的是 identityForBundleID: —— 同环境（SB 内）同目标的已验证形态，优先走；
     * processIdentity 保留为兜底。 */
    id clientIdentity = AevonSDClassFactory1(@"FBSSceneClientIdentity",
                                             @"identityForBundleID:", bundleID);
    if (clientIdentity == nil) {
        clientIdentity = AevonSDClassFactory1(@"FBSSceneClientIdentity",
                                              @"identityForProcessIdentity:", processIdentity);
    }
    if (clientIdentity == nil) { if (outErr) { *outErr = @"client-identity-nil"; } return nil; }
    AevonSDSetObject(definition, "clientIdentity", clientIdentity);
    id specification = AevonSDClassFactory(@"UIApplicationSceneSpecification", @"specification");
    if (specification == nil) { if (outErr) { *outErr = @"specification-nil"; } return nil; }
    AevonSDSetObject(definition, "specification", specification);

    // ── 5. 初始参数：settings 画布 ★创建时烙定（真重排的立身之本）──
    id parameters = AevonSDClassFactory1(@"FBSMutableSceneParameters",
                                         @"parametersForSpecification:", specification);
    if (parameters == nil) { if (outErr) { *outErr = @"parameters-nil"; } return nil; }

    Class settingsCls = NSClassFromString(@"UIMutableApplicationSceneSettings");
    if (settingsCls == nil) { if (outErr) { *outErr = @"settings-class-nil"; } return nil; }
    id settings = [[settingsCls alloc] init];

    AevonSDSetBool(settings, "canShowAlerts", YES);
    // dc 母本 = 主屏 dc（iOS 17 无 setter，创建期由系统拷贝 —— ScreenCore/Mango 同款）
    SEL dcSel = NSSelectorFromString(@"displayConfiguration");
    if ([UIScreen.mainScreen respondsToSelector:dcSel]) {
        id dc = ((AevonSDIdFn0)objc_msgSend)(UIScreen.mainScreen, dcSel);
        AevonSDSetObject(settings, "displayConfiguration", dc);
    }
    AevonSDSetBool(settings, "foreground", YES);            // 后台场景不渲染（round6 根因之一）
    AevonSDSetRect(settings, "frame", CGRectMake(0, 0, w, h)); // ★ 画布 = 浮窗尺寸
    AevonSDSetInt(settings, "interfaceOrientation", 1);      // Portrait
    AevonSDSetInt(settings, "level", 1);
    AevonSDSetObject(settings, "persistenceIdentifier", NSUUID.UUID.UUIDString);
    AevonSDSetBool(settings, "statusBarDisabled", YES);      // 非原生窗（参考实现同款）
    AevonSDSetInsets(settings, "peripheryInsets", UIEdgeInsetsZero);
    AevonSDSetInsets(settings, "safeAreaInsetsPortrait", UIEdgeInsetsZero);
    AevonSDSetObject(parameters, "settings", settings);

    Class clientCls = NSClassFromString(@"UIMutableApplicationSceneClientSettings");
    if (clientCls != nil) {
        id clientSettings = [[clientCls alloc] init];
        AevonSDSetInt(clientSettings, "interfaceOrientation", 1);
        AevonSDSetInt(clientSettings, "statusBarStyle", 0);
        AevonSDSetObject(parameters, "clientSettings", clientSettings);
    }

    // ── 6. 创建场景 ──
    SEL createSel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
    if (![manager respondsToSelector:createSel]) { if (outErr) { *outErr = @"create-sel-missing"; } return nil; }
    id scene = ((AevonSDIdFn2)objc_msgSend)(manager, createSel, definition, parameters);
    if (scene == nil) { if (outErr) { *outErr = @"scene-nil"; } return nil; }

    // V0.2.34（AevonSelfSceneTakeoverV234）：广播创建成功。App 侧收到后开始
    // 轮询 connectedScenes，发现自建场景就把主 UIWindow 搬过来（单场景 App
    // 不会为第二场景建 window —— 0.2.33 真机判型：这是黑屏的直接原因）。
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.aevon.selfscene.created"),
                                         NULL, NULL, true);

    if (outSceneID) { *outSceneID = sceneID; }
    return scene;
}

BOOL AevonSelfSceneResize(id scene, double w, double h) {
    @try {
        if (scene == nil || w < 50 || h < 50) return NO;
        SEL sel = NSSelectorFromString(@"updateSettingsWithBlock:");
        if (![scene respondsToSelector:sel]) return NO;
        // 单飞：缩放提交一次一调（transform live 期间不调），无并发窗口。
        ((AevonSDVoidFnBlock1)objc_msgSend)(scene, sel, ^(id settings) {
            @try {
                AevonSDSetRect(settings, "frame", CGRectMake(0, 0, w, h));
                AevonSDSetBool(settings, "foreground", YES);
            } @catch (NSException *exception) {
                // 画布写失败不影响其他 settings
            }
        });
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

/* V0.2.42（AevonMainSceneResizeV242）：S2 —— 把「已在运行的主场景」画布改成画布尺寸。
 * 只写 frame，绝不写 foreground / deactivationReasons —— 主场景的前台状态机归系统
 * （写它就是抢同一份状态，归档(12)(13)(14) 的 SIGTRAP 来源）。
 * 走 updateSettingsWithBlock:（与自建场景 resize 同一条 API，SB 进程内可用）；
 * 主场景可能被 FrontBoard 重算回写，调用方要做读回复查（防回弹）。 */
BOOL AevonMainSceneSetFrame(id scene, double w, double h) {
    @try {
        if (scene == nil || w < 50 || h < 50) return NO;
        SEL sel = NSSelectorFromString(@"updateSettingsWithBlock:");
        if (![scene respondsToSelector:sel]) return NO;
        __block BOOL wrote = NO;
        ((AevonSDVoidFnBlock1)objc_msgSend)(scene, sel, ^(id settings) {
            @try {
                AevonSDSetRect(settings, "frame", CGRectMake(0, 0, w, h));
                wrote = YES;
            } @catch (NSException *exception) {
                // 单次写入失败：由读回复查暴露，不在这里抛
            }
        });
        return wrote;
    } @catch (NSException *exception) {
        return NO;
    }
}

/// 只读取回：主场景 settings.frame 与 foreground / contentState（判 S2 是否被回弹）。
NSString *AevonMainSceneFrameState(id scene) {
    @try {
        if (scene == nil) { return @"frame=nil"; }
        NSString *frameText = @"?";
        SEL setSel = NSSelectorFromString(@"settings");
        if ([scene respondsToSelector:setSel]) {
            id settings = ((AevonSDIdFn0)objc_msgSend)(scene, setSel);
            SEL fSel = NSSelectorFromString(@"frame");
            if (settings != nil && [settings respondsToSelector:fSel]) {
                CGRect f = ((AevonSDRectFn0)objc_msgSend)(settings, fSel);
                frameText = [NSString stringWithFormat:@"%dx%d",
                             (int)(f.size.width + 0.5), (int)(f.size.height + 0.5)];
            }
            BOOL fg = NO;
            SEL fgSel = NSSelectorFromString(@"foreground");
            if ([settings respondsToSelector:fgSel]) {
                fg = ((AevonSDIntFn0)objc_msgSend)(settings, fgSel) != 0;
            }
            NSInteger cs = -1;
            SEL csSel = NSSelectorFromString(@"contentState");
            if ([scene respondsToSelector:csSel]) {
                cs = ((AevonSDIntFn0)objc_msgSend)(scene, csSel);
            }
            return [NSString stringWithFormat:@"frame=%@ fg=%d cs=%ld", frameText, fg ? 1 : 0, (long)cs];
        }
        return [NSString stringWithFormat:@"frame=%@ fg=? cs=?", frameText];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"frame=exc(%@)", exception.name];
    }
}

/// V0.2.47（AevonDarkGuardV247）：只读 —— contentState（-1 = 取不到）。
NSInteger AevonSceneContentState(id scene) {
    @try {
        if (scene == nil) { return -1; }
        SEL csSel = NSSelectorFromString(@"contentState");
        if (![scene respondsToSelector:csSel]) { return -1; }
        return ((AevonSDIntFn0)objc_msgSend)(scene, csSel);
    } @catch (NSException *exception) {
        return -1;
    }
}

/// V0.2.47（AevonDarkGuardV247）：只读 —— layerManager.layers 数量（-1 = 取不到）。
NSInteger AevonSceneLayerCount(id scene) {
    @try {
        if (scene == nil) { return -1; }
        SEL lmSel = NSSelectorFromString(@"layerManager");
        if (![scene respondsToSelector:lmSel]) { return -1; }
        id lm = ((AevonSDIdFn0)objc_msgSend)(scene, lmSel);
        if (lm == nil) { return -1; }
        SEL layersSel = NSSelectorFromString(@"layers");
        if (![lm respondsToSelector:layersSel]) { return -1; }
        id layers = ((AevonSDIdFn0)objc_msgSend)(lm, layersSel);
        if (![layers isKindOfClass:[NSArray class]]) { return -1; }
        return (NSInteger)[(NSArray *)layers count];
    } @catch (NSException *exception) {
        return -1;
    }
}

BOOL AevonSelfSceneDestroy(id scene) {
    @try {
        if (scene == nil) return NO;
        NSString *sceneID = nil;
        SEL idSel = NSSelectorFromString(@"identifier");
        if ([scene respondsToSelector:idSel]) {
            sceneID = ((AevonSDIdFn0)objc_msgSend)(scene, idSel);
        }
        id manager = AevonSDClassFactory(@"FBSceneManager", @"sharedInstance");
        if (manager == nil || sceneID.length == 0) return NO;
        SEL destroySel = NSSelectorFromString(@"destroyScene:withTransitionContext:");
        if (![manager respondsToSelector:destroySel]) return NO;

        // V0.2.34（AevonSelfSceneTakeoverV234）：销毁前先广播，让 App 侧把
        // 搬进自建场景的主 UIWindow 搬回主场景，再延迟销毁 —— 不给时间的话
        // window 会挂在已断开的场景上，App 回前台就是黑屏。
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.aevon.selfscene.destroyed"),
                                             NULL, NULL, true);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                SEL destroySel2 = NSSelectorFromString(@"destroyScene:withTransitionContext:");
                if ([manager respondsToSelector:destroySel2]) {
                    ((AevonSDIdFn2)objc_msgSend)(manager, destroySel2, sceneID, nil);
                }
            } @catch (NSException *exception) { /* 销毁失败不影响关窗主链 */ }
        });
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

/*
 * V0.2.32（AevonSelfSceneFGV232 / AevonForegroundProbeV232，0.2.31 真机实锤）：
 * 设置/电池数据等「多场景友好」App 真重排成功，抖音/Sileo 等「单场景」App 黑屏
 * （进程活着、声音在放 = 渲染没停，是自建场景没人画）。
 *
 * 两条证据链指向同一个机制：
 *   ① MultiFloat round8 档案：SB 重算 scene settings 把 foreground 写回 0 →
 *      contentState 2→0、layers 2→0 → 黑。判据 = contentState==2 / layers>0。
 *   ② LiveContainer #942：FBSSceneObserver 会优先发 resignActive，需要重申
 *      settings.foreground = YES + settings.deactivationReasons = 0（源码原文）。
 * 本版对策（全部只作用于自建场景——自建场景的 settings 写入是受支持通路；
 * 主场景的 deactivation 状态机仍然绝不碰，归档(14) SIGTRAP 教训）：
 *   ① AevonSelfSceneReassertForeground：重申前台（保活定时器改打自建场景）；
 *   ② AevonSelfSceneContentAlive：真首帧判定（结构性子视图 ≠ App 真画了，
 *      0.2.31 抖音 4ms 就「首帧已到达」是假首帧，把诊断和看门狗全骗停了）；
 *   ③ AevonSelfSceneDebugState：只读取证串（fg/cs/layers/dr/idle），
 *      下轮日志直接判断黑在哪一层。
 */

/// 重申自建场景前台：updateSettings { foreground=YES; deactivationReasons=0; }。
/// LiveContainer #942 同款；只许对自建场景调用。
BOOL AevonSelfSceneReassertForeground(id scene) {
    @try {
        if (scene == nil) return NO;
        SEL sel = NSSelectorFromString(@"updateSettingsWithBlock:");
        if (![scene respondsToSelector:sel]) return NO;
        ((AevonSDVoidFnBlock1)objc_msgSend)(scene, sel, ^(id settings) {
            @try {
                AevonSDSetBool(settings, "foreground", YES);
                AevonSDSetInt(settings, "deactivationReasons", 0);
            } @catch (NSException *exception) {
                // 单项写失败不影响其他
            }
        });
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

/// 真渲染判据（round8 档案）：contentState == 2 或 layerManager.layers 数 > 0。
/// 只许对自建场景调用（主场景保持 0.2.27 判定不变）。
BOOL AevonSelfSceneContentAlive(id scene) {
    @try {
        if (scene == nil) return NO;
        // contentState：FBScene 只读属性（NSInteger）
        SEL csSel = NSSelectorFromString(@"contentState");
        if ([scene respondsToSelector:csSel]) {
            NSInteger cs = ((AevonSDIntFn0)objc_msgSend)(scene, csSel);
            if (cs == 2) return YES;
        }
        // layerManager.layers：NSArray count
        SEL lmSel = NSSelectorFromString(@"layerManager");
        if ([scene respondsToSelector:lmSel]) {
            id lm = ((AevonSDIdFn0)objc_msgSend)(scene, lmSel);
            if (lm != nil) {
                SEL layersSel = NSSelectorFromString(@"layers");
                if ([lm respondsToSelector:layersSel]) {
                    id layers = ((AevonSDIdFn0)objc_msgSend)(lm, layersSel);
                    if ([layers isKindOfClass:[NSArray class]] && [(NSArray *)layers count] > 0) {
                        return YES;
                    }
                }
            }
        }
        return NO;
    } @catch (NSException *exception) {
        return NO;
    }
}

/// 只读取证串（全 @try，任何键取不到就 "?"）：
/// "fg=<0|1|?> cs=<n|?> layers=<n|?> dr=<n|?> idle=<0|1|?>"
NSString *AevonSelfSceneDebugState(id scene) {
    @try {
        if (scene == nil) return @"scene-nil";
        NSMutableString *out = [NSMutableString string];
        // foreground
        id settings = nil;
        SEL stSel = NSSelectorFromString(@"settings");
        if ([scene respondsToSelector:stSel]) {
            settings = ((AevonSDIdFn0)objc_msgSend)(scene, stSel);
        }
        if (settings != nil) {
            SEL fgSel = NSSelectorFromString(@"foreground");
            if ([settings respondsToSelector:fgSel]) {
                BOOL fg = ((BOOL (*)(id, SEL))objc_msgSend)(settings, fgSel);
                [out appendFormat:@"fg=%d", fg ? 1 : 0];
            } else { [out appendString:@"fg=?"]; }
            // deactivationReasons / idleModeEnabled
            SEL drSel = NSSelectorFromString(@"deactivationReasons");
            if ([settings respondsToSelector:drSel]) {
                NSInteger dr = ((AevonSDIntFn0)objc_msgSend)(settings, drSel);
                [out appendFormat:@" dr=%ld", (long)dr];
            } else { [out appendString:@" dr=?"]; }
            SEL idleSel = NSSelectorFromString(@"idleModeEnabled");
            if ([settings respondsToSelector:idleSel]) {
                BOOL idle = ((BOOL (*)(id, SEL))objc_msgSend)(settings, idleSel);
                [out appendFormat:@" idle=%d", idle ? 1 : 0];
            } else { [out appendString:@" idle=?"]; }
        } else {
            [out appendString:@"settings-nil"];
        }
        // contentState
        SEL csSel = NSSelectorFromString(@"contentState");
        if ([scene respondsToSelector:csSel]) {
            NSInteger cs = ((AevonSDIntFn0)objc_msgSend)(scene, csSel);
            [out appendFormat:@" cs=%ld", (long)cs];
        } else { [out appendString:@" cs=?"]; }
        // layers count
        SEL lmSel = NSSelectorFromString(@"layerManager");
        if ([scene respondsToSelector:lmSel]) {
            id lm = ((AevonSDIdFn0)objc_msgSend)(scene, lmSel);
            SEL layersSel = NSSelectorFromString(@"layers");
            if (lm != nil && [lm respondsToSelector:layersSel]) {
                id layers = ((AevonSDIdFn0)objc_msgSend)(lm, layersSel);
                if ([layers isKindOfClass:[NSArray class]]) {
                    [out appendFormat:@" layers=%lu", (unsigned long)[(NSArray *)layers count]];
                } else { [out appendString:@" layers=?"]; }
            } else { [out appendString:@" layers=?"]; }
        } else { [out appendString:@" layers=?"]; }
        return out;
    } @catch (NSException *exception) {
        return @"exception";
    }
}

/* V0.2.40（AevonSceneRouteV240）：二进制扫描 —— 权威判据落地。
 * 0.2.39 真机定论：①SBApplication 对 sceneSpecification/applicationSceneSpecification
 * **两个选择子都不响应**（sbApp=SBApplication 拿到了，sel=no/no）→ 全部 -1 → 全回退；
 * ②LSApplicationProxy→bundleURL→直接读 Info.plist 文件**完全可用**（plist=ok(40)）；
 * ③设置的 manifest 真容 = uiSceneDel=no uiMulti=0（**根本没有 scene delegate 类名**）
 * ——但它照样实现了 configurationForConnecting（0.2.33 App 侧探针）且真重排成功。
 * ⇒ 判据不在 manifest，在 **App 可执行文件是否实现该选择子**。选择子字符串以明文
 * 存于 __objc_methname 段 → 读 App 二进制 memmem 扫
 * "configurationForConnectingSceneSession"。分块扫（1MB+尾部重叠）防大文件爆内存；
 * 加密 App Store 应用扫不到 → 0/-1 → 保守旧路径（方向安全：它们本来就拒连）。
 * 返回 2 = 含（自建）/ 0 = 读毕未含（旧路径）/ -1 = 判不了（保守旧路径）。
 * 结果按 bundleID 缓存（判分与取证串共用，避免重复扫几百 MB）。 */
static NSMutableDictionary *AevonRouteScanCache = nil;
static NSObject *AevonRouteScanLock = nil;

static NSInteger AevonScanBinaryForSelector(NSString *path) {
    @try {
        FILE *f = fopen(path.fileSystemRepresentation, "rb");
        if (f == NULL) { return -1; }
        static const char needle[] = "configurationForConnectingSceneSession";
        const size_t nlen = sizeof(needle) - 1;
        const size_t CHUNK = 1u << 20;
        NSMutableData *buf = [NSMutableData dataWithLength:CHUNK + nlen];
        NSInteger verdict = -1;
        size_t carry = 0;
        for (;;) {
            size_t got = fread((char *)buf.mutableBytes + carry, 1, CHUNK, f);
            size_t total = carry + got;
            if (total >= nlen) {
                if (memmem(buf.bytes, total, needle, nlen) != NULL) { verdict = 2; break; }
            }
            if (got == 0) { verdict = ferror(f) ? -1 : 0; break; }
            carry = nlen - 1;
            memmove(buf.mutableBytes, (const char *)buf.bytes + total - carry, carry);
        }
        fclose(f);
        return verdict;
    } @catch (NSException *exception) {
        return -1;
    }
}

NSInteger AevonSelfSceneAppBinarySupport(NSString *bundleID) {
    if (AevonRouteScanLock == nil) { AevonRouteScanLock = [NSObject new]; }
    @synchronized (AevonRouteScanLock) {
        if (AevonRouteScanCache == nil) { AevonRouteScanCache = [NSMutableDictionary dictionary]; }
        NSNumber *cached = AevonRouteScanCache[bundleID];
        if (cached != nil) { return cached.integerValue; }
    }
    NSInteger verdict = -1;
    @try {
        if (bundleID.length == 0) { return -1; }
        Class lsCls = NSClassFromString(@"LSApplicationProxy");
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (lsCls == nil || ![(id)lsCls respondsToSelector:proxySel]) { return -1; }
        id proxy = ((AevonSDIdFn1)objc_msgSend)((id)lsCls, proxySel, bundleID);
        if (proxy == nil) { return -1; }
        SEL urlSel = NSSelectorFromString(@"bundleURL");
        if (![proxy respondsToSelector:urlSel]) { return -1; }
        NSURL *bundleURL = ((AevonSDIdFn0)objc_msgSend)(proxy, urlSel);
        if (![bundleURL isKindOfClass:[NSURL class]]) { return -1; }
        NSURL *plURL = [bundleURL URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfURL:plURL];
        NSString *exe = pl[@"CFBundleExecutable"];
        if (exe.length == 0) { return -1; }
        NSURL *binURL = [bundleURL URLByAppendingPathComponent:exe];
        verdict = AevonScanBinaryForSelector(binURL.path);
    } @catch (NSException *exception) {
        verdict = -1;
    }
    @synchronized (AevonRouteScanLock) {
        if (AevonRouteScanCache == nil) { AevonRouteScanCache = [NSMutableDictionary dictionary]; }
        AevonRouteScanCache[bundleID] = @(verdict);
    }
    return verdict;
}

/* V0.2.35~38 历史（AevonSceneRouteV235/236/237/238）：LSApplicationProxy 路线三连翻车。
 * 0.2.38 取证实锤：proxy 拿到了、infoDictionary respondsToSelector=ok，但**调用即抛
 * NSInvalidArgumentException**（roothide SB 进程）→ 三版黑屏组与成功组**全部 -1**，
 * 分流从未生效（0.2.38 白名单制把 -1 全挡旧路径 = 全部回退整屏，用户实测）。
 *
 * V0.2.39（AevonSceneRouteV239）：主路线换 SBApplication.sceneSpecification ——
 * 0.2.40 真机再定论：SBApplication 对两个选择子都**不响应**（sel=no/no）→ 也全 -1。
 *
 * V0.2.40（AevonSceneRouteV240）现行结构：
 *   A 路线 = SBApplication.sceneSpecification（选择子响应才用，其他 iOS 版本兜底）；
 *   B 路线 = App 二进制扫 "configurationForConnectingSceneSession"（新主路线，见上）。
 * 返回值语义：
 *   2 = 确证 scene App（可走自建场景，真重排）
 *   0 = 确证老式 App（走旧路径）
 *  -1 = 判不了（保守走旧路径，Swift 侧白名单制） */
NSInteger AevonSelfSceneAppSceneSupport(NSString *bundleID) {
    @try {
        if (bundleID.length == 0) { return -1; }
        Class ctlCls = NSClassFromString(@"SBApplicationController");
        if (ctlCls != nil) {
            SEL sharedSel = NSSelectorFromString(@"sharedInstance");
            if ([(id)ctlCls respondsToSelector:sharedSel]) {
                id controller = ((AevonSDIdFn0)objc_msgSend)((id)ctlCls, sharedSel);
                if (controller != nil) {
                    SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
                    if ([controller respondsToSelector:appSel]) {
                        id app = ((AevonSDIdFn1)objc_msgSend)(controller, appSel, bundleID);
                        if (app != nil) {
                            for (NSString *selName in @[@"sceneSpecification", @"applicationSceneSpecification"]) {
                                SEL sel = NSSelectorFromString(selName);
                                if (![app respondsToSelector:sel]) { continue; }
                                id spec = ((AevonSDIdFn0)objc_msgSend)(app, sel);
                                return (spec != nil) ? 2 : 0;
                            }
                        }
                    }
                }
            }
        }
        return AevonSelfSceneAppBinarySupport(bundleID);
    } @catch (NSException *exception) {
        return -1;
    }
}

/* V0.2.39（AevonSceneRouteV239）：分流取证 —— 双路线各段拼串 + 异常 reason。
 * A 路线 = SBApplication.sceneSpecification（新主路线）；
 * B 路线 = LSApplicationProxy.bundleURL → 直接读 Info.plist 文件
 *   （infoDictionary 抛异常的备选，本轮只取证不判分）。 */
NSString *AevonSelfSceneRouteDump(NSString *bundleID) {
    NSMutableString *out = [NSMutableString stringWithString:@"route2: "];
    @try {
        [out appendFormat:@"bid=%@ ", bundleID.length ? @"ok" : @"empty"];
        /* A 路线：SBApplication（V0.2.39 主路线） */
        Class ctlCls = NSClassFromString(@"SBApplicationController");
        [out appendFormat:@"ctlCls=%@ ", ctlCls ? @"ok" : @"nil"];
        if (!ctlCls) { return out; }
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if (![(id)ctlCls respondsToSelector:sharedSel]) { [out appendString:@"shared=no "]; return out; }
        id controller = ((AevonSDIdFn0)objc_msgSend)((id)ctlCls, sharedSel);
        [out appendFormat:@"ctl=%@ ", controller ? @"ok" : @"nil"];
        if (!controller) { return out; }
        SEL appSel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
        if (![controller respondsToSelector:appSel]) { [out appendString:@"appSel=no "]; return out; }
        id app = ((AevonSDIdFn1)objc_msgSend)(controller, appSel, bundleID);
        [out appendFormat:@"sbApp=%@ ", app ? NSStringFromClass([app class]) : @"nil"];
        if (!app) { return out; }
        for (NSString *selName in @[@"sceneSpecification", @"applicationSceneSpecification"]) {
            SEL sel = NSSelectorFromString(selName);
            if (![app respondsToSelector:sel]) { [out appendFormat:@"%@=no ", selName]; continue; }
            id spec = ((AevonSDIdFn0)objc_msgSend)(app, sel);
            [out appendFormat:@"%@=%@ ", selName, spec ? NSStringFromClass([spec class]) : @"nil"];
            if (spec != nil) {
                @try {
                    id del = [spec valueForKey:@"delegateClassName"];
                    id multi = [spec valueForKey:@"supportsMultipleScenes"];
                    [out appendFormat:@"del=%@ multi=%@ ",
                        del ?: (id)@"nil",
                        ([multi isKindOfClass:[NSNumber class]]
                            ? (((NSNumber *)multi).boolValue ? @"YES" : @"NO") : (id)@"nil")];
                } @catch (NSException *e2) {
                    [out appendFormat:@"specKVC=%@(%@) ", e2.name, e2.reason ?: @"-"];
                }
            }
        }
        /* B 路线：bundleURL → Info.plist 文件（只取证） */
        Class lsCls = NSClassFromString(@"LSApplicationProxy");
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (lsCls && [(id)lsCls respondsToSelector:proxySel]) {
            @try {
                id proxy = ((AevonSDIdFn1)objc_msgSend)((id)lsCls, proxySel, bundleID);
                [out appendFormat:@"proxy=%@ ", proxy ? @"ok" : @"nil"];
                if (proxy) {
                    SEL urlSel = NSSelectorFromString(@"bundleURL");
                    if ([proxy respondsToSelector:urlSel]) {
                        id u = ((AevonSDIdFn0)objc_msgSend)(proxy, urlSel);
                        [out appendFormat:@"bundleURL=%@ ", u ?: (id)@"nil"];
                        if ([u isKindOfClass:[NSURL class]]) {
                            NSURL *plURL = [(NSURL *)u URLByAppendingPathComponent:@"Info.plist"];
                            NSDictionary *pl = [NSDictionary dictionaryWithContentsOfURL:plURL];
                            [out appendFormat:@"plist=%@(%lu) ", pl ? @"ok" : @"nil",
                                pl ? (unsigned long)[pl count] : (unsigned long)0];
                            if (pl) {
                                id manifest = pl[@"UIApplicationSceneManifest"];
                                [out appendFormat:@"plistManifest=%@ ", manifest ? @"yes" : @"nil"];
                                if ([manifest isKindOfClass:[NSDictionary class]]) {
                                    NSDictionary *md = (NSDictionary *)manifest;
                                    [out appendFormat:@"mKeys=%@ ",
                                        [md.allKeys componentsJoinedByString:@","]];
                                    id configs = md[@"UISceneConfigurations"];
                                    if ([configs isKindOfClass:[NSDictionary class]]) {
                                        BOOL sceneDel = NO;
                                        for (id arr in ((NSDictionary *)configs).allValues) {
                                            if (![arr isKindOfClass:[NSArray class]]) { continue; }
                                            for (id item in (NSArray *)arr) {
                                                if ([item isKindOfClass:[NSDictionary class]]
                                                    && ((NSDictionary *)item)[@"UISceneDelegateClassName"] != nil) {
                                                    sceneDel = YES;
                                                    break;
                                                }
                                            }
                                            if (sceneDel) { break; }
                                        }
                                        [out appendFormat:@"sceneDel=%@ ", sceneDel ? @"yes" : @"no"];
                                    }
                                    [out appendFormat:@"uiSceneDel=%@ uiMulti=%@ ",
                                        md[@"UIApplicationSceneDelegateClassName"] ? @"yes" : @"no",
                                        md[@"UIApplicationSupportsMultipleScenes"] ?: (id)@"nil"];
                                }
                            }
                        }
                    } else { [out appendString:@"bundleURL=no "]; }
                }
            } @catch (NSException *e3) {
                [out appendFormat:@"LS=%@(%@) ", e3.name, e3.reason ?: @"-"];
            }
        }
        /* V0.2.40（AevonSceneRouteV240）：二进制扫描结果（判分主路线，带缓存） */
        @try {
            NSInteger binVerdict = AevonSelfSceneAppBinarySupport(bundleID);
            NSString *exeInfo = @"?";
            Class lsCls2 = NSClassFromString(@"LSApplicationProxy");
            SEL proxySel2 = NSSelectorFromString(@"applicationProxyForIdentifier:");
            if (lsCls2 && [(id)lsCls2 respondsToSelector:proxySel2]) {
                id proxy2 = ((AevonSDIdFn1)objc_msgSend)((id)lsCls2, proxySel2, bundleID);
                SEL urlSel2 = NSSelectorFromString(@"bundleURL");
                if (proxy2 && [proxy2 respondsToSelector:urlSel2]) {
                    NSURL *bURL = ((AevonSDIdFn0)objc_msgSend)(proxy2, urlSel2);
                    if ([bURL isKindOfClass:[NSURL class]]) {
                        NSDictionary *pl2 = [NSDictionary dictionaryWithContentsOfURL:
                                             [bURL URLByAppendingPathComponent:@"Info.plist"]];
                        NSString *exe = pl2[@"CFBundleExecutable"];
                        if (exe.length) {
                            NSURL *binURL = [bURL URLByAppendingPathComponent:exe];
                            NSDictionary *attr = [NSFileManager.defaultManager
                                                  attributesOfItemAtPath:binURL.path error:NULL];
                            exeInfo = [NSString stringWithFormat:@"%@(%@B)", exe,
                                       attr[NSFileSize] ?: @"?"];
                        }
                    }
                }
            }
            [out appendFormat:@"bin=%@ scan=%ld ", exeInfo, (long)binVerdict];
        } @catch (NSException *e4) {
            [out appendFormat:@"BIN=%@(%@) ", e4.name, e4.reason ?: @"-"];
        }
        return out;
    } @catch (NSException *exception) {
        [out appendFormat:@"EXC=%@(%@) ", exception.name, exception.reason ?: @"-"];
        return out;
    }
}

/* V0.2.41（AevonSceneCapsV241）：读 App 侧能力登记表（进程内权威判据的落地）。
 * 文件由 App 侧 AevonAppSceneCapRegistry 写（/var/mobile/aevon_caps.txt，
 * `bundleID=1/0` 逐行）：1 = delegate 实现 configurationForConnecting（自建可接受），
 * 0 = 未实现（老式，必拒 → 旧路径），-1 = 该 App 从未登记（未知 → 调用方维持自建）。*/
NSInteger AevonSelfSceneAppCapVerdict(NSString *bundleID) {
    @try {
        if (bundleID.length == 0) { return -1; }
        NSString *raw = [NSString stringWithContentsOfFile:@"/var/mobile/aevon_caps.txt"
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        if (raw.length == 0) { return -1; }
        for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) { continue; }
            if (![[line substringToIndex:eq.location] isEqualToString:bundleID]) { continue; }
            NSString *value = [line substringFromIndex:eq.location + 1];
            return [value isEqualToString:@"1"] ? 1 : 0;
        }
        return -1;
    } @catch (NSException *exception) {
        return -1;
    }
}

/* V0.2.35（AevonSceneRouteV235）：连接取证（只读）。
 * client = FBSceneClient（App 端接上后非空）；clientPort 同理。
 * 分流误判的 App（有 manifest 仍被拒）靠这串定界：FB 层就没客户端 vs App 端拒。 */
NSString *AevonSelfSceneConnectionState(id scene) {
    @try {
        if (scene == nil) { return @"scene-nil"; }
        NSMutableString *out = [NSMutableString string];
        for (NSString *key in @[@"client", @"clientPort"]) {
            id v = nil;
            @try { v = [scene valueForKey:key]; } @catch (NSException *e) { v = nil; }
            NSString *desc = @"nil";
            if ([v isKindOfClass:[NSString class]]) {
                desc = v;
            } else if (v != nil) {
                SEL pidSel = NSSelectorFromString(@"pid");
                if ([v respondsToSelector:pidSel]) {
                    desc = [NSString stringWithFormat:@"<%@ pid=%ld>",
                            NSStringFromClass([v class]), (long)((NSInteger (*)(id, SEL))objc_msgSend)(v, pidSel)];
                } else {
                    desc = NSStringFromClass([v class]);
                }
            }
            [out appendFormat:@"%@=%@ ", key, desc];
        }
        return out;
    } @catch (NSException *exception) {
        return @"exception";
    }
}

/* ── V0.2.49（AevonNoAutoLockV249）：压住系统空闲熄屏 ────────────────────────
 *
 * Aevon(24)：「悬浮窗打开期间，依旧会跟随系统时间暗屏锁屏」。
 * 0.2.48 的 `UIApplication.shared.isIdleTimerDisabled = true` 在 SpringBoard 进程里
 * 不进 SpringBoard 自己的空闲计时器（它归 SBIdleTimerGlobalCoordinator 管），
 * 所以日志写着「已禁用」，屏幕照样按「自动锁定」暗下去。
 *
 * 这里做的是 iOS 上公认的「caffeine」写法：找到 SpringBoard 的全局空闲计时协调器，
 * 每调一次 resetIdleTimer 就等于告诉系统「用户又动了」，空闲计时重新起表。
 * 全链选择子探测 + @try，任何一步不存在就降级 —— 绝不因为私有 API 改名而崩。
 * 调用频率由调用方控制（20 秒一次），本函数自身不做任何计时。 */
__attribute__((used)) static const char AevonNoAutoLockV249Marker[] = "AevonNoAutoLockV249";
__attribute__((used)) static const char AevonIdleKickProbeV249Marker[] = "AevonIdleKickV249";
NSInteger AevonIdleTimerKick(void) {
    NSInteger mask = 0;
    @try {
        NSArray<NSString *> *coordinatorNames = @[@"SBIdleTimerGlobalCoordinator",
                                                  @"SBIdleTimerCoordinatorHelper",
                                                  @"SBIdleTimerGlobalStateMonitor"];
        id coordinator = nil;
        for (NSString *name in coordinatorNames) {
            Class cls = NSClassFromString(name);
            if (cls == Nil) { continue; }
            SEL sharedSel = NSSelectorFromString(@"sharedInstance");
            if ([cls respondsToSelector:sharedSel]) {
                coordinator = ((AevonSDIdFn0)objc_msgSend)((id)cls, sharedSel);
            }
            if (coordinator == nil) {
                SEL shared2 = NSSelectorFromString(@"sharedCoordinator");
                if ([cls respondsToSelector:shared2]) {
                    coordinator = ((AevonSDIdFn0)objc_msgSend)((id)cls, shared2);
                }
            }
            if (coordinator != nil) { break; }
        }
        if (coordinator != nil) {
            SEL resetSel = NSSelectorFromString(@"resetIdleTimer");
            if ([coordinator respondsToSelector:resetSel]) {
                ((AevonSDVoidFn0)objc_msgSend)(coordinator, resetSel);
                mask |= 1;
            }
            SEL undimSel = NSSelectorFromString(@"resetIdleTimerAndUndim:");
            if ([coordinator respondsToSelector:undimSel]) {
                ((AevonSDVoidFnBool1)objc_msgSend)(coordinator, undimSel, YES);
                mask |= 2;
            }
        }
    } @catch (NSException *exception) {
        /* 私有 API 抛异常：继续走下面的兜底，绝不上抛 */
    }
    // 兜底：与 0.2.48 同一条写入（部分机型 / 部分版本上它确实有效）
    @try {
        Class appCls = NSClassFromString(@"UIApplication");
        SEL sharedSel = NSSelectorFromString(@"sharedApplication");
        if (appCls != Nil && [appCls respondsToSelector:sharedSel]) {
            id app = ((AevonSDIdFn0)objc_msgSend)((id)appCls, sharedSel);
            SEL setSel = NSSelectorFromString(@"setIdleTimerDisabled:");
            if (app != nil && [app respondsToSelector:setSel]) {
                ((AevonSDVoidFnBool1)objc_msgSend)(app, setSel, YES);
                mask |= 4;
            }
        }
    } @catch (NSException *exception) {
    }
    return mask;
}

/* ── V0.2.49 标记锚（Aevon(24) 九项）────────────────────────────────────────
 * 这些常量本身不参与逻辑，只保证标记串进二进制 —— 字节复检用 strings 逐条命中。
 * （C 函数名与 Swift 常量名都不在 __TEXT 内容里，只靠源码 grep 抓不到产物。） */
__attribute__((used)) static const char AevonGlowTightV249Marker[] = "AevonGlowTightV249";
__attribute__((used)) static const char AevonFloatAnimV249Marker[] = "AevonFloatAnimV249";
__attribute__((used)) static const char AevonRelayoutKickV249Marker[] = "AevonRelayoutKickV249";
__attribute__((used)) static const char AevonUnlockGuardV249Marker[] = "AevonUnlockGuardV249";
__attribute__((used)) static const char AevonDarkGuardV249Marker[] = "AevonDarkGuardV249";
__attribute__((used)) static const char AevonCloseSettleV249Marker[] = "AevonCloseSettleV249";
