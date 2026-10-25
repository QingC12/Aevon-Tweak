#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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

/*
 * 传 C 字符串而不是 NSString：Swift 的 @_cdecl 只接受 C 兼容类型。
 * 这里的指针指向 autoreleased NSString 的内部缓冲，只在 viewDidAppear 调用栈内有效 ——
 * 所以 Swift 侧必须**立即**拷贝成自己的 String，不能存起来延迟用。
 */
extern void AevonSceneVCDidAppear(UIViewController *vc, const char *sceneIdentifier);
extern void AevonSceneVCDidDisappear(UIViewController *vc);

static IMP AevonOrigDidAppear = NULL;
static IMP AevonOrigDidDisappear = NULL;
static BOOL AevonSceneHookInstalled = NO;

/* ── V0.1.6（AevonFullscreenCloseV106）：从全屏画面容器反查它承载的 App ──
 *
 * 用途：0.1.5 起「浮窗开着设置 → 桌面点设置图标」不再注销了，但**浮窗变成黑屏** ——
 * 因为同一个场景被系统拿去做全屏呈现了，我们浮窗里那个 presenter 拿不到画面。
 * 正解就是用户说的：全屏打开时把浮窗关掉。要关得准，就必须知道这个全屏画面是谁。
 *
 * SBDeviceApplicationSceneViewController 手里握着 SBSceneHandle，handle → scene → identifier
 * 就是 `com.apple.Preferences-default` 这种串。不同 iOS 版本上字段名有出入，
 * 所以这里按「从最具体到最兜底」排了一串候选，全部用 @try 包住：
 * KVC 打到不存在的 key 会抛 NSUnknownKeyException，绝不能让异常冒到 SpringBoard。
 * 全失败返回 nil —— 上层把 nil 当「未知」处理，不做任何关闭动作。
 */
static NSString *AevonSceneHookScanDirectStrings(id object);

static NSString *AevonSceneHookStringOf(id object, NSArray<NSString *> *keys) {
    if (object == nil) { return nil; }
    for (NSString *key in keys) {
        @try {
            id value = [object valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                return (NSString *)value;
            }
        } @catch (NSException *exception) {
            // 该字段不存在，试下一个
        }
    }
    return nil;
}

NSString *AevonSceneIdentifierOfViewController(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]]) { return nil; }

    id handle = nil;
    for (NSString *key in @[@"_sceneHandle", @"sceneHandle"]) {
        @try { handle = [vc valueForKey:key]; } @catch (NSException *exception) { handle = nil; }
        if (handle != nil) { break; }
    }

    // ① handle 自己就带标识
    NSString *direct = AevonSceneHookStringOf(handle, @[@"_sceneIdentifier", @"sceneIdentifier",
                                                       @"_sceneID", @"sceneID",
                                                       @"_applicationIdentifier", @"applicationIdentifier",
                                                       @"bundleIdentifier"]);
    if (direct.length > 0) { return direct; }

    // ② handle → scene → identifier / clientProcess.bundleIdentifier
    for (NSString *key in @[@"_scene", @"scene"]) {
        id scene = nil;
        @try { scene = [handle valueForKey:key]; } @catch (NSException *exception) { scene = nil; }
        if (scene == nil) { continue; }
        NSString *identifier = AevonSceneHookStringOf(scene, @[@"identifier", @"_identifier"]);
        if (identifier.length > 0) { return identifier; }
        for (NSString *processKey in @[@"_clientProcess", @"clientProcess"]) {
            id process = nil;
            @try { process = [scene valueForKey:processKey]; } @catch (NSException *exception) { process = nil; }
            NSString *bundle = AevonSceneHookStringOf(process, @[@"bundleIdentifier", @"_bundleIdentifier"]);
            if (bundle.length > 0) { return bundle; }
        }
    }

    // ③ handle → 进程句柄 → bundleIdentifier
    for (NSString *key in @[@"_processHandle", @"processHandle", @"_process"]) {
        id process = nil;
        @try { process = [handle valueForKey:key]; } @catch (NSException *exception) { process = nil; }
        NSString *bundle = AevonSceneHookStringOf(process, @[@"bundleIdentifier", @"_bundleIdentifier",
                                                             @"applicationIdentifier"]);
        if (bundle.length > 0) { return bundle; }
    }

    // ④ 最后才问控制器本身
    NSString *fallback = AevonSceneHookStringOf(vc, @[@"_sceneIdentifier", @"sceneIdentifier",
                                                      @"_sceneID", @"bundleIdentifier"]);
    if (fallback.length > 0) { return fallback; }

    // ⑤ 兜底：直接扫 ivar 里的字符串（只扫一层，不递归对象图）。
    //    有些版本上标识挂在完全没想到的字段名里，按 KVC 逐个试永远试不完；
    //    这里退一步做「形状匹配」：看起来像 bundleID / sceneIdentifier 的字符串就认。
    //    只读 `object_getIvar` + 类型编码判 '@'，不碰对象图、不递归，代价可忽略。
    NSString *scanned = AevonSceneHookScanDirectStrings(handle);
    if (scanned.length > 0) { return scanned; }
    return AevonSceneHookScanDirectStrings(vc);
}

/// 扫对象自身的字符串 ivar，挑出「像标识符」的那一个。
static NSString *AevonSceneHookScanDirectStrings(id object) {
    if (object == nil) { return nil; }
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(object_getClass(object), &count);
    if (ivars == NULL) { return nil; }
    NSString *found = nil;
    for (unsigned int index = 0; index < count; index++) {
        const char *encoding = ivar_getTypeEncoding(ivars[index]);
        if (encoding == NULL || encoding[0] != '@') { continue; }
        @try {
            id value = object_getIvar(object, ivars[index]);
            if ([value isKindOfClass:[NSString class]]) {
                NSString *candidate = (NSString *)value;
                if (candidate.length > 5
                    && [candidate containsString:@"."]
                    && ![candidate containsString:@" "]
                    && ([candidate containsString:@"com."] || [candidate hasSuffix:@"-default"])) {
                    found = candidate;
                    break;
                }
            }
        } @catch (NSException *exception) {
        }
    }
    free(ivars);
    return found;
}

static void AevonSceneHookDidAppear(id self, SEL _cmd, BOOL animated) {
    if (AevonOrigDidAppear) {
        ((void (*)(id, SEL, BOOL))AevonOrigDidAppear)(self, _cmd, animated);
    }
    @try {
        if ([self isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)self;
            NSString *identifier = AevonSceneIdentifierOfViewController(vc);
            AevonSceneVCDidAppear(vc, identifier.length > 0 ? [identifier UTF8String] : NULL);
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
