#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/*
 * App 场景容器钩子（V0.0.22）。
 *
 * 为什么要 hook：
 *   SpringBoard 把前台 App 的画面放在 `SBDeviceApplicationSceneViewController` 的 view 里，
 *   它**不是 UIWindow**，所以窗口层级（哪怕 1e7）也压不过它 —— 这就是 V0.0.19–V0.0.21
 *   一直解决不了「全屏 App 里看不到右侧触发条」的原因。想压住 App，只能把入口视图
 *   塞进同一个 view，并且是这个 view 的最后一个子视图。
 *   逆向数据（Stheno.dylib）里同样只有一个 `SBDeviceApplicationSceneViewControllerHook`，
 *   走的正是这条路。
 *
 * 为什么只 hook 两个方法：
 *   viewDidAppear / viewDidDisappear 足以判断「App 画面进来了 / 走了」，
 *   不会介入布局流程（规避布局递归），也不改任何系统行为 —— 回调里只做一件事：
 *   通知 Swift 侧把入口容器搬过去 / 搬回来。
 *
 * 安全性：全程 @try/@catch，任何异常都不外抛；类不存在时静默跳过。
 */

extern void AevonSceneVCDidAppear(UIViewController *vc, NSString *bundleID);
extern void AevonSceneVCDidDisappear(UIViewController *vc);

static IMP AevonOrigDidAppear = NULL;
static IMP AevonOrigDidDisappear = NULL;
static BOOL AevonSceneHookInstalled = NO;

/* ── V0.0.62（AevonFrontmostIDV62）：从场景 VC 深挖宿主 App 的 bundleID ──
 * V59/V61 在 Swift 侧做字符串键探测（scene/representedScene/hostScene/_scene →
 * identifier/persistentIdentifier），真机日志（Aevon(55)）显示恒失败（「前台场景=无」），
 * 导致关浮窗后屏幕无法滑动的修复从未生效。
 * 根因：SB 场景对象是 FBScene，它的 identifier 是 FBSceneIdentity **对象**
 * （不是 NSString），`as? String` 永远失败。
 * 这里在 ObjC 层多策略深挖：
 *   ① 常见属性键拿 FBScene（representedScene / scene / hostedScene / _scene）
 *   ② ivar 遍历 VC，找类型为 FBScene 的 ivar（不靠猜名字）
 *   ③ 从 FBScene 拿 bundleID：sceneIdentifier（Stheno/TrollOpen 逆向数据实锤的键）
 *      / identity.bundleIdentifier / bundleIdentifier
 *   ④ FBScene 的 ivar 遍历找 FBSceneIdentity → bundleIdentifier（同样不靠猜名字）
 *   ⑤ 兜底：VC 自身 ivar 里找「形如 bundleID 的 NSString」（含 '.' 且无空格）
 * 任何一步拿到合法 bundleID 即返回；全程 @try/@catch，失败返回 nil（只影响
 * 关窗休眠的精确性，不影响显示）。 */
static BOOL AevonLooksLikeBundleID(NSString *s) {
    if (s == nil || s.length < 4) { return NO; }
    if ([s containsString:@" "] || [s containsString:@"/"]) { return NO; }
    return [s containsString:@"."];
}

/* V0.0.63（AevonIvarSafeV63）：V62 在真机上把 SpringBoard 搞崩（自动注销）。
 * 根因：ivar 遍历里不检查类型编码就调 object_getIvar —— 非对象类型 ivar
 * （BOOL / 整型 / CGRect / char[]）的原始字节被当成对象指针，
 * 后续 isKindOfClass 解引用垃圾地址 → SIGSEGV。ObjC 的 @try 捕不了信号。
 * 修复：**只有类型编码以 '@' 开头的 ivar 才允许 object_getIvar**；
 * getter 调用前也检查方法返回类型编码必须是对象。 */

static BOOL AevonIvarIsObjectType(Ivar ivar) {
    const char *enc = ivar_getTypeEncoding(ivar);
    return enc != NULL && enc[0] == '@';
}

