#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <signal.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

/*
 * RBSAssertion 保活垫片（Objective-C，异常安全）。
 *
 * 为什么用 ObjC：RBSAssertion / RBSTarget / RBSLegacyAttribute 均为私有框架类，
 * 且 acquireWithError: 内部可能抛出 ObjC 异常；Swift 无法捕获 ObjC 异常，
 * 因此单独放在 ObjC 文件中用 @try/@catch 兜底，保证任何失败都不会影响主流程。
 */

static CFStringRef AevonPrefsAppID(void) {
    return CFSTR("com.Aevon");
}

/* V0.0.30：CI 校验标记。
 * 面板去掉「左右分屏」档后 openSplit 暂无调用方，Swift/LLVM 会把无人调用的函数
 * 连同其内部的字符串常量一起消除（V0.0.29 里靠面板调用链保活，现在断了），
 * Swift 侧的常量引用也会被常量折叠/死代码消除 —— 只有 ObjC 的 used 属性能强制
 * 保留。分屏流程代码本身保留，后续版本复用。 */
__attribute__((used)) static const char AevonSplitFlowCIMarker[] = "AevonSplitFlow";

/* V0.0.31 CI 标记：Swift 侧字符串可能被常量折叠/死代码消除，统一用 ObjC used 兜底 */
__attribute__((used)) static const char AevonRingSquareV31Marker[] = "AevonRingSquareV31";
__attribute__((used)) static const char AevonRingAutoSizeV31Marker[] = "AevonRingAutoSizeV31";
__attribute__((used)) static const char AevonRingPinnedV31Marker[] = "AevonRingPinnedV31";
__attribute__((used)) static const char AevonGuardFileConfV31Marker[] = "AEVONGUARDCONFV31";

/* V0.0.32 CI 标记：notify(3) 跨进程热区通道（沙盒 App 唯一可靠的配置来源） */
__attribute__((used)) static const char AevonGuardNotifyV32Marker[] = "AevonGuardNotifyV32";

/* V0.0.33 CI 标记：热区按下无条件接管 + 圆盘速度弹簧 + Guard 圆盘期吞区加宽 */
__attribute__((used)) static const char AevonTouchOwnV33Marker[] = "AevonTouchOwnV33";
__attribute__((used)) static const char AevonRingSpringV33Marker[] = "AevonRingSpringV33";
__attribute__((used)) static const char AevonGuardRingWideV33Marker[] = "AevonGuardRingWideV33";

/* V0.0.34 CI 标记：圆盘状态走 notify(3) 共享内存位（沙盒 App 零时序依赖） */
__attribute__((used)) static const char AevonNotifyRingBitV34Marker[] = "AevonNotifyRingBitV34";

/* V0.0.35 CI 标记：Guard 全 App 注入（UIKit bundle filter）+ ack 回执 + hover 向上跳跃 */
__attribute__((used)) static const char AevonGuardUIKitV35Marker[] = "AevonGuardUIKitV35";
__attribute__((used)) static const char AevonGuardAckV35Marker[] = "AevonGuardAckV35";
__attribute__((used)) static const char AevonRingHopV35Marker[] = "AevonRingHopV35";

/* V0.0.36 CI 标记：浮窗外壳搬进入口容器（单窗口化）+ 四周 8 向缩放手势 + 浮窗设置项 */
__attribute__((used)) static const char AevonFloatInEntryV36Marker[] = "AevonFloatInEntryV36";
__attribute__((used)) static const char AevonEdgeResizeV36Marker[] = "AevonEdgeResizeV36";
__attribute__((used)) static const char AevonFloatPrefV36Marker[] = "AevonFloatPrefV36";

/* ──────────────────────────────────────────────────────────────────
 * V0.0.32：notify(3) 状态通道
 * 沙盒 App（抖音 / QQ）里 CFPreferences 被重定向进自身容器、guard.conf 也可能
 * 因目录权限写不进去（Aevon(25) 日志：guard.conf 写入失败 × N）。notify_set_state
 * 的 64 位状态挂在 notify token 上，跨进程且不受沙盒文件限制，是 Guard 的主配置源。
 * 打包：x:10 y:10 w:8 h:10 enabled:1 ring:1(bit39) 版本:8（0x34 = V34）
 *
 * V0.0.34（AevonNotifyRingBitV34）：bit39 = 圆盘展开状态。
 * 旧的 Darwin 广播（com.aevon.ringopen / ringclose）是 fire-and-forget，
 * 沙盒 App 里可能收不到或收得晚（Aevon(27)：连续 3 版「圆盘滑动带动全屏 App」）。
 * 改成共享内存状态位：SpringBoard 写、Guard 每条 sendEvent 直接读，零时序依赖。
 *
 * 注意：notify_set_state / notify_get_state 的参数是 **int token**，不是名字！
 * 必须先 notify_register_check("com.aevon.guardzone", &token) 再用 token 读写。
 * ────────────────────────────────────────────────────────────────── */
