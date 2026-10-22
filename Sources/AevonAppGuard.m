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
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

/// CI 标记：构建后校验这段逻辑确实编进了 __cstring
__attribute__((used)) static const char AevonAppGuardMarker[] = "AevonAppGuardV27";

/// CI 标记（V0.0.29）：圆盘展开期「下半屏整块吞掉」
__attribute__((used)) static const char AevonGuardRingZoneMarker[] = "AevonGuardRingZoneV29";

/// CI 标记（V0.0.31）：guard.conf 文件通道配置（沙盒 App 读不到偏好域的根治）
__attribute__((used)) static const char AevonGuardFileConfMarker[] = "AevonGuardFileConfV31";

static CFStringRef const AevonGuardDomain = CFSTR("com.Aevon");
static IMP AevonGuardOrigSendEvent = NULL;
static CFMutableSetRef AevonGuardSwallowed = NULL;
static BOOL AevonGuardEnabled = NO;
static CGRect AevonGuardZone = {{0, 0}, {0, 0}};
static CFTimeInterval AevonGuardConfigAt = 0;
/// 配置最长缓存时间（秒）。设置里改完会发 Darwin 通知立即失效，这里只是兜底。
static CFTimeInterval const AevonGuardConfigTTL = 2.0;

/* V0.0.29：圆盘展开状态（SpringBoard 侧发 Darwin 通知 com.aevon.ringopen / ringclose）。
 * 圆盘开着的时候，前台 App 的下半屏一律收不到输入 —— 图标选择/旋转走的是
 * SpringBoard 全局通道的副本，不依赖 App 进程投递，所以整块吞掉没有任何副作用。
 * Darwin 通知没有载荷，这里自己计时兜底：超过 10 秒没收到 ringclose 就自动失效。 */
static CFTimeInterval AevonGuardRingOpenAt = 0;
static CFTimeInterval const AevonGuardRingOpenMaxAge = 10.0;

static BOOL AevonGuardRingOpen(void) {
    if (AevonGuardRingOpenAt <= 0) { return NO; }
    return (CACurrentMediaTime() - AevonGuardRingOpenAt) < AevonGuardRingOpenMaxAge;
}

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
///
/// V0.0.31（AevonGuardFileConfV31）：配置来源改为「文件优先」。
/// 沙盒 App（抖音 / QQ）进程里 CFPreferences 读 com.Aevon 会被重定向进自己的容器，
/// 读到的永远是空 → Enabled 恒 false → Guard 在 App 里从未生效（Aevon(24) 实证：
/// 呼出圆盘后抖音被暂停、圆盘里滑动仍带动全屏 App）。SpringBoard 侧
/// `AevonEdgeEntry.syncGuardConfig()` 会把几何写进 guard.conf（jbroot 下，
/// 注入进程可读），这里优先读文件，读不到才回退偏好域（非沙盒进程仍可用）。
static BOOL AevonGuardReadConfFile(CGRect *outZone, BOOL *outEnabled) {
    const char *paths[] = {
        "/var/jb/Library/PreferenceBundles/AevonPrefs.bundle/guard.conf",
        "/Library/PreferenceBundles/AevonPrefs.bundle/guard.conf",
        "/var/mobile/Library/PreferenceBundles/AevonPrefs.bundle/guard.conf",
    };
    for (int i = 0; i < 3; i++) {
        FILE *f = fopen(paths[i], "r");
        if (f == NULL) { continue; }
        char marker[64];
        char values[160];
        BOOL ok = (fgets(marker, sizeof(marker), f) != NULL)
            && (strstr(marker, "AEVONGUARDCONFV31") != NULL)
            && (fgets(values, sizeof(values), f) != NULL);
        fclose(f);
        if (!ok) { continue; }
        double x = 0, y = 0, w = 0, h = 0;
        int enabled = 0;
        if (sscanf(values, "%lf %lf %lf %lf %d", &x, &y, &w, &h, &enabled) == 5) {
            if (w >= 1 && h >= 1) {
                *outZone = CGRectMake(x, y, w, h);
                *outEnabled = enabled ? YES : NO;
                return YES;
            }
        }
    }
    return NO;
}

static void AevonGuardReloadConfig(void) {
    AevonGuardConfigAt = CACurrentMediaTime();

    CGRect zone = CGRectZero;
    BOOL enabled = NO;
    if (AevonGuardReadConfFile(&zone, &enabled)) {
        AevonGuardEnabled = enabled;
        AevonGuardZone = enabled ? zone : CGRectZero;
        return;
    }

    /* 兜底：偏好域（仅对非沙盒进程有意义）。语义与 SB 一致的「底边锚定」。 */
    BOOL prefOn = AevonGuardPrefBool("Enabled", NO);
    BOOL edge = AevonGuardPrefBool("EdgeGestureEnabled", YES);
    AevonGuardEnabled = (prefOn && edge);
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
    /* V0.0.30 语义：RingTriggerY 是热区**底边**占屏高百分比，100% = 底边贴屏底 */
    CGFloat bottomY = bounds.size.height * ratio;
    CGFloat y = MIN(MAX(bottomY - height, 0.0), bounds.size.height - height);

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
            BOOL inZone = CGRectContainsPoint(AevonGuardZone, [touch locationInView:nil]);
            /* V0.0.29：圆盘展开期间，下半屏整块视为热区 —— 前台 App 在圆盘开着时
             * 收不到任何下半屏输入（用户 Aevon(22) 反馈「滑动到圆盘外面依旧触发 App 操作」）。
             * 圆盘的图标选择 / 旋转走 SpringBoard 全局通道的副本，不依赖这里投递。 */
            if (!inZone && AevonGuardRingOpen()) {
                CGFloat y = [touch locationInView:nil].y;
                CGFloat half = [UIScreen mainScreen].bounds.size.height * 0.5;
                if (y >= half) { inZone = YES; }
            }
            if (inZone) {
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

/* V0.0.29：圆盘开 / 关广播（SpringBoard 侧 AevonEdgeEntry 发出） */
static void AevonGuardRingOpened(CFNotificationCenterRef center,
                                 void *observer,
                                 CFNotificationName name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    AevonGuardRingOpenAt = CACurrentMediaTime();
    // V0.0.31：圆盘刚打开 —— 立刻重读 guard.conf（热区可能刚被设置页改过）
    AevonGuardConfigAt = 0;
}

static void AevonGuardRingClosed(CFNotificationCenterRef center,
                                 void *observer,
                                 CFNotificationName name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    AevonGuardRingOpenAt = 0;
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

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    AevonGuardRingOpened,
                                    CFSTR("com.aevon.ringopen"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    AevonGuardRingClosed,
                                    CFSTR("com.aevon.ringclose"),
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
        /*
         * V0.0.28：**排除「设置」App**。
         * 设置页里的三个触发区滑杆跨在热区里，若在 Preferences 进程也被接管，
         * 滑杆右半截就拖不动（用户会以为「滑条只能拖到最小值」）。
         * Aevon 自己的设置页永远不需要热区手势。
         */
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"com.apple.Preferences"]) { return; }

        @try {
            AevonGuardInstall();
        } @catch (NSException *exception) {
            // 任何异常都不允许影响 App 启动
        }
    }
}
