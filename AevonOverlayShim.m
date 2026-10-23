#import "AevonOverlayShim.h"
#import <objc/runtime.h>
#import <objc/message.h>

/// 覆盖层可见性探测（V0.0.55）。
/// 全程 @try/@catch：这是每条轮询都要跑的热路径，任何异常都不能冒到 SpringBoard。

static NSArray<UIWindow *> *AevonOverlayAllWindows(void) {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    @try {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window == nil) { continue; }
                [result addObject:window];
            }
        }
        // 有些窗口不属于任何已连接场景（比如系统临时窗口），补一遍。
        // `UIApplication.windows` 在 iOS 15 起被标弃用，但这里正是要找「所有窗口」，
        // CI 开着 -Werror，必须显式压掉这条弃用警告。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window == nil || [result containsObject:window]) { continue; }
            [result addObject:window];
        }
#pragma clang diagnostic pop
    } @catch (NSException *exception) {
    }
    return result;
}

static BOOL AevonOverlayWindowVisible(UIWindow *window) {
    if (window == nil) { return NO; }
    if (window.isHidden) { return NO; }
    if (window.alpha < 0.01) { return NO; }
    if (window.windowLevel <= 0) { return NO; }
    return YES;
}

/// 名字里带这些片段的窗口 = 锁屏 / 通知中心 / 控制中心的承载窗口。
/// 用 contains 而不是精确匹配：不同 iOS 版本类名有 `SBCoverSheetWindow` /
/// `SBCoverSheetMainWindow` / `SBControlCenterWindow` / `SBNotificationCenterWindow` 等变体。
static BOOL AevonOverlayNameIsSheet(NSString *name) {
    if (name.length == 0) { return NO; }
    static NSArray<NSString *> *fragments = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fragments = @[@"CoverSheet",
                      @"ControlCenter",
                      @"NotificationCenter",
                      @"LockScreen",
                      @"LockScreenWindow",
                      @"PasscodeView",
                      @"WakeScreen"];
    });
    for (NSString *fragment in fragments) {
        if ([name containsString:fragment]) { return YES; }
    }
    return NO;
}

static NSArray<NSString *> *AevonOverlayVisibleSheetNames(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    @try {
        for (UIWindow *window in AevonOverlayAllWindows()) {
            if (!AevonOverlayWindowVisible(window)) { continue; }
            NSString *name = NSStringFromClass([window class]);
            if (!AevonOverlayNameIsSheet(name)) { continue; }
            // 通知中心在图上是挂在 SBCoverSheetWindow 里的（不是独立窗口），
            // 所以只要 cover sheet 可见就已经覆盖了「锁屏 / 通知中心」两种情况。
            if (![names containsObject:name]) { [names addObject:name]; }
        }
    } @catch (NSException *exception) {
    }
    return names;
}

BOOL AevonOverlayCoverSheetVisible(void) {
    // ① 窗口可见性：最直接、最可靠
    if (AevonOverlayVisibleSheetNames().count > 0) { return YES; }

    // ② 锁屏管理器兜底：某些版本锁屏窗口一直存在只是被移出屏幕，
    //    这种情况下问 `SBLockScreenManager` 的锁定 / 可见标记更准。
    @try {
        Class managerClass = objc_getClass("SBLockScreenManager");
        if (managerClass == Nil) { return NO; }
        id manager = nil;
        for (NSString *name in @[@"sharedInstance", @"sharedInstanceIfExists"]) {
            SEL sel = NSSelectorFromString(name);
            if (![managerClass respondsToSelector:sel]) { continue; }
            id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            manager = fn((id)managerClass, sel);
            if (manager != nil) { break; }
        }
        if (manager == nil) { return NO; }
        for (NSString *name in @[@"isLockScreenVisible", @"isUILocked", @"isLockScreenActive"]) {
            SEL sel = NSSelectorFromString(name);
            if (![manager respondsToSelector:sel]) { continue; }
            BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            if (fn(manager, sel)) { return YES; }
        }
    } @catch (NSException *exception) {
    }
    return NO;
}

BOOL AevonOverlaySwitcherVisible(void) {
    // ① 问 SpringBoard 的切换器协调器（不同版本方法名不同，逐个试）
    @try {
        Class coordinatorClass = objc_getClass("SBMainSwitcherControllerCoordinator");
        if (coordinatorClass != Nil) {
            id coordinator = nil;
            for (NSString *name in @[@"sharedInstance", @"sharedInstanceIfExists"]) {
                SEL sel = NSSelectorFromString(name);
                if (![coordinatorClass respondsToSelector:sel]) { continue; }
                id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                coordinator = fn((id)coordinatorClass, sel);
                if (coordinator != nil) { break; }
            }
            if (coordinator != nil) {
                for (NSString *name in @[@"isAnySwitcherVisible",
                                         @"_isAnySwitcherVisible",
                                         @"isSwitcherVisible",
                                         @"hasAnySwitcherVisible"]) {
                    SEL sel = NSSelectorFromString(name);
                    if (![coordinator respondsToSelector:sel]) { continue; }
                    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
                    if (fn(coordinator, sel)) { return YES; }
                }
            }
        }
    } @catch (NSException *exception) {
    }

    // ② 兜底：窗口类名里带 Switcher 且可见
    @try {
        for (UIWindow *window in AevonOverlayAllWindows()) {
            if (!AevonOverlayWindowVisible(window)) { continue; }
            NSString *name = NSStringFromClass([window class]);
            if ([name containsString:@"Switcher"]) { return YES; }
        }
    } @catch (NSException *exception) {
    }
    return NO;
}

NSString *AevonOverlayVisibleOverlayNames(void) {
    @try {
        NSArray<NSString *> *sheets = AevonOverlayVisibleSheetNames();
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithArray:sheets];
        if (AevonOverlaySwitcherVisible()) { [parts addObject:@"切换器"]; }
        return [parts componentsJoinedByString:@"/"];
    } @catch (NSException *exception) {
        return @"";
    }
}