#include <notify.h>
#include <math.h>

static int AevonNotifyZoneToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.aevon.guardzone", &token);
    });
    return token;
}

#define AEVON_NOTIFY_VER (0x34ULL << 40)
#define AEVON_NOTIFY_RING_BIT (1ULL << 39)

void AevonNotifySetZone(double x, double y, double w, double h, int enabled) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return; }
        /* 读-改-写：保留 bit39 圆盘状态位（圆盘开着时设置页改几何，不能把 ring 位冲掉） */
        uint64_t old = 0;
        notify_get_state(token, &old);
        uint64_t ringBit = (((old >> 40) & 0xFF) == 0x34) ? (old & AEVON_NOTIFY_RING_BIT) : 0;
        uint64_t pack = ringBit;
        pack |= ((uint64_t)llround(x)) & 0x3FFULL;
        pack |= (((uint64_t)llround(y)) & 0x3FFULL) << 10;
        pack |= (((uint64_t)llround(w)) & 0xFFULL) << 20;
        pack |= (((uint64_t)llround(h)) & 0x3FFULL) << 28;
        pack |= (enabled ? 1ULL : 0ULL) << 38;
        pack |= AEVON_NOTIFY_VER;
        notify_set_state(token, pack);
        notify_post("com.aevon.guardzone");
    } @catch (NSException *exception) {
    }
}

/* V0.0.34：圆盘展开状态位（AevonNotifyRingBitV34）。
 * SpringBoard 在 presentRing / ringDidDismiss 调用；Guard 每条 sendEvent 直接读。 */
void AevonNotifySetRing(int on) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return; }
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        if (((pack >> 40) & 0xFF) != 0x34) { pack = 0; }
        if (on) { pack |= AEVON_NOTIFY_RING_BIT; } else { pack &= ~AEVON_NOTIFY_RING_BIT; }
        pack |= AEVON_NOTIFY_VER;
        notify_set_state(token, pack);
        notify_post("com.aevon.guardzone");
    } @catch (NSException *exception) {
    }
}

int AevonNotifyGetZone(double *x, double *y, double *w, double *h, int *enabled) {
    @try {
        int token = AevonNotifyZoneToken();
        if (token < 0) { return 0; }
        uint64_t pack = 0;
        notify_get_state(token, &pack);
        if (((pack >> 40) & 0xFF) != 0x34) { return 0; }
        if (x) { *x = (double)(pack & 0x3FFULL); }
        if (y) { *y = (double)((pack >> 10) & 0x3FFULL); }
        if (w) { *w = (double)((pack >> 20) & 0xFFULL); }
        if (h) { *h = (double)((pack >> 28) & 0x3FFULL); }
        if (enabled) { *enabled = (int)((pack >> 38) & 1ULL); }
        return 1;
    } @catch (NSException *exception) {
        return 0;
    }
}

void AevonPrefSetBool(NSString *key, BOOL value) {
    @try {
        CFPreferencesSetAppValue((CFStringRef)key,
                                 value ? kCFBooleanTrue : kCFBooleanFalse,
                                 AevonPrefsAppID());
        CFPreferencesAppSynchronize(AevonPrefsAppID());
    } @catch (NSException *exception) {
        // 偏好写入失败不影响主流程
    }
}

void AevonPrefSetDouble(NSString *key, double value) {
    @try {
        CFPreferencesSetAppValue((CFStringRef)key,
                                 (__bridge CFPropertyListRef)[NSNumber numberWithDouble:value],
                                 AevonPrefsAppID());
        CFPreferencesAppSynchronize(AevonPrefsAppID());
    } @catch (NSException *exception) {
        // 偏好写入失败不影响主流程
    }
}