static BOOL AevonGetterReturnsObject(id obj, SEL sel) {
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (m == NULL) { return NO; }
    const char *enc = method_getTypeEncoding(m);
    /* 类型编码开头是返回类型（可能带数字长度前缀），对象返回是 '@' */
    while (enc != NULL && *enc >= '0' && *enc <= '9') { enc++; }
    return enc != NULL && enc[0] == '@';
}

static NSString *AevonStringFromObject(id obj, NSString *key) {
    if (obj == nil || key.length == 0) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(key);
        if (![obj respondsToSelector:sel]) { return nil; }
        if (!AevonGetterReturnsObject(obj, sel)) { return nil; }
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id result = fn(obj, sel);
        if ([result isKindOfClass:[NSString class]]) { return result; }
    } @catch (NSException *unused) {}
    return nil;
}

static NSString *AevonBundleIDFromIdentity(id identity) {
    if (identity == nil) { return nil; }
    NSString *direct = AevonStringFromObject(identity, @"bundleIdentifier");
    if (AevonLooksLikeBundleID(direct)) { return direct; }
    /* FBSceneIdentity 的 ivar 遍历：找形如 bundleID 的 NSString（不猜名字）。
     * 只读对象类型 ivar（AevonIvarSafeV63）。 */
    @try {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(object_getClass(identity), &count);
        for (unsigned int i = 0; i < count && ivars != NULL; i++) {
            if (!AevonIvarIsObjectType(ivars[i])) { continue; }
            id value = object_getIvar(identity, ivars[i]);
            if ([value isKindOfClass:[NSString class]] && AevonLooksLikeBundleID(value)) {
                free(ivars);
                return value;
            }
        }
        if (ivars != NULL) { free(ivars); }
    } @catch (NSException *unused) {}
    return nil;
}

static NSString *AevonBundleIDFromScene(id scene) {
    if (scene == nil) { return nil; }
    /* ③ 常见键（sceneIdentifier 是 Stheno/TrollOpen 逆向数据实锤的字符串键） */
    for (NSString *key in @[@"sceneIdentifier", @"bundleIdentifier"]) {
        NSString *s = AevonStringFromObject(scene, key);
        if (AevonLooksLikeBundleID(s)) { return s; }
    }
    /* identity 键 → FBSceneIdentity → bundleIdentifier */
    @try {
        SEL identitySel = NSSelectorFromString(@"identity");
        if ([scene respondsToSelector:identitySel] && AevonGetterReturnsObject(scene, identitySel)) {
            id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            NSString *s = AevonBundleIDFromIdentity(fn(scene, identitySel));
            if (s != nil) { return s; }
        }
    } @catch (NSException *unused) {}
    /* ④ FBScene ivar 遍历：找 FBSceneIdentity 类型 ivar（不猜名字） */
    @try {
        Class identityCls = NSClassFromString(@"FBSceneIdentity");
        if (identityCls != Nil) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(object_getClass(scene), &count);
            for (unsigned int i = 0; i < count && ivars != NULL; i++) {
                if (!AevonIvarIsObjectType(ivars[i])) { continue; }
                id value = object_getIvar(scene, ivars[i]);
                if (value != nil && [value isKindOfClass:identityCls]) {
                    NSString *s = AevonBundleIDFromIdentity(value);
                    if (s != nil) { free(ivars); return s; }
                }
            }
            if (ivars != NULL) { free(ivars); }
        }
    } @catch (NSException *unused) {}
    return nil;
}

