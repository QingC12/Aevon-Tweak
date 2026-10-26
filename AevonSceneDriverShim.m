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

/// CI 标记锚（used 常量；ObjC used 常量是 strings 检查的最可靠载体）
__attribute__((used)) static const char AevonSelfSceneV228Marker[] = "AevonSelfSceneV228";
__attribute__((used)) static const char AevonSelfSceneFallbackV228Marker[] = "AevonSelfSceneFallbackV228";
__attribute__((used)) static const char AevonSelfSceneFixV229Marker[] = "AevonSelfSceneFixV229";
__attribute__((used)) static const char AevonSelfSceneRBSV230Marker[] = "AevonSelfSceneRBSV230";
__attribute__((used)) static const char AevonSelfScenePidV231Marker[] = "AevonSelfScenePidV231";

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
    id clientIdentity = AevonSDClassFactory1(@"FBSSceneClientIdentity",
                                             @"identityForProcessIdentity:", processIdentity);
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
        ((AevonSDIdFn2)objc_msgSend)(manager, destroySel, sceneID, nil);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