void AevonPrefSetInt(NSString *key, NSInteger value) {
    @try {
        CFPreferencesSetAppValue((CFStringRef)key,
                                 (__bridge CFPropertyListRef)[NSNumber numberWithInteger:value],
                                 AevonPrefsAppID());
        CFPreferencesAppSynchronize(AevonPrefsAppID());
    } @catch (NSException *exception) {
        // 偏好写入失败不影响主流程
    }
}

static NSMutableDictionary *_assertionsByPID = nil;

/*
 * 私有框架 API 的编译期声明（仅让编译器接受选择子，运行时由真实类实现）。
 * RBSAssertion / RBSTarget / RBSLegacyAttribute 均为私有框架类，无公开头文件，
 * 全部经 NSClassFromString 动态获取；这些声明挂在 NSObject 上只是为了通过类型检查。
 */
@interface NSObject (AevonRBSPrivate)
+ (id)targetWithPid:(int)pid;
+ (id)attributeWithReason:(NSInteger)reason flags:(NSUInteger)flags;
- (id)initWithExplanation:(NSString *)explanation target:(id)target attributes:(NSArray *)attributes;
- (BOOL)acquireWithError:(NSError **)error;
@end

@interface AevonAssertionShim : NSObject
/// 为指定 pid 获取保活断言（阻止内核挂起 / 降频），并尝试 task_resume / SIGCONT。
+ (void)acquireKeepAliveForPID:(int)pid;
/// 释放指定 pid 的保活断言。
+ (void)releaseKeepAliveForPID:(int)pid;
/// 仅恢复进程执行（不取断言）：suspended 拉起的 App 必须恢复才会渲染画面。
+ (void)resumePID:(int)pid;
@end

@implementation AevonAssertionShim

+ (void)initialize {
    if (self == [AevonAssertionShim class]) {
        _assertionsByPID = [NSMutableDictionary dictionary];
    }
}

+ (void)resumePID:(int)pid {
    if (pid <= 0) return;
    @try {
        mach_port_t task = MACH_PORT_NULL;
        kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
        if (kr == KERN_SUCCESS && task != MACH_PORT_NULL) {
            task_resume(task);
            mach_port_deallocate(mach_task_self(), task);
        } else {
            kill(pid, SIGCONT);
        }
    } @catch (NSException *exception) {
        // 恢复失败不影响主流程
    }
}

+ (void)acquireKeepAliveForPID:(int)pid {
    @try {
        if (pid <= 0) return;

        @synchronized (self) {
            if (_assertionsByPID[@(pid)] != nil) return;
        }

        Class targetClass = NSClassFromString(@"RBSTarget");
        Class attributeClass = NSClassFromString(@"RBSLegacyAttribute");
        Class assertionClass = NSClassFromString(@"RBSAssertion");
        if (!targetClass || !attributeClass || !assertionClass) return;

        id target = [targetClass targetWithPid:pid];
        if (!target) return;

        // BKSProcessAssertionPreventTaskSuspend | PreventTaskThrottleDown
        // | WantsForegroundResourcePriority | PreventThrottleDownUI
        NSUInteger flags = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 5);
        id attribute = [attributeClass attributeWithReason:7 flags:flags]; // BKSProcessAssertionReasonBackgroundUI
        if (!attribute) return;

        id assertion = [[assertionClass alloc] initWithExplanation:@"Aevon keep-alive"
                                                            target:target
                                                        attributes:@[attribute]];
        if (!assertion) return;

        NSError *error = nil;
        if (![assertion acquireWithError:&error]) {
            // 必须 invalidate 后再释放：否则 autorelease pool 回收时 dealloc 会抛
            // NSInternalInconsistencyException: Must be invalidated before deallocating
            if ([assertion respondsToSelector:@selector(invalidate)]) {
                [assertion invalidate];
            }
            return;
        }

        @synchronized (self) {
            _assertionsByPID[@(pid)] = assertion;
        }

        // 进程可能已被内核挂起：立即恢复执行
        [self resumePID:pid];
    } @catch (NSException *exception) {
        // 保活是尽力而为：任何失败静默忽略
    }
}

+ (void)releaseKeepAliveForPID:(int)pid {
    @try {
        if (pid <= 0) return;
        @synchronized (self) {
            id assertion = _assertionsByPID[@(pid)];
            if (assertion) {
                if ([assertion respondsToSelector:@selector(invalidate)]) {
                    [assertion invalidate];
                }
                [_assertionsByPID removeObjectForKey:@(pid)];
            }
        }
    } @catch (NSException *exception) {
        // 忽略
    }
}