static NSString *AevonSceneBundleIDFromVC(UIViewController *vc) {
    @try {
        /* ① 常见属性键直接拿 FBScene */
        for (NSString *key in @[@"representedScene", @"scene", @"hostedScene", @"_scene"]) {
            @try {
                SEL sel = NSSelectorFromString(key);
                if (![vc respondsToSelector:sel]) { continue; }
                if (!AevonGetterReturnsObject(vc, sel)) { continue; }
                id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id scene = fn(vc, sel);
                if (scene == nil || [scene isKindOfClass:[NSString class]]) { continue; }
                NSString *s = AevonBundleIDFromScene(scene);
                if (s != nil) { return s; }
            } @catch (NSException *unused) {}
        }
        /* ② VC 的 ivar 遍历找 FBScene（iOS 17.3.1 属性名未知时靠类型匹配）。
         * 只读对象类型 ivar（AevonIvarSafeV63：非对象 ivar 当指针读 = SIGSEGV）。 */
        Class sceneCls = NSClassFromString(@"FBScene");
        if (sceneCls != Nil) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList([vc class], &count);
            for (unsigned int i = 0; i < count && ivars != NULL; i++) {
                if (!AevonIvarIsObjectType(ivars[i])) { continue; }
                id value = object_getIvar(vc, ivars[i]);
                if (value != nil && [value isKindOfClass:sceneCls]) {
                    NSString *s = AevonBundleIDFromScene(value);
                    if (s != nil) { free(ivars); return s; }
                }
            }
            if (ivars != NULL) { free(ivars); }
        }
        /* ⑤ 兜底：VC 自身 ivar 里找形如 bundleID 的 NSString（同样只读对象类型） */
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([vc class], &count);
        for (unsigned int i = 0; i < count && ivars != NULL; i++) {
            if (!AevonIvarIsObjectType(ivars[i])) { continue; }
            id value = object_getIvar(vc, ivars[i]);
            if ([value isKindOfClass:[NSString class]] && AevonLooksLikeBundleID(value)) {
                free(ivars);
                return value;
            }
        }
        if (ivars != NULL) { free(ivars); }
    } @catch (NSException *unused) {}
    return nil;
}

static void AevonSceneHookDidAppear(id self, SEL _cmd, BOOL animated) {
    if (AevonOrigDidAppear) {
        ((void (*)(id, SEL, BOOL))AevonOrigDidAppear)(self, _cmd, animated);
    }
    @try {
        if ([self isKindOfClass:[UIViewController class]]) {
            /* V0.0.62（AevonFrontmostIDV62）：把宿主场景 bundleID 一起传给 Swift，
             * 修复「关浮窗后屏幕无法滑动」—— V59/V61 的修复依赖前台场景标识，
             * 而标识探测在 Swift 层恒失败（FBScene.identifier 是对象不是字符串）。 */
            NSString *bundleID = AevonSceneBundleIDFromVC((UIViewController *)self);
            AevonSceneVCDidAppear((UIViewController *)self, bundleID);
        }
    } @catch (NSException *exception) {
        // 私有类回调出错绝不影响 SpringBoard
    }
}

static void AevonSceneHookDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (AevonOrigDidDisappear) {
        ((void (*)(id, SEL, BOOL))AevonOrigDidDisappear)(self, _cmd, animated);
    }
    @try {
        if ([self isKindOfClass:[UIViewController class]]) {
            AevonSceneVCDidDisappear((UIViewController *)self);
        }
    } @catch (NSException *exception) {
    }
}

/// 交换实现。类自己没有实现时用 class_addMethod（原实现从父类取），
/// 否则 method_setImplementation。绝不能直接用 setImplementation 覆盖父类方法。
static void AevonSceneHookSwap(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL || original == NULL) { return; }
    if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        Class superClass = class_getSuperclass(cls);
        *original = superClass ? class_getMethodImplementation(superClass, sel) : NULL;
    } else {
        *original = method_setImplementation(method, replacement);
    }
}

BOOL AevonSceneHookAvailable(void) {
    return NSClassFromString(@"SBDeviceApplicationSceneViewController") != Nil;
}

void AevonSceneHookInstall(void) {
    if (AevonSceneHookInstalled) { return; }
    AevonSceneHookInstalled = YES;
    @try {
        Class cls = NSClassFromString(@"SBDeviceApplicationSceneViewController");
        if (cls == Nil) { return; }
        AevonSceneHookSwap(cls, @selector(viewDidAppear:), (IMP)AevonSceneHookDidAppear, &AevonOrigDidAppear);
        AevonSceneHookSwap(cls, @selector(viewDidDisappear:), (IMP)AevonSceneHookDidDisappear, &AevonOrigDidDisappear);
    } @catch (NSException *exception) {
    }
}
