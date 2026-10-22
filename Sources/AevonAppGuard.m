/*
 * AevonGuard —— App 进程侧的「圆盘热区触摸拦截」。
 *
 * 为什么必须有它（V0.0.27 的核心修复）
 * =====================================================================
 * Aevon.dylib 只注入 SpringBoard。实测（Aevon(20) 日志）在 SpringBoard 的
 * `UIApplication -sendEvent:` 里丢弃触摸，能挡住 App 的滚动，但挡不住
 * **App 自己的横向手势**：QQ 的左滑删除会话、抖音的左滑进作者主页照样触发。
 *
 * 原因：前台 App 的触摸事件是 backboardd 直接投递给 **App 进程**的，
 * SpringBoard 只是同时收到一份。在 SpringBoard 里吞事件，App 进程那一份照样存在。
 *
 * 所以这里再放一个「极小的纯 ObjC dylib」，注入到 GUI App 进程，只做一件事：
 * 热区内按下的那根手指，从 began 到 ended 的**整条事件都不投递给 App**。
 * App 连 began 都收不到 → 任何 App 内手势（左滑删除、左滑进主页、滚动、长按）
 * 都不可能被触发。
 *
 * 安全设计（绝不能影响没启用插件的机器）：
 *   · 不是 GUI 进程（没有 UIApplication / 是 SpringBoard）→ 构造函数直接 return；
 *   · `Enabled` 默认 false → 未启用时 hook 里第一行就原样转发，零行为变化；
 *   · hook 里任何异常都不抛给 App：只用 CFPreferences / UIKit 公开 API；
 *   · 只拦「热区内按下」的那一根手指，其它手指照常给 App。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <stdlib.h>
#import <string.h>

/// CI 标记：构建后校验这段逻辑确实编进了 __cstring
__attribute__((used)) static const char AevonAppGuardMarker[] = "AevonAppGuardV27";

static CFStringRef const AevonGuardDomain = CFSTR("com.Aevon");
static IMP AevonGuardOrigSendEvent = NULL;
static CFMutableSetRef AevonGuardSwallowed = NULL;
static BOOL AevonGuardEnabled = NO;
static CGRect AevonGuardZone = {{0, 0}, {0, 0}};
static CFTimeInterval AevonGuardConfigAt = 0;
/// 配置最长缓存时间（秒）。设置里改完会发 Darwin 通知立即失效，这里只是兜底。
static CFTimeInterval const AevonGuardConfigTTL = 2.0;

#pragma mark - 偏好读取

static CFStringRef AevonGuardKey(const char *utf8) {
    return CFStringCreateWithCString(kCFAllocatorDefault, utf8, kCFStringEncodingUTF8);
}

static BOOL AevonGuardPrefBool(const char *key, BOOL fallback) {
    CFStringRef k = AevonGuardKey(key);
    if (k == NULL) return fallback;
    Boolean exists = false;
    Boolean value = CFPreferencesGetAppBooleanValue(k, AevonGuardDomain, &exists);
    CFRelease(k);
    return exists ? (BOOL)value : fallback;
}

static double AevonGuardPrefDouble(const char *key, double fallback, double lo, double hi) {
    CFStringRef k = AevonGuardKey(key);
    if (k == NULL) return fallback;
    CFPropertyListRef raw = CFPreferencesCopyAppValue(k, AevonGuardDomain);
    CFRelease(k);

    double value = fallback;
    if (raw != NULL) {
        CFTypeID type = CFGetTypeID(raw);
        if (type == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)raw, kCFNumberDoubleType, &value);
        } else if (type == CFStringGetTypeID()) {
            value = CFStringGetDoubleValue((CFStringRef)raw);
        }
        CFRelease(raw);
    }
    if (value < lo) value = lo;
    if (value > hi) value = hi;
    return value;
}

/// 与 SpringBoard 侧 `AevonTriggerZone.rect(in:)` 完全一致的几何计算
static void AevonGuardReloadConfig(void) {
    AevonGuardConfigAt = CACurrentMediaTime();

    BOOL enabled = AevonGuardPrefBool("Enabled", NO);
    BOOL edge = AevonGuardPrefBool("EdgeGestureEnabled", YES);
    AevonGuardEnabled = (enabled && edge);
    if (!AevonGuardEnabled) {
        AevonGuardZone = CGRectZero;
        return;
    }

    CGRect bounds = [UIScreen mainScreen].bounds;
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0) {
        AevonGuardZone = CGRectZero;
        return;
    }

    double ratio = AevonGuardPrefDouble("RingTriggerY", 75.0, 0.0, 100.0) / 100.0;
    double rawWidth = AevonGuardPrefDouble("RingTriggerWidth", 48.0, 18.0, 140.0);
    double rawHeight = AevonGuardPrefDouble("RingTriggerHeight", 320.0, 80.0, 900.0);

    CGFloat width = MIN(rawWidth, bounds.size.width);
    CGFloat height = MIN(rawHeight, bounds.size.height);
    CGFloat centerY = bounds.size.height * ratio;
    CGFloat y = MIN(MAX(centerY - height / 2.0, 0.0), bounds.size.height - height);

    AevonGuardZone = CGRectMake(bounds.size.width - width, y, width, height);
}

#pragma mark - 事件拦截

/*
 * 判定与投递规则（与 SpringBoard 侧 `AevonEdgeEntry.shouldSwallowGlobalTouch` 同语义）：
 *   · 某个触摸在 `Began` 时落在热区 → 记入「已接管集合」，从这一帧起它的所有事件都不投递；
 *   · 该触摸 `Ended` / `Cancelled` 时判定完再移出集合（保证抬手那一帧也吞掉）；
 *   · 只有**整条事件里所有活动触摸都被接管**时才整条丢弃 —— 混进别的手指就整体照常投递，
 *     绝不因为用户在热区按了一下就把另一根手指的输入也吃掉。
 */
