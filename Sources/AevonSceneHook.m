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

extern void AevonSceneVCDidAppear(UIViewController *vc);
extern void AevonSceneVCDidDisappear(UIViewController *vc);

static IMP AevonOrigDidAppear = NULL;
static IMP AevonOrigDidDisappear = NULL;
static BOOL AevonSceneHookInstalled = NO;

static void AevonSceneHookDidAppear(id self, SEL _cmd, BOOL animated) {
    if (AevonOrigDidAppear) {
        ((void (*)(id, SEL, BOOL))AevonOrigDidAppear)(self, _cmd, animated);
    }
    @try {
        if ([self isKindOfClass:[UIViewController class]]) {
            AevonSceneVCDidAppear((UIViewController *)self);
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