@end

/*
 * App 图标垫片（V0.0.22 多源重写）。
 *
 * 为什么要多源：V0.0.21 只走 `SBIconController -applicationIconImageForBundleIdentifier:format:scale:`
 * 一条路，在 iOS 17.3.1 的 SpringBoard 里实测恒返回 nil（旧版本只能退回首字母色点，
 * 用户看到的就是「圆盘和面板里都没有 App 图标」）。这里改成四级取图，任一成功即返回：
 *   ① SBIconModel → 图标对象 → `-iconImageWithInfo:`（iOS 13+ 屏幕快照渲染，最准）
 *   ② App 包内的 PNG（AppIcon60x60@3x.png 等，系统 App 和多数第三方 App 都有）
 *   ③ UIImage 私有 `+_applicationIconImageForBundleIdentifier:format:scale:`
 *   ④ SBIconController 的旧接口（format 0~3 逐个试）
 * 全部失败返回 nil，Swift 侧仍保留文字卡片兜底。
 *
 * 私有调用一律 @try/@catch：图标取不到是小事，绝不能让它把 SpringBoard 拖下水。
 */

typedef struct {
    CGSize size;
    CGFloat scale;
    CGFloat cornerRadius;
} AevonIconImageInfo;

static NSMutableDictionary<NSString *, UIImage *> *AevonIconCache(void) {
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

/* ① 桌面图标模型 → iconImageWithInfo: */
static UIImage *AevonIconFromIconModel(NSString *bundleID, CGFloat pointSize) {
    Class ctlClass = NSClassFromString(@"SBIconController");
    if (ctlClass == Nil) { return nil; }
    id controller = ((id (*)(id, SEL))objc_msgSend)(ctlClass, NSSelectorFromString(@"sharedInstance"));
    if (controller == nil || ![controller respondsToSelector:NSSelectorFromString(@"model")]) { return nil; }
    id model = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"model"));
    if (model == nil) { return nil; }

    id icon = nil;
    SEL leafSelector = NSSelectorFromString(@"leafIconForIdentifier:");
    if ([model respondsToSelector:leafSelector]) {
        icon = ((id (*)(id, SEL, id))objc_msgSend)(model, leafSelector, bundleID);
    }
    if (icon == nil) {
        SEL appSelector = NSSelectorFromString(@"applicationIconForBundleIdentifier:");
        if ([model respondsToSelector:appSelector]) {
            icon = ((id (*)(id, SEL, id))objc_msgSend)(model, appSelector, bundleID);
        }
    }
    if (icon == nil) { return nil; }

    SEL infoSelector = NSSelectorFromString(@"iconImageWithInfo:");
    if ([icon respondsToSelector:infoSelector]) {
        NSMethodSignature *signature = [icon methodSignatureForSelector:infoSelector];
        if (signature != nil && signature.numberOfArguments >= 3) {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            [invocation setTarget:icon];
            [invocation setSelector:infoSelector];
            AevonIconImageInfo info;
            info.size = CGSizeMake(pointSize, pointSize);
            info.scale = 3.0;
            info.cornerRadius = pointSize * 0.2237;
            [invocation setArgument:&info atIndex:2];
            [invocation retainArguments];
            [invocation invoke];
            __unsafe_unretained id result = nil;
            [invocation getReturnValue:&result];
            if ([result isKindOfClass:[UIImage class]]) { return (UIImage *)result; }
        }
    }
    SEL legacySelector = NSSelectorFromString(@"getIconImage:");
    if ([icon respondsToSelector:legacySelector]) {
        id image = ((id (*)(id, SEL, id))objc_msgSend)(icon, legacySelector, bundleID);
        if ([image isKindOfClass:[UIImage class]]) { return (UIImage *)image; }
    }
    return nil;
}

