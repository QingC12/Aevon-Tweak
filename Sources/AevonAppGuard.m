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
#import <notify.h>

/// CI 标记：构建后校验这段逻辑确实编进了 __cstring
__attribute__((used)) static const char AevonAppGuardMarker[] = "AevonAppGuardV27";

/// CI 标记（V0.0.29）：圆盘展开期「下半屏整块吞掉」
__attribute__((used)) static const char AevonGuardRingZoneMarker[] = "AevonGuardRingZoneV29";

/// CI 标记（V0.0.31）：guard.conf 文件通道配置（沙盒 App 读不到偏好域的根治）
__attribute__((used)) static const char AevonGuardFileConfMarker[] = "AevonGuardFileConfV31";

/// CI 标记（V0.0.32）：notify(3) 主配置通道 + 圆盘展开期无条件吞下半屏
__attribute__((used)) static const char AevonGuardNotifyMarker[] = "AevonGuardNotifyV32";
__attribute__((used)) static const char AevonGuardRingForceMarker[] = "AevonGuardRingForceV32";

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
/// V0.0.32：只要收到过 ringopen，就证明插件在 SpringBoard 侧是启用的。
/// 之后即使配置三路（notify / 文件 / 偏好）全失败，也用默认几何兜底拦截，
/// 不再整条 Guard 失效（Aevon(25)：guard.conf 写不进 → 抖音被暂停/误触）。
static BOOL AevonGuardPluginAlive = NO;

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
/// V0.0.32（AevonGuardNotifyV32）：配置来源优先级
///   1. notify(3) 状态（跨进程、沙盒通用，主通道）
///   2. guard.conf 文件（多路径兜底）
///   3. 偏好域（仅非沙盒进程）
///   4. 默认几何 + PluginAlive 插存（收到过 ringopen 就证明插件开着）
/// 沙盒 App（抖音 / QQ）里 CFPreferences 读 com.Aevon 会被重定向进自己的容器；
/// guard.conf 也可能因 SpringBoard 写不进 root 属主目录而失败（Aevon(25)）。
static BOOL AevonGuardReadConfFile(CGRect *outZone, BOOL *outEnabled) {
    const char *paths[] = {
        "/var/jb/Library/Aevon/guard.conf",
        "/var/jb/Library/PreferenceBundles/AevonPrefs.bundle/guard.conf",
        "/Library/Aevon/guard.conf",
        "/Library/PreferenceBundles/AevonPrefs.bundle/guard.conf",
        "/var/mobile/AevonGuard.conf",
    };
    for (int i = 0; i < 5; i++) {
        FILE *f = fopen(paths[i], "r");
        if (f == NULL) { continue; }
        char marker[64];
        char values[160];
        BOOL ok = (fgets(marker, sizeof(marker), f) != NULL)
            && (strstr(marker, "AEVONGUARDCONF") != NULL)
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

/* V0.0.32：读 notify(3) 状态通道（与 SpringBoard 侧 AevonNotifySetZone 打包格式一致）。
 * AevonGuard 是独立 dylib，不链接 AevonAssertionShim，所以这里自带一份解包。
 * 格式：x:10 y:10 w:8 h:10 enabled:1 版本:8（0x32 = V32）。
 * 注意：notify_set_state / notify_get_state 参数是 **int token**，不是名字！ */
static int AevonGuardNotifyToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.aevon.guardzone", &token);
    });
    return token;
}

static BOOL AevonGuardReadNotifyZone(CGRect *outZone, BOOL *outEnabled) {
    int token = AevonGuardNotifyToken();
    if (token < 0) { return NO; }
    uint64_t pack = 0;
    notify_get_state(token, &pack);
    /* 读失败时 pack 保持 0，版本标记对不上就当没有配置 */
    if (((pack >> 40) & 0xFF) != 0x32) { return NO; }
    double x = (double)(pack & 0x3FFULL);
    double y = (double)((pack >> 10) & 0x3FFULL);
    double w = (double)((pack >> 20) & 0xFFULL);
    double h = (double)((pack >> 28) & 0x3FFULL);
    if (w < 1 || h < 1) { return NO; }
    *outZone = CGRectMake(x, y, w, h);
    *outEnabled = ((pack >> 38) & 1ULL) ? YES : NO;
    return YES;
}

