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

typedef id (*AevonSDIdFn0)(id, SEL);
typedef id (*AevonSDIdFn1)(id, SEL, id);
typedef void (*AevonSDVoidFn0)(id, SEL);
typedef void (*AevonSDVoidFnBool1)(id, SEL, BOOL);
typedef void (*AevonSDVoidFnInt1)(id, SEL, NSInteger);
typedef void (*AevonSDVoidFnRect1)(id, SEL, CGRect);
typedef void (*AevonSDVoidFnInsets1)(id, SEL, UIEdgeInsets);
typedef void (*AevonSDVoidFnBlock1)(id, SEL, void (^)(id));

/// CI 标记锚（used 常量；ObjC used 常量是 strings 检查的最可靠载体）
__attribute__((used)) static const char AevonSelfSceneV228Marker[] = "AevonSelfSceneV228";
__attribute__((used)) static const char AevonSelfSceneFallbackV228Marker[] = "AevonSelfSceneFallbackV228";

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

/// KVC 取运行中 App 的进程句柄（SBApplication.processHandle）。
static id AevonSDAppProcessHandle(NSString *bundleID) {
    id app = AevonSDClassFactory1(@"SBApplicationController",
                                  @"applicationWithBundleIdentifier:", bundleID);
    if (app == nil) return nil;
    for (NSString *key in @[@"processHandle", @"_processHandle"]) {
        id handle = nil;
        @try { handle = [app valueForKey:key]; } @catch (NSException *exception) { handle = nil; }
        if (handle != nil) return handle;
    }
    return nil;
}

id AevonSelfSceneCreate(NSString *bundleID, double w, double h,
                        NSString **outSceneID, NSString **outErr) {
    NSString *step = @"";
    @try {
        if (outErr) { *outErr = nil; }
        if (outSceneID) { *outSceneID = nil; }
        if (bundleID.length == 0) { step = @"bundleID-empty"; goto fail; }
        if (w < 50 || h < 50) { step = @"size-invalid"; goto fail; }

        // ── 1. 运行中 App 的进程身份（clientIdentity 必须指向已存在的进程）──
        step = @"process-handle";
        id handle = AevonSDAppProcessHandle(bundleID);
        if (handle == nil) { step = @"app-not-running"; goto fail; }
        id processIdentity = nil;
        for (NSString *key in @[@"identity", @"processIdentity"]) {
            @try { processIdentity = [handle valueForKey:key]; } @catch (NSException *exception) { processIdentity = nil; }
            if (processIdentity != nil) break;
        }
        if (processIdentity == nil) { step = @"process-identity"; goto fail; }

        // ── 2. 场景管理器 ──
        step = @"fb-manager";
        id manager = AevonSDClassFactory(@"FBSceneManager", @"sharedInstance");
        if (manager == nil) { step = @"fb-manager-nil"; goto fail; }

        // ── 3. 唯一身份（绝不与主场景 sceneID:<bid>-default 撞，round7 教训）──
        step = @"identity";
        NSString *sceneID = [NSString stringWithFormat:@"sceneID:com.aevon.float-%@", bundleID];

        // 遗留场景先销毁（respring 后我们没来得及收尾的情况）
        SEL sceneByIdSel = NSSelectorFromString(@"sceneWithIdentifier:");
        if ([manager respondsToSelector:sceneByIdSel]) {
            id leftover = ((AevonSDIdFn1)objc_msgSend)(manager, sceneByIdSel, sceneID);
            if (leftover != nil) {
                SEL destroySel = NSSelectorFromString(@"destroyScene:withTransitionContext:");
                if ([manager respondsToSelector:destroySel]) {
                    ((AevonSDIdFn1)objc_msgSend)(manager, destroySel, sceneID, nil);
                }
            }
        }

        // ── 4. 场景定义（identity / clientIdentity / specification）──
        step = @"definition";
        id definition = AevonSDClassFactory(@"FBSMutableSceneDefinition", @"definition");
        if (definition == nil) { step = @"definition-nil"; goto fail; }
        id sceneIdentity = AevonSDClassFactory1(@"FBSSceneIdentity",
                                                @"identityForIdentifier:", sceneID);
        if (sceneIdentity == nil) { step = @"scene-identity-nil"; goto fail; }
        AevonSDSetObject(definition, "identity", sceneIdentity);
        id clientIdentity = AevonSDClassFactory1(@"FBSSceneClientIdentity",
                                                 @"identityForProcessIdentity:", processIdentity);
        if (clientIdentity == nil) { step = @"client-identity-nil"; goto fail; }
        AevonSDSetObject(definition, "clientIdentity", clientIdentity);
        id specification = AevonSDClassFactory(@"UIApplicationSceneSpecification", @"specification");
        if (specification == nil) { step = @"specification-nil"; goto fail; }
        AevonSDSetObject(definition, "specification", specification);

        // ── 5. 初始参数：settings 画布 ★创建时烙定（真重排的立身之本）──
        step = @"parameters";
        id parameters = AevonSDClassFactory1(@"FBSMutableSceneParameters",
                                             @"parametersForSpecification:", specification);
        if (parameters == nil) { step = @"parameters-nil"; goto fail; }

        Class settingsCls = NSClassFromString(@"UIMutableApplicationSceneSettings");
        if (settingsCls == nil) { step = @"settings-class-nil"; goto fail; }
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
        step = @"create-scene";
        SEL createSel = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
        if (![manager respondsToSelector:createSel]) { step = @"create-sel-missing"; goto fail; }
        id scene = ((AevonSDIdFn1)objc_msgSend)(manager, createSel, definition, parameters);
        if (scene == nil) { step = @"scene-nil"; goto fail; }

        if (outSceneID) { *outSceneID = sceneID; }
        return scene;

    fail:
        if (outErr) { *outErr = step; }
        return nil;
    } @catch (NSException *exception) {
        if (outErr) { *outErr = [NSString stringWithFormat:@"exception:%@", exception.name]; }
        return nil;
    }
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
        ((AevonSDIdFn1)objc_msgSend)(manager, destroySel, sceneID, nil);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