/* ② App 包内 PNG（不依赖私有 UI 接口，系统 App 必有） */
static UIImage *AevonIconFromBundleFiles(NSString *bundleID) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass == Nil) { return nil; }
    SEL proxySelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![proxyClass respondsToSelector:proxySelector]) { return nil; }
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, bundleID);
    if (proxy == nil) { return nil; }

    NSURL *bundleURL = nil;
    @try {
        if ([proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) {
            bundleURL = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleURL"));
        }
    } @catch (NSException *exception) {
        bundleURL = nil;
    }
    if (![bundleURL isKindOfClass:[NSURL class]]) { return nil; }
    NSString *directory = bundleURL.path;
    if (directory.length == 0) { return nil; }

    NSArray<NSString *> *preferred = @[
        @"AppIcon60x60@3x.png",
        @"AppIcon60x60@2x.png",
        @"AppIcon76x76@2x~ipad.png",
        @"Icon-60@3x.png",
        @"Icon-60@2x.png",
        @"Icon@3x.png",
        @"Icon@2x.png",
        @"Icon.png",
        @"icon.png",
    ];
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *name in preferred) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if (![manager fileExistsAtPath:path]) { continue; }
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image != nil) { return image; }
    }

    // 兜底：目录里所有 png 里挑名字像图标、像素最大的那张
    NSArray<NSString *> *files = [manager contentsOfDirectoryAtPath:directory error:NULL];
    UIImage *best = nil;
    CGFloat bestArea = 0;
    for (NSString *file in files) {
        if (![[file lowercaseString] hasSuffix:@".png"]) { continue; }
        NSString *lower = [file lowercaseString];
        if (!([lower containsString:@"appicon"] || [lower containsString:@"icon"])) { continue; }
        if ([lower containsString:@"mask"] || [lower containsString:@"small"] ||
            [lower containsString:@"spotlight"] || [lower containsString:@"notification"]) { continue; }
        NSString *path = [directory stringByAppendingPathComponent:file];
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image == nil) { continue; }
        CGFloat area = image.size.width * image.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = image;
        }
    }
    return best;
}

/* ③ UIImage 的私有接口：+_applicationIconImageForBundleIdentifier:format:scale: */
static UIImage *AevonIconFromUIImage(NSString *bundleID, CGFloat scale) {
    Class imageClass = [UIImage class];
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![imageClass respondsToSelector:selector]) { return nil; }
    CGFloat useScale = scale > 0 ? scale : 3.0;
    for (int format = 0; format <= 3; format++) {
        @try {
            id image = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)(imageClass, selector, bundleID, format, useScale);
            if ([image isKindOfClass:[UIImage class]]) { return (UIImage *)image; }
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return nil;
}

/* ④ SBIconController 旧接口 */
static UIImage *AevonIconFromIconController(NSString *bundleID, CGFloat scale) {
    Class ctlClass = NSClassFromString(@"SBIconController");
    if (ctlClass == Nil) { return nil; }
    id controller = ((id (*)(id, SEL))objc_msgSend)(ctlClass, NSSelectorFromString(@"sharedInstance"));
    if (controller == nil) { return nil; }
    SEL selector = NSSelectorFromString(@"applicationIconImageForBundleIdentifier:format:scale:");
    if (![controller respondsToSelector:selector]) { return nil; }
    CGFloat useScale = scale > 0 ? scale : 3.0;
    for (int format = 0; format <= 3; format++) {
        @try {
            id image = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)(controller, selector, bundleID, format, useScale);
            if ([image isKindOfClass:[UIImage class]]) { return (UIImage *)image; }
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return nil;
}

UIImage *AevonIconImage(NSString *bundleID, CGFloat scale) {
    if (bundleID.length == 0) { return nil; }
    NSMutableDictionary<NSString *, UIImage *> *cache = AevonIconCache();
    UIImage *cached = cache[bundleID];
    if (cached != nil) { return cached; }

    CGFloat pointSize = 60.0;
    UIImage *image = nil;
    @try {
        image = AevonIconFromIconModel(bundleID, pointSize);
        if (image == nil) { image = AevonIconFromBundleFiles(bundleID); }
        if (image == nil) { image = AevonIconFromUIImage(bundleID, scale); }
        if (image == nil) { image = AevonIconFromIconController(bundleID, scale); }
    } @catch (NSException *exception) {
        image = nil;
    }
    if (image != nil) { cache[bundleID] = image; }
    return image;
}

/*
 * dyld 构造函数入口（与垫片同文件，省掉单独的 ctor.m）。
 * 保持极小：只转发到 Swift 侧的分屏初始化函数，Swift 内部全部有守卫，
 * 任何失败只记录日志，绝不把异常抛回 dyld。
 */
extern void AevonInitialize(void);

__attribute__((constructor)) static void AevonConstructor(void) {
    AevonInitialize();
}