static void AevonGuardReloadConfig(void) {
    AevonGuardConfigAt = CACurrentMediaTime();

    CGRect zone = CGRectZero;
    BOOL enabled = NO;

    /* 1. notify(3) 状态通道（主通道，沙盒通用） */
    if (AevonGuardReadNotifyZone(&zone, &enabled)) {
        AevonGuardEnabled = enabled;
        AevonGuardZone = enabled ? zone : CGRectZero;
        return;
    }

    /* 2. guard.conf 文件通道 */
    if (AevonGuardReadConfFile(&zone, &enabled)) {
        AevonGuardEnabled = enabled;
        AevonGuardZone = enabled ? zone : CGRectZero;
        return;
    }

    /* 3. 偏好域（仅对非沙盒进程有意义）。语义与 SB 一致的「底边锚定」。 */
    BOOL prefOn = AevonGuardPrefBool("Enabled", NO);
    BOOL edge = AevonGuardPrefBool("EdgeGestureEnabled", YES);
    AevonGuardEnabled = (prefOn && edge);
    if (AevonGuardEnabled) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (bounds.size.width >= 1.0 && bounds.size.height >= 1.0) {
            double ratio = AevonGuardPrefDouble("RingTriggerY", 75.0, 0.0, 100.0) / 100.0;
            double rawWidth = AevonGuardPrefDouble("RingTriggerWidth", 48.0, 18.0, 140.0);
            double rawHeight = AevonGuardPrefDouble("RingTriggerHeight", 320.0, 80.0, 900.0);
            CGFloat width = MIN(rawWidth, bounds.size.width);
            CGFloat height = MIN(rawHeight, bounds.size.height);
            CGFloat bottomY = bounds.size.height * ratio;
            CGFloat y = MIN(MAX(bottomY - height, 0.0), bounds.size.height - height);
            AevonGuardZone = CGRectMake(bounds.size.width - width, y, width, height);
            return;
        }
    }

    /* 4. V0.0.32：三路全失败，但收到过 ringopen —— 插件肯定开着，用默认几何兜底 */
    if (AevonGuardPluginAlive) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (bounds.size.width >= 1.0 && bounds.size.height >= 1.0) {
            CGFloat width = MIN(48.0, bounds.size.width);
            CGFloat height = MIN(320.0, bounds.size.height);
            CGFloat bottomY = bounds.size.height * 0.75;
            CGFloat y = MIN(MAX(bottomY - height, 0.0), bounds.size.height - height);
            AevonGuardEnabled = YES;
            AevonGuardZone = CGRectMake(bounds.size.width - width, y, width, height);
            return;
        }
    }

    AevonGuardEnabled = NO;
    AevonGuardZone = CGRectZero;
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
    /* V0.0.32：圆盘展开期的下半屏吞触摸**不再依赖 Enabled / 配置**。
     * Aevon(25)：guard.conf 写不进 → 配置全空 → Enabled 恒 false →
     * 连圆盘展开保护也整条失效，抖音被暂停 / 圆盘滑动带动全屏 App。
     * 只要收到过 ringopen（通知本身不依赖任何配置），下半屏一律吞。 */
    BOOL ringOpen = AevonGuardRingOpen();
    if (!AevonGuardEnabled && !ringOpen) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }
    if (AevonGuardSwallowed == NULL || event == nil) {
        AevonGuardCallOriginal(self, _cmd, event);
        return;
    }
    if (!ringOpen && CGRectIsEmpty(AevonGuardZone)) {
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
            CGPoint pt = [touch locationInView:nil];
            BOOL inZone = NO;
            if (ringOpen) {
                /* AevonGuardRingForceV32：圆盘开着 —— 下半屏整块 + 热区全吞。
                 * 图标选择 / 旋转走 SpringBoard 全局通道副本，不依赖这里投递。 */
                CGFloat half = [UIScreen mainScreen].bounds.size.height * 0.5;
                if (pt.y >= half) { inZone = YES; }
                if (!CGRectIsEmpty(AevonGuardZone) && CGRectContainsPoint(AevonGuardZone, pt)) {
                    inZone = YES;
                }
            } else if (!CGRectIsEmpty(AevonGuardZone) && CGRectContainsPoint(AevonGuardZone, pt)) {
                inZone = YES;
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
    /* V0.0.32：收到 ringopen = 插件肯定在跑。立刻重读配置；
     * 之后即使配置读不到也用默认几何兜底，不再整条 Guard 失效。 */
    AevonGuardPluginAlive = YES;
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

    /* V0.0.32：notify(3) 状态写入时 SpringBoard 会 post com.aevon.prefschanged，
     * 上面的 prefschanged 观察者已把 ConfigAt 清零 → 下一次 sendEvent 重读 notify 状态。
     * 不额外 register notify 回调，避免 blocks / dispatch 依赖。 */

    NSLog(@"[Aevon] App 侧热区拦截已安装（%s %s）", AevonAppGuardMarker, AevonGuardNotifyMarker);
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