static void AevonGuardCallOriginal(id self, SEL _cmd, UIEvent *event) {
    if (AevonGuardOrigSendEvent == NULL) { return; }
    ((void (*)(id, SEL, UIEvent *))AevonGuardOrigSendEvent)(self, _cmd, event);
}

static void AevonGuardSendEvent(id self, SEL _cmd, UIEvent *event) {
    if (AevonGuardOrigSendEvent == NULL) {
        return;
    }
    // 先判断配置是否过期（构造函数里不读 UIScreen，首次 sendEvent 时才加载）
    if (CACurrentMediaTime() - AevonGuardConfigAt > AevonGuardConfigTTL) {
        AevonGuardReloadConfig();
    }
    if (!AevonGuardEnabled) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }
    if (AevonGuardSwallowed == NULL || CGRectIsEmpty(AevonGuardZone) || event == nil) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }

    NSSet *touches = [event allTouches];
    if (touches.count == 0) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }

    NSUInteger active = 0;
    NSUInteger swallowed = 0;
    for (UITouch *touch in touches) {
        UITouchPhase phase = [touch phase];
        if (phase == UITouchPhaseStationary) { continue; }
        active += 1;

        const void *identity = (__bridge const void *)touch;
        BOOL owned = CFSetContainsValue(AevonGuardSwallowed, identity) ? YES : NO;

        if (phase == UITouchPhaseBegan) {
            if (CGRectContainsPoint(AevonGuardZone, [touch locationInView:nil])) {
                CFSetAddValue(AevonGuardSwallowed, identity);
                owned = YES;
            }
        }

        if (owned) {
            swallowed += 1;
            if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
                CFSetRemoveValue(AevonGuardSwallowed, identity);
            }
        }
    }

    if (active > 0 && swallowed == active) {
        return;   // 整条事件丢弃
    }
    AevonGuardCallOriginal(self, _cmd, event);
}

#pragma mark - 安装

static void AevonGuardPrefsChanged(CFNotificationCenterRef center,
                                   void *observer,
                                   CFNotificationName name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    // 让下一次 sendEvent 重新读配置
    AevonGuardConfigAt = 0;
}

static void AevonGuardInstall(void) {
    if (AevonGuardOrigSendEvent != NULL) { return; }

    Class applicationClass = objc_getClass("UIApplication");
    if (applicationClass == Nil) { return; }
    Method method = class_getInstanceMethod(applicationClass, sel_registerName("sendEvent:"));
    if (method == NULL) { return; }

    if (AevonGuardSwallowed == NULL) {
        AevonGuardSwallowed = CFSetCreateMutable(kCFAllocatorDefault, 8, NULL);
    }
    // 构造函数阶段不读 UIScreen / 偏好，等第一次 sendEvent 再加载（主线程、UIKit 已就绪）
    AevonGuardConfigAt = 0;
    AevonGuardOrigSendEvent = method_setImplementation(method, (IMP)AevonGuardSendEvent);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    AevonGuardPrefsChanged,
                                    CFSTR("com.aevon.prefschanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    NSLog(@"[Aevon] App 侧热区拦截已安装（%s）", AevonAppGuardMarker);
}

__attribute__((constructor)) static void AevonGuardConstructor(void) {
    @autoreleasepool {
        const char *process = getprogname();
        // SpringBoard 由 Aevon.dylib 负责；这里只管前台 App
        if (process != NULL && strcmp(process, "SpringBoard") == 0) { return; }
        // 没有 UIKit 的进程（守护进程 / launchd / backboardd）直接退出，绝不做任何事
        if (objc_getClass("UIApplication") == NULL) { return; }
        if (objc_getClass("SpringBoard") != NULL) { return; }

        @try {
            AevonGuardInstall();
        } @catch (NSException *exception) {
            // 任何异常都不允许影响 App 启动
        }
    }
}
