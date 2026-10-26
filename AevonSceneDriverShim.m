#import "AevonSceneDriverShim.h"
#import <objc/message.h>

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

/* V0.2.35（AevonSceneRouteV235）：创建前分流判据。
 * UIKit 的规则：Info.plist 有 UIApplicationSceneManifest = scene 生命周期 App，
 * 自建场景的连接请求会进 App 端 UIKit 正常建 session（设置/GitHub/Safari 实证）；
 * 无 manifest = 老式单场景 App，UIKit 自动桥接只认主场景，第二场景连接被拒
 * （0.2.34 真机：Sileo connectedScenes 8 秒无自建场景）。
 *
 * V0.2.36（AevonSceneRouteV236）细判一档：0.2.35 真机显示「有 manifest」不够——
 * UIApplicationSupportsMultipleScenes 缺省 NO，单场景 manifest App（Sileo/抖音/
 * 微信）第二场景连接同样被拒。返回值语义：
 *   2 = 多场景 App（UIApplicationSupportsMultipleScenes=YES）→ 可走自建场景
 *   1 = 有 manifest 但单场景（键缺失或为 NO）→ 走旧路径
 *   0 = 无 manifest（老式 App）→ 走旧路径
 *  -1 = 取证失败（proxy/info 拿不到）→ 由调用方保守处理 */
NSInteger AevonSelfSceneAppSceneSupport(NSString *bundleID) {
    @try {
        if (bundleID.length == 0) { return -1; }
        Class lsCls = NSClassFromString(@"LSApplicationProxy");
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (lsCls == nil || ![(id)lsCls respondsToSelector:proxySel]) { return -1; }
        id proxy = ((AevonSDIdFn1)objc_msgSend)((id)lsCls, proxySel, bundleID);
        if (proxy == nil) { return -1; }
        NSDictionary *info = nil;
        SEL infoSel = NSSelectorFromString(@"infoDictionary");
        if ([proxy respondsToSelector:infoSel]) {
            info = ((AevonSDIdFn0)objc_msgSend)(proxy, infoSel);
        }
        if (info == nil) { return -1; }
        id manifest = info[@"UIApplicationSceneManifest"];
        if (manifest == nil) { return 0; }
        if (![manifest isKindOfClass:[NSDictionary class]]) { return 1; }
        // V0.2.37（AevonSceneRouteV237）：manifest 里必须真的写了 scene delegate
        // 类名 —— 老式 AppDelegate 自动桥接的 App（Sileo/Filza/抖音/微信，App 侧
        // 探针实锤「未实现 configurationForConnecting」）manifest 就算写满
        // UIApplicationSupportsMultipleScenes=YES 第二场景连接也必拒。
        BOOL hasDelegate = NO;
        id configs = ((NSDictionary *)manifest)[@"UISceneConfigurations"];
        if ([configs isKindOfClass:[NSDictionary class]]) {
            for (id arr in ((NSDictionary *)configs).allValues) {
                if (![arr isKindOfClass:[NSArray class]]) { continue; }
                for (id item in (NSArray *)arr) {
                    if ([item isKindOfClass:[NSDictionary class]]
                        && ((NSDictionary *)item)[@"UISceneDelegateClassName"] != nil) {
                        hasDelegate = YES;
                        break;
                    }
                }
                if (hasDelegate) { break; }
            }
        }
        if (!hasDelegate && ((NSDictionary *)manifest)[@"UIApplicationSceneDelegateClassName"] != nil) {
            hasDelegate = YES;
        }
        if (!hasDelegate) { return 1; } /* 老式自动桥接 → App 端必拒 → 旧路径 */
        // V0.2.36（AevonSceneRouteV236）：细判 UIApplicationSupportsMultipleScenes。
        id multi = ((NSDictionary *)manifest)[@"UIApplicationSupportsMultipleScenes"];
        if ([multi isKindOfClass:[NSNumber class]]) { return [multi boolValue] ? 2 : 1; }
        if ([multi isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)multi;
            BOOL yes = [s caseInsensitiveCompare:@"YES"] == NSOrderedSame
                    || [s caseInsensitiveCompare:@"true"] == NSOrderedSame
                    || [s isEqualToString:@"1"];
            return yes ? 2 : 1;
        }
        return 1; /* 键缺失 = iOS 文档缺省 NO = 单场景 */
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
